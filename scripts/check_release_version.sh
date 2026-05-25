#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CI_HELPERS_DIR="${CI_HELPERS_DIR:-$REPO_ROOT/scripts/ci-helpers}"

if [ ! -f "$CI_HELPERS_DIR/scripts/check_release_version.sh" ]; then
  "$REPO_ROOT/scripts/bootstrap_ci_helpers.sh"
fi

exec "$CI_HELPERS_DIR/scripts/check_release_version.sh" "$@"
