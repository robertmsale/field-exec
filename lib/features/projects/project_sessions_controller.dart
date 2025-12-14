import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:design_system/design_system.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import '../../services/active_session_service.dart';
import '../../services/conversation_store.dart';
import '../../services/field_exec_session_store.dart';
import '../../services/project_tabs_store.dart';
import '../../rinf/rust_ssh_service.dart';
import '../session/session_controller.dart';

class ProjectSessionsController extends ProjectSessionsControllerBase {
  @override
  final ProjectArgs args;

  ProjectSessionsController({required this.args});

  @override
  final tabs = <ProjectTab>[].obs;
  @override
  final activeIndex = 0.obs;
  @override
  final isReady = false.obs;

  final _uuid = const Uuid();
  String? _sshPassword;
  Worker? _activeWorker1;
  Worker? _activeWorker2;

  FieldExecSessionStore get _store => Get.find<FieldExecSessionStore>();
  ProjectTabsStore get _tabsStore => Get.find<ProjectTabsStore>();
  ConversationStore get _conversations => Get.find<ConversationStore>();
  ActiveSessionService get _active => Get.find<ActiveSessionService>();

  @override
  void onInit() {
    super.onInit();
    _load();
    _activeWorker1 = ever<int>(activeIndex, (_) => _updateActiveSession());
    _activeWorker2 = ever<List<ProjectTab>>(
      tabs,
      (_) => _updateActiveSession(),
    );
    _updateActiveSession();
  }

  @override
  void onClose() {
    _activeWorker1?.dispose();
    _activeWorker2?.dispose();
    _active.setActive(null);
    super.onClose();
  }

  String _sessionTag(String tabId) =>
      '${args.target.targetKey}|${args.project.path}|$tabId';

  @override
  SessionControllerBase sessionForTab(ProjectTab tab) {
    return Get.find<SessionController>(tag: _sessionTag(tab.id));
  }

  void _updateActiveSession() {
    final items = tabs;
    if (items.isEmpty) {
      _active.setActive(null);
      return;
    }
    final idx = activeIndex.value.clamp(0, items.length - 1);
    final tab = items[idx];
    _active.setActive(
      ActiveSessionRef(
        targetKey: args.target.targetKey,
        projectPath: args.project.path,
        tabId: tab.id,
      ),
    );
  }

  Future<void> _load() async {
    final loaded = await _tabsStore.loadTabs(
      targetKey: args.target.targetKey,
      projectPath: args.project.path,
    );

    if (loaded.isEmpty) {
      final id = _uuid.v4();
      final initial = [ProjectTab(id: id, title: 'Tab 1')];
      tabs.assignAll(initial);
      _ensureSessionControllers();
      await _tabsStore.saveTabs(
        targetKey: args.target.targetKey,
        projectPath: args.project.path,
        tabs: tabs.toList(growable: false),
      );
    } else {
      tabs.assignAll(loaded);
      _ensureSessionControllers();
    }

    isReady.value = true;
  }

  void _ensureSessionControllers() {
    for (final tab in tabs) {
      final tag = _sessionTag(tab.id);
      if (Get.isRegistered<SessionController>(tag: tag)) continue;
      Get.put(
        SessionController(
          target: args.target,
          projectPath: args.project.path,
          tabId: tab.id,
        ),
        tag: tag,
        permanent: true,
      );
    }
  }

  @override
  Future<void> addTab() async {
    final id = _uuid.v4();
    final title = 'Tab ${tabs.length + 1}';
    final tab = ProjectTab(id: id, title: title);

    final tag = _sessionTag(id);
    Get.put(
      SessionController(
        target: args.target,
        projectPath: args.project.path,
        tabId: id,
      ),
      tag: tag,
      permanent: true,
    );

    tabs.add(tab);
    activeIndex.value = tabs.length - 1;

    await _tabsStore.saveTabs(
      targetKey: args.target.targetKey,
      projectPath: args.project.path,
      tabs: tabs.toList(growable: false),
    );
  }

