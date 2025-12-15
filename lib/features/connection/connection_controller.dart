import 'dart:io';

import 'package:flutter/material.dart';
import 'package:design_system/design_system.dart';
import 'package:get/get.dart';

import '../../rinf/rust_ssh_service.dart';
import '../../services/connection_history_service.dart';
import '../../services/secure_storage_service.dart';
import '../../services/ssh_key_service.dart';
import '../../services/ssh_service.dart';

enum _BootstrapKeyChoice { generateNew, useExisting }

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
  final remoteShell = PosixShell.sh.obs;

  @override
  final isBusy = false.obs;
  @override
  final hasSavedPrivateKey = false.obs;
  @override
  final requiresSshBootstrap = false.obs;
  @override
  final status = ''.obs;
  @override
  final recentProfiles = <ConnectionProfile>[].obs;

  String? _sshPassword;

  SecureStorageService get _storage => Get.find<SecureStorageService>();
  ConnectionHistoryService get _history => Get.find<ConnectionHistoryService>();
  SshService get _ssh => Get.find<SshService>();
  SshKeyService get _keys => Get.find<SshKeyService>();

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
      remoteShell.value = last.shell;
    }
  }

  Future<void> _loadKeyFromKeychain() async {
    final pem = await _storage.read(
      key: SecureStorageService.sshPrivateKeyPemKey,
    );
    privateKeyPemController.text = pem ?? '';
    hasSavedPrivateKey.value = pem != null && pem.trim().isNotEmpty;
    if (!hasSavedPrivateKey.value) {
      requiresSshBootstrap.value = false;
    }
  }

  @override
  Future<void> reloadKeyFromKeychain() => _loadKeyFromKeychain();

  @override
  Future<void> savePrivateKeyToKeychain() async {
    final pem = privateKeyPemController.text.trim();
    if (pem.isEmpty) {
      status.value = 'Private key PEM is empty.';
      hasSavedPrivateKey.value = false;
      return;
    }
    await _storage.write(
      key: SecureStorageService.sshPrivateKeyPemKey,
      value: pem,
    );
    status.value = 'Saved private key PEM to Keychain.';
    hasSavedPrivateKey.value = true;
  }

  @override
  Future<void> savePrivateKeyPem(String pem) async {
    final trimmed = pem.trim();
    if (trimmed.isEmpty) {
      status.value = 'Private key PEM is empty.';
      hasSavedPrivateKey.value = false;
      return;
    }
    await _storage.write(
      key: SecureStorageService.sshPrivateKeyPemKey,
      value: trimmed,
    );
    privateKeyPemController.text = trimmed;
    hasSavedPrivateKey.value = true;
    requiresSshBootstrap.value = false;
  }

  @override
  Future<String> generateNewPrivateKeyPem() {
    return _keys.generateEd25519PrivateKeyPem();
  }

  @override
  Future<List<String>> listHostPrivateKeys({
    required String userAtHost,
    required int port,
    required String password,
  }) async {
    final trimmed = userAtHost.trim();
    if (!trimmed.contains('@')) return const [];
    final parts = trimmed.split('@');
    if (parts.length != 2) return const [];
    final username = parts[0];
    final host = parts[1];

    final script = [
      r'dir="$HOME/.ssh"',
      r'if [ ! -d "$dir" ]; then exit 0; fi',
      r'for f in "$dir"/id_*; do',
      r'  [ -f "$f" ] || continue',
      r'  case "$f" in',
      r'    *.pub) continue ;;',
      r'    *known_hosts*|*authorized_keys*|*config*) continue ;;',
      r'  esac',
      r'  echo "$f"',
      r'done',
    ].join('\n');

    final cmd = _wrapWithShell(remoteShell.value, script);
    final res = await _ssh.runCommandWithResult(
      host: host,
      port: port,
      username: username,
      password: password,
      command: cmd,
      timeout: const Duration(seconds: 15),
    );

    return res.stdout
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
  }

  @override
  Future<String> readHostPrivateKeyPem({
    required String userAtHost,
    required int port,
    required String password,
    required String remotePath,
  }) async {
    final trimmed = userAtHost.trim();
    if (!trimmed.contains('@')) {
      throw StateError('Invalid username@host');
    }
    final parts = trimmed.split('@');
    if (parts.length != 2) throw StateError('Invalid username@host');
    final username = parts[0];
    final host = parts[1];

    final cmd = _wrapWithShell(
      remoteShell.value,
      'cat ${_shQuote(remotePath)} 2>/dev/null || true',
    );
    final res = await _ssh.runCommandWithResult(
      host: host,
      port: port,
      username: username,
      password: password,
      command: cmd,
      timeout: const Duration(seconds: 15),
    );

    final pem = res.stdout.trim();
    if (pem.isEmpty) {
      throw StateError('Failed to read key: $remotePath');
    }
    return pem;
  }

  @override
  Future<String> authorizedKeysLineFromPrivateKey({
    required String privateKeyPem,
    String? privateKeyPassphrase,
  }) {
    return _keys.toAuthorizedKeysLine(
      privateKeyPem: privateKeyPem,
      privateKeyPassphrase: privateKeyPassphrase,
    );
  }

  @override
  Future<void> installPublicKeyWithPassword({
    required String userAtHost,
    required int port,
    required String password,
    required String privateKeyPem,
    String? privateKeyPassphrase,
  }) {
    return _ssh
        .installPublicKey(
          userAtHost: userAtHost,
          port: port,
          password: password,
          privateKeyPem: privateKeyPem,
          privateKeyPassphrase: privateKeyPassphrase,
        )
        .then((_) {
          requiresSshBootstrap.value = false;
        });
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

    return ConnectionProfile(
      userAtHost: userAtHost,
      port: port,
      shell: remoteShell.value,
    );
  }

  bool _looksLikeAuthFailure(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('permission denied') ||
        s.contains('authentication') ||
        s.contains('auth failed') ||
        s.contains('no authentication methods') ||
        s.contains('publickey') ||
        s.contains('password prompt cancelled') ||
        s.contains('prompt cancelled');
  }

  Future<_BootstrapKeyChoice?> _promptBootstrapStep3Choice() {
    return Get.dialog<_BootstrapKeyChoice>(
      AlertDialog(
        title: const Text('Fix SSH access'),
        content: const Text(
          'This server rejected your current key. Install a key on the server to continue.',
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: null),
            child: const Text('Cancel'),
          ),
          OutlinedButton(
            onPressed: () => Get.back(result: _BootstrapKeyChoice.useExisting),
            child: const Text('Use existing'),
          ),
          FilledButton(
            onPressed: () => Get.back(result: _BootstrapKeyChoice.generateNew),
            child: const Text('Generate new'),
          ),
        ],
      ),
    );
  }

  Future<String?> _promptPickHostKey(List<String> paths) async {
    if (paths.isEmpty) return null;
    return Get.bottomSheet<String>(
      SafeArea(
        child: ListView.separated(
          shrinkWrap: true,
          padding: const EdgeInsets.all(12),
          itemCount: paths.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final p = paths[i];
            final label = p.split('/').where((s) => s.isNotEmpty).last;
            return ListTile(
              leading: const Icon(Icons.key),
              title: Text(label),
              subtitle: Text(p),
              onTap: () => Get.back(result: p),
            );
          },
        ),
      ),
      isScrollControlled: true,
    );
  }

  Future<void> _bootstrapStep3ForHost({
    required String userAtHost,
    required int port,
  }) async {
    final password = await _promptForPassword();
    if (password == null || password.trim().isEmpty) return;
    _sshPassword = password;

    final choice = await _promptBootstrapStep3Choice();
    if (choice == null) return;

    if (choice == _BootstrapKeyChoice.generateNew) {
      status.value = 'Generating key...';
      final pem = await generateNewPrivateKeyPem();
      await savePrivateKeyPem(pem);
      status.value = 'Installing public key...';
      await installPublicKeyWithPassword(
        userAtHost: userAtHost,
        port: port,
        password: password,
        privateKeyPem: pem,
      );
      status.value = 'Installed key on server.';
      return;
    }

    status.value = 'Scanning ~/.ssh/id_* on host...';
    final keys = await listHostPrivateKeys(
      userAtHost: userAtHost,
      port: port,
      password: password,
    );
    final picked = await _promptPickHostKey(keys);
    if (picked == null) return;
    status.value = 'Copying selected key...';
    final pem = await readHostPrivateKeyPem(
      userAtHost: userAtHost,
      port: port,
      password: password,
      remotePath: picked,
    );
    await savePrivateKeyPem(pem);
    status.value = 'Installing public key...';
    await installPublicKeyWithPassword(
      userAtHost: userAtHost,
      port: port,
      password: password,
      privateKeyPem: pem,
    );
    status.value = 'Installed key on server.';
  }

  static String _shQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

  static String _wrapWithShell(PosixShell shell, String body) {
    switch (shell) {
      case PosixShell.sh:
        return 'sh -c ${_shQuote(body)}';
      case PosixShell.bash:
        return 'bash --noprofile --norc -c ${_shQuote(body)}';
      case PosixShell.zsh:
        return 'zsh -f -c ${_shQuote(body)}';
      case PosixShell.fizsh:
        return 'fizsh -f -c ${_shQuote(body)}';
    }
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
    final profile = _parseProfile();
    if (profile == null) {
      status.value = 'Enter username@host.';
      return;
    }
    final port = int.tryParse(portController.text.trim()) ?? 22;

    isBusy.value = true;
    status.value = 'Connecting...';
    try {
      final host = profile.host;
      final username = profile.username;

      final privateKeyPassphrase = privateKeyPassphraseController.text.trim();

      // Enforce key-based auth for normal connections. Password is only used
      // for bootstrapping key installation.
      var pem =
          (await _storage.read(
            key: SecureStorageService.sshPrivateKeyPemKey,
          ))?.trim() ??
          '';
      if (pem.isEmpty) {
        status.value = 'SSH key required. Set up a key first.';
        hasSavedPrivateKey.value = false;
        return;
      }

      final res = await RustSshService.runCommandWithResult(
        host: host,
        port: port,
        username: username,
        command: _wrapWithShell(profile.shell, 'whoami'),
        privateKeyPassphrase: privateKeyPassphrase.isEmpty
            ? null
            : privateKeyPassphrase,
        connectTimeout: const Duration(seconds: 10),
        commandTimeout: const Duration(seconds: 10),
        privateKeyPemOverride: pem,
        passwordProvider: null,
      );

      status.value = 'SSH OK: ${res.stdout.trim()}';

      await _history.saveLast(profile);
      final existing = recentProfiles
          .where((p) => p.userAtHost == profile.userAtHost && p.port == port)
          .toList();
      final next = <ConnectionProfile>[profile, ...recentProfiles]
          .where(
            (p) =>
                p.userAtHost.isNotEmpty &&
                !existing.any(
                  (e) => e.userAtHost == p.userAtHost && e.port == p.port,
                ),
          )
          .take(10)
          .toList();
      recentProfiles.assignAll(next);
      await _history.saveProfiles(next);

      Get.toNamed(DesignRoutes.projects, arguments: TargetArgs.remote(profile));
    } catch (e) {
      if (_looksLikeAuthFailure(e)) {
        requiresSshBootstrap.value = true;
        status.value = 'SSH key not accepted. Complete SSH setup to continue.';
        return;
      }
      status.value = 'SSH failed: $e';
    } finally {
      isBusy.value = false;
    }
  }
}
