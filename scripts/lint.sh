#!/usr/bin/env bash
# SCRIPT: lint.sh
# DESCRIPTION: Static checks for every shell script in this repository.
# USAGE: ./scripts/lint.sh
# ENVIRONMENT:
#   LINT_ALLOW_MISSING_SHELLCHECK=1  Skip shellcheck when it is not installed.
#                                    For local use only. CI must never set it,
#                                    or the gate silently stops checking.
# EXAMPLE: ./scripts/lint.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# The entrypoints carry no .sh extension, so they have to be named.
EXTENSIONLESS=(dump prompt update)

collect_files() {
  local -a found=()
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # Tracked files only. This cannot walk into scripts/script-helpers or
    # scripts/ci-helpers, which are gitignored clones of other repositories and
    # are not ours to lint.
    while IFS= read -r f; do
      [ -n "$f" ] && found+=("$f")
    done < <(git ls-files -- '*.sh' "${EXTENSIONLESS[@]}")
  else
    while IFS= read -r -d '' f; do
      found+=("${f#./}")
    done < <(find . -path ./.git -prune -o \
      -path ./scripts/script-helpers -prune -o \
      -path ./scripts/ci-helpers -prune -o \
      -type f -name '*.sh' -print0)
    local e
    for e in "${EXTENSIONLESS[@]}"; do
      [ -f "$e" ] && found+=("$e")
    done
  fi
  printf '%s\n' "${found[@]}"
}

mapfile -t FILES < <(collect_files)

if [ "${#FILES[@]}" -eq 0 ]; then
  printf 'lint: found no shell files to check\n' >&2
  exit 1
fi

printf 'lint: checking %d shell files\n' "${#FILES[@]}"

printf 'lint: bash -n\n'
bash -n "${FILES[@]}"

if command -v shellcheck >/dev/null 2>&1; then
  printf 'lint: shellcheck\n'
  # -x follows sourced files.
  #
  # Severity `info`, not `warning`: SC2086 (unquoted expansion, so word
  # splitting and globbing) is info-level, and in a tool that runs `rm -rf` and
  # `adb push` on user-chosen paths that is the single check most worth having.
  # A `warning` threshold passes `rm -rf $1/sub` without comment.
  #
  # The repository is clean at this level, so anything new that trips it is a
  # regression rather than backlog.
  shellcheck -S info -x "${FILES[@]}"
elif [ "${LINT_ALLOW_MISSING_SHELLCHECK:-0}" = "1" ]; then
  printf 'lint: shellcheck not installed; skipped by LINT_ALLOW_MISSING_SHELLCHECK\n' >&2
else
  printf 'lint: shellcheck is not installed.\n' >&2
  printf 'lint: install it, or set LINT_ALLOW_MISSING_SHELLCHECK=1 to skip locally.\n' >&2
  exit 1
fi

printf 'lint: OK\n'
