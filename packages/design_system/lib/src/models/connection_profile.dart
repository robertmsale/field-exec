enum PosixShell { sh, bash, zsh, fizsh }

extension PosixShellX on PosixShell {
  String get label {
    switch (this) {
      case PosixShell.sh:
        return 'sh (default)';
      case PosixShell.bash:
        return 'bash';
      case PosixShell.zsh:
        return 'zsh';
      case PosixShell.fizsh:
        return 'fizsh';
    }
  }

  static PosixShell fromJson(Object? raw) {
    final v = (raw as String?)?.trim().toLowerCase();
    switch (v) {
      case 'bash':
        return PosixShell.bash;
      case 'zsh':
        return PosixShell.zsh;
      case 'fizsh':
        return PosixShell.fizsh;
      case 'sh':
      default:
        return PosixShell.sh;
    }
  }
}

class ConnectionProfile {
  final String userAtHost;
  final int port;
  final PosixShell shell;

  ConnectionProfile({
    required this.userAtHost,
    required this.port,
    this.shell = PosixShell.sh,
  });

  String get username {
    final at = userAtHost.indexOf('@');
    return at == -1 ? '' : userAtHost.substring(0, at);
  }

  String get host {
    final at = userAtHost.indexOf('@');
    return at == -1 ? '' : userAtHost.substring(at + 1);
  }

  Map<String, Object?> toJson() => {
    'userAtHost': userAtHost,
    'port': port,
    'shell': shell.name,
  };

  factory ConnectionProfile.fromJson(Map<String, Object?> json) {
    return ConnectionProfile(
      userAtHost: (json['userAtHost'] as String?) ?? '',
      port: (json['port'] as num?)?.toInt() ?? 22,
      shell: PosixShellX.fromJson(json['shell']),
    );
  }
}
