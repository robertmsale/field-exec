import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:get/get.dart';

import '../controllers/session_controller_base.dart';
import 'codex_composer.dart';

class CodexChatView extends StatelessWidget {
  final SessionControllerBase controller;

  const CodexChatView({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final theme = ChatTheme.fromThemeData(Theme.of(context));
    return Obx(() {
      final canLoadMore = controller.hasMoreHistory.value;

      return Chat(
        chatController: controller.chatController,
        currentUserId: 'user',
        resolveUser: controller.resolveUser,
        onMessageSend: controller.sendText,
        theme: theme,
        backgroundColor: theme.colors.surface,
        builders: Builders(
          chatAnimatedListBuilder: (context, itemBuilder) {
            return ChatAnimatedList(
              itemBuilder: itemBuilder,
              bottomPadding: 120,
              onEndReached: canLoadMore ? controller.loadMoreHistory : null,
            );
          },
          composerBuilder: (context) => CodexComposer(controller: controller),
          emptyChatListBuilder: (context) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Start a conversation. Use the Help button for tips.',
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ),
            );
          },
          customMessageBuilder:
              (
                context,
                message,
                index, {
                required bool isSentByMe,
                MessageGroupStatus? groupStatus,
              }) {
                final meta = message.metadata ?? const {};
                final kind = meta['kind']?.toString();

                if (kind == 'codex_image') {
                  return _CodexImageBubble(
                    controller: controller,
                    message: message,
                  );
                }

                if (kind == 'codex_image_grid') {
                  return _CodexImageGridBubble(
                    controller: controller,
                    message: message,
                  );
                }

                if (kind == 'codex_actions') {
                  final actions = (meta['actions'] as List?) ?? const [];
                  if (actions.isEmpty) return const SizedBox.shrink();
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: actions.whereType<Map>().map((a) {
                      final label = a['label']?.toString() ?? '';
                      final value = a['value']?.toString() ?? '';
                      return Obx(
                        () => OutlinedButton(
                          onPressed: controller.isRunning.value
                              ? null
                              : () => controller.sendQuickReply(value),
                          child: Text(label),
                        ),
                      );
                    }).toList(),
                  );
                }

                if (kind == 'codex_event') {
                  final eventType = meta['eventType']?.toString() ?? 'event';
                  if (eventType == 'welcome' ||
                      eventType == 'remote_job' ||
                      eventType == 'thread.started' ||
                      eventType == 'turn.started' ||
                      eventType == 'turn.completed') {
                    return const SizedBox.shrink();
                  }
                  final text = meta['text']?.toString() ?? '';
                  return _CodexEventBubble(eventType: eventType, text: text);
                }

                if (kind == 'codex_item') {
                  final itemType = meta['itemType']?.toString() ?? 'item';
                  final eventType = meta['eventType']?.toString();
                  if (eventType == 'item.started') {
                    return const SizedBox.shrink();
                  }
                  if (itemType == 'reasoning' || itemType == 'agent_message') {
                    return const SizedBox.shrink();
                  }
                  final text = meta['text']?.toString() ?? '';
                  final item = meta['item'];
                  return _CodexItemBubble(
                    itemType: itemType,
                    eventType: eventType,
                    text: text,
                    item: item is Map ? item : null,
                  );
                }

                return const SizedBox.shrink();
              },
        ),
      );
    });
  }
}

class _CodexEventBubble extends StatelessWidget {
  final String eventType;
  final String text;

  const _CodexEventBubble({required this.eventType, required this.text});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final isError =
        eventType == 'stderr' ||
        eventType == 'tail_stderr' ||
        eventType == 'error' ||
        eventType == 'git_commit_failed' ||
        eventType == 'git_commit_stderr' ||
        eventType == 'turn.failed';

    final isCommand = eventType == 'command_execution';
    final isSuccess = eventType == 'git_commit_stdout';

    final bg = isError
        ? cs.errorContainer
        : isSuccess
        ? cs.tertiaryContainer
        : isCommand
        ? cs.secondaryContainer
        : cs.surfaceContainerHighest;

    final fg = isError
        ? cs.onErrorContainer
        : isSuccess
        ? cs.onTertiaryContainer
        : isCommand
        ? cs.onSecondaryContainer
        : cs.onSurface;

    final icon = isError
        ? Icons.error_outline
        : isSuccess
        ? Icons.check_circle_outline
        : isCommand
        ? Icons.terminal
        : Icons.info_outline;

