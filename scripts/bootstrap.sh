#!/usr/bin/env bash
# SCRIPT: bootstrap.sh
# DESCRIPTION: Install host dependencies, helper repositories and git hooks.
# USAGE: adrescue bootstrap
#
# This was the body of ./update. It kept that name because install.sh calls it
# and because every android-rescue-update launcher already points at it. The
# documented name is now `adrescue bootstrap`; `adrescue update` moves the
# toolkit to a newer release, which is a different job.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

run_git_submodule_update() {
  if [ -f .gitmodules ]; then
    printf 'Updating git submodules...\n'
    git submodule sync --recursive
    git submodule update --init --recursive
  else
    printf 'No git submodules configured.\n'
  fi
}

run_git_submodule_update

"$ROOT/scripts/bootstrap_script_helpers.sh"
"$ROOT/scripts/bootstrap_ci_helpers.sh"

# Hooks before dependencies, deliberately. install_deps.sh exits non-zero on
# an unsupported OS or a failed package install, and under `set -e` that used
# to abort before the hooks were ever wired -- silently leaving the gitleaks
# pre-commit guard off on exactly the first run a contributor makes.
if [ -f "$ROOT/scripts/script-helpers/scripts/setup-hooks.sh" ]; then
  bash "$ROOT/scripts/script-helpers/scripts/setup-hooks.sh"
fi

"$ROOT/scripts/install_deps.sh"

printf 'Dependencies are ready. To move to a newer release: adrescue update\n'
