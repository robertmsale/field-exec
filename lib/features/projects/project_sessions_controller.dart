import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import '../../models/project_tab.dart';
import '../../services/codex_session_store.dart';
import '../../services/project_tabs_store.dart';
import '../session/session_controller.dart';
import 'project_args.dart';

class ProjectSessionsController extends GetxController {
  final ProjectArgs args;

  ProjectSessionsController({required this.args});

  final tabs = <ProjectTab>[].obs;
  final activeIndex = 0.obs;
  final isReady = false.obs;

  final _uuid = const Uuid();

  CodexSessionStore get _store => Get.find<CodexSessionStore>();
  ProjectTabsStore get _tabsStore => Get.find<ProjectTabsStore>();

  @override
  void onInit() {
    super.onInit();
    _load();
  }

  SessionController sessionForTab(ProjectTab tab) {
    return Get.find<SessionController>(tag: tab.id);
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
      if (Get.isRegistered<SessionController>(tag: tab.id)) continue;
      Get.put(
        SessionController(
          target: args.target,
          projectPath: args.project.path,
          tabId: tab.id,
        ),
        tag: tab.id,
      );
    }
  }

  Future<void> addTab() async {
    final id = _uuid.v4();
    final title = 'Tab ${tabs.length + 1}';
    final tab = ProjectTab(id: id, title: title);

    Get.put(
      SessionController(
        target: args.target,
        projectPath: args.project.path,
        tabId: id,
      ),
      tag: id,
    );

    tabs.add(tab);
    activeIndex.value = tabs.length - 1;

    await _tabsStore.saveTabs(
      targetKey: args.target.targetKey,
      projectPath: args.project.path,
      tabs: tabs.toList(growable: false),
    );
  }

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
    Get.delete<SessionController>(tag: tab.id, force: true);

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
}