    return _CodexBubble(
      icon: icon,
      title: eventType,
      body: text,
      background: bg,
      foreground: fg,
      monospaceBody: isCommand || eventType.contains('stderr'),
    );
  }
}

class _CodexItemBubble extends StatelessWidget {
  final String itemType;
  final String? eventType;
  final String text;
  final Map? item;

  const _CodexItemBubble({
    required this.itemType,
    required this.eventType,
    required this.text,
    required this.item,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    String title = itemType;
    IconData icon = Icons.info_outline;
    Color bg = cs.surfaceContainerHighest;
    Color fg = cs.onSurface;
    bool monospaceBody = false;

    String body = text;

    switch (itemType) {
      case 'command_execution':
        title = 'Command';
        icon = Icons.terminal;
        bg = cs.secondaryContainer;
        fg = cs.onSecondaryContainer;
        monospaceBody = true;
        final cmd = item?['command']?.toString();
        final code = item?['exit_code']?.toString();
        if (cmd != null && cmd.isNotEmpty) body = cmd;
        if (code != null && code.isNotEmpty) {
          body = body.isEmpty ? 'exit=$code' : '$body\nexit=$code';
        }
        break;
      case 'file_change':
        title = 'File';
        icon = Icons.description_outlined;
        bg = cs.primaryContainer;
        fg = cs.onPrimaryContainer;
        final path = item?['path']?.toString();
        final summary = item?['summary']?.toString();
        if (summary != null &&
            summary.isNotEmpty &&
            path != null &&
            path.isNotEmpty) {
          body = '$summary\n$path';
        } else if (path != null && path.isNotEmpty) {
          body = path;
        }
        break;
      case 'web_search':
        title = 'Web search';
        icon = Icons.search;
        bg = cs.surfaceContainerHigh;
        fg = cs.onSurface;
        final query = item?['query']?.toString();
        if (query != null && query.isNotEmpty) body = query;
        break;
      case 'mcp_tool_call':
        title = 'Tool';
        icon = Icons.build_outlined;
        bg = cs.tertiaryContainer;
        fg = cs.onTertiaryContainer;
        final tool = item?['tool']?.toString();
        final topic = item?['topic']?.toString();
        if ((tool != null && tool.isNotEmpty) ||
            (topic != null && topic.isNotEmpty)) {
          body = [
            if (tool != null && tool.isNotEmpty) tool,
            if (topic != null && topic.isNotEmpty) topic,
          ].join('\n');
        }
        break;
      case 'todo_list':
        return _CodexTodoListBubble(
          eventType: eventType,
          background: cs.surfaceContainerHigh,
          foreground: cs.onSurface,
          items: item?['items'],
          fallbackText: text,
        );
      default:
        title = itemType;
        icon = Icons.info_outline;
        bg = cs.surfaceContainerHighest;
        fg = cs.onSurface;
        break;
    }

    if (eventType != null && eventType!.isNotEmpty) {
      title = '$title • $eventType';
    }

    return _CodexBubble(
      icon: icon,
      title: title,
      body: body,
      background: bg,
      foreground: fg,
      monospaceBody: monospaceBody,
    );
  }
}

class _CodexTodoListBubble extends StatelessWidget {
  final String? eventType;
  final Color background;
  final Color foreground;
  final Object? items;
  final String fallbackText;

  const _CodexTodoListBubble({
    required this.eventType,
    required this.background,
    required this.foreground,
    required this.items,
    required this.fallbackText,
  });

  @override
  Widget build(BuildContext context) {
    final title = eventType == null || eventType!.isEmpty
        ? 'Plan'
        : 'Plan • $eventType';

    final parsed = <({String text, bool completed})>[];
    if (items is List) {
      for (final entry in (items as List).whereType<Map>()) {
        final text = entry['text']?.toString() ?? '';
        if (text.trim().isEmpty) continue;
        final completed = entry['completed'] == true;
        parsed.add((text: text, completed: completed));
      }
    }

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: DefaultTextStyle(
        style:
            Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: foreground) ??
            TextStyle(fontSize: 12, color: foreground),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.checklist, size: 14, color: foreground),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(
                      context,
                    ).textTheme.labelMedium?.copyWith(color: foreground),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (parsed.isNotEmpty) ...[
              const SizedBox(height: 6),
              for (final row in parsed)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Icon(
                          row.completed
                              ? Icons.check_box
                              : Icons.check_box_outline_blank,
                          size: 14,
                          color: foreground.withValues(alpha: 0.8),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          row.text,
                          style: row.completed
                              ? TextStyle(
                                  decoration: TextDecoration.lineThrough,
                                  color: foreground.withValues(alpha: 0.75),
                                )
                              : TextStyle(color: foreground),
                        ),
                      ),
                    ],
                  ),
                ),
            ] else if (fallbackText.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(fallbackText),
            ],
          ],
        ),
      ),
    );
  }
}

