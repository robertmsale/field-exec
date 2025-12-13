class Conversation {
  final String threadId;
  final String preview;
  final String tabId;
  final int createdAtMs;
  final int lastUsedAtMs;

  const Conversation({
    required this.threadId,
    required this.preview,
    required this.tabId,
    required this.createdAtMs,
    required this.lastUsedAtMs,
  });

  Conversation touch(int nowMs) => Conversation(
        threadId: threadId,
        preview: preview,
        tabId: tabId,
        createdAtMs: createdAtMs,
        lastUsedAtMs: nowMs,
      );

  Map<String, Object?> toJson() => {
        'threadId': threadId,
        'preview': preview,
        'tabId': tabId,
        'createdAtMs': createdAtMs,
        'lastUsedAtMs': lastUsedAtMs,
      };

  factory Conversation.fromJson(Map<String, Object?> json) {
    return Conversation(
      threadId: (json['threadId'] as String?) ?? '',
      preview: (json['preview'] as String?) ?? '',
      tabId: (json['tabId'] as String?) ?? '',
      createdAtMs: (json['createdAtMs'] as num?)?.toInt() ?? 0,
      lastUsedAtMs: (json['lastUsedAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}
