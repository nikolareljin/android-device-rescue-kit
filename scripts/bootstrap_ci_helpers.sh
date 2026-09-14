#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPERS_DIR="${CI_HELPERS_DIR:-$REPO_ROOT/scripts/ci-helpers}"
HELPERS_URL="${CI_HELPERS_URL:-https://github.com/nikolareljin/ci-helpers.git}"
HELPERS_REF="${CI_HELPERS_REF:-99ff8e3313bd53aede98d8e81fd7afaca4eb9b8b}"

if [ -f "$HELPERS_DIR/scripts/check_release_version.sh" ]; then
  printf 'ci-helpers already available at %s\n' "$HELPERS_DIR"
  exit 0
fi

if [ -d "$HELPERS_DIR" ] && [ "$(find "$HELPERS_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)" -gt 0 ]; then
  printf 'Directory exists but does not look like ci-helpers: %s\n' "$HELPERS_DIR" >&2
  exit 1
fi

mkdir -p "$(dirname "$HELPERS_DIR")"
git clone "$HELPERS_URL" "$HELPERS_DIR"
git -C "$HELPERS_DIR" checkout --detach "$HELPERS_REF"
printf 'ci-helpers ready at %s\n' "$HELPERS_DIR"
