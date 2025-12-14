import 'package:get/get.dart';

import '../args/project_args.dart';
import '../models/conversation.dart';
import '../models/project_tab.dart';
import 'session_controller_base.dart';

class RunCommandResult {
  final int exitCode;
  final String stdout;
  final String stderr;

  const RunCommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });
}

abstract class ProjectSessionsControllerBase extends GetxController {
  ProjectArgs get args;

  RxList<ProjectTab> get tabs;
  RxInt get activeIndex;
  RxBool get isReady;

  SessionControllerBase sessionForTab(ProjectTab tab);

  Future<void> addTab();
  Future<void> closeTab(ProjectTab tab);
  Future<void> renameTab(ProjectTab tab, String title);

  Future<List<Conversation>> loadConversations();
  Future<void> openConversation(Conversation conversation);

  String runCommandHint();
  Future<RunCommandResult> runShellCommand(String command);
}
