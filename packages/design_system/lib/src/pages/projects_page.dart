import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../args/project_args.dart';
import '../controllers/projects_controller_base.dart';
import '../models/project.dart';
import '../routes/design_routes.dart';

class ProjectsPage extends GetView<ProjectsControllerBase> {
  const ProjectsPage({super.key});

  Future<String?> _promptNewGroupName(BuildContext context) async {
    final text = TextEditingController();
    try {
      return showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('New group'),
          content: TextField(
            controller: text,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(labelText: 'Group name'),
            onSubmitted: (v) => Navigator.of(context).pop(v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(text.text),
              child: const Text('Create'),
            ),
          ],
        ),
      );
    } finally {
      text.dispose();
    }
  }

  Future<String?> _pickGroupForProject({
    required BuildContext context,
    required List<String> existingGroups,
    required String? currentGroup,
  }) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(Icons.clear),
                title: const Text('No group'),
                subtitle: currentGroup == null ? const Text('Current') : null,
                onTap: () => Navigator.of(context).pop(''),
              ),
              for (final g in existingGroups)
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(g),
                  subtitle: currentGroup == g ? const Text('Current') : null,
                  onTap: () => Navigator.of(context).pop(g),
                ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('New group…'),
                onTap: () => Navigator.of(context).pop('__new__'),
              ),
            ],
          ),
        );
      },
    );

    if (picked == null) return null;
    if (picked != '__new__') return picked;

    final created = await _promptNewGroupName(context);
    final trimmed = created?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    return trimmed;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Projects'),
        actions: [
          IconButton(
            tooltip: 'Add',
            onPressed: () async {
              final project = await controller.promptAddProject();
              if (project != null) await controller.addProject(project);
            },
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: SafeArea(
        child: Obx(() {
          final projects = controller.projects;
          if (projects.isEmpty) {
            return const Center(
              child: Text('No projects yet. Tap + to add one.'),
            );
          }

          final grouped = <String, List<Project>>{};
          final ungrouped = <Project>[];
          for (final p in projects) {
            final g = (p.group ?? '').trim();
            if (g.isEmpty) {
              ungrouped.add(p);
            } else {
              (grouped[g] ??= <Project>[]).add(p);
            }
          }
          final groupNames = grouped.keys.toList()..sort();
          final existingGroups = groupNames.toList(growable: false);

          ListTile tileFor(Project p) {
            Future<void> openGroupPicker() async {
              final picked = await _pickGroupForProject(
                context: context,
                existingGroups: existingGroups,
                currentGroup: p.group?.trim().isEmpty == true ? null : p.group,
              );
              if (picked == null) return;
              final next = picked.trim().isEmpty
                  ? p.copyWith(group: null)
                  : p.copyWith(group: picked.trim());
              await controller.updateProject(next);
            }

            return ListTile(
              title: Text(p.name),
              subtitle: Text(p.path),
              trailing: PopupMenuButton<String>(
                tooltip: 'More',
                itemBuilder: (_) => [
                  const PopupMenuItem<String>(
                    value: 'group',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.folder_outlined, size: 18),
                      title: Text('Group…'),
                    ),
                  ),
                  if (p.group != null && p.group!.trim().isNotEmpty)
                    const PopupMenuItem<String>(
                      value: 'ungroup',
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.clear, size: 18),
                        title: Text('Ungroup'),
                      ),
                    ),
                  const PopupMenuDivider(),
                  const PopupMenuItem<String>(
                    value: 'delete',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.delete_outline, size: 18),
                      title: Text('Delete'),
                    ),
                  ),
                ],
                onSelected: (v) async {
                  if (v == 'delete') {
                    await controller.deleteProject(p);
                    return;
                  }
                  if (v == 'ungroup') {
                    await controller.updateProject(p.copyWith(group: null));
                    return;
                  }
                  if (v == 'group') {
                    await openGroupPicker();
                    return;
                  }
                },
              ),
              onTap: () {
                final args = ProjectArgs(target: controller.target, project: p);
                Get.toNamed(DesignRoutes.project, arguments: args);
              },
            );
          }

          final children = <Widget>[];
          for (final g in groupNames) {
            children.add(
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                child: Text(g, style: Theme.of(context).textTheme.titleSmall),
              ),
            );
            final items = grouped[g] ?? const <Project>[];
            for (var i = 0; i < items.length; i++) {
              children.add(tileFor(items[i]));
              children.add(const Divider(height: 1));
            }
          }

          if (ungrouped.isNotEmpty) {
            if (groupNames.isNotEmpty) {
              children.add(
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 18, 12, 6),
                  child: Text(
                    'Ungrouped',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              );
            }
            for (var i = 0; i < ungrouped.length; i++) {
              children.add(tileFor(ungrouped[i]));
              children.add(const Divider(height: 1));
            }
          }

          return ListView(
            padding: const EdgeInsets.all(12),
            children: children,
          );
        }),
      ),
    );
  }
}
