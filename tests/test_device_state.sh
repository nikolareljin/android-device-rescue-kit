#!/usr/bin/env bash
# SCRIPT: test_device_state.sh
# DESCRIPTION: Unit tests for the device-reachability parser in tools/lib/common.sh.
# USAGE: bash tests/test_device_state.sh
# EXAMPLE: bash tests/test_device_state.sh
#
# The fixtures are real `adb devices` output, including the unauthorized case
# captured from a handset that had dropped its authorisation mid-session.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/test_env.sh
source "$ROOT/tests/lib/test_env.sh"
# shellcheck source=tools/lib/common.sh
source "$ROOT/tools/lib/common.sh"

TESTS=0
FAILURES=0
check() {
  TESTS=$((TESTS + 1))
  if [ "$2" != "$3" ]; then
    FAILURES=$((FAILURES + 1))
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3" >&2
  fi
}

READY="List of devices attached
${TEST_SERIAL}	device
"
# Captured verbatim while the phone had dropped its authorisation.
UNAUTH="List of devices attached
${TEST_SERIAL}	unauthorized
"
OFFLINE="List of devices attached
${TEST_SERIAL}	offline
"
NONE='List of devices attached
'
TWO="List of devices attached
${TEST_SERIAL}	device
EMULATOR30	device
"

check "ready device"        "device"       "$(adb_device_state "$READY")"
check "unauthorized"        "unauthorized" "$(adb_device_state "$UNAUTH")"
check "offline"             "offline"      "$(adb_device_state "$OFFLINE")"
check "nothing attached"    "none"         "$(adb_device_state "$NONE")"
check "empty input"         "none"         "$(adb_device_state "")"

# A second device must not be mistaken for a problem, nor silently picked.
check "two ready devices"   "multiple"     "$(adb_device_state "$TWO")"

# The header line must never be read as a device.
check "header alone is not a device" "none" "$(adb_device_state 'List of devices attached')"

# adb prints its complaints on stdout in some builds; they must not parse as a
# state, or "unreadable" and "ready" collapse into the same answer.
# The single quotes are the point: this is literal adb output, not a variable.
# shellcheck disable=SC2016
check "an adb error is not a ready device" "none" \
  "$(adb_device_state 'adb: device unauthorized.
This adb server'"'"'s $ADB_VENDOR_KEYS is not set')"

if [ "$FAILURES" -eq 0 ]; then
  printf 'device_state: %d checks passed\n' "$TESTS"
else
  printf 'device_state: %d of %d checks FAILED\n' "$FAILURES" "$TESTS" >&2
  exit 1
fi
