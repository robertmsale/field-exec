class Conversation {
  final String threadId;
  final String preview;
  final int createdAtMs;
  final int lastUsedAtMs;

  const Conversation({
    required this.threadId,
    required this.preview,
    required this.createdAtMs,
    required this.lastUsedAtMs,
  });

  Conversation touch(int nowMs) => Conversation(
        threadId: threadId,
        preview: preview,
        createdAtMs: createdAtMs,
        lastUsedAtMs: nowMs,
      );

  Map<String, Object?> toJson() => {
        'threadId': threadId,
        'preview': preview,
        'createdAtMs': createdAtMs,
        'lastUsedAtMs': lastUsedAtMs,
      };

  factory Conversation.fromJson(Map<String, Object?> json) {
    return Conversation(
      threadId: (json['threadId'] as String?) ?? '',
      preview: (json['preview'] as String?) ?? '',
      createdAtMs: (json['createdAtMs'] as num?)?.toInt() ?? 0,
      lastUsedAtMs: (json['lastUsedAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}

