import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/project_tab.dart';

class ProjectTabsStore {
  static String _keyFor(String targetKey, String projectPath) =>
      'project_tabs_v1:$targetKey:$projectPath';

  Future<List<ProjectTab>> loadTabs({
    required String targetKey,
    required String projectPath,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyFor(targetKey, projectPath));
    if (raw == null || raw.isEmpty) return const [];

    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((m) => ProjectTab.fromJson(m.cast<String, Object?>()))
            .where((t) => t.id.isNotEmpty)
            .toList(growable: false);
      }
    } catch (_) {}
    return const [];
  }

  Future<void> saveTabs({
    required String targetKey,
    required String projectPath,
    required List<ProjectTab> tabs,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(tabs.map((t) => t.toJson()).toList(growable: false));
    await prefs.setString(_keyFor(targetKey, projectPath), json);
  }
}

