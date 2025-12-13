import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../services/secure_storage_service.dart';
import '../../services/ssh_service.dart';
import 'target_args.dart';

class RunCommandSheet extends StatefulWidget {
  final TargetArgs target;
  final String projectPath;

  const RunCommandSheet({
    super.key,
    required this.target,
    required this.projectPath,
  });

  @override
  State<RunCommandSheet> createState() => _RunCommandSheetState();
}

class _RunCommandSheetState extends State<RunCommandSheet> {
  final _commandController = TextEditingController();
  String _output = '';
  bool _running = false;
  String? _sshPassword;

  SecureStorageService get _storage => Get.find<SecureStorageService>();
  SshService get _ssh => Get.find<SshService>();

  @override
  void dispose() {
    _commandController.dispose();
    super.dispose();
  }

  Future<String?> _promptForPassword() async {
    final controller = TextEditingController();
    try {
      return await Get.dialog<String>(
        AlertDialog(
          title: const Text('SSH password'),
          content: TextField(
            controller: controller,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Password'),
            onSubmitted: (_) => Get.back(result: controller.text),
          ),
          actions: [
            TextButton(
              onPressed: () => Get.back(result: null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Get.back(result: controller.text),
              child: const Text('Run'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  Future<void> _run() async {
    final cmd = _commandController.text.trim();
    if (cmd.isEmpty || _running) return;

    setState(() {
      _running = true;
      _output = '';
    });

    try {
      if (widget.target.local) {
        if (!Platform.isMacOS) {
          setState(() => _output = 'Local mode is only supported on macOS.');
          return;
        }

        final res = await Process.run(
          '/bin/sh',
          ['-lc', cmd],
          workingDirectory: widget.projectPath,
        );

        final stdout = (res.stdout as Object?)?.toString() ?? '';
        final stderr = (res.stderr as Object?)?.toString() ?? '';
        setState(() {
          _output = [
            'exit=${res.exitCode}',
            if (stdout.trim().isNotEmpty) '--- stdout ---\n$stdout',
            if (stderr.trim().isNotEmpty) '--- stderr ---\n$stderr',
          ].join('\n\n');
        });
        return;
      }

      final profile = widget.target.profile;
      if (profile == null) {
        setState(() => _output = 'Missing remote connection profile.');
        return;
      }

      final pem =
          await _storage.read(key: SecureStorageService.sshPrivateKeyPemKey);
      if (pem == null || pem.trim().isEmpty) {
        setState(() => _output = 'No SSH private key set. Add one in Settings.');
        return;
      }

      final remoteCmd = "cd ${_shQuote(widget.projectPath)} && $cmd";

      Future<SshCommandResult> runOnce({String? password}) {
        return _ssh.runCommandWithResult(
          host: profile.host,
          port: profile.port,
          username: profile.username,
          privateKeyPem: pem,
          password: password,
          command: remoteCmd,
        );
      }

      SshCommandResult result;
      try {
        result = await runOnce(password: _sshPassword);
      } catch (_) {
        if (_sshPassword == null) {
          final pw = await _promptForPassword();
          if (pw == null || pw.isEmpty) rethrow;
          _sshPassword = pw;
          result = await runOnce(password: _sshPassword);
        } else {
          rethrow;
        }
      }

      setState(() {
        _output = [
          'exit=${result.exitCode ?? -1}',
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

  static String _shQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

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
                hintText: widget.target.local
                    ? 'Runs in ${widget.projectPath}'
                    : 'Runs in ${widget.projectPath} (remote)',
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