  @override
  Future<void> closeTab(ProjectTab tab) async {
    final idx = tabs.indexWhere((t) => t.id == tab.id);
    if (idx == -1) return;

    // If this is the last remaining tab, don't remove it. Just clear the chat
    // and thread so it behaves like starting a brand new session.
    if (tabs.length <= 1) {
      final session = sessionForTab(tab);
      await session.resetSession();
      return;
    }

    // Move selection away from the closing tab first to avoid transient builds
    // that still reference the soon-to-be-disposed SessionController.
    final wasActive = activeIndex.value == idx;
    if (wasActive) {
      activeIndex.value = (idx - 1).clamp(0, tabs.length - 1);
    } else if (activeIndex.value > idx) {
      activeIndex.value = (activeIndex.value - 1).clamp(0, tabs.length - 2);
    }

    tabs.removeAt(idx);

    await _store.clearThreadId(
      targetKey: args.target.targetKey,
      projectPath: args.project.path,
      tabId: tab.id,
    );
    await _store.clearRemoteJobId(
      targetKey: args.target.targetKey,
      projectPath: args.project.path,
      tabId: tab.id,
    );

    // Dispose the SessionController after the UI has had a chance to rebuild
    // without this tab to avoid "TextEditingController used after dispose".
    SchedulerBinding.instance.addPostFrameCallback((_) {
      try {
        Get.delete<SessionController>(tag: _sessionTag(tab.id), force: true);
      } catch (_) {}
    });

    await _tabsStore.saveTabs(
      targetKey: args.target.targetKey,
      projectPath: args.project.path,
      tabs: tabs.toList(growable: false),
    );
  }

  @override
  Future<void> renameTab(ProjectTab tab, String title) async {
    final nextTitle = title.trim();
    if (nextTitle.isEmpty) return;

    final idx = tabs.indexWhere((t) => t.id == tab.id);
    if (idx == -1) return;

    tabs[idx] = ProjectTab(id: tab.id, title: nextTitle);

    await _tabsStore.saveTabs(
      targetKey: args.target.targetKey,
      projectPath: args.project.path,
      tabs: tabs.toList(growable: false),
    );
  }

  @override
  Future<List<Conversation>> loadConversations() async {
    final stored = await _conversations.load(
      targetKey: args.target.targetKey,
      projectPath: args.project.path,
    );
    final discovered = await _discoverConversationsFromLogs();

    // Merge by thread id, preferring the most recently used.
    final map = <String, Conversation>{};
    for (final c in [...stored, ...discovered]) {
      if (c.threadId.isEmpty) continue;
      final prev = map[c.threadId];
      if (prev == null ||
          (prev.tabId.isEmpty && c.tabId.isNotEmpty) ||
          c.lastUsedAtMs > prev.lastUsedAtMs) {
        map[c.threadId] = c;
      }
    }
    final out = map.values.toList(growable: false);
    out.sort((a, b) => b.lastUsedAtMs.compareTo(a.lastUsedAtMs));
    return out;
  }

