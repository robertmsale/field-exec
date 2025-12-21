import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

class FieldExecPasteService {
  FieldExecPasteService._();

  static final FieldExecPasteService instance = FieldExecPasteService._();

  static const MethodChannel _channel = MethodChannel('field_exec/paste');

  bool _initialized = false;
  TextEditingController? _activeController;
  TextEditingController? _lastKnownController;

  final List<String> _pendingParts = <String>[];
  bool _flushScheduled = false;
  int _suppressInsertTextUntilMs = 0;
  bool _pendingHasInsertText = false;

  void ensureInitialized() {
    if (_initialized) return;
    _initialized = true;

    if (!Platform.isMacOS) return;

    _channel.setMethodCallHandler((call) async {
      if (call.method != 'pasteText' && call.method != 'insertText') return;
      final args = (call.arguments is Map)
          ? Map<String, dynamic>.from(call.arguments as Map)
          : const <String, dynamic>{};
      final text = (args['text'] as String?) ?? '';
      if (text.isEmpty) return;

      final controller = _activeController ?? _lastKnownController;
      if (controller == null) return;

      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final isInsertText = call.method == 'insertText';
      if (isInsertText && nowMs < _suppressInsertTextUntilMs) return;

      _pendingParts.add(text);
      _pendingHasInsertText = _pendingHasInsertText || isInsertText;
      if (_flushScheduled) return;
      _flushScheduled = true;
      scheduleMicrotask(_flush);
    });
  }

  void setActive(TextEditingController controller) {
    _activeController = controller;
    _lastKnownController = controller;
  }

  void clearActive(TextEditingController controller) {
    if (_activeController == controller) {
      _activeController = null;
    }
  }

  void dispose() {
    _activeController = null;
    _lastKnownController = null;
    _pendingParts.clear();
    _flushScheduled = false;
    _pendingHasInsertText = false;
    _initialized = false;
  }

  void _flush() {
    _flushScheduled = false;
    if (_pendingParts.isEmpty) return;

    final controller = _activeController ?? _lastKnownController;
    if (controller == null) {
      _pendingParts.clear();
      _pendingHasInsertText = false;
      return;
    }

    final text = _pendingParts.join();
    _pendingParts.clear();
    if (text.isEmpty) return;

    // Prevent a feedback loop where inserting into a Flutter TextField causes
    // a programmatic insertText callback from AppKit that we would echo back.
    final suppressInsertText = _pendingHasInsertText;
    _pendingHasInsertText = false;
    if (suppressInsertText) {
      _suppressInsertTextUntilMs = DateTime.now().millisecondsSinceEpoch + 25;
    }

    try {
      _insertText(controller, text);
    } catch (_) {
      // If the controller is disposed or otherwise invalid, ignore.
    }
  }

  void _insertText(TextEditingController controller, String insert) {
    final value = controller.value;
    final selection = value.selection;

    final int start = selection.start >= 0
        ? selection.start
        : value.text.length;
    final int end = selection.end >= 0 ? selection.end : value.text.length;

    final newText = value.text.replaceRange(start, end, insert);
    controller.value = value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: start + insert.length),
      composing: TextRange.empty,
    );
  }
}

class FieldExecPasteTarget extends StatefulWidget {
  const FieldExecPasteTarget({
    super.key,
    required this.controller,
    required this.child,
    this.enabled = true,
  });

  final TextEditingController controller;
  final Widget child;
  final bool enabled;

  @override
  State<FieldExecPasteTarget> createState() => _FieldExecPasteTargetState();
}

class _FieldExecPasteTargetState extends State<FieldExecPasteTarget> {
  bool _hasFocus = false;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) {
      FieldExecPasteService.instance.ensureInitialized();
    }
  }

  @override
  void didUpdateWidget(covariant FieldExecPasteTarget oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.enabled != widget.enabled) {
      if (widget.enabled) {
        FieldExecPasteService.instance.ensureInitialized();
        if (_hasFocus) {
          FieldExecPasteService.instance.setActive(widget.controller);
        }
      } else {
        if (_hasFocus) {
          FieldExecPasteService.instance.clearActive(oldWidget.controller);
        }
      }
      return;
    }

    if (!widget.enabled) return;

    if (oldWidget.controller != widget.controller) {
      if (_hasFocus) {
        FieldExecPasteService.instance.clearActive(oldWidget.controller);
        FieldExecPasteService.instance.setActive(widget.controller);
      }
    }
  }

  void _onFocusChanged(bool hasFocus) {
    if (!widget.enabled) return;
    _hasFocus = hasFocus;
    if (hasFocus) {
      FieldExecPasteService.instance.setActive(widget.controller);
    } else {
      FieldExecPasteService.instance.clearActive(widget.controller);
    }
  }

  @override
  void dispose() {
    if (widget.enabled && _hasFocus) {
      FieldExecPasteService.instance.clearActive(widget.controller);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || !Platform.isMacOS) {
      return widget.child;
    }

    return Focus(onFocusChange: _onFocusChanged, child: widget.child);
  }
}
