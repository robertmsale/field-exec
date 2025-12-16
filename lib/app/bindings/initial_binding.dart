import 'package:get/get.dart';
import 'package:design_system/design_system.dart';

import '../../features/connection/connection_controller.dart';
import '../../features/settings/settings_controller.dart';
import '../../features/settings/keys/keys_controller.dart';
import '../../features/settings/keys/install_key_controller.dart';
import '../../services/connection_history_service.dart';
import '../../services/field_exec_session_store.dart';
import '../../services/conversation_store.dart';
import '../../services/app_lifecycle_service.dart';
import '../../services/local_shell_service.dart';
import '../../services/active_session_service.dart';
import '../../services/secure_storage_service.dart';
import '../../services/ssh_key_service.dart';
import '../../services/ssh_service.dart';
import '../../services/project_store.dart';
import '../../services/project_tabs_store.dart';
import '../../services/notification_service.dart';
import '../../services/remote_jobs_store.dart';
import '../../services/local_ssh_keys_service.dart';
import '../../services/session_scrollback_service.dart';

class InitialBinding extends Bindings {
  @override
  void dependencies() {
    Get.put<SecureStorageService>(SecureStorageService(), permanent: true);
    Get.put<SshService>(SshService(), permanent: true);
    Get.put<SshKeyService>(SshKeyService(), permanent: true);
    Get.put<ConnectionHistoryService>(
      ConnectionHistoryService(),
      permanent: true,
    );
    Get.put<FieldExecSessionStore>(FieldExecSessionStore(), permanent: true);
    Get.put<ProjectStore>(ProjectStore(), permanent: true);
    Get.put<ProjectTabsStore>(ProjectTabsStore(), permanent: true);
    Get.put<ConversationStore>(ConversationStore(), permanent: true);
    Get.put<LocalShellService>(LocalShellService(), permanent: true);
    Get.put<NotificationService>(NotificationService(), permanent: true);
    Get.put<RemoteJobsStore>(RemoteJobsStore(), permanent: true);
    Get.put<ActiveSessionService>(ActiveSessionService(), permanent: true);
    Get.put<LocalSshKeysService>(LocalSshKeysService(), permanent: true);
    if (!Get.isRegistered<SessionScrollbackService>()) {
      Get.put<SessionScrollbackService>(
        SessionScrollbackService(),
        permanent: true,
      );
    }
    final lifecycle = Get.put<AppLifecycleService>(
      AppLifecycleService(),
      permanent: true,
    );
    lifecycle.start();

    Get.lazyPut<ConnectionControllerBase>(() => ConnectionController());
    Get.lazyPut<SettingsControllerBase>(() => SettingsController());
    Get.lazyPut<KeysControllerBase>(() => KeysController());
    Get.lazyPut<InstallKeyControllerBase>(() => InstallKeyController());
  }
}
