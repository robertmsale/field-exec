import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import '../../codex/codex_command.dart';
import '../../codex/codex_events.dart';
import '../../codex/codex_output_schema.dart';
import '../../services/field_exec_session_store.dart';
import '../../services/conversation_store.dart';
import '../../services/local_shell_service.dart';
import '../../services/active_session_service.dart';
import '../../services/app_lifecycle_service.dart';
import '../../services/notification_service.dart';
import '../../services/secure_storage_service.dart';
import '../../services/remote_jobs_store.dart';
import '../../services/ssh_service.dart';

class SessionController extends SessionControllerBase {
  final TargetArgs target;
  final String projectPath;
  final String tabId;
  @override
  final InMemoryChatController chatController;
  @override
  final TextEditingController inputController = TextEditingController();

  @override
  final isRunning = false.obs;
  @override
  final isLoadingMoreHistory = false.obs;
  @override
  final hasMoreHistory = false.obs;
  final _needsScrollToBottom = false.obs;
  @override
  RxBool get needsScrollToBottom => _needsScrollToBottom;
  @override
  final threadId = RxnString();
  @override
  final remoteJobId = RxnString();
  @override
  final thinkingPreview = RxnString();

  final _uuid = const Uuid();
  void Function()? _cancelCurrent;
  CustomMessage? _pendingActionsMessage;
  String _lastUserPromptPreview = '';
  bool _repairedExplodedChat = false;
  // FieldExec uses key-based SSH for normal operation; password auth is only
  // used for explicit key-install bootstrap flows.
  //
  // Keep this non-null to ensure we never show the legacy password prompt
  // from normal session execution paths.
  String? _sshPassword = '';
  int _logLineCursor = 0;
  String _logLastLineHash = '';
  static const _historyPageSizeLines = 400;
  int? _historyRemoteStartLine; // 1-based
  int? _historyLocalStartIndex; // 0-based
  String? _historyLogRelPath;
  String? _historyFocusThreadId;
  Timer? _cursorSaveTimer;
  Future<void> _cursorSaveQueue = Future.value();
  Timer? _hashSaveTimer;
  Future<void> _hashSaveQueue = Future.value();

  static const _fieldExecDir = '.field_exec';
  String get _schemaRelPath => '$_fieldExecDir/output-schema.json';
  String get _sessionsDirRelPath => '$_fieldExecDir/sessions';
  String get _tmpDirRelPath => '$_fieldExecDir/tmp';
  String get _devInstructionsRelPath =>
      '$_fieldExecDir/developer_instructions.txt';
  String get _logRelPath => '$_sessionsDirRelPath/$tabId.log';
  String get _stderrLogRelPath => '$_sessionsDirRelPath/$tabId.stderr.log';
  String get _jobRelPath => '$_sessionsDirRelPath/$tabId.job';
  String get _pidRelPath => '$_sessionsDirRelPath/$tabId.pid';

  String? _remoteJobId;
  SshCommandProcess? _remoteLaunchProc;
  SshCommandProcess? _tailProc;
  StreamSubscription<String>? _tailStdoutSub;
  StreamSubscription<String>? _tailStderrSub;
  Future<void> _tailQueue = Future.value();
  Future<void> _activeQueue = Future.value();
  Object? _tailToken;
  LocalCommandProcess? _localTailProc;
  StreamSubscription<String>? _localTailStdoutSub;
  StreamSubscription<String>? _localTailStderrSub;
  Object? _localTailToken;
  Worker? _lifecycleWorker;
  Worker? _activeWorker;
  final _recentLogLineHashes = <String>[];
  final _recentLogLineHashSet = <String>{};
  final _seenAgentMessageItemIds = <String>{};
  var _autoCommitCatchUpInProgress = false;

  SessionController({
    required this.target,
    required this.projectPath,
    required this.tabId,
  }) : chatController = InMemoryChatController();

  FieldExecSessionStore get _sessionStore => Get.find<FieldExecSessionStore>();
  ConversationStore get _conversationStore => Get.find<ConversationStore>();
  SecureStorageService get _storage => Get.find<SecureStorageService>();
  SshService get _ssh => Get.find<SshService>();
  LocalShellService get _localShell => Get.find<LocalShellService>();
  NotificationService get _notifications => Get.find<NotificationService>();
  ActiveSessionService get _activeSession => Get.find<ActiveSessionService>();
  AppLifecycleService get _lifecycle => Get.find<AppLifecycleService>();
  RemoteJobsStore get _remoteJobs => Get.find<RemoteJobsStore>();

  static const _me = 'user';
  static const _codex = 'codex';
  static const _system = 'system';
  static const _clientUserMessageType = 'client.user_message';
  static const _clientGitCommitType = 'client.git_commit';
  static const _serverGitCommitType = 'server.git_commit';
  static const _serverGitignoreBootstrapType = 'server.gitignore_bootstrap';
  static const _maxImageBytes = 10 * 1024 * 1024;

