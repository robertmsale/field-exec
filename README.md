# Codex Remote

Codex Remote is a Flutter app (iOS + macOS) that lets you run Codex CLI “sessions” on your Mac—either **over SSH** (from iOS or macOS) or **locally** (macOS).

It’s designed for concurrency: you can keep multiple projects and multiple sessions running at once, switch between them, and resume past conversations by thread ID.

## Features

- **Remote mode (iOS + macOS)**: connect to `username@host` over SSH and run `codex exec`.
- **Local mode (macOS)**: run `codex` directly via local shell execution.
- **Projects**: save remote/local working directories as “projects”.
- **Tabs per project**: multiple concurrent agent sessions per project.
- **Resumable sessions**: `codex exec --json` thread IDs are stored and can be resumed.
- **Structured output**: uses `codex exec --json --output-schema` so the app can render events and interactive action buttons.
- **Background-friendly remote execution**:
  - If `tmux` is available on the remote host, sessions run detached in `tmux`.
  - Otherwise it falls back to `nohup` and tracks the process PID.
- **Stop button**: stops the current remote job (kills tmux session or PID) or local process.
- **Key-based SSH**: store a single global private key in Apple Keychain.
- **Password is never stored**: password is only used as a setup/bootstrapping path to get keys installed.
- **Optional auto-commit**: if the final structured response includes a non-empty `commit_message`, the app runs `git add -A && git commit -m "<commit_message>"` (only if there are changes).

## How It Works

Each user message starts a non-interactive Codex turn:

- Remote: the app starts a background job on the remote host that runs `codex exec --json --output-schema …` in the selected project directory.
- The job appends JSONL output to a project-local log file:
  - `.codex_remote/sessions/<tabId>.log`
- The app tails that file over SSH and renders events/messages in the chat UI.

On macOS local mode, the app runs `codex` locally and streams stdout/stderr into the chat in the same JSONL format.

## Requirements

- Flutter SDK + Xcode (for iOS and macOS builds).
- Codex CLI installed on the Mac that will run Codex:
  - Local mode: installed on the same Mac running the app.
  - Remote mode: installed on the remote Mac host reachable via SSH.
- SSH server enabled on the remote Mac (System Settings → Sharing → Remote Login).
- Optional (recommended): `tmux` installed on the remote host for the best “keep running while disconnected” behavior.

## Setup

Install dependencies:

```bash
flutter pub get
```

Run macOS:

```bash
flutter run -d macos
```

Run iOS (device or simulator):

```bash
flutter run -d ios
```

### macOS sandbox note

Local execution requires the macOS App Sandbox to be disabled. This repo sets:

- `macos/Runner/DebugProfile.entitlements`
- `macos/Runner/Release.entitlements`

to `com.apple.security.app-sandbox = false`.

## Using the App

### Connect (Remote mode)

1. Enter `username@host` and the port.
2. If a key is saved, the app tries key auth first.
3. If key auth fails (or no key exists), it prompts for a password (not stored).

### Manage SSH keys

Use **Settings → SSH Keys** to:

- Paste/import a PEM private key
- Generate a new Ed25519 key
- Install the derived public key on a server (writes to `~/.ssh/authorized_keys`)

Currently the app supports **one global key**.

### Projects, tabs, and resuming conversations

- Add a project by selecting a path (remote path over SSH, or local path on macOS local mode).
- Each project has tabs; each tab runs an independent Codex session.
- Use the history picker to resume a previous `thread_id`.

## Data & Security

- Private keys are stored using `flutter_secure_storage` (Apple Keychain).
- Passwords are never stored.
- Session logs are written into the project under `.codex_remote/`.
  - The app automatically adds `.codex_remote/` to `.git/info/exclude` before auto-commit so logs/schema don’t get committed.

## Troubleshooting

- If you don’t see `tmux` sessions on the remote host, install `tmux` or the app will fall back to `nohup`+PID.
- To inspect remote processes: `ps -ax | grep codex`
- The active remote session log is in `.codex_remote/sessions/<tabId>.log`

## License

MIT. See `LICENSE.md`.
