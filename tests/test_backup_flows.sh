#!/usr/bin/env bash
# SCRIPT: test_backup_flows.sh
# DESCRIPTION: The backup flows, attended and unattended: dialogs never reached when unattended, and the credential-export path intact.
# USAGE: bash tests/test_backup_flows.sh
# EXAMPLE: bash tests/test_backup_flows.sh
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
printf 'name,url,username,password\nbank,https://b.example,owner,hunter2\n' \
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
  devices)
    # require_device reads this. MOCK_DEVICE_STATE lets a test present an
    # unauthorised or absent phone.
    printf 'List of devices attached\n'
    st="$(cat "${MOCK_WORK:-/nonexistent}/device_state" 2>/dev/null || echo device)"
    [ "$st" = "none" ] || printf 'MOCKSERIAL\t%s\n' "$st"
    exit 0 ;;
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
MOCK
chmod +x "$BIN/adb"

export MOCK_DEVICE="$DEVICE" MOCK_WORK="$WORK"
# The fake phone starts unlocked, with the Android default stay-on value.
printf '0\n' >"$WORK/stayon"
printf '0\n' >"$WORK/locked"
: >"$WORK/stayon_writes.txt"
: >"$WORK/wake_calls.txt"
: >"$WORK/writes_fail"
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
# The hint now warns about the biometric prompt, because Samsung Pass demands
# one on arrival at the export screen and a user who is not told assumes a fault.
check "the export hint travels with it" "1" \
  "$(grep -c 'fingerprint or PIN first' "$BK/recovery_profile/recovery_actions.txt" 2>/dev/null)"
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
# The target is the import/export menu itself, not the Settings screen it used
# to land on several taps away.
check "launch-spec app opens via am start" "1" \
  "$(grep -c 'am start -a com.samsung.android.samsungpass.action.SETTINGS' "$WORK/am_calls.txt")"
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

# --- screen control: recorded, held, and put back --------------------------

: >"$WORK/stayon_writes.txt"; : >"$WORK/wake_calls.txt"
printf '0\n' >"$WORK/stayon"; printf '0\n' >"$WORK/locked"
BK7="$WORK/backup7"; mkdir -p "$BK7"
( cd "$ROOT" && bash tools/android_backup_dialog.sh "$BK7" \
    --recovery-profile --no-encrypt --non-interactive --select recovery_profile \
    >"$WORK/out7.txt" 2>&1 )
check "screen-control run exits 0" "0" "$?"
check "the screen was woken" "1" \
  "$([ -s "$WORK/wake_calls.txt" ] && echo 1 || echo 0)"
check "stay-on was set to the USB bit" "1" \
  "$(grep -cx '2' "$WORK/stayon_writes.txt")"
# The value that matters: whatever the phone is left holding at the end.
check "the original value was restored" "0" "$(cat "$WORK/stayon" | tr -d ' ')"
check "the last write was the restore" "0" "$(tail -1 "$WORK/stayon_writes.txt")"
check "the state file is cleaned up" "absent" \
  "$([ -f "$BK7/.screen_state" ] && echo present || echo absent)"

# --- a non-default original must be preserved, not zeroed -----------------
#
#     Restoring a hardcoded 0 would silently disable stay-awake on a phone whose
#     owner had deliberately enabled it.

: >"$WORK/stayon_writes.txt"
printf '15\n' >"$WORK/stayon"
BK8="$WORK/backup8"; mkdir -p "$BK8"
( cd "$ROOT" && bash tools/android_backup_dialog.sh "$BK8" \
    --recovery-profile --no-encrypt --non-interactive --select recovery_profile \
    >"$WORK/out8.txt" 2>&1 )
check "a non-default original is restored, not zeroed" "15" "$(cat "$WORK/stayon" | tr -d ' ')"
printf '0\n' >"$WORK/stayon"

# --- --no-screen-control writes nothing -----------------------------------

: >"$WORK/stayon_writes.txt"; : >"$WORK/wake_calls.txt"
BK9="$WORK/backup9"; mkdir -p "$BK9"
( cd "$ROOT" && bash tools/android_backup_dialog.sh "$BK9" \
    --recovery-profile --no-encrypt --non-interactive --select recovery_profile \
    --no-screen-control >"$WORK/out9.txt" 2>&1 )
check "--no-screen-control run exits 0" "0" "$?"
check "--no-screen-control writes no setting" "0" \
  "$(wc -l <"$WORK/stayon_writes.txt" | tr -d ' ')"
