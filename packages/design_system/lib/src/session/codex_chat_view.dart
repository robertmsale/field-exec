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
    return Chat(
      chatController: controller.chatController,
      currentUserId: 'user',
      resolveUser: controller.resolveUser,
      onMessageSend: controller.sendText,
      builders: Builders(
        chatAnimatedListBuilder: (context, itemBuilder) {
          return ChatAnimatedList(
            itemBuilder: itemBuilder,
            bottomPadding: 120,
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
        customMessageBuilder: (
          context,
          message,
          index, {
          required bool isSentByMe,
          MessageGroupStatus? groupStatus,
        }) {
          final meta = message.metadata ?? const {};
          final kind = meta['kind']?.toString();

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
  }
}

class _CodexEventBubble extends StatelessWidget {
  final String eventType;
  final String text;

  const _CodexEventBubble({required this.eventType, required this.text});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final isError = eventType == 'stderr' ||
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
        if (summary != null && summary.isNotEmpty && path != null && path.isNotEmpty) {
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
        if ((tool != null && tool.isNotEmpty) || (topic != null && topic.isNotEmpty)) {
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
        style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: foreground) ??
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
                    style: Theme.of(context)
                        .textTheme
                        .labelMedium
                        ?.copyWith(color: foreground),
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
    final titleStyle = Theme.of(context)
        .textTheme
        .labelMedium
        ?.copyWith(color: foreground);
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
