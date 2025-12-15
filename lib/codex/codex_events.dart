class CodexStructuredAction {
  final String id;
  final String label;
  final String value;

  const CodexStructuredAction({
    required this.id,
    required this.label,
    required this.value,
  });

  factory CodexStructuredAction.fromJson(Map<String, Object?> json) {
    return CodexStructuredAction(
      id: (json['id'] as String?) ?? '',
      label: (json['label'] as String?) ?? '',
      value: (json['value'] as String?) ?? '',
    );
  }
}

class CodexStructuredImageRef {
  final String path;
  final String caption;

  const CodexStructuredImageRef({required this.path, required this.caption});

  static String _coerceString(Object? v) {
    if (v == null) return '';
    return v.toString();
  }

  factory CodexStructuredImageRef.fromJson(Map<String, Object?> json) {
    // Be tolerant here: even with a strict schema, models sometimes drift on
    // key names when returning many images. We still want to render what we can.
    final path = _coerceString(
      json['path'] ??
          json['file_path'] ??
          json['filepath'] ??
          json['image_path'] ??
          json['file'],
    );
    final caption = _coerceString(
      json['caption'] ?? json['title'] ?? json['label'] ?? json['alt'],
    );
    return CodexStructuredImageRef(
      path: path,
      caption: caption,
    );
  }
}

class CodexStructuredResponse {
  final String message;
  final String commitMessage;
  final List<CodexStructuredImageRef> images;
  final List<CodexStructuredAction> actions;

  const CodexStructuredResponse({
    required this.message,
    required this.commitMessage,
    required this.images,
    required this.actions,
  });

  static List<CodexStructuredImageRef> _parseImages(Object? raw) {
    final Iterable imagesRaw;
    if (raw is List) {
      imagesRaw = raw;
    } else if (raw is Map) {
      imagesRaw = raw.values;
    } else {
      imagesRaw = const [];
    }
    final out = <CodexStructuredImageRef>[];
    for (final entry in imagesRaw) {
      if (entry is Map) {
        // Some toolchains wrap the payload as {"image": {...}} or {"ref": {...}}.
        final inner = (entry['image'] is Map)
            ? entry['image']
            : ((entry['ref'] is Map) ? entry['ref'] : entry);
        try {
          out.add(
            CodexStructuredImageRef.fromJson(inner.cast<String, Object?>()),
          );
        } catch (_) {}
      } else if (entry is List) {
        final p = (entry.isNotEmpty ? entry[0] : null)?.toString().trim();
        final c = (entry.length >= 2 ? entry[1] : null)?.toString().trim();
        if (p != null && p.isNotEmpty) {
          out.add(CodexStructuredImageRef(path: p, caption: c ?? ''));
        }
      } else if (entry is String) {
        final p = entry.trim();
        if (p.isNotEmpty) {
          out.add(CodexStructuredImageRef(path: p, caption: ''));
        }
      }
    }
    return out.where((i) => i.path.trim().isNotEmpty).toList(growable: false);
  }

  factory CodexStructuredResponse.fromJson(Map<String, Object?> json) {
    final images = _parseImages(json['images']);
    final actionsRaw = (json['actions'] as List?) ?? const [];
    final actions = actionsRaw
        .whereType<Map>()
        .map((m) => CodexStructuredAction.fromJson(m.cast<String, Object?>()))
        .where((a) => a.id.isNotEmpty && a.label.isNotEmpty && a.value.isNotEmpty)
        .toList(growable: false);
    return CodexStructuredResponse(
      message: (json['message'] as String?) ?? '',
      commitMessage: (json['commit_message'] as String?) ?? '',
      images: images,
      actions: actions,
    );
  }
}
