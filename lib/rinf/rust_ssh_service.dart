import 'dart:async';

import '../src/bindings/bindings.dart';

class RustSshCommandResult {
  final String stdout;
  final String stderr;
  final int exitCode;

  const RustSshCommandResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
  });
}

class RustSshCommandProcess {
  final Stream<String> stdoutLines;
  final Stream<String> stderrLines;
  final Future<int?> exitCode;
  final Future<void> done;
  final void Function() cancel;

  const RustSshCommandProcess({
    required this.stdoutLines,
    required this.stderrLines,
    required this.exitCode,
    required this.done,
    required this.cancel,
  });
}

typedef RustPasswordProvider = Future<String?> Function();

class RustSshService {
  static int _nextRequestId = 1;

  static final _passwordProviders = <Uint64, RustPasswordProvider?>{};

  static final _pendingExec = <Uint64, Completer<RustSshCommandResult>>{};
  static final _pendingWrite = <Uint64, Completer<void>>{};
  static final _pendingStart = <Uint64, Completer<RustSshCommandProcess>>{};
  static final _pendingInstall = <Uint64, Completer<void>>{};
  static final _pendingKeyGen = <Uint64, Completer<String>>{};
  static final _pendingAuthorized = <Uint64, Completer<String>>{};

  static final _streams = <Uint64, _ActiveStream>{};

  static bool _started = false;

  static void start() {
    if (_started) return;
    _started = true;

    AuthRequired.rustSignalStream.listen((pack) {
      unawaited(_handleAuthRequired(pack.message));
    });

    SshExecResponse.rustSignalStream.listen((pack) {
      final resp = pack.message;
      final c = _pendingExec.remove(resp.requestId);
      _passwordProviders.remove(resp.requestId);
      if (c == null) return;
      if (!resp.ok) {
        c.completeError(resp.error ?? 'SSH failed');
        return;
      }
      c.complete(
        RustSshCommandResult(
          stdout: resp.stdout,
          stderr: resp.stderr,
          exitCode: resp.exitStatus,
        ),
      );
    });

    SshStartCommandResponse.rustSignalStream.listen((pack) {
      final resp = pack.message;
      final c = _pendingStart.remove(resp.requestId);
      _passwordProviders.remove(resp.requestId);
      if (c == null) return;
      if (!resp.ok) {
        c.completeError(resp.error ?? 'SSH start failed');
        return;
      }

      final stdout = StreamController<String>(sync: true);
      final stderr = StreamController<String>(sync: true);
      final exit = Completer<int?>();

      final active = _ActiveStream(
        stdout: stdout,
        stderr: stderr,
        exitCode: exit,
      );
      _streams[resp.streamId] = active;

      void cancel() {
        if (!_streams.containsKey(resp.streamId)) return;
        _streams.remove(resp.streamId);
        SshCancelStream(streamId: resp.streamId).sendSignalToRust();
        try {
          stdout.close();
        } catch (_) {}
        try {
          stderr.close();
        } catch (_) {}
        if (!exit.isCompleted) exit.complete(null);
      }

      final done = exit.future.then((_) async {
        if (!_streams.containsKey(resp.streamId)) return;
        _streams.remove(resp.streamId);
        try {
          await stdout.close();
        } catch (_) {}
        try {
          await stderr.close();
        } catch (_) {}
      });

      c.complete(
        RustSshCommandProcess(
          stdoutLines: stdout.stream,
          stderrLines: stderr.stream,
          exitCode: exit.future,
          done: done,
          cancel: cancel,
        ),
      );
    });

    SshStreamLine.rustSignalStream.listen((pack) {
      final msg = pack.message;
      final stream = _streams[msg.streamId];
      if (stream == null) return;
      if (msg.isStderr) {
        stream.stderr.add(msg.line);
      } else {
        stream.stdout.add(msg.line);
      }
    });

    SshStreamExit.rustSignalStream.listen((pack) {
      final msg = pack.message;
      final stream = _streams.remove(msg.streamId);
      if (stream == null) return;
      if (!stream.exitCode.isCompleted) {
        stream.exitCode.complete(msg.exitStatus);
      }
      try {
        stream.stdout.close();
      } catch (_) {}
      try {
        stream.stderr.close();
      } catch (_) {}
    });

    SshWriteFileResponse.rustSignalStream.listen((pack) {
      final resp = pack.message;
      final c = _pendingWrite.remove(resp.requestId);
      _passwordProviders.remove(resp.requestId);
      if (c == null) return;
      if (!resp.ok) {
        c.completeError(resp.error ?? 'SSH write failed');
      } else {
        c.complete();
      }
    });

    SshInstallPublicKeyResponse.rustSignalStream.listen((pack) {
      final resp = pack.message;
      final c = _pendingInstall.remove(resp.requestId);
      if (c == null) return;
      if (!resp.ok) {
        c.completeError(resp.error ?? 'Install failed');
      } else {
        c.complete();
      }
    });

    SshGenerateKeyResponse.rustSignalStream.listen((pack) {
      final resp = pack.message;
      final c = _pendingKeyGen.remove(resp.requestId);
      if (c == null) return;
      if (!resp.ok) {
        c.completeError(resp.error ?? 'Key generation failed');
      } else {
        c.complete(resp.privateKeyPem);
      }
    });

    SshAuthorizedKeyResponse.rustSignalStream.listen((pack) {
      final resp = pack.message;
      final c = _pendingAuthorized.remove(resp.requestId);
      if (c == null) return;
      if (!resp.ok) {
        c.completeError(resp.error ?? 'Public key derivation failed');
      } else {
        c.complete(resp.authorizedKeyLine);
      }
    });
  }