class _CodexImageBubble extends StatelessWidget {
  final SessionControllerBase controller;
  final CustomMessage message;

  const _CodexImageBubble({required this.controller, required this.message});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final meta = message.metadata ?? const {};
    final path = meta['path']?.toString() ?? '';
    final caption = meta['caption']?.toString() ?? '';
    final status = meta['status']?.toString() ?? 'tap_to_load';
    final error = meta['error']?.toString() ?? '';
    final bytes = meta['bytes'];
    final Uint8List? imgBytes = bytes is Uint8List ? bytes : null;
    final loaded = imgBytes?.isNotEmpty ?? false;
    final loading = status == 'loading' && !loaded;
    final hasError = status == 'error';

    final bg = cs.surfaceContainerHigh;
    final fg = cs.onSurface;

    Future<void> onTap() async {
      if (loaded) {
        final bytes = imgBytes;
        if (bytes == null) return;
        await showDialog<void>(
          context: context,
          barrierColor: Colors.black.withValues(alpha: 0.92),
          builder: (context) {
            return Dialog(
              insetPadding: EdgeInsets.zero,
              backgroundColor: Colors.transparent,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      child: InteractiveViewer(
                        minScale: 0.5,
                        maxScale: 6,
                        child: Center(
                          child: Image.memory(
                            bytes,
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stack) {
                              return _imageDecodeError(context);
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 24,
                    right: 24,
                    child: IconButton.filledTonal(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ),
                  if (caption.trim().isNotEmpty)
                    Positioned(
                      left: 24,
                      right: 24,
                      bottom: 24,
                      child: Material(
                        color: Colors.black.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            caption,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: Colors.white),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        );
        return;
      }
      await controller.loadImageAttachment(message);
    }

    final title = path.isEmpty
        ? 'Image'
        : (path.split('/').last.isEmpty ? 'Image' : path.split('/').last);

    Widget body;
    if (loaded) {
      final bytes = imgBytes;
      if (bytes == null) return const SizedBox.shrink();
      body = ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stack) {
              return _imageDecodeError(context);
            },
          ),
        ),
      );
    } else if (hasError) {
      body = Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cs.errorContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.broken_image_outlined,
              size: 18,
              color: cs.onErrorContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                error.trim().isEmpty ? 'Failed to load image.' : error.trim(),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: cs.onErrorContainer),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => controller.loadImageAttachment(message),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    } else {
      body = Container(
        height: 160,
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.6)),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.image_outlined, color: fg.withValues(alpha: 0.7)),
              const SizedBox(height: 8),
              Text(
                loading ? 'Loading…' : 'Tap to load',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: fg.withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: loading ? null : onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
          ),
          child: DefaultTextStyle(
            style:
                Theme.of(context).textTheme.bodySmall?.copyWith(color: fg) ??
                TextStyle(fontSize: 12, color: fg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.image, size: 14, color: fg),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        title,
                        style: Theme.of(
                          context,
                        ).textTheme.labelMedium?.copyWith(color: fg),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (loading) ...[
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: fg.withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                body,
                if (caption.trim().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    caption.trim(),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: fg.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CodexImageGridBubble extends StatelessWidget {
  final SessionControllerBase controller;
  final CustomMessage message;

  const _CodexImageGridBubble({
    required this.controller,
    required this.message,
  });

  static const double _tileSize = 160;
  static const double _gap = 8;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = cs.onSurface;
    final meta = message.metadata ?? const {};
    final raw = meta['images'];
    if (raw is! List) return const SizedBox.shrink();

    final images = raw
        .whereType<Map>()
        .map((m) => m.cast<String, Object?>())
        .toList();
    if (images.isEmpty) return const SizedBox.shrink();

    Future<void> openFullscreen(Uint8List bytes, {String caption = ''}) async {
      await showDialog<void>(
        context: context,
        barrierColor: Colors.black.withValues(alpha: 0.92),
        builder: (context) {
          return Dialog(
            insetPadding: EdgeInsets.zero,
            backgroundColor: Colors.transparent,
            child: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: InteractiveViewer(
                      minScale: 0.5,
                      maxScale: 6,
                      child: Center(
                        child: Image.memory(
                          bytes,
                          fit: BoxFit.contain,
                          errorBuilder: (context, error, stack) {
                            return _imageDecodeError(context);
                          },
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 24,
                  right: 24,
                  child: IconButton.filledTonal(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ),
                if (caption.trim().isNotEmpty)
                  Positioned(
                    left: 24,
                    right: 24,
                    bottom: 24,
                    child: Material(
                      color: Colors.black.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          caption.trim(),
                          style: Theme.of(
                            context,
                          ).textTheme.bodyMedium?.copyWith(color: Colors.white),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      );
    }

    Widget tileFor(int i) {
      final img = images[i];
      final path = img['path']?.toString() ?? '';
      final caption = img['caption']?.toString() ?? '';
      final status = img['status']?.toString() ?? 'tap_to_load';
      final error = img['error']?.toString() ?? '';
      final bytes = img['bytes'];
      final Uint8List? imgBytes = bytes is Uint8List ? bytes : null;
      final loaded = imgBytes?.isNotEmpty ?? false;
      final loading = status == 'loading' && !loaded;
      final hasError = status == 'error';

      Future<void> onTap() async {
        if (loaded) {
          final b = imgBytes;
          if (b == null) return;
          await openFullscreen(b, caption: caption);
          return;
        }
        await controller.loadImageAttachment(message, index: i);
      }

      final label = path.isEmpty
          ? 'Image'
          : (path.split('/').last.isEmpty ? 'Image' : path.split('/').last);

      Widget inner;
      if (loaded) {
        final b = imgBytes;
        if (b == null) return const SizedBox.shrink();
        inner = ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.memory(
            b,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stack) {
              return _imageDecodeError(context);
            },
          ),
        );
      } else if (hasError) {
        final details = error.trim();
        inner = Container(
          decoration: BoxDecoration(
            color: cs.errorContainer,
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.all(10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.broken_image_outlined, color: cs.onErrorContainer),
              const SizedBox(height: 8),
              Text(
                'Failed',
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(color: cs.onErrorContainer),
              ),
              const SizedBox(height: 6),
              Text(
                details.isEmpty ? 'Tap to retry' : details,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onErrorContainer.withValues(alpha: 0.85),
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        );
      } else {
        inner = Container(
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.6)),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.image_outlined, color: fg.withValues(alpha: 0.7)),
                const SizedBox(height: 8),
                Text(
                  loading ? 'Loading…' : 'Tap to load',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: fg.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
        );
      }

      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: loading ? null : onTap,
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: _tileSize,
            height: _tileSize,
            child: Stack(
              children: [
                Positioned.fill(child: inner),
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(
                        alpha: loaded ? 0.35 : 0.18,
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      caption.trim().isNotEmpty ? caption.trim() : label,
                      style: Theme.of(
                        context,
                      ).textTheme.labelSmall?.copyWith(color: Colors.white),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
                if (loading)
                  Positioned(
                    top: 10,
                    right: 10,
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white.withValues(alpha: 0.9),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    final bg = cs.surfaceContainerHigh;
    final titleStyle = Theme.of(
      context,
    ).textTheme.labelMedium?.copyWith(color: fg);
    final count = images.length;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.photo_library_outlined, size: 14, color: fg),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  count == 1 ? 'Image' : 'Images ($count)',
                  style: titleStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: _gap,
            runSpacing: _gap,
            children: List.generate(count, tileFor),
          ),
        ],
      ),
    );
  }
}

Widget _imageDecodeError(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return Container(
    decoration: BoxDecoration(
      color: cs.errorContainer,
      borderRadius: BorderRadius.circular(10),
    ),
    padding: const EdgeInsets.all(10),
    child: Row(
      children: [
        Icon(Icons.broken_image_outlined, color: cs.onErrorContainer),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'Invalid image data.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: cs.onErrorContainer),
          ),
        ),
      ],
    ),
  );
}

class _CodexBubble extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final Color background;
  final Color foreground;
  final bool monospaceBody;

  const _CodexBubble({
    required this.icon,
    required this.title,
    required this.body,
    required this.background,
    required this.foreground,
    required this.monospaceBody,
  });

  @override
  Widget build(BuildContext context) {
    final titleStyle = Theme.of(
      context,
    ).textTheme.labelMedium?.copyWith(color: foreground);
    final bodyStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: foreground,
      fontFamily: monospaceBody ? 'monospace' : null,
    );

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: DefaultTextStyle(
        style: bodyStyle ?? const TextStyle(fontSize: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 14, color: foreground),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    title,
                    style: titleStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (body.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(body),
            ],
          ],
        ),
      ),
    );
  }
}
