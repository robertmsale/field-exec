# Advanced Usage
## Agent Pipeline

`codex exec` is an incredibly powerful tool. FieldExec was build around it, but the possibilities for automation are quite literally endless. Here we will talk about creating a pipeline that turns a single branch into an integration point for multiple worktrees.

### Git Hooks

On pre-commit:

```bash
#!/usr/bin/env bash
set -euo pipefail

branch="$(git symbolic-ref -q --short HEAD 2>/dev/null || echo "HEAD")"
if [[ "$branch" == "master" ]] || [[ "$branch" == "staging" ]]; then
  exit 0
fi

if git diff --cached --quiet; then
  exit 0
fi

if ! command -v codex >/dev/null 2>&1; then
  echo "facts-alignment: 'codex' not found; aborting commit (set EZRA_FACTS_ALIGN_SKIP=1 to bypass)" >&2
  exit 1
fi

hook_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
prompt_file="${hook_dir}/facts-alignment.prompt.txt"
if [[ ! -f "${prompt_file}" ]]; then
  echo "facts-alignment: missing ${prompt_file}; aborting commit" >&2
  exit 1
fi

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

prompt="$(cat "${prompt_file}")"

codex exec -c 'model_reasoning_effort="low"' "$prompt"

# Auto-stage any alignment edits.
git add -A docs .githooks/README.md 2>/dev/null || true
```

This hook does two crucial pre-commit actions:
1. It skips commits made to master and staging.
2. It executes a codex agent specifically tasked with factual realignment of the code documentation.

If you are not utilizing a memory and planning system for your AI assistants in your codebase, now is a good time to set this up. Keeping the agents aligned with the codebase as it currently exists is extremely helpful for avoiding drift.

On post-commit & post-rewrite:

```bash
#!/usr/bin/env bash
set -euo pipefail

hook_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
helper="${hook_dir}/worktree-auto-fastforward.sh"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "${repo_root}" ]] && [[ -f "${repo_root}/scripts/worktree-auto-fastforward.sh" ]]; then
  exec "${repo_root}/scripts/worktree-auto-fastforward.sh" "post-commit"
fi

if [[ -f "${helper}" ]]; then
  exec "${helper}" "post-commit"
fi

exit 0
```

In my projects I have a script that automatically merges and fast-forwards into staging branch. This way after facts & alignment are completed, if another agent is prompted, their worktree can be fast-forwarded to see the most recent changes (factually and in working code). This ensures concurrent work in different areas of the codebase are immediately visible to every agent.

### Env Wrapper

A little known secret feature in FieldExec is that you can wrap the codex command as a shell function, giving you pre-launch automation:

```bash

# Fast-forward the current branch to match another ref/branch
git_ff_to() {
  target="$1"

  if [ -z "$target" ]; then
    echo "Usage: git_ff_to <target-branch-or-ref>" >&2
    return 1
  fi

  # Make sure we're in a git worktree
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Not inside a git worktree." >&2
    return 1
  fi

  # Refuse to operate on a detached HEAD
  cur_branch=$(git symbolic-ref --quiet --short HEAD) || {
    echo "HEAD is detached; refusing to move it automatically." >&2
    return 1
  }

  # Reject if the target refers to the same branch as the one checked out here
  if [ "$cur_branch" = "$target" ] || \
     [ "$(git rev-parse "$cur_branch")" = "$(git rev-parse "$target")" ]; then
      echo "Target is the same as the current worktree branch; no fast-forward needed." >&2
      return 1
  fi

  # Require a clean worktree (no unstaged or staged changes)
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Worktree has uncommitted changes; commit or stash them first." >&2
    return 1
  fi

  # Refuse if a rebase/merge/etc is in progress
  gitdir=$(git rev-parse --git-dir)
  if [ -d "$gitdir/rebase-apply" ] || [ -d "$gitdir/rebase-merge" ] \
     || [ -f "$gitdir/MERGE_HEAD" ] || [ -f "$gitdir/CHERRY_PICK_HEAD" ]; then
    echo "A rebase/merge/cherry-pick appears to be in progress; aborting." >&2
    return 1
  fi

  # Resolve target to a commit
  target_commit=$(git rev-parse --verify -q "${target}^{commit}") || {
    echo "Unknown target ref: $target" >&2
    return 1
  }

  head_commit=$(git rev-parse --verify HEAD)

  # Already there?
  if [ "$head_commit" = "$target_commit" ]; then
    echo "Already at $target_commit"
    return 0
  fi

  # Ensure this is a *fast-forward* (current HEAD must be ancestor of target)
  if ! git merge-base --is-ancestor "$head_commit" "$target_commit"; then
    echo "Cannot fast-forward: $cur_branch has diverged from $target." >&2
    echo "Aborting without changing anything." >&2
    return 1
  fi

  echo "Fast-forwarding $cur_branch from $head_commit to $target ($target_commit)..."
  git merge --ff-only "$target"
}

silent_git_ff_to() {
  git_ff_to staging >/dev/null 2>&1 || true
}

codex() {
  silent_git_ff_to
  command codex "$@"
}

```

FieldExec sources from `<REPO_ROOT>/.field_exec/env.sh` before launching `codex exec`. In this case, since pre-commit hook ensures the worktree is not diverged from staging, the `git_ff_to` function performs one last fast-forward on the worker branch before launching codex for another round. In the event that another commit was merged into staging before you had a chance to launch another session, you never have to worry about the worker starting their session without the most recent CI changes.

You can take the function a step further by specifying inline configuration changes:

```bash
codex() {
    shift # remove `exec` from the command
    silent_git_ff_to
    command codex exec -c 'model="gpt-5.1-codex-max"' "$@"
}
```

Here you can override what's present in your config.toml, incase you prefer specific models for specific worktrees. What's important for FieldExec to work properly is that none of your prelaunch scripting produces any stdout or stderr because FieldExec relies on JSON payloads from `codex exec --json --output-schema` to properly render the UI. Setups like this require a lot of trial and error. Pay attention to `ps -ax` during testing, and happy coding!
