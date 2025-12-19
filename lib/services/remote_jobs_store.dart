import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'desktop_file_store.dart';

class RemoteJobRecord {
  final String targetKey;
  final String host;
  final int port;
  final String username;
  final String projectPath;
  final String tabId;
  final String remoteJobId; // tmux:<name> or pid:<pid>
  final String? threadId;
  final int startedAtMsUtc;

  const RemoteJobRecord({
    required this.targetKey,
    required this.host,
    required this.port,
    required this.username,
    required this.projectPath,
    required this.tabId,
    required this.remoteJobId,
    required this.startedAtMsUtc,
    this.threadId,
  });

  String get key => '$targetKey|$projectPath|$tabId';

  Map<String, Object?> toJson() => {
    'targetKey': targetKey,
    'host': host,
    'port': port,
    'username': username,
    'projectPath': projectPath,
    'tabId': tabId,
    'remoteJobId': remoteJobId,
    'threadId': threadId,
    'startedAtMsUtc': startedAtMsUtc,
  };

  static RemoteJobRecord? fromJson(Map<String, Object?> json) {
    final targetKey = (json['targetKey'] as String?) ?? '';
    final host = (json['host'] as String?) ?? '';
    final port = json['port'];
    final username = (json['username'] as String?) ?? '';
    final projectPath = (json['projectPath'] as String?) ?? '';
    final tabId = (json['tabId'] as String?) ?? '';
    final remoteJobId = (json['remoteJobId'] as String?) ?? '';
    final startedAt = json['startedAtMsUtc'];

    final portInt = port is int ? port : int.tryParse(port?.toString() ?? '');
    final startedAtInt = startedAt is int
        ? startedAt
        : int.tryParse(startedAt?.toString() ?? '');

    if (targetKey.isEmpty ||
        host.isEmpty ||
        portInt == null ||
        username.isEmpty ||
        projectPath.isEmpty ||
        tabId.isEmpty ||
        remoteJobId.isEmpty ||
        startedAtInt == null) {
      return null;
    }

    return RemoteJobRecord(
      targetKey: targetKey,
      host: host,
      port: portInt,
      username: username,
      projectPath: projectPath,
      tabId: tabId,
      remoteJobId: remoteJobId,
      threadId: (json['threadId'] as String?)?.trim().isEmpty == true
          ? null
          : (json['threadId'] as String?),
      startedAtMsUtc: startedAtInt,
    );
  }
}

class RemoteJobsStore {
  static const _jobsKey = 'field_exec_active_jobs_v1';

  Future<List<RemoteJobRecord>> loadAll() async {
    if (DesktopFileStore.enabled) {
      final v = await DesktopFileStore.readJson(_jobsKey);
      final list = v is List ? v : const [];
      final out = <RemoteJobRecord>[];
      for (final item in list) {
        try {
          if (item is Map) {
            final rec = RemoteJobRecord.fromJson(item.cast<String, Object?>());
            if (rec != null) out.add(rec);
          } else if (item is String) {
            final decoded = jsonDecode(item);
            if (decoded is Map) {
              final rec = RemoteJobRecord.fromJson(
                decoded.cast<String, Object?>(),
              );
              if (rec != null) out.add(rec);
            }
          }
        } catch (_) {}
      }
      return out;
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_jobsKey) ?? const <String>[];
    final out = <RemoteJobRecord>[];
    for (final s in raw) {
      try {
        final decoded = jsonDecode(s);
        if (decoded is Map) {
          final rec = RemoteJobRecord.fromJson(decoded.cast<String, Object?>());
          if (rec != null) out.add(rec);
        }
      } catch (_) {}
    }
    return out;
  }

  Future<void> upsert(RemoteJobRecord record) async {
    final existing = await loadAll();

    final next = <RemoteJobRecord>[
      record,
      ...existing.where((r) => r.key != record.key),
    ];

    if (DesktopFileStore.enabled) {
      await DesktopFileStore.writeJson(
        _jobsKey,
        next.map((r) => r.toJson()).toList(growable: false),
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _jobsKey,
      next.map((r) => jsonEncode(r.toJson())).toList(growable: false),
    );
  }

  Future<void> remove({
    required String targetKey,
    required String projectPath,
    required String tabId,
  }) async {
    final existing = await loadAll();
    final key = '$targetKey|$projectPath|$tabId';
    final next = existing.where((r) => r.key != key).toList(growable: false);

    if (DesktopFileStore.enabled) {
      await DesktopFileStore.writeJson(
        _jobsKey,
        next.map((r) => r.toJson()).toList(growable: false),
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _jobsKey,
      next.map((r) => jsonEncode(r.toJson())).toList(growable: false),
    );
  }
}
