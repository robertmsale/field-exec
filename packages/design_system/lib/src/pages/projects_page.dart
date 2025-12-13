import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../args/project_args.dart';
import '../controllers/projects_controller_base.dart';
import '../routes/design_routes.dart';

class ProjectsPage extends GetView<ProjectsControllerBase> {
  const ProjectsPage({super.key});

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
                  Get.toNamed(DesignRoutes.project, arguments: args);
                },
              );
            },
          );
        }),
      ),
    );
  }
}

