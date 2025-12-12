import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import '../../models/project.dart';
import '../../services/project_store.dart';
import 'target_args.dart';

class ProjectsController extends GetxController {
  final TargetArgs target;

  ProjectsController({required this.target});

  final projects = <Project>[].obs;
  final isBusy = false.obs;
  final status = ''.obs;

  final _uuid = const Uuid();

  ProjectStore get _store => Get.find<ProjectStore>();

  @override
  void onInit() {
    super.onInit();
    _load();
  }

  Future<void> _load() async {
    isBusy.value = true;
    try {
      final loaded = await _store.loadProjects(targetKey: target.targetKey);
      projects.assignAll(loaded);
    } finally {
      isBusy.value = false;
    }
  }

  Future<Project?> promptAddProject() async {
    final pathController = TextEditingController();
    final nameController = TextEditingController();
    try {
      final result = await Get.dialog<Project>(
        AlertDialog(
          title: const Text('Add project'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: pathController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Path',
                  hintText: '/Users/me/repo or /home/me/repo',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Name (optional)',
                  hintText: 'my-repo',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Get.back(result: null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final path = pathController.text.trim();
                if (path.isEmpty) return;
                final name = nameController.text.trim();
                final fallback = path.split('/').where((p) => p.isNotEmpty).last;
                Get.back(
                  result: Project(
                    id: _uuid.v4(),
                    path: path,
                    name: name.isEmpty ? fallback : name,
                  ),
                );
              },
              child: const Text('Add'),
            ),
          ],
        ),
      );
      return result;
    } finally {
      pathController.dispose();
      nameController.dispose();
    }
  }

  Future<void> addProject(Project project) async {
    final next = [project, ...projects].take(25).toList(growable: false);
    projects.assignAll(next);
    await _store.saveProjects(targetKey: target.targetKey, projects: next);
    await _store.saveLastProjectId(targetKey: target.targetKey, projectId: project.id);
  }

  Future<void> deleteProject(Project project) async {
    final next = projects.where((p) => p.id != project.id).toList(growable: false);
    projects.assignAll(next);
    await _store.saveProjects(targetKey: target.targetKey, projects: next);
  }
}

