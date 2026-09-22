#!/usr/bin/env bash

ANDROID_RESCUE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Git Bash on Windows runs on the MSYS2 runtime, which rewrites arguments that
# look like POSIX paths into Windows ones before a native .exe sees them. adb
# is a native .exe, so `adb shell ls /sdcard` reaches the phone as
# `ls C:/Program Files/Git/sdcard`. The phone answers "no such file" and it
# reads as a device fault rather than a tooling one.
#
# Excluded by prefix, not disabled outright. Blanket MSYS_NO_PATHCONV would
# also stop the conversion of the local destination in
# `adb pull /sdcard/DCIM/x.jpg /c/Users/me/backup`, which native adb does need
# as a Windows path. Only the device side must survive untouched.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    ANDROID_RESCUE_DEVICE_PATHS='/sdcard;/storage;/data;/system;/mnt/sdcard'
    if [ -n "${MSYS2_ARG_CONV_EXCL:-}" ]; then
      export MSYS2_ARG_CONV_EXCL="$MSYS2_ARG_CONV_EXCL;$ANDROID_RESCUE_DEVICE_PATHS"
    else
      export MSYS2_ARG_CONV_EXCL="$ANDROID_RESCUE_DEVICE_PATHS"
    fi
    ;;
esac
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$ANDROID_RESCUE_ROOT/scripts/script-helpers}"
# Exported so a script that sources this file can tell whether the real helper
# library loaded or the fallback definitions below are in use.
export ANDROID_RESCUE_HAS_HELPERS=0

if [ -f "$SCRIPT_HELPERS_DIR/helpers.sh" ]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_HELPERS_DIR/helpers.sh"
  shlib_import logging dialog os
  export ANDROID_RESCUE_HAS_HELPERS=1
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

# --- device reachability ---------------------------------------------------
#
# `require_tool adb` only proves the binary exists. It says nothing about
# whether a phone is attached or whether it has authorised this computer, and
# the difference matters: a phone holding 5,399 photos that has not authorised
# the computer reported "No photos or videos were found on the device" and
# exited 0. "Could not ask" and "asked, and there are none" must never produce
# the same answer.

# Parse `adb devices` output into one word: device, unauthorized, offline,
# multiple, or none. Pure -- takes the text, touches nothing.
adb_device_state() {
  local text="$1" line serial state ready=0 seen=""
  while IFS= read -r line; do
    line="${line%$'\r'}"
    case "$line" in
      'List of devices attached'*|'') continue ;;
      'adb:'*|'error:'*|'*'*) continue ;;
    esac
    # "<serial><TAB><state>"; anything else is not a device row.
    serial="${line%%[	 ]*}"
    state="${line##*[	 ]}"
    # An if, not `A && B || C`: that runs C when A succeeds and B fails, which
    # is not what it reads like.
    if [ -z "$serial" ] || [ "$serial" = "$line" ]; then continue; fi
    case "$state" in
      device) ready=$((ready + 1)); seen="device" ;;
      unauthorized|offline|recovery|sideload|bootloader) [ -n "$seen" ] || seen="$state" ;;
    esac
  done <<EOT
$text
EOT
  if [ "$ready" -gt 1 ]; then printf 'multiple\n'; return 0; fi
  printf '%s\n' "${seen:-none}"
}

# Refuse to continue unless a phone is attached and has authorised this
# computer. Waits briefly, because the authorisation dialog is often sitting
# behind a lock screen and the owner may be about to accept it.
require_device() {
  local timeout="${ADB_WAIT_TIMEOUT:-25}" waited=0 state told=0
  while :; do
    state="$(adb_device_state "$(adb devices 2>/dev/null)")"
    case "$state" in
      device) return 0 ;;
      multiple)
        print_error "More than one device is attached. Disconnect the others, or set ANDROID_SERIAL."
        return 1 ;;
    esac

    if [ "$told" -eq 0 ]; then
      told=1
      case "$state" in
        unauthorized)
          print_warning "The phone is connected but has NOT authorised this computer."
          print_warning "Unlock it and accept 'Allow USB debugging?' -- tick 'Always allow from this computer'."
          print_warning "The dialog often sits behind the lock screen." ;;
        offline)
          print_warning "The phone is attached but offline. Unplug and replug the cable." ;;
        none)
          print_warning "No device is attached. Connect the phone by USB and enable USB debugging." ;;
        *)
          print_warning "The phone is in '$state' mode, not ready for a backup." ;;
      esac
      print_info "Waiting up to ${timeout}s..."
    fi

    [ "$waited" -lt "$timeout" ] || break
    sleep 2
    waited=$((waited + 2))
  done

  print_error "No usable device after ${timeout}s (state: $state). Nothing was read from the phone."
  print_error "Run 'adb devices' to check. Any backup written now would be empty, so none was attempted."
  return 1
}
