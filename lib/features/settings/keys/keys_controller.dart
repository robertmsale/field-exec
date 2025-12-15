import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../../services/local_ssh_keys_service.dart';
import '../../../services/secure_storage_service.dart';
import '../../../services/ssh_key_service.dart';

class KeysController extends KeysControllerBase {
  SecureStorageService get _storage => Get.find<SecureStorageService>();
  SshKeyService get _keys => Get.find<SshKeyService>();
  LocalSshKeysService get _localKeys => Get.find<LocalSshKeysService>();

  @override
  final pemController = TextEditingController();

  @override
  final busy = false.obs;

  @override
  final status = ''.obs;

  @override
  final scanningLocalKeys = false.obs;

  @override
  final localKeyCandidates = <LocalSshKeyCandidate>[].obs;

  @override
  void onInit() {
    super.onInit();
    load();
    unawaited(scanLocalKeys());
  }

  @override
  void onClose() {
    pemController.dispose();
    super.onClose();
  }

  @override
  Future<void> load() async {
    final pem = await _storage.read(
      key: SecureStorageService.sshPrivateKeyPemKey,
    );
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
    await _storage.write(
      key: SecureStorageService.sshPrivateKeyPemKey,
      value: pem,
    );
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
    await _storage.write(
      key: SecureStorageService.sshPrivateKeyPemKey,
      value: pem,
    );
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
    final line = await _keys.toAuthorizedKeysLine(privateKeyPem: pem);
    await Clipboard.setData(ClipboardData(text: line));
    status.value = 'Copied public key to clipboard.';
  }

  @override
  Future<void> scanLocalKeys() async {
    if (!LocalSshKeysService.supportsScan) {
      localKeyCandidates.assignAll(const []);
      return;
    }
    if (scanningLocalKeys.value) return;
    scanningLocalKeys.value = true;
    try {
      final candidates = await _localKeys.scan(maxCandidates: 50);
      localKeyCandidates.assignAll(candidates);
      if (candidates.isEmpty) status.value = 'No private keys found in ~/.ssh.';
    } finally {
      scanningLocalKeys.value = false;
    }
  }

  @override
  Future<void> useLocalKey(LocalSshKeyCandidate key) async {
    try {
      final contents = (await _localKeys.readPrivateKeyPem(key.path)).trim();
      if (contents.isEmpty) {
        status.value = 'Key file is empty: ${key.path}';
        return;
      }
      await _storage.write(
        key: SecureStorageService.sshPrivateKeyPemKey,
        value: contents,
      );
      pemController.text = contents;
      status.value = key.looksEncrypted
          ? 'Imported key (may be passphrase-protected).'
          : 'Imported key from ~/.ssh.';
    } catch (e) {
      status.value = 'Failed to import key: $e';
    }
  }
}
