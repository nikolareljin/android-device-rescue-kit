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
    # Required: without any of these a command fails outright.
    missing=""
    for tool in adb rg gzip gpg tar; do
      command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
    done
    if [ -n "$missing" ]; then
      print_error "Not on PATH:$missing"
      print_error "Install them with winget, or re-run install.ps1, then open a new shell."
      exit 1
    fi

    # Optional, and each degrades something specific rather than failing. Said
    # plainly here, because "installed everything" that quietly leaves two gaps
    # is how a smaller report and a different set of prompts get blamed on the
    # phone.
    if ! command -v dialog >/dev/null 2>&1; then
      print_info "dialog: not available. Git for Windows ships no package manager to install it with,"
      print_info "  so the prompts are numbered questions instead of full-screen menus. Same questions."
      print_info "  Force either mode anywhere with: adrescue --ui dialog|text"
    fi
    if ! command -v unzip >/dev/null 2>&1; then
      if tar --version 2>/dev/null | head -1 | grep -qi 'bsdtar\|libarchive'; then
        print_info "unzip: not present; bsdtar will read the bugreport zip instead."
      else
        print_warning "unzip: not present, and no bsdtar either. 'adrescue log' will skip bugreport"
        print_warning "  extraction, which is where last_kmsg, tombstones and recovery logs live."
      fi
    fi
    ;;
  *)
    print_error "Unsupported OS. Install adb, dialog, ripgrep, unzip, and gzip manually."
    exit 1
    ;;
esac

print_success "Dependencies installed."
