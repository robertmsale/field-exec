import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:design_system/design_system.dart';

import 'desktop_file_store.dart';

class ProjectStore {
  static String _projectsKey(String targetKey) => 'projects_v1:$targetKey';
  static String _lastProjectKey(String targetKey) =>
      'projects_last_v1:$targetKey';

  Future<List<Project>> loadProjects({required String targetKey}) async {
    if (DesktopFileStore.enabled) {
      final v = await DesktopFileStore.readJson(_projectsKey(targetKey));
      if (v is List) {
        return v
            .whereType<Map>()
            .map((m) => Project.fromJson(m.cast<String, Object?>()))
            .where((p) => p.id.isNotEmpty && p.path.isNotEmpty)
            .toList(growable: false);
      }
      return const [];
    }
    final prefs = await SharedPreferences.getInstance();
    final raw =
        prefs.getStringList(_projectsKey(targetKey)) ?? const <String>[];
    return raw
        .map(
          (s) =>
              Project.fromJson((jsonDecode(s) as Map).cast<String, Object?>()),
        )
        .where((p) => p.id.isNotEmpty && p.path.isNotEmpty)
        .toList(growable: false);
  }

  Future<void> saveProjects({
    required String targetKey,
    required List<Project> projects,
  }) async {
    if (DesktopFileStore.enabled) {
      await DesktopFileStore.writeJson(
        _projectsKey(targetKey),
        projects.map((p) => p.toJson()).toList(growable: false),
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = projects.map((p) => jsonEncode(p.toJson())).toList();
    await prefs.setStringList(_projectsKey(targetKey), raw);
  }

  Future<String?> loadLastProjectId({required String targetKey}) async {
    if (DesktopFileStore.enabled) {
      final v = await DesktopFileStore.readJson(_lastProjectKey(targetKey));
      final id = (v as String?)?.trim() ?? '';
      return id.isEmpty ? null : id;
    }
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_lastProjectKey(targetKey));
    if (id == null || id.isEmpty) return null;
    return id;
  }

  Future<void> saveLastProjectId({
    required String targetKey,
    required String projectId,
  }) async {
    if (DesktopFileStore.enabled) {
      await DesktopFileStore.writeJson(_lastProjectKey(targetKey), projectId);
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastProjectKey(targetKey), projectId);
  }
}
