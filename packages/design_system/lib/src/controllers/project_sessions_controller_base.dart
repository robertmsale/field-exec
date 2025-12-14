import 'package:get/get.dart';

import '../args/project_args.dart';
import '../models/conversation.dart';
import '../models/project.dart';
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

  /// Projects that can be switched to from the current project page (typically
  /// other projects in the same group).
  Future<List<Project>> loadSwitchableProjects();

  /// Navigates to another project (typically from [loadSwitchableProjects]).
  Future<void> switchToProject(Project project);

  /// Loads the project-scoped developer instructions from `.field_exec/`.
  Future<String> loadDeveloperInstructions();

  /// Saves the project-scoped developer instructions to `.field_exec/`.
  Future<void> saveDeveloperInstructions(String instructions);

  String runCommandHint();
  Future<RunCommandResult> runShellCommand(String command);
}
