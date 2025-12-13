import '../models/connection_profile.dart';

class TargetArgs {
  final bool local;
  final ConnectionProfile? profile;

  const TargetArgs.local()
      : local = true,
        profile = null;

  const TargetArgs.remote(this.profile) : local = false;

  String get targetKey {
    if (local) return 'local';
    final p = profile;
    return p == null ? 'remote' : '${p.userAtHost}:${p.port}';
  }
}