  static Uint64 _newRequestId() => Uint64.fromBigInt(BigInt.from(_nextRequestId++));

  static Future<RustSshCommandResult> runCommandWithResult({
    required String host,
    required int port,
    required String username,
    required String command,
    String? privateKeyPemOverride,
    String? privateKeyPassphrase,
    required Duration connectTimeout,
    required Duration commandTimeout,
    RustPasswordProvider? passwordProvider,
  }) {
    start();
    final requestId = _newRequestId();
    final c = Completer<RustSshCommandResult>();
    _pendingExec[requestId] = c;
    _passwordProviders[requestId] = passwordProvider;

    SshExecRequest(
      requestId: requestId,
      host: host,
      port: port,
      username: username,
      command: command,
      privateKeyPem: (privateKeyPemOverride == null || privateKeyPemOverride.trim().isEmpty)
          ? null
          : privateKeyPemOverride,
      privateKeyPassphrase:
          (privateKeyPassphrase == null || privateKeyPassphrase.trim().isEmpty)
              ? null
              : privateKeyPassphrase,
      connectTimeoutMs: connectTimeout.inMilliseconds,
      commandTimeoutMs: commandTimeout.inMilliseconds,
    ).sendSignalToRust();

    return c.future;
  }

  static Future<RustSshCommandProcess> startCommand({
    required String host,
    required int port,
    required String username,
    required String command,
    String? privateKeyPemOverride,
    String? privateKeyPassphrase,
    required Duration connectTimeout,
    RustPasswordProvider? passwordProvider,
  }) {
    start();
    final requestId = _newRequestId();
    final c = Completer<RustSshCommandProcess>();
    _pendingStart[requestId] = c;
    _passwordProviders[requestId] = passwordProvider;

    SshStartCommandRequest(
      requestId: requestId,
      host: host,
      port: port,
      username: username,
      command: command,
      privateKeyPem: (privateKeyPemOverride == null || privateKeyPemOverride.trim().isEmpty)
          ? null
          : privateKeyPemOverride,
      privateKeyPassphrase:
          (privateKeyPassphrase == null || privateKeyPassphrase.trim().isEmpty)
              ? null
              : privateKeyPassphrase,
      connectTimeoutMs: connectTimeout.inMilliseconds,
    ).sendSignalToRust();

    return c.future;
  }

