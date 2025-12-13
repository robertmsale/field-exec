import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'keys_page.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          ListTile(
            title: const Text('SSH Keys'),
            subtitle: const Text('Manage the global key used for connections'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Get.to(() => const KeysPage()),
          ),
        ],
      ),
    );
  }
}

