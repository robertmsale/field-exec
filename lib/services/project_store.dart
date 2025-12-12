import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/project.dart';

class ProjectStore {
  static String _projectsKey(String targetKey) => 'projects_v1:$targetKey';
  static String _lastProjectKey(String targetKey) => 'projects_last_v1:$targetKey';

  Future<List<Project>> loadProjects({required String targetKey}) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_projectsKey(targetKey)) ?? const <String>[];
    return raw
        .map((s) => Project.fromJson(
              (jsonDecode(s) as Map).cast<String, Object?>(),
            ))
        .where((p) => p.id.isNotEmpty && p.path.isNotEmpty)
        .toList(growable: false);
  }

  Future<void> saveProjects({
    required String targetKey,
    required List<Project> projects,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = projects.map((p) => jsonEncode(p.toJson())).toList();
    await prefs.setStringList(_projectsKey(targetKey), raw);
  }

  Future<String?> loadLastProjectId({required String targetKey}) async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_lastProjectKey(targetKey));
    if (id == null || id.isEmpty) return null;
    return id;
  }

  Future<void> saveLastProjectId({
    required String targetKey,
    required String projectId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastProjectKey(targetKey), projectId);
  }
}

