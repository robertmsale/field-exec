import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:design_system/design_system.dart';
import 'dart:io';

import 'bindings/initial_binding.dart';
import 'routes/app_pages.dart';
import '../services/theme_mode_service.dart';
import '../services/ssh_service.dart';

class FieldExecApp extends StatelessWidget {
  final ProjectArgs? startupProjectArgs;

  const FieldExecApp({super.key, this.startupProjectArgs});

  @override
  Widget build(BuildContext context) {
    final service = Get.isRegistered<ThemeModeService>()
        ? Get.find<ThemeModeService>()
        : null;

    if (service == null) {
      return GetMaterialApp(
        title: 'FieldExec',
        debugShowCheckedModeBanner: false,
        theme: DesignSystemThemes.light(),
        darkTheme: DesignSystemThemes.dark(),
        themeMode: ThemeMode.system,
        initialBinding: InitialBinding(startupProjectArgs: startupProjectArgs),
        initialRoute: startupProjectArgs == null
            ? DesignRoutes.connect
            : DesignRoutes.project,
        getPages: AppPages.pages,
        routingCallback: _routingCallback,
      );
    }

    return Obx(
      () => GetMaterialApp(
        title: 'FieldExec',
        debugShowCheckedModeBanner: false,
        theme: DesignSystemThemes.light(),
        darkTheme: DesignSystemThemes.dark(),
        themeMode: service.modeRx.value,
        initialBinding: InitialBinding(startupProjectArgs: startupProjectArgs),
        initialRoute: startupProjectArgs == null
            ? DesignRoutes.connect
            : DesignRoutes.project,
        getPages: AppPages.pages,
        routingCallback: _routingCallback,
      ),
    );
  }

  static void _routingCallback(Routing? routing) {
    // Mobile-only: when navigating back to the login page, tear down the pooled
    // SSH connection so the user can reconnect without restarting the app.
    if (!Platform.isIOS && !Platform.isAndroid) return;
    if (routing == null) return;
    if (routing.current != DesignRoutes.connect) return;

    try {
      if (!Get.isRegistered<SshService>()) return;
      Get.find<SshService>().resetAllConnections(reason: 'navigate:connect');
    } catch (_) {
      // Best-effort.
    }
  }
}
