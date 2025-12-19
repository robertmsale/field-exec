import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'desktop_file_store.dart';

class SessionScrollbackService {
  static const _key = 'field_exec_session_scrollback_lines_v1';
  static const int defaultLines = 400;

  final linesRx = defaultLines.obs;

  int get lines => linesRx.value;

  Future<void> init() async {
    if (DesktopFileStore.enabled) {
      final v = await DesktopFileStore.readJson(_key);
      final raw = v is int ? v : int.tryParse(v?.toString() ?? '');
      linesRx.value = clampLines(raw ?? defaultLines);
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getInt(_key);
    linesRx.value = clampLines(raw ?? defaultLines);
  }

  Future<void> setLines(int lines) async {
    final next = clampLines(lines);
    linesRx.value = next;
    if (DesktopFileStore.enabled) {
      await DesktopFileStore.writeJson(_key, next);
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key, next);
  }

  static int clampLines(int v) => v.clamp(200, 20000);
}
