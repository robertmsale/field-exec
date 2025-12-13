import 'package:flutter/material.dart';

class ProjectSessionsHelpSheet extends StatelessWidget {
  const ProjectSessionsHelpSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Text('Help', style: textTheme.titleLarge),
          const SizedBox(height: 12),
          Text(
            'Codex Remote runs Codex CLI sessions either locally (macOS) or over SSH (iOS/macOS).',
            style: textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          Text('What you’re seeing', style: textTheme.titleMedium),
          const SizedBox(height: 8),
          const _HelpBullet('Each tab is an independent Codex session.'),
          const _HelpBullet('The status bar shows the remote job (tmux/PID) and thread ID.'),
          const _HelpBullet('Use the History button to resume a previous thread.'),
          const _HelpBullet('Use the Stop button to stop the current job.'),
          const SizedBox(height: 16),
          Text('Troubleshooting', style: textTheme.titleMedium),
          const SizedBox(height: 8),
          const _HelpBullet('For best remote behavior, install tmux on the host.'),
          const _HelpBullet('If logs stop updating after sleep, switch tabs or resume the app to reattach.'),
          const _HelpBullet('SSH passwords are never stored; keys are stored in Keychain.'),
        ],
      ),
    );
  }
}

class _HelpBullet extends StatelessWidget {
  final String text;
  const _HelpBullet(this.text);

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Icon(Icons.circle, size: 6),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: style)),
        ],
      ),
    );
  }
}