  @override
  void onInit() {
    super.onInit();
    _initAsync();
    _lifecycleWorker = ever<AppLifecycleState?>(_lifecycle.stateRx, (state) {
      if (state == AppLifecycleState.resumed) {
        _onAppResumed();
      } else if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.inactive ||
          state == AppLifecycleState.detached) {
        _onAppBackgrounded();
      }
    });
    _activeWorker = ever<ActiveSessionRef?>(_activeSession.activeRx, (ref) {
      if (target.local) return;
      final isActive =
          ref != null &&
          ref.targetKey == target.targetKey &&
          ref.projectPath == projectPath &&
          ref.tabId == tabId;
      if (!isActive) return;
      if (_tailProc != null) return;
      _activeQueue = _activeQueue.then((_) async {
        try {
          await _refreshRemoteRunningStateAndTail(backfillLines: 200);
        } catch (_) {}
      });
    });
  }

  @override
  void onClose() {
    _lifecycleWorker?.dispose();
    _activeWorker?.dispose();
    try {
      _cursorSaveTimer?.cancel();
    } catch (_) {}
    try {
      _hashSaveTimer?.cancel();
    } catch (_) {}
    _cancelTailOnly();
    _cancelLocalTailOnly();
    chatController.dispose();
    inputController.dispose();
    super.onClose();
  }

  @override
  Future<User> resolveUser(UserID id) async {
    if (id == _me) return const User(id: _me, name: 'You');
    if (id == _codex) return const User(id: _codex, name: 'Codex');
    return const User(id: _system, name: 'System');
  }

  Future<void> resetThread() async {
    threadId.value = null;
    thinkingPreview.value = null;
    _historyLogRelPath = _logRelPath;
    _historyFocusThreadId = null;
    _historyRemoteStartLine = null;
    _historyLocalStartIndex = null;
    hasMoreHistory.value = false;
    isLoadingMoreHistory.value = false;
    await _sessionStore.clearThreadId(
      targetKey: target.targetKey,
      projectPath: projectPath,
      tabId: tabId,
    );
    await chatController.setMessages([]);
    _needsScrollToBottom.value = false;
    _pendingActionsMessage = null;
  }

  @override
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
    _needsScrollToBottom.value = false;
    _pendingActionsMessage = null;
    _historyLogRelPath = null;
    _historyFocusThreadId = id;
    _historyRemoteStartLine = null;
    _historyLocalStartIndex = null;
    hasMoreHistory.value = false;
    isLoadingMoreHistory.value = false;
    await _insertEvent(
      type: 'resume',
      text: 'Resuming thread ${id.substring(0, 8)}… ${preview ?? ''}',
    );

    try {
      await _rehydrateFromAnyLogForThread(threadId: id, maxLines: 300);
    } catch (_) {}
  }

  @override
  Future<void> reattachIfNeeded({int backfillLines = 200}) async {
    if (target.local) {
      await _refreshLocalRunningStateAndTail(backfillLines: backfillLines);
    } else {
      await _refreshRemoteRunningStateAndTail(backfillLines: backfillLines);
    }
  }

  @override
  Future<void> refresh() async {
    // Clear the visible chat and then attempt to rehydrate + reattach to the
    // active log tail (useful after backgrounding/disconnects or duplication).
    _repairedExplodedChat = false;
    _pendingActionsMessage = null;
    isLoadingMoreHistory.value = false;
    hasMoreHistory.value = false;
    _historyLogRelPath = _logRelPath;
    _historyFocusThreadId = null;
    _historyRemoteStartLine = null;
    _historyLocalStartIndex = null;
    _needsScrollToBottom.value = false;

    if (!target.local) _cancelTailOnly();
    if (target.local) _cancelLocalTailOnly();

    try {
      await chatController.setMessages([], animated: false);
    } catch (_) {}

    try {
      if (target.local) {
        await _rehydrateFromLocalLog(maxLines: 200, logRelPath: _logRelPath);
      } else {
        await _rehydrateFromRemoteLog(maxLines: 200);
      }
    } catch (_) {}

    try {
      await reattachIfNeeded(backfillLines: 0);
    } catch (_) {}
  }

  @override
  Future<void> loadMoreHistory() async {
    if (isLoadingMoreHistory.value) return;
    if (!hasMoreHistory.value) return;

    isLoadingMoreHistory.value = true;
    try {
      final logRelPath = _historyLogRelPath ?? _logRelPath;
      final focusThreadId = _historyFocusThreadId;

      Future<List<Message>> materializeLines(List<String> lines) async {
        final out = <Message>[];
        for (final line in lines) {
          if (line.trim().isEmpty) continue;
          try {
            final decoded = jsonDecode(line);
            if (decoded is Map) {
              final msgs = await _materializeCodexJsonEvent(
                decoded.cast<String, Object?>(),
                replay: true,
              );
              out.addAll(msgs);
            }
          } catch (_) {}
        }
        return out;
      }

      if (target.local) {
        final logPath = _joinPosix(projectPath, logRelPath);
        final file = File(logPath);
        if (!await file.exists()) {
          hasMoreHistory.value = false;
          return;
        }

        final contents = await file.readAsString();
        final lines = const LineSplitter().convert(contents);
        if (lines.isEmpty) {
          hasMoreHistory.value = false;
          return;
        }

        final currentStart = (_historyLocalStartIndex ?? lines.length).clamp(
          0,
          lines.length,
        );
        if (currentStart <= 0) {
          hasMoreHistory.value = false;
          return;
        }

        final newStart = (currentStart - _historyPageSizeLines).clamp(
          0,
          currentStart,
        );
        final chunk = lines.sublist(newStart, currentStart);
        if (chunk.isEmpty) {
          hasMoreHistory.value = newStart > 0;
          _historyLocalStartIndex = newStart;
          return;
        }

        final foundThreadStart = focusThreadId == null
            ? false
            : _containsThreadStart(chunk, focusThreadId);
        final focusStart = focusThreadId == null
            ? 0
            : _findFocusStartIndex(chunk, focusThreadId);
        final relevant = (focusThreadId != null && foundThreadStart)
            ? chunk.skip(focusStart)
            : chunk;
        final relevantList = relevant is List<String>
            ? relevant
            : relevant.toList();

        for (final l in relevantList) {
          if (l.trim().isNotEmpty) _rememberRecentLogLine(l);
        }

        final older = await materializeLines(relevantList);
        if (older.isNotEmpty) {
          await chatController.insertAllMessages(
            older,
            index: 0,
            animated: false,
          );
        }

        if (focusThreadId != null && foundThreadStart) {
          _historyLocalStartIndex = newStart + focusStart;
          hasMoreHistory.value = false;
        } else {
          _historyLocalStartIndex = newStart;
          hasMoreHistory.value = newStart > 0;
        }
        return;
      }

      // Remote
      final profile = target.profile!;
      final pem = await _storage.read(
        key: SecureStorageService.sshPrivateKeyPemKey,
      );
      if (pem == null || pem.trim().isEmpty) {
        hasMoreHistory.value = false;
        return;
      }

      final startLine = _historyRemoteStartLine;
      if (startLine == null || startLine <= 1) {
        hasMoreHistory.value = false;
        return;
      }

      final endLine = startLine - 1;
      final newStartLine = (endLine - _historyPageSizeLines + 1).clamp(
        1,
        endLine,
      );
      final logAbs = _remoteAbsPath(logRelPath);
      final cmdBody = [
        'if [ -f ${_shQuote(logAbs)} ]; then',
        '  sed -n \'$newStartLine,${endLine}p\' ${_shQuote(logAbs)} 2>/dev/null || true',
        'fi',
      ].join('\n');

      Future<SshCommandResult> runOnce({String? password}) {
        return _ssh.runCommandWithResult(
          host: profile.host,
          port: profile.port,
          username: profile.username,
          privateKeyPem: pem,
          password: password,
          command: _wrapWithShell(profile, cmdBody),
        );
      }

      SshCommandResult res;
      try {
        res = await runOnce(password: _sshPassword);
      } catch (_) {
        if (_sshPassword == null) {
          final pw = await _promptForPassword();
          if (pw == null || pw.isEmpty) rethrow;
          _sshPassword = pw;
          res = await runOnce(password: _sshPassword);
        } else {
          rethrow;
        }
      }

      final chunkLines = const LineSplitter().convert(res.stdout);
      if (chunkLines.isEmpty) {
        hasMoreHistory.value = newStartLine > 1;
        _historyRemoteStartLine = newStartLine;
        return;
      }

      final foundThreadStart = focusThreadId == null
          ? false
          : _containsThreadStart(chunkLines, focusThreadId);
      final focusStart = focusThreadId == null
          ? 0
          : _findFocusStartIndex(chunkLines, focusThreadId);
      final relevant = (focusThreadId != null && foundThreadStart)
          ? chunkLines.skip(focusStart)
          : chunkLines;
      final relevantList = relevant is List<String>
          ? relevant
          : relevant.toList();

      for (final l in relevantList) {
        if (l.trim().isNotEmpty) _rememberRecentLogLine(l);
      }

      final older = await materializeLines(relevantList);
      if (older.isNotEmpty) {
        await chatController.insertAllMessages(
          older,
          index: 0,
          animated: false,
        );
      }

      if (focusThreadId != null && foundThreadStart) {
        _historyRemoteStartLine = newStartLine + focusStart;
        hasMoreHistory.value = false;
      } else {
        _historyRemoteStartLine = newStartLine;
        hasMoreHistory.value = newStartLine > 1;
      }
    } finally {
      isLoadingMoreHistory.value = false;
    }
  }

  @override
  void stop() {
    _cancelCurrent?.call();

    if (target.local) {
      final job = remoteJobId.value;
      if (job == null || job.isEmpty) return;
      _stopLocalJob(job).whenComplete(() async {
        await _sessionStore.clearRemoteJobId(
          targetKey: target.targetKey,
          projectPath: projectPath,
          tabId: tabId,
        );
        remoteJobId.value = null;
        _remoteJobId = null;
        isRunning.value = false;
        thinkingPreview.value = null;
        _cancelLocalTailOnly();
      });
    }
  }

  @override
  Future<void> sendText(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    await _consumePendingActions();
    _lastUserPromptPreview = trimmed.length > 80
        ? '${trimmed.substring(0, 80)}…'
        : trimmed;
    inputController.clear();

    final createdAt = DateTime.now().toUtc();
    final userMessage = Message.text(
      id: _uuid.v4(),
      authorId: _me,
      createdAt: createdAt,
      text: trimmed,
    );
    await chatController.insertMessage(userMessage, animated: true);

    await _runCodexTurn(
      prompt: trimmed,
      userMessageId: userMessage.id,
      userMessageCreatedAt: createdAt,
    );
  }

  @override
  Future<void> sendQuickReply(String value) => sendText(value);

  @override
  Future<void> resetSession() async {
    // Stop any in-progress activity and clear session state, leaving the tab in
    // a "fresh" state without deleting the controller.
    stop();
    try {
      await resetThread();
    } catch (_) {}

    try {
      await _sessionStore.clearRemoteJobId(
        targetKey: target.targetKey,
        projectPath: projectPath,
        tabId: tabId,
      );
    } catch (_) {}
    try {
      if (!target.local) {
        await _remoteJobs.remove(
          targetKey: target.targetKey,
          projectPath: projectPath,
          tabId: tabId,
        );
      }
    } catch (_) {}

    _remoteJobId = null;
    remoteJobId.value = null;
    isRunning.value = false;
    thinkingPreview.value = null;
    _cancelCurrent = null;
    _cancelTailOnly();
    _cancelLocalTailOnly();
  }

  @override
  Future<void> clearSessionArtifacts() async {
    // Clear persisted keys first so an app restart won't "reattach" to this tab.
    try {
      await _sessionStore.clearThreadId(
        targetKey: target.targetKey,
        projectPath: projectPath,
        tabId: tabId,
      );
    } catch (_) {}
    try {
      await _sessionStore.clearRemoteJobId(
        targetKey: target.targetKey,
        projectPath: projectPath,
        tabId: tabId,
      );
    } catch (_) {}
    try {
      await _sessionStore.clearRemoteTmuxSessionName(
        targetKey: target.targetKey,
        projectPath: projectPath,
        tabId: tabId,
      );
    } catch (_) {}
    try {
      await _sessionStore.clearLogLineCursor(
        targetKey: target.targetKey,
        projectPath: projectPath,
        tabId: tabId,
      );
    } catch (_) {}
    _logLineCursor = 0;
    try {
      await _sessionStore.clearLogLastLineHash(
        targetKey: target.targetKey,
        projectPath: projectPath,
        tabId: tabId,
      );
    } catch (_) {}
    _logLastLineHash = '';

    hasMoreHistory.value = false;
    isLoadingMoreHistory.value = false;
    _historyLogRelPath = null;
    _historyFocusThreadId = null;
    _historyRemoteStartLine = null;
    _historyLocalStartIndex = null;

    if (target.local) {
      Future<void> rmRel(String rel) async {
        try {
          final p = _joinPosix(projectPath, rel);
          final f = File(p);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }

      await rmRel(_logRelPath);
      await rmRel(_stderrLogRelPath);
      await rmRel(_jobRelPath);
      await rmRel(_pidRelPath);
      return;
    }

    final profile = target.profile;
    if (profile == null) return;
    final pem = await _storage.read(
      key: SecureStorageService.sshPrivateKeyPemKey,
    );
    if (pem == null || pem.trim().isEmpty) return;

    final logAbs = _remoteAbsPath(_logRelPath);
    final stderrAbs = _remoteAbsPath(_stderrLogRelPath);
    final jobAbs = _remoteAbsPath(_jobRelPath);
    final pidAbs = _remoteAbsPath(_pidRelPath);

    final cmdBody = [
      'rm -f ${_shQuote(logAbs)} ${_shQuote(stderrAbs)} ${_shQuote(jobAbs)} ${_shQuote(pidAbs)} 2>/dev/null || true',
    ].join('\n');

    try {
      await _ssh.runCommandWithResult(
        host: profile.host,
        port: profile.port,
        username: profile.username,
        privateKeyPem: pem,
        password: _sshPassword,
        command: _wrapWithShell(profile, cmdBody),
      );
    } catch (_) {
      if (_sshPassword == null) {
        try {
          final pw = await _promptForPassword();
          if (pw == null || pw.isEmpty) return;
          _sshPassword = pw;
          await _ssh.runCommandWithResult(
            host: profile.host,
            port: profile.port,
            username: profile.username,
            privateKeyPem: pem,
            password: _sshPassword,
            command: _wrapWithShell(profile, cmdBody),
          );
        } catch (_) {}
      }
    }
  }

  @override
  Future<void> loadImageAttachment(CustomMessage message, {int? index}) async {
    final meta = message.metadata ?? const {};
    final kind = meta['kind']?.toString();
    if (kind == 'codex_image') {
      final existingBytes = meta['bytes'];
      if (existingBytes is Uint8List && existingBytes.isNotEmpty) return;

      final status = meta['status']?.toString() ?? '';
      if (status == 'loading') return;

      String rawPath = meta['path']?.toString() ?? '';
      if (rawPath.trim().isEmpty) return;

      rawPath = _normalizeWorkspacePath(rawPath);
      if (!_isPathWithinWorkspace(rawPath)) {
        await _updateImageMessage(
          message,
          status: 'error',
          error: 'Image path is outside the workspace.',
        );
        return;
      }

      await _updateImageMessage(message, status: 'loading');

      try {
        final bytes = target.local
            ? await _readLocalImageBytes(rawPath)
            : await _readRemoteImageBytes(rawPath);
        await _updateImageMessage(message, status: 'loaded', bytes: bytes);
      } catch (e) {
        await _updateImageMessage(message, status: 'error', error: '$e');
      }
      return;
    }

    if (kind != 'codex_image_grid') return;

    final rawImages = meta['images'];
    if (rawImages is! List) return;
    final images = rawImages
        .whereType<Map>()
        .map((m) => Map<String, Object?>.from(m))
        .toList();
    if (images.isEmpty) return;

    final indices = <int>[];
    if (index != null) {
      if (index < 0 || index >= images.length) return;
      indices.add(index);
    } else {
      for (var i = 0; i < images.length; i++) {
        indices.add(i);
      }
    }

    for (final i in indices) {
      final entry = images[i];
      final existingBytes = entry['bytes'];
      if (existingBytes is Uint8List && existingBytes.isNotEmpty) continue;

      final status = entry['status']?.toString() ?? '';
      if (status == 'loading') continue;

      String rawPath = entry['path']?.toString() ?? '';
      if (rawPath.trim().isEmpty) continue;

      rawPath = _normalizeWorkspacePath(rawPath);
      if (!_isPathWithinWorkspace(rawPath)) {
        await _updateImageGridMessage(
          message,
          i,
          status: 'error',
          error: 'Image path is outside the workspace.',
        );
        continue;
      }

      await _updateImageGridMessage(message, i, status: 'loading');

      try {
        final bytes = target.local
            ? await _readLocalImageBytes(rawPath)
            : await _readRemoteImageBytes(rawPath);
        await _updateImageGridMessage(
          message,
          i,
          status: 'loaded',
          bytes: bytes,
        );
      } catch (e) {
        await _updateImageGridMessage(message, i, status: 'error', error: '$e');
      }
    }
  }

  String _normalizeWorkspacePath(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return trimmed;
    if (trimmed.startsWith('/')) return trimmed;
    var rel = trimmed;
    if (rel.startsWith('./')) rel = rel.substring(2);
    if (projectPath.endsWith('/')) return '$projectPath$rel';
    return '$projectPath/$rel';
  }

  bool _isPathWithinWorkspace(String absPath) {
    final root = projectPath.endsWith('/') ? projectPath : '$projectPath/';
    return absPath == projectPath || absPath.startsWith(root);
  }

  Future<Uint8List> _readLocalImageBytes(String absPath) async {
    final file = File(absPath);
    if (!await file.exists()) {
      throw StateError('Image not found: $absPath');
    }
    final len = await file.length();
    if (len > _maxImageBytes) {
      throw StateError(
        'Image too large (${(len / (1024 * 1024)).toStringAsFixed(1)} MB).',
      );
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) throw StateError('Image was empty.');
    final out = Uint8List.fromList(bytes);
    if (!_looksLikeImage(out)) {
      throw StateError('File is not a supported image type.');
    }
    return out;
  }

  Future<Uint8List> _readRemoteImageBytes(String absPath) async {
    final profile = target.profile!;
    final pem = await _storage.read(
      key: SecureStorageService.sshPrivateKeyPemKey,
    );

    final root = projectPath;
    final cmdBody = [
      'set -e',
      'p=${_shQuote(absPath)}',
      'root=${_shQuote(root)}',
      'case "\$p" in',
      '  "\$root"|"\$root"/*) ;;',
      '  *) echo "outside workspace" >&2; exit 3 ;;',
      'esac',
      '[ -f "\$p" ] || { echo "missing: \$p" >&2; exit 4; }',
      'sz=\$(stat -f %z "\$p" 2>/dev/null || stat -c %s "\$p" 2>/dev/null || echo 0)',
      'if [ "\$sz" -gt ${_maxImageBytes.toString()} ]; then',
      '  echo "too large: \$sz bytes" >&2; exit 5;',
      'fi',
      'base64 < "\$p"',
    ].join('\n');

    SshCommandResult res;
    try {
      res = await _ssh.runCommandWithResult(
        host: profile.host,
        port: profile.port,
        username: profile.username,
        privateKeyPem: pem,
        password: _sshPassword,
        command: _wrapWithShell(profile, cmdBody),
      );
    } catch (_) {
      if (_sshPassword == null) {
        final pw = await _promptForPassword();
        if (pw == null || pw.isEmpty) rethrow;
        _sshPassword = pw;
        res = await _ssh.runCommandWithResult(
          host: profile.host,
          port: profile.port,
          username: profile.username,
          privateKeyPem: pem,
          password: _sshPassword,
          command: _wrapWithShell(profile, cmdBody),
        );
      } else {
        rethrow;
      }
    }

    final exit = res.exitCode ?? 1;
    if (exit != 0) {
      final err = res.stderr.trim().isEmpty
          ? 'Failed to read image.'
          : res.stderr.trim();
      throw StateError(err);
    }

    final b64 = res.stdout.replaceAll(RegExp(r'\s+'), '');
    if (b64.isEmpty) throw StateError('Remote returned empty image payload.');
    final decoded = base64.decode(b64);
    if (decoded.isEmpty) throw StateError('Decoded image was empty.');
    final out = Uint8List.fromList(decoded);
    if (!_looksLikeImage(out)) {
      throw StateError('File is not a supported image type.');
    }
    return out;
  }

  bool _looksLikeImage(Uint8List bytes) {
    if (bytes.length >= 8) {
      // PNG
      if (bytes[0] == 0x89 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x4E &&
          bytes[3] == 0x47 &&
          bytes[4] == 0x0D &&
          bytes[5] == 0x0A &&
          bytes[6] == 0x1A &&
          bytes[7] == 0x0A) {
        return true;
      }
    }
    if (bytes.length >= 3) {
      // JPEG
      if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
        return true;
      }
    }
    if (bytes.length >= 6) {
      // GIF
      final g0 = bytes[0],
          g1 = bytes[1],
          g2 = bytes[2],
          g3 = bytes[3],
          g4 = bytes[4],
          g5 = bytes[5];
      if (g0 == 0x47 && g1 == 0x49 && g2 == 0x46 && g3 == 0x38) {
        if ((g4 == 0x37 || g4 == 0x39) && g5 == 0x61) return true;
      }
    }
    if (bytes.length >= 12) {
      // WEBP: RIFF....WEBP
      if (bytes[0] == 0x52 &&
          bytes[1] == 0x49 &&
          bytes[2] == 0x46 &&
          bytes[3] == 0x46 &&
          bytes[8] == 0x57 &&
          bytes[9] == 0x45 &&
          bytes[10] == 0x42 &&
          bytes[11] == 0x50) {
        return true;
      }
    }
    if (bytes.length >= 2) {
      // BMP
      if (bytes[0] == 0x42 && bytes[1] == 0x4D) return true;
    }
    if (bytes.length >= 4) {
      // ICO
      if (bytes[0] == 0x00 &&
          bytes[1] == 0x00 &&
          bytes[2] == 0x01 &&
          bytes[3] == 0x00) {
        return true;
      }
    }
    return false;
  }

  Future<void> _updateImageMessage(
    CustomMessage message, {
    required String status,
    Uint8List? bytes,
    String? error,
  }) async {
    try {
      final next = Map<String, Object?>.from(message.metadata ?? const {});
      next['status'] = status;
      if (bytes != null) next['bytes'] = bytes;
      if (error != null && error.trim().isNotEmpty) {
        next['error'] = error.trim();
      } else {
        next.remove('error');
      }
      await chatController.updateMessage(
        message,
        message.copyWith(metadata: next),
      );
    } catch (_) {}
  }

  Future<void> _updateImageGridMessage(
    CustomMessage message,
    int index, {
    required String status,
    Uint8List? bytes,
    String? error,
  }) async {
    try {
      final next = Map<String, Object?>.from(message.metadata ?? const {});
      final rawImages = next['images'];
      if (rawImages is! List) return;
      if (index < 0 || index >= rawImages.length) return;
      final items = rawImages
          .whereType<Map>()
          .map((m) => Map<String, Object?>.from(m))
          .toList(growable: false);
      if (index >= items.length) return;

      final item = Map<String, Object?>.from(items[index]);
      item['status'] = status;
      if (bytes != null) item['bytes'] = bytes;
      if (error != null && error.trim().isNotEmpty) {
        item['error'] = error.trim();
      } else {
        item.remove('error');
      }
      items[index] = item;
      next['images'] = items;

      await chatController.updateMessage(
        message,
        message.copyWith(metadata: next),
      );
    } catch (_) {}
  }

  Future<void> _initAsync() async {
    try {
      await _loadThreadId();
      await _loadRemoteJobId();
      await _loadLogLineCursor();
      await _loadLogLastLineHash();
      if (!target.local) {
        await _maybeReattachRemote();
      } else {
        await _maybeReattachLocal();
      }
    } catch (_) {
      // Best-effort.
    }
  }

  Future<void> _loadLogLineCursor() async {
    try {
      _logLineCursor = await _sessionStore.loadLogLineCursor(
        targetKey: target.targetKey,
        projectPath: projectPath,
        tabId: tabId,
      );
    } catch (_) {
      _logLineCursor = 0;
    }
  }

  Future<void> _loadLogLastLineHash() async {
    try {
      _logLastLineHash =
          (await _sessionStore.loadLogLastLineHash(
            targetKey: target.targetKey,
            projectPath: projectPath,
            tabId: tabId,
          )) ??
          '';
    } catch (_) {
      _logLastLineHash = '';
    }
  }

  void _bumpLogLineCursor() {
    _logLineCursor++;
    if (_cursorSaveTimer != null) return;
    _cursorSaveTimer = Timer(const Duration(milliseconds: 400), () {
      _cursorSaveTimer = null;
      final cursor = _logLineCursor;
      _cursorSaveQueue = _cursorSaveQueue.then((_) async {
        try {
          await _sessionStore.saveLogLineCursor(
            targetKey: target.targetKey,
            projectPath: projectPath,
            tabId: tabId,
            cursor: cursor,
          );
        } catch (_) {}
      });
    });
  }

  static String _fnv1a64Hex(String s) {
    // 64-bit FNV-1a hash, returned as fixed-width hex.
    const int fnvOffset = 0xcbf29ce484222325;
    const int fnvPrime = 0x100000001b3;
    var hash = fnvOffset;
    final bytes = utf8.encode(s);
    for (final b in bytes) {
      hash ^= b;
      hash = (hash * fnvPrime).toUnsigned(64);
    }
    final v = hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
    return v;
  }

  String _remoteProjectTmuxSessionName() {
    // One tmux session per project (remote only), with a stable name so multiple
    // clients can attach to the same project layout.
    final h = _fnv1a64Hex('${target.targetKey}|$projectPath');
    return 'fe_${h.substring(0, 12)}';
  }

  String _remoteTabTmuxWindowName() {
    // One tmux window per tab, stable across restarts.
    final clean = tabId.replaceAll('-', '');
    final short = clean.length >= 10 ? clean.substring(0, 10) : clean;
    return 'cr_$short';
  }

  ({String session, String window})? _parseProjectTmuxJobId(String jobId) {
    if (!jobId.startsWith('tmux:')) return null;
    final rest = jobId.substring('tmux:'.length).trim();
    if (rest.isEmpty) return null;
    final parts = rest.split(':');
    if (parts.length < 2) return null;
    final session = parts[0].trim();
    final window = parts[1].trim();
    if (session.isEmpty || window.isEmpty) return null;
    return (session: session, window: window);
  }

  void _noteLogLineSeen(String line) {
    final h = _fnv1a64Hex(line);
    _logLastLineHash = h;
    if (_hashSaveTimer != null) return;
    _hashSaveTimer = Timer(const Duration(milliseconds: 400), () {
      _hashSaveTimer = null;
      final hash = _logLastLineHash;
      _hashSaveQueue = _hashSaveQueue.then((_) async {
        try {
          await _sessionStore.saveLogLastLineHash(
            targetKey: target.targetKey,
            projectPath: projectPath,
            tabId: tabId,
            hash: hash,
          );
        } catch (_) {}
      });
    });
  }

  void _flushLogLineCursor() {
    try {
      _cursorSaveTimer?.cancel();
    } catch (_) {}
    _cursorSaveTimer = null;
    final cursor = _logLineCursor;
    _cursorSaveQueue = _cursorSaveQueue.then((_) async {
      try {
        await _sessionStore.saveLogLineCursor(
          targetKey: target.targetKey,
          projectPath: projectPath,
          tabId: tabId,
          cursor: cursor,
        );
      } catch (_) {}
    });
  }

  void _flushLogLastLineHash() {
    try {
      _hashSaveTimer?.cancel();
    } catch (_) {}
    _hashSaveTimer = null;
    final hash = _logLastLineHash;
    if (hash.trim().isEmpty) return;
    _hashSaveQueue = _hashSaveQueue.then((_) async {
      try {
        await _sessionStore.saveLogLastLineHash(
          targetKey: target.targetKey,
          projectPath: projectPath,
          tabId: tabId,
          hash: hash,
        );
      } catch (_) {}
    });
  }

  Future<void> _loadThreadId() async {
    final stored = await _sessionStore.loadThreadId(
      targetKey: target.targetKey,
      projectPath: projectPath,
      tabId: tabId,
    );
    threadId.value = stored;
  }

  Future<void> _loadRemoteJobId() async {
    final stored = await _sessionStore.loadRemoteJobId(
      targetKey: target.targetKey,
      projectPath: projectPath,
      tabId: tabId,
    );
    _remoteJobId = stored;
    remoteJobId.value = stored;
  }

  Future<void> _maybeReattachLocal() async {
    // Only relevant for "attaching" to a remote-style job (tmux/pid) that is
    // writing JSONL to this tab's log file (e.g., started from iOS over SSH).
    if (!target.local) return;
    try {
      if (remoteJobId.value == null || remoteJobId.value!.isEmpty) {
        final jobId = await _readLocalJobId();
        if (jobId != null && jobId.isNotEmpty) {
          _remoteJobId = jobId;
          remoteJobId.value = jobId;
          await _sessionStore.saveRemoteJobId(
            targetKey: target.targetKey,
            projectPath: projectPath,
            tabId: tabId,
            remoteJobId: jobId,
          );
        }
      }

      await _rehydrateFromLocalLog(maxLines: 200, logRelPath: _logRelPath);
      // If the job finished while the app was backgrounded/terminated, we may
      // have missed >200 lines; replay any unseen log lines using the cursor.
      try {
        await _catchUpFromLocalLogOnce(backfillLines: 200);
      } catch (_) {}

      final stored = remoteJobId.value;
      if (stored == null || stored.isEmpty) return;

      // Optimistically mark as running right away so we don't accidentally start
      // a new turn and kill the existing local job before we finish checking.
      isRunning.value = true;
      _cancelCurrent = () {
        _stopLocalJob(stored).whenComplete(() {
          _cancelLocalTailOnly();
          _cancelCurrent = null;
          isRunning.value = false;
          thinkingPreview.value = null;
        });
      };

      final alive = await _isLocalJobAlive(stored);
      if (alive) {
        await _startLocalLogTailIfNeeded(backfillLines: 200);
      } else {
        try {
          await _sessionStore.clearRemoteJobId(
            targetKey: target.targetKey,
            projectPath: projectPath,
            tabId: tabId,
          );
        } catch (_) {}
        try {
          final file = File(_joinPosix(projectPath, _jobRelPath));
          if (await file.exists()) await file.writeAsString('', flush: true);
        } catch (_) {}
        _remoteJobId = null;
        remoteJobId.value = null;
        _cancelCurrent = null;
        isRunning.value = false;
        thinkingPreview.value = null;
      }
    } catch (_) {
      // Best-effort.
    }
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
    final pem = await _storage.read(
      key: SecureStorageService.sshPrivateKeyPemKey,
    );

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

  Future<void> _ensureFieldExecDirsLocal() async {
    await _ensureFieldExecIgnoredInGitignoreLocal();
    await _ensureFieldExecExcludedLocal();
    final dir = Directory(_joinPosix(projectPath, _fieldExecDir));
    await dir.create(recursive: true);
    await Directory(
      _joinPosix(projectPath, _sessionsDirRelPath),
    ).create(recursive: true);
    await Directory(
      _joinPosix(projectPath, _tmpDirRelPath),
    ).create(recursive: true);
    await File(_joinPosix(projectPath, _logRelPath)).create(recursive: true);
    await File(
      _joinPosix(projectPath, _stderrLogRelPath),
    ).create(recursive: true);
    await File(_joinPosix(projectPath, _jobRelPath)).create(recursive: true);
    await File(_joinPosix(projectPath, _pidRelPath)).create(recursive: true);
    await File(
      _joinPosix(projectPath, _devInstructionsRelPath),
    ).create(recursive: true);
  }

  Future<void> _ensureFieldExecDirsRemote() async {
    final profile = target.profile!;
    final pem = await _storage.read(
      key: SecureStorageService.sshPrivateKeyPemKey,
    );

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
    final jobAbs = _remoteAbsPath(_jobRelPath);
    final pidAbs = _remoteAbsPath(_pidRelPath);
    final devAbs = _remoteAbsPath(_devInstructionsRelPath);

    final ignoreLine = _shQuote('**/.field_exec/');
    final cd = _shQuote(projectPath);
    final cmd = [
      'cd $cd || exit 0',
      // Ensure .field_exec is ignored early to keep the repo clean for any
      // server-side bootstrap commits (and to discourage agents from deleting it).
      'if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then',
      r'  exclude_path="$(git rev-parse --git-path info/exclude 2>/dev/null || true)"',
      r'  if [ -n "$exclude_path" ]; then',
      r'    exclude_dir="$(dirname "$exclude_path")"',
      r'    mkdir -p "$exclude_dir" >/dev/null 2>&1 || true',
      r'    touch "$exclude_path" >/dev/null 2>&1 || true',
      '    grep -qxF $ignoreLine "\$exclude_path" 2>/dev/null || printf %s\\\\n $ignoreLine >> "\$exclude_path" || true',
      '  fi',
      'fi',
      'mkdir -p ${_shQuote(sessionsAbs)} ${_shQuote(tmpAbs)} && touch ${_shQuote(logAbs)} ${_shQuote(errAbs)} ${_shQuote(jobAbs)} ${_shQuote(pidAbs)} ${_shQuote(devAbs)}',
    ].join('\n');
    await run(_wrapWithShell(profile, cmd));
  }

  void _cancelTailOnly() {
    _tailToken = null;
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

  void _cancelLocalTailOnly() {
    _localTailToken = null;
    try {
      _localTailStdoutSub?.cancel();
    } catch (_) {}
    try {
      _localTailStderrSub?.cancel();
    } catch (_) {}
    try {
      _localTailProc?.cancel();
    } catch (_) {}
    _localTailProc = null;
    _localTailStdoutSub = null;
    _localTailStderrSub = null;
  }

  Future<String?> _readLocalJobId() async {
    try {
      final file = File(_joinPosix(projectPath, _jobRelPath));
      if (!await file.exists()) return null;
      final text = (await file.readAsString()).trim();
      return text.isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  Future<void> _startLocalLogTailIfNeeded({
    int? startAtLine,
    int backfillLines = 200,
  }) async {
    if (_localTailProc != null) return;
    final logPath = _joinPosix(projectPath, _logRelPath);
    final file = File(logPath);
    if (!await file.exists()) {
      await file.parent.create(recursive: true);
      await file.create(recursive: true);
    }

    // We handle resume/catch-up separately; start tails from end to avoid
    // re-streaming old logs (which can cause duplicates and scroll jumps).
    final start = startAtLine ?? 0;

    final proc = _localShell.startCommand(
      executable: 'tail',
      arguments: start > 0
          ? ['-n', '+$start', '-F', logPath]
          : ['-n', '0', '-F', logPath],
      workingDirectory: projectPath,
    );
    final token = Object();
    _localTailToken = token;
    _localTailProc = proc;

    _localTailStdoutSub = proc.stdoutLines.listen((line) {
      if (line.trim().isEmpty) return;
      _noteLogLineSeen(line);
      _bumpLogLineCursor();
      if (!_shouldProcessLogLine(line)) return;
      _tailQueue = _tailQueue.then((_) async {
        try {
          final decoded = jsonDecode(line);
          if (decoded is Map) {
            await _handleCodexJsonEvent(decoded.cast<String, Object?>());
          }
        } catch (_) {}
      });
    });

    _localTailStderrSub = proc.stderrLines.listen((line) {
      if (line.trim().isEmpty) return;
      _insertEvent(type: 'tail_stderr', text: line);
    });

    proc.done.then((_) {
      if (_localTailToken != token) return;
      _cancelLocalTailOnly();
    });
  }

  Future<void> _catchUpFromLocalLogOnce({required int backfillLines}) async {
    if (!target.local) return;
    if (_localTailProc != null) return;

    final logPath = _joinPosix(projectPath, _logRelPath);
    final file = File(logPath);
    if (!await file.exists()) return;

    // Bounded catch-up: read a window from the end, then only apply lines
    // after the last seen hash (prevents replaying the entire log repeatedly).
    const window = 8000;
    final res = await Process.run('/bin/sh', [
      '-c',
      'tail -n $window ${_shQuote(logPath)} 2>/dev/null || true',
    ]);
    final stdout = (res.stdout as Object?)?.toString() ?? '';
    final lines = const LineSplitter().convert(stdout);
    if (lines.isEmpty) return;

    var startIndex = 0;
    final last = _logLastLineHash.trim();
    if (last.isNotEmpty) {
      for (var i = lines.length - 1; i >= 0; i--) {
        if (_fnv1a64Hex(lines[i]) == last) {
          startIndex = i + 1;
          break;
        }
      }
    } else {
      startIndex = (lines.length - backfillLines).clamp(0, lines.length);
    }

    for (final line in lines.skip(startIndex)) {
      if (line.trim().isEmpty) continue;
      _noteLogLineSeen(line);
      if (!_shouldProcessLogLine(line)) continue;
      _tailQueue = _tailQueue.then((_) async {
        try {
          final decoded = jsonDecode(line);
          if (decoded is Map) {
            await _handleCodexJsonEvent(decoded.cast<String, Object?>());
          }
        } catch (_) {}
      });
    }
  }

  void _rememberRecentLogLine(String line) {
    // Keep an LRU-ish window of hashes to suppress duplicates when reattaching
    // the tail after sleep/background. Hashes avoid holding large strings.
    final h = _fnv1a64Hex(line);
    if (_recentLogLineHashSet.contains(h)) return;
    _recentLogLineHashes.add(h);
    _recentLogLineHashSet.add(h);
    const max = 20000;
    if (_recentLogLineHashes.length > max) {
      final removed = _recentLogLineHashes.removeAt(0);
      _recentLogLineHashSet.remove(removed);
    }
  }

  bool _shouldProcessLogLine(String line) {
    final h = _fnv1a64Hex(line);
    if (_recentLogLineHashSet.contains(h)) return false;
    _rememberRecentLogLine(line);
    return true;
  }

  void _onAppBackgrounded() {
    _flushLogLineCursor();
    _flushLogLastLineHash();
    // Avoid holding a long-lived SSH connection open while backgrounded.
    // The remote job continues in tmux/nohup; we can reattach on resume.
    if (!target.local) _cancelTailOnly();
    if (target.local) _cancelLocalTailOnly();
  }

  Future<void> _onAppResumed() async {
    final active = _activeSession.active;
    final isActiveView =
        active != null &&
        active.targetKey == target.targetKey &&
        active.projectPath == projectPath &&
        active.tabId == tabId;
    if (!isActiveView) return;

    if (target.local) {
      if (_localTailProc != null) return;
    } else {
      if (_tailProc != null) return;
    }
    // Always attempt a log catch-up on resume, even if the job finished while
    // backgrounded (remote job id may be stale until we replay the log).
    await reattachIfNeeded(backfillLines: 200);
  }

  Future<void> _runCodexTurn({
    required String prompt,
    required String userMessageId,
    required DateTime userMessageCreatedAt,
  }) async {
    if (isRunning.value) return;

    if (target.local) {
      await _runLocalViaTmux(
        prompt: prompt,
        userMessageId: userMessageId,
        userMessageCreatedAt: userMessageCreatedAt,
      );
      return;
    }

    await _runRemoteViaTmux(
      prompt: prompt,
      userMessageId: userMessageId,
      userMessageCreatedAt: userMessageCreatedAt,
    );
  }

  String _clientUserMessageJsonlLine({
    required String messageId,
    required String text,
    required int createdAtMsUtc,
  }) {
    final payload = <String, Object?>{
      'type': _clientUserMessageType,
      'message_id': messageId,
      'text': text,
      'created_at_ms_utc': createdAtMsUtc,
    };
    final currentThread = threadId.value;
    if (currentThread != null && currentThread.isNotEmpty) {
      payload['thread_id'] = currentThread;
    }
    return jsonEncode(payload);
  }

  String _clientGitCommitJsonlLine({
    required String status,
    required String commitMessage,
    String? reason,
    String? stdout,
    String? stderr,
    String? sourceItemId,
  }) {
    final payload = <String, Object?>{
      'type': _clientGitCommitType,
      'status': status,
      'commit_message': commitMessage,
      'created_at_ms_utc': DateTime.now().toUtc().millisecondsSinceEpoch,
      'target': target.local ? 'local' : 'remote',
    };
    final currentThread = threadId.value;
    if (currentThread != null && currentThread.isNotEmpty) {
      payload['thread_id'] = currentThread;
    }
    if (sourceItemId != null && sourceItemId.isNotEmpty) {
      payload['source_item_id'] = sourceItemId;
    }
    if (reason != null && reason.isNotEmpty) {
      payload['reason'] = reason;
    }
    if (stdout != null && stdout.isNotEmpty) {
      payload['stdout'] = stdout;
    }
    if (stderr != null && stderr.isNotEmpty) {
      payload['stderr'] = stderr;
    }
    return jsonEncode(payload);
  }

  Future<void> _appendRemoteUserMessageToLog({
    required String prompt,
    required String logAbsPath,
    required String userMessageId,
    required DateTime userMessageCreatedAt,
  }) async {
    final profile = target.profile!;
    final pem = await _storage.read(
      key: SecureStorageService.sshPrivateKeyPemKey,
    );

    final line = _clientUserMessageJsonlLine(
      messageId: userMessageId,
      text: prompt,
      createdAtMsUtc: userMessageCreatedAt.millisecondsSinceEpoch,
    );
    final cmd = 'printf %s\\\\n ${_shQuote(line)} >> ${_shQuote(logAbsPath)}';
    await _ssh.runCommandWithResult(
      host: profile.host,
      port: profile.port,
      username: profile.username,
      privateKeyPem: pem,
      password: _sshPassword,
      command: _wrapWithShell(profile, cmd),
    );
  }

  Future<void> _appendClientJsonlToLog({required String jsonlLine}) async {
    if (target.local) {
      await _ensureFieldExecDirsLocal();
      final file = File(_joinPosix(projectPath, _logRelPath));
      await file.writeAsString('$jsonlLine\n', mode: FileMode.append);
      return;
    }

    final profile = target.profile!;
    final pem = await _storage.read(
      key: SecureStorageService.sshPrivateKeyPemKey,
    );
    final logAbsPath = _remoteAbsPath(_logRelPath);
    final cmd =
        'printf %s\\\\n ${_shQuote(jsonlLine)} >> ${_shQuote(logAbsPath)}';
    try {
      await _ssh.runCommandWithResult(
        host: profile.host,
        port: profile.port,
        username: profile.username,
        privateKeyPem: pem,
        password: _sshPassword,
        command: _wrapWithShell(profile, cmd),
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
          command: _wrapWithShell(profile, cmd),
        );
        return;
      }
      rethrow;
    }
  }

  Future<void> _runLocalViaTmux({
    required String prompt,
    required String userMessageId,
    required DateTime userMessageCreatedAt,
  }) async {
    if (isRunning.value) return;
    isRunning.value = true;
    thinkingPreview.value = null;
    _cancelCurrent = () {
      final job = _remoteJobId ?? remoteJobId.value;
      if (job != null && job.isNotEmpty) {
        _stopLocalJob(job).whenComplete(() async {
          _cancelLocalTailOnly();
          _cancelCurrent = null;
          isRunning.value = false;
          thinkingPreview.value = null;
          _remoteJobId = null;
          remoteJobId.value = null;
          try {
            await _sessionStore.clearRemoteJobId(
              targetKey: target.targetKey,
              projectPath: projectPath,
              tabId: tabId,
            );
          } catch (_) {}
        });
        return;
      }
      _cancelLocalTailOnly();
      isRunning.value = false;
      thinkingPreview.value = null;
      _cancelCurrent = null;
    };

    try {
      await _ensureFieldExecDirsLocal();
      await _ensureSchema(schemaContents: CodexOutputSchema.encode());

      final logAbs = _joinPosix(projectPath, _logRelPath);
      final errAbs = _joinPosix(projectPath, _stderrLogRelPath);
      final pidAbs = _joinPosix(projectPath, _pidRelPath);
      final jobAbs = _joinPosix(projectPath, _jobRelPath);

      await _appendClientJsonlToLog(
        jsonlLine: _clientUserMessageJsonlLine(
          messageId: userMessageId,
          text: prompt,
          createdAtMsUtc: userMessageCreatedAt.millisecondsSinceEpoch,
        ),
      );

      final cmd = CodexCommandBuilder.build(
        prompt: prompt,
        schemaPath: _schemaRelPath,
        resumeThreadId: threadId.value,
        jsonl: true,
        cd: null,
        configOverrides: const {},
      );

      await _insertEvent(
        type: 'command_execution',
        text:
            'Starting local job: codex ${CodexCommandBuilder.shellString(cmd.args)}',
      );

      await _startLocalLogTailIfNeeded(backfillLines: 0);

      final tmuxName =
          'cl_${tabId.replaceAll('-', '').substring(0, 8)}_${DateTime.now().millisecondsSinceEpoch}';

      final codexArgsTail = CodexCommandBuilder.shellString(
        cmd.args.sublist(1),
      );
      final baseDevB64 = base64.encode(
        utf8.encode(CodexCommandBuilder.defaultDeveloperInstructions),
      );

      final runBody = [
        'set -e',
        'PATH="/opt/homebrew/bin:/usr/local/bin:\$HOME/.local/bin:\$PATH"; export PATH',
        'PROJECT=${_shQuote(projectPath)}',
        'cd "\$PROJECT" 2>/dev/null || { echo "Failed to cd into \$PROJECT" >&2; exit 2; }',
        'LOG=${_shQuote(logAbs)}',
        'ERR=${_shQuote(errAbs)}',
        'exec >> "\$LOG" 2>> "\$ERR"',
        'mkdir -p ${_shQuote(_fieldExecDir)} >/dev/null 2>&1 || true',
        'touch ${_shQuote(_devInstructionsRelPath)} >/dev/null 2>&1 || true',
        'CODEX_BIN="\$(command -v codex 2>/dev/null || true)"',
        'if [ -z "\$CODEX_BIN" ]; then echo "codex not found" >&2; exit 127; fi',
        'JQ_BIN="\$(command -v jq 2>/dev/null || true)"',
        'PLUTIL_BIN="\$(command -v plutil 2>/dev/null || true)"',
        'line="\$(tail -n 1 "\$LOG" 2>/dev/null || true)"',
        'prompt=""',
        'if [ -n "\$line" ] && [ -n "\$JQ_BIN" ]; then',
        '  prompt="\$(printf %s\\\\n "\$line" | "\$JQ_BIN" -r \'select(.type=="client.user_message") | (.text // empty)\' 2>/dev/null || true)"',
        'fi',
        'if [ -z "\$prompt" ] && [ -n "\$line" ] && [ -n "\$PLUTIL_BIN" ]; then',
        '  t="\$(printf %s\\\\n "\$line" | "\$PLUTIL_BIN" -extract type raw -o - - 2>/dev/null || true)"',
        '  if [ "\$t" = "client.user_message" ]; then',
        '    prompt="\$(printf %s\\\\n "\$line" | "\$PLUTIL_BIN" -extract text raw -o - - 2>/dev/null || true)"',
        '  fi',
        'fi',
        'if [ -z "\$prompt" ]; then',
        '  echo "Failed to extract prompt from last JSONL log line (install jq or ensure plutil is available)." >&2',
        '  exit 2',
        'fi',
        '',
        '# Project-scoped developer instructions.',
        'BASE_DEV_B64=${_shQuote(baseDevB64)}',
        r'BASE_DEV="$(printf %s "$BASE_DEV_B64" | base64 -D 2>/dev/null || printf %s "$BASE_DEV_B64" | base64 -d 2>/dev/null || true)"',
        r'USER_DEV="$(cat ".field_exec/developer_instructions.txt" 2>/dev/null || true)"',
        "APOS=\"'\"",
        r'DELIM="${APOS}${APOS}${APOS}"',
        r'REPL="${APOS}${APOS}’"',
        r'BASE_DEV="$(printf %s "$BASE_DEV" | tr -d "\r" | sed "s/${DELIM}/${REPL}/g")"',
        r'USER_DEV="$(printf %s "$USER_DEV" | tr -d "\r" | sed "s/${DELIM}/${REPL}/g")"',
        r'DEV_COMBINED="$(printf "%s\n\n# Project developer instructions (.field_exec/developer_instructions.txt)\n%s\n" "$BASE_DEV" "$USER_DEV")"',
        r'DEV_TOML="$(printf "%s\n%s\n%s\n" "$DELIM" "$DEV_COMBINED" "$DELIM")"',
        '',
        'printf %s\\\\n "\$prompt" | "\$CODEX_BIN" exec -c "developer_instructions=\$DEV_TOML" $codexArgsTail',
        // If the last JSONL event is missing a trailing newline, tail/line-splitting
        // can get stuck "waiting" forever. Force a final newline so the client
        // receives the last line promptly.
        'printf "\\\\n" >> "\$LOG" 2>/dev/null || true',
        '',
        'commit_message=""',
        'if [ -n "\$JQ_BIN" ]; then',
        '  commit_message="\$(tail -n 2000 "\$LOG" 2>/dev/null | "\$JQ_BIN" -r \'select(.type=="item.completed" and .item.type=="agent_message") | (.item.text | fromjson | (.commit_message // ""))\' 2>/dev/null | tail -n 1 | tr -d \'\\r\')"',
        'fi',
        'if [ -z "\$commit_message" ]; then',
        '  commit_message="\$(tail -n 2000 "\$LOG" 2>/dev/null | sed -n \'s/.*"commit_message"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p\' | tail -n 1)"',
        'fi',
        'commit_message="\$(printf %s "\$commit_message" | tr \'\\n\\t\' \'  \' | tr -s \' \' | sed \'s/^ //; s/ \$//\')"',
        'if [ -z "\$commit_message" ]; then',
        '  printf %s\\\\n \'{"type":"$_serverGitCommitType","status":"skipped","reason":"empty_commit_message"}\'',
        '  exit 0',
        'fi',
        'commit_message_b64="\$(printf %s "\$commit_message" | base64 | tr -d \'\\n\')"',
        'printf %s\\\\n \'{"type":"$_serverGitCommitType","status":"started","commit_message_b64":"\'"\$commit_message_b64"\'"}\'',
        'if ! command -v git >/dev/null 2>&1; then',
        '  printf %s\\\\n \'{"type":"$_serverGitCommitType","status":"failed","reason":"git_not_found","commit_message_b64":"\'"\$commit_message_b64"\'"}\'',
        '  exit 0',
        'fi',
        'if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then',
        '  printf %s\\\\n \'{"type":"$_serverGitCommitType","status":"failed","reason":"not_a_git_repo","commit_message_b64":"\'"\$commit_message_b64"\'"}\'',
        '  exit 0',
        'fi',
        'git add -A >/dev/null 2>&1 || true',
        'if [ -z "\$(git status --porcelain 2>/dev/null || true)" ]; then',
        '  printf %s\\\\n \'{"type":"$_serverGitCommitType","status":"skipped","reason":"no_changes","commit_message_b64":"\'"\$commit_message_b64"\'"}\'',
        '  exit 0',
        'fi',
        'if git commit -m "\$commit_message" >/dev/null 2>&1; then',
        '  printf %s\\\\n \'{"type":"$_serverGitCommitType","status":"completed","commit_message_b64":"\'"\$commit_message_b64"\'"}\'',
        'else',
        '  printf %s\\\\n \'{"type":"$_serverGitCommitType","status":"failed","reason":"git_commit_failed","commit_message_b64":"\'"\$commit_message_b64"\'"}\'',
        'fi',
      ].join('\n');

      final startBody = [
        'PATH="/opt/homebrew/bin:/usr/local/bin:\$HOME/.local/bin:\$PATH"; export PATH',
        'set -e',
        'TMUX_BIN="\$(command -v tmux 2>/dev/null || true)"',
        'rm -f ${_shQuote(jobAbs)} >/dev/null 2>&1 || true',
        'if [ -n "\$TMUX_BIN" ]; then',
        '  "\$TMUX_BIN" new-session -d -s ${_shQuote(tmuxName)} sh -c ${_shQuote(runBody)}',
        '  echo "tmux:$tmuxName" > ${_shQuote(jobAbs)}',
        '  printf %s\\\\n "FIELD_EXEC_JOB=tmux:$tmuxName"',
        'else',
        '  nohup sh -c ${_shQuote(runBody)} >/dev/null 2>&1 &',
        '  pid=\$!',
        '  echo "\$pid" > ${_shQuote(pidAbs)}',
        '  echo "pid:\$pid" > ${_shQuote(jobAbs)}',
        '  printf %s\\\\n "FIELD_EXEC_JOB=pid:\$pid"',
        'fi',
      ].join('\n');

      final launchProc = _localShell.startCommand(
        executable: '/bin/sh',
        arguments: ['-c', startBody],
        workingDirectory: projectPath,
      );

      final stdout = <String>[];
      final stderr = <String>[];
      final stdoutSub = launchProc.stdoutLines.listen(stdout.add);
      final stderrSub = launchProc.stderrLines.listen(stderr.add);

      int? exit;
      Object? exitError;
      try {
        exit = await launchProc.exitCode.timeout(const Duration(seconds: 10));
      } on TimeoutException catch (e) {
        exitError = e;
      } finally {
        await stdoutSub.cancel();
        await stderrSub.cancel();
      }

      String? jobLine;
      for (final line in [...stdout, ...stderr].reversed) {
        if (line.startsWith('FIELD_EXEC_JOB=')) {
          jobLine = line;
          break;
        }
      }
      var jobId = jobLine?.substring('FIELD_EXEC_JOB='.length).trim();
      if (jobId == null || jobId.isEmpty) {
        try {
          jobId = (await File(jobAbs).readAsString()).trim();
        } catch (_) {}
      }

      if (jobId == null || jobId.isEmpty) {
        if ((exit ?? 1) != 0) {
          throw StateError(
            'Local launch failed (exit=$exit): ${(stderr.join('\n')).trim().isEmpty ? (stdout.join('\n')).trim() : (stderr.join('\n')).trim()}',
          );
        }
        if (exitError != null) {
          throw StateError(
            'Local launch failed (timeout): ${(stderr.join('\n')).trim().isEmpty ? (stdout.join('\n')).trim() : (stderr.join('\n')).trim()}',
          );
        }
        throw StateError('Local launch did not return a job id.');
      }

      _remoteJobId = jobId;
      remoteJobId.value = jobId;
      await _sessionStore.saveRemoteJobId(
        targetKey: target.targetKey,
        projectPath: projectPath,
        tabId: tabId,
        remoteJobId: jobId,
      );
    } catch (e) {
      await _insertEvent(type: 'error', text: 'Local start failed: $e');
      _cancelCurrent = null;
      isRunning.value = false;
      thinkingPreview.value = null;
      _remoteJobId = null;
      remoteJobId.value = null;
      try {
        await _sessionStore.clearRemoteJobId(
          targetKey: target.targetKey,
          projectPath: projectPath,
          tabId: tabId,
        );
      } catch (_) {}
    }
  }

  Future<void> _runRemoteViaTmux({
    required String prompt,
    required String userMessageId,
    required DateTime userMessageCreatedAt,
  }) async {
    if (isRunning.value) return;
    isRunning.value = true;
    thinkingPreview.value = null;
    _cancelCurrent = () {
      final launch = _remoteLaunchProc;
      if (launch != null) {
        launch.cancel();
        _remoteLaunchProc = null;
        _cancelTailOnly();
        isRunning.value = false;
        thinkingPreview.value = null;
        _cancelCurrent = null;
        return;
      }
      _stopRemoteJob().whenComplete(() {
        _cancelTailOnly();
        _cancelCurrent = null;
        isRunning.value = false;
        thinkingPreview.value = null;
      });
    };

    final profile = target.profile!;

    final pem =
        (await _storage.read(
          key: SecureStorageService.sshPrivateKeyPemKey,
        ))?.trim() ??
        '';
    if (pem.isEmpty) {
      await _insertEvent(
        type: 'error',
        text: 'SSH key required. Set up a key in Settings → SSH Keys.',
      );
      _cancelCurrent = null;
      isRunning.value = false;
      thinkingPreview.value = null;
      remoteJobId.value = null;
      _remoteJobId = null;
      return;
    }

    try {
      await _stopRemoteJobBestEffort();
      await _ensureFieldExecDirsRemote();
      await _ensureSchema(schemaContents: CodexOutputSchema.encode());

      final schemaAbs = _remoteAbsPath(_schemaRelPath);
      final cmd = CodexCommandBuilder.build(
        prompt: prompt,
        schemaPath: schemaAbs,
        resumeThreadId: threadId.value,
        jsonl: true,
        cd: projectPath,
        configOverrides: const {},
      );

      await _insertEvent(
        type: 'command_execution',
        text:
            'Starting remote job: codex ${CodexCommandBuilder.shellString(cmd.args)}',
      );

      await _startRemoteLogTailIfNeeded(backfillLines: 0);

      final tmuxSession = _remoteProjectTmuxSessionName();
      final tmuxWindow = _remoteTabTmuxWindowName();
      const tmuxServerName = 'field_exec';

      final logAbs = _remoteAbsPath(_logRelPath);
      final errAbs = _remoteAbsPath(_stderrLogRelPath);
      final pidAbs = _remoteAbsPath(_pidRelPath);
      final jobAbs = _remoteAbsPath(_jobRelPath);

      // Persist the user prompt into the JSONL log so rehydration can show it and
      // so the remote job can read it back as stdin without creating temp files.
      await _appendRemoteUserMessageToLog(
        prompt: prompt,
        logAbsPath: logAbs,
        userMessageId: userMessageId,
        userMessageCreatedAt: userMessageCreatedAt,
      );

      final codexArgsTail = CodexCommandBuilder.shellString(
        cmd.args.sublist(1),
      );
      final baseDevB64 = base64.encode(
        utf8.encode(CodexCommandBuilder.defaultDeveloperInstructions),
      );
      final runBody = [
        'set -e',
        'PATH="/opt/homebrew/bin:/usr/local/bin:\$HOME/.local/bin:\$PATH"; export PATH',
        'PROJECT=${_shQuote(projectPath)}',
        'cd "\$PROJECT" 2>/dev/null || { echo "Failed to cd into \$PROJECT" >&2; exit 2; }',
        'LOG=${_shQuote(logAbs)}',
        'ERR=${_shQuote(errAbs)}',
        'exec >> "\$LOG" 2>> "\$ERR"',
        'mkdir -p ${_shQuote(_fieldExecDir)} >/dev/null 2>&1 || true',
        'touch ${_shQuote(_devInstructionsRelPath)} >/dev/null 2>&1 || true',
        'CODEX_BIN="\$(command -v codex 2>/dev/null || true)"',
        'if [ -z "\$CODEX_BIN" ]; then',
        '  for p in /opt/homebrew/bin/codex /usr/local/bin/codex "\$HOME/.local/bin/codex" /usr/bin/codex; do',
        '    if [ -x "\$p" ]; then CODEX_BIN="\$p"; break; fi',
        '  done',
        'fi',
        'if [ -z "\$CODEX_BIN" ]; then echo "codex not found" >&2; exit 127; fi',
        'JQ_BIN="\$(command -v jq 2>/dev/null || true)"',
        'if [ -z "\$JQ_BIN" ]; then',
        '  for p in /opt/homebrew/bin/jq /usr/local/bin/jq "\$HOME/.local/bin/jq" /usr/bin/jq; do',
        '    if [ -x "\$p" ]; then JQ_BIN="\$p"; break; fi',
        '  done',
        'fi',
        'PLUTIL_BIN="\$(command -v plutil 2>/dev/null || true)"',
        'if [ -z "\$PLUTIL_BIN" ]; then',
        '  for p in /usr/bin/plutil; do',
        '    if [ -x "\$p" ]; then PLUTIL_BIN="\$p"; break; fi',
        '  done',
        'fi',
        'line="\$(tail -n 1 "\$LOG" 2>/dev/null || true)"',
        'prompt=""',
        'if [ -n "\$line" ] && [ -n "\$JQ_BIN" ]; then',
        '  prompt="\$(printf %s\\\\n "\$line" | "\$JQ_BIN" -r \'select(.type=="client.user_message") | (.text // empty)\' 2>/dev/null || true)"',
        'fi',
        'if [ -z "\$prompt" ] && [ -n "\$line" ] && [ -n "\$PLUTIL_BIN" ]; then',
        '  t="\$(printf %s\\\\n "\$line" | "\$PLUTIL_BIN" -extract type raw -o - - 2>/dev/null || true)"',
        '  if [ "\$t" = "client.user_message" ]; then',
        '    prompt="\$(printf %s\\\\n "\$line" | "\$PLUTIL_BIN" -extract text raw -o - - 2>/dev/null || true)"',
        '  fi',
        'fi',
        'if [ -z "\$prompt" ]; then',
        '  echo "Failed to extract prompt from last JSONL log line (install jq or ensure plutil is available)." >&2',
        '  exit 2',
        'fi',
        '',
        '# Project-scoped developer instructions.',
        'BASE_DEV_B64=${_shQuote(baseDevB64)}',
        r'BASE_DEV="$(printf %s "$BASE_DEV_B64" | base64 -D 2>/dev/null || printf %s "$BASE_DEV_B64" | base64 -d 2>/dev/null || true)"',
        r'USER_DEV="$(cat ".field_exec/developer_instructions.txt" 2>/dev/null || true)"',
        "APOS=\"'\"",
        r'DELIM="${APOS}${APOS}${APOS}"',
        r'REPL="${APOS}${APOS}’"',
        r'BASE_DEV="$(printf %s "$BASE_DEV" | tr -d "\r" | sed "s/${DELIM}/${REPL}/g")"',
        r'USER_DEV="$(printf %s "$USER_DEV" | tr -d "\r" | sed "s/${DELIM}/${REPL}/g")"',
        r'DEV_COMBINED="$(printf "%s\n\n# Project developer instructions (.field_exec/developer_instructions.txt)\n%s\n" "$BASE_DEV" "$USER_DEV")"',
        r'DEV_TOML="$(printf "%s\n%s\n%s\n" "$DELIM" "$DEV_COMBINED" "$DELIM")"',
        '',
        '# Bootstrap .gitignore for .field_exec to keep agent logs safe.',
        'if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then',
        '  before_status="\$(git status --porcelain 2>/dev/null || true)"',
        '  changed=0',
        '  if [ ! -f .gitignore ]; then : > .gitignore; changed=1; fi',
        '  if ! grep -qxF ${_shQuote('**/.field_exec/')} .gitignore 2>/dev/null; then',
        '    printf %s\\\\n ${_shQuote('**/.field_exec/')} >> .gitignore',
        '    changed=1',
        '  fi',
        '  if [ "\$changed" -eq 1 ]; then',
        '    if [ -z "\$before_status" ]; then',
        '      if git add .gitignore >/dev/null 2>&1 && git commit -m ${_shQuote('chore: ignore .field_exec')} >/dev/null 2>&1; then',
        '        printf %s\\\\n \'{"type":"$_serverGitignoreBootstrapType","status":"committed"}\'',
        '      else',
        '        printf %s\\\\n \'{"type":"$_serverGitignoreBootstrapType","status":"updated"}\'',
        '      fi',
        '    else',
        '      printf %s\\\\n \'{"type":"$_serverGitignoreBootstrapType","status":"updated"}\'',
        '    fi',
        '  fi',
        'fi',
        'printf %s\\\\n "\$prompt" | "\$CODEX_BIN" exec -c "developer_instructions=\$DEV_TOML" $codexArgsTail',
        // If the last JSONL event is missing a trailing newline, tail/line-splitting
        // can get stuck "waiting" forever. Force a final newline so the client
        // receives the last line promptly.
        'printf "\\\\n"',
        '',
        '# Server-side auto-commit (avoids multi-client races).',
        'commit_message=""',
        'if [ -n "\$JQ_BIN" ]; then',
        '  commit_message="\$(tail -n 2000 "\$LOG" 2>/dev/null | "\$JQ_BIN" -r \'select(.type=="item.completed" and .item.type=="agent_message") | (.item.text | fromjson | (.commit_message // ""))\' 2>/dev/null | tail -n 1 | tr -d \'\\r\')"',
        'fi',
        'if [ -z "\$commit_message" ]; then',
        '  commit_message="\$(tail -n 2000 "\$LOG" 2>/dev/null | sed -n \'s/.*"commit_message"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p\' | tail -n 1)"',
        'fi',
        'commit_message="\$(printf %s "\$commit_message" | tr \'\\n\\t\' \'  \' | tr -s \' \' | sed \'s/^ //; s/ \$//\')"',
        'if [ -z "\$commit_message" ]; then',
        '  printf %s\\\\n \'{"type":"$_serverGitCommitType","status":"skipped","reason":"empty_commit_message"}\'',
        '  exit 0',
        'fi',
        'commit_message_b64="\$(printf %s "\$commit_message" | base64 | tr -d \'\\n\')"',
        'printf %s\\\\n \'{"type":"$_serverGitCommitType","status":"started","commit_message_b64":"\'"\$commit_message_b64"\'"}\'',
        '',
        'if ! command -v git >/dev/null 2>&1; then',
        '  printf %s\\\\n \'{"type":"$_serverGitCommitType","status":"failed","reason":"git_not_found","commit_message_b64":"\'"\$commit_message_b64"\'"}\'',
        '  exit 0',
        'fi',
        'if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then',
        '  printf %s\\\\n \'{"type":"$_serverGitCommitType","status":"failed","reason":"not_a_git_repo","commit_message_b64":"\'"\$commit_message_b64"\'"}\'',
        '  exit 0',
        'fi',
        '',
        '# Ensure .field_exec/ is not auto-committed.',
        'exclude_path="\$(git rev-parse --git-path info/exclude 2>/dev/null || true)"',
        'if [ -n "\$exclude_path" ]; then',
        '  mkdir -p "\$(dirname "\$exclude_path")" >/dev/null 2>&1 || true',
        '  touch "\$exclude_path" >/dev/null 2>&1 || true',
        '  grep -qxF ${_shQuote('**/.field_exec/')} "\$exclude_path" 2>/dev/null || printf %s\\\\n ${_shQuote('**/.field_exec/')} >> "\$exclude_path" || true',
        'fi',
        '',
        'changes="\$(git status --porcelain 2>/dev/null || true)"',
        'if [ -z "\$changes" ]; then',
        '  printf %s\\\\n \'{"type":"$_serverGitCommitType","status":"skipped","reason":"no_changes","commit_message_b64":"\'"\$commit_message_b64"\'"}\'',
        '  exit 0',
        'fi',
        '',
        'git add -A >/dev/null 2>&1 || true',
        'if git commit -m "\$commit_message" >/dev/null 2>&1; then',
        '  printf %s\\\\n \'{"type":"$_serverGitCommitType","status":"completed","commit_message_b64":"\'"\$commit_message_b64"\'"}\'',
        'else',
        '  printf %s\\\\n \'{"type":"$_serverGitCommitType","status":"failed","reason":"git_commit_failed","commit_message_b64":"\'"\$commit_message_b64"\'"}\'',
        'fi',
      ].join('\n');

      final startBody = [
        'PATH="/opt/homebrew/bin:/usr/local/bin:\$HOME/.local/bin:\$PATH"; export PATH',
        'set -e',
        'TMUX_BIN="\$(command -v tmux 2>/dev/null || true)"',
        'if [ -z "\$TMUX_BIN" ]; then',
        '  for p in /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do',
        '    if [ -x "\$p" ]; then TMUX_BIN="\$p"; break; fi',
        '  done',
        'fi',
        'rm -f ${_shQuote(jobAbs)} >/dev/null 2>&1 || true',
        'if [ -n "\$TMUX_BIN" ]; then',
        '  SESSION=${_shQuote(tmuxSession)}',
        '  WINDOW=${_shQuote(tmuxWindow)}',
        '  if "\$TMUX_BIN" -L $tmuxServerName has-session -t "\$SESSION" >/dev/null 2>&1; then',
        '    "\$TMUX_BIN" -L $tmuxServerName kill-window -t "\$SESSION:\$WINDOW" >/dev/null 2>&1 || true',
        '    "\$TMUX_BIN" -L $tmuxServerName new-window -d -t "\$SESSION" -n "\$WINDOW" sh -c ${_shQuote(runBody)}',
        '  else',
        '    "\$TMUX_BIN" -L $tmuxServerName new-session -d -s "\$SESSION" -n "\$WINDOW" sh -c ${_shQuote(runBody)}',
        '  fi',
        '  echo "tmux:\$SESSION:\$WINDOW" > ${_shQuote(jobAbs)}',
        '  printf %s\\\\n "FIELD_EXEC_JOB=tmux:\$SESSION:\$WINDOW"',
        'else',
        '  nohup sh -c ${_shQuote(runBody)} >/dev/null 2>&1 &',
        '  pid=\$!',
        '  echo "\$pid" > ${_shQuote(pidAbs)}',
        '  echo "pid:\$pid" > ${_shQuote(jobAbs)}',
        '  printf %s\\\\n "FIELD_EXEC_JOB=pid:\$pid"',
        'fi',
      ].join('\n');
      final startCmd = _wrapWithShell(profile, startBody);

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
      Object? exitError;
      try {
        exit = await launchProc.exitCode.timeout(const Duration(seconds: 10));
      } on TimeoutException catch (e) {
        exitError = e;
      } finally {
        await stdoutSub.cancel();
        await stderrSub.cancel();
        _remoteLaunchProc = null;
      }

      String? jobLine;
      for (final line in [...stdout, ...stderr].reversed) {
        if (line.startsWith('FIELD_EXEC_JOB=')) {
          jobLine = line;
          break;
        }
      }
      var remoteJobId = jobLine?.substring('FIELD_EXEC_JOB='.length).trim();
      if (remoteJobId == null || remoteJobId.isEmpty) {
        try {
          final readJob = await _ssh.runCommandWithResult(
            host: profile.host,
            port: profile.port,
            username: profile.username,
            privateKeyPem: pem,
            password: _sshPassword,
            command: _wrapWithShell(
              profile,
              'if [ -f ${_shQuote(jobAbs)} ]; then cat ${_shQuote(jobAbs)}; fi',
            ),
          );
          final fromFile = readJob.stdout.trim();
          if (fromFile.isNotEmpty) remoteJobId = fromFile;
        } catch (_) {}
      }
      if (remoteJobId == null || remoteJobId.isEmpty) {
        if ((exit ?? 1) != 0) {
          throw StateError(
            'Remote launch failed (exit=$exit): ${(stderr.join('\n')).trim().isEmpty ? (stdout.join('\n')).trim() : (stderr.join('\n')).trim()}',
          );
        }
        if (exitError != null) {
          throw StateError(
            'Remote launch failed (timeout): ${(stderr.join('\n')).trim().isEmpty ? (stdout.join('\n')).trim() : (stderr.join('\n')).trim()}',
          );
        }
        throw StateError('Remote launch did not return a job id.');
      }

      _remoteJobId = remoteJobId;
      this.remoteJobId.value = remoteJobId;
      await _sessionStore.saveRemoteJobId(
        targetKey: target.targetKey,
        projectPath: projectPath,
        tabId: tabId,
        remoteJobId: remoteJobId,
      );
      try {
        final profile = target.profile;
        if (profile != null) {
          await _remoteJobs.upsert(
            RemoteJobRecord(
              targetKey: target.targetKey,
              host: profile.host,
              port: profile.port,
              username: profile.username,
              projectPath: projectPath,
              tabId: tabId,
              remoteJobId: remoteJobId,
              threadId: threadId.value,
              startedAtMsUtc: DateTime.now().toUtc().millisecondsSinceEpoch,
            ),
          );
        }
      } catch (_) {}
      // Render remote job status in the session status bar (not as a chat bubble).
    } catch (e) {
      try {
        _remoteLaunchProc?.cancel();
      } catch (_) {}
      _remoteLaunchProc = null;
      await _insertEvent(type: 'error', text: 'Remote start failed: $e');
      _cancelCurrent = null;
      isRunning.value = false;
      remoteJobId.value = null;
    }
  }

  static int _parseWcLineCount(String stdout) {
    final trimmed = stdout.trim();
    if (trimmed.isEmpty) return 0;
    final first = trimmed.split(RegExp(r'\\s+')).first;
    return int.tryParse(first) ?? 0;
  }

  Future<int> _remoteLineCount({required String absPath}) async {
    if (target.local) return 0;
    final profile = target.profile!;
    final pem = await _storage.read(
      key: SecureStorageService.sshPrivateKeyPemKey,
    );

    Future<SshCommandResult> run(String cmd) async {
      try {
        return await _ssh.runCommandWithResult(
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
          return _ssh.runCommandWithResult(
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

    final script =
        'if [ -f ${_shQuote(absPath)} ]; then wc -l ${_shQuote(absPath)} 2>/dev/null | sed \'s/^[[:space:]]*\\\\([0-9][0-9]*\\\\).*/\\\\1/\'; else echo 0; fi';
    final res = await run(_wrapWithShell(profile, script));
    return _parseWcLineCount(res.stdout);
  }

  Future<void> _startRemoteLogTailIfNeeded({
    int? startAtLine,
    int backfillLines = 200,
  }) async {
    if (_tailProc != null) return;

    final profile = target.profile!;
    final pem = await _storage.read(
      key: SecureStorageService.sshPrivateKeyPemKey,
    );

    Future<SshCommandProcess> startProc(String cmd) async {
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

    // We handle resume/catch-up separately; start tails from end by default to
    // avoid re-streaming old logs (which can cause duplicates and scroll jumps).
    final startLine = startAtLine ?? 0;

    final cmd = _wrapWithShell(
      profile,
      startLine > 0
          ? 'tail -n +$startLine -F ${_shQuote(logAbs)}'
          : 'tail -n 0 -F ${_shQuote(logAbs)}',
    );
    final proc = await startProc(cmd);
    final token = Object();
    _tailToken = token;
    _tailProc = proc;

    _tailStdoutSub = proc.stdoutLines.listen((line) {
      if (line.trim().isEmpty) return;
      _noteLogLineSeen(line);
      _bumpLogLineCursor();
      if (!_shouldProcessLogLine(line)) return;
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
      // If this tail was cancelled/replaced intentionally, suppress noise.
      if (_tailToken != token) return;
      if (!isClosed) {
        _insertEvent(type: 'tail_closed', text: 'Log tail stopped.');
      }
      _cancelTailOnly();
    });
  }

  Future<void> _catchUpFromRemoteLogOnce({required int backfillLines}) async {
    if (target.local) return;
    if (_tailProc != null) return;

    final profile = target.profile;
    if (profile == null) return;

    final pem = await _storage.read(
      key: SecureStorageService.sshPrivateKeyPemKey,
    );
    if (pem == null || pem.trim().isEmpty) return;

    // Bounded catch-up: read a window from the end, then only apply lines after
    // the last seen hash. This avoids expensive full-log scans and prevents
    // re-inserting the entire log repeatedly on flaky resumes.
    const window = 8000;
    final logAbs = _remoteAbsPath(_logRelPath);
    final cmdBody = [
      'if [ -f ${_shQuote(logAbs)} ]; then',
      '  tail -n $window ${_shQuote(logAbs)} 2>/dev/null || true',
      'fi',
    ].join('\n');

    SshCommandResult res;
    try {
      res = await _ssh.runCommandWithResult(
        host: profile.host,
        port: profile.port,
        username: profile.username,
        privateKeyPem: pem,
        password: _sshPassword,
        command: _wrapWithShell(profile, cmdBody),
      );
    } catch (_) {
      // Best-effort: if we can't catch up, we still reattach the live tail.
      return;
    }

    final lines = const LineSplitter().convert(res.stdout);
    if (lines.isEmpty) return;

    var startIndex = 0;
    final last = _logLastLineHash.trim();
    if (last.isNotEmpty) {
      for (var i = lines.length - 1; i >= 0; i--) {
        if (_fnv1a64Hex(lines[i]) == last) {
          startIndex = i + 1;
          break;
        }
      }
    } else {
      startIndex = (lines.length - backfillLines).clamp(0, lines.length);
    }

    for (final line in lines.skip(startIndex)) {
      if (line.trim().isEmpty) continue;
      _noteLogLineSeen(line);
      if (!_shouldProcessLogLine(line)) continue;
      _tailQueue = _tailQueue.then((_) async {
        try {
          final decoded = jsonDecode(line);
          if (decoded is Map) {
            await _handleCodexJsonEvent(decoded.cast<String, Object?>());
          }
        } catch (_) {}
      });
    }
  }

  Future<void> _refreshRemoteRunningStateAndTail({
    required int backfillLines,
  }) async {
    try {
      await _catchUpFromRemoteLogOnce(backfillLines: backfillLines);
    } catch (_) {}

    var stored =
        _remoteJobId ??
        await _sessionStore.loadRemoteJobId(
          targetKey: target.targetKey,
          projectPath: projectPath,
          tabId: tabId,
        );
    if (stored == null || stored.isEmpty) {
      try {
        final latched = await _tryLatchRemoteJobIdFromRemoteJobFile();
        if (latched != null && latched.isNotEmpty) {
          stored = latched;
          await _sessionStore.saveRemoteJobId(
            targetKey: target.targetKey,
            projectPath: projectPath,
            tabId: tabId,
            remoteJobId: latched,
          );
        }
      } catch (_) {}
    }
    _remoteJobId = stored;
    remoteJobId.value = stored;
    if (stored == null || stored.isEmpty) {
      isRunning.value = false;
      thinkingPreview.value = null;
      _cancelCurrent = null;
      _cancelTailOnly();
      return;
    }

    final profile = target.profile!;
    final pem = await _storage.read(
      key: SecureStorageService.sshPrivateKeyPemKey,
    );

    String checkCmd;
    if (stored.startsWith('tmux:')) {
      final project = _parseProjectTmuxJobId(stored);
      if (project != null) {
        checkCmd = [
          'PATH="/opt/homebrew/bin:/usr/local/bin:\$HOME/.local/bin:\$PATH"; export PATH',
          'TMUX_BIN="\$(command -v tmux 2>/dev/null || true)"',
          'if [ -z "\$TMUX_BIN" ]; then',
          '  for p in /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do',
          '    if [ -x "\$p" ]; then TMUX_BIN="\$p"; break; fi',
          '  done',
          'fi',
          '[ -n "\$TMUX_BIN" ] || exit 127',
          '"\$TMUX_BIN" -L field_exec has-session -t ${_shQuote(project.session)}',
          '"\$TMUX_BIN" -L field_exec list-windows -t ${_shQuote(project.session)} -F \'#W\' | grep -qxF ${_shQuote(project.window)}',
        ].join('\n');
      } else {
        final name = stored.substring('tmux:'.length);
        checkCmd = [
          'PATH="/opt/homebrew/bin:/usr/local/bin:\$HOME/.local/bin:\$PATH"; export PATH',
          'TMUX_BIN="\$(command -v tmux 2>/dev/null || true)"',
          'if [ -z "\$TMUX_BIN" ]; then',
          '  for p in /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do',
          '    if [ -x "\$p" ]; then TMUX_BIN="\$p"; break; fi',
          '  done',
          'fi',
          '[ -n "\$TMUX_BIN" ] || exit 127',
          '"\$TMUX_BIN" has-session -t ${_shQuote(name)}',
        ].join('\n');
      }
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
      command: _wrapWithShell(profile, checkCmd),
    );

    if ((check.exitCode ?? 1) == 0 || (check.exitCode ?? 1) == 127) {
      isRunning.value = true;
      _cancelCurrent ??= () {
        _stopRemoteJob().whenComplete(() {
          _cancelTailOnly();
          _cancelCurrent = null;
          isRunning.value = false;
        });
      };
      await _startRemoteLogTailIfNeeded(backfillLines: backfillLines);
      return;
    }

    await _sessionStore.clearRemoteJobId(
      targetKey: target.targetKey,
      projectPath: projectPath,
      tabId: tabId,
    );
    try {
      await _remoteJobs.remove(
        targetKey: target.targetKey,
        projectPath: projectPath,
        tabId: tabId,
      );
    } catch (_) {}
    _remoteJobId = null;
    remoteJobId.value = null;
    isRunning.value = false;
    thinkingPreview.value = null;
    _cancelCurrent = null;
    _cancelTailOnly();
  }

  Future<void> _refreshLocalRunningStateAndTail({
    required int backfillLines,
  }) async {
    if (!target.local) return;
    try {
      await _catchUpFromLocalLogOnce(backfillLines: backfillLines);
    } catch (_) {}
    final stored =
        remoteJobId.value ??
        (await _sessionStore.loadRemoteJobId(
          targetKey: target.targetKey,
          projectPath: projectPath,
          tabId: tabId,
        ));
    final job = (stored == null || stored.isEmpty)
        ? await _readLocalJobId()
        : stored;

    if (job == null || job.isEmpty) {
      isRunning.value = false;
      thinkingPreview.value = null;
      _cancelCurrent = null;
      _cancelLocalTailOnly();
      remoteJobId.value = null;
      _remoteJobId = null;
      return;
    }

    _remoteJobId = job;
    remoteJobId.value = job;
    await _sessionStore.saveRemoteJobId(
      targetKey: target.targetKey,
      projectPath: projectPath,
      tabId: tabId,
      remoteJobId: job,
    );

    final alive = await _isLocalJobAlive(job);
    if (alive) {
      isRunning.value = true;
      _cancelCurrent ??= () {
        _stopLocalJob(job).whenComplete(() async {
          _cancelLocalTailOnly();
          _cancelCurrent = null;
          isRunning.value = false;
          thinkingPreview.value = null;
          await _sessionStore.clearRemoteJobId(
            targetKey: target.targetKey,
            projectPath: projectPath,
            tabId: tabId,
          );
          remoteJobId.value = null;
          _remoteJobId = null;
        });
      };
      await _startLocalLogTailIfNeeded(backfillLines: backfillLines);
      return;
    }

    await _sessionStore.clearRemoteJobId(
      targetKey: target.targetKey,
      projectPath: projectPath,
      tabId: tabId,
    );
    remoteJobId.value = null;
    _remoteJobId = null;
    isRunning.value = false;
    thinkingPreview.value = null;
    _cancelCurrent = null;
    _cancelLocalTailOnly();
  }

  Future<bool> _isLocalJobAlive(String job) async {
    if (job.startsWith('tmux:')) {
      final name = job.substring('tmux:'.length);
      final checkCmd = [
        'PATH="/opt/homebrew/bin:/usr/local/bin:\$HOME/.local/bin:\$PATH"; export PATH',
        'TMUX_BIN="\$(command -v tmux 2>/dev/null || true)"',
        'if [ -z "\$TMUX_BIN" ]; then',
        '  for p in /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do',
        '    if [ -x "\$p" ]; then TMUX_BIN="\$p"; break; fi',
        '  done',
        'fi',
        '[ -n "\$TMUX_BIN" ] || exit 127',
        '"\$TMUX_BIN" has-session -t ${_shQuote(name)}',
      ].join('\n');
      final res = await Process.run('/bin/sh', ['-c', checkCmd]);
      return res.exitCode == 0 || res.exitCode == 127;
    }

    if (job.startsWith('pid:')) {
      final pid = job.substring('pid:'.length);
      final res = await Process.run('/bin/sh', [
        '-c',
        'kill -0 $pid >/dev/null 2>&1',
      ]);
      return res.exitCode == 0;
    }

    return false;
  }

  Future<void> _stopLocalJob(String job) async {
    String cmd;
    if (job.startsWith('tmux:')) {
      final project = _parseProjectTmuxJobId(job);
      if (project != null) {
        cmd = [
          'PATH="/opt/homebrew/bin:/usr/local/bin:\$HOME/.local/bin:\$PATH"; export PATH',
          'TMUX_BIN="\$(command -v tmux 2>/dev/null || true)"',
          'if [ -z "\$TMUX_BIN" ]; then',
          '  for p in /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do',
          '    if [ -x "\$p" ]; then TMUX_BIN="\$p"; break; fi',
          '  done',
          'fi',
          '[ -n "\$TMUX_BIN" ] || exit 127',
          '"\$TMUX_BIN" -L field_exec kill-window -t ${_shQuote('${project.session}:${project.window}')} >/dev/null 2>&1 || true',
        ].join('\n');
      } else {
        final name = job.substring('tmux:'.length);
        cmd = [
          'PATH="/opt/homebrew/bin:/usr/local/bin:\$HOME/.local/bin:\$PATH"; export PATH',
          'TMUX_BIN="\$(command -v tmux 2>/dev/null || true)"',
          'if [ -z "\$TMUX_BIN" ]; then',
          '  for p in /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do',
          '    if [ -x "\$p" ]; then TMUX_BIN="\$p"; break; fi',
          '  done',
          'fi',
          '[ -n "\$TMUX_BIN" ] || exit 127',
          '"\$TMUX_BIN" kill-session -t ${_shQuote(name)} >/dev/null 2>&1 || true',
        ].join('\n');
      }
    } else if (job.startsWith('pid:')) {
      final pid = job.substring('pid:'.length);
      cmd = 'kill $pid >/dev/null 2>&1 || true';
    } else {
      cmd = 'true';
    }
    await Process.run('/bin/sh', ['-c', cmd]);
  }

  Future<void> _stopRemoteJobBestEffort() async {
    try {
      await _stopRemoteJob();
    } catch (_) {}
  }

  Future<void> _stopRemoteJob() async {
    final job =
        _remoteJobId ??
        await _sessionStore.loadRemoteJobId(
          targetKey: target.targetKey,
          projectPath: projectPath,
          tabId: tabId,
        );
    if (job == null || job.isEmpty) {
      return;
    }

    final profile = target.profile!;
    final pem = await _storage.read(
      key: SecureStorageService.sshPrivateKeyPemKey,
    );

    String cmd;
    if (job.startsWith('tmux:')) {
      final name = job.substring('tmux:'.length);
      cmd = [
        'PATH="/opt/homebrew/bin:/usr/local/bin:\$HOME/.local/bin:\$PATH"; export PATH',
        'TMUX_BIN="\$(command -v tmux 2>/dev/null || true)"',
        'if [ -z "\$TMUX_BIN" ]; then',
        '  for p in /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do',
        '    if [ -x "\$p" ]; then TMUX_BIN="\$p"; break; fi',
        '  done',
        'fi',
        '[ -n "\$TMUX_BIN" ] || exit 127',
        '"\$TMUX_BIN" kill-session -t ${_shQuote(name)} >/dev/null 2>&1 || true',
      ].join('\n');
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
      command: _wrapWithShell(profile, cmd),
    );

    await _sessionStore.clearRemoteJobId(
      targetKey: target.targetKey,
      projectPath: projectPath,
      tabId: tabId,
    );
    try {
      await _remoteJobs.remove(
        targetKey: target.targetKey,
        projectPath: projectPath,
        tabId: tabId,
      );
    } catch (_) {}
    _remoteJobId = null;
    remoteJobId.value = null;
  }

  Future<void> _maybeReattachRemote() async {
    try {
      var stored = await _sessionStore.loadRemoteJobId(
        targetKey: target.targetKey,
        projectPath: projectPath,
        tabId: tabId,
      );
      if (stored == null || stored.isEmpty) {
        try {
          final latched = await _tryLatchRemoteJobIdFromRemoteJobFile();
          if (latched != null && latched.isNotEmpty) {
            stored = latched;
            await _sessionStore.saveRemoteJobId(
              targetKey: target.targetKey,
              projectPath: projectPath,
              tabId: tabId,
              remoteJobId: latched,
            );
          }
        } catch (_) {}
      }
      _remoteJobId = stored;
      remoteJobId.value = stored;

      await _rehydrateFromRemoteLog(maxLines: 200);
      // If the job finished while the app was backgrounded/terminated, we may
      // have missed >200 lines; replay any unseen log lines using the cursor.
      try {
        await _catchUpFromRemoteLogOnce(backfillLines: 200);
      } catch (_) {}

      if (stored == null || stored.isEmpty) return;

      // Optimistically mark as running right away so we don't accidentally start
      // a new turn and kill the existing remote job before we finish checking.
      isRunning.value = true;
      _cancelCurrent = () {
        _stopRemoteJob().whenComplete(() {
          _cancelTailOnly();
          _cancelCurrent = null;
          isRunning.value = false;
        });
      };

      final profile = target.profile!;
      final pem = await _storage.read(
        key: SecureStorageService.sshPrivateKeyPemKey,
      );

      String checkCmd;
      if (stored.startsWith('tmux:')) {
        final project = _parseProjectTmuxJobId(stored);
        if (project != null) {
          checkCmd = [
            'PATH="/opt/homebrew/bin:/usr/local/bin:\$HOME/.local/bin:\$PATH"; export PATH',
            'TMUX_BIN="\$(command -v tmux 2>/dev/null || true)"',
            'if [ -z "\$TMUX_BIN" ]; then',
            '  for p in /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do',
            '    if [ -x "\$p" ]; then TMUX_BIN="\$p"; break; fi',
            '  done',
            'fi',
            '[ -n "\$TMUX_BIN" ] || exit 127',
            '"\$TMUX_BIN" -L field_exec has-session -t ${_shQuote(project.session)}',
            '"\$TMUX_BIN" -L field_exec list-windows -t ${_shQuote(project.session)} -F \'#W\' | grep -qxF ${_shQuote(project.window)}',
          ].join('\n');
        } else {
          final name = stored.substring('tmux:'.length);
          checkCmd = [
            'PATH="/opt/homebrew/bin:/usr/local/bin:\$HOME/.local/bin:\$PATH"; export PATH',
            'TMUX_BIN="\$(command -v tmux 2>/dev/null || true)"',
            'if [ -z "\$TMUX_BIN" ]; then',
            '  for p in /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do',
            '    if [ -x "\$p" ]; then TMUX_BIN="\$p"; break; fi',
            '  done',
            'fi',
            '[ -n "\$TMUX_BIN" ] || exit 127',
            '"\$TMUX_BIN" has-session -t ${_shQuote(name)}',
          ].join('\n');
        }
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
        command: _wrapWithShell(profile, checkCmd),
      );

      if ((check.exitCode ?? 1) == 0 || (check.exitCode ?? 1) == 127) {
        await _startRemoteLogTailIfNeeded(backfillLines: 200);
      } else {
        await _sessionStore.clearRemoteJobId(
          targetKey: target.targetKey,
          projectPath: projectPath,
          tabId: tabId,
        );
        try {
          await _remoteJobs.remove(
            targetKey: target.targetKey,
            projectPath: projectPath,
            tabId: tabId,
          );
        } catch (_) {}
        _remoteJobId = null;
        remoteJobId.value = null;
        _cancelCurrent = null;
        isRunning.value = false;
      }
    } catch (_) {
      // Best-effort. Keep the optimistic running state; starting a new turn
      // could otherwise kill a still-running remote job.
      await _insertEvent(
        type: 'reattach_failed',
        text: 'Failed to reattach/check running state. Verify SSH access.',
      );
    }
  }

  Future<String?> _tryLatchRemoteJobIdFromRemoteJobFile() async {
    if (target.local) return null;
    final profile = target.profile;
    if (profile == null) return null;

    final pem = await _storage.read(
      key: SecureStorageService.sshPrivateKeyPemKey,
    );
    if (pem == null || pem.trim().isEmpty) return null;

    final jobAbs = _remoteAbsPath(_jobRelPath);
    final cmd = _wrapWithShell(
      profile,
      'if [ -f ${_shQuote(jobAbs)} ]; then head -n 1 ${_shQuote(jobAbs)}; fi',
    );

    Future<SshCommandResult> runOnce({String? password}) {
      return _ssh.runCommandWithResult(
        host: profile.host,
        port: profile.port,
        username: profile.username,
        privateKeyPem: pem,
        password: password,
        command: cmd,
      );
    }

    SshCommandResult res;
    try {
      res = await runOnce(password: _sshPassword);
    } catch (_) {
      if (_sshPassword == null) {
        final pw = await _promptForPassword();
        if (pw == null || pw.isEmpty) return null;
        _sshPassword = pw;
        res = await runOnce(password: _sshPassword);
      } else {
        return null;
      }
    }

    final job = res.stdout.trim();
    if (job.isEmpty) return null;
    return job;
  }

  Future<void> _rehydrateFromRemoteLog({required int maxLines}) async {
    if (target.local) return;
    final profile = target.profile!;
    final pem = await _storage.read(
      key: SecureStorageService.sshPrivateKeyPemKey,
    );

    try {
      Future<SshCommandResult> run(String cmd) async {
        try {
          return await _ssh.runCommandWithResult(
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
            return _ssh.runCommandWithResult(
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
      _historyLogRelPath = _logRelPath;
      _historyFocusThreadId = null;

      int totalLines = 0;
      try {
        totalLines = await _remoteLineCount(absPath: logAbs);
      } catch (_) {}
      final cmd = _wrapWithShell(
        profile,
        'if [ -f ${_shQuote(logAbs)} ]; then tail -n $maxLines ${_shQuote(logAbs)}; fi',
      );

      final res = await run(cmd);

      final lines = const LineSplitter().convert(res.stdout);
      if (lines.isEmpty) {
        _historyRemoteStartLine = null;
        hasMoreHistory.value = false;
        return;
      }

      for (final line in lines) {
        if (line.trim().isNotEmpty) _rememberRecentLogLine(line);
      }
      for (var i = lines.length - 1; i >= 0; i--) {
        final line = lines[i];
        if (line.trim().isEmpty) continue;
        _logLastLineHash = _fnv1a64Hex(line);
        _flushLogLastLineHash();
        break;
      }

      final tailStartLine = (totalLines - lines.length + 1).clamp(
        1,
        totalLines == 0 ? 1 : totalLines,
      );
      _historyRemoteStartLine = tailStartLine;
      hasMoreHistory.value = tailStartLine > 1;

      final wasEmpty = chatController.messages.isEmpty;
      _pendingActionsMessage = null;
      final backfill = <Message>[
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
      if (wasEmpty && backfill.isNotEmpty) {
        _needsScrollToBottom.value = true;
      }
      await _maybeCatchUpAutoCommitFromHydratedLog(lines: lines, startIndex: 0);
    } catch (_) {
      // Best-effort.
    }
  }

  Future<bool> _remoteLogHasGitCommitMarker({
    required String sourceItemId,
  }) async {
    if (target.local) return false;
    final profile = target.profile!;
    final pem = await _storage.read(
      key: SecureStorageService.sshPrivateKeyPemKey,
    );
    final logAbs = _remoteAbsPath(_logRelPath);
    final pattern = _shQuote(
      '"type":"$_clientGitCommitType","status":"(completed|skipped|failed)".*"source_item_id":"$sourceItemId"',
    );
    final cmd = _wrapWithShell(
      profile,
      'grep -qE $pattern ${_shQuote(logAbs)} 2>/dev/null',
    );
    try {
      final res = await _ssh.runCommandWithResult(
        host: profile.host,
        port: profile.port,
        username: profile.username,
        privateKeyPem: pem,
        password: _sshPassword,
        command: cmd,
      );
      return (res.exitCode ?? 1) == 0;
    } catch (_) {
      if (_sshPassword == null) {
        try {
          final pw = await _promptForPassword();
          if (pw == null || pw.isEmpty) return false;
          _sshPassword = pw;
          final res = await _ssh.runCommandWithResult(
            host: profile.host,
            port: profile.port,
            username: profile.username,
            privateKeyPem: pem,
            password: _sshPassword,
            command: cmd,
          );
          return (res.exitCode ?? 1) == 0;
        } catch (_) {
          return false;
        }
      }
      return false;
    }
  }

  Future<void> _maybeCatchUpAutoCommitFromHydratedLog({
    required List<String> lines,
    required int startIndex,
  }) async {
    if (isRunning.value) return;
    if (_autoCommitCatchUpInProgress) return;
    if (!target.local) return;
    // Local turns now auto-commit inside the detached job (mirrors remote).
    // If we already have server-side commit markers, do not attempt a client
    // catch-up commit (avoids double-commit noise).
    if (lines.any((l) => l.contains('"type":"$_serverGitCommitType"'))) return;

    String? lastCommitMessage;
    String? lastSourceItemId;
    final committedSourceIds = <String>{};

    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map) continue;
        final map = decoded.cast<String, Object?>();
        final type = map['type']?.toString();
        if (type == _clientGitCommitType) {
          final status = map['status']?.toString() ?? '';
          if (status == 'started') continue;
          final sid = map['source_item_id']?.toString() ?? '';
          if (sid.isNotEmpty) committedSourceIds.add(sid);
          continue;
        }
      } catch (_) {}
    }

    for (final line in lines.skip(startIndex)) {
      if (line.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map) continue;
        final map = decoded.cast<String, Object?>();
        final type = map['type']?.toString();
        if (type == null || !type.startsWith('item.')) continue;
        final item = map['item'];
        if (item is! Map) continue;
        final itemType = item['type']?.toString();
        if (itemType != 'agent_message') continue;
        final itemId = item['id']?.toString();
        final text = item['text']?.toString() ?? '';
        final structured = jsonDecode(text);
        if (structured is! Map) continue;
        final resp = CodexStructuredResponse.fromJson(
          structured.cast<String, Object?>(),
        );
        final commitMessage = resp.commitMessage.trim();
        lastCommitMessage = commitMessage.isEmpty ? null : commitMessage;
        lastSourceItemId = itemId;
      } catch (_) {}
    }

    final commitMessage = lastCommitMessage;
    final sourceItemId = lastSourceItemId;
    if (commitMessage == null || commitMessage.isEmpty) return;
    if (sourceItemId == null || sourceItemId.isEmpty) return;

    if (committedSourceIds.contains(sourceItemId)) return;
    if (!target.local) {
      final alreadyLogged = await _remoteLogHasGitCommitMarker(
        sourceItemId: sourceItemId,
      );
      if (alreadyLogged) return;
    } else {
      final marker = '"type":"$_clientGitCommitType"';
      final source = '"source_item_id":"$sourceItemId"';
      final hasFinalMarker = lines.any(
        (l) =>
            l.contains(marker) &&
            l.contains(source) &&
            !l.contains('"status":"started"'),
      );
      if (hasFinalMarker) return;
    }

    _autoCommitCatchUpInProgress = true;
    try {
      await _maybeAutoCommit(commitMessage, sourceItemId: sourceItemId);
    } finally {
      _autoCommitCatchUpInProgress = false;
    }
  }

  Future<void> _rehydrateFromAnyLogForThread({
    required String threadId,
    required int maxLines,
  }) async {
    if (threadId.trim().isEmpty) return;
    if (target.local) {
      final rel = await _findLocalLogRelPathForThread(threadId: threadId);
      if (rel == null) return;
      await _rehydrateFromLocalLog(
        maxLines: maxLines,
        logRelPath: rel,
        focusThreadId: threadId,
      );
      return;
    }

    final rel = await _findRemoteLogRelPathForThread(threadId: threadId);
    if (rel == null) return;
    await _rehydrateFromRemoteLogPath(
      maxLines: maxLines,
      logRelPath: rel,
      focusThreadId: threadId,
    );
  }

  Future<void> _rehydrateFromRemoteLogPath({
    required int maxLines,
    required String logRelPath,
    String? focusThreadId,
  }) async {
    if (target.local) return;

    final profile = target.profile!;
    final pem = await _storage.read(
      key: SecureStorageService.sshPrivateKeyPemKey,
    );

    Future<SshCommandResult> run(String cmd) async {
      try {
        return await _ssh.runCommandWithResult(
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
          return _ssh.runCommandWithResult(
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

    final logAbs = _remoteAbsPath(logRelPath);
    _historyLogRelPath = logRelPath;
    _historyFocusThreadId = focusThreadId;

    int totalLines = 0;
    try {
      totalLines = await _remoteLineCount(absPath: logAbs);
    } catch (_) {}
    final cmd = _wrapWithShell(
      profile,
      'if [ -f ${_shQuote(logAbs)} ]; then tail -n $maxLines ${_shQuote(logAbs)}; fi',
    );

    final res = await run(cmd);
    final lines = const LineSplitter().convert(res.stdout);
    if (lines.isEmpty) {
      _historyRemoteStartLine = null;
      hasMoreHistory.value = false;
      return;
    }

    for (final line in lines) {
      if (line.trim().isNotEmpty) _rememberRecentLogLine(line);
    }

    final start = _findFocusStartIndex(lines, focusThreadId);
    final tailStartLine = (totalLines - lines.length + 1).clamp(
      1,
      totalLines == 0 ? 1 : totalLines,
    );
    _historyRemoteStartLine = tailStartLine + start;
    final foundThreadStart = focusThreadId == null
        ? false
        : _containsThreadStart(lines, focusThreadId);
    hasMoreHistory.value = focusThreadId != null && foundThreadStart
        ? false
        : (tailStartLine + start) > 1;
    _pendingActionsMessage = null;
    _seenAgentMessageItemIds.clear();
    final backfill = <Message>[
      _eventMessage(
        type: 'replay',
        text: 'Replayed ${lines.length} lines from $logRelPath.',
      ),
    ];

    for (final line in lines.skip(start)) {
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
    await _maybeCatchUpAutoCommitFromHydratedLog(
      lines: lines,
      startIndex: start,
    );
  }

  Future<void> _rehydrateFromLocalLog({
    required int maxLines,
    required String logRelPath,
    String? focusThreadId,
  }) async {
    final logPath = _joinPosix(projectPath, logRelPath);
    final file = File(logPath);
    if (!await file.exists()) {
      _historyLogRelPath = logRelPath;
      _historyFocusThreadId = focusThreadId;
      _historyLocalStartIndex = null;
      hasMoreHistory.value = false;
      return;
    }

    final contents = await file.readAsString();
    final lines = const LineSplitter().convert(contents);
    if (lines.isEmpty) {
      _historyLogRelPath = logRelPath;
      _historyFocusThreadId = focusThreadId;
      _historyLocalStartIndex = null;
      hasMoreHistory.value = false;
      return;
    }

    final tail = lines.length <= maxLines
        ? lines
        : lines.sublist(lines.length - maxLines);
    _historyLogRelPath = logRelPath;
    _historyFocusThreadId = focusThreadId;
    final tailStartIndex = (lines.length - tail.length).clamp(0, lines.length);
    for (final line in tail) {
      if (line.trim().isNotEmpty) _rememberRecentLogLine(line);
    }
    for (var i = tail.length - 1; i >= 0; i--) {
      final line = tail[i];
      if (line.trim().isEmpty) continue;
      _logLastLineHash = _fnv1a64Hex(line);
      _flushLogLastLineHash();
      break;
    }

    final start = _findFocusStartIndex(tail, focusThreadId);
    _historyLocalStartIndex = tailStartIndex + start;
    final foundThreadStart = focusThreadId == null
        ? false
        : _containsThreadStart(tail, focusThreadId);
    hasMoreHistory.value = focusThreadId != null && foundThreadStart
        ? false
        : (tailStartIndex + start) > 0;
    final wasEmpty = chatController.messages.isEmpty;
    _pendingActionsMessage = null;
    _seenAgentMessageItemIds.clear();
    final backfill = <Message>[
      _eventMessage(
        type: 'replay',
        text: 'Replayed ${tail.length} local log lines from $logRelPath.',
      ),
    ];

    for (final line in tail.skip(start)) {
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
    if (wasEmpty && backfill.isNotEmpty) {
      _needsScrollToBottom.value = true;
    }
    await _maybeCatchUpAutoCommitFromHydratedLog(
      lines: tail,
      startIndex: start,
    );
  }

  static int _findFocusStartIndex(List<String> lines, String? focusThreadId) {
    if (focusThreadId == null || focusThreadId.trim().isEmpty) return 0;
    for (var i = lines.length - 1; i >= 0; i--) {
      final line = lines[i];
      if (!line.contains('thread.started')) continue;
      if (!line.contains(focusThreadId)) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map) {
          final type = decoded['type']?.toString();
          final id = decoded['thread_id']?.toString();
          if (type == 'thread.started' && id == focusThreadId) {
            // Include the immediately preceding user prompt line if present.
            if (i > 0) {
              final prev = lines[i - 1];
              if (prev.contains('"type":"$_clientUserMessageType"')) {
                return i - 1;
              }
            }
            return i;
          }
        }
      } catch (_) {}
    }
    return 0;
  }

  static bool _containsThreadStart(List<String> lines, String threadId) {
    if (threadId.trim().isEmpty) return false;
    for (final line in lines) {
      if (!line.contains('thread.started')) continue;
      if (!line.contains(threadId)) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map) {
          final type = decoded['type']?.toString();
          final id = decoded['thread_id']?.toString();
          if (type == 'thread.started' && id == threadId) return true;
        }
      } catch (_) {}
    }
    return false;
  }

  Future<String?> _findLocalLogRelPathForThread({
    required String threadId,
  }) async {
    final dir = Directory(_joinPosix(projectPath, _sessionsDirRelPath));
    if (!await dir.exists()) return null;

    final entries = await dir.list().toList();
    final files = entries.whereType<File>().where((f) {
      final name = f.path.split('/').last;
      return name.endsWith('.log') && !name.endsWith('.stderr.log');
    }).toList();

    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    for (final f in files) {
      try {
        final text = await f.readAsString();
        if (text.contains('"thread_id":"$threadId"')) {
          return '$_sessionsDirRelPath/${f.path.split('/').last}';
        }
      } catch (_) {}
    }
    return null;
  }

  Future<String?> _findRemoteLogRelPathForThread({
    required String threadId,
  }) async {
    if (target.local) return null;
    final profile = target.profile!;
    final pem = await _storage.read(
      key: SecureStorageService.sshPrivateKeyPemKey,
    );
    if (pem == null || pem.trim().isEmpty) return null;

    final pattern = _shQuote('"thread_id":"$threadId"');
    final findCmd = [
      'cd ${_shQuote(projectPath)} || exit 0',
      'if [ ! -d ${_shQuote(_fieldExecDir)} ]; then exit 0; fi',
      'for f in \$(ls -t ${_shQuote(_sessionsDirRelPath)}/*.log 2>/dev/null); do',
      '  case "\$f" in',
      '    *.stderr.log) continue ;;',
      '  esac',
      '  if grep -q $pattern "\$f" 2>/dev/null; then',
      '    echo "\$f"',
      '    exit 0',
      '  fi',
      'done',
      'exit 0',
    ].join('\n');

    Future<SshCommandResult> runOnce({String? password}) {
      return _ssh.runCommandWithResult(
        host: profile.host,
        port: profile.port,
        username: profile.username,
        privateKeyPem: pem,
        password: password,
        command: _wrapWithShell(profile, findCmd),
      );
    }

    SshCommandResult res;
    try {
      res = await runOnce(password: _sshPassword);
    } catch (_) {
      if (_sshPassword == null) {
        final pw = await _promptForPassword();
        if (pw == null || pw.isEmpty) return null;
        _sshPassword = pw;
        res = await runOnce(password: _sshPassword);
      } else {
        return null;
      }
    }

    final path = res.stdout.trim();
    if (path.isEmpty) return null;
    return path;
  }

  Future<void> _handleCodexJsonEvent(Map<String, Object?> event) async {
    final type = event['type'] as String?;
    if (type == null || type.isEmpty) return;

    // Safety valve: if something goes wrong with cursoring/deduping, the chat
    // list can explode to tens of thousands of messages, which also tends to
    // make the view jump around. When that happens, rebuild from the log tail.
    if (!_repairedExplodedChat && chatController.messages.length > 8000) {
      _repairedExplodedChat = true;
      try {
        if (target.local) {
          await _rehydrateFromLocalLog(maxLines: 300, logRelPath: _logRelPath);
        } else {
          await _rehydrateFromRemoteLog(maxLines: 300);
        }
      } catch (_) {}
      return;
    }

    // Prompts are inserted into chat immediately; keep them out of the live
    // stream to avoid duplicates. Rehydration renders them from the log instead.
    if (type == _clientUserMessageType) return;
    if (type == _clientGitCommitType) return;
    if (type == _serverGitCommitType) {
      final out = await _materializeCodexJsonEvent(event, replay: false);
      if (out.isNotEmpty) {
        await chatController.insertAllMessages(out, animated: true);
      }
      return;
    }
    if (type == _serverGitignoreBootstrapType) {
      final out = await _materializeCodexJsonEvent(event, replay: false);
      if (out.isNotEmpty) {
        await chatController.insertAllMessages(out, animated: true);
      }
      return;
    }

    if (type == 'thread.started') {
      final id = event['thread_id'] as String?;
      if (id != null && id.isNotEmpty) {
        await _saveThreadId(id);
        await _conversationStore.upsert(
          targetKey: target.targetKey,
          projectPath: projectPath,
          threadId: id,
          preview: _lastUserPromptPreview,
          tabId: tabId,
        );
        if (!target.local) {
          try {
            final profile = target.profile;
            final jobId = _remoteJobId;
            if (profile != null && jobId != null && jobId.isNotEmpty) {
              await _remoteJobs.upsert(
                RemoteJobRecord(
                  targetKey: target.targetKey,
                  host: profile.host,
                  port: profile.port,
                  username: profile.username,
                  projectPath: projectPath,
                  tabId: tabId,
                  remoteJobId: jobId,
                  threadId: id,
                  startedAtMsUtc: DateTime.now().toUtc().millisecondsSinceEpoch,
                ),
              );
            }
          } catch (_) {}
        }
      }
      return;
    }

    if (type == 'turn.started' ||
        type == 'turn.completed' ||
        type == 'turn.failed') {
      if (type == 'turn.started' && !isRunning.value) {
        isRunning.value = true;
        thinkingPreview.value = null;
        if (!target.local) {
          _cancelCurrent ??= () {
            _stopRemoteJob().whenComplete(() {
              _cancelTailOnly();
              _cancelCurrent = null;
              isRunning.value = false;
              thinkingPreview.value = null;
            });
          };
        }
      }

      if (type == 'turn.completed' || type == 'turn.failed') {
        if (type == 'turn.failed') {
          final err = event['error']?.toString();
          final trimmed = err?.trim();
          await _insertEvent(
            type: 'turn.failed',
            text: trimmed == null || trimmed.isEmpty ? 'Turn failed.' : trimmed,
          );
        }
        // Best-effort: notify even if user is on a different screen/tab.
        try {
          final active = _activeSession.active;
          final isActiveView =
              active != null &&
              active.targetKey == target.targetKey &&
              active.projectPath == projectPath &&
              active.tabId == tabId;

          // Do not notify if the user is actively looking at this chat.
          if (!(_lifecycle.isForeground && isActiveView)) {
            await _notifications.notifyTurnFinished(
              projectPath: projectPath,
              success: type == 'turn.completed',
              tabId: tabId,
              threadId: threadId.value,
            );
          }
        } catch (_) {}
      }

      if (type == 'turn.completed' || type == 'turn.failed') {
        await _sessionStore.clearRemoteJobId(
          targetKey: target.targetKey,
          projectPath: projectPath,
          tabId: tabId,
        );
        if (!target.local) {
          try {
            await _remoteJobs.remove(
              targetKey: target.targetKey,
              projectPath: projectPath,
              tabId: tabId,
            );
          } catch (_) {}
        } else {
          try {
            final job = File(_joinPosix(projectPath, _jobRelPath));
            if (await job.exists()) await job.writeAsString('', flush: true);
          } catch (_) {}
          try {
            final pid = File(_joinPosix(projectPath, _pidRelPath));
            if (await pid.exists()) await pid.writeAsString('', flush: true);
          } catch (_) {}
        }
        _remoteJobId = null;
        remoteJobId.value = null;
        _cancelCurrent = null;
        isRunning.value = false;
        thinkingPreview.value = null;
      }
      return;
    }

    if (type.startsWith('item.')) {
      final item = event['item'];
      if (item is Map) {
        final itemType = item['type'] as String?;
        if (itemType == 'reasoning') {
          final raw = (item['text'] as Object?)?.toString() ?? '';
          final oneLine = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
          if (oneLine.isNotEmpty && isRunning.value) {
            thinkingPreview.value = oneLine.length > 160
                ? '${oneLine.substring(0, 160)}…'
                : oneLine;
          }
          return;
        }
        if (type == 'item.started') {
          // Reduce noise: started items are typically intermediate state.
          return;
        }
        if (itemType == 'agent_message') {
          final text = item['text'] as String? ?? '';
          final itemId = item['id']?.toString();
          if (itemId != null && itemId.isNotEmpty) {
            if (_seenAgentMessageItemIds.contains(itemId)) return;
            _seenAgentMessageItemIds.add(itemId);
          }
          final messages = await _materializeAgentMessage(
            text,
            replay: false,
            sourceItemId: itemId,
          );
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
    String? sourceItemId,
  }) async {
    // With --output-schema, agent_message should be a JSON object matching it.
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        final resp = CodexStructuredResponse.fromJson(
          decoded.cast<String, Object?>(),
        );

        final out = <Message>[
          Message.text(
            id: _uuid.v4(),
            authorId: _codex,
            createdAt: DateTime.now().toUtc(),
            text: resp.message.isEmpty ? '(empty response)' : resp.message,
          ),
        ];

        if (resp.images.isNotEmpty) {
          out.add(
            Message.custom(
              id: _uuid.v4(),
              authorId: _codex,
              createdAt: DateTime.now().toUtc(),
              metadata: {
                'kind': 'codex_image_grid',
                'images': resp.images
                    .map(
                      (img) => {
                        'path': img.path.trim(),
                        if (img.caption.trim().isNotEmpty)
                          'caption': img.caption.trim(),
                        'status': 'tap_to_load',
                      },
                    )
                    .where(
                      (m) => (m['path']?.toString().trim() ?? '').isNotEmpty,
                    )
                    .toList(growable: false),
              },
            ),
          );
        }

        final commitMessage = resp.commitMessage.trim();
        out.add(
          _eventMessage(
            type: 'commit_message',
            text: commitMessage.isEmpty
                ? '(empty commit_message)'
                : commitMessage,
          ),
        );

        if (resp.actions.isNotEmpty) {
          final actionsMessage =
              Message.custom(
                    id: _uuid.v4(),
                    authorId: _codex,
                    createdAt: DateTime.now().toUtc(),
                    metadata: {
                      'kind': 'codex_actions',
                      'actions': resp.actions
                          .map(
                            (a) => {
                              'id': a.id,
                              'label': a.label,
                              'value': a.value,
                            },
                          )
                          .toList(),
                    },
                  )
                  as CustomMessage;
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

    if (type == _clientUserMessageType) {
      final text = event['text']?.toString() ?? '';
      final messageId = event['message_id']?.toString().trim() ?? '';
      final createdAtMs = event['created_at_ms_utc'];
      final createdAt = createdAtMs is int
          ? DateTime.fromMillisecondsSinceEpoch(createdAtMs, isUtc: true)
          : DateTime.now().toUtc();
      if (messageId.isNotEmpty &&
          chatController.messages.any((m) => m.id == messageId)) {
        return const [];
      }
      return [
        Message.text(
          id: messageId.isNotEmpty ? messageId : _uuid.v4(),
          authorId: _me,
          createdAt: createdAt,
          text: text,
        ),
      ];
    }

    if (type == _clientGitCommitType) {
      final status = event['status']?.toString().trim() ?? '';
      final msg = event['commit_message']?.toString().trim() ?? '';
      final reason = event['reason']?.toString().trim() ?? '';
      final stderr = event['stderr']?.toString().trim() ?? '';

      final summary = [
        if (status.isNotEmpty) status,
        if (reason.isNotEmpty) reason,
        if (msg.isNotEmpty) msg,
        if (stderr.isNotEmpty && (status == 'failed')) stderr,
      ].join(' • ');

      return [
        _eventMessage(
          type: 'git_commit',
          text: summary.isEmpty ? 'Auto-commit event.' : summary,
        ),
      ];
    }

    if (type == _serverGitCommitType) {
      final status = event['status']?.toString().trim() ?? '';
      final reason = event['reason']?.toString().trim() ?? '';
      final b64 = event['commit_message_b64']?.toString().trim() ?? '';

      String msg = '';
      if (b64.isNotEmpty) {
        try {
          msg = utf8.decode(base64.decode(b64)).trim();
        } catch (_) {}
      }

      final summary = [
        'server',
        if (status.isNotEmpty) status,
        if (reason.isNotEmpty) reason,
        if (msg.isNotEmpty) msg,
      ].join(' • ');

      return [
        _eventMessage(
          type: 'git_commit',
          text: summary.isEmpty ? 'Server auto-commit event.' : summary,
        ),
      ];
    }

    if (type == _serverGitignoreBootstrapType) {
      final status = event['status']?.toString().trim() ?? '';
      final summary = [
        'server',
        'gitignore',
        if (status.isNotEmpty) status,
      ].join(' • ');
      return [
        _eventMessage(
          type: 'gitignore_bootstrap',
          text: summary.isEmpty ? 'Server gitignore bootstrap.' : summary,
        ),
      ];
    }

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
            tabId: tabId,
          );
        }
      }
      return const [];
    }

    if (type == 'turn.started' ||
        type == 'turn.completed' ||
        type == 'turn.failed') {
      if (type == 'turn.failed') {
        final err = event['error']?.toString();
        final trimmed = err?.trim();
        return [
          _eventMessage(
            type: 'turn.failed',
            text: trimmed == null || trimmed.isEmpty ? 'Turn failed.' : trimmed,
          ),
        ];
      }
      return const [];
    }

    if (type.startsWith('item.')) {
      final item = event['item'];
      if (item is Map) {
        if (type == 'item.started') return const [];
        final itemType = item['type'] as String? ?? 'unknown';
        if (itemType == 'reasoning') return const [];
        if (itemType == 'agent_message') {
          final text = item['text'] as String? ?? '';
          final itemId = item['id']?.toString();
          if (itemId != null && itemId.isNotEmpty) {
            if (_seenAgentMessageItemIds.contains(itemId)) return const [];
            _seenAgentMessageItemIds.add(itemId);
          }
          return _materializeAgentMessage(
            text,
            replay: replay,
            sourceItemId: itemId,
          );
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

  Future<void> _maybeAutoCommit(
    String commitMessage, {
    String? sourceItemId,
  }) async {
    final trimmed = commitMessage.trim();
    if (trimmed.isEmpty) return;

    try {
      if (target.local) {
        await _maybeAutoCommitLocal(trimmed, sourceItemId: sourceItemId);
      } else {
        await _maybeAutoCommitRemote(trimmed, sourceItemId: sourceItemId);
      }
    } catch (e) {
      await _insertEvent(type: 'git_commit_failed', text: '$e');
      try {
        await _appendClientJsonlToLog(
          jsonlLine: _clientGitCommitJsonlLine(
            status: 'failed',
            commitMessage: trimmed,
            stderr: '$e',
            sourceItemId: sourceItemId,
          ),
        );
      } catch (_) {}
    }
  }

  Future<void> _maybeAutoCommitLocal(
    String commitMessage, {
    String? sourceItemId,
  }) async {
    await _ensureFieldExecExcludedLocal();

    await _appendClientJsonlToLog(
      jsonlLine: _clientGitCommitJsonlLine(
        status: 'started',
        commitMessage: commitMessage,
        sourceItemId: sourceItemId,
      ),
    );

    final status = await _localShell.run(
      executable: 'git',
      arguments: const ['status', '--porcelain'],
      workingDirectory: projectPath,
      throwOnError: false,
    );

    if (status.exitCode != 0) {
      final err = (status.stderr as Object?).toString().trim();
      await _insertEvent(
        type: 'git_commit_failed',
        text: err.isEmpty ? 'git status failed.' : err,
      );
      await _appendClientJsonlToLog(
        jsonlLine: _clientGitCommitJsonlLine(
          status: 'failed',
          commitMessage: commitMessage,
          reason: 'git_status_failed',
          stderr: err,
          sourceItemId: sourceItemId,
        ),
      );
      return;
    }

    final changes = (status.stdout as Object?).toString().trim();
    if (changes.isEmpty) {
      await _insertEvent(
        type: 'git_commit_skipped',
        text: 'No changes to commit.',
      );
      await _appendClientJsonlToLog(
        jsonlLine: _clientGitCommitJsonlLine(
          status: 'skipped',
          commitMessage: commitMessage,
          reason: 'no_changes',
          sourceItemId: sourceItemId,
        ),
      );
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
    if (out.isNotEmpty) {
      await _insertEvent(type: 'git_commit_stdout', text: out);
    }
    if (err.isNotEmpty) {
      await _insertEvent(type: 'git_commit_stderr', text: err);
    }

    await _appendClientJsonlToLog(
      jsonlLine: _clientGitCommitJsonlLine(
        status: 'completed',
        commitMessage: commitMessage,
        stdout: out,
        stderr: err,
        sourceItemId: sourceItemId,
      ),
    );
  }

  Future<void> _maybeAutoCommitRemote(
    String commitMessage, {
    String? sourceItemId,
  }) async {
    final profile = target.profile!;
    final pem = await _storage.read(
      key: SecureStorageService.sshPrivateKeyPemKey,
    );

    String? password = _sshPassword;

    Future<SshCommandResult> runWithResult(String cmd) async {
      try {
        return await _ssh.runCommandWithResult(
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
          return _ssh.runCommandWithResult(
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

    await _appendClientJsonlToLog(
      jsonlLine: _clientGitCommitJsonlLine(
        status: 'started',
        commitMessage: commitMessage,
        sourceItemId: sourceItemId,
      ),
    );

    final cd = _shQuote(projectPath);
    await runWithResult(
      'cd $cd && if [ -d .git ]; then mkdir -p .git/info; touch .git/info/exclude; grep -qxF ${_shQuote('.field_exec/')} .git/info/exclude || printf %s\\\\n ${_shQuote('.field_exec/')} >> .git/info/exclude; fi',
    );
    final statusRes = await runWithResult('cd $cd && git status --porcelain');
    final statusOut = statusRes.stdout.trim();
    if ((statusRes.exitCode ?? 1) != 0) {
      final err = statusRes.stderr.trim();
      await _insertEvent(
        type: 'git_commit_failed',
        text: err.isEmpty ? 'git status failed.' : err,
      );
      await _appendClientJsonlToLog(
        jsonlLine: _clientGitCommitJsonlLine(
          status: 'failed',
          commitMessage: commitMessage,
          reason: 'git_status_failed',
          stderr: err,
          sourceItemId: sourceItemId,
        ),
      );
      return;
    }
    if (statusOut.isEmpty) {
      await _insertEvent(
        type: 'git_commit_skipped',
        text: 'No changes to commit.',
      );
      await _appendClientJsonlToLog(
        jsonlLine: _clientGitCommitJsonlLine(
          status: 'skipped',
          commitMessage: commitMessage,
          reason: 'no_changes',
          sourceItemId: sourceItemId,
        ),
      );
      return;
    }

    final msg = _shQuote(commitMessage);
    final commitRes = await runWithResult(
      'cd $cd && git add -A && git commit -m $msg',
    );
    final out = commitRes.stdout.trim();
    final err = commitRes.stderr.trim();
    if (out.isNotEmpty) {
      await _insertEvent(type: 'git_commit_stdout', text: out);
    }
    if (err.isNotEmpty) {
      await _insertEvent(type: 'git_commit_stderr', text: err);
    }
    await _appendClientJsonlToLog(
      jsonlLine: _clientGitCommitJsonlLine(
        status: (commitRes.exitCode ?? 1) == 0 ? 'completed' : 'failed',
        commitMessage: commitMessage,
        stdout: out,
        stderr: err,
        sourceItemId: sourceItemId,
      ),
    );
  }

  static String _shQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

  static String _wrapWithShell(ConnectionProfile profile, String body) {
    switch (profile.shell) {
      case PosixShell.sh:
        return 'sh -c ${_shQuote(body)}';
      case PosixShell.bash:
        return 'bash --noprofile --norc -c ${_shQuote(body)}';
      case PosixShell.zsh:
        return 'zsh -f -c ${_shQuote(body)}';
      case PosixShell.fizsh:
        return 'fizsh -f -c ${_shQuote(body)}';
    }
  }

  Future<void> _ensureFieldExecExcludedLocal() async {
    // Best-effort: support running from subdirectories and worktrees.
    try {
      final top = await _localShell.run(
        executable: 'git',
        arguments: const ['rev-parse', '--show-toplevel'],
        workingDirectory: projectPath,
        throwOnError: false,
      );
      if (top.exitCode != 0) return;
      final root = (top.stdout as Object?)?.toString().trim() ?? '';
      if (root.isEmpty) return;

      final pathRes = await _localShell.run(
        executable: 'git',
        arguments: const ['rev-parse', '--git-path', 'info/exclude'],
        workingDirectory: projectPath,
        throwOnError: false,
      );
      if (pathRes.exitCode != 0) return;
      final raw = (pathRes.stdout as Object?)?.toString().trim() ?? '';
      if (raw.isEmpty) return;

      final abs = raw.startsWith('/') ? raw : _joinPosix(root, raw);
      final excludeFile = File(abs);
      await excludeFile.parent.create(recursive: true);

      final existing = await excludeFile.exists()
          ? await excludeFile.readAsString()
          : '';
      const line = '**/.field_exec/';
      if (existing.split('\n').any((l) => l.trim() == line)) return;

      final needsNewline = existing.isNotEmpty && !existing.endsWith('\n');
      await excludeFile.writeAsString(
        "${needsNewline ? '\n' : ''}$line\n",
        mode: FileMode.append,
      );
    } catch (_) {}
  }

  Future<void> _ensureFieldExecIgnoredInGitignoreLocal() async {
    // Best-effort: only applies to git repos and should never block a turn.
    try {
      final res = await _localShell.run(
        executable: 'git',
        arguments: const ['rev-parse', '--show-toplevel'],
        workingDirectory: projectPath,
        throwOnError: false,
      );
      if (res.exitCode != 0) return;
      final root = (res.stdout as Object?)?.toString().trim() ?? '';
      if (root.isEmpty) return;

      final ignoreFile = File(_joinPosix(root, '.gitignore'));
      final existing = await ignoreFile.exists()
          ? await ignoreFile.readAsString()
          : '';
      const line = '**/.field_exec/';
      if (existing.split('\n').any((l) => l.trim() == line)) return;

      final beforeStatus = await _localShell.run(
        executable: 'git',
        arguments: const ['status', '--porcelain'],
        workingDirectory: root,
        throwOnError: false,
      );
      final wasClean =
          beforeStatus.exitCode == 0 &&
          ((beforeStatus.stdout as Object?)?.toString().trim() ?? '').isEmpty;

      final needsNewline = existing.isNotEmpty && !existing.endsWith('\n');
      await ignoreFile.writeAsString(
        "${needsNewline ? '\n' : ''}$line\n",
        mode: FileMode.append,
      );

      if (wasClean) {
        await _localShell.run(
          executable: 'git',
          arguments: const ['add', '.gitignore'],
          workingDirectory: root,
          throwOnError: false,
        );
        final commit = await _localShell.run(
          executable: 'git',
          arguments: const ['commit', '-m', 'chore: ignore .field_exec'],
          workingDirectory: root,
          throwOnError: false,
        );
        if (commit.exitCode == 0) {
          await _insertEvent(
            type: 'gitignore_bootstrap',
            text: 'Committed .gitignore to ignore .field_exec.',
          );
        } else {
          await _insertEvent(
            type: 'gitignore_bootstrap',
            text: 'Updated .gitignore to ignore .field_exec.',
          );
        }
      } else {
        await _insertEvent(
          type: 'gitignore_bootstrap',
          text: 'Updated .gitignore to ignore .field_exec.',
        );
      }
    } catch (_) {}
  }

  Future<void> _insertEvent({
    required String type,
    required String text,
  }) async {
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
      metadata: {'kind': 'codex_event', 'eventType': type, 'text': text},
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
        final cmd =
            item['command']?.toString() ?? item['text']?.toString() ?? '';
        final code = item['exit_code']?.toString();
        if (cmd.trim().isEmpty) {
          return code == null ? 'Command' : 'Command (exit=$code)';
        }
        return code == null ? cmd : '$cmd (exit=$code)';
      case 'file_change':
        final path = item['path']?.toString() ?? '';
        final summary = item['summary']?.toString() ?? '';
        if (summary.isNotEmpty && path.isNotEmpty) return '$summary — $path';
        if (path.isNotEmpty) return path;
        return 'File change';
      case 'mcp_tool_call':
        final tool = item['tool']?.toString() ?? 'mcp';
        final topic = item['topic']?.toString() ?? '';
        return topic.isEmpty ? tool : '$tool: $topic';
      case 'web_search':
        final query = item['query']?.toString() ?? '';
        return query.isEmpty ? 'Web search' : 'Search: $query';
      case 'todo_list':
        final items = item['items'];
        if (items is List) {
          final lines = <String>[];
          for (final entry in items.whereType<Map>()) {
            final text = entry['text']?.toString() ?? '';
            if (text.trim().isEmpty) continue;
            final completed = entry['completed'] == true;
            lines.add('${completed ? "[x]" : "[ ]"} $text');
          }
          if (lines.isNotEmpty) return lines.join('\n');
        }
        return (item['text'] as String?) ?? 'Todo list';
      default:
        final text = item['text']?.toString() ?? '';
        if (text.isNotEmpty) return text;
        final message = item['message']?.toString() ?? '';
        if (message.isNotEmpty) return message;
        return itemType ?? 'item';
    }
  }

  static String _compact(Map<String, Object?> map) {
    final copy = Map<String, Object?>.from(map);
    copy.remove('item');
    return copy.toString();
  }
}
