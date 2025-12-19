import 'package:shared_preferences/shared_preferences.dart';

import 'desktop_file_store.dart';

class FieldExecSessionStore {
  static String _keyFor(String targetKey, String projectPath, String tabId) =>
      'field_exec_thread_v2:$targetKey:$projectPath:$tabId';

  static String _tmuxKeyFor(
    String targetKey,
    String projectPath,
    String tabId,
  ) => 'field_exec_tmux_v1:$targetKey:$projectPath:$tabId';

  static String _remoteJobKeyFor(
    String targetKey,
    String projectPath,
    String tabId,
  ) => 'field_exec_remote_job_v1:$targetKey:$projectPath:$tabId';

  static String _logCursorKeyFor(
    String targetKey,
    String projectPath,
    String tabId,
  ) => 'field_exec_log_cursor_v1:$targetKey:$projectPath:$tabId';

  static String _logLastLineHashKeyFor(
    String targetKey,
    String projectPath,
    String tabId,
  ) => 'field_exec_log_last_line_hash_v1:$targetKey:$projectPath:$tabId';

  Future<String?> loadThreadId({
    required String targetKey,
    required String projectPath,
    required String tabId,
  }) async {
    if (DesktopFileStore.enabled) {
      final v = await DesktopFileStore.readJson(
        _keyFor(targetKey, projectPath, tabId),
      );
      final s = (v as String?)?.trim() ?? '';
      return s.isEmpty ? null : s;
    }
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_keyFor(targetKey, projectPath, tabId));
    if (id == null || id.isEmpty) return null;
    return id;
  }

  Future<void> saveThreadId({
    required String targetKey,
    required String projectPath,
    required String tabId,
    required String threadId,
  }) async {
    if (DesktopFileStore.enabled) {
      await DesktopFileStore.writeJson(
        _keyFor(targetKey, projectPath, tabId),
        threadId,
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyFor(targetKey, projectPath, tabId), threadId);
  }

  Future<void> clearThreadId({
    required String targetKey,
    required String projectPath,
    required String tabId,
  }) async {
    if (DesktopFileStore.enabled) {
      await DesktopFileStore.remove(_keyFor(targetKey, projectPath, tabId));
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyFor(targetKey, projectPath, tabId));
  }

  Future<String?> loadRemoteTmuxSessionName({
    required String targetKey,
    required String projectPath,
    required String tabId,
  }) async {
    if (DesktopFileStore.enabled) {
      final v = await DesktopFileStore.readJson(
        _tmuxKeyFor(targetKey, projectPath, tabId),
      );
      final s = (v as String?)?.trim() ?? '';
      return s.isEmpty ? null : s;
    }
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_tmuxKeyFor(targetKey, projectPath, tabId));
    if (name == null || name.isEmpty) return null;
    return name;
  }

  Future<void> saveRemoteTmuxSessionName({
    required String targetKey,
    required String projectPath,
    required String tabId,
    required String tmuxSessionName,
  }) async {
    if (DesktopFileStore.enabled) {
      await DesktopFileStore.writeJson(
        _tmuxKeyFor(targetKey, projectPath, tabId),
        tmuxSessionName,
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _tmuxKeyFor(targetKey, projectPath, tabId),
      tmuxSessionName,
    );
  }

  Future<void> clearRemoteTmuxSessionName({
    required String targetKey,
    required String projectPath,
    required String tabId,
  }) async {
    if (DesktopFileStore.enabled) {
      await DesktopFileStore.remove(_tmuxKeyFor(targetKey, projectPath, tabId));
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tmuxKeyFor(targetKey, projectPath, tabId));
  }

  /// Stores the remote job identifier, e.g.:
  /// - `tmux:<sessionName>`
  /// - `tmux:<projectSessionName>:<windowName>`
  /// - `pid:<pid>`
  Future<String?> loadRemoteJobId({
    required String targetKey,
    required String projectPath,
    required String tabId,
  }) async {
    if (DesktopFileStore.enabled) {
      final v = await DesktopFileStore.readJson(
        _remoteJobKeyFor(targetKey, projectPath, tabId),
      );
      final s = (v as String?)?.trim() ?? '';
      return s.isEmpty ? null : s;
    }
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_remoteJobKeyFor(targetKey, projectPath, tabId));
    if (id == null || id.isEmpty) return null;
    return id;
  }

  Future<void> saveRemoteJobId({
    required String targetKey,
    required String projectPath,
    required String tabId,
    required String remoteJobId,
  }) async {
    if (DesktopFileStore.enabled) {
      await DesktopFileStore.writeJson(
        _remoteJobKeyFor(targetKey, projectPath, tabId),
        remoteJobId,
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _remoteJobKeyFor(targetKey, projectPath, tabId),
      remoteJobId,
    );
  }

  Future<void> clearRemoteJobId({
    required String targetKey,
    required String projectPath,
    required String tabId,
  }) async {
    if (DesktopFileStore.enabled) {
      await DesktopFileStore.remove(
        _remoteJobKeyFor(targetKey, projectPath, tabId),
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_remoteJobKeyFor(targetKey, projectPath, tabId));
  }

  /// Stores the last consumed line number (1-based) for this tab's JSONL log.
  /// Used to resume tailing without missing output after sleep/background/app restarts.
  Future<int> loadLogLineCursor({
    required String targetKey,
    required String projectPath,
    required String tabId,
  }) async {
    if (DesktopFileStore.enabled) {
      final v = await DesktopFileStore.readJson(
        _logCursorKeyFor(targetKey, projectPath, tabId),
      );
      final n = v is int ? v : int.tryParse(v?.toString() ?? '');
      if (n == null || n < 0) return 0;
      return n;
    }
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getInt(_logCursorKeyFor(targetKey, projectPath, tabId));
    if (v == null || v < 0) return 0;
    return v;
  }

  Future<void> saveLogLineCursor({
    required String targetKey,
    required String projectPath,
    required String tabId,
    required int cursor,
  }) async {
    if (DesktopFileStore.enabled) {
      await DesktopFileStore.writeJson(
        _logCursorKeyFor(targetKey, projectPath, tabId),
        cursor,
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_logCursorKeyFor(targetKey, projectPath, tabId), cursor);
  }

  Future<void> clearLogLineCursor({
    required String targetKey,
    required String projectPath,
    required String tabId,
  }) async {
    if (DesktopFileStore.enabled) {
      await DesktopFileStore.remove(
        _logCursorKeyFor(targetKey, projectPath, tabId),
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_logCursorKeyFor(targetKey, projectPath, tabId));
  }

  /// Stores a hash of the last observed JSONL line for this tab's log.
  /// Used as a resilient resume marker when line counts/cursors are unreliable.
  Future<String?> loadLogLastLineHash({
    required String targetKey,
    required String projectPath,
    required String tabId,
  }) async {
    if (DesktopFileStore.enabled) {
      final v = await DesktopFileStore.readJson(
        _logLastLineHashKeyFor(targetKey, projectPath, tabId),
      );
      final trimmed = (v as String?)?.trim() ?? '';
      return trimmed.isEmpty ? null : trimmed;
    }
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(
      _logLastLineHashKeyFor(targetKey, projectPath, tabId),
    );
    final trimmed = (v ?? '').trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  Future<void> saveLogLastLineHash({
    required String targetKey,
    required String projectPath,
    required String tabId,
    required String hash,
  }) async {
    if (DesktopFileStore.enabled) {
      await DesktopFileStore.writeJson(
        _logLastLineHashKeyFor(targetKey, projectPath, tabId),
        hash.trim(),
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _logLastLineHashKeyFor(targetKey, projectPath, tabId),
      hash.trim(),
    );
  }

  Future<void> clearLogLastLineHash({
    required String targetKey,
    required String projectPath,
    required String tabId,
  }) async {
    if (DesktopFileStore.enabled) {
      await DesktopFileStore.remove(
        _logLastLineHashKeyFor(targetKey, projectPath, tabId),
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_logLastLineHashKeyFor(targetKey, projectPath, tabId));
  }
}
