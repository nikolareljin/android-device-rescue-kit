#!/usr/bin/env bash

ANDROID_RESCUE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$ANDROID_RESCUE_ROOT/scripts/script-helpers}"
ANDROID_RESCUE_HAS_HELPERS=0

if [ -f "$SCRIPT_HELPERS_DIR/helpers.sh" ]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_HELPERS_DIR/helpers.sh"
  shlib_import logging dialog os
  ANDROID_RESCUE_HAS_HELPERS=1
else
  print_info() { printf '[Info]: %s\n' "$*"; }
  print_warning() { printf '[Warning]: %s\n' "$*" >&2; }
  print_error() { printf '[Error]: %s\n' "$*" >&2; }
  print_success() { printf 'Success: %s\n' "$*"; }
  dialog_init() {
    local cols lines
    cols=$(tput cols 2>/dev/null || echo 120)
    lines=$(tput lines 2>/dev/null || echo 40)
    DIALOG_WIDTH=$((cols * 70 / 100))
    DIALOG_HEIGHT=$((lines * 70 / 100))
    [ "$DIALOG_WIDTH" -lt 60 ] && DIALOG_WIDTH=60
    [ "$DIALOG_HEIGHT" -lt 20 ] && DIALOG_HEIGHT=20
    export DIALOG_WIDTH DIALOG_HEIGHT
  }
  check_if_dialog_installed() {
    if ! command -v dialog >/dev/null 2>&1; then
      print_error "dialog is required. Run scripts/install_deps.sh or install dialog manually."
      return 1
    fi
    dialog_init
  }
fi

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    print_error "$1 is required. Run scripts/install_deps.sh or install it manually."
    return 1
  fi
}
