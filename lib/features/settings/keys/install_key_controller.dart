import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../services/secure_storage_service.dart';
import '../../../services/ssh_service.dart';

class InstallKeyController extends InstallKeyControllerBase {
  SecureStorageService get _storage => Get.find<SecureStorageService>();
  SshService get _ssh => Get.find<SshService>();

  @override
  final targetController = TextEditingController();
  @override
  final portController = TextEditingController(text: '22');
  @override
  final passwordController = TextEditingController();

  @override
  final busy = false.obs;

  @override
  final status = ''.obs;

  @override
  void onClose() {
    targetController.dispose();
    portController.dispose();
    passwordController.dispose();
    super.onClose();
  }

  @override
  Future<void> install() async {
    final target = targetController.text.trim();
    final port = int.tryParse(portController.text.trim()) ?? 22;
    final password = passwordController.text;

    if (!target.contains('@')) {
      status.value = 'Enter username@host.';
      return;
    }
    if (password.isEmpty) {
      status.value = 'Password required for setup.';
      return;
    }

    final pem = await _storage.read(key: SecureStorageService.sshPrivateKeyPemKey);
    if (pem == null || pem.isEmpty) {
      status.value = 'No private key saved. Paste/import one first.';
      return;
    }

    status.value = 'Installing key...';
    await _ssh.installPublicKey(
      userAtHost: target,
      port: port,
      password: password,
      privateKeyPem: pem,
    );
    status.value = 'Installed. You should be able to connect with the key now.';
  }
}

