import 'dart:async';

import '../rinf/rust_ssh_service.dart';

class SshCommandResult {
  final String stdout;
  final String stderr;
  final int? exitCode;

  const SshCommandResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
  });
}

class SshCommandProcess {
  final Stream<String> stdoutLines;
  final Stream<String> stderrLines;
  final Future<int?> exitCode;
  final Future<void> done;
  final void Function() cancel;

  const SshCommandProcess({
    required this.stdoutLines,
    required this.stderrLines,
    required this.exitCode,
    required this.done,
    required this.cancel,
  });
}

class SshService {
  static const defaultConnectTimeout = Duration(seconds: 10);
  static const defaultAuthTimeout = Duration(seconds: 10);
  static const defaultCommandTimeout = Duration(minutes: 2);

  static String _normalizeSshError(Object e) {
    final msg = e.toString();
    if (msg.contains('Password prompt cancelled') ||
        msg.contains('Password prompt timed out')) {
      return 'SSH authentication failed (password auth is not used). Verify your SSH key is installed and accepted by the server.';
    }
    if (msg.contains('SSH key authentication failed')) {
      return 'SSH key authentication failed. Verify your SSH key is installed and accepted by the server.';
    }
    if (msg.contains('SSH private key is invalid') ||
        msg.contains('passphrase is wrong')) {
      return 'SSH private key is invalid or passphrase is wrong.';
    }
    return msg;
  }

  Future<String> runCommand({
    required String host,
    required int port,
    required String username,
    String? password,
    String? privateKeyPem,
    String? privateKeyPassphrase,
    required String command,
    Duration connectTimeout = defaultConnectTimeout,
    Duration authTimeout = defaultAuthTimeout,
    Duration timeout = defaultCommandTimeout,
    int retries = 1,
  }) async {
    final res = await runCommandWithResult(
      host: host,
      port: port,
      username: username,
      password: password,
      privateKeyPem: privateKeyPem,
      privateKeyPassphrase: privateKeyPassphrase,
      command: command,
      connectTimeout: connectTimeout,
      authTimeout: authTimeout,
      timeout: timeout,
      retries: retries,
    );
    return res.stdout;
  }

  Future<SshCommandResult> runCommandWithResult({
    required String host,
    required int port,
    required String username,
    String? password,
    String? privateKeyPem,
    String? privateKeyPassphrase,
    required String command,
    String? stdin,
    Duration connectTimeout = defaultConnectTimeout,
    Duration authTimeout = defaultAuthTimeout,
    Duration timeout = defaultCommandTimeout,
    int retries = 1,
  }) async {
    SshCommandResult last = const SshCommandResult(stdout: '', stderr: '', exitCode: 1);
    Object? lastErr;

    for (var attempt = 0; attempt <= retries; attempt++) {
      try {
        if (stdin != null && stdin.isNotEmpty) {
          throw UnsupportedError('stdin is not supported via RustSshService.runCommandWithResult');
        }

        final res = await RustSshService.runCommandWithResult(
          host: host,
          port: port,
          username: username,
          command: command,
          privateKeyPemOverride: privateKeyPem,
          privateKeyPassphrase: privateKeyPassphrase,
          connectTimeout: connectTimeout,
          commandTimeout: timeout,
          passwordProvider: password == null ? null : () async => password,
        );

        return SshCommandResult(
          stdout: res.stdout,
          stderr: res.stderr,
          exitCode: res.exitCode,
        );
      } catch (e) {
        final normalized = _normalizeSshError(e);
        lastErr = StateError(normalized);
        last = SshCommandResult(stdout: '', stderr: normalized, exitCode: 1);
        if (attempt >= retries) break;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }

    if (lastErr != null) {
      // ignore: only_throw_errors
      throw lastErr;
    }
    return last;
  }

  Future<SshCommandProcess> startCommand({
    required String host,
    required int port,
    required String username,
    String? password,
    String? privateKeyPem,
    String? privateKeyPassphrase,
    required String command,
    String? stdin,
    Duration connectTimeout = defaultConnectTimeout,
    Duration authTimeout = defaultAuthTimeout,
  }) async {
    if (stdin != null && stdin.isNotEmpty) {
      throw UnsupportedError('stdin is not supported for startCommand');
    }

    try {
      final proc = await RustSshService.startCommand(
        host: host,
        port: port,
        username: username,
        command: command,
        privateKeyPemOverride: privateKeyPem,
        privateKeyPassphrase: privateKeyPassphrase,
        connectTimeout: connectTimeout,
        passwordProvider: password == null ? null : () async => password,
      );

      return SshCommandProcess(
        stdoutLines: proc.stdoutLines,
        stderrLines: proc.stderrLines,
        exitCode: proc.exitCode,
        done: proc.done,
        cancel: proc.cancel,
      );
    } catch (e) {
      throw StateError(_normalizeSshError(e));
    }
  }

  Future<void> writeRemoteFile({
    required String host,
    required int port,
    required String username,
    String? password,
    String? privateKeyPem,
    String? privateKeyPassphrase,
    required String remotePath,
    required String contents,
    Duration connectTimeout = defaultConnectTimeout,
    Duration authTimeout = defaultAuthTimeout,
    Duration timeout = defaultCommandTimeout,
    int retries = 1,
  }) async {
    for (var attempt = 0; attempt <= retries; attempt++) {
      try {
        await RustSshService.writeRemoteFile(
          host: host,
          port: port,
          username: username,
          remotePath: remotePath,
          contents: contents,
          privateKeyPemOverride: privateKeyPem,
          privateKeyPassphrase: privateKeyPassphrase,
          connectTimeout: connectTimeout,
          commandTimeout: timeout,
          passwordProvider: password == null ? null : () async => password,
        );
        return;
      } catch (e) {
        final normalized = _normalizeSshError(e);
        if (attempt >= retries) {
          throw StateError(normalized);
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
  }

  Future<void> installPublicKey({
    required String userAtHost,
    required int port,
    required String password,
    required String privateKeyPem,
    String? privateKeyPassphrase,
    String comment = 'field-exec',
  }) {
    return RustSshService.installPublicKey(
      userAtHost: userAtHost,
      port: port,
      password: password,
      privateKeyPem: privateKeyPem,
      privateKeyPassphrase: privateKeyPassphrase,
      comment: comment,
    );
  }
}
