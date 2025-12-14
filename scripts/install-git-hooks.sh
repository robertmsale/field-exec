#!/usr/bin/env bash
set -euo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${root}" ]]; then
  echo "Not a git repo (no top-level)." >&2
  exit 1
fi

cd "${root}"

if [[ ! -f .githooks/pre-commit ]]; then
  echo "Missing hook file: ${root}/.githooks/pre-commit" >&2
  exit 1
fi

# Decide where hooks should live:
# - If core.hooksPath is set, use it (supports repo-level custom hooks dir).
# - Otherwise install into the repo's actual hooks directory (handles worktrees
#   because `git rev-parse --git-path` follows the `.git` pointer file).
hooks_path="$(git config --get core.hooksPath 2>/dev/null || true)"
if [[ -n "${hooks_path}" ]]; then
  if [[ "${hooks_path}" = /* ]]; then
    hooks_dir="${hooks_path}"
  else
    hooks_dir="${root}/${hooks_path}"
  fi
else
  git_hooks_path="$(git rev-parse --git-path hooks)"
  if [[ "${git_hooks_path}" = /* ]]; then
    hooks_dir="${git_hooks_path}"
  else
    hooks_dir="${root}/${git_hooks_path}"
  fi
fi

hooks_dir="${hooks_dir%/}"
mkdir -p "${hooks_dir}"

src="${root}/.githooks/pre-commit"
dest="${hooks_dir}/pre-commit"
if [[ "${dest}" == "${src}" ]]; then
  chmod 0755 "${src}"
else
  install -m 0755 "${src}" "${dest}"
fi

echo "Installed pre-commit hook to ${dest}"