check "--no-screen-control does not wake" "0" \
  "$(wc -l <"$WORK/wake_calls.txt" | tr -d ' ')"

# --- a locked phone unattended: skip credentials, finish everything else ---

: >"$WORK/stayon_writes.txt"
printf '1\n' >"$WORK/locked"
BK10="$WORK/backup10"; mkdir -p "$BK10"
( cd "$ROOT" && SCREEN_UNLOCK_TIMEOUT=5 bash tools/android_backup_dialog.sh "$BK10" \
    --recovery-profile --no-encrypt --non-interactive \
    --select downloads,recovery_profile >"$WORK/out10.txt" 2>&1 )
check "a locked phone does not fail the backup" "0" "$?"
check "the skip is recorded in the manifest" "1" \
  "$(grep -c 'SKIPPED credential steps: phone stayed locked' "$BK10/backup_manifest.txt")"
check "no recovery profile was written" "absent" \
  "$([ -d "$BK10/recovery_profile" ] && echo present || echo absent)"
check "the other category still ran" "present" \
  "$([ -d "$BK10/shared/Download" ] && echo present || echo absent)"
check "the skip is stated at the end too" "1" \
  "$(grep -c 'NOT CAPTURED' "$WORK/out10.txt")"
check "the setting is still restored when skipping" "0" "$(cat "$WORK/stayon" | tr -d ' ')"
printf '0\n' >"$WORK/locked"

# --- interrupted mid-run: the phone must not be left changed --------------
#
#     stay_on_while_plugged_in survives a reboot, so a Ctrl-C that skipped the
#     restore would permanently alter someone else's phone.

: >"$WORK/stayon_writes.txt"
printf '0\n' >"$WORK/stayon"; printf '1\n' >"$WORK/locked"
BK11="$WORK/backup11"; mkdir -p "$BK11"
# `exec` is load-bearing. Without it $! is the subshell's pid, the signal never
# reaches the script, and the run simply polls to its timeout and restores on
# the normal path -- so the test passes whether or not the traps exist.
( cd "$ROOT" && SCREEN_UNLOCK_TIMEOUT=60 exec bash tools/android_backup_dialog.sh "$BK11" \
    --recovery-profile --no-encrypt --non-interactive --select recovery_profile \
    >"$WORK/out11.txt" 2>&1 ) &
bg=$!
# Long enough to be inside the unlock wait, with the setting already changed.
sleep 6
check "the setting was changed before the interrupt" "2" "$(cat "$WORK/stayon" | tr -d ' ')"
kill -INT "$bg" 2>/dev/null
wait "$bg" 2>/dev/null
check "SIGINT restores the original value" "0" "$(cat "$WORK/stayon" | tr -d ' ')"
check "and the restore was the last write" "0" "$(tail -1 "$WORK/stayon_writes.txt")"
printf '0\n' >"$WORK/locked"

# --- a failed restore keeps the record and says so ------------------------
#
#     Deleting the state file when the restore did not take would destroy the
#     only evidence of what the phone had, leaving it changed and untraceable.

: >"$WORK/stayon_writes.txt"
printf '0\n' >"$WORK/stayon"
BK12="$WORK/backup12"; mkdir -p "$BK12"
printf '0\n' >"$WORK/writes_fail"        # the restore to 0 is swallowed; the hold to 2 works
( cd "$ROOT" && bash tools/android_backup_dialog.sh "$BK12" \
    --recovery-profile --no-encrypt --non-interactive --select recovery_profile \
    >"$WORK/out12.txt" 2>&1 )
: >"$WORK/writes_fail"
check "a failed restore is reported" "1" \
  "$(grep -c 'Could not restore' "$WORK/out12.txt")"
check "it prints the command to fix it by hand" "1" \
  "$(grep -c 'adb shell settings put global stay_on_while_plugged_in 0' "$WORK/out12.txt")"
check "the record is KEPT when the restore failed" "present" \
  "$([ -f "$BK12/.screen_state" ] && echo present || echo absent)"
check "and it still holds the original value" "0" \
  "$(cat "$BK12/.screen_state" 2>/dev/null | tr -d ' ')"

# --- an unwritable record means the phone is not touched at all -----------

