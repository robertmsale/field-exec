import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../app/routes/app_routes.dart';
import '../../models/connection_profile.dart';
import '../../services/connection_history_service.dart';
import '../../services/secure_storage_service.dart';
import '../../services/ssh_service.dart';
import '../projects/target_args.dart';

class ConnectionController extends GetxController {
  final userAtHostController = TextEditingController();
  final portController = TextEditingController(text: '22');
  final privateKeyPemController = TextEditingController();
  final privateKeyPassphraseController = TextEditingController();

  final useLocalRunner = (Platform.isMacOS).obs;

  final isBusy = false.obs;
  final status = ''.obs;
  final recentProfiles = <ConnectionProfile>[].obs;

  SecureStorageService get _storage => Get.find<SecureStorageService>();
  ConnectionHistoryService get _history => Get.find<ConnectionHistoryService>();
  SshService get _ssh => Get.find<SshService>();

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

  Future<void> reloadKeyFromKeychain() => _loadKeyFromKeychain();

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

  Future<void> runLocalCodex() async {
    if (!Platform.isMacOS) {
      status.value = 'Local runner only supported on macOS.';
      return;
    }
    Get.toNamed(AppRoutes.projects, arguments: const TargetArgs.local());
  }

  Future<void> testSshConnection() async {
    final port = int.tryParse(portController.text.trim()) ?? 22;
    final profile = _parseProfile();
    if (profile == null) {
      status.value = 'Enter username@host.';
      return;
    }

    final host = profile.host;
    final username = profile.username;
    var privateKeyPem = privateKeyPemController.text.trim();
    if (privateKeyPem.isEmpty) {
      final fromKeychain =
          (await _storage.read(key: SecureStorageService.sshPrivateKeyPemKey))
              ?.trim();
      if (fromKeychain != null && fromKeychain.isNotEmpty) {
        privateKeyPem = fromKeychain;
        privateKeyPemController.text = fromKeychain;
      }
    }
    final privateKeyPassphrase = privateKeyPassphraseController.text;

    isBusy.value = true;
    status.value = 'Connecting...';
    try {
      final keyAvailable = privateKeyPem.trim().isNotEmpty;

      String? password;
      if (!keyAvailable) {
        password = await _promptForPassword();
        if (password == null || password.isEmpty) {
          status.value = 'Cancelled.';
          return;
        }
      }

      final output = await _ssh.runCommand(
        host: host,
        port: port,
        username: username,
        password: password,
        privateKeyPem: privateKeyPem.isEmpty ? null : privateKeyPem,
        privateKeyPassphrase:
            privateKeyPassphrase.isEmpty ? null : privateKeyPassphrase,
        command: 'whoami',
      );
      status.value = 'SSH OK: ${output.trim()}';

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

      Get.toNamed(AppRoutes.projects, arguments: TargetArgs.remote(profile));
    } catch (e) {
      // If key auth failed, prompt password and retry (password isn't stored).
      final keyAvailable = privateKeyPem.trim().isNotEmpty;
      if (keyAvailable) {
        final pw = await _promptForPassword();
        if (pw != null && pw.isNotEmpty) {
          try {
            final output = await _ssh.runCommand(
              host: host,
              port: port,
              username: username,
              password: pw,
              privateKeyPem: privateKeyPem.isEmpty ? null : privateKeyPem,
              privateKeyPassphrase:
                  privateKeyPassphrase.isEmpty ? null : privateKeyPassphrase,
              command: 'whoami',
            );
            status.value = 'SSH OK: ${output.trim()}';

            await _history.saveLast(profile);
            Get.toNamed(AppRoutes.projects, arguments: TargetArgs.remote(profile));
            return;
          } catch (_) {
            // fall through
          }
        }
      }
      status.value = 'SSH failed: $e';
    } finally {
      isBusy.value = false;
    }
  }
}
