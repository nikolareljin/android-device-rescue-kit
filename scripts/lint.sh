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
EXTENSIONLESS=(adrescue dump prompt update .githooks/pre-commit .githooks/pre-push)

collect_files() {
  local -a found=()
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # Tracked files AND untracked ones that are not ignored.
    #
    # --others is not optional: with --cached alone a script that has been
    # written but not yet `git add`ed is invisible, so the lint reports OK
    # having never opened the file you just wrote. --exclude-standard still
    # honours .gitignore, so this cannot walk into scripts/script-helpers or
    # scripts/ci-helpers, which are clones of other repositories and are not
    # ours to lint.
    while IFS= read -r f; do
      [ -n "$f" ] && found+=("$f")
    done < <(git ls-files --cached --others --exclude-standard -- '*.sh' "${EXTENSIONLESS[@]}" | sort -u)
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
# One file per invocation, deliberately.
#
# `bash -n a.sh b.sh` syntax-checks ONLY a.sh — b.sh and the rest become $1, $2
# … and are never read. It exits 0 on a file with an unterminated `if` as long
# as the first file is clean, which is how the previous inline CI command left
# `prompt` and `update` unchecked while appearing to cover them.
bash_n_failed=0
for f in "${FILES[@]}"; do
  bash -n "$f" || bash_n_failed=1
done
[ "$bash_n_failed" -eq 0 ] || exit 1

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