: >"$WORK/stayon_writes.txt"
printf '0\n' >"$WORK/stayon"
BK13="$WORK/backup13"; mkdir -p "$BK13"
# A directory where the state file should go: the write cannot succeed.
mkdir -p "$BK13/.screen_state"
( cd "$ROOT" && bash tools/android_backup_dialog.sh "$BK13" \
    --recovery-profile --no-encrypt --non-interactive --select recovery_profile \
    >"$WORK/out13.txt" 2>&1 )
check "an unrecordable setting is left alone" "0" \
  "$(wc -l <"$WORK/stayon_writes.txt" | tr -d ' ')"
check "and that is said out loud" "1" \
  "$(grep -c 'Cannot record the screen setting' "$WORK/out13.txt")"
rmdir "$BK13/.screen_state" 2>/dev/null || true

# --- an explicit --recovery-profile is not silently dropped ---------------
#
#     --select omitting the category, with the flag given on the same command
#     line, used to skip the step somebody asked for by name.

printf '0\n' >"$WORK/stayon"
BK14="$WORK/backup14"; mkdir -p "$BK14"
( cd "$ROOT" && bash tools/android_backup_dialog.sh "$BK14" \
    --recovery-profile --no-encrypt --non-interactive --select downloads \
    >"$WORK/out14.txt" 2>&1 )
check "the flag still collects the profile" "present" \
  "$([ -d "$BK14/recovery_profile" ] && echo present || echo absent)"
check "and says it is doing so" "1" \
  "$(grep -c 'omits recovery_profile; collecting it anyway' "$WORK/out14.txt")"
check "the selected category also ran" "present" \
  "$([ -d "$BK14/shared/Download" ] && echo present || echo absent)"

# Without the flag, an omitted category stays omitted.
BK15="$WORK/backup15"; mkdir -p "$BK15"
( cd "$ROOT" && bash tools/android_backup_dialog.sh "$BK15" \
    --no-encrypt --non-interactive --select downloads >"$WORK/out15.txt" 2>&1 )
check "no flag means no profile" "absent" \
  "$([ -d "$BK15/recovery_profile" ] && echo present || echo absent)"

# --- a missing --select is refused rather than hanging ---------------------

BK2="$WORK/backup2"; mkdir -p "$BK2"
( cd "$ROOT" && bash tools/android_backup_dialog.sh "$BK2" --non-interactive >"$WORK/out2.txt" 2>&1 )
check "--non-interactive without --select is refused" "2" "$?"
check "and says why" "1" "$(grep -c 'requires --select' "$WORK/out2.txt")"

# ---------------------------------------------------------------------------

# --- a recovery profile with no credentials is complete --------------------
#
#     Reported from a real run: the owner keeps passwords in their Google
#     account, so they selected no credential provider. Everything else was
#     captured, and the run still ended with "Recovery profile was not
#     completed" and exit 1, abandoning the categories that had not run yet.
#     Encryption is what failed, and with nothing secret to protect, declining
#     it is a choice rather than a failure.

BK6="$WORK/backup6"; mkdir -p "$BK6"
: >"$WORK/dialog_calls.txt"
( cd "$ROOT" && bash tools/android_backup_dialog.sh "$BK6" \
    --recovery-profile --non-interactive --select recovery_profile,downloads \
    >"$WORK/out6.txt" 2>&1 )
check "no credentials, encryption not set: exits 0" "0" "$?"
check "the profile was still captured" "present" \
  "$([ -s "$BK6/recovery_profile/settings_system.txt" ] && echo present || echo absent)"
check "the other categories still ran" "present" \
  "$([ -d "$BK6/shared/Download" ] && echo present || echo absent)"
check "it is not reported as a failure" "0" \
  "$(grep -c 'FAILED recovery profile' "$BK6/backup_manifest.txt")"
check "and the manifest says the profile is readable" "1" \
  "$(grep -c 'PLAINTEXT profile at' "$BK6/backup_manifest.txt")"
# --non-interactive promises never to reach a dialog. Asking for a passphrase
# broke that promise, and with no terminal to answer it an unattended
# --recovery-profile run could not complete unless --no-encrypt was passed too.
check "no dialog was reached for the passphrase" "" "$(cat "$WORK/dialog_calls.txt")"

# --- with credentials, declining encryption is still a failure -------------
#
#     Same path, but now the profile holds someone's passwords in the clear.
#     That must still fail -- and must still let the rest of the backup finish,
#     because abandoning it protects nothing.

