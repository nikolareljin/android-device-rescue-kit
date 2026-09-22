#!/usr/bin/env bash
# SCRIPT: test_real_device.sh
# DESCRIPTION: Read-only checks against a real handset named in .env.
# USAGE: bash tests/test_real_device.sh
#
# Skipped unless .env opts in:
#
#   cp env.example .env
#   ANDROID_RESCUE_TEST_DEVICE=1
#   ANDROID_RESCUE_TEST_SERIAL=<what `adb devices` prints>
#
# Every other suite runs against a mock, which is why they pass with no phone
# and prove nothing about a real one. This one talks to the handset, and is
# deliberately read-only: it probes, it reads state, it copies nothing and
# writes nothing. Backing up or restoring is not something a test suite should
# do to someone's phone on its own initiative.
#
# The serial from .env becomes ANDROID_SERIAL, so every adb call underneath
# targets that handset. With more than one phone attached, adb otherwise
# refuses outright or, worse, picks a different one.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/test_env.sh
source "$ROOT/tests/lib/test_env.sh"

checks=0
failures=0
pass() { checks=$((checks + 1)); }
note() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

if ! test_env_wants_device; then
  printf 'real_device: skipped, ANDROID_RESCUE_TEST_DEVICE is not 1 (see env.example)\n'
  exit 0
fi

if ! command -v adb >/dev/null 2>&1; then
  note "ANDROID_RESCUE_TEST_DEVICE=1 but adb is not installed"
  printf 'real_device: %s of %s checks FAILED\n' "$failures" "$((checks + failures))" >&2
  exit 1
fi

if [ -z "${ANDROID_RESCUE_TEST_SERIAL:-}" ]; then
  note "ANDROID_RESCUE_TEST_DEVICE=1 but ANDROID_RESCUE_TEST_SERIAL is empty."
  printf '  Set it to the serial adb devices prints, so a run cannot reach\n' >&2
  printf '  whichever handset happens to be plugged in.\n' >&2
  printf 'real_device: %s of %s checks FAILED\n' "$failures" "$((checks + failures))" >&2
  exit 1
fi

test_env_target_device
printf 'real_device: targeting %s\n' "$ANDROID_SERIAL"

attached="$(adb devices 2>/dev/null | awk 'NR > 1 && NF >= 2 { print $1 }')"
if ! grep -Fxq "$ANDROID_SERIAL" <<<"$attached"; then
  note "the configured handset is not attached."
  printf '  Configured: %s\n' "$ANDROID_SERIAL" >&2
  printf '  Attached:   %s\n' "$(printf '%s' "$attached" | tr '\n' ' ')" >&2
  printf 'real_device: %s of %s checks FAILED\n' "$failures" "$((checks + failures))" >&2
  exit 1
fi
pass

# The state adb reports for that serial, whatever else is plugged in.
state="$(adb devices 2>/dev/null | awk -v s="$ANDROID_SERIAL" '$1 == s { print $2 }')"
printf 'real_device: adb reports state "%s"\n' "$state"

# probe is the contract: 0 when the phone is usable, 2 when it is not, and it
# must never hang or change a setting.
set +e
probe_out="$(cd "$ROOT" && timeout 60 ./adrescue probe 2>&1)"
probe_rc=$?
set -e

case "$state:$probe_rc" in
  device:0) pass ;;
  unauthorized:2|offline:2|:2) pass ;;
  *:124)
    note "probe did not return within 60s; it is supposed to answer immediately"
    ;;
  *)
    note "probe exit $probe_rc does not match adb state '$state'"
    printf '%s\n' "$probe_out" | sed 's/^/    /' >&2
    ;;
esac

# Whatever it decided, it has to say which state it found rather than exiting
# silently: this output is what someone acts on.
if printf '%s' "$probe_out" | grep -qiE 'authoris|authoriz|not detected|unlock'; then
  pass
else
  note "probe said nothing actionable about the phone's state"
  printf '%s\n' "$probe_out" | sed 's/^/    /' >&2
fi

# A second run must agree with the first. probe is read-only, so a differing
# answer means it changed something or is racing.
set +e
probe_again_rc=$(cd "$ROOT" && timeout 60 ./adrescue probe >/dev/null 2>&1; echo $?)
set -e
if [ "$probe_again_rc" = "$probe_rc" ]; then
  pass
else
  note "probe is not repeatable: $probe_rc then $probe_again_rc"
fi

# config must resolve without touching the device at all.
if (cd "$ROOT" && ./adrescue config >/dev/null 2>&1); then
  pass
else
  note "adrescue config failed with a device attached"
fi

if [ "$failures" -eq 0 ]; then
  printf 'real_device: %s checks passed against %s\n' "$checks" "$ANDROID_SERIAL"
else
  printf 'real_device: %s of %s checks FAILED\n' "$failures" "$((checks + failures))" >&2
  exit 1
fi
