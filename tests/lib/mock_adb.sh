#!/usr/bin/env bash
# SCRIPT: tests/lib/mock_adb.sh
# DESCRIPTION: A fake adb backed by a directory tree. Install it as $BIN/adb.
# USAGE: install -m 755 tests/lib/mock_adb.sh "$BIN/adb"
#
# MOCK_DEVICE points at the tree standing in for the phone's storage, MOCK_WORK
# at a scratch directory it records into. It lives here rather than inside one
# suite because two copies of a mock drift, and the one that drifts is whichever
# suite nobody is looking at.
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
  devices)
    # require_device reads this. MOCK_DEVICE_STATE lets a test present an
    # unauthorised or absent phone.
    printf 'List of devices attached\n'
    st="$(cat "${MOCK_WORK:-/nonexistent}/device_state" 2>/dev/null || echo device)"
    [ "$st" = "none" ] || printf 'MOCKSERIAL\t%s\n' "$st"
    exit 0 ;;
  start-server|wait-for-device|kill-server) exit 0 ;;
  push)
      # Restore writes with push: the same translation as pull, the other way
      # round. A trailing "/." on the source means "the contents of", which is
      # how android_restore_dialog.sh addresses a directory.
      shift
      [ "${1:-}" = "-a" ] && shift
      src="$1"; dst="$2"
      l="$(dev_to_local "${dst%/}")"
      case "$src" in
        */.)
          mkdir -p "$l" || exit 1
          cp -r "${src%/.}/." "$l/" || exit 1 ;;
        *)
          if [ -d "$src" ]; then
            mkdir -p "$l" && cp -r "$src/." "$l/" || exit 1
          else
            [ -f "$src" ] || exit 1
            mkdir -p "$(dirname "$l")" && cp "$src" "$l" || exit 1
          fi ;;
      esac
      exit 0
      ;;
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
      "mkdir -p "*)
        p="${cmd#mkdir -p }"; p="${p#\'}"; p="${p%\'}"
        mkdir -p "$(dev_to_local "$p")" || exit 1
        exit 0 ;;
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
      "settings get global stay_on_while_plugged_in"*)
        cat "${MOCK_WORK}/stayon" 2>/dev/null || printf '0\n'
        exit 0 ;;
      "settings put global stay_on_while_plugged_in"*)
        v="${cmd##* }"
        printf '%s\n' "$v" >>"${MOCK_WORK}/stayon_writes.txt"
        # A phone that has been unplugged or rebooted accepts the command and
        # changes nothing. writes_fail names the value to swallow, so the hold
        # can succeed and only the restore fail -- which is the case worth
        # testing. Failing both writes would leave nothing to restore at all.
        if [ "$v" = "$(cat "${MOCK_WORK}/writes_fail" 2>/dev/null)" ]; then exit 0; fi
        printf '%s\n' "$v" >"${MOCK_WORK}/stayon"
        exit 0 ;;
      "cmd power wakeup"*)
        printf 'wakeup\n' >>"${MOCK_WORK}/wake_calls.txt"
        exit 0 ;;
      "dumpsys window policy"*)
        # MOCK_LOCKED controls whether the fake phone shows a keyguard.
        if [ "$(cat "${MOCK_WORK}/locked" 2>/dev/null || echo 0)" = "1" ]; then
          printf '    KeyguardServiceDelegate\n      showing=true\n      secure=false\n      dreaming=true\n'
        else
          printf '    KeyguardServiceDelegate\n      showing=false\n      secure=false\n      dreaming=false\n'
        fi
        exit 0 ;;
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
