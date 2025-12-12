import 'package:get/get.dart';

import '../../features/connection/connection_controller.dart';
import '../../services/connection_history_service.dart';
import '../../services/codex_session_store.dart';
import '../../services/conversation_store.dart';
import '../../services/local_shell_service.dart';
import '../../services/secure_storage_service.dart';
import '../../services/ssh_key_service.dart';
import '../../services/ssh_service.dart';
import '../../services/project_store.dart';
import '../../services/project_tabs_store.dart';

class InitialBinding extends Bindings {
  @override
  void dependencies() {
    Get.put<SecureStorageService>(SecureStorageService(), permanent: true);
    Get.put<SshService>(SshService(), permanent: true);
    Get.put<SshKeyService>(SshKeyService(), permanent: true);
    Get.put<ConnectionHistoryService>(ConnectionHistoryService(),
        permanent: true);
    Get.put<CodexSessionStore>(CodexSessionStore(), permanent: true);
    Get.put<ProjectStore>(ProjectStore(), permanent: true);
    Get.put<ProjectTabsStore>(ProjectTabsStore(), permanent: true);
    Get.put<ConversationStore>(ConversationStore(), permanent: true);
    Get.put<LocalShellService>(LocalShellService(), permanent: true);

    Get.lazyPut<ConnectionController>(() => ConnectionController());
  }
}
