import 'package:flutter/material.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';

import '../controllers/session_controller_base.dart';

class CodexComposer extends StatefulWidget {
  final SessionControllerBase controller;

  const CodexComposer({super.key, required this.controller});

  @override
  State<CodexComposer> createState() => _CodexComposerState();
}

class _CodexComposerState extends State<CodexComposer> {
  late final TextEditingController _text;
  final GlobalKey _key = GlobalKey();
  double _lastHeight = -1;

  @override
  void initState() {
    super.initState();
    _text = widget.controller.inputController;
  }

  void _measure() {
    final ctx = _key.currentContext;
    if (ctx == null) return;

    final renderBox = ctx.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final height = renderBox.size.height;
    if (height == _lastHeight) return;
    _lastHeight = height;

    final bottomSafeArea = MediaQuery.of(context).padding.bottom;
    context.read<ComposerHeightNotifier>().setHeight(height - bottomSafeArea);
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        minimum: const EdgeInsets.all(12),
        child: Material(
          key: _key,
          elevation: 2,
          borderRadius: BorderRadius.circular(16),
          color: Theme.of(context).colorScheme.surface,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Obx(() {
                  if (!widget.controller.isRunning.value) {
                    return const SizedBox.shrink();
                  }

                  final preview = widget.controller.thinkingPreview.value;
                  final cs = Theme.of(context).colorScheme;
                  final style = Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: cs.onSurfaceVariant);

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        const IsTypingIndicator(size: 5),
                        const SizedBox(width: 8),
                        Text('Thinking', style: style),
                        if (preview != null && preview.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              preview,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: style,
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                }),
                Row(
                  children: [
                    Expanded(
                      child: Obx(
                        () => TextField(
                          controller: _text,
                          enabled: !widget.controller.isRunning.value,
                          decoration: const InputDecoration(
                            hintText: 'Message Codex…',
                            border: InputBorder.none,
                          ),
                          textInputAction: TextInputAction.send,
                          onSubmitted: (value) {
                            if (widget.controller.isRunning.value) return;
                            widget.controller.sendText(value);
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Obx(() {
                      final running = widget.controller.isRunning.value;
                      return IconButton.filled(
                        onPressed: () {
                          if (running) {
                            widget.controller.stop();
                            return;
                          }
                          widget.controller.sendText(_text.text);
                        },
                        icon: Icon(running ? Icons.stop : Icons.send),
                        tooltip: running ? 'Stop' : 'Send',
                      );
                    }),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
