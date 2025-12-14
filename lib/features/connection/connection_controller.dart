import 'dart:io';

import 'package:flutter/material.dart';
import 'package:design_system/design_system.dart';
import 'package:get/get.dart';

import '../../rinf/rust_ssh_service.dart';
import '../../services/connection_history_service.dart';
import '../../services/secure_storage_service.dart';

class ConnectionController extends ConnectionControllerBase {
  @override
  final userAtHostController = TextEditingController();
  @override
  final portController = TextEditingController(text: '22');
  @override
  final privateKeyPemController = TextEditingController();
  @override
  final privateKeyPassphraseController = TextEditingController();

  @override
  final useLocalRunner = (Platform.isMacOS).obs;

  @override
  final isBusy = false.obs;
  @override
  final status = ''.obs;
  @override
  final recentProfiles = <ConnectionProfile>[].obs;

  String? _sshPassword;

  SecureStorageService get _storage => Get.find<SecureStorageService>();
  ConnectionHistoryService get _history => Get.find<ConnectionHistoryService>();

  @override
  void onInit() {
    super.onInit();
    _loadKeyFromKeychain();
    _loadHistory();
  }

  @override
  void onClose() {
    portController.dispose();
    userAtHostController.dispose();
    privateKeyPemController.dispose();
    privateKeyPassphraseController.dispose();
    super.onClose();
  }

  Future<void> _loadHistory() async {
    final profiles = await _history.loadProfiles();
    recentProfiles.assignAll(profiles);
    final last = await _history.loadLast();
    if (last != null && last.userAtHost.isNotEmpty) {
      userAtHostController.text = last.userAtHost;
      portController.text = last.port.toString();
    }
  }

  Future<void> _loadKeyFromKeychain() async {
    final pem = await _storage.read(key: SecureStorageService.sshPrivateKeyPemKey);
    if (pem != null && pem.isNotEmpty) {
      privateKeyPemController.text = pem;
    }
  }

  @override
  Future<void> reloadKeyFromKeychain() => _loadKeyFromKeychain();

  @override
  Future<void> savePrivateKeyToKeychain() async {
    final pem = privateKeyPemController.text.trim();
    if (pem.isEmpty) {
      status.value = 'Private key PEM is empty.';
      return;
    }
    await _storage.write(key: SecureStorageService.sshPrivateKeyPemKey, value: pem);
    status.value = 'Saved private key PEM to Keychain.';
  }

  Future<String?> _promptForPassword() async {
    var value = '';
    return Get.dialog<String>(
      AlertDialog(
        title: const Text('Password required'),
        content: TextField(
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Password'),
          onChanged: (v) => value = v,
          onSubmitted: (v) => Get.back(result: v),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Get.back(result: value),
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }

  ConnectionProfile? _parseProfile() {
    final userAtHost = userAtHostController.text.trim();
    final port = int.tryParse(portController.text.trim()) ?? 22;

    if (!userAtHost.contains('@')) return null;
    final parts = userAtHost.split('@');
    if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) return null;

    return ConnectionProfile(userAtHost: userAtHost, port: port);
  }

  @override
  Future<void> runLocalCodex() async {
    if (!Platform.isMacOS) {
      status.value = 'Local runner only supported on macOS.';
      return;
    }
    Get.toNamed(DesignRoutes.projects, arguments: const TargetArgs.local());
  }

  @override
  Future<void> testSshConnection() async {
    final port = int.tryParse(portController.text.trim()) ?? 22;
    final profile = _parseProfile();
    if (profile == null) {
      status.value = 'Enter username@host.';
      return;
    }

    isBusy.value = true;
    status.value = 'Connecting...';
    try {
      final host = profile.host;
      final username = profile.username;

      final privateKeyPemOverride = privateKeyPemController.text.trim();
      final privateKeyPassphrase = privateKeyPassphraseController.text.trim();

      final res = await RustSshService.runCommandWithResult(
        host: host,
        port: port,
        username: username,
        command: 'whoami',
        privateKeyPemOverride:
            privateKeyPemOverride.isEmpty ? null : privateKeyPemOverride,
        privateKeyPassphrase:
            privateKeyPassphrase.isEmpty ? null : privateKeyPassphrase,
        connectTimeout: const Duration(seconds: 10),
        commandTimeout: const Duration(seconds: 10),
        passwordProvider: () async {
          if (_sshPassword != null && _sshPassword!.trim().isNotEmpty) {
            return _sshPassword;
          }
          final pw = await _promptForPassword();
          if (pw != null && pw.trim().isNotEmpty) _sshPassword = pw;
          return pw;
        },
      );

      status.value = 'SSH OK: ${res.stdout.trim()}';

      await _history.saveLast(profile);
      final existing = recentProfiles
          .where((p) => p.userAtHost == profile.userAtHost && p.port == port)
          .toList();
      final next = <ConnectionProfile>[profile, ...recentProfiles]
          .where((p) =>
              p.userAtHost.isNotEmpty &&
              !existing.any((e) =>
                  e.userAtHost == p.userAtHost && e.port == p.port))
          .take(10)
          .toList();
      recentProfiles.assignAll(next);
      await _history.saveProfiles(next);

      Get.toNamed(DesignRoutes.projects, arguments: TargetArgs.remote(profile));
    } catch (e) {
      status.value = 'SSH failed: $e';
    } finally {
      isBusy.value = false;
    }
  }
}
