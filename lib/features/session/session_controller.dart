import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import '../../codex/codex_command.dart';
import '../../codex/codex_events.dart';
import '../../codex/codex_output_schema.dart';
import '../../services/codex_session_store.dart';
import '../../services/conversation_store.dart';
import '../../services/local_shell_service.dart';
import '../../services/secure_storage_service.dart';
import '../../services/ssh_service.dart';
import '../projects/target_args.dart';

class SessionController extends GetxController {
  final TargetArgs target;
  final String projectPath;
  final String tabId;
  final InMemoryChatController chatController;
  final TextEditingController inputController = TextEditingController();

  final isRunning = false.obs;
  final threadId = RxnString();

  final _uuid = const Uuid();
  void Function()? _cancelCurrent;
  CustomMessage? _pendingActionsMessage;
  String _lastUserPromptPreview = '';
  String? _sshPassword;

  static const _codexRemoteDir = '.codex_remote';
  String get _schemaRelPath => '$_codexRemoteDir/output-schema.json';
  String get _sessionsDirRelPath => '$_codexRemoteDir/sessions';
  String get _tmpDirRelPath => '$_codexRemoteDir/tmp';
  String get _logRelPath => '$_sessionsDirRelPath/$tabId.log';
  String get _stderrLogRelPath => '$_sessionsDirRelPath/$tabId.stderr.log';

  String? _remoteJobId;
  SshCommandProcess? _remoteLaunchProc;
  SshCommandProcess? _tailProc;
  StreamSubscription<String>? _tailStdoutSub;
  StreamSubscription<String>? _tailStderrSub;
  Future<void> _tailQueue = Future.value();

  SessionController({
    required this.target,
    required this.projectPath,
    required this.tabId,
  }) : chatController = InMemoryChatController();

  CodexSessionStore get _sessionStore => Get.find<CodexSessionStore>();
  ConversationStore get _conversationStore => Get.find<ConversationStore>();
  SecureStorageService get _storage => Get.find<SecureStorageService>();
  SshService get _ssh => Get.find<SshService>();
  LocalShellService get _localShell => Get.find<LocalShellService>();

  static const _me = 'user';
  static const _codex = 'codex';
  static const _system = 'system';

  @override
  void onInit() {
    super.onInit();
    _loadThreadId();
    _insertWelcome();
    if (!target.local) {
      _maybeReattachRemote();
    }
  }

  @override
  void onClose() {
    _cancelTailOnly();
    chatController.dispose();
    inputController.dispose();
    super.onClose();
  }

  Future<User> resolveUser(UserID id) async {
    if (id == _me) return const User(id: _me, name: 'You');
    if (id == _codex) return const User(id: _codex, name: 'Codex');
    return const User(id: _system, name: 'System');
  }

  Future<void> resetThread() async {
    threadId.value = null;
    await _sessionStore.clearThreadId(
      targetKey: target.targetKey,
      projectPath: projectPath,
      tabId: tabId,
    );
    await chatController.setMessages([]);
    _pendingActionsMessage = null;
    await _insertWelcome();
  }

  Future<void> resumeThreadById(String id, {String? preview}) async {
    await _consumePendingActions();
    threadId.value = id;
    await _sessionStore.saveThreadId(
      targetKey: target.targetKey,
      projectPath: projectPath,
      tabId: tabId,
      threadId: id,
    );

    await chatController.setMessages([]);
    _pendingActionsMessage = null;
    await _insertEvent(
      type: 'resume',
      text: 'Resuming thread ${id.substring(0, 8)}… ${preview ?? ''}',
    );
  }

  void stop() {
    _cancelCurrent?.call();
  }

  Future<void> sendText(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    await _consumePendingActions();
    _lastUserPromptPreview =
        trimmed.length > 80 ? '${trimmed.substring(0, 80)}…' : trimmed;
    inputController.clear();

    final userMessage = Message.text(
      id: _uuid.v4(),
      authorId: _me,
      createdAt: DateTime.now().toUtc(),
      text: trimmed,
    );
    await chatController.insertMessage(userMessage, animated: true);

    await _runCodexTurn(prompt: trimmed);
  }

  Future<void> sendQuickReply(String value) => sendText(value);