BK7="$WORK/backup7"; mkdir -p "$BK7"
( cd "$ROOT" && bash tools/android_backup_dialog.sh "$BK7" \
    --recovery-profile --non-interactive --select recovery_profile,downloads \
    --credential-export /sdcard/Download/passwords.csv \
    >"$WORK/out7.txt" 2>&1 )
check "credentials present, no encryption: exits non-zero" "1" "$?"
check "the failure is named in the manifest" "1" \
  "$(grep -c 'FAILED recovery profile' "$BK7/backup_manifest.txt")"
check "the credential export was still imported" "present" \
  "$([ -s "$BK7/recovery_profile/imports/passwords.csv" ] && echo present || echo absent)"
check "and the rest of the backup still ran" "present" \
  "$([ -d "$BK7/shared/Download" ] && echo present || echo absent)"

# --- attended: the whole credential-export path still works ----------------
#
#     There was no attended coverage at all, which is how a defect in the
#     passphrase step shipped. This drives the real interactive route: the
#     owner picks a manager to open, types the path of the file that manager
#     exported, and sets a passphrase.
#
#     It exists to stop the export options being narrowed. Any change that
#     stops offering the manager list, or stops accepting an exported file,
#     fails here.

: >"$WORK/dialog_seen.txt"
: >"$WORK/inputbox_calls"
cat >"$BIN/dialog" <<MOCK
#!/usr/bin/env bash
args="\$*"
printf '%s\n' "\$args" >>"$WORK/dialog_seen.txt"
case "\$args" in
  *"Open A Password Manager"*) printf '0\n'; exit 0 ;;
  *--checklist*) printf 'recovery_profile\ndownloads\n'; exit 0 ;;
  *"Credential Export"*)
      n=\$(wc -l <"$WORK/inputbox_calls")
      printf 'x\n' >>"$WORK/inputbox_calls"
      if [ "\$n" -eq 0 ]; then printf '/sdcard/Download/passwords.csv\n'; else printf '\n'; fi
      exit 0 ;;
  *--passwordbox*) printf 'correct horse battery staple\n'; exit 0 ;;
  *) exit 0 ;;
esac
MOCK
chmod +x "$BIN/dialog"

BK8="$WORK/backup8"; mkdir -p "$BK8"
( cd "$ROOT" && bash tools/android_backup_dialog.sh "$BK8" --recovery-profile </dev/null \
    >"$WORK/out8.txt" 2>&1 )
check "attended export run exits 0" "0" "$?"
check "the manager list was offered" "1" \
  "$(grep -c 'Open A Password Manager' "$WORK/dialog_seen.txt")"
check "the chosen manager was opened" "1" \
  "$(grep -c '^OPENED ' "$BK8/backup_manifest.txt")"
check "the credential export prompt was shown" "2" \
  "$(grep -c 'Credential Export' "$WORK/dialog_seen.txt")"
check "the exported file was imported" "present" \
  "$([ -s "$BK8/recovery_profile/imports/passwords.csv" ] && echo present || echo absent)"
check "and counted" "1" \
  "$(grep -c 'Credential exports imported: 1' "$BK8/backup_manifest.txt")"
check "the encrypted archive was built and verified" "1" \
  "$(grep -c 'OK recovery-profile.tar.gpg verified' "$BK8/backup_manifest.txt")"

# --- attended: no manager chosen, passphrase cancelled ---------------------
#
#     The reported case. Passwords live in the owner's Google account, so no
#     provider is picked and there is nothing to encrypt.

: >"$WORK/dialog_seen.txt"
cat >"$BIN/dialog" <<MOCK
#!/usr/bin/env bash
args="\$*"
case "\$args" in
  *"Open A Password Manager"*) exit 0 ;;
  *--checklist*) printf 'recovery_profile\ndownloads\n'; exit 0 ;;
  *--inputbox*) printf '\n'; exit 0 ;;
  *--passwordbox*) exit 1 ;;
  *) exit 0 ;;
esac
MOCK
chmod +x "$BIN/dialog"

BK9="$WORK/backup9"; mkdir -p "$BK9"
( cd "$ROOT" && bash tools/android_backup_dialog.sh "$BK9" --recovery-profile </dev/null \
    >"$WORK/out9.txt" 2>&1 )
check "attended, nothing to encrypt: exits 0" "0" "$?"
check "the profile was captured anyway" "present" \
  "$([ -s "$BK9/recovery_profile/settings_system.txt" ] && echo present || echo absent)"
