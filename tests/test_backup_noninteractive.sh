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
      "cmd package list packages"*) printf 'package:com.android.chrome\r\npackage:com.bitwarden\r\n' ;;
      "getprop"*) printf 'prop\n' ;;
      monkey*) exit 0 ;;
      *) exit 0 ;;
    esac
    exit 0 ;;
esac
exit 0
MOCK
chmod +x "$BIN/adb"

export MOCK_DEVICE="$DEVICE"
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
