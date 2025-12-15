import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/project_sessions_controller_base.dart';
import '../models/conversation.dart';
import '../models/project.dart';
import '../models/project_tab.dart';
import '../session/codex_chat_view.dart';
import '../session/codex_session_status_bar.dart';
import '../git/git_tools_sheet.dart';
import 'project_sessions_help_sheet.dart';
import 'run_command_sheet.dart';

enum _ProjectMenuAction {
  help,
  runCommand,
  resumeConversation,
  git,
  developerInstructions,
  renameProject,
}

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
  Worker? _activeWorker;

  Future<void> _showHelp() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const ProjectSessionsHelpSheet(),
    );
  }

  Future<void> _showRunCommand() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => RunCommandSheet(
        hintText: controller.runCommandHint(),
        run: controller.runShellCommand,
      ),
    );
  }

  Future<void> _showGit() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => GitToolsSheet(
        run: controller.runShellCommand,
        projectPathLabel: controller.args.project.path,
      ),
    );
  }

  Future<void> _showResumeConversation() async {
    final items = await controller.loadConversations();
    if (!mounted) return;
    await _showConversationPicker(items);
  }

  Future<void> _switchToProjectInGroup() async {
    final candidates = await controller.loadSwitchableProjects();
    if (!mounted) return;
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No other projects in this group.')),
      );
      return;
    }

    final picked = await showModalBottomSheet<Project>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: candidates.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final p = candidates[i];
            return ListTile(
              title: Text(p.name),
              subtitle: Text(p.path),
              leading: const Icon(Icons.swap_horiz),
              onTap: () => Navigator.of(context).pop(p),
            );
          },
        ),
      ),
    );
    if (picked == null) return;
    await controller.switchToProject(picked);
  }

  Future<void> _editDeveloperInstructions() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _DeveloperInstructionsSheet(controller: controller),
    );
  }

  Future<void> _renameProject() async {
    final title = await _promptRenameProject();
    if (!mounted) return;
    if (title == null) return;
    await controller.renameProject(title);
  }

  Future<void> _handleMenu(_ProjectMenuAction action) async {
    switch (action) {
      case _ProjectMenuAction.help:
        await _showHelp();
        return;
      case _ProjectMenuAction.runCommand:
        await _showRunCommand();
        return;
      case _ProjectMenuAction.resumeConversation:
        await _showResumeConversation();
        return;
      case _ProjectMenuAction.git:
        await _showGit();
        return;
      case _ProjectMenuAction.developerInstructions:
        await _editDeveloperInstructions();
        return;
      case _ProjectMenuAction.renameProject:
        await _renameProject();
        return;
    }
  }

  Future<void> _showTabMenu({
    required ProjectTab tab,
    required Offset globalPosition,
  }) async {
    final overlay = Overlay.of(context).context.findRenderObject();
    final box = overlay is RenderBox ? overlay : null;
    final size = box?.size ?? MediaQuery.of(context).size;

    final picked = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        size.width - globalPosition.dx,
        size.height - globalPosition.dy,
      ),
      items: const [
        PopupMenuItem<String>(
          value: 'rename',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.edit, size: 18),
            title: Text('Rename tab'),
          ),
        ),
      ],
    );
    if (!mounted) return;
    if (picked != 'rename') return;

    final title = await _promptRenameTab(tab);
    if (!mounted) return;
    if (title == null) return;
    await controller.renameTab(tab, title);
  }

  Future<String?> _promptRenameTab(ProjectTab tab) async {
    final text = TextEditingController(text: tab.title);
    try {
      return showDialog<String>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('Rename tab'),
            content: TextField(
              controller: text,
              autofocus: true,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(labelText: 'Tab name'),
              onSubmitted: (v) => Navigator.of(context).pop(v),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(text.text),
                child: const Text('Save'),
              ),
            ],
          );
        },
      );
    } finally {
      text.dispose();
    }
  }

  Future<String?> _promptRenameProject() async {
    final text = TextEditingController(text: controller.projectName.value);
    try {
      return showDialog<String>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('Rename project'),
            content: TextField(
              controller: text,
              autofocus: true,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(labelText: 'Project name'),
              onSubmitted: (v) => Navigator.of(context).pop(v),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(text.text),
                child: const Text('Save'),
              ),
            ],
          );
        },
      );
    } finally {
      text.dispose();
    }
  }

  @override
  void initState() {
    super.initState();
    controller = Get.find<ProjectSessionsControllerBase>();

    _recreateTabController();
    _tabsWorker = ever<List<ProjectTab>>(controller.tabs, (_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _recreateTabController();
      });
    });
    _activeWorker = ever<int>(controller.activeIndex, (idx) {
      final tabs = _tabs;
      if (tabs == null) return;
      final safe = idx.clamp(0, tabs.length - 1);
      if (safe == tabs.index) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final current = _tabs;
        if (current == null) return;
        final next = controller.activeIndex.value.clamp(0, current.length - 1);
        if (next == current.index) return;
        try {
          current.animateTo(next);
        } catch (_) {}
      });
    });
  }

  void _recreateTabController() {
    final length = controller.tabs.length;
    if (length <= 0) {
      final old = _tabs;
      _tabs = null;
      old?.dispose();
      if (mounted) setState(() {});
      return;
    }

    final nextIndex = controller.activeIndex.value.clamp(0, length - 1);
    final old = _tabs;
    _tabs = TabController(length: length, vsync: this, initialIndex: nextIndex);
    _tabs!.addListener(() {
      if (_tabs!.indexIsChanging) return;
      controller.activeIndex.value = _tabs!.index;
    });
    old?.dispose();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tabsWorker?.dispose();
    _activeWorker?.dispose();
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
        title: Obx(() => Text(controller.projectName.value)),
        actions: [
          IconButton(
            tooltip: 'Switch project',
            onPressed: () => unawaited(_switchToProjectInGroup()),
            icon: const Icon(Icons.swap_horiz),
          ),
          PopupMenuButton<_ProjectMenuAction>(
            tooltip: 'Project menu',
            icon: const Icon(Icons.more_vert),
            onSelected: (a) => unawaited(_handleMenu(a)),
            itemBuilder: (_) => const [
              PopupMenuItem<_ProjectMenuAction>(
                value: _ProjectMenuAction.renameProject,
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.edit, size: 18),
                  title: Text('Rename project…'),
                ),
              ),
              PopupMenuItem<_ProjectMenuAction>(
                value: _ProjectMenuAction.developerInstructions,
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.tune, size: 18),
                  title: Text('Developer instructions…'),
                ),
              ),
              PopupMenuDivider(),
              PopupMenuItem<_ProjectMenuAction>(
                value: _ProjectMenuAction.git,
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.difference, size: 18),
                  title: Text('Git'),
                ),
              ),
              PopupMenuItem<_ProjectMenuAction>(
                value: _ProjectMenuAction.runCommand,
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.terminal, size: 18),
                  title: Text('Run command'),
                ),
              ),
              PopupMenuItem<_ProjectMenuAction>(
                value: _ProjectMenuAction.resumeConversation,
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.history, size: 18),
                  title: Text('Resume conversation'),
                ),
              ),
              PopupMenuItem<_ProjectMenuAction>(
                value: _ProjectMenuAction.help,
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.help_outline, size: 18),
                  title: Text('Help'),
                ),
              ),
            ],
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(44),
          child: Obx(() {
            final items = controller.tabs;
            if (items.isEmpty) return const SizedBox(height: 44);
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
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onSecondaryTapDown: (d) => _showTabMenu(
                                  tab: t,
                                  globalPosition: d.globalPosition,
                                ),
                                onLongPressStart: (d) => _showTabMenu(
                                  tab: t,
                                  globalPosition: d.globalPosition,
                                ),
                                child: Text(t.title),
                              ),
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
        if (items.isEmpty) return const SizedBox.shrink();
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
    await controller.openConversation(picked);
  }
}

