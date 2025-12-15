import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/connection_controller_base.dart';
import '../models/connection_profile.dart';

enum _BootstrapStep {
  method,
  enterPrivateKey,
  connectionDetails,
  keyChoice,
  pickHostKey,
}

enum _ConnectMode { remote, local }

class ConnectionPage extends StatefulWidget {
  const ConnectionPage({super.key});

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage> {
  late final ConnectionControllerBase controller;

  static const _shellOptions = <PosixShell>[
    PosixShell.sh,
    PosixShell.bash,
    PosixShell.zsh,
    PosixShell.fizsh,
  ];

  final _bootstrapPem = TextEditingController();
  final _bootstrapPassword = TextEditingController();
  var _step = _BootstrapStep.method;
  var _working = false;
  String? _error;
  List<String> _hostKeys = const [];

  @override
  void initState() {
    super.initState();
    controller = Get.find<ConnectionControllerBase>();
    // Ensure state reflects the latest keychain contents (e.g. after deleting
    // the key in Settings).
    controller.reloadKeyFromKeychain();
  }

  @override
  void dispose() {
    _bootstrapPem.dispose();
    _bootstrapPassword.dispose();
    super.dispose();
  }

  bool get _supportsLocalRunner => Platform.isMacOS || Platform.isLinux;

  bool get _isRemote =>
      !_supportsLocalRunner || !controller.useLocalRunner.value;

  Widget _modePicker() {
    if (!_supportsLocalRunner) return const SizedBox.shrink();
    return Obx(() {
      final selected = controller.useLocalRunner.value
          ? {_ConnectMode.local}
          : {_ConnectMode.remote};
      return SegmentedButton<_ConnectMode>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(
            value: _ConnectMode.remote,
            label: Text('Remote (SSH)'),
          ),
          ButtonSegment(value: _ConnectMode.local, label: Text('Local')),
        ],
        selected: selected,
        onSelectionChanged: controller.isBusy.value
            ? null
            : (set) {
                if (set.isEmpty) return;
                final next = set.first;
                controller.useLocalRunner.value = next == _ConnectMode.local;
                controller.status.value = '';
                setState(() {
                  _error = null;
                  _step = _BootstrapStep.method;
                });
              },
      );
    });
  }

  Future<void> _bootstrapSavePrivateKey() async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await controller.savePrivateKeyPem(_bootstrapPem.text);
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _bootstrapNextFromConnectionDetails() {
    final target = controller.userAtHostController.text.trim();
    final pw = _bootstrapPassword.text;
    if (!target.contains('@')) {
      setState(() => _error = 'Enter username@host.');
      return;
    }
    if (pw.trim().isEmpty) {
      setState(() => _error = 'Password required for setup.');
      return;
    }

    setState(() {
      _error = null;
      _step = _BootstrapStep.keyChoice;
    });
  }

  Future<void> _bootstrapGenerateNewAndInstall() async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final target = controller.userAtHostController.text.trim();
      final port = int.tryParse(controller.portController.text.trim()) ?? 22;
      final password = _bootstrapPassword.text;
      final pem = await controller.generateNewPrivateKeyPem();
      await controller.savePrivateKeyPem(pem);
      await controller.installPublicKeyWithPassword(
        userAtHost: target,
        port: port,
        password: password,
        privateKeyPem: pem,
      );
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _bootstrapLoadHostKeys() async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = null;
      _hostKeys = const [];
    });
    try {
      final target = controller.userAtHostController.text.trim();
      final port = int.tryParse(controller.portController.text.trim()) ?? 22;
      final password = _bootstrapPassword.text;
      final keys = await controller.listHostPrivateKeys(
        userAtHost: target,
        port: port,
        password: password,
      );
      if (keys.isEmpty) {
        _error = 'No ~/.ssh/id_* keys found on the host.';
      } else {
        _hostKeys = keys;
        _step = _BootstrapStep.pickHostKey;
      }
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _bootstrapUseHostKey(String remotePath) async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final target = controller.userAtHostController.text.trim();
      final port = int.tryParse(controller.portController.text.trim()) ?? 22;
      final password = _bootstrapPassword.text;
      final pem = await controller.readHostPrivateKeyPem(
        userAtHost: target,
        port: port,
        password: password,
        remotePath: remotePath,
      );
      await controller.savePrivateKeyPem(pem);
      await controller.installPublicKeyWithPassword(
        userAtHost: target,
        port: port,
        password: password,
        privateKeyPem: pem,
      );
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Widget _bootstrapScaffold({required Widget child}) {
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'SSH Setup',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              if (_supportsLocalRunner) ...[
                const SizedBox(height: 12),
                _modePicker(),
              ],
              const SizedBox(height: 8),
              const Text(
                'Private key authentication is required. Complete setup to continue.',
              ),
              const SizedBox(height: 16),
              if (_error != null) ...[
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                const SizedBox(height: 12),
              ],
              child,
            ],
          ),
        ),
      ),
    );
  }

  Widget _bootstrapStep1() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FilledButton(
          onPressed: _working
              ? null
              : () => setState(() => _step = _BootstrapStep.enterPrivateKey),
          child: const Text('Enter private key'),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: _working
              ? null
              : () => setState(() => _step = _BootstrapStep.connectionDetails),
          child: const Text('Set up with password'),
        ),
      ],
    );
  }

  Widget _bootstrapStepEnterKey() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _bootstrapPem,
          maxLines: 12,
          decoration: const InputDecoration(
            labelText: 'Private key PEM',
            hintText: 'Paste an OpenSSH private key PEM here',
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            OutlinedButton(
              onPressed: _working
                  ? null
                  : () => setState(() => _step = _BootstrapStep.method),
              child: const Text('Back'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: _working ? null : _bootstrapSavePrivateKey,
                child: Text(_working ? 'Saving...' : 'Save'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _bootstrapStepConnectionDetails() {
    return Column(
      children: [
        TextField(
          controller: controller.userAtHostController,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'username@host',
            hintText: 'robert@mac.local',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: controller.portController,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(labelText: 'Port'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _bootstrapPassword,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Password'),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            OutlinedButton(
              onPressed: _working
                  ? null
                  : () => setState(() => _step = _BootstrapStep.method),
              child: const Text('Back'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: _working
                    ? null
                    : _bootstrapNextFromConnectionDetails,
                child: const Text('Continue'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _bootstrapStepKeyChoice() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FilledButton(
          onPressed: _working ? null : _bootstrapGenerateNewAndInstall,
          child: Text(_working ? 'Working...' : 'Generate new'),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: _working ? null : _bootstrapLoadHostKeys,
          child: const Text('Use existing'),
        ),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: _working
              ? null
              : () => setState(() => _step = _BootstrapStep.connectionDetails),
          child: const Text('Back'),
        ),
      ],
    );
  }

  Widget _bootstrapStepPickHostKey() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Select a key from ~/.ssh on the host:',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        for (final p in _hostKeys)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.key),
            title: Text(p.split('/').where((s) => s.isNotEmpty).last),
            subtitle: Text(p),
            onTap: _working ? null : () => _bootstrapUseHostKey(p),
          ),
        const Divider(height: 1),
        OutlinedButton(
          onPressed: _working
              ? null
              : () => setState(() => _step = _BootstrapStep.keyChoice),
          child: const Text('Back'),
        ),
      ],
    );
  }

  Widget _remoteConnect() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('FieldExec', style: Theme.of(context).textTheme.headlineSmall),
        if (_supportsLocalRunner) ...[
          const SizedBox(height: 12),
          _modePicker(),
        ],
        const SizedBox(height: 16),
        TextField(
          controller: controller.userAtHostController,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'username@host',
            hintText: 'robert@mac.local',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: controller.portController,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(labelText: 'Port'),
        ),
        const SizedBox(height: 12),
        Obx(
          () => DropdownButtonFormField<PosixShell>(
            value: controller.remoteShell.value,
            items: [
              for (final s in _shellOptions)
                DropdownMenuItem(value: s, child: Text(s.label)),
            ],
            onChanged: (v) {
              if (v == null) return;
              controller.remoteShell.value = v;
            },
            decoration: const InputDecoration(
              labelText: 'Remote shell',
              helperText:
                  'Used to run non-interactive commands (no profiles/rc files).',
            ),
          ),
        ),
        const SizedBox(height: 12),
        Obx(() {
          final recents = controller.recentProfiles;
          if (recents.isEmpty) return const SizedBox.shrink();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Recent', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 6),
              ...recents.map(
                (p) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(p.userAtHost),
                  subtitle: Text('Port ${p.port} • ${p.shell.name}'),
                  onTap: () {
                    controller.userAtHostController.text = p.userAtHost;
                    controller.portController.text = p.port.toString();
                    controller.remoteShell.value = p.shell;
                  },
                ),
              ),
            ],
          );
        }),
        const SizedBox(height: 16),
        Obx(
          () => FilledButton(
            onPressed: controller.isBusy.value
                ? null
                : () async {
                    await controller.testSshConnection();
                  },
            child: Text(controller.isBusy.value ? 'Working...' : 'Connect'),
          ),
        ),
        const SizedBox(height: 12),
        Obx(() => Text(controller.status.value)),
      ],
    );
  }

  Widget _localConnect() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('FieldExec', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12),
        if (_supportsLocalRunner) ...[
          _modePicker(),
          const SizedBox(height: 12),
        ],
        const Text(
          'Local mode runs Codex directly on this computer (macOS/Linux).\n'
          'You will pick a local project path next.',
        ),
        const SizedBox(height: 16),
        Obx(
          () => FilledButton(
            onPressed: controller.isBusy.value
                ? null
                : controller.runLocalCodex,
            child: Text(controller.isBusy.value ? 'Working...' : 'Continue'),
          ),
        ),
        const SizedBox(height: 12),
        Obx(() => Text(controller.status.value)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final needsBootstrap =
          _isRemote &&
          (!controller.hasSavedPrivateKey.value ||
              controller.requiresSshBootstrap.value);
      if (needsBootstrap) {
        if (controller.requiresSshBootstrap.value &&
            _step == _BootstrapStep.method) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() {
              _error ??=
                  'This server rejected your key. Install/authorize a key to continue.';
              _step = _BootstrapStep.connectionDetails;
            });
          });
        }
        final child = switch (_step) {
          _BootstrapStep.method => _bootstrapStep1(),
          _BootstrapStep.enterPrivateKey => _bootstrapStepEnterKey(),
          _BootstrapStep.connectionDetails => _bootstrapStepConnectionDetails(),
          _BootstrapStep.keyChoice => _bootstrapStepKeyChoice(),
          _BootstrapStep.pickHostKey => _bootstrapStepPickHostKey(),
        };
        return Scaffold(body: _bootstrapScaffold(child: child));
      }

      return Scaffold(
        body: SafeArea(
          child: Obx(() {
            // Always read the observable inside Obx; if we short-circuit on a
            // non-reactive flag, GetX will report an improper Obx usage.
            final useLocal = controller.useLocalRunner.value;
            if (_supportsLocalRunner && useLocal) {
              return _localConnect();
            }
            return _remoteConnect();
          }),
        ),
      );
    });
  }
}
