class ProjectTab {
  final String id;
  final String title;

  const ProjectTab({required this.id, required this.title});

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
      };

  factory ProjectTab.fromJson(Map<String, Object?> json) {
    return ProjectTab(
      id: (json['id'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
    );
  }
}

