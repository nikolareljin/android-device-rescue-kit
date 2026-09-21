#!/usr/bin/env bash
# SCRIPT: device_screen.sh
# DESCRIPTION: Hold the phone's screen awake for the steps that need a person, and put it back.
# USAGE: source tools/lib/device_screen.sh
# ENVIRONMENT:
#   SCREEN_UNLOCK_TIMEOUT   Seconds to wait for an unlock when unattended. Default 120.
#   SCREEN_CONTROL          0 disables every write to the device. Default 1.
#
# Only the steps that need someone at the handset are covered. Copying files
# works perfectly well with the screen off, and holding a failing phone's
# display on for a 45-minute transfer earns nothing but heat.
#
# The parsing is separated from the device calls so it can be tested without
# hardware, the same split tools/lib/photo_index.sh uses.

SCREEN_UNLOCK_TIMEOUT="${SCREEN_UNLOCK_TIMEOUT:-120}"
SCREEN_CONTROL="${SCREEN_CONTROL:-1}"

# The USB bit of stay_on_while_plugged_in (BatteryManager: AC=1, USB=2,
# WIRELESS=4, DOCK=8).
#
# Deliberately not `svc power stayon true`, which writes the whole mask -- 15 on
# an Android 16 build that exposes DOCK -- and would quietly enable stay-awake
# for wireless and dock charging nobody asked about. 2 matches the mPlugType of
# a USB-attached phone and stops applying the moment the cable is pulled.
SCREEN_STAYON_USB=2

# Where the original value is recorded. A file rather than a variable so the
# value survives a crash: a later run can still put the phone back.
SCREEN_STATE_FILE="${SCREEN_STATE_FILE:-}"

# --- pure parsers ----------------------------------------------------------

# Is the keyguard up? Takes `dumpsys window policy` text.
#
# Keyed on `showing=`, NOT on `deviceLocked=`. This phone reports
# `deviceLocked=0` while a swipe lockscreen is still covering the display, so a
# parser reading that field calls a locked phone unlocked and sends someone to
# a screen they cannot act on.
#
# Unreadable input counts as locked. "dumpsys said nothing" and "the phone is
# ready" must not produce the same answer.
screen_parse_locked() {
  local text="$1"
  case "$text" in
    *showing=true*) return 0 ;;
    *showing=false*) return 1 ;;
    *) return 0 ;;
  esac
}

# Does unlocking need a credential, or just a swipe? Takes the same text.
# Unknown input is reported as not-secure, because the caller only uses this to
# choose the wording of an instruction.
screen_parse_secure() {
  local text="$1"
  case "$text" in
    *secure=true*) return 0 ;;
    *) return 1 ;;
  esac
}

# The instruction to put in front of the user, which differs by lock type.
screen_unlock_hint() {
  if screen_parse_secure "$1"; then
    printf 'Unlock the phone with its PIN, pattern or password.\n'
  else
    printf 'Swipe up on the phone to dismiss the lock screen.\n'
  fi
}

# Normalise what `settings get` printed into an integer.
#
# An unset key prints the literal "null", and a failed call can print an
# exception. Feeding either back on restore would write junk into a persistent
# global setting, so anything that is not a plain number becomes 0 -- the
# Android default, and the value this device actually had.
screen_parse_stayon() {
  local v="${1:-}"
  v="${v%$'\r'}"
  v="$(printf '%s' "$v" | tr -d '[:space:]')"
  case "$v" in
    ''|*[!0-9]*) printf '0\n' ;;
    *) printf '%s\n' "$v" ;;
  esac
}

# --- device calls ----------------------------------------------------------

screen_keyguard_dump() {
  adb shell "dumpsys window policy" </dev/null 2>/dev/null | tr -d '\r' | grep -A8 KeyguardServiceDelegate
}

screen_is_locked() { screen_parse_locked "$(screen_keyguard_dump)"; }

# Wake without unlocking and without toggling.
#
# `cmd power wakeup` goes straight to PowerManager.wakeUp() and is idempotent.
# KEYCODE_WAKEUP is the fallback for a build without it. KEYCODE_POWER is never
# used: it toggles, so on an already-awake screen it turns the display off.
screen_wake() {
  [ "$SCREEN_CONTROL" -eq 1 ] || return 0
  adb shell cmd power wakeup </dev/null >/dev/null 2>&1 ||
    adb shell input keyevent KEYCODE_WAKEUP </dev/null >/dev/null 2>&1 || true
}

# Record the current setting and hold the screen on. Safe to call twice.
screen_hold_begin() {
  [ "$SCREEN_CONTROL" -eq 1 ] || return 0
  [ -n "$SCREEN_STATE_FILE" ] || return 0
  if [ -s "$SCREEN_STATE_FILE" ]; then
    screen_wake
    return 0
  fi
  local original
  original="$(screen_parse_stayon "$(adb shell settings get global stay_on_while_plugged_in </dev/null 2>/dev/null)")"
  printf '%s\n' "$original" >"$SCREEN_STATE_FILE"
  adb shell settings put global stay_on_while_plugged_in "$SCREEN_STAYON_USB" </dev/null >/dev/null 2>&1 || true
  screen_wake
}

# Put the setting back to what was recorded. Idempotent: it runs on the normal
# path and again from the trap, and a second call must do nothing.
#
# Restores the RECORDED value, never a hardcoded 0 -- a phone that legitimately
# had stay-awake enabled must keep it.
screen_hold_end() {
  [ -n "$SCREEN_STATE_FILE" ] || return 0
  [ -s "$SCREEN_STATE_FILE" ] || return 0
  local original
  original="$(screen_parse_stayon "$(cat "$SCREEN_STATE_FILE" 2>/dev/null)")"
  adb shell settings put global stay_on_while_plugged_in "$original" </dev/null >/dev/null 2>&1 || true
  rm -f "$SCREEN_STATE_FILE"
}

# Wake the phone and get it unlocked, or report that it could not be.
#
# Returns 0 when the phone is usable, 1 when the caller should skip whatever
# needed a person. Never unlocks anything itself: `wm dismiss-keyguard` exists
# and is deliberately not used.
screen_wait_unlock() {
  screen_wake
  screen_is_locked || return 0

  local dump hint
  dump="$(screen_keyguard_dump)"
  hint="$(screen_unlock_hint "$dump")"

  if [ "${INTERACTIVE:-1}" -eq 1 ]; then
    while :; do
      if ui_yesno "Unlock The Phone" "The phone is locked, and the password export cannot be reached through a lock screen.\n\n$hint\n\nChoose Yes once it is unlocked.\nChoose No to skip the credential step and continue with the rest of the backup." yes; then
        screen_wake
        screen_is_locked || return 0
        hint="$(screen_unlock_hint "$(screen_keyguard_dump)")"
        continue
      fi
      return 1
    done
  fi

  # Unattended: somebody may still be standing there, so poll rather than give
  # up at once, but never stall a scripted run indefinitely.
  local waited=0
  while [ "$waited" -lt "$SCREEN_UNLOCK_TIMEOUT" ]; do
    sleep 5
    waited=$((waited + 5))
    screen_wake
    screen_is_locked || return 0
  done
  return 1
}
