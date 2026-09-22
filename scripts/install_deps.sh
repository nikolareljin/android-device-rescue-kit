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
    install_dependencies android-tools-adb dialog ripgrep unzip gzip coreutils gnupg
    ;;
  mac)
    install_dependencies android-platform-tools dialog ripgrep unzip gzip coreutils gnupg
    ;;
  windows)
    # Git Bash. The packages come from winget in install.ps1, and the trimmed
    # MSYS2 userland Git for Windows ships has no package manager to install
    # anything with, so there is nothing to do but report what is actually
    # here. `dialog` is expected to be missing: it gates `data` and `restore`,
    # which is stated rather than discovered at the moment someone needs them.
    missing=""
    for tool in adb rg unzip gzip gpg; do
      command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
    done
    if [ -n "$missing" ]; then
      print_error "Not on PATH:$missing"
      print_error "Install them with winget, or re-run install.ps1, then open a new shell."
      exit 1
    fi
    command -v dialog >/dev/null 2>&1 \
      || print_info "dialog is not available under Git Bash. Every command still runs; the prompts are plain text instead of a curses menu."
    ;;
  *)
    print_error "Unsupported OS. Install adb, dialog, ripgrep, unzip, and gzip manually."
    exit 1
    ;;
esac

print_success "Dependencies installed."
