class ConnectionProfile {
  final String userAtHost;
  final int port;

  ConnectionProfile({
    required this.userAtHost,
    required this.port,
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
      };

  factory ConnectionProfile.fromJson(Map<String, Object?> json) {
    return ConnectionProfile(
      userAtHost: (json['userAtHost'] as String?) ?? '',
      port: (json['port'] as num?)?.toInt() ?? 22,
    );
  }
}

