import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../services/secure_storage_service.dart';
import 'rust_ssh_service.dart';
import '../src/bindings/bindings.dart';

final _prefs = SharedPreferences.getInstance();
final _keychain = SecureStorageService();

StreamSubscription? _storageSub;

Future<void> startRustHosts() async {
  _storageSub ??= StorageRequest.rustSignalStream.listen((pack) {
    unawaited(_handleStorageRequest(pack.message));
  });
  RustSshService.start();
}

Future<void> _handleStorageRequest(StorageRequest req) async {
  try {
    if (req.scope == 0) {
      final prefs = await _prefs;
      if (req.op == 0) {
        final v = prefs.getString(req.key);
        StorageResponse(
          requestId: req.requestId,
          ok: true,
          value: v,
          error: null,
        ).sendSignalToRust();
        return;
      }
      if (req.op == 1) {
        final v = req.value;
        if (v == null) {
          StorageResponse(
            requestId: req.requestId,
            ok: false,
            value: null,
            error: 'Missing value for set_string',
          ).sendSignalToRust();
          return;
        }
        await prefs.setString(req.key, v);
        StorageResponse(
          requestId: req.requestId,
          ok: true,
          value: null,
          error: null,
        ).sendSignalToRust();
        return;
      }
      if (req.op == 2) {
        await prefs.remove(req.key);
        StorageResponse(
          requestId: req.requestId,
          ok: true,
          value: null,
          error: null,
        ).sendSignalToRust();
        return;
      }
    } else if (req.scope == 1) {
      if (req.op == 0) {
        final v = await _keychain.read(key: req.key);
        StorageResponse(
          requestId: req.requestId,
          ok: true,
          value: v,
          error: null,
        ).sendSignalToRust();
        return;
      }
      if (req.op == 1) {
        final v = req.value;
        if (v == null) {
          StorageResponse(
            requestId: req.requestId,
            ok: false,
            value: null,
            error: 'Missing value for set_string',
          ).sendSignalToRust();
          return;
        }
        await _keychain.write(key: req.key, value: v);
        StorageResponse(
          requestId: req.requestId,
          ok: true,
          value: null,
          error: null,
        ).sendSignalToRust();
        return;
      }
      if (req.op == 2) {
        await _keychain.delete(key: req.key);
        StorageResponse(
          requestId: req.requestId,
          ok: true,
          value: null,
          error: null,
        ).sendSignalToRust();
        return;
      }
    }

    StorageResponse(
      requestId: req.requestId,
      ok: false,
      value: null,
      error: 'Unsupported storage request (scope=${req.scope}, op=${req.op})',
    ).sendSignalToRust();
  } catch (e) {
    StorageResponse(
      requestId: req.requestId,
      ok: false,
      value: null,
      error: e.toString(),
    ).sendSignalToRust();
  }
}