  Future<void> _loadThreadId() async {
    final stored = await _sessionStore.loadThreadId(
      targetKey: target.targetKey,
      projectPath: projectPath,
      tabId: tabId,
    );
    threadId.value = stored;
  }

  Future<void> _saveThreadId(String id) async {
    threadId.value = id;
    await _sessionStore.saveThreadId(
      targetKey: target.targetKey,
      projectPath: projectPath,
      tabId: tabId,
      threadId: id,
    );
  }

  Future<void> _insertWelcome() async {
    await chatController.insertMessage(
      _welcomeMessage(),
    );
  }

  Message _welcomeMessage() {
    return Message.custom(
      id: _uuid.v4(),
      authorId: _system,
      createdAt: DateTime.now().toUtc(),
      metadata: const {
        'kind': 'codex_event',
        'eventType': 'welcome',
        'text': 'Uses `codex exec --json --output-schema` and renders events + actions.',
      },
    );
  }

  Future<String?> _promptForPassword() async {
    final controller = TextEditingController();
    try {
      return await Get.dialog<String>(
        AlertDialog(
          title: const Text('SSH password'),
          content: TextField(
            controller: controller,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Password'),
            onSubmitted: (_) => Get.back(result: controller.text),
          ),
          actions: [
            TextButton(
              onPressed: () => Get.back(result: null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Get.back(result: controller.text),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  static String _joinPosix(String a, String b) {
    if (a.endsWith('/')) return '$a$b';
    return '$a/$b';
  }

  String _remoteAbsPath(String rel) => _joinPosix(projectPath, rel);

  Future<void> _ensureSchema({required String schemaContents}) async {
    if (target.local) {
      final schemaPath = _joinPosix(projectPath, _schemaRelPath);
      final file = File(schemaPath);
      await file.parent.create(recursive: true);
      await file.writeAsString(schemaContents);
      return;
    }

    final profile = target.profile!;
    final pem =
        await _storage.read(key: SecureStorageService.sshPrivateKeyPemKey);

    await _ssh.writeRemoteFile(
      host: profile.host,
      port: profile.port,
      username: profile.username,
      privateKeyPem: pem,
      password: _sshPassword,
      remotePath: _joinPosix(projectPath, _schemaRelPath),
      contents: schemaContents,
    );
  }

  Future<void> _ensureCodexRemoteDirsLocal() async {
    final dir = Directory(_joinPosix(projectPath, _codexRemoteDir));
    await dir.create(recursive: true);
    await Directory(_joinPosix(projectPath, _sessionsDirRelPath))
        .create(recursive: true);
    await Directory(_joinPosix(projectPath, _tmpDirRelPath))
        .create(recursive: true);
    await File(_joinPosix(projectPath, _logRelPath)).create(recursive: true);
    await File(_joinPosix(projectPath, _stderrLogRelPath))
        .create(recursive: true);
  }

  Future<void> _ensureCodexRemoteDirsRemote() async {
    final profile = target.profile!;
    final pem =
        await _storage.read(key: SecureStorageService.sshPrivateKeyPemKey);

    Future<void> run(String cmd) async {
      try {
        await _ssh.runCommandWithResult(
          host: profile.host,
          port: profile.port,
          username: profile.username,
          privateKeyPem: pem,
          password: _sshPassword,
          command: cmd,
        );
      } catch (_) {
        if (_sshPassword == null) {
          final pw = await _promptForPassword();
          if (pw == null || pw.isEmpty) rethrow;
          _sshPassword = pw;
          await _ssh.runCommandWithResult(
            host: profile.host,
            port: profile.port,
            username: profile.username,
            privateKeyPem: pem,
            password: _sshPassword,
            command: cmd,
          );
          return;
        }
        rethrow;
      }
    }

    final sessionsAbs = _remoteAbsPath(_sessionsDirRelPath);
    final tmpAbs = _remoteAbsPath(_tmpDirRelPath);
    final logAbs = _remoteAbsPath(_logRelPath);
    final errAbs = _remoteAbsPath(_stderrLogRelPath);

    final cmd =
        'mkdir -p ${_shQuote(sessionsAbs)} ${_shQuote(tmpAbs)} && touch ${_shQuote(logAbs)} ${_shQuote(errAbs)}';
    await run('sh -lc ${_shQuote(cmd)}');
  }

  void _cancelTailOnly() {
    try {
      _tailStdoutSub?.cancel();
    } catch (_) {}
    try {
      _tailStderrSub?.cancel();
    } catch (_) {}
    try {
      _tailProc?.cancel();
    } catch (_) {}
    _tailProc = null;
    _tailStdoutSub = null;
    _tailStderrSub = null;
  }

  Future<void> _runCodexTurn({required String prompt}) async {
    if (isRunning.value) return;

    if (target.local) {
      isRunning.value = true;
      _cancelCurrent = null;
      try {
        await _ensureCodexRemoteDirsLocal();
        await _ensureSchema(schemaContents: CodexOutputSchema.encode());

        final cmd = CodexCommandBuilder.build(
          prompt: prompt,
          schemaPath: _schemaRelPath,
          resumeThreadId: threadId.value,
          jsonl: true,
          cd: null,
          configOverrides: const {
            // Avoid repeating/adding global developer instructions on every turn.
            'developer_instructions': '""',
          },
        );

        await _insertEvent(
          type: 'command_execution',
          text: 'Running locally: codex ${CodexCommandBuilder.shellString(cmd.args)}',
        );

        await _runLocal(cmd);
      } finally {
        _cancelCurrent = null;
        isRunning.value = false;
      }
      return;
    }

    await _runRemoteViaTmux(prompt: prompt);
  }

  Future<void> _runLocal(CodexCommand cmd) async {
    final proc = _localShell.startCommand(
      executable: 'codex',
      arguments: cmd.args,
      workingDirectory: projectPath,
      stdin: cmd.stdin,
    );
    _cancelCurrent = proc.cancel;

    await _consumeCodexStreams(
      stdoutJsonl: proc.stdoutLines.map((l) {
        try {
          final decoded = jsonDecode(l);
          if (decoded is Map) return decoded.cast<String, Object?>();
        } catch (_) {}
        return <String, Object?>{};
      }).where((m) => m.isNotEmpty),
      stderrLines: proc.stderrLines,
      onExit: proc.done,
    );
  }

  Future<void> _runRemoteViaTmux({required String prompt}) async {
    if (isRunning.value) return;
    isRunning.value = true;
    _cancelCurrent = () {
      final launch = _remoteLaunchProc;
      if (launch != null) {
        launch.cancel();
        _remoteLaunchProc = null;
        _cancelTailOnly();
        isRunning.value = false;
        _cancelCurrent = null;
        return;
      }
      _stopRemoteJob().whenComplete(() {
        _cancelTailOnly();
        _cancelCurrent = null;
        isRunning.value = false;
      });
    };

    final profile = target.profile!;

    final pem =
        await _storage.read(key: SecureStorageService.sshPrivateKeyPemKey);

    try {
      await _stopRemoteJobBestEffort();
      await _ensureCodexRemoteDirsRemote();
      await _ensureSchema(schemaContents: CodexOutputSchema.encode());

      final schemaAbs = _remoteAbsPath(_schemaRelPath);
      final cmd = CodexCommandBuilder.build(
        prompt: prompt,
        schemaPath: schemaAbs,
        resumeThreadId: threadId.value,
        jsonl: true,
        cd: projectPath,
        configOverrides: const {
          // Avoid repeating/adding global developer instructions on every turn.
          'developer_instructions': '""',
        },
      );

      await _insertEvent(
        type: 'command_execution',
        text:
            'Starting remote job: codex ${CodexCommandBuilder.shellString(cmd.args)}',
      );

      await _startRemoteLogTailIfNeeded();

      final promptRel = '$_tmpDirRelPath/prompt-${_uuid.v4()}.txt';
      final promptAbs = _remoteAbsPath(promptRel);
      await _ssh.writeRemoteFile(
        host: profile.host,
        port: profile.port,
        username: profile.username,
        privateKeyPem: pem,
        password: _sshPassword,
        remotePath: promptAbs,
        contents: cmd.stdin,
      );

      final tmuxName =
          'cr_${tabId.replaceAll('-', '').substring(0, 8)}_${DateTime.now().millisecondsSinceEpoch}';

      final runRel = '$_tmpDirRelPath/run-${_uuid.v4()}.sh';
      final runAbs = _remoteAbsPath(runRel);

      final logAbs = _remoteAbsPath(_logRelPath);
      final errAbs = _remoteAbsPath(_stderrLogRelPath);
      final pidAbs = _remoteAbsPath('$_sessionsDirRelPath/$tabId.pid');

      final codexCmd = 'codex ${CodexCommandBuilder.shellString(cmd.args)}';
      final runScript = [
        '#!/bin/sh',
        'set -e',
        '$codexCmd < ${_shQuote(promptAbs)} >> ${_shQuote(logAbs)} 2>> ${_shQuote(errAbs)}',
      ].join('\n');

      await _ssh.writeRemoteFile(
        host: profile.host,
        port: profile.port,
        username: profile.username,
        privateKeyPem: pem,
        password: _sshPassword,
        remotePath: runAbs,
        contents: runScript,
      );

      final startBody = [
        'if command -v tmux >/dev/null 2>&1; then',
        '  tmux new-session -d -s ${_shQuote(tmuxName)} sh ${_shQuote(runAbs)}',
        '  echo CODEX_REMOTE_JOB=tmux:$tmuxName',
        'else',
        '  nohup sh ${_shQuote(runAbs)} >/dev/null 2>&1 &',
        '  pid=\$!',
        '  echo "\$pid" > ${_shQuote(pidAbs)}',
        '  echo CODEX_REMOTE_JOB=pid:\$pid',
        'fi',
      ].join('\n');
      final startCmd = 'sh -lc ${_shQuote(startBody)}';

      final launchProc = await _ssh.startCommand(
        host: profile.host,
        port: profile.port,
        username: profile.username,
        privateKeyPem: pem,
        password: _sshPassword,
        command: startCmd,
      );
      _remoteLaunchProc = launchProc;

      final stdout = <String>[];
      final stderr = <String>[];
      final stdoutSub = launchProc.stdoutLines.listen(stdout.add);
      final stderrSub = launchProc.stderrLines.listen(stderr.add);

      int? exit;
      try {
        exit = await launchProc.exitCode.timeout(const Duration(seconds: 10));
      } finally {
        await stdoutSub.cancel();
        await stderrSub.cancel();
        _remoteLaunchProc = null;
      }

      if ((exit ?? 1) != 0) {
        throw StateError(
          'Remote launch failed (exit=$exit): ${(stderr.join('\n')).trim().isEmpty ? (stdout.join('\n')).trim() : (stderr.join('\n')).trim()}',
        );
      }

      String? jobLine;
      for (final line in stdout.reversed) {
        if (line.startsWith('CODEX_REMOTE_JOB=')) {
          jobLine = line;
          break;
        }
      }
      final remoteJobId =
          jobLine?.substring('CODEX_REMOTE_JOB='.length).trim();
      if (remoteJobId == null || remoteJobId.isEmpty) {
        throw StateError('Remote launch did not return a job id.');
      }

      _remoteJobId = remoteJobId;
      await _sessionStore.saveRemoteJobId(
        targetKey: target.targetKey,
        projectPath: projectPath,
        tabId: tabId,
        remoteJobId: remoteJobId,
      );
      await _insertEvent(type: 'remote_job', text: remoteJobId);
    } catch (e) {
      try {
        _remoteLaunchProc?.cancel();
      } catch (_) {}
      _remoteLaunchProc = null;
      await _insertEvent(type: 'error', text: 'Remote start failed: $e');
      _cancelCurrent = null;
      isRunning.value = false;
    }
  }

  Future<void> _startRemoteLogTailIfNeeded() async {
    if (_tailProc != null) return;

    final profile = target.profile!;
    final pem =
        await _storage.read(key: SecureStorageService.sshPrivateKeyPemKey);

    Future<SshCommandProcess> start(String cmd) async {
      try {
        return await _ssh.startCommand(
          host: profile.host,
          port: profile.port,
          username: profile.username,
          privateKeyPem: pem,
          password: _sshPassword,
          command: cmd,
        );
      } catch (_) {
        if (_sshPassword == null) {
          final pw = await _promptForPassword();
          if (pw == null || pw.isEmpty) rethrow;
          _sshPassword = pw;
          return _ssh.startCommand(
            host: profile.host,
            port: profile.port,
            username: profile.username,
            privateKeyPem: pem,
            password: _sshPassword,
            command: cmd,
          );
        }
        rethrow;
      }
    }

    final logAbs = _remoteAbsPath(_logRelPath);
    final cmd = 'sh -lc ${_shQuote('tail -n 0 -F ${_shQuote(logAbs)}')}';
    final proc = await start(cmd);
    _tailProc = proc;

    _tailStdoutSub = proc.stdoutLines.listen((line) {
      if (line.trim().isEmpty) return;
      _tailQueue = _tailQueue.then((_) async {
        try {
          final decoded = jsonDecode(line);
          if (decoded is Map) {
            await _handleCodexJsonEvent(decoded.cast<String, Object?>());
          }
        } catch (_) {
          // Ignore non-JSON noise.
        }
      });
    });

    _tailStderrSub = proc.stderrLines.listen((line) {
      if (line.trim().isEmpty) return;
      _insertEvent(type: 'tail_stderr', text: line);
    });

    proc.done.then((_) {
      if (!isClosed) {
        _insertEvent(type: 'tail_closed', text: 'Log tail stopped.');
      }
      _cancelTailOnly();
    });
  }

  Future<void> _stopRemoteJobBestEffort() async {
    try {
      await _stopRemoteJob();
    } catch (_) {}
  }

  Future<void> _stopRemoteJob() async {
    final job = _remoteJobId ??
        await _sessionStore.loadRemoteJobId(
          targetKey: target.targetKey,
          projectPath: projectPath,
          tabId: tabId,
        );
    if (job == null || job.isEmpty) {
      return;
    }

    final profile = target.profile!;
    final pem =
        await _storage.read(key: SecureStorageService.sshPrivateKeyPemKey);

    String cmd;
    if (job.startsWith('tmux:')) {
      final name = job.substring('tmux:'.length);
      cmd = 'tmux kill-session -t ${_shQuote(name)} || true';
    } else if (job.startsWith('pid:')) {
      final pid = job.substring('pid:'.length);
      cmd = 'kill $pid >/dev/null 2>&1 || true';
    } else {
      cmd = 'true';
    }

    await _ssh.runCommandWithResult(
      host: profile.host,
      port: profile.port,
      username: profile.username,
      privateKeyPem: pem,
      password: _sshPassword,
      command: 'sh -lc ${_shQuote(cmd)}',
    );

    await _sessionStore.clearRemoteJobId(
      targetKey: target.targetKey,
      projectPath: projectPath,
      tabId: tabId,
    );
    _remoteJobId = null;
  }

  Future<void> _maybeReattachRemote() async {
    try {
      final stored = await _sessionStore.loadRemoteJobId(
        targetKey: target.targetKey,
        projectPath: projectPath,
        tabId: tabId,
      );
      _remoteJobId = stored;

      await _rehydrateFromRemoteLog(maxLines: 200);

      if (stored == null || stored.isEmpty) return;

      final profile = target.profile!;
      final pem =
          await _storage.read(key: SecureStorageService.sshPrivateKeyPemKey);

      String checkCmd;
      if (stored.startsWith('tmux:')) {
        final name = stored.substring('tmux:'.length);
        checkCmd = 'tmux has-session -t ${_shQuote(name)}';
      } else if (stored.startsWith('pid:')) {
        final pid = stored.substring('pid:'.length);
        checkCmd = 'kill -0 $pid >/dev/null 2>&1';
      } else {
        checkCmd = 'false';
      }

      final check = await _ssh.runCommandWithResult(
        host: profile.host,
        port: profile.port,
        username: profile.username,
        privateKeyPem: pem,
        password: _sshPassword,
        command: 'sh -lc ${_shQuote(checkCmd)}',
      );

      if ((check.exitCode ?? 1) == 0) {
        isRunning.value = true;
        _cancelCurrent = () {
          _stopRemoteJob().whenComplete(() {
            _cancelTailOnly();
            _cancelCurrent = null;
            isRunning.value = false;
          });
        };
        await _startRemoteLogTailIfNeeded();
      } else {
        await _sessionStore.clearRemoteJobId(
          targetKey: target.targetKey,
          projectPath: projectPath,
          tabId: tabId,
        );
        _remoteJobId = null;
      }
    } catch (_) {
      // Best-effort.
    }
  }

  Future<void> _rehydrateFromRemoteLog({required int maxLines}) async {
    if (target.local) return;
    final profile = target.profile!;
    final pem =
        await _storage.read(key: SecureStorageService.sshPrivateKeyPemKey);

    try {
      final logAbs = _remoteAbsPath(_logRelPath);
      final cmd =
          'sh -lc ${_shQuote('if [ -f ${_shQuote(logAbs)} ]; then tail -n $maxLines ${_shQuote(logAbs)}; fi')}';

      final res = await _ssh.runCommandWithResult(
        host: profile.host,
        port: profile.port,
        username: profile.username,
        privateKeyPem: pem,
        password: _sshPassword,
        command: cmd,
      );

      final lines = const LineSplitter().convert(res.stdout);
      if (lines.isEmpty) return;

      _pendingActionsMessage = null;
      final backfill = <Message>[
        _welcomeMessage(),
        _eventMessage(
          type: 'replay',
          text: 'Replayed last ${lines.length} log lines.',
        ),
      ];

      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final decoded = jsonDecode(line);
          if (decoded is Map) {
            final out = await _materializeCodexJsonEvent(
              decoded.cast<String, Object?>(),
              replay: true,
            );
            backfill.addAll(out);
          }
        } catch (_) {}
      }

      await chatController.setMessages(backfill, animated: false);
    } catch (_) {
      // Best-effort.
    }
  }

  Future<void> _consumeCodexStreams({
    required Stream<Map<String, Object?>> stdoutJsonl,
    required Stream<String> stderrLines,
    required Future<void> onExit,
  }) async {
    final stderrSub = stderrLines.listen((line) {
      if (line.trim().isEmpty) return;
      _insertEvent(type: 'stderr', text: line);
    });

    try {
      await for (final event in stdoutJsonl) {
        await _handleCodexJsonEvent(event);
      }
      await onExit;
    } finally {
      await stderrSub.cancel();
    }
  }

  Future<void> _handleCodexJsonEvent(Map<String, Object?> event) async {
    final type = event['type'] as String?;
    if (type == null || type.isEmpty) return;

    if (type == 'thread.started') {
      final id = event['thread_id'] as String?;
      if (id != null && id.isNotEmpty) {
        await _saveThreadId(id);
        await _conversationStore.upsert(
          targetKey: target.targetKey,
          projectPath: projectPath,
          threadId: id,
          preview: _lastUserPromptPreview,
        );
      }
      await _insertEvent(type: type, text: 'thread_id=${id ?? ''}');
      return;
    }

    if (type == 'turn.started' || type == 'turn.completed' || type == 'turn.failed') {
      await _insertEvent(type: type, text: _compact(event));

      if (!target.local && (type == 'turn.completed' || type == 'turn.failed')) {
        await _sessionStore.clearRemoteJobId(
          targetKey: target.targetKey,
          projectPath: projectPath,
          tabId: tabId,
        );
        _remoteJobId = null;
        _cancelCurrent = null;
        isRunning.value = false;
      }
      return;
    }

    if (type.startsWith('item.')) {
      final item = event['item'];
      if (item is Map) {
        final itemType = item['type'] as String?;
        if (itemType == 'agent_message') {
          final text = item['text'] as String? ?? '';
          final messages = await _materializeAgentMessage(text, replay: false);
          if (messages.isNotEmpty) {
            await chatController.insertAllMessages(messages, animated: true);
          }
          return;
        }

        // Render each item type distinctly.
        await chatController.insertMessage(
          _itemMessage(
            eventType: type,
            itemType: itemType ?? 'unknown',
            text: _summarizeItem(itemType, item.cast<String, Object?>()),
            item: item,
          ),
          animated: true,
        );
      }
      return;
    }

    await _insertEvent(type: type, text: _compact(event));
  }

  Future<List<Message>> _materializeAgentMessage(
    String text, {
    required bool replay,
  }) async {
    // With --output-schema, agent_message should be a JSON object matching it.
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        final resp =
            CodexStructuredResponse.fromJson(decoded.cast<String, Object?>());

        final out = <Message>[
          Message.text(
            id: _uuid.v4(),
            authorId: _codex,
            createdAt: DateTime.now().toUtc(),
            text: resp.message.isEmpty ? '(empty response)' : resp.message,
          ),
        ];

        final commitMessage = resp.commitMessage.trim();
        out.add(
          _eventMessage(
            type: 'commit_message',
            text: commitMessage.isEmpty ? '(empty commit_message)' : commitMessage,
          ),
        );

        if (!replay && commitMessage.isNotEmpty) {
          await _maybeAutoCommit(commitMessage);
        }

        if (resp.actions.isNotEmpty) {
          final actionsMessage = Message.custom(
                id: _uuid.v4(),
                authorId: _codex,
                createdAt: DateTime.now().toUtc(),
                metadata: {
                  'kind': 'codex_actions',
                  'actions': resp.actions
                      .map((a) => {'id': a.id, 'label': a.label, 'value': a.value})
                      .toList(),
                },
              ) as CustomMessage;
          _pendingActionsMessage = actionsMessage;
          out.add(actionsMessage);
        }
        return out;
      }
    } catch (_) {
      // Fall through.
    }

    return [
      Message.text(
        id: _uuid.v4(),
        authorId: _codex,
        createdAt: DateTime.now().toUtc(),
        text: text,
      ),
    ];
  }

  Future<List<Message>> _materializeCodexJsonEvent(
    Map<String, Object?> event, {
    required bool replay,
  }) async {
    final type = event['type'] as String?;
    if (type == null || type.isEmpty) return const [];

    if (type == 'thread.started') {
      final id = event['thread_id'] as String?;
      if (id != null && id.isNotEmpty) {
        threadId.value = id;
        if (!replay) {
          await _saveThreadId(id);
          await _conversationStore.upsert(
            targetKey: target.targetKey,
            projectPath: projectPath,
            threadId: id,
            preview: _lastUserPromptPreview,
          );
        }
      }
      return [_eventMessage(type: type, text: 'thread_id=${id ?? ''}')];
    }

    if (type == 'turn.started' || type == 'turn.completed' || type == 'turn.failed') {
      return [_eventMessage(type: type, text: _compact(event))];
    }

    if (type.startsWith('item.')) {
      final item = event['item'];
      if (item is Map) {
        final itemType = item['type'] as String? ?? 'unknown';
        if (itemType == 'agent_message') {
          final text = item['text'] as String? ?? '';
          return _materializeAgentMessage(text, replay: replay);
        }
        return [
          _itemMessage(
            eventType: type,
            itemType: itemType,
            text: _summarizeItem(itemType, item.cast<String, Object?>()),
            item: item,
          ),
        ];
      }
      return const [];
    }

    return [_eventMessage(type: type, text: _compact(event))];
  }

  Future<void> _consumePendingActions() async {
    final pending = _pendingActionsMessage;
    if (pending == null) return;
    _pendingActionsMessage = null;

    try {
      final metadata = Map<String, Object?>.from(pending.metadata ?? const {});
      metadata['kind'] = 'codex_actions_consumed';
      metadata['actions'] = const [];

      await chatController.updateMessage(
        pending,
        pending.copyWith(metadata: metadata),
      );
    } catch (_) {
      // Best-effort: if the message is gone, ignore.
    }
  }

  Future<void> _maybeAutoCommit(String commitMessage) async {
    try {
      if (target.local) {
        await _maybeAutoCommitLocal(commitMessage);
      } else {
        await _maybeAutoCommitRemote(commitMessage);
      }
    } catch (e) {
      await _insertEvent(type: 'git_commit_failed', text: '$e');
    }
  }

  Future<void> _maybeAutoCommitLocal(String commitMessage) async {
    await _ensureCodexRemoteExcludedLocal();

    final status = await _localShell.run(
      executable: 'git',
      arguments: const ['status', '--porcelain'],
      workingDirectory: projectPath,
      throwOnError: false,
    );

    final changes = (status.stdout as Object?).toString().trim();
    if (changes.isEmpty) {
      await _insertEvent(type: 'git_commit_skipped', text: 'No changes to commit.');
      return;
    }

    await _localShell.run(
      executable: 'git',
      arguments: const ['add', '-A'],
      workingDirectory: projectPath,
      throwOnError: false,
    );

    final commit = await _localShell.run(
      executable: 'git',
      arguments: ['commit', '-m', commitMessage],
      workingDirectory: projectPath,
      throwOnError: false,
    );

    final out = (commit.stdout as Object?).toString().trim();
    final err = (commit.stderr as Object?).toString().trim();
    if (out.isNotEmpty) await _insertEvent(type: 'git_commit_stdout', text: out);
    if (err.isNotEmpty) await _insertEvent(type: 'git_commit_stderr', text: err);
  }

  Future<void> _maybeAutoCommitRemote(String commitMessage) async {
    final profile = target.profile!;
    final pem = await _storage.read(key: SecureStorageService.sshPrivateKeyPemKey);

    String? password = _sshPassword;

    Future<String> run(String cmd) async {
      try {
        return await _ssh.runCommand(
          host: profile.host,
          port: profile.port,
          username: profile.username,
          privateKeyPem: pem,
          password: password,
          command: cmd,
        );
      } catch (_) {
        if (password == null) {
          password = await _promptForPassword();
          if (password == null || password!.isEmpty) rethrow;
          _sshPassword = password;
          return _ssh.runCommand(
            host: profile.host,
            port: profile.port,
            username: profile.username,
            privateKeyPem: pem,
            password: password,
            command: cmd,
          );
        }
        rethrow;
      }
    }

    final cd = _shQuote(projectPath);
    await run(
      'cd $cd && if [ -d .git ]; then mkdir -p .git/info; touch .git/info/exclude; grep -qxF ${_shQuote('.codex_remote/')} .git/info/exclude || printf %s\\\\n ${_shQuote('.codex_remote/')} >> .git/info/exclude; fi',
    );
    final statusOut = await run('cd $cd && git status --porcelain');
    if (statusOut.trim().isEmpty) {
      await _insertEvent(type: 'git_commit_skipped', text: 'No changes to commit.');
      return;
    }

    final msg = _shQuote(commitMessage);
    final commitOut = await run('cd $cd && git add -A && git commit -m $msg || true');
    if (commitOut.trim().isNotEmpty) {
      await _insertEvent(type: 'git_commit_stdout', text: commitOut.trim());
    }
  }

  static String _shQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

  Future<void> _ensureCodexRemoteExcludedLocal() async {
    final gitDir = Directory(_joinPosix(projectPath, '.git'));
    if (!gitDir.existsSync()) return;

    final excludeFile = File(_joinPosix(projectPath, '.git/info/exclude'));
    await excludeFile.parent.create(recursive: true);

    final existing = await excludeFile.exists()
        ? await excludeFile.readAsString()
        : '';
    const line = '.codex_remote/';
    if (existing.split('\n').any((l) => l.trim() == line)) return;

    final needsNewline = existing.isNotEmpty && !existing.endsWith('\n');
    await excludeFile.writeAsString(
      "${needsNewline ? '\n' : ''}$line\n",
      mode: FileMode.append,
    );
  }

  Future<void> _insertEvent({required String type, required String text}) async {
    await chatController.insertMessage(
      _eventMessage(type: type, text: text),
      animated: true,
    );
  }

  Message _eventMessage({required String type, required String text}) {
    return Message.custom(
      id: _uuid.v4(),
      authorId: _system,
      createdAt: DateTime.now().toUtc(),
      metadata: {
        'kind': 'codex_event',
        'eventType': type,
        'text': text,
      },
    );
  }

  Message _itemMessage({
    required String eventType,
    required String itemType,
    required String text,
    required Map item,
  }) {
    return Message.custom(
      id: _uuid.v4(),
      authorId: _system,
      createdAt: DateTime.now().toUtc(),
      metadata: {
        'kind': 'codex_item',
        'eventType': eventType,
        'itemType': itemType,
        'text': text,
        'item': item,
      },
    );
  }

  static String _summarizeItem(String? itemType, Map<String, Object?> item) {
    switch (itemType) {
      case 'reasoning':
        return (item['text'] as String?) ?? '';
      case 'command_execution':
        final cmd = item['command']?.toString() ?? '';
        final code = item['exit_code']?.toString();
        return code == null ? cmd : '$cmd (exit=$code)';
      case 'file_change':
        return item.toString();
      case 'mcp_tool_call':
        return item.toString();
      case 'web_search':
        return item.toString();
      case 'todo_list':
        return (item['text'] as String?) ?? item.toString();
      default:
        return item.toString();
    }
  }

  static String _compact(Map<String, Object?> map) {
    final copy = Map<String, Object?>.from(map);
    copy.remove('item');
    return copy.toString();
  }
}
