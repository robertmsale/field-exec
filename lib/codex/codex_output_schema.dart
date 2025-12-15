import 'dart:convert';

/// JSON Schema used with `codex exec --output-schema` to force a structured
/// final response.
///
/// This is intentionally minimal: the assistant always returns a `message`
/// string plus optional `actions` that the UI can render as buttons.
abstract final class CodexOutputSchema {
  static const json = {
    'type': 'object',
    'description':
        'Final structured response from Codex. This must be valid JSON and MUST match this schema exactly. '
        'The client uses `message` for user-visible output, `commit_message` to optionally auto-commit git changes, '
        '`images` to reference image files produced in the workspace, and `actions` to render interactive buttons (quick replies).',
    'properties': {
      'message': {
        'type': 'string',
        'description':
            'User-visible assistant message. Write the final answer here (markdown allowed). '
            'This should be the main response the user reads in the chat. '
            'Do not include JSON or extra wrapper text outside this field.',
      },
      'commit_message': {
        'type': 'string',
        'description':
            'A concise, single-line git commit message summarizing the work performed, in imperative mood '
            '(e.g., "Add project tabs and persist sessions"). '
            'The client will run `git add -A && git commit -m "<commit_message>"` only if there are uncommitted changes. '
            'Provide this even if you made no changes (use something like "No changes").',
        'minLength': 1,
      },
      'images': {
        'type': 'array',
        'description':
            'Optional image references produced during this turn. '
            'Each entry must use an absolute `path` to an image file inside the workspace (the current project directory). '
            'The client may fetch and render these images on-demand.',
        'items': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description':
                  'Absolute filesystem path to an image file within the workspace (project directory).',
              'minLength': 1,
            },
            'caption': {
              'type': 'string',
              'description': 'Optional short caption shown under the image.',
            },
          },
          'required': ['path', 'caption'],
          'additionalProperties': false,
        },
      },
      'actions': {
        'type': 'array',
        'description':
            'Optional interactive buttons the client should render under the final message. '
            'Each action becomes a button; when the user taps it, the client sends `value` as the next user message (no typing). '
            'Use this for structured decisions (yes/no, choose option A/B, etc.). '
            'If no buttons are needed, return an empty array.',
        'items': {
          'type': 'object',
          'description':
              'A single UI action button. Keep labels short; values should be exactly what you want the user to say next.',
          'properties': {
            'id': {
              'type': 'string',
              'description':
                  'Stable identifier for this action within the response (e.g., "yes", "no", "option_a").',
              'minLength': 1,
            },
            'label': {
              'type': 'string',
              'description':
                  'Button text shown to the user (e.g., "Yes", "No").',
              'minLength': 1,
            },
            'value': {
              'type': 'string',
              'description':
                  'The exact user message to inject into the chat when this button is tapped (e.g., "yes").',
              'minLength': 1,
            },
          },
          'required': ['id', 'label', 'value'],
          'additionalProperties': false,
        },
      },
    },
    'required': ['message', 'commit_message', 'images', 'actions'],
    'additionalProperties': false,
    'strict': true,
  };

  static String encode() => const JsonEncoder.withIndent('  ').convert(json);
}
