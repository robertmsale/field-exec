class Project {
  final String id;
  final String path;
  final String name;
  final String? group;

  const Project({
    required this.id,
    required this.path,
    required this.name,
    this.group,
  });

  static const _unset = Object();

  Project copyWith({
    String? id,
    String? path,
    String? name,
    Object? group = _unset,
  }) {
    return Project(
      id: id ?? this.id,
      path: path ?? this.path,
      name: name ?? this.name,
      group: identical(group, _unset) ? this.group : group as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'path': path,
    'name': name,
    'group': group,
  };

  factory Project.fromJson(Map<String, Object?> json) {
    final rawGroup = (json['group'] as String?)?.trim();
    return Project(
      id: (json['id'] as String?) ?? '',
      path: (json['path'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      group: rawGroup == null || rawGroup.isEmpty ? null : rawGroup,
    );
  }
}
