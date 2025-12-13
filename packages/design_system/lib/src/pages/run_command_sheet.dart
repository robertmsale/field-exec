import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/project_sessions_controller_base.dart';

class RunCommandSheet extends StatefulWidget {
  final String hintText;
  final Future<RunCommandResult> Function(String command) run;

  const RunCommandSheet({
    super.key,
    required this.hintText,
    required this.run,
  });

  @override
  State<RunCommandSheet> createState() => _RunCommandSheetState();
}

class _RunCommandSheetState extends State<RunCommandSheet> {
  final _commandController = TextEditingController();
  String _output = '';
  bool _running = false;

  @override
  void dispose() {
    _commandController.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final cmd = _commandController.text.trim();
    if (cmd.isEmpty || _running) return;

    setState(() {
      _running = true;
      _output = '';
    });

    try {
      final result = await widget.run(cmd);
      setState(() {
        _output = [
          'exit=${result.exitCode}',
          if (result.stdout.trim().isNotEmpty) '--- stdout ---\n${result.stdout}',
          if (result.stderr.trim().isNotEmpty) '--- stderr ---\n${result.stderr}',
        ].join('\n\n');
      });
    } catch (e) {
      setState(() => _output = 'Error: $e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _copyOutput() async {
    if (_output.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _output));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Output copied to clipboard')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 12,
          bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Run shell command',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: 'Copy output',
                  onPressed: _copyOutput,
                  icon: const Icon(Icons.copy),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _commandController,
              autofocus: true,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                hintText: widget.hintText,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _run(),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _running ? null : _run,
                    icon: _running
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_arrow),
                    label: Text(_running ? 'Running…' : 'Run'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Flexible(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    _output.trim().isEmpty ? '(no output yet)' : _output,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

