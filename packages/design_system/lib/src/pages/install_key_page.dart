import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/install_key_controller_base.dart';

class InstallKeyPage extends GetView<InstallKeyControllerBase> {
  const InstallKeyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Install Key')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: controller.targetController,
              decoration: const InputDecoration(
                labelText: 'username@host',
                hintText: 'robert@mac.local',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller.portController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Port'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller.passwordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
            ),
            const SizedBox(height: 16),
            Obx(
              () => FilledButton(
                onPressed: controller.busy.value
                    ? null
                    : () async {
                        controller.busy.value = true;
                        try {
                          await controller.install();
                        } finally {
                          controller.busy.value = false;
                        }
                      },
                child: Text(controller.busy.value ? 'Working...' : 'Install'),
              ),
            ),
            const SizedBox(height: 12),
            Obx(() => Text(controller.status.value)),
          ],
        ),
      ),
    );
  }
}

