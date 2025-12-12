class CodexCommand {
  final List<String> args;
  final String stdin;

  const CodexCommand({required this.args, required this.stdin});

  @override
  String toString() => 'codex ${args.join(' ')}';
}

abstract final class CodexCommandBuilder {
  static CodexCommand build({
    required String prompt,
    required String schemaPath,
    String? resumeThreadId,
    bool jsonl = true,
    String? cd,
    bool skipGitRepoCheck = false,
    Map<String, String> configOverrides = const {},
  }) {
    final args = <String>['exec'];

    if (configOverrides.isNotEmpty) {
      for (final entry in configOverrides.entries) {
        args.addAll(['-c', '${entry.key}=${entry.value}']);
      }
    }

    if (cd != null && cd.isNotEmpty) {
      args.addAll(['--cd', cd]);
    }
    if (skipGitRepoCheck) {
      args.add('--skip-git-repo-check');
    }
    if (jsonl) {
      args.add('--json');
    }

    args.addAll(['--output-schema', schemaPath]);

    if (resumeThreadId != null && resumeThreadId.isNotEmpty) {
      args.addAll(['resume', resumeThreadId, '-']);
    } else {
      args.add('-');
    }

    final stdin = prompt.endsWith('\n') ? prompt : '$prompt\n';
    return CodexCommand(args: args, stdin: stdin);
  }

  static String shellString(List<String> args) {
    // Shell-escaped argument string (used for remote SSH execution).
    return args.map(_shellEscape).join(' ');
  }

  static String _shellEscape(String s) {
    if (s.isEmpty) return "''";
    final safe = RegExp(r'^[A-Za-z0-9_./:=@-]+$');
    if (safe.hasMatch(s)) return s;
    return "'${s.replaceAll("'", "'\\''")}'";
  }
}
