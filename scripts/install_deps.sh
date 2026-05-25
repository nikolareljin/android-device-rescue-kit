#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$REPO_ROOT/scripts/script-helpers}"

if [ ! -f "$SCRIPT_HELPERS_DIR/helpers.sh" ]; then
  "$REPO_ROOT/scripts/bootstrap_script_helpers.sh"
fi

# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import deps os logging

case "$(get_os)" in
  linux)
    install_dependencies android-tools-adb dialog ripgrep unzip gzip coreutils
    ;;
  mac)
    install_dependencies android-platform-tools dialog ripgrep unzip gzip coreutils
    ;;
  *)
    print_error "Unsupported OS. Install adb, dialog, ripgrep, unzip, and gzip manually."
    exit 1
    ;;
esac

print_success "Dependencies installed."
