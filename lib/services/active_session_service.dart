import 'package:get/get.dart';

class ActiveSessionRef {
  final String targetKey;
  final String projectPath;
  final String tabId;

  const ActiveSessionRef({
    required this.targetKey,
    required this.projectPath,
    required this.tabId,
  });
}

class ActiveSessionService {
  final activeRx = Rxn<ActiveSessionRef>();

  ActiveSessionRef? get active => activeRx.value;

  void setActive(ActiveSessionRef? ref) {
    activeRx.value = ref;
  }
}
