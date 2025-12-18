import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

class FieldExecdClient {
  static const protocolVersion = 1;

  static bool get supported => Platform.isMacOS || Platform.isLinux;

  Socket? _socket;
  StreamSubscription<String>? _sub;

  var _nextId = 1;
  final Map<int, Completer<Map<String, Object?>>> _pending = {};

  final Map<int, DaemonStream> _streams = {};

  bool get isConnected => _socket != null;

  static String? _home() => (Platform.environment['HOME'] ?? '').trim();

  static Directory? configDir() {
    if (!supported) return null;
    final h = _home();
    if (h == null || h.isEmpty) return null;
    return Directory('$h/.config/field_exec');
  }

  static File? stateFile() {
    final dir = configDir();
    if (dir == null) return null;
    return File('${dir.path}/field_execd.json');
  }

  Future<void> ensureConnected() async {
    if (!supported) return;
    if (_socket != null) return;

    final state = await _readState();
    if (state != null) {
      final ok = await _tryConnect(state);
      if (ok) return;
    }

    await _startDaemon();
    for (var i = 0; i < 30; i++) {
      final next = await _readState();
      if (next != null && await _tryConnect(next)) return;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    throw StateError('field_execd failed to start or connect.');
  }

  Future<_FieldExecdState?> _readState() async {
    final file = stateFile();
    if (file == null) return null;
    try {
      if (!await file.exists()) return null;
      final raw = (await file.readAsString()).trim();
      if (raw.isEmpty) return null;
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final port = (json['port'] as num?)?.toInt();
      final token = (json['token'] as String?)?.trim();
      final protocol = (json['protocol'] as num?)?.toInt() ?? protocolVersion;
      if (port == null || port <= 0) return null;
      if (token == null || token.isEmpty) return null;
      return _FieldExecdState(port: port, token: token, protocol: protocol);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _tryConnect(_FieldExecdState state) async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        state.port,
        timeout: const Duration(seconds: 1),
      );
      socket.setOption(SocketOption.tcpNoDelay, true);
      _socket = socket;

      _sub = socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleLine, onDone: _handleDone, onError: (_) => _handleDone());

      final hello = await request(
        method: 'hello',
        params: <String, Object?>{
          'token': state.token,
          'protocol': state.protocol,
        },
      );
      final proto = (hello['protocol'] as num?)?.toInt() ?? protocolVersion;
      if (proto != protocolVersion) {
        await close();
        return false;
      }

      return true;
    } catch (_) {
      await close();
      return false;
    }
  }

  Future<void> _startDaemon() async {
    final file = stateFile();
    if (file == null) return;
    await file.parent.create(recursive: true);

    final bin = await _resolveDaemonBinary();
    if (bin == null) {
      throw StateError(
        'field_execd binary not found. Run `cargo build -p field_execd` from the repo root.',
      );
    }

    try {
      await Process.start(
        bin,
        [
          '--port',
          '0',
          '--state-file',
          file.path,
        ],
        mode: ProcessStartMode.detached,
      );
    } catch (e) {
      throw StateError('Failed to start field_execd: $e');
    }
  }

  Future<String?> _resolveDaemonBinary() async {
    final override = (Platform.environment['FIELD_EXECD_PATH'] ?? '').trim();
    if (override.isNotEmpty && await File(override).exists()) return override;

    final cwd = Directory.current.path;
    final candidates = <String>[
      '$cwd/target/release/field_execd',
      '$cwd/target/debug/field_execd',
    ];

    for (final c in candidates) {
      if (await File(c).exists()) return c;
    }

    // Best-effort auto-build for debug/dev runs.
    if (!kReleaseMode) {
      try {
        final res = await Process.run(
          'cargo',
          const ['build', '-p', 'field_execd'],
          runInShell: true,
          workingDirectory: cwd,
        );
        if (res.exitCode == 0) {
          final built = '$cwd/target/debug/field_execd';
          if (await File(built).exists()) return built;
        }
      } catch (_) {}
    }

    return null;
  }

  void _handleDone() {
    final pending = Map<int, Completer<Map<String, Object?>>>.from(_pending);
    _pending.clear();
    for (final c in pending.values) {
      if (!c.isCompleted) {
        c.completeError(StateError('field_execd disconnected'));
      }
    }
    final streams = Map<int, DaemonStream>.from(_streams);
    _streams.clear();
    for (final s in streams.values) {
      s._closeWithError(StateError('field_execd disconnected'));
    }
    _socket = null;
  }

  void _handleLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    Object? msg;
    try {
      msg = jsonDecode(trimmed);
    } catch (_) {
      return;
    }
    if (msg is! Map) return;

    final type = (msg['type'] as String?)?.trim();
    if (type == 'stream_line') {
      final streamId = (msg['stream_id'] as num?)?.toInt();
      final isStderr = (msg['is_stderr'] as bool?) ?? false;
      final text = (msg['line'] as String?) ?? '';
      final s = streamId == null ? null : _streams[streamId];
      if (s == null) return;
      if (isStderr) {
        s._stderr.add(text);
      } else {
        s._stdout.add(text);
      }
      return;
    }

    if (type == 'stream_exit') {
      final streamId = (msg['stream_id'] as num?)?.toInt();
      final exitStatus = (msg['exit_status'] as num?)?.toInt();
      final err = (msg['error'] as String?)?.trim();
      final s = streamId == null ? null : _streams.remove(streamId);
      if (s == null) return;
      if (exitStatus != null) {
        s._exit.complete(exitStatus);
      } else {
        s._exit.complete(-1);
      }
      if (err != null && err.isNotEmpty) {
        // Keep stderr stream open; surface error via exit.
        s._stderr.add(err);
      }
      s._close();
      return;
    }

    final id = (msg['id'] as num?)?.toInt();
    if (id == null) return;
    final completer = _pending.remove(id);
    if (completer == null) return;

    final ok = (msg['ok'] as bool?) ?? false;
    final error = (msg['error'] as String?)?.trim();
    final result = msg['result'];
    if (!ok) {
      completer.completeError(StateError(error ?? 'field_execd error'));
      return;
    }
    if (result is Map<String, Object?>) {
      completer.complete(result);
      return;
    }
    if (result is Map) {
      completer.complete(Map<String, Object?>.from(result));
      return;
    }
    completer.complete(<String, Object?>{});
  }

  Future<Map<String, Object?>> request({
    required String method,
    required Map<String, Object?> params,
  }) async {
    await ensureConnected();
    final socket = _socket;
    if (socket == null) throw StateError('field_execd not connected');

    final id = _nextId++;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;

    final payload = jsonEncode(<String, Object?>{
      'id': id,
      'method': method,
      'params': params,
    });
    socket.write('$payload\n');
    await socket.flush();

    return completer.future;
  }

  Future<DaemonStream> startStream({
    required String method,
    required Map<String, Object?> params,
  }) async {
    final res = await request(method: method, params: params);
    final streamId = (res['stream_id'] as num?)?.toInt();
    if (streamId == null) {
      throw StateError('Missing stream_id from field_execd');
    }
    final s = DaemonStream(streamId);
    _streams[streamId] = s;
    return s;
  }

  Future<void> cancelStream(int streamId) async {
    try {
      await request(
        method: 'ssh.cancel',
        params: <String, Object?>{'stream_id': streamId},
      );
    } catch (_) {
      // Best-effort.
    }
  }

  Future<void> close() async {
    try {
      await _sub?.cancel();
    } catch (_) {}
    _sub = null;
    try {
      await _socket?.close();
    } catch (_) {}
    _socket = null;
  }
}

class _FieldExecdState {
  final int port;
  final String token;
  final int protocol;

  const _FieldExecdState({
    required this.port,
    required this.token,
    required this.protocol,
  });
}

class DaemonStream {
  final int streamId;

  final _stdout = StreamController<String>.broadcast();
  final _stderr = StreamController<String>.broadcast();
  final _exit = Completer<int>();

  DaemonStream(this.streamId);

  Stream<String> get stdoutLines => _stdout.stream;
  Stream<String> get stderrLines => _stderr.stream;
  Future<int> get exitCode => _exit.future;
  Future<void> get done async {
    await _exit.future;
  }

  void _close() {
    if (!_stdout.isClosed) _stdout.close();
    if (!_stderr.isClosed) _stderr.close();
  }

  void _closeWithError(Object e) {
    if (!_exit.isCompleted) _exit.completeError(e);
    _close();
  }
}
