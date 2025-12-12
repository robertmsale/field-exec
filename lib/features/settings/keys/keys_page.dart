import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../../services/secure_storage_service.dart';
import '../../../services/ssh_key_service.dart';
import 'install_key_page.dart';

class KeysPage extends StatefulWidget {
  const KeysPage({super.key});

  @override
  State<KeysPage> createState() => _KeysPageState();
}

class _KeysPageState extends State<KeysPage> {
  final _pemController = TextEditingController();
  final _busy = false.obs;
  final _status = ''.obs;

  SecureStorageService get _storage => Get.find<SecureStorageService>();
  SshKeyService get _keys => Get.find<SshKeyService>();

  @override
  void dispose() {
    _pemController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final pem = await _storage.read(key: SecureStorageService.sshPrivateKeyPemKey);
    _pemController.text = pem ?? '';
    _status.value = pem == null || pem.isEmpty ? 'No key saved.' : 'Key loaded.';
  }

  Future<void> _save() async {
    final pem = _pemController.text.trim();
    if (pem.isEmpty) {
      _status.value = 'PEM is empty.';
      return;
    }
    await _storage.write(key: SecureStorageService.sshPrivateKeyPemKey, value: pem);
    _status.value = 'Saved.';
  }

  Future<void> _delete() async {
    await _storage.delete(key: SecureStorageService.sshPrivateKeyPemKey);
    _pemController.text = '';
    _status.value = 'Deleted.';
  }

  Future<void> _generate() async {
    _status.value = 'Generating...';
    final pem = await _keys.generateEd25519PrivateKeyPem();
    await _storage.write(key: SecureStorageService.sshPrivateKeyPemKey, value: pem);
    _pemController.text = pem;
    _status.value = 'Generated and saved.';
  }

  Future<void> _copyPublicKey() async {
    final pem = _pemController.text.trim();
    if (pem.isEmpty) {
      _status.value = 'No private key to derive public key from.';
      return;
    }
    final line = _keys.toAuthorizedKeysLine(privateKeyPem: pem);
    await Clipboard.setData(ClipboardData(text: line));
    _status.value = 'Copied public key to clipboard.';
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SSH Keys')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Global Private Key (PEM)',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _pemController,
              maxLines: 10,
              decoration: const InputDecoration(
                hintText: 'Paste an OpenSSH private key PEM here',
              ),
            ),
            const SizedBox(height: 12),
            Obx(
              () => Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: _busy.value
                          ? null
                          : () async {
                              _busy.value = true;
                              try {
                                await _save();
                              } finally {
                                _busy.value = false;
                              }
                            },
                      child: const Text('Save'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy.value
                          ? null
                          : () async {
                              _busy.value = true;
                              try {
                                await _delete();
                              } finally {
                                _busy.value = false;
                              }
                            },
                      child: const Text('Delete'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Obx(
              () => Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy.value
                          ? null
                          : () async {
                              _busy.value = true;
                              try {
                                await _generate();
                              } finally {
                                _busy.value = false;
                              }
                            },
                      child: const Text('Generate New Key'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy.value
                          ? null
                          : () async {
                              _busy.value = true;
                              try {
                                await _copyPublicKey();
                              } finally {
                                _busy.value = false;
                              }
                            },
                      child: const Text('Copy Public Key'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Obx(() => Text(_status.value)),
            const SizedBox(height: 24),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Install key on server'),
              subtitle: const Text('Password-based setup, then key auth'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const InstallKeyPage()),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
