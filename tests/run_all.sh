#!/usr/bin/env bash
# SCRIPT: run_all.sh
# DESCRIPTION: Run every test suite in tests/.
# USAGE: bash tests/run_all.sh
# EXAMPLE: bash tests/run_all.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

failed=0
for suite in tests/test_*.sh; do
  printf '\n--- %s ---\n' "$suite"
  bash "$suite" || failed=1
done

if [ "$failed" -ne 0 ]; then
  printf '\nSome suites FAILED.\n' >&2
  exit 1
fi
printf '\nAll suites passed.\n'
