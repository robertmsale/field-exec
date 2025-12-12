import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'bindings/initial_binding.dart';
import 'routes/app_pages.dart';
import 'routes/app_routes.dart';

class CodexRemoteApp extends StatelessWidget {
  const CodexRemoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'Codex Remote',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue)),
      initialBinding: InitialBinding(),
      initialRoute: AppRoutes.connect,
      getPages: AppPages.pages,
    );
  }
}

