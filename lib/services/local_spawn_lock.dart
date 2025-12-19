import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Cross-window (multi-engine) mutex for local-mode operations.
///
/// This is intended to prevent deadlocks/races when multiple desktop windows
/// try to spawn local Codex processes concurrently.
///
/// We intentionally implement this as an atomic `mkdir`-based lock rather than
/// file locks, since file locks are commonly process-scoped and all Flutter
/// desktop windows share a single process.
class LocalSpawnLock {
  static bool get supported => Platform.isMacOS || Platform.isLinux;

  final Directory _dir;

  LocalSpawnLock._(this._dir);

  static Directory? _baseDir() {
    if (!supported) return null;
    final home = (Platform.environment['HOME'] ?? '').trim();
    if (home.isEmpty) return null;
    return Directory('$home/.config/field_exec/locks_v1');
  }

  static Future<LocalSpawnLock> acquire({
    required String key,
    Duration timeout = const Duration(seconds: 20),
    Duration staleAfter = const Duration(minutes: 2),
  }) async {
    final base = _baseDir();
    if (base == null) return LocalSpawnLock._(Directory.systemTemp);

    await base.create(recursive: true);
    try {
      await Process.run('chmod', ['700', base.path]);
    } catch (_) {}

    final name = _fnv1a64Hex(key);
    final dir = Directory('${base.path}/$name.lock');

    final deadline = DateTime.now().add(timeout);
    var delayMs = 50;

    while (DateTime.now().isBefore(deadline)) {
      try {
        await dir.create(recursive: false);
        await _writeOwnerFile(dir, key: key);
        try {
          await Process.run('chmod', ['700', dir.path]);
        } catch (_) {}
        return LocalSpawnLock._(dir);
      } on FileSystemException catch (_) {
        // Lock already held. Check for staleness and retry.
        try {
          final stat = await dir.stat();
          final age = DateTime.now().difference(stat.modified);
          if (age > staleAfter) {
            await dir.delete(recursive: true);
            continue;
          }
        } catch (_) {}
        await Future<void>.delayed(Duration(milliseconds: delayMs));
        delayMs = (delayMs * 2).clamp(50, 250);
      }
    }

    throw TimeoutException('Timed out waiting for local spawn lock: $key');
  }

  Future<void> release() async {
    if (!supported) return;
    try {
      if (await _dir.exists()) await _dir.delete(recursive: true);
    } catch (_) {}
  }

  static Future<void> _writeOwnerFile(
    Directory dir, {
    required String key,
  }) async {
    try {
      final payload = jsonEncode(<String, Object?>{
        'key': key,
        'pid': pid,
        'created_at_ms': DateTime.now().millisecondsSinceEpoch,
      });
      final file = File('${dir.path}/owner.json');
      await file.writeAsString(payload, flush: true);
      try {
        await Process.run('chmod', ['600', file.path]);
      } catch (_) {}
    } catch (_) {}
  }

  static String _fnv1a64Hex(String input) {
    const int fnvOffsetBasis = 0xcbf29ce484222325;
    const int fnvPrime = 0x100000001b3;

    var hash = fnvOffsetBasis;
    final bytes = utf8.encode(input);
    for (final b in bytes) {
      hash ^= b;
      hash = (hash * fnvPrime) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}
