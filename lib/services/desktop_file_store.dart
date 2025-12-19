import 'dart:convert';
import 'dart:io';

/// A tiny, multi-window-safe (filesystem-based) store for desktop.
///
/// This avoids relying on plugins like shared_preferences in multiple Flutter
/// engines at once, which can be a source of deadlocks/hangs on some platforms.
class DesktopFileStore {
  static bool get enabled => Platform.isMacOS || Platform.isLinux;

  static Directory? _baseDir() {
    if (!enabled) return null;
    final home = (Platform.environment['HOME'] ?? '').trim();
    if (home.isEmpty) return null;
    return Directory('$home/.config/field_exec/store_v1');
  }

  static Future<File?> _fileForKey(String key) async {
    final base = _baseDir();
    if (base == null) return null;
    await base.create(recursive: true);
    try {
      // Keep it private.
      await Process.run('chmod', ['700', base.path]);
    } catch (_) {}
    final name = _fnv1a64Hex(key);
    return File('${base.path}/$name.json');
  }

  static Future<void> writeJson(String key, Object? value) async {
    final file = await _fileForKey(key);
    if (file == null) return;
    final tmp = File('${file.path}.tmp');
    final payload = jsonEncode(<String, Object?>{'key': key, 'value': value});
    await tmp.writeAsString(payload, flush: true);
    try {
      await Process.run('chmod', ['600', tmp.path]);
    } catch (_) {}
    await tmp.rename(file.path);
    try {
      await Process.run('chmod', ['600', file.path]);
    } catch (_) {}
  }

  static Future<Object?> readJson(String key) async {
    final file = await _fileForKey(key);
    if (file == null) return null;
    if (!await file.exists()) return null;
    try {
      final raw = (await file.readAsString()).trim();
      if (raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map) return decoded['value'];
    } catch (_) {}
    return null;
  }

  static Future<void> remove(String key) async {
    final file = await _fileForKey(key);
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  // Non-cryptographic, fast hash for stable filenames.
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
