#!/usr/bin/env bash
# SCRIPT: test_backup_noninteractive.sh
# DESCRIPTION: Prove --non-interactive never reaches a dialog, and that --no-encrypt leaves readable credentials.
# USAGE: bash tests/test_backup_noninteractive.sh
# EXAMPLE: bash tests/test_backup_noninteractive.sh
#
# `dialog` is replaced by a stub that records being called and exits non-zero.
# An unattended run that touches any prompt therefore fails loudly here rather
# than hanging on a machine with no terminal. adb is the same fake-device mock
# used by the photo tests.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS=0
FAILURES=0

check() {
  TESTS=$((TESTS + 1))
  if [ "$2" != "$3" ]; then
    FAILURES=$((FAILURES + 1))
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3" >&2
  fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

DEVICE="$WORK/device"
BIN="$WORK/bin"
mkdir -p "$BIN" "$DEVICE/storage/emulated/0/Download" "$DEVICE/storage/emulated/0/Documents"
printf 'name,url,username,password\nbank,https://b.example,dragana,hunter2\n' \
  >"$DEVICE/storage/emulated/0/Download/passwords.csv"
printf 'a-download\n' >"$DEVICE/storage/emulated/0/Download/file.txt"

# --- dialog stub: any call is a failure -----------------------------------
cat >"$BIN/dialog" <<MOCK
#!/usr/bin/env bash
printf 'DIALOG WAS CALLED: %s\n' "\$*" >>"$WORK/dialog_calls.txt"
exit 99
MOCK
chmod +x "$BIN/dialog"
: >"$WORK/dialog_calls.txt"

# --- adb mock --------------------------------------------------------------
cat >"$BIN/adb" <<'MOCK'
#!/usr/bin/env bash
set -uo pipefail
DEVICE="${MOCK_DEVICE:?}"
# /sdcard is a symlink to /storage/emulated/0 on a real device, and the backup
# script addresses paths the /sdcard way. Resolve it here so the fake tree does
# not have to exist under two names.
dev_to_local() {
  local p="$1"
  case "$p" in
    /sdcard/*) p="/storage/emulated/0/${p#/sdcard/}" ;;
    /sdcard) p="/storage/emulated/0" ;;
  esac
  printf '%s%s\n' "$DEVICE" "$p"
}

case "${1:-}" in
  start-server|wait-for-device|kill-server) exit 0 ;;
  pull)
    shift
    [ "${1:-}" = "-a" ] && shift
    src="$1"; dst="$2"
    l="$(dev_to_local "$src")"
    if [ -d "$l" ]; then mkdir -p "$dst" && cp -r "$l/." "$dst/" && exit 0; fi
    [ -f "$l" ] || exit 1
    mkdir -p "$(dirname "$dst")"
    cp "$l" "$dst" || exit 1
    exit 0
    ;;
  shell)
    shift
    # Real adb shell reads stdin and forwards it to the device. The mock drains
    # it for the same reason: a caller that runs adb inside a `while read` loop
    # without </dev/null loses the rest of its input, which is how sizes were
    # collected for only the first 200 of 5,399 files on a real phone.
    # Bounded: a plain `cat` blocks forever when stdin has a writer that never
    # closes, which hangs the suite instead of failing it.
    if [ ! -t 0 ]; then timeout 0.2 cat >/dev/null 2>&1 || true; fi
    cmd="$*"
    case "$cmd" in
      "test -e "*)
        p="${cmd#test -e }"; p="${p#\'}"; p="${p%\'}"
        [ -e "$(dev_to_local "$p")" ] && exit 0 || exit 1 ;;
      stat*)
        rest="${cmd#stat }"
        case "$rest" in -c\ *) rest="${rest#-c }"; rest="${rest#* }" ;; esac
        eval "set -- $rest"
        for p in "$@"; do
          l="$(dev_to_local "$p")"
          [ -f "$l" ] || continue
          printf '%s|%s\n' "$(wc -c <"$l" | tr -d ' ')" "$p"
        done
        exit 0 ;;
      "su -c id"*) exit 1 ;;                      # not rooted
      "settings list"*) printf 'a_setting=1\n' ;;
      "dumpsys wifi"*) printf 'Wi-Fi record\n' ;;
      "dumpsys connectivity"*) printf 'connectivity\n' ;;
      "dumpsys bluetooth_manager"*) printf 'bluetooth\n' ;;
      "dumpsys package"*) printf 'packages\n' ;;
      "cmd package list packages"*)
        # CRLF on purpose: some adb/device combinations return it.
        printf 'package:com.android.chrome\r\npackage:com.samsung.android.samsungpass\r\npackage:com.azure.authenticator\r\n' ;;
      "getprop"*) printf 'prop\n' ;;
      "cmd package resolve-activity"*)
        # Chrome has a launcher activity; Samsung Pass deliberately does not.
        case "$cmd" in
          *com.android.chrome*) printf 'com.android.chrome/com.google.android.apps.chrome.Main\n' ;;
          *) printf 'No activity found\n' ;;
        esac
        exit 0 ;;
      "am start"*)
        printf '%s\n' "$cmd" >>"${MOCK_WORK:-/dev/null}/am_calls.txt" 2>/dev/null
        exit 0 ;;
      monkey*)
        # Record which package was opened so the test can assert on it.
        printf '%s\n' "$cmd" >>"${MOCK_WORK:-/dev/null}/monkey_calls.txt" 2>/dev/null
        exit 0 ;;
      *) exit 0 ;;
    esac
    exit 0 ;;
esac
exit 0
MOCK
chmod +x "$BIN/adb"

export MOCK_DEVICE="$DEVICE" MOCK_WORK="$WORK"
export PATH="$BIN:$PATH"

BK="$WORK/backup"
mkdir -p "$BK"

( cd "$ROOT" && bash tools/android_backup_dialog.sh "$BK" \
    --recovery-profile --no-encrypt --non-interactive \
    --select downloads,recovery_profile \
    --credential-export /sdcard/Download/passwords.csv \
    >"$WORK/out.txt" 2>&1 )
rc=$?

# --- the central assertion -------------------------------------------------

check "no dialog was ever invoked" "" "$(cat "$WORK/dialog_calls.txt")"
check "unattended run exits 0" "0" "$rc"

# --- --no-encrypt leaves readable credentials ------------------------------

check "no encrypted archive was produced" "absent" \
  "$([ -f "$BK/recovery-profile.tar.gpg" ] && echo present || echo absent)"
check "readable profile exists" "present" \
  "$([ -d "$BK/recovery_profile" ] && echo present || echo absent)"
check "the credential export is readable" "hunter2" \
  "$(awk -F, 'NR==2{print $4}' "$BK/recovery_profile/imports/passwords.csv" 2>/dev/null)"
check "credential import is owner-only" "600" \
  "$(stat -c '%a' "$BK/recovery_profile/imports/passwords.csv" 2>/dev/null)"
check "manifest records the unencrypted profile" "1" \
  "$(grep -c 'SKIPPED recovery profile encryption' "$BK/backup_manifest.txt" 2>/dev/null)"
check "manifest records the import" "1" \
  "$(grep -c 'OK owner-exported credentials' "$BK/backup_manifest.txt" 2>/dev/null)"

# --- the selection was honoured -------------------------------------------

check "selected category ran" "present" \
  "$([ -d "$BK/shared/Download" ] && echo present || echo absent)"
check "unselected category did not run" "absent" \
  "$([ -d "$BK/shared/DCIM" ] && echo present || echo absent)"

# --- recovery apps come from config, and Samsung Pass is among them -------

# Matched on the package id: the display name also occurs inside its own hint
# text, so counting the name alone counts two lines.
check "detected managers are listed in the guidance" "1" \
  "$(grep -c 'com.samsung.android.samsungpass' "$BK/recovery_profile/recovery_actions.txt" 2>/dev/null)"
check "so is Chrome" "1" \
  "$(grep -c '(com.android.chrome)' "$BK/recovery_profile/recovery_actions.txt" 2>/dev/null)"
check "the export hint travels with it" "1" \
  "$(grep -c 'Samsung Pass > ⋮ > Settings > Export data' "$BK/recovery_profile/recovery_actions.txt" 2>/dev/null)"
check "a manager that is NOT installed is not listed" "0" \
  "$(grep -c 'Bitwarden' "$BK/recovery_profile/recovery_actions.txt" 2>/dev/null)"
check "unattended with no --open-manager opens nothing" "absent" \
  "$([ -s "$WORK/monkey_calls.txt" ] && echo present || echo absent)"

# --- --open-manager opens exactly what was named --------------------------

: >"$WORK/monkey_calls.txt"
BK3="$WORK/backup3"; mkdir -p "$BK3"
( cd "$ROOT" && bash tools/android_backup_dialog.sh "$BK3" \
    --recovery-profile --no-encrypt --non-interactive --select recovery_profile \
    --open-manager com.samsung.android.samsungpass \
    >"$WORK/out3.txt" 2>&1 )
check "--open-manager run exits 0" "0" "$?"
# Route-agnostic: which mechanism is right for a given app is asserted below,
# per route. Here the point is only that the named one, and nothing else, was
# opened at all.
check "the named manager was opened" "1" \
  "$(grep -c 'OPENED com.samsung.android.samsungpass' "$BK3/backup_manifest.txt")"
check "and nothing else was" "1" \
  "$(grep -c '^OPENED ' "$BK3/backup_manifest.txt")"

# --- an app with no launcher is opened by its configured spec -------------
#
#     Samsung Pass has no LAUNCHER activity -- it lives inside Settings -- so
#     `monkey -p` can never open it. On the first phone this ran against, that
#     produced "could not open" for an app that was never openable that way.

: >"$WORK/monkey_calls.txt"; : >"$WORK/am_calls.txt"
BK5="$WORK/backup5"; mkdir -p "$BK5"
( cd "$ROOT" && bash tools/android_backup_dialog.sh "$BK5" \
    --recovery-profile --no-encrypt --non-interactive --select recovery_profile \
    --open-manager com.samsung.android.samsungpass \
    >"$WORK/out5.txt" 2>&1 )
check "launch-spec app opens via am start" "1" \
  "$(grep -c 'am start -n com.android.settings' "$WORK/am_calls.txt")"
check "and not via monkey" "0" "$(wc -l <"$WORK/monkey_calls.txt" | tr -d ' ')"
check "manifest records the route" "1" \
  "$(grep -c 'OPENED com.samsung.android.samsungpass via' "$BK5/backup_manifest.txt")"
check "no false failure is reported" "0" \
  "$(grep -c 'Could not open' "$WORK/out5.txt")"

# --- an app with a launcher still goes through monkey ---------------------

: >"$WORK/monkey_calls.txt"; : >"$WORK/am_calls.txt"
BK6="$WORK/backup6"; mkdir -p "$BK6"
( cd "$ROOT" && bash tools/android_backup_dialog.sh "$BK6" \
    --recovery-profile --no-encrypt --non-interactive --select recovery_profile \
    --open-manager com.android.chrome \
    >"$WORK/out6.txt" 2>&1 )
check "launcher app opens via monkey" "1" \
  "$(grep -c 'monkey -p com.android.chrome' "$WORK/monkey_calls.txt")"
check "and not via am start" "0" "$(wc -l <"$WORK/am_calls.txt" | tr -d ' ')"

# --- naming something not installed warns, and does not open it -----------

: >"$WORK/monkey_calls.txt"
BK4="$WORK/backup4"; mkdir -p "$BK4"
( cd "$ROOT" && bash tools/android_backup_dialog.sh "$BK4" \
    --recovery-profile --no-encrypt --non-interactive --select recovery_profile \
    --open-manager com.bitwarden \
    >"$WORK/out4.txt" 2>&1 )
check "a manager that is not installed opens nothing" "0" \
  "$(wc -l <"$WORK/monkey_calls.txt" | tr -d ' ')"
check "and says so" "1" \
  "$(grep -c 'com.bitwarden is not installed' "$WORK/out4.txt")"

# --- a missing --select is refused rather than hanging ---------------------

BK2="$WORK/backup2"; mkdir -p "$BK2"
( cd "$ROOT" && bash tools/android_backup_dialog.sh "$BK2" --non-interactive >"$WORK/out2.txt" 2>&1 )
check "--non-interactive without --select is refused" "2" "$?"
check "and says why" "1" "$(grep -c 'requires --select' "$WORK/out2.txt")"

# ---------------------------------------------------------------------------

if [ "$FAILURES" -eq 0 ]; then
  printf 'backup_noninteractive: %d checks passed\n' "$TESTS"
else
  printf 'backup_noninteractive: %d of %d checks FAILED\n' "$FAILURES" "$TESTS" >&2
  printf -- '--- run output ---\n' >&2
  sed 's/\x1b\[[0-9;]*m//g' "$WORK/out.txt" | tail -25 >&2
  exit 1
fi
