import 'dart:convert';

class CodexCommand {
  final List<String> args;
  final String stdin;

  const CodexCommand({required this.args, required this.stdin});

  @override
  String toString() => 'codex ${args.join(' ')}';
}

abstract final class CodexCommandBuilder {
  static const String defaultDeveloperInstructions = '''
You are running as Codex CLI in non-interactive mode.

You MUST produce a final response that is valid JSON matching the schema passed via `--output-schema`.
- Put all user-visible content in `message` (markdown allowed).
- Always include `commit_message` as a concise, single-line git commit message (imperative mood).
  - The client may run `git add -A && git commit -m "<commit_message>"` only if there are changes.
- If you produced images the user should see (e.g. golden test diffs, screenshots), include them in `images`:
  - Each entry must include `path` as an absolute filesystem path inside the workspace (project directory).
  - Optionally include a short `caption`.
  - The client may fetch these images and display them in the chat.
- You may use a .gitignored path for image storage such as `.field_exec/images` to ensure they are not committed and only visible to the user.
- If you did not produce any images, return `images` as an empty array (`[]`).
- If you need a user decision, return `actions` as button options:
  - Each action has `id`, `label`, and `value`.
  - When tapped, the client sends `value` as the next user message.
  - Even if the only option is "Continue", provide that option for the user.

Do NOT add extra wrapper text outside the JSON object.
''';

  /// Encodes plain text as a TOML basic string value (including surrounding quotes),
  /// suitable for `codex exec -c key=value`.
  static String tomlString(String value) => jsonEncode(value);

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
