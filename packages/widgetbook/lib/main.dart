import 'dart:convert';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';
import 'package:widgetbook/widgetbook.dart';

void main() {
  runApp(const FieldExecWidgetbookApp());
}

class FieldExecWidgetbookApp extends StatelessWidget {
  const FieldExecWidgetbookApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Widgetbook.material(
      addons: [
        ViewportAddon([
          Viewports.none,
          MacosViewports.macbookPro,
          IosViewports.iPhone13,
          AndroidViewports.samsungGalaxyNote20,
          WindowsViewports.desktop,
          LinuxViewports.desktop,
        ]),
        MaterialThemeAddon(
          themes: [
            WidgetbookTheme(name: 'Light', data: DesignSystemThemes.light()),
            WidgetbookTheme(name: 'Dark', data: DesignSystemThemes.dark()),
          ],
        ),
      ],
      directories: [
        WidgetbookCategory(
          name: 'Pages',
          children: [
            WidgetbookComponent(
              name: 'ConnectionPage',
              useCases: [
                WidgetbookUseCase(
                  name: 'Default',
                  builder: (context) {
                    _putConnection();
                    return const ConnectionPage();
                  },
                ),
              ],
            ),
            WidgetbookComponent(
              name: 'ProjectsPage',
              useCases: [
                WidgetbookUseCase(
                  name: 'Local',
                  builder: (context) {
                    _putProjects(target: const TargetArgs.local());
                    return const ProjectsPage();
                  },
                ),
                WidgetbookUseCase(
                  name: 'Remote',
                  builder: (context) {
                    _putProjects(
                      target: TargetArgs.remote(
                        ConnectionProfile(
                          userAtHost: 'robert@mac.local',
                          port: 22,
                        ),
                      ),
                    );
                    return const ProjectsPage();
                  },
                ),
              ],
            ),
            WidgetbookComponent(
              name: 'ProjectSessionsPage',
              useCases: [
                WidgetbookUseCase(
                  name: 'Default',
                  builder: (context) {
                    _putProjectSessions(args: _demoProjectArgs);
                    return const ProjectSessionsPage();
                  },
                ),
              ],
            ),
            WidgetbookComponent(
              name: 'GitToolsSheet',
              useCases: [
                WidgetbookUseCase(
                  name: 'Default',
                  builder: (context) {
                    return Scaffold(
                      body: Center(
                        child: FilledButton(
                          onPressed: () async {
                            await showModalBottomSheet<void>(
                              context: context,
                              isScrollControlled: true,
                              showDragHandle: true,
                              builder: (_) => GitToolsSheet(
                                projectPathLabel: '/Users/me/demo-repo',
                                run: _mockGitRunCommand,
                              ),
                            );
                          },
                          child: const Text('Open Git Sheet'),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
            WidgetbookComponent(
              name: 'GitCompareCommitsSheet',
              useCases: [
                WidgetbookUseCase(
                  name: 'Default',
                  builder: (context) {
                    return Scaffold(
                      body: Center(
                        child: FilledButton(
                          onPressed: () async {
                            await showModalBottomSheet<void>(
                              context: context,
                              isScrollControlled: true,
                              showDragHandle: true,
                              builder: (_) => GitCompareCommitsSheet(
                                run: _mockGitRunCommand,
                                worktreeLabel: 'main',
                                worktreePath: '/Users/me/demo-repo',
                              ),
                            );
                          },
                          child: const Text('Open Commit Compare'),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
            WidgetbookComponent(
              name: 'GitCompareWorktreesSheet',
              useCases: [
                WidgetbookUseCase(
                  name: 'Default',
                  builder: (context) {
                    return Scaffold(
                      body: Center(
                        child: FilledButton(
                          onPressed: () async {
                            await showModalBottomSheet<void>(
                              context: context,
                              isScrollControlled: true,
                              showDragHandle: true,
                              builder: (_) => GitCompareWorktreesSheet(
                                run: _mockGitRunCommand,
                                worktrees: const [
                                  GitWorktreeRef(
                                    label: 'main',
                                    path: '/Users/me/demo-repo',
                                  ),
                                  GitWorktreeRef(
                                    label: 'feature-x',
                                    path: '/Users/me/demo-repo-wt',
                                  ),
                                ],
                              ),
                            );
                          },
                          child: const Text('Open Worktree Compare'),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
            WidgetbookComponent(
              name: 'SettingsPage',
              useCases: [
                WidgetbookUseCase(
                  name: 'Default',
                  builder: (context) {
                    _putKeys();
                    _putInstallKey();
                    _putSettings();
                    return const SettingsPage();
                  },
                ),
              ],
            ),
            WidgetbookComponent(
              name: 'KeysPage',
              useCases: [
                WidgetbookUseCase(
                  name: 'Default',
                  builder: (context) {
                    _putKeys();
                    return const KeysPage();
                  },
                ),
              ],
            ),
            WidgetbookComponent(
              name: 'InstallKeyPage',
              useCases: [
                WidgetbookUseCase(
                  name: 'Default',
                  builder: (context) {
                    _putInstallKey();
                    return const InstallKeyPage();
                  },
                ),
              ],
            ),
          ],
        ),
      ],
      appBuilder: (context, child) {
        final theme = Theme.of(context);
        return GetMaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          themeMode: ThemeMode.light,
          initialBinding: WidgetbookBinding(),
          getPages: [
            GetPage(name: DesignRoutes.connect, page: ConnectionPage.new),
            GetPage(
              name: DesignRoutes.projects,
              page: ProjectsPage.new,
              binding: BindingsBuilder(() {
                final args = (Get.arguments is TargetArgs)
                    ? (Get.arguments as TargetArgs)
                    : const TargetArgs.local();
                _putProjects(target: args);
              }),
            ),
            GetPage(
              name: DesignRoutes.project,
              page: ProjectSessionsPage.new,
              binding: BindingsBuilder(() {
                final args = (Get.arguments is ProjectArgs)
                    ? (Get.arguments as ProjectArgs)
                    : _demoProjectArgs;
                _putProjectSessions(args: args);
              }),
            ),
            GetPage(name: DesignRoutes.settings, page: SettingsPage.new),
          ],
          home: child,
        );
      },
    );
  }
}

const _demoTarget = TargetArgs.local();
const _demoProject = Project(
  id: 'demo',
  path: '/Users/me/demo-repo',
  name: 'demo-repo',
);
const _demoProjectArgs = ProjectArgs(
  target: _demoTarget,
  project: _demoProject,
);

Future<RunCommandResult> _mockGitRunCommand(String command) async {
  final cmd = command.trim();
  if (cmd.contains('FIELDEXEC_GIT_BATCH_V2')) {
    return const RunCommandResult(
      exitCode: 0,
      stdout:
          '#FIELDEXEC_GIT_BATCH_V2\n'
          'WT\tL1VzZXJzL21lL2RlbW8tcmVwbw==\tZGVhZGJlZWZkZWFkYmVlZg==\tcmVmcy9oZWFkcy9tYWlu\t0\t1\n'
          'S\tL1VzZXJzL21lL2RlbW8tcmVwbw==\tIE0gbGliL21haW4uZGFydA==\n'
          'S\tL1VzZXJzL21lL2RlbW8tcmVwbw==\tPz8gbm90ZXMudHh0\n'
          'N\tL1VzZXJzL21lL2RlbW8tcmVwbw==\t0\t3\t1\tbGliL21haW4uZGFydA==\n'
          'N\tL1VzZXJzL21lL2RlbW8tcmVwbw==\t0\t1\t0\tbm90ZXMudHh0\n'
          'WT\tL1VzZXJzL21lL2RlbW8tcmVwby13dA==\tY2FmZWJhYmVjYWZlYmFiZQ==\tcmVmcy9oZWFkcy9mZWF0dXJlLXg=\t0\t0\n',
      stderr: '',
    );
  }
  if (cmd == 'git worktree list --porcelain') {
    return const RunCommandResult(
      exitCode: 0,
      stdout:
          'worktree /Users/me/demo-repo\nHEAD deadbeefdeadbeef\nbranch refs/heads/main\n\nworktree /Users/me/demo-repo-wt\nHEAD cafebabecafebabe\nbranch refs/heads/feature-x\n\n',
      stderr: '',
    );
  }

  if (cmd.contains('--no-pager log --oneline')) {
    return const RunCommandResult(
      exitCode: 0,
      stdout:
          'aaaa111 Fix: something (HEAD -> main)\nbbbb222 Add: thing\ncccc333 Init\n',
      stderr: '',
    );
  }

  if (cmd.contains('rev-parse HEAD')) {
    if (cmd.contains('/Users/me/demo-repo-wt')) {
      return const RunCommandResult(
        exitCode: 0,
        stdout: 'cafebabecafebabe\n',
        stderr: '',
      );
    }
    return const RunCommandResult(
      exitCode: 0,
      stdout: 'deadbeefdeadbeef\n',
      stderr: '',
    );
  }

  if (cmd.startsWith('git -C ') && cmd.endsWith(' status --porcelain')) {
    return const RunCommandResult(
      exitCode: 0,
      stdout: ' M lib/main.dart\n?? notes.txt\n',
      stderr: '',
    );
  }

  if (cmd.contains('--no-pager diff --numstat')) {
    if (cmd.contains('aaaa111..bbbb222') || cmd.contains('bbbb222..aaaa111')) {
      return const RunCommandResult(
        exitCode: 0,
        stdout: '10\t2\tlib/main.dart\n1\t0\tnotes.txt\n',
        stderr: '',
      );
    }
    if (cmd.contains('deadbeefdeadbeef..cafebabecafebabe')) {
      return const RunCommandResult(
        exitCode: 0,
        stdout: '5\t1\tlib/main.dart\n',
        stderr: '',
      );
    }
    return const RunCommandResult(
      exitCode: 0,
      stdout: '3\t1\tlib/main.dart\n',
      stderr: '',
    );
  }

  if (cmd.contains('--no-pager diff --name-status')) {
    if (cmd.contains('deadbeefdeadbeef..cafebabecafebabe')) {
      return const RunCommandResult(
        exitCode: 0,
        stdout: 'M\tlib/main.dart\n',
        stderr: '',
      );
    }
    return const RunCommandResult(
      exitCode: 0,
      stdout: 'M\tlib/main.dart\nA\tnotes.txt\n',
      stderr: '',
    );
  }

  if (cmd.contains('--no-pager diff --cached')) {
    return const RunCommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  if (cmd.contains('--no-pager diff --no-index')) {
    return const RunCommandResult(
      exitCode: 1,
      stdout:
          'diff --git a/notes.txt b/notes.txt\nnew file mode 100644\nindex 0000000..e69de29\n--- /dev/null\n+++ b/notes.txt\n@@\n+hello\n',
      stderr: '',
    );
  }

  if (cmd.contains('--no-pager diff -- ')) {
    return const RunCommandResult(
      exitCode: 0,
      stdout:
          'diff --git a/lib/main.dart b/lib/main.dart\nindex 1111111..2222222 100644\n--- a/lib/main.dart\n+++ b/lib/main.dart\n@@ -1,2 +1,2 @@\n-print("hi")\n+print("hello")\n',
      stderr: '',
    );
  }

  return RunCommandResult(
    exitCode: 1,
    stdout: '',
    stderr: 'Mock: unsupported command: $cmd',
  );
}

void _putConnection() {
  if (Get.isRegistered<ConnectionControllerBase>()) {
    Get.delete<ConnectionControllerBase>(force: true);
  }
  Get.put<ConnectionControllerBase>(MockConnectionController());
}

void _putProjects({required TargetArgs target}) {
  if (Get.isRegistered<ProjectsControllerBase>()) {
    Get.delete<ProjectsControllerBase>(force: true);
  }
  Get.put<ProjectsControllerBase>(MockProjectsController(target: target));
}

void _putProjectSessions({required ProjectArgs args}) {
  if (Get.isRegistered<ProjectSessionsControllerBase>()) {
    Get.delete<ProjectSessionsControllerBase>(force: true);
  }
  Get.put<ProjectSessionsControllerBase>(
    MockProjectSessionsController(args: args),
  );
}

void _putKeys() {
  if (Get.isRegistered<KeysControllerBase>()) {
    Get.delete<KeysControllerBase>(force: true);
  }
  Get.put<KeysControllerBase>(MockKeysController());
}

void _putInstallKey() {
  if (Get.isRegistered<InstallKeyControllerBase>()) {
    Get.delete<InstallKeyControllerBase>(force: true);
  }
  Get.put<InstallKeyControllerBase>(MockInstallKeyController());
}

void _putSettings() {
  if (Get.isRegistered<SettingsControllerBase>()) {
    Get.delete<SettingsControllerBase>(force: true);
  }
  Get.put<SettingsControllerBase>(MockSettingsController());
}

class WidgetbookBinding extends Bindings {
  @override
  void dependencies() {
    Get.lazyPut<ConnectionControllerBase>(() => MockConnectionController());
    Get.lazyPut<KeysControllerBase>(() => MockKeysController());
    Get.lazyPut<InstallKeyControllerBase>(() => MockInstallKeyController());
    Get.lazyPut<SettingsControllerBase>(() => MockSettingsController());

    // Defaults for pages that might be opened via navigation buttons.
    Get.lazyPut<ProjectsControllerBase>(
      () => MockProjectsController(target: _demoTarget),
    );
    Get.lazyPut<ProjectSessionsControllerBase>(
      () => MockProjectSessionsController(args: _demoProjectArgs),
    );
  }
}

class MockSettingsController extends SettingsControllerBase {
  @override
  final themeMode = ThemeMode.system.obs;

  @override
  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode.value = mode;
  }
}

class MockConnectionController extends ConnectionControllerBase {
  @override
  final userAtHostController = TextEditingController(text: 'robert@mac.local');
  @override
  final portController = TextEditingController(text: '22');
  @override
  final privateKeyPemController = TextEditingController();
  @override
  final privateKeyPassphraseController = TextEditingController();

  @override
  final useLocalRunner = true.obs;
  @override
  final remoteShell = PosixShell.sh.obs;
  @override
  final isBusy = false.obs;
  @override
  final status = ''.obs;
  @override
  final recentProfiles = <ConnectionProfile>[
    ConnectionProfile(
      userAtHost: 'robert@mac.local',
      port: 22,
      shell: PosixShell.sh,
    ),
    ConnectionProfile(
      userAtHost: 'ci@macmini.local',
      port: 2222,
      shell: PosixShell.zsh,
    ),
  ].obs;

  @override
  void onClose() {
    userAtHostController.dispose();
    portController.dispose();
    privateKeyPemController.dispose();
    privateKeyPassphraseController.dispose();
    super.onClose();
  }

  @override
  Future<void> reloadKeyFromKeychain() async {}

  @override
  Future<void> savePrivateKeyToKeychain() async {
    status.value = 'Saved (mock).';
  }

  @override
  Future<void> runLocalCodex() async {
    status.value = 'Local OK (mock).';
    Get.toNamed(DesignRoutes.projects, arguments: const TargetArgs.local());
  }

  @override
  Future<void> testSshConnection() async {
    isBusy.value = true;
    status.value = 'Connecting...';
    await Future<void>.delayed(const Duration(milliseconds: 400));

    final userAtHost = userAtHostController.text.trim();
    final port = int.tryParse(portController.text.trim()) ?? 22;
    status.value = 'SSH OK (mock): $userAtHost:$port';
    isBusy.value = false;

    Get.toNamed(
      DesignRoutes.projects,
      arguments: TargetArgs.remote(
        ConnectionProfile(
          userAtHost: userAtHost,
          port: port,
          shell: remoteShell.value,
        ),
      ),
    );
  }
}

class MockProjectsController extends ProjectsControllerBase {
  @override
  final TargetArgs target;

  MockProjectsController({required this.target});

  @override
  final projects = <Project>[
    const Project(
      id: '1',
      path: '/Users/me/repo-one',
      name: 'repo-one',
      group: 'Client A',
    ),
    const Project(
      id: '2',
      path: '/Users/me/repo-two',
      name: 'repo-two',
      group: 'Client A',
    ),
  ].obs;

  @override
  final isBusy = false.obs;
  @override
  final status = ''.obs;

  final _uuid = const Uuid();

  @override
  Future<Project?> promptAddProject() async {
    final id = _uuid.v4();
    return Project(id: id, path: '/Users/me/new-repo-$id', name: 'new-repo');
  }

  @override
  Future<void> addProject(Project project) async {
    projects.insert(0, project);
  }

  @override
  Future<void> updateProject(Project project) async {
    final idx = projects.indexWhere((p) => p.id == project.id);
    if (idx == -1) return;
    projects[idx] = project;
  }

  @override
  Future<void> deleteProject(Project project) async {
    projects.removeWhere((p) => p.id == project.id);
  }
}

class MockProjectSessionsController extends ProjectSessionsControllerBase {
  @override
  final ProjectArgs args;

  MockProjectSessionsController({required this.args});

  @override
  final tabs = <ProjectTab>[].obs;
  @override
  final activeIndex = 0.obs;
  @override
  final isReady = true.obs;

  final _uuid = const Uuid();
  final _sessionsByTabId = <String, MockSessionController>{};
  String _developerInstructions = '';

  @override
  void onInit() {
    super.onInit();
    tabs.assignAll(const [
      ProjectTab(id: 'tab-1', title: 'Tab 1'),
      ProjectTab(id: 'tab-2', title: 'Tab 2'),
    ]);
    for (final t in tabs) {
      _sessionsByTabId[t.id] = MockSessionController(
        projectName: args.project.name,
        seed: t.id == 'tab-1',
      );
    }
  }

  @override
  SessionControllerBase sessionForTab(ProjectTab tab) {
    return _sessionsByTabId.putIfAbsent(
      tab.id,
      () => MockSessionController(projectName: args.project.name, seed: false),
    );
  }

  @override
  Future<void> addTab() async {
    final id = 'tab-${_uuid.v4().substring(0, 6)}';
    final tab = ProjectTab(id: id, title: 'Tab ${tabs.length + 1}');
    tabs.add(tab);
    activeIndex.value = tabs.length - 1;
    _sessionsByTabId[id] = MockSessionController(
      projectName: args.project.name,
      seed: false,
    );
  }

  @override
  Future<void> closeTab(ProjectTab tab) async {
    final idx = tabs.indexWhere((t) => t.id == tab.id);
    if (idx == -1) return;
    tabs.removeAt(idx);
    _sessionsByTabId.remove(tab.id);
    if (tabs.isEmpty) {
      await addTab();
    } else if (activeIndex.value >= tabs.length) {
      activeIndex.value = tabs.length - 1;
    }
  }

  @override
  Future<void> renameTab(ProjectTab tab, String title) async {
    final nextTitle = title.trim();
    if (nextTitle.isEmpty) return;
    final idx = tabs.indexWhere((t) => t.id == tab.id);
    if (idx == -1) return;
    tabs[idx] = ProjectTab(id: tab.id, title: nextTitle);
  }

  @override
  Future<List<Conversation>> loadConversations() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    return [
      Conversation(
        threadId: 'thread_demo_1',
        preview: 'How do I refactor this controller?',
        tabId: 'tab-1',
        createdAtMs: now - 1000 * 60 * 60,
        lastUsedAtMs: now - 1000 * 60 * 2,
      ),
      Conversation(
        threadId: 'thread_demo_2',
        preview: 'Add reattach support to tailing logs',
        tabId: 'tab-2',
        createdAtMs: now - 1000 * 60 * 60 * 6,
        lastUsedAtMs: now - 1000 * 60 * 40,
      ),
    ];
  }

  @override
  Future<void> openConversation(Conversation conversation) async {
    final tabs = this.tabs;
    if (tabs.isEmpty) return;
    final active = tabs[activeIndex.value.clamp(0, tabs.length - 1)];
    final session = sessionForTab(active);
    await session.resumeThreadById(
      conversation.threadId,
      preview: conversation.preview,
    );
  }

  @override
  Future<List<Project>> loadSwitchableProjects() async {
    final group = args.project.group?.trim() ?? '';
    if (group.isEmpty) return const [];
    return [
      Project(
        id: 'switch-1',
        path: '/Users/me/switch-target',
        name: 'switch-target',
        group: group,
      ),
    ].where((p) => p.id != args.project.id).toList(growable: false);
  }

  @override
  Future<void> switchToProject(Project project) async {
    Get.offNamed(
      DesignRoutes.project,
      arguments: ProjectArgs(target: args.target, project: project),
    );
  }

  @override
  Future<String> loadDeveloperInstructions() async {
    return _developerInstructions;
  }

  @override
  Future<void> saveDeveloperInstructions(String instructions) async {
    _developerInstructions = instructions;
  }

  @override
  String runCommandHint() => 'Runs in ${args.project.path} (mock)';

  @override
  Future<RunCommandResult> runShellCommand(String command) async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    return RunCommandResult(
      exitCode: 0,
      stdout: 'mock: $command\n',
      stderr: '',
    );
  }
}

class MockSessionController extends SessionControllerBase {
  MockSessionController({required this.projectName, this.seed = true}) {
    if (seed) _seedIfNeeded();
  }

  final String projectName;
  final bool seed;
  final _uuid = const Uuid();
  var _seeded = false;
  static const _mockScreenshotAssetKey = '../../assets/screenshot.png';

  @override
  final chatController = InMemoryChatController();
  @override
  final inputController = TextEditingController();
  @override
  final isRunning = false.obs;
  @override
  final threadId = RxnString('thread_mock_1234');
  @override
  final remoteJobId = RxnString('tmux:cr_tab1_1730000000000');
  @override
  final thinkingPreview = RxnString();

  static const _me = 'user';
  static const _codex = 'codex';
  static const _system = 'system';

  @override
  void onInit() {
    super.onInit();
    if (seed) _seedIfNeeded();
  }

  void _seedIfNeeded() {
    if (_seeded) return;
    _seeded = true;
    _seed();
  }

  void _seed() {
    final now = DateTime.now().toUtc();

    Message event(String type, String text, {DateTime? at}) {
      return Message.custom(
        id: _uuid.v4(),
        authorId: _system,
        createdAt: at ?? now,
        metadata: {'kind': 'codex_event', 'eventType': type, 'text': text},
      );
    }

    Message item(
      String eventType,
      String itemType,
      String text, {
      Map<String, Object?> item = const {},
      DateTime? at,
    }) {
      return Message.custom(
        id: _uuid.v4(),
        authorId: _system,
        createdAt: at ?? now,
        metadata: {
          'kind': 'codex_item',
          'eventType': eventType,
          'itemType': itemType,
          'text': text,
          'item': item,
        },
      );
    }

    Message actions(List<Map<String, String>> actions, {DateTime? at}) {
      return Message.custom(
        id: _uuid.v4(),
        authorId: _codex,
        createdAt: at ?? now,
        metadata: {'kind': 'codex_actions', 'actions': actions},
      );
    }

    final t0 = now.subtract(const Duration(minutes: 4));
    final t1 = now.subtract(const Duration(minutes: 3, seconds: 40));
    final t2 = now.subtract(const Duration(minutes: 3, seconds: 20));
    final t3 = now.subtract(const Duration(minutes: 2, seconds: 50));
    final t4 = now.subtract(const Duration(minutes: 2, seconds: 10));
    final t5 = now.subtract(const Duration(minutes: 1, seconds: 30));
    final t6 = now.subtract(const Duration(seconds: 45));

    chatController.setMessages([
      event(
        'replay',
        'Replayed last 42 log lines.',
        at: t0.add(const Duration(seconds: 2)),
      ),
      Message.text(
        id: _uuid.v4(),
        authorId: _me,
        createdAt: t1,
        text: 'Please add a stop button that works across app restarts.',
      ),
      // Codex exec JSONL-style items (started/updated/completed). We intentionally
      // seed some item.started events to verify they are not shown as bubbles.
      item(
        'item.started',
        'command_execution',
        '',
        item: const {
          'id': 'item_1',
          'type': 'command_execution',
          'command': 'bash -lc ls',
          'status': 'in_progress',
        },
        at: t2,
      ),
      item(
        'item.completed',
        'command_execution',
        '',
        item: const {
          'id': 'item_1',
          'type': 'command_execution',
          'command': 'bash -lc ls',
          'aggregated_output': 'README.md\\nlib\\npackages\\n',
          'exit_code': 0,
          'status': 'completed',
        },
        at: t2.add(const Duration(seconds: 10)),
      ),

      item(
        'item.completed',
        'reasoning',
        'We need to persist the running state and reconnect to the tail stream.',
        item: const {'text': 'We need to persist the running state...'},
        at: t3.add(const Duration(seconds: 10)),
      ),
      item(
        'item.completed',
        'todo_list',
        '',
        item: const {
          'id': 'item_20',
          'type': 'todo_list',
          'items': [
            {'text': 'Migrate Sales pages', 'completed': true},
            {'text': 'Update plan progress doc', 'completed': true},
            {'text': 'Run tests and quick pipeline', 'completed': true},
          ],
        },
        at: t3.add(const Duration(seconds: 20)),
      ),
      item(
        'item.completed',
        'file_change',
        'Modified lib/features/session/session_controller.dart',
        item: const {
          'path': 'lib/features/session/session_controller.dart',
          'summary': 'Improve reattach + stop behavior',
        },
        at: t4.add(const Duration(seconds: 10)),
      ),
      item(
        'item.completed',
        'web_search',
        'Searched: getx permanent controller keep alive',
        item: const {'query': 'getx permanent controller keep alive'},
        at: t4.add(const Duration(seconds: 20)),
      ),
      item(
        'item.completed',
        'mcp_tool_call',
        'context7: getx dependency management docs',
        item: const {'tool': 'context7', 'topic': 'Get.put permanent'},
        at: t4.add(const Duration(seconds: 30)),
      ),

      event('stderr', 'warning: using fallback shell', at: t5),
      event(
        'tail_stderr',
        'tail: .field_exec/sessions/tab-1.log: file truncated',
        at: t5.add(const Duration(seconds: 10)),
      ),

      Message.text(
        id: _uuid.v4(),
        authorId: _codex,
        createdAt: t6.add(const Duration(seconds: 1)),
        text: 'Done. The stop button now reflects active jobs across restarts.',
      ),
      Message.custom(
        id: _uuid.v4(),
        authorId: _codex,
        createdAt: t6.add(const Duration(seconds: 1, milliseconds: 200)),
        metadata: {
          'kind': 'codex_image_grid',
          'images': [
            {
              'path': _mockScreenshotAssetKey,
              'caption': 'Golden diff A (mock)',
              'status': 'tap_to_load',
            },
            {
              'path': _mockScreenshotAssetKey,
              'caption': 'Golden diff B (mock)',
              'status': 'tap_to_load',
            },
            {
              'path': _mockScreenshotAssetKey,
              'caption': 'Golden diff C (mock)',
              'status': 'tap_to_load',
            },
            {
              'path': _mockScreenshotAssetKey,
              'caption': 'Golden diff D (mock)',
              'status': 'tap_to_load',
            },
          ],
        },
      ),
      event(
        'commit_message',
        'Fix session reattach stop button',
        at: t6.add(const Duration(seconds: 2)),
      ),
      actions(const [
        {
          'id': 'run_tests',
          'label': 'Run tests',
          'value': 'Please run the test suite.',
        },
        {
          'id': 'open_pr',
          'label': 'Open PR',
          'value': 'Create a PR for these changes.',
        },
        {'id': 'ship', 'label': 'Ship', 'value': 'Looks good—ship it.'},
      ], at: t6.add(const Duration(seconds: 3))),
    ], animated: false);
  }

  @override
  Future<User> resolveUser(UserID id) async {
    if (id == _me) return const User(id: _me, name: 'You');
    if (id == _codex) return const User(id: _codex, name: 'Codex');
    return const User(id: _system, name: 'System');
  }

  @override
  Future<void> sendText(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    inputController.clear();

    await chatController.insertMessage(
      Message.text(
        id: _uuid.v4(),
        authorId: _me,
        createdAt: DateTime.now().toUtc(),
        text: trimmed,
      ),
      animated: true,
    );

    isRunning.value = true;
    thinkingPreview.value = 'Mock: planning…';
    await Future<void>.delayed(const Duration(milliseconds: 350));
    await chatController.insertMessage(
      Message.text(
        id: _uuid.v4(),
        authorId: _codex,
        createdAt: DateTime.now().toUtc(),
        text: 'Mock: received “$trimmed”.',
      ),
      animated: true,
    );
    isRunning.value = false;
    thinkingPreview.value = null;
  }

  @override
  Future<void> sendQuickReply(String value) => sendText(value);

  @override
  Future<void> loadImageAttachment(CustomMessage message, {int? index}) async {
    final meta = message.metadata ?? const {};
    final kind = meta['kind']?.toString();
    if (kind != 'codex_image' && kind != 'codex_image_grid') return;

    final bytes = await _readMockScreenshotBytes();

    if (kind == 'codex_image') {
      final next = Map<String, Object?>.from(meta);
      next['status'] = 'loaded';
      next['bytes'] = bytes;
      await chatController.updateMessage(
        message,
        message.copyWith(metadata: next),
      );
      return;
    }

    final raw = meta['images'];
    if (raw is! List) return;
    final items = raw
        .whereType<Map>()
        .map((m) => Map<String, Object?>.from(m))
        .toList();
    if (items.isEmpty) return;

    final indices = <int>[];
    if (index != null) {
      if (index < 0 || index >= items.length) return;
      indices.add(index);
    } else {
      for (var i = 0; i < items.length; i++) {
        indices.add(i);
      }
    }

    for (final i in indices) {
      final item = Map<String, Object?>.from(items[i]);
      item['status'] = 'loaded';
      item['bytes'] = bytes;
      items[i] = item;
    }

    final next = Map<String, Object?>.from(meta);
    next['images'] = items;
    await chatController.updateMessage(
      message,
      message.copyWith(metadata: next),
    );
  }

  Future<Uint8List> _readMockScreenshotBytes() async {
    try {
      final data = await rootBundle.load(_mockScreenshotAssetKey);
      return Uint8List.fromList(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    } catch (_) {}
    final fallback = base64.decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO9l9WQAAAAASUVORK5CYII=',
    );
    return Uint8List.fromList(fallback);
  }

  @override
  Future<void> resumeThreadById(String id, {String? preview}) async {
    threadId.value = id;
    await chatController.insertMessage(
      Message.custom(
        id: _uuid.v4(),
        authorId: _system,
        createdAt: DateTime.now().toUtc(),
        metadata: {
          'kind': 'codex_event',
          'eventType': 'resume',
          'text': 'Resumed $id (mock) ${preview ?? ''}',
        },
      ),
      animated: true,
    );
  }

  @override
  Future<void> reattachIfNeeded({int backfillLines = 200}) async {}

  @override
  Future<void> resetSession() async {
    threadId.value = null;
    remoteJobId.value = null;
    thinkingPreview.value = null;
    isRunning.value = false;
    await chatController.setMessages(const [], animated: false);
  }

  @override
  void stop() {
    isRunning.value = false;
  }

  @override
  void onClose() {
    inputController.dispose();
    chatController.dispose();
    super.onClose();
  }
}

class MockKeysController extends KeysControllerBase {
  @override
  final pemController = TextEditingController(text: '-----BEGIN MOCK KEY-----');

  @override
  final busy = false.obs;

  @override
  final status = 'Key loaded (mock).'.obs;

  @override
  Future<void> load() async {}

  @override
  Future<void> save() async {
    status.value = 'Saved (mock).';
  }

  @override
  Future<void> deleteKey() async {
    pemController.text = '';
    status.value = 'Deleted (mock).';
  }

  @override
  Future<void> generate() async {
    pemController.text = '-----BEGIN MOCK KEY-----\n...';
    status.value = 'Generated (mock).';
  }

  @override
  Future<void> copyPublicKey() async {
    status.value = 'Copied (mock).';
  }

  @override
  void onClose() {
    pemController.dispose();
    super.onClose();
  }
}

class MockInstallKeyController extends InstallKeyControllerBase {
  @override
  final targetController = TextEditingController(text: 'robert@mac.local');
  @override
  final portController = TextEditingController(text: '22');
  @override
  final passwordController = TextEditingController();

  @override
  final busy = false.obs;

  @override
  final status = ''.obs;

  @override
  Future<void> install() async {
    status.value = 'Installed (mock).';
  }

  @override
  void onClose() {
    targetController.dispose();
    portController.dispose();
    passwordController.dispose();
    super.onClose();
  }
}
