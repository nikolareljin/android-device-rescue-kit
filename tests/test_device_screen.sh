#!/usr/bin/env bash
# SCRIPT: test_device_screen.sh
# DESCRIPTION: Unit tests for the pure screen-state parsers in tools/lib/device_screen.sh.
# USAGE: bash tests/test_device_screen.sh
# EXAMPLE: bash tests/test_device_screen.sh
#
# The fixtures are real `dumpsys window policy` output from a Galaxy S22 on
# Android 16, not invented text. The device-facing half is covered separately in
# test_backup_noninteractive.sh against the mock adb.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tools/lib/device_screen.sh
source "$ROOT/tools/lib/device_screen.sh"

TESTS=0
FAILURES=0
check() {
  TESTS=$((TESTS + 1))
  if [ "$2" != "$3" ]; then
    FAILURES=$((FAILURES + 1))
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3" >&2
  fi
}
yn() { if "$@"; then printf 'yes'; else printf 'no'; fi; }

# Captured verbatim from the device while it sat on a swipe lockscreen.
LOCKED_SWIPE='    KeyguardServiceDelegate
      showing=true
      inputRestricted=false
      occluded=false
      secure=false
      dreaming=true
      systemIsReady=true
      deviceHasKeyguard=true
      enabled=true
      offReason=OFF_BECAUSE_OF_TIMEOUT
      currentUser=0
      bootCompleted=true
      screenState=SCREEN_STATE_ON'

UNLOCKED='    KeyguardServiceDelegate
      showing=false
      inputRestricted=false
      occluded=false
      secure=false
      dreaming=false
      systemIsReady=true'

LOCKED_SECURE='    KeyguardServiceDelegate
      showing=true
      inputRestricted=true
      occluded=false
      secure=true
      dreaming=false'

# --- screen_parse_locked ---------------------------------------------------

check "locked: swipe lockscreen showing" "yes" "$(yn screen_parse_locked "$LOCKED_SWIPE")"
check "locked: keyguard not showing" "no" "$(yn screen_parse_locked "$UNLOCKED")"
check "locked: secured keyguard showing" "yes" "$(yn screen_parse_locked "$LOCKED_SECURE")"

# Absent or unreadable input must not be read as "unlocked". Claiming the phone
# is ready when dumpsys said nothing would send someone to a dark screen.
check "locked: empty input is treated as locked" "yes" "$(yn screen_parse_locked "")"
check "locked: garbage input is treated as locked" "yes" "$(yn screen_parse_locked "command not found")"

# `deviceLocked=0` is reported on this phone WITH a swipe lockscreen up, so a
# parser keying on it would call this unlocked. Guard against that regression.
check "locked: does not key on deviceLocked" "yes" \
  "$(yn screen_parse_locked 'KeyguardServiceDelegate
      showing=true
      secure=false
      deviceLocked=0')"

# The mirror case, and the one that actually pins the behaviour: the two fields
# disagreeing the other way. Keyed on showing= this is unlocked; a parser keyed
# on deviceLocked= would say locked and skip the credential step for nothing.
check "locked: showing=false wins over deviceLocked=1" "no" \
  "$(yn screen_parse_locked 'KeyguardServiceDelegate
      showing=false
      secure=true
      deviceLocked=1')"

# --- screen_parse_secure ---------------------------------------------------

check "secure: swipe-only is not secure" "no" "$(yn screen_parse_secure "$LOCKED_SWIPE")"
check "secure: PIN-protected is secure" "yes" "$(yn screen_parse_secure "$LOCKED_SECURE")"
check "secure: empty input is not claimed secure" "no" "$(yn screen_parse_secure "")"

# --- screen_unlock_hint ----------------------------------------------------
# The instruction differs by lock type; telling someone to enter a PIN they do
# not have is as unhelpful as telling them to swipe past one they do.

check "hint: swipe-only mentions swiping" "1" \
  "$(screen_unlock_hint "$LOCKED_SWIPE" | grep -ci 'swipe')"
check "hint: secured mentions PIN" "1" \
  "$(screen_unlock_hint "$LOCKED_SECURE" | grep -ciE 'pin|password|pattern')"

# --- screen_parse_stayon ---------------------------------------------------
# `settings get` prints "null" when a key has never been written; that is not a
# number and must not be fed back as one on restore.

check "stayon: plain value" "0" "$(screen_parse_stayon '0')"
check "stayon: value with CR" "2" "$(screen_parse_stayon "$(printf '2\r')")"
check "stayon: null becomes 0" "0" "$(screen_parse_stayon 'null')"
check "stayon: empty becomes 0" "0" "$(screen_parse_stayon '')"
check "stayon: junk becomes 0" "0" "$(screen_parse_stayon 'Exception: whatever')"
check "stayon: full bitmask preserved" "15" "$(screen_parse_stayon '15')"

# ---------------------------------------------------------------------------

if [ "$FAILURES" -eq 0 ]; then
  printf 'device_screen: %d checks passed\n' "$TESTS"
else
  printf 'device_screen: %d of %d checks FAILED\n' "$FAILURES" "$TESTS" >&2
  exit 1
fi
