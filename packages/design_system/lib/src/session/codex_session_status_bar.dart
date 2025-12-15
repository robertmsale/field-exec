import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/session_controller_base.dart';

class CodexSessionStatusBar extends StatelessWidget {
  final SessionControllerBase controller;

  const CodexSessionStatusBar({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final style =
        theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant) ??
            TextStyle(fontSize: 12, color: cs.onSurfaceVariant);

    return Obx(() {
      final job = controller.remoteJobId.value;
      final thread = controller.threadId.value;

      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          border: Border(
            bottom: BorderSide(color: cs.outlineVariant),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: DefaultTextStyle(
                style: style,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      job == null || job.isEmpty ? 'Job: —' : 'Job: $job',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      thread == null || thread.isEmpty
                          ? 'Thread: —'
                          : 'Thread: $thread',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
            IconButton(
              tooltip: 'Refresh',
              onPressed: controller.refresh,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
      );
    });
  }
}
