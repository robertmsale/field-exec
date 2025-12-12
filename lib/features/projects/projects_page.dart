import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../app/routes/app_routes.dart';
import 'project_args.dart';
import 'projects_controller.dart';
import 'target_args.dart';

class ProjectsPage extends StatefulWidget {
  const ProjectsPage({super.key});

  @override
  State<ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends State<ProjectsPage> {
  late final ProjectsController controller;

  @override
  void initState() {
    super.initState();
    final args = (Get.arguments is TargetArgs)
        ? (Get.arguments as TargetArgs)
        : const TargetArgs.local();
    controller = Get.put(ProjectsController(target: args));
  }

  @override
  void dispose() {
    Get.delete<ProjectsController>(force: true);
    super.dispose();
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
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: projects.length,
            separatorBuilder: (_, index) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final p = projects[i];
              return ListTile(
                title: Text(p.name),
                subtitle: Text(p.path),
                trailing: IconButton(
                  tooltip: 'Delete',
                  onPressed: () => controller.deleteProject(p),
                  icon: const Icon(Icons.delete_outline),
                ),
                onTap: () {
                  final args = ProjectArgs(target: controller.target, project: p);
                  Get.toNamed(AppRoutes.project, arguments: args);
                },
              );
            },
          );
        }),
      ),
    );
  }
}
