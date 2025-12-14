import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:rinf/rinf.dart';
import 'package:workmanager/workmanager.dart';

import '../rinf/rust_hosts.dart';
import '../src/bindings/bindings.dart';
import '../services/notification_service.dart';
import '../services/remote_jobs_store.dart';
import '../services/secure_storage_service.dart';
import '../services/ssh_service.dart';

const codexRemoteBackgroundRefreshTaskId =
    'com.openai.codexremote.iOSBackgroundAppRefresh';

@pragma('vm:entry-point')
void codexRemoteCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      DartPluginRegistrant.ensureInitialized();
    } catch (_) {}

    try {
      await _checkRemoteJobs();
    } catch (_) {
      // Best-effort. Background execution isn't guaranteed.
    }
    return Future.value(true);
  });
}

Future<void> _checkRemoteJobs() async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
  } catch (_) {}

  try {
    await initializeRust(assignRustSignal);
    await startRustHosts();
  } catch (_) {
    // Best-effort: background isolate may not support all plugins/FFI.
  }

  final jobsStore = RemoteJobsStore();
  final jobs = await jobsStore.loadAll();
  if (jobs.isEmpty) return;

  final storage = SecureStorageService();
  final pem =
      await storage.read(key: SecureStorageService.sshPrivateKeyPemKey);
  if (pem == null || pem.trim().isEmpty) return;

  final ssh = SshService();
  final notifications = NotificationService();

  for (final job in jobs) {
    final stillRunning = await _isRemoteJobRunning(
      ssh: ssh,
      job: job,
      privateKeyPem: pem,
    );

    if (stillRunning) continue;

    final success = await _inferTurnSuccessFromRemoteLog(
      ssh: ssh,
      job: job,
      privateKeyPem: pem,
    );

    try {
      await notifications.notifyTurnFinished(
        projectPath: job.projectPath,
        success: success ?? true,
        tabId: job.tabId,
        threadId: job.threadId,
      );
    } catch (_) {}

    await jobsStore.remove(
      targetKey: job.targetKey,
      projectPath: job.projectPath,
      tabId: job.tabId,
    );
  }
}

Future<bool> _isRemoteJobRunning({
  required SshService ssh,
  required RemoteJobRecord job,
  required String privateKeyPem,
}) async {
  final String checkCmd;
  final id = job.remoteJobId;
  if (id.startsWith('tmux:')) {
    final name = id.substring('tmux:'.length);
    checkCmd = [
      'PATH="/opt/homebrew/bin:/usr/local/bin:\$HOME/.local/bin:\$PATH"; export PATH',
      'TMUX_BIN="\$(command -v tmux 2>/dev/null || true)"',
      'if [ -z "\$TMUX_BIN" ]; then',
      '  for p in /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do',
      '    if [ -x "\$p" ]; then TMUX_BIN="\$p"; break; fi',
      '  done',
      'fi',
      '[ -n "\$TMUX_BIN" ] || exit 127',
      '"\$TMUX_BIN" has-session -t ${_shQuote(name)}',
    ].join('\n');
  } else if (id.startsWith('pid:')) {
    final pid = id.substring('pid:'.length);
    checkCmd = 'kill -0 $pid >/dev/null 2>&1';
  } else {
    return false;
  }

  final res = await ssh.runCommandWithResult(
    host: job.host,
    port: job.port,
    username: job.username,
    privateKeyPem: privateKeyPem,
    command: 'sh -c ${_shQuote(checkCmd)}',
  );
  final code = res.exitCode ?? 1;
  return code == 0 || code == 127;
}

Future<bool?> _inferTurnSuccessFromRemoteLog({
  required SshService ssh,
  required RemoteJobRecord job,
  required String privateKeyPem,
}) async {
  final logAbs = _joinPosix(
    job.projectPath,
    '.codex_remote/sessions/${job.tabId}.log',
  );
  final cmd =
      'sh -c ${_shQuote('if [ -f ${_shQuote(logAbs)} ]; then tail -n 400 ${_shQuote(logAbs)}; fi')}';

  final res = await ssh.runCommandWithResult(
    host: job.host,
    port: job.port,
    username: job.username,
    privateKeyPem: privateKeyPem,
    command: cmd,
  );

  final lines = const LineSplitter().convert(res.stdout).reversed;
  for (final line in lines) {
    if (line.trim().isEmpty) continue;
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map) {
        final type = decoded['type']?.toString();
        if (type == 'turn.completed') return true;
        if (type == 'turn.failed') return false;
      }
    } catch (_) {}
  }
  return null;
}

String _joinPosix(String a, String b) {
  if (a.endsWith('/')) return '$a$b';
  return '$a/$b';
}

String _shQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";
