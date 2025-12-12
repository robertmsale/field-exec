import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:get/get.dart';

import 'session_controller.dart';
import 'codex_composer.dart';

class CodexChatView extends StatelessWidget {
  final SessionController controller;

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
          // Extra padding keeps the last bubbles comfortably above our custom
          // composer (which is not the stock `Composer` widget).
          return ChatAnimatedList(
            itemBuilder: itemBuilder,
            bottomPadding: 120,
          );
        },
        composerBuilder: (context) => CodexComposer(controller: controller),
        customMessageBuilder: (
          context,
          message,
          index, {
          required bool isSentByMe,
          MessageGroupStatus? groupStatus,
        }) {
          final meta = message.metadata ?? const {};
          final kind = meta['kind'];
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

          if (kind == 'codex_event' || kind == 'codex_item') {
            final title =
                (meta['eventType'] ?? meta['itemType'] ?? 'event').toString();
            final text = (meta['text'] ?? '').toString();
            return Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: DefaultTextStyle(
                style: Theme.of(context).textTheme.bodySmall!,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.labelMedium),
                    if (text.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(text),
                    ],
                  ],
                ),
              ),
            );
          }

          return const SizedBox.shrink();
        },
      ),
    );
  }
}
