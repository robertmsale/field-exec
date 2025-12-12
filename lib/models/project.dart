class Project {
  final String id;
  final String path;
  final String name;

  const Project({
    required this.id,
    required this.path,
    required this.name,
  });

  Project copyWith({String? id, String? path, String? name}) {
    return Project(
      id: id ?? this.id,
      path: path ?? this.path,
      name: name ?? this.name,
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'path': path,
        'name': name,
      };

  factory Project.fromJson(Map<String, Object?> json) {
    return Project(
      id: (json['id'] as String?) ?? '',
      path: (json['path'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
    );
  }
}

