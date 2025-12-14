import 'package:get/get.dart';

import '../args/target_args.dart';
import '../models/project.dart';

abstract class ProjectsControllerBase extends GetxController {
  TargetArgs get target;

  RxList<Project> get projects;
  RxBool get isBusy;
  RxString get status;

  Future<Project?> promptAddProject();
  Future<void> addProject(Project project);
  Future<void> updateProject(Project project);
  Future<void> deleteProject(Project project);
}