class _DeveloperInstructionsSheet extends StatefulWidget {
  const _DeveloperInstructionsSheet({required this.controller});

  final ProjectSessionsControllerBase controller;

  @override
  State<_DeveloperInstructionsSheet> createState() =>
      _DeveloperInstructionsSheetState();
}

class _DeveloperInstructionsSheetState
    extends State<_DeveloperInstructionsSheet> {
  final _text = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final s = await widget.controller.loadDeveloperInstructions();
      _text.text = s;
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.controller.saveDeveloperInstructions(_text.text);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved developer instructions.')),
      );
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.9,
          child: Column(
            children: [
              ListTile(
                title: const Text('Developer instructions'),
                subtitle: Text(
                  '${widget.controller.projectName.value} • .field_exec/developer_instructions.txt',
                ),
                trailing: Wrap(
                  spacing: 4,
                  children: [
                    IconButton(
                      tooltip: 'Reload',
                      onPressed: _loading || _saving ? null : _load,
                      icon: const Icon(Icons.refresh),
                    ),
                    FilledButton(
                      onPressed: _loading || _saving ? null : _save,
                      child: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Save'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(_error!, textAlign: TextAlign.center),
                        ),
                      )
                    : Padding(
                        padding: const EdgeInsets.all(12),
                        child: TextField(
                          controller: _text,
                          maxLines: null,
                          expands: true,
                          keyboardType: TextInputType.multiline,
                          textInputAction: TextInputAction.newline,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            hintText:
                                'These instructions are appended to the developer prompt for every Codex run in this project.',
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