  Future<List<Conversation>> _discoverConversationsFromLogs() async {
    if (!args.target.local) {
      return _discoverConversationsFromRemoteLogs();
    }
    if (!Platform.isMacOS) return const [];

    final sessionsDir = Directory('${args.project.path}/.field_exec/sessions');
    if (!await sessionsDir.exists()) return const [];

    final entries = await sessionsDir.list(followLinks: false).toList();
    final logs = entries.whereType<File>().where((f) {
      final name = f.path.split('/').last;
      return name.endsWith('.log') && !name.endsWith('.stderr.log');
    }).toList();

    logs.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));

    final out = <Conversation>[];
    for (final f in logs.take(200)) {
      try {
        final tabId = f.path.split('/').last.replaceAll('.log', '');
        if (tabId.isEmpty) continue;

        final lastUsed = f.lastModifiedSync().millisecondsSinceEpoch;
        final head = await _readHeadUtf8(f, maxBytes: 80 * 1024);
        final tail = await _readTailUtf8(f, maxBytes: 200 * 1024);
        final parsed = _parseThreadAndPreviewFromJsonl(head: head, tail: tail);
        final threadId = parsed.threadId;
        if (threadId.isEmpty) continue;

        out.add(
          Conversation(
            threadId: threadId,
            preview: parsed.preview,
            tabId: tabId,
            createdAtMs: lastUsed,
            lastUsedAtMs: lastUsed,
          ),
        );
      } catch (_) {}
    }
    return out;
  }

  Future<List<Conversation>> _discoverConversationsFromRemoteLogs() async {
    if (args.target.profile == null) return const [];

    // Single remote command to keep SSH overhead low. Emit markers and raw JSONL
    // so parsing/JSON decoding happens locally (handles proper escaping).
    const begin = '__FIELD_EXEC_LOG_BEGIN__';
    const tail = '__FIELD_EXEC_LOG_TAIL__';
    const end = '__FIELD_EXEC_LOG_END__';

    final script =
        '''
DIR=".field_exec/sessions"
files=\$(ls -t "\$DIR"/*.log 2>/dev/null | grep -v '\\\\.stderr\\\\.log\$' | head -n 80 || true)
printf "%s\\n" "\$files" | while IFS= read -r f; do
  [ -f "\$f" ] || continue
  tab=\$(basename "\$f" .log)
  m=\$(stat -f %m "\$f" 2>/dev/null || stat -c %Y "\$f" 2>/dev/null || echo 0)
  printf "$begin\\t%s\\t%s\\n" "\$tab" "\$m"
  head -n 60 "\$f" 2>/dev/null || true
  printf "$tail\\n"
  tail -n 120 "\$f" 2>/dev/null || true
  printf "$end\\n"
done
''';

    RunCommandResult res;
    try {
      res = await runShellCommand(script);
    } catch (_) {
      return const [];
    }
    if (res.stdout.trim().isEmpty) return const [];

    final out = <Conversation>[];
    String? activeTabId;
    int activeMtimeSec = 0;
    var inTail = false;
    var headBuf = StringBuffer();
    var tailBuf = StringBuffer();

    void flush() {
      final tabId = activeTabId;
      if (tabId == null || tabId.isEmpty) return;
      final parsed = _parseThreadAndPreviewFromJsonl(
        head: headBuf.toString(),
        tail: tailBuf.toString(),
      );
      final threadId = parsed.threadId;
      if (threadId.isEmpty) return;
      final ms = activeMtimeSec > 0
          ? activeMtimeSec * 1000
          : DateTime.now().toUtc().millisecondsSinceEpoch;
      out.add(
        Conversation(
          threadId: threadId,
          preview: parsed.preview,
          tabId: tabId,
          createdAtMs: ms,
          lastUsedAtMs: ms,
        ),
      );
    }

    for (final line in const LineSplitter().convert(res.stdout)) {
      final l = line.trimRight();
      if (l.startsWith(begin)) {
        // Flush previous
        flush();
        headBuf = StringBuffer();
        tailBuf = StringBuffer();
        inTail = false;
        final parts = l.split('\t');
        activeTabId = parts.length >= 2 ? parts[1].trim() : '';
        activeMtimeSec = 0;
        if (parts.length >= 3) {
          activeMtimeSec = int.tryParse(parts[2].trim()) ?? 0;
        }
        continue;
      }
      if (l == tail) {
        inTail = true;
        continue;
      }
      if (l == end) {
        flush();
        activeTabId = null;
        activeMtimeSec = 0;
        headBuf = StringBuffer();
        tailBuf = StringBuffer();
        inTail = false;
        continue;
      }
      if (activeTabId == null) continue;
      if (inTail) {
        tailBuf.writeln(l);
      } else {
        headBuf.writeln(l);
      }
    }
    // Flush trailing file if end marker missing.
    flush();

    out.sort((a, b) => b.lastUsedAtMs.compareTo(a.lastUsedAtMs));
    return out;
  }

  static Future<String> _readHeadUtf8(
    File file, {
    required int maxBytes,
  }) async {
    final raf = await file.open();
    try {
      final len = await raf.length();
      final readLen = len > maxBytes ? maxBytes : len;
      await raf.setPosition(0);
      final bytes = await raf.read(readLen);
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      await raf.close();
    }
  }

  static Future<String> _readTailUtf8(
    File file, {
    required int maxBytes,
  }) async {
    final raf = await file.open();
    try {
      final len = await raf.length();
      final start = len > maxBytes ? (len - maxBytes) : 0;
      await raf.setPosition(start);
      final bytes = await raf.read(len - start);
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      await raf.close();
    }
  }

  static ({String threadId, String preview}) _parseThreadAndPreviewFromJsonl({
    required String head,
    required String tail,
  }) {
    String threadId = '';
    for (final line in const LineSplitter().convert(head)) {
      final l = line.trim();
      if (l.isEmpty) continue;
      try {
        final decoded = jsonDecode(l);
        if (decoded is! Map) continue;
        final map = decoded.cast<String, Object?>();
        if (map['type']?.toString() == 'thread.started') {
          threadId = map['thread_id']?.toString() ?? '';
          if (threadId.isNotEmpty) break;
        }
      } catch (_) {}
    }

    String preview = '';
    for (final line in const LineSplitter().convert(tail).reversed) {
      final l = line.trim();
      if (l.isEmpty) continue;
      try {
        final decoded = jsonDecode(l);
        if (decoded is! Map) continue;
        final map = decoded.cast<String, Object?>();
        if (map['type']?.toString() == 'client.user_message') {
          final t = map['text']?.toString() ?? '';
          final trimmed = t.trim();
          if (trimmed.isNotEmpty) {
            preview = trimmed.length > 80
                ? '${trimmed.substring(0, 80)}…'
                : trimmed;
            break;
          }
        }
      } catch (_) {}
    }

    return (threadId: threadId, preview: preview);
  }

  @override
  Future<void> openConversation(Conversation conversation) async {
    final tabId = conversation.tabId;
    if (tabId.isEmpty) {
      final items = tabs;
      if (items.isEmpty) return;
      final active = items[activeIndex.value.clamp(0, items.length - 1)];
      await sessionForTab(
        active,
      ).resumeThreadById(conversation.threadId, preview: conversation.preview);
      return;
    }

    final idx = tabs.indexWhere((t) => t.id == tabId);
    if (idx == -1) {
      final title = conversation.preview.isNotEmpty
          ? (conversation.preview.length > 18
                ? '${conversation.preview.substring(0, 18)}…'
                : conversation.preview)
          : (conversation.threadId.isNotEmpty
                ? conversation.threadId.substring(0, 8)
                : 'Tab ${tabs.length + 1}');
      final tab = ProjectTab(id: tabId, title: title);
      tabs.add(tab);
      _ensureSessionControllers();
      await _tabsStore.saveTabs(
        targetKey: args.target.targetKey,
        projectPath: args.project.path,
        tabs: tabs.toList(growable: false),
      );
      activeIndex.value = tabs.length - 1;
    } else {
      activeIndex.value = idx;
    }

    final active = tabs[activeIndex.value.clamp(0, tabs.length - 1)];
    final session = sessionForTab(active);

    // If this device has never used this tab before, populate the stored
    // remote job id from the project's `.field_exec` artifacts so we can
    // "latch onto" an in-progress tmux/nohup job and start tailing logs.
    if (!args.target.local) {
      final jobRelPath = '.field_exec/sessions/$tabId.job';
      try {
        final res = await runShellCommand(
          'if [ -f ${_shQuote(jobRelPath)} ]; then head -n 1 ${_shQuote(jobRelPath)}; fi',
        );
        final job = res.stdout.trim();
        if (job.isNotEmpty) {
          await _store.saveRemoteJobId(
            targetKey: args.target.targetKey,
            projectPath: args.project.path,
            tabId: tabId,
            remoteJobId: job,
          );
        }
      } catch (_) {}
    }

    await session.resumeThreadById(
      conversation.threadId,
      preview: conversation.preview,
    );
    await session.reattachIfNeeded(backfillLines: 200);
  }

  @override
  String runCommandHint() {
    final p = args.project.path;
    return args.target.local ? 'Runs in $p' : 'Runs in $p (remote)';
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
              child: const Text('Run'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  static String _shQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

  static String _wrapWithShell(PosixShell shell, String body) {
    switch (shell) {
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

  @override
  Future<RunCommandResult> runShellCommand(String command) async {
    final cmd = command.trim();
    if (cmd.isEmpty) {
      throw ArgumentError('Command is empty.');
    }

    if (args.target.local) {
      if (!Platform.isMacOS) {
        return const RunCommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'Local mode is only supported on macOS.',
        );
      }
      final res = await Process.run('/bin/sh', [
        '-c',
        cmd,
      ], workingDirectory: args.project.path);
      return RunCommandResult(
        exitCode: res.exitCode,
        stdout: (res.stdout as Object?)?.toString() ?? '',
        stderr: (res.stderr as Object?)?.toString() ?? '',
      );
    }

    final profile = args.target.profile;
    if (profile == null) {
      return const RunCommandResult(
        exitCode: 1,
        stdout: '',
        stderr: 'Missing remote connection profile.',
      );
    }

    final remoteCmd = 'cd ${_shQuote(args.project.path)} && $cmd';

    const timeout = Duration(seconds: 60);
    try {
      final res = await RustSshService.runCommandWithResult(
        host: profile.host,
        port: profile.port,
        username: profile.username,
        command: _wrapWithShell(profile.shell, remoteCmd),
        connectTimeout: const Duration(seconds: 10),
        commandTimeout: timeout,
        passwordProvider: () async {
          if (_sshPassword != null && _sshPassword!.trim().isNotEmpty) {
            return _sshPassword;
          }
          final pw = await _promptForPassword();
          if (pw != null && pw.trim().isNotEmpty) _sshPassword = pw;
          return pw;
        },
      );

      return RunCommandResult(
        exitCode: res.exitCode,
        stdout: res.stdout,
        stderr: res.stderr,
      );
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('timeout')) {
        return const RunCommandResult(
          exitCode: 124,
          stdout: '',
          stderr: 'Command timed out after 60 seconds.',
        );
      }
      return RunCommandResult(
        exitCode: 1,
        stdout: '',
        stderr: 'SSH failed: $e',
      );
    }
  }
}