check "it is not called a failure" "0" \
  "$(grep -c 'FAILED recovery profile' "$BK9/backup_manifest.txt")"
check "and the old error text is gone" "0" \
  "$(sed 's/\x1b\[[0-9;]*m//g' "$WORK/out9.txt" | grep -c 'Recovery profile was not completed')"

# --- the shared-storage pulls draw into the gauge too ----------------------
#
#     adb prints its own progress -- "[ 11%] /sdcard/Download/zoom.apk: 98%" --
#     straight to the terminal. After the photo gauge closed, the rest of the
#     backup went back to scrolling those lines. Its percentage is now read
#     back out and drawn in the bar instead.

mv "$BIN/adb" "$BIN/adb.real"
cat >"$BIN/adb" <<MOCK
#!/usr/bin/env bash
if [ "\$1" = pull ]; then
  printf '[  7%%] /sdcard/Download/zoom.apk: 41%%\n'
  printf '[ 53%%] /sdcard/Download/zoom.apk: 98%%\n'
  printf '[100%%] /sdcard/Download/file.txt\n'
fi
exec "$BIN/adb.real" "\$@"
MOCK
chmod +x "$BIN/adb"
cat >"$BIN/dialog" <<MOCK
#!/usr/bin/env bash
case "\$*" in
  *--gauge*) printf 'OPENED\n' >>"$WORK/gauges.txt"; cat >>"$WORK/gauge_body.txt" ;;
  *) exit 0 ;;
esac
MOCK
chmod +x "$BIN/dialog"
: >"$WORK/gauges.txt"; : >"$WORK/gauge_body.txt"

BKG="$WORK/backup_gauge"; mkdir -p "$BKG"
( cd "$ROOT" && ANDROID_RESCUE_PROGRESS=always bash tools/android_backup_dialog.sh "$BKG" \
    --non-interactive --select downloads </dev/null >"$WORK/outg.txt" 2>&1 )
check "gauge data run exits 0" "0" "$?"
check "no raw adb progress reached the terminal" "0" \
  "$(sed 's/\x1b\[[0-9;]*m//g' "$WORK/outg.txt" | grep -c '%\]')"
check "exactly one gauge for the run" "1" "$(grep -c OPENED "$WORK/gauges.txt")"
# Both the Download and the Documents pull emit the mock's progress, so the
# value appears more than once; presence is the assertion, not the count.
check "adb's own percentage drove the bar" "yes" \
  "$(grep -q '^53$' "$WORK/gauge_body.txt" && echo yes || echo no)"
check "the file being pulled is named in the bar" "1" \
  "$(grep -c 'zoom.apk' "$WORK/gauge_body.txt" | head -1 | awk '{print ($1>0)?1:0}')"
check "and the pull still happened" "present" \
  "$([ -s "$BKG/shared/Download/file.txt" ] && echo present || echo absent)"
check "recorded in the manifest" "1" \
  "$(grep -c 'OK /sdcard/Download -> shared/Download' "$BKG/backup_manifest.txt")"

# --- two dialogs must never share the terminal -----------------------------
#
#     The photos category shells out to android_photo_backup.sh, which draws
#     its own gauge. Ours comes down for the duration and goes back up, so the
#     run opens three in total rather than stacking two at once.

: >"$WORK/gauges.txt"
BKP="$WORK/backup_photos_gauge"; mkdir -p "$BKP"
( cd "$ROOT" && ANDROID_RESCUE_PROGRESS=always bash tools/android_backup_dialog.sh "$BKP" \
    --non-interactive --select photos,downloads </dev/null >"$WORK/outp.txt" 2>&1 )
check "photos plus downloads exits 0" "0" "$?"
check "the parent bar steps aside for the photo tool" "3" \
  "$(grep -c OPENED "$WORK/gauges.txt")"
rm -f "$BIN/adb"; mv "$BIN/adb.real" "$BIN/adb"

if [ "$FAILURES" -eq 0 ]; then
  printf 'backup_flows: %d checks passed\n' "$TESTS"
else
  printf 'backup_flows: %d of %d checks FAILED\n' "$FAILURES" "$TESTS" >&2
  printf -- '--- run output ---\n' >&2
  sed 's/\x1b\[[0-9;]*m//g' "$WORK/out.txt" | tail -25 >&2
  exit 1
fi
