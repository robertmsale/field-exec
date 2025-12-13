import 'dart:io';

import 'package:flutter/material.dart';
import 'package:design_system/design_system.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import '../../services/active_session_service.dart';
import '../../services/conversation_store.dart';
import '../../services/codex_session_store.dart';
import '../../services/project_tabs_store.dart';
import '../../services/secure_storage_service.dart';
import '../../services/ssh_service.dart';
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

  CodexSessionStore get _store => Get.find<CodexSessionStore>();
  ProjectTabsStore get _tabsStore => Get.find<ProjectTabsStore>();
  ConversationStore get _conversations => Get.find<ConversationStore>();
  ActiveSessionService get _active => Get.find<ActiveSessionService>();
  SecureStorageService get _storage => Get.find<SecureStorageService>();
  SshService get _ssh => Get.find<SshService>();

  @override
  void onInit() {
    super.onInit();
    _load();
    _activeWorker1 = ever<int>(activeIndex, (_) => _updateActiveSession());
    _activeWorker2 = ever<List<ProjectTab>>(tabs, (_) => _updateActiveSession());
    _updateActiveSession();
  }

  @override
  void onClose() {
    _activeWorker1?.dispose();
    _activeWorker2?.dispose();
    _active.setActive(null);
    super.onClose();
  }

  String _sessionTag(String tabId) => '${args.target.targetKey}|${args.project.path}|$tabId';

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
    Get.delete<SessionController>(tag: _sessionTag(tab.id), force: true);

    if (tabs.isEmpty) {
      await addTab();
      return;
    }
    if (activeIndex.value >= tabs.length) {
      activeIndex.value = tabs.length - 1;
    }

    await _tabsStore.saveTabs(
      targetKey: args.target.targetKey,
      projectPath: args.project.path,
      tabs: tabs.toList(growable: false),
    );
  }

  @override
  Future<List<Conversation>> loadConversations() async {
    return _conversations.load(
      targetKey: args.target.targetKey,
      projectPath: args.project.path,
    );
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
      final res = await Process.run(
        '/bin/sh',
        ['-c', cmd],
        workingDirectory: args.project.path,
      );
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

    final pem = await _storage.read(key: SecureStorageService.sshPrivateKeyPemKey);
    if (pem == null || pem.trim().isEmpty) {
      return const RunCommandResult(
        exitCode: 1,
        stdout: '',
        stderr: 'No SSH private key set. Add one in Settings.',
      );
    }

    final remoteCmd = 'cd ${_shQuote(args.project.path)} && $cmd';

    Future<SshCommandResult> runOnce({String? password}) {
      return _ssh.runCommandWithResult(
        host: profile.host,
        port: profile.port,
        username: profile.username,
        privateKeyPem: pem,
        password: password,
        command: 'sh -c ${_shQuote(remoteCmd)}',
      );
    }

    SshCommandResult result;
    try {
      result = await runOnce(password: _sshPassword);
    } catch (_) {
      if (_sshPassword == null) {
        final pw = await _promptForPassword();
        if (pw == null || pw.isEmpty) rethrow;
        _sshPassword = pw;
        result = await runOnce(password: _sshPassword);
      } else {
        rethrow;
      }
    }

    return RunCommandResult(
      exitCode: result.exitCode ?? -1,
      stdout: result.stdout,
      stderr: result.stderr,
    );
  }
}
