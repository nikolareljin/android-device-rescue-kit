#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPERS_DIR="$REPO_ROOT/scripts/script-helpers"
HELPERS_URL="${SCRIPT_HELPERS_URL:-https://github.com/nikolareljin/script-helpers.git}"
HELPERS_BRANCH="${SCRIPT_HELPERS_BRANCH:-production}"

if [ -f "$HELPERS_DIR/helpers.sh" ]; then
  printf 'script-helpers already available at %s\n' "$HELPERS_DIR"
  exit 0
fi

if [ -d "$HELPERS_DIR" ] && [ "$(find "$HELPERS_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)" -gt 0 ]; then
  printf 'Directory exists but does not look like script-helpers: %s\n' "$HELPERS_DIR" >&2
  exit 1
fi

# Only attempt a submodule update when one is actually declared for this path.
# This repo tracks script-helpers by cloning its `production` branch rather than
# pinning a submodule, so the unconditional attempt always failed and printed an
# error on a run that then succeeded.
#
# Matched on the declared `path`, not on the submodule's name: the two are equal
# by convention but not by rule, and `[submodule "script-helpers"]` with
# `path = scripts/script-helpers` is valid.
declares_submodule() {
  [ -f "$REPO_ROOT/.gitmodules" ] || return 1
  git -C "$REPO_ROOT" config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null |
    awk '{ print $2 }' | grep -Fxq 'scripts/script-helpers'
}

if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 && declares_submodule; then
  git -C "$REPO_ROOT" submodule update --init --recursive scripts/script-helpers || {
    printf 'Submodule update failed; trying direct clone.\n' >&2
    rm -rf "$HELPERS_DIR"
    git clone --branch "$HELPERS_BRANCH" "$HELPERS_URL" "$HELPERS_DIR"
  }
else
  mkdir -p "$(dirname "$HELPERS_DIR")"
  git clone --branch "$HELPERS_BRANCH" "$HELPERS_URL" "$HELPERS_DIR"
fi

printf 'script-helpers ready at %s\n' "$HELPERS_DIR"
