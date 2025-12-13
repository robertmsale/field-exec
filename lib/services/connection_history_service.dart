import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:design_system/design_system.dart';

class ConnectionHistoryService {
  static const _profilesKey = 'connection_profiles_v1';
  static const _lastKey = 'connection_last_v1';

  Future<List<ConnectionProfile>> loadProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_profilesKey) ?? const <String>[];
    return raw
        .map((s) => ConnectionProfile.fromJson(
              (jsonDecode(s) as Map).cast<String, Object?>(),
            ))
        .where((p) => p.userAtHost.isNotEmpty)
        .toList(growable: false);
  }

  Future<void> saveProfiles(List<ConnectionProfile> profiles) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = profiles.map((p) => jsonEncode(p.toJson())).toList();
    await prefs.setStringList(_profilesKey, raw);
  }

  Future<ConnectionProfile?> loadLast() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_lastKey);
    if (raw == null || raw.isEmpty) return null;
    return ConnectionProfile.fromJson(
      (jsonDecode(raw) as Map).cast<String, Object?>(),
    );
  }

  Future<void> saveLast(ConnectionProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastKey, jsonEncode(profile.toJson()));
  }
}