  static Future<void> writeRemoteFile({
    required String host,
    required int port,
    required String username,
    required String remotePath,
    required String contents,
    String? privateKeyPemOverride,
    String? privateKeyPassphrase,
    required Duration connectTimeout,
    required Duration commandTimeout,
    RustPasswordProvider? passwordProvider,
  }) {
    start();
    final requestId = _newRequestId();
    final c = Completer<void>();
    _pendingWrite[requestId] = c;
    _passwordProviders[requestId] = passwordProvider;

    SshWriteFileRequest(
      requestId: requestId,
      host: host,
      port: port,
      username: username,
      remotePath: remotePath,
      contents: contents,
      privateKeyPem: (privateKeyPemOverride == null || privateKeyPemOverride.trim().isEmpty)
          ? null
          : privateKeyPemOverride,
      privateKeyPassphrase:
          (privateKeyPassphrase == null || privateKeyPassphrase.trim().isEmpty)
              ? null
              : privateKeyPassphrase,
      connectTimeoutMs: connectTimeout.inMilliseconds,
      commandTimeoutMs: commandTimeout.inMilliseconds,
    ).sendSignalToRust();

    return c.future;
  }

  static Future<String> generateEd25519PrivateKeyPem({String comment = 'codex-remote'}) {
    start();
    final requestId = _newRequestId();
    final c = Completer<String>();
    _pendingKeyGen[requestId] = c;
    SshGenerateKeyRequest(requestId: requestId, comment: comment).sendSignalToRust();
    return c.future;
  }

  static Future<String> toAuthorizedKeysLine({
    required String privateKeyPem,
    String? privateKeyPassphrase,
    String comment = 'codex-remote',
  }) {
    start();
    final requestId = _newRequestId();
    final c = Completer<String>();
    _pendingAuthorized[requestId] = c;
    SshAuthorizedKeyRequest(
      requestId: requestId,
      privateKeyPem: privateKeyPem,
      privateKeyPassphrase:
          (privateKeyPassphrase == null || privateKeyPassphrase.trim().isEmpty)
              ? null
              : privateKeyPassphrase,
      comment: comment,
    ).sendSignalToRust();
    return c.future;
  }

  static Future<void> installPublicKey({
    required String userAtHost,
    required int port,
    required String password,
    required String privateKeyPem,
    String? privateKeyPassphrase,
    String comment = 'codex-remote',
  }) {
    start();
    final requestId = _newRequestId();
    final c = Completer<void>();
    _pendingInstall[requestId] = c;
    SshInstallPublicKeyRequest(
      requestId: requestId,
      userAtHost: userAtHost,
      port: port,
      password: password,
      privateKeyPem: privateKeyPem,
      privateKeyPassphrase:
          (privateKeyPassphrase == null || privateKeyPassphrase.trim().isEmpty)
              ? null
              : privateKeyPassphrase,
      comment: comment,
    ).sendSignalToRust();
    return c.future;
  }

  static Future<void> _handleAuthRequired(AuthRequired req) async {
    final provider = _passwordProviders[req.requestId];
    if (provider == null) {
      AuthProvide(requestId: req.requestId, value: null).sendSignalToRust();
      return;
    }

    try {
      final password = (await provider())?.trim();
      if (password == null || password.isEmpty) {
        AuthProvide(requestId: req.requestId, value: null).sendSignalToRust();
      } else {
        AuthProvide(requestId: req.requestId, value: password).sendSignalToRust();
      }
    } catch (_) {
      AuthProvide(requestId: req.requestId, value: null).sendSignalToRust();
    }
  }
}

class _ActiveStream {
  final StreamController<String> stdout;
  final StreamController<String> stderr;
  final Completer<int?> exitCode;

  const _ActiveStream({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
  });
}
