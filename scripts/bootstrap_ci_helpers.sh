#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPERS_DIR="$REPO_ROOT/scripts/ci-helpers"
HELPERS_URL="${CI_HELPERS_URL:-https://github.com/nikolareljin/ci-helpers.git}"
HELPERS_BRANCH="${CI_HELPERS_BRANCH:-production}"

if [ -f "$HELPERS_DIR/scripts/check_release_version.sh" ]; then
  printf 'ci-helpers already available at %s\n' "$HELPERS_DIR"
  exit 0
fi

if [ -d "$HELPERS_DIR" ] && [ "$(find "$HELPERS_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)" -gt 0 ]; then
  printf 'Directory exists but does not look like ci-helpers: %s\n' "$HELPERS_DIR" >&2
  exit 1
fi

mkdir -p "$(dirname "$HELPERS_DIR")"
git clone --branch "$HELPERS_BRANCH" "$HELPERS_URL" "$HELPERS_DIR"
printf 'ci-helpers ready at %s\n' "$HELPERS_DIR"
