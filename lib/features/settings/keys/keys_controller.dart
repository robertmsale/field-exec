import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../../services/secure_storage_service.dart';
import '../../../services/ssh_key_service.dart';

class KeysController extends KeysControllerBase {
  SecureStorageService get _storage => Get.find<SecureStorageService>();
  SshKeyService get _keys => Get.find<SshKeyService>();

  @override
  final pemController = TextEditingController();

  @override
  final busy = false.obs;

  @override
  final status = ''.obs;

  @override
  void onInit() {
    super.onInit();
    load();
  }

  @override
  void onClose() {
    pemController.dispose();
    super.onClose();
  }

  @override
  Future<void> load() async {
    final pem = await _storage.read(key: SecureStorageService.sshPrivateKeyPemKey);
    pemController.text = pem ?? '';
    status.value = pem == null || pem.isEmpty ? 'No key saved.' : 'Key loaded.';
  }

  @override
  Future<void> save() async {
    final pem = pemController.text.trim();
    if (pem.isEmpty) {
      status.value = 'PEM is empty.';
      return;
    }
    await _storage.write(key: SecureStorageService.sshPrivateKeyPemKey, value: pem);
    status.value = 'Saved.';
  }

  @override
  Future<void> deleteKey() async {
    await _storage.delete(key: SecureStorageService.sshPrivateKeyPemKey);
    pemController.text = '';
    status.value = 'Deleted.';
  }

  @override
  Future<void> generate() async {
    status.value = 'Generating...';
    final pem = await _keys.generateEd25519PrivateKeyPem();
    await _storage.write(key: SecureStorageService.sshPrivateKeyPemKey, value: pem);
    pemController.text = pem;
    status.value = 'Generated and saved.';
  }

  @override
  Future<void> copyPublicKey() async {
    final pem = pemController.text.trim();
    if (pem.isEmpty) {
      status.value = 'No private key to derive public key from.';
      return;
    }
    final line = _keys.toAuthorizedKeysLine(privateKeyPem: pem);
    await Clipboard.setData(ClipboardData(text: line));
    status.value = 'Copied public key to clipboard.';
  }
}

