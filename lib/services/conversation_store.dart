import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:design_system/design_system.dart';

import 'desktop_file_store.dart';

class ConversationStore {
  static String _key(String targetKey, String projectPath) =>
      'codex_conversations_v1:$targetKey:$projectPath';

  Future<List<Conversation>> load({
    required String targetKey,
    required String projectPath,
  }) async {
    if (DesktopFileStore.enabled) {
      final v = await DesktopFileStore.readJson(_key(targetKey, projectPath));
      final list = v is List ? v : const [];
      final items = <Conversation>[];
      for (final item in list) {
        try {
          if (item is Map) {
            items.add(Conversation.fromJson(item.cast<String, Object?>()));
          } else if (item is String) {
            final decoded = jsonDecode(item);
            if (decoded is Map) {
              items.add(Conversation.fromJson(decoded.cast<String, Object?>()));
            }
          }
        } catch (_) {}
      }
      final filtered = items.where((c) => c.threadId.isNotEmpty).toList();
      filtered.sort((a, b) => b.lastUsedAtMs.compareTo(a.lastUsedAtMs));
      return filtered;
    }
    final prefs = await SharedPreferences.getInstance();
    final raw =
        prefs.getStringList(_key(targetKey, projectPath)) ?? const <String>[];
    final items = raw
        .map(
          (s) => Conversation.fromJson(
            (jsonDecode(s) as Map).cast<String, Object?>(),
          ),
        )
        .where((c) => c.threadId.isNotEmpty)
        .toList(growable: false);
    items.sort((a, b) => b.lastUsedAtMs.compareTo(a.lastUsedAtMs));
    return items;
  }

  Future<void> upsert({
    required String targetKey,
    required String projectPath,
    required String threadId,
    required String preview,
    required String tabId,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final list = await load(targetKey: targetKey, projectPath: projectPath);
    final idx = list.indexWhere((c) => c.threadId == threadId);
    final next = [...list];

    if (idx == -1) {
      next.insert(
        0,
        Conversation(
          threadId: threadId,
          preview: preview,
          tabId: tabId,
          createdAtMs: now,
          lastUsedAtMs: now,
        ),
      );
    } else {
      final existing = next[idx];
      next[idx] = Conversation(
        threadId: existing.threadId,
        preview: existing.preview,
        tabId: existing.tabId.isNotEmpty ? existing.tabId : tabId,
        createdAtMs: existing.createdAtMs,
        lastUsedAtMs: now,
      );
    }

    final capped = next.take(50).toList(growable: false);
    if (DesktopFileStore.enabled) {
      await DesktopFileStore.writeJson(
        _key(targetKey, projectPath),
        capped.map((c) => c.toJson()).toList(growable: false),
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = capped.map((c) => jsonEncode(c.toJson())).toList();
    await prefs.setStringList(_key(targetKey, projectPath), raw);
  }
}
