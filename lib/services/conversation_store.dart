import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:design_system/design_system.dart';

class ConversationStore {
  static String _key(String targetKey, String projectPath) =>
      'codex_conversations_v1:$targetKey:$projectPath';

  Future<List<Conversation>> load({
    required String targetKey,
    required String projectPath,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key(targetKey, projectPath)) ?? const <String>[];
    final items = raw
        .map((s) => Conversation.fromJson(
              (jsonDecode(s) as Map).cast<String, Object?>(),
            ))
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
    final prefs = await SharedPreferences.getInstance();
    final raw = capped.map((c) => jsonEncode(c.toJson())).toList();
    await prefs.setStringList(_key(targetKey, projectPath), raw);
  }
}
