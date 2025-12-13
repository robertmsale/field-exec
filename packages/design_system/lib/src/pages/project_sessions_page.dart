import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/project_sessions_controller_base.dart';
import '../models/conversation.dart';
import '../models/project_tab.dart';
import '../session/codex_chat_view.dart';
import '../session/codex_session_status_bar.dart';
import 'project_sessions_help_sheet.dart';
import 'run_command_sheet.dart';

class ProjectSessionsPage extends StatefulWidget {
  const ProjectSessionsPage({super.key});

  @override
  State<ProjectSessionsPage> createState() => _ProjectSessionsPageState();
}

class _ProjectSessionsPageState extends State<ProjectSessionsPage>
    with TickerProviderStateMixin {
  late final ProjectSessionsControllerBase controller;
  TabController? _tabs;
  Worker? _tabsWorker;

  @override
  void initState() {
    super.initState();
    controller = Get.find<ProjectSessionsControllerBase>();

    _recreateTabController();
    _tabsWorker = ever<List<ProjectTab>>(controller.tabs, (_) {
      _recreateTabController();
    });
  }

  void _recreateTabController() {
    final length = controller.tabs.length;
    if (length <= 0) return;

    final nextIndex = controller.activeIndex.value.clamp(0, length - 1);
    final old = _tabs;
    _tabs = TabController(length: length, vsync: this, initialIndex: nextIndex);
    _tabs!.addListener(() {
      if (_tabs!.indexIsChanging) return;
      controller.activeIndex.value = _tabs!.index;
    });
    old?.dispose();
    setState(() {});
  }

  @override
  void dispose() {
    _tabsWorker?.dispose();
    _tabs?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tabs = _tabs;
    if (tabs == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(controller.args.project.name),
        actions: [
          IconButton(
            tooltip: 'Help',
            icon: const Icon(Icons.help_outline),
            onPressed: () async {
              await showModalBottomSheet<void>(
                context: context,
                showDragHandle: true,
                isScrollControlled: true,
                builder: (_) => const ProjectSessionsHelpSheet(),
              );
            },
          ),
          IconButton(
            tooltip: 'Run command',
            icon: const Icon(Icons.terminal),
            onPressed: () async {
              await showModalBottomSheet<void>(
                context: context,
                showDragHandle: true,
                isScrollControlled: true,
                builder: (_) => RunCommandSheet(
                  hintText: controller.runCommandHint(),
                  run: controller.runShellCommand,
                ),
              );
            },
          ),
          IconButton(
            tooltip: 'Resume conversation',
            icon: const Icon(Icons.history),
            onPressed: () async {
              final items = await controller.loadConversations();
              if (!mounted) return;
              await _showConversationPicker(items);
            },
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(44),
          child: Obx(() {
            final items = controller.tabs;
            return Row(
              children: [
                Expanded(
                  child: TabBar(
                    controller: tabs,
                    isScrollable: true,
                    tabs: [
                      for (final t in items)
                        Tab(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(t.title),
                              const SizedBox(width: 8),
                              GestureDetector(
                                onTap: () => controller.closeTab(t),
                                child: const Icon(Icons.close, size: 16),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'New tab',
                  onPressed: controller.addTab,
                  icon: const Icon(Icons.add),
                ),
              ],
            );
          }),
        ),
      ),
      body: Obx(() {
        final items = controller.tabs;
        return TabBarView(
          controller: tabs,
          children: [
            for (final t in items)
              Builder(
                builder: (context) {
                  final session = controller.sessionForTab(t);
                  return Column(
                    children: [
                      CodexSessionStatusBar(controller: session),
                      Expanded(child: CodexChatView(controller: session)),
                    ],
                  );
                },
              ),
          ],
        );
      }),
    );
  }

  Future<void> _showConversationPicker(List<Conversation> items) async {
    final tabs = controller.tabs;
    if (tabs.isEmpty) return;
    final active = tabs[controller.activeIndex.value.clamp(0, tabs.length - 1)];
    final session = controller.sessionForTab(active);

    final picked = await showModalBottomSheet<Conversation>(
      context: context,
      showDragHandle: true,
      builder: (_) {
        if (items.isEmpty) {
          return const SafeArea(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('No previous conversations for this project yet.'),
            ),
          );
        }
        return SafeArea(
          child: ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: items.length,
            separatorBuilder: (_, index) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final c = items[i];
              return ListTile(
                title: Text(c.preview.isEmpty ? c.threadId : c.preview),
                subtitle: Text(c.threadId),
                onTap: () => Navigator.of(context).pop(c),
              );
            },
          ),
        );
      },
    );

    if (picked == null) return;
    await session.resumeThreadById(picked.threadId, preview: picked.preview);
  }
}
