import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/connection_controller_base.dart';
import '../models/connection_profile.dart';
import '../routes/design_routes.dart';

class ConnectionPage extends GetView<ConnectionControllerBase> {
  const ConnectionPage({super.key});

  static const _shellOptions = <PosixShell>[
    PosixShell.sh,
    PosixShell.bash,
    PosixShell.zsh,
    PosixShell.fizsh,
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('FieldExec'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            onPressed: () async {
              await Get.toNamed(DesignRoutes.settings);
              await controller.reloadKeyFromKeychain();
            },
            icon: const Icon(Icons.settings),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (Platform.isMacOS)
              Obx(
                () => SwitchListTile(
                  title: const Text('Run locally on this Mac'),
                  subtitle: const Text('Disable to connect over SSH instead'),
                  value: controller.useLocalRunner.value,
                  onChanged: (v) => controller.useLocalRunner.value = v,
                ),
              ),
            const SizedBox(height: 8),
            Obx(() {
              if (controller.useLocalRunner.value && Platform.isMacOS) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'Local mode runs Codex directly on this Mac.\n'
                    'You will pick a local project path next.',
                  ),
                );
              }
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
                  TextField(
                    controller: controller.privateKeyPassphraseController,
                    obscureText: true,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Private key passphrase (optional)',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller.privateKeyPemController,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      labelText: 'Private key PEM (optional)',
                      helperText:
                          'Stored in Apple Keychain via flutter_secure_storage.',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () =>
                              controller.savePrivateKeyToKeychain(),
                          child: const Text('Save Key to Keychain'),
                        ),
                      ),
                    ],
                  ),
                ],
              );
            }),
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
                        if (controller.useLocalRunner.value) {
                          await controller.runLocalCodex();
                          return;
                        }
                        await controller.testSshConnection();
                      },
                child: Text(
                  controller.isBusy.value
                      ? 'Working...'
                      : (controller.useLocalRunner.value
                            ? 'Connect Locally'
                            : 'Connect'),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Obx(
              () => Text(
                controller.status.value,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
