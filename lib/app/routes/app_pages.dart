import 'package:get/get.dart';

import '../../features/connection/connection_page.dart';
import '../../features/projects/projects_page.dart';
import '../../features/settings/settings_page.dart';
import '../../features/projects/project_sessions_page.dart';
import 'app_routes.dart';

abstract final class AppPages {
  static final pages = <GetPage<dynamic>>[
    GetPage(name: AppRoutes.connect, page: ConnectionPage.new),
    GetPage(name: AppRoutes.projects, page: ProjectsPage.new),
    GetPage(name: AppRoutes.project, page: ProjectSessionsPage.new),
    GetPage(name: AppRoutes.settings, page: SettingsPage.new),
  ];
}
