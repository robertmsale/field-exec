import 'package:shared_preferences/shared_preferences.dart';

class CodexSessionStore {
  static String _keyFor(
    String targetKey,
    String projectPath,
    String tabId,
  ) =>
      'codex_thread_v2:$targetKey:$projectPath:$tabId';

  static String _tmuxKeyFor(
    String targetKey,
    String projectPath,
    String tabId,
  ) =>
      'codex_tmux_v1:$targetKey:$projectPath:$tabId';

  static String _remoteJobKeyFor(
    String targetKey,
    String projectPath,
    String tabId,
  ) =>
      'codex_remote_job_v1:$targetKey:$projectPath:$tabId';

  Future<String?> loadThreadId({
    required String targetKey,
    required String projectPath,
    required String tabId,
  }) async {
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyFor(targetKey, projectPath, tabId), threadId);
  }

  Future<void> clearThreadId({
    required String targetKey,
    required String projectPath,
    required String tabId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyFor(targetKey, projectPath, tabId));
  }

  Future<String?> loadRemoteTmuxSessionName({
    required String targetKey,
    required String projectPath,
    required String tabId,
  }) async {
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tmuxKeyFor(targetKey, projectPath, tabId));
  }

  /// Stores the remote job identifier, e.g.:
  /// - `tmux:<sessionName>`
  /// - `pid:<pid>`
  Future<String?> loadRemoteJobId({
    required String targetKey,
    required String projectPath,
    required String tabId,
  }) async {
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_remoteJobKeyFor(targetKey, projectPath, tabId), remoteJobId);
  }

  Future<void> clearRemoteJobId({
    required String targetKey,
    required String projectPath,
    required String tabId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_remoteJobKeyFor(targetKey, projectPath, tabId));
  }
}
