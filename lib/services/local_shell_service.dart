import 'dart:convert';
import 'dart:io';

import 'package:process_run/shell.dart';

class LocalCommandProcess {
  final Stream<String> stdoutLines;
  final Stream<String> stderrLines;
  final Future<int> exitCode;
  final Future<void> done;
  final void Function() cancel;

  const LocalCommandProcess({
    required this.stdoutLines,
    required this.stderrLines,
    required this.exitCode,
    required this.done,
    required this.cancel,
  });
}

class LocalShellService {
  LocalCommandProcess startCommand({
    required String executable,
    required List<String> arguments,
    required String workingDirectory,
    String? stdin,
  }) {
    final out = ShellLinesController(encoding: utf8);
    final err = ShellLinesController(encoding: utf8);

    final stdinStream = (stdin == null)
        ? null
        : Stream<List<int>>.fromIterable([utf8.encode(stdin)]);

    final shell = Shell(
      workingDirectory: workingDirectory,
      stdin: stdinStream,
      stdout: out.sink,
      stderr: err.sink,
      verbose: false,
      throwOnError: false,
    );

    final runFuture = shell.runExecutableArguments(executable, arguments);

    void cancel() {
      try {
        shell.kill();
      } catch (_) {}
    }

    return LocalCommandProcess(
      stdoutLines: out.stream,
      stderrLines: err.stream,
      done: runFuture.then((_) {}),
      exitCode: runFuture.then((r) => r.exitCode),
      cancel: cancel,
    );
  }

  Future<ProcessResult> run({
    required String executable,
    required List<String> arguments,
    required String workingDirectory,
    bool throwOnError = false,
  }) async {
    final shell = Shell(
      workingDirectory: workingDirectory,
      verbose: false,
      throwOnError: throwOnError,
    );
    return shell.runExecutableArguments(executable, arguments);
  }
}
