import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../services/secure_storage_service.dart';
import '../../../services/ssh_service.dart';

class InstallKeyPage extends StatefulWidget {
  const InstallKeyPage({super.key});

  @override
  State<InstallKeyPage> createState() => _InstallKeyPageState();
}

class _InstallKeyPageState extends State<InstallKeyPage> {
  final _targetController = TextEditingController();
  final _portController = TextEditingController(text: '22');
  final _passwordController = TextEditingController();

  final _busy = false.obs;
  final _status = ''.obs;

  SecureStorageService get _storage => Get.find<SecureStorageService>();
  SshService get _ssh => Get.find<SshService>();

  @override
  void dispose() {
    _targetController.dispose();
    _portController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _install() async {
    final target = _targetController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? 22;
    final password = _passwordController.text;

    if (!target.contains('@')) {
      _status.value = 'Enter username@host.';
      return;
    }
    if (password.isEmpty) {
      _status.value = 'Password required for setup.';
      return;
    }

    final pem = await _storage.read(key: SecureStorageService.sshPrivateKeyPemKey);
    if (pem == null || pem.isEmpty) {
      _status.value = 'No private key saved. Paste/import one first.';
      return;
    }

    _status.value = 'Installing key...';
    await _ssh.installPublicKey(
      userAtHost: target,
      port: port,
      password: password,
      privateKeyPem: pem,
    );
    _status.value = 'Installed. You should be able to connect with the key now.';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Install Key')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _targetController,
              decoration: const InputDecoration(
                labelText: 'username@host',
                hintText: 'robert@mac.local',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _portController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Port'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
            ),
            const SizedBox(height: 16),
            Obx(
              () => FilledButton(
                onPressed: _busy.value
                    ? null
                    : () async {
                        _busy.value = true;
                        try {
                          await _install();
                        } finally {
                          _busy.value = false;
                        }
                      },
                child: Text(_busy.value ? 'Working...' : 'Install'),
              ),
            ),
            const SizedBox(height: 12),
            Obx(() => Text(_status.value)),
          ],
        ),
      ),
    );
  }
}
