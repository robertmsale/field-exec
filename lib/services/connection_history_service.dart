import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:design_system/design_system.dart';

import 'desktop_file_store.dart';

class ConnectionHistoryService {
  static const _profilesKey = 'connection_profiles_v1';
  static const _lastKey = 'connection_last_v1';

  Future<List<ConnectionProfile>> loadProfiles() async {
    if (DesktopFileStore.enabled) {
      final v = await DesktopFileStore.readJson(_profilesKey);
      if (v is List) {
        return v
            .whereType<Map>()
            .map((m) => ConnectionProfile.fromJson(m.cast<String, Object?>()))
            .where((p) => p.userAtHost.isNotEmpty)
            .toList(growable: false);
      }
      return const [];
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_profilesKey) ?? const <String>[];
    return raw
        .map(
          (s) => ConnectionProfile.fromJson(
            (jsonDecode(s) as Map).cast<String, Object?>(),
          ),
        )
        .where((p) => p.userAtHost.isNotEmpty)
        .toList(growable: false);
  }

  Future<void> saveProfiles(List<ConnectionProfile> profiles) async {
    if (DesktopFileStore.enabled) {
      await DesktopFileStore.writeJson(
        _profilesKey,
        profiles.map((p) => p.toJson()).toList(growable: false),
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = profiles.map((p) => jsonEncode(p.toJson())).toList();
    await prefs.setStringList(_profilesKey, raw);
  }

  Future<ConnectionProfile?> loadLast() async {
    if (DesktopFileStore.enabled) {
      final v = await DesktopFileStore.readJson(_lastKey);
      if (v is Map) {
        return ConnectionProfile.fromJson(v.cast<String, Object?>());
      }
      return null;
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_lastKey);
    if (raw == null || raw.isEmpty) return null;
    return ConnectionProfile.fromJson(
      (jsonDecode(raw) as Map).cast<String, Object?>(),
    );
  }

  Future<void> saveLast(ConnectionProfile profile) async {
    if (DesktopFileStore.enabled) {
      await DesktopFileStore.writeJson(_lastKey, profile.toJson());
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastKey, jsonEncode(profile.toJson()));
  }
}
