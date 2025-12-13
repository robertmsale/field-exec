import '../models/project.dart';
import 'target_args.dart';

class ProjectArgs {
  final TargetArgs target;
  final Project project;

  const ProjectArgs({required this.target, required this.project});
}

