import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

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
  static String _shellEscape(String s) {
    if (s.isEmpty) return "''";
    final safe = RegExp(r'^[A-Za-z0-9_./:=@-]+$');
    if (safe.hasMatch(s)) return s;
    return "'${s.replaceAll("'", "'\\''")}'";
  }

  Future<String> runCommand({
    required String host,
    required int port,
    required String username,
    String? password,
    String? privateKeyPem,
    String? privateKeyPassphrase,
    required String command,
  }) async {
    final socket = await SSHSocket.connect(host, port);

    final identities = (privateKeyPem == null || privateKeyPem.trim().isEmpty)
        ? <SSHKeyPair>[]
        : SSHKeyPair.fromPem(privateKeyPem, privateKeyPassphrase).toList();

    final client = SSHClient(
      socket,
      username: username,
      identities: identities.isEmpty ? null : identities,
      onPasswordRequest: password == null ? null : () => password,
    );

    try {
      final bytes = await client.run(command);
      return utf8.decode(bytes);
    } finally {
      client.close();
    }
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
  }) async {
    final socket = await SSHSocket.connect(host, port);

    final identities = (privateKeyPem == null || privateKeyPem.trim().isEmpty)
        ? <SSHKeyPair>[]
        : SSHKeyPair.fromPem(privateKeyPem, privateKeyPassphrase).toList();

    final client = SSHClient(
      socket,
      username: username,
      identities: identities.isEmpty ? null : identities,
      onPasswordRequest: password == null ? null : () => password,
    );

    final session = await client.execute(command);
    try {
      if (stdin != null && stdin.isNotEmpty) {
        session.stdin.add(Uint8List.fromList(utf8.encode(stdin)));
      }
      await session.stdin.close();

      final outBytes = <int>[];
      final errBytes = <int>[];
      await Future.wait([
        session.stdout.listen(outBytes.addAll).asFuture<void>(),
        session.stderr.listen(errBytes.addAll).asFuture<void>(),
      ]);

      await session.done;
      return SshCommandResult(
        stdout: utf8.decode(outBytes, allowMalformed: true),
        stderr: utf8.decode(errBytes, allowMalformed: true),
        exitCode: session.exitCode,
      );
    } finally {
      client.close();
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
  }) async {
    final socket = await SSHSocket.connect(host, port);

    final identities = (privateKeyPem == null || privateKeyPem.trim().isEmpty)
        ? <SSHKeyPair>[]
        : SSHKeyPair.fromPem(privateKeyPem, privateKeyPassphrase).toList();

    final client = SSHClient(
      socket,
      username: username,
      identities: identities.isEmpty ? null : identities,
      onPasswordRequest: password == null ? null : () => password,
    );

    final remoteDir = remotePath.contains('/')
        ? remotePath.substring(0, remotePath.lastIndexOf('/'))
        : '.';

    // Avoid complex quoting by writing via stdin.
    final command =
        'mkdir -p ${_shellEscape(remoteDir)} && cat > ${_shellEscape(remotePath)}';
    final session = await client.execute(command);
    try {
      session.stdin.add(Uint8List.fromList(utf8.encode(contents)));
      await session.stdin.close();
      await session.done;
    } finally {
      client.close();
    }
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
  }) async {
    final socket = await SSHSocket.connect(host, port);

    final identities = (privateKeyPem == null || privateKeyPem.trim().isEmpty)
        ? <SSHKeyPair>[]
        : SSHKeyPair.fromPem(privateKeyPem, privateKeyPassphrase).toList();

    final client = SSHClient(
      socket,
      username: username,
      identities: identities.isEmpty ? null : identities,
      onPasswordRequest: password == null ? null : () => password,
    );

    final session = await client.execute(command);
    var cancelled = false;

    void cancel() {
      if (cancelled) return;
      cancelled = true;
      try {
        session.close();
      } catch (_) {}
      try {
        client.close();
      } catch (_) {}
    }

    if (stdin != null && stdin.isNotEmpty) {
      session.stdin.add(Uint8List.fromList(utf8.encode(stdin)));
      await session.stdin.close();
    }

    final done = session.done.whenComplete(() {
      try {
        client.close();
      } catch (_) {}
    });
    final exitCode = done.then((_) => session.exitCode);

    Stream<String> lines(Stream<Uint8List> bytes) async* {
      final decoder = const Utf8Decoder(allowMalformed: true);
      var pending = '';
      await for (final chunk in bytes) {
        pending += decoder.convert(chunk);
        var idx = pending.indexOf('\n');
        while (idx != -1) {
          yield pending.substring(0, idx).trimRight();
          pending = pending.substring(idx + 1);
          idx = pending.indexOf('\n');
        }
      }
      final tail = pending.trim();
      if (tail.isNotEmpty) yield tail;
    }

    return SshCommandProcess(
      stdoutLines: lines(session.stdout),
      stderrLines: lines(session.stderr),
      done: done,
      exitCode: exitCode,
      cancel: cancel,
    );
  }

  Future<void> installPublicKey({
    required String userAtHost,
    required int port,
    required String password,
    required String privateKeyPem,
    String? privateKeyPassphrase,
    String comment = 'codex-remote',
  }) async {
    final at = userAtHost.indexOf('@');
    if (at == -1) throw ArgumentError('userAtHost must be username@host');
    final username = userAtHost.substring(0, at);
    final host = userAtHost.substring(at + 1);

    final pairs = SSHKeyPair.fromPem(privateKeyPem, privateKeyPassphrase);
    if (pairs.isEmpty) throw StateError('No keys found in PEM.');

    final pair = pairs.first;
    final publicWire = pair.toPublicKey().encode();
    final publicB64 = base64.encode(publicWire);
    final publicLine = '${pair.name} $publicB64 $comment';

    final escaped = publicLine.replaceAll("'", "'\\''");
    final remoteCommand = [
      "umask 077",
      "mkdir -p ~/.ssh",
      "chmod 700 ~/.ssh",
      "touch ~/.ssh/authorized_keys",
      "chmod 600 ~/.ssh/authorized_keys",
      "grep -qxF '$escaped' ~/.ssh/authorized_keys || printf '%s\\n' '$escaped' >> ~/.ssh/authorized_keys",
    ].join('; ');

    final socket = await SSHSocket.connect(host, port);
    final client = SSHClient(
      socket,
      username: username,
      onPasswordRequest: () => password,
    );

    try {
      await client.run(remoteCommand, stdout: false);
    } finally {
      client.close();
    }
  }
}
