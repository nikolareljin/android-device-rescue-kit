#!/usr/bin/env bash
# SCRIPT: android_device_probe.sh
# DESCRIPTION: Report whether a connected phone can be backed up over ADB.
# USAGE: tools/android_device_probe.sh
# EXAMPLE: adrescue probe
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_tool adb || exit 1
state="$(adb_device_state "$(adb devices 2>/dev/null)")"

case "$state" in
  device)
    print_success "Phone is connected and has authorised this computer."
    print_info "Start the priority backup now: ${ANDROID_RESCUE_SELF:-./adrescue} photos"
    ;;
  unauthorized)
    print_warning "Phone is connected, but this computer is not authorised."
    print_warning "USB debugging cannot be enabled or authorised from this computer."
    print_info "Unlock the phone and accept 'Allow USB debugging?' on the phone."
    exit 2
    ;;
  offline)
    print_warning "Phone is attached but offline. Reconnect a known-good data cable."
    exit 2
    ;;
  multiple)
    print_warning "More than one authorised device is connected. Disconnect the others, or set ANDROID_SERIAL."
    exit 2
    ;;
  none)
    print_warning "No ADB-capable phone was detected."
    print_info "If USB debugging is off or the screen is unusable, follow docs/cracked-screen.html."
    exit 2
    ;;
  *)
    print_warning "Phone is in '$state' mode, not ready for an ADB backup."
    exit 2
    ;;
esac
