#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPERS_DIR="${CI_HELPERS_DIR:-$REPO_ROOT/scripts/ci-helpers}"
HELPERS_URL="${CI_HELPERS_URL:-https://github.com/nikolareljin/ci-helpers.git}"
# `production` is the floating release ref, matching the @production the
# workflows use. It exists as both a tag and a branch, and git resolves the tag
# first; they point at the same commit. Pinning a SHA here instead silently
# strands the repo on an old release — this file sat on ci-helpers 0.25.0 while
# production had moved to 0.29.0.
HELPERS_REF="${CI_HELPERS_REF:-production}"

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
