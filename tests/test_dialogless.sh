#!/usr/bin/env bash
# SCRIPT: test_dialogless.sh
# DESCRIPTION: restore and data complete end to end with dialog absent.
# USAGE: bash tests/test_dialogless.sh
#
# Until 0.9.0 `tools/android_restore_dialog.sh` had no branch that did not go
# through dialog, so on Git Bash for Windows -- which ships no package manager
# to install dialog with -- restore could not run in any form. The prompts fall
# back to plain text now.
#
# dialog is not stubbed here, it is absent: PATH is rebuilt from a directory
# holding only the mock adb plus symlinks to the real tools, so nothing can
# reach a dialog that happens to be installed on the machine running this. A
# stub that exits non-zero would prove something weaker, because a flow could
# still be branching on its failure rather than never calling it.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

checks=0
failures=0
pass() { checks=$((checks + 1)); }
note() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BIN="$WORK/bin"
DEVICE="$WORK/device"
mkdir -p "$BIN" "$DEVICE/storage/emulated/0/DCIM" "$DEVICE/storage/emulated/0/Download"
printf 'a photo\n' >"$DEVICE/storage/emulated/0/DCIM/IMG_0001.jpg"
printf 'a download\n' >"$DEVICE/storage/emulated/0/Download/file.txt"

install -m 755 "$ROOT/tests/lib/mock_adb.sh" "$BIN/adb"

# A PATH with the real utilities but no dialog. Built by name rather than by
# copying a directory, so a dialog sitting in /usr/bin cannot be reached.
for tool in bash sh env cat cp mv rm mkdir ls find sed awk grep printf sort \
            date stat wc tr head tail cut basename dirname tar gzip gpg du df \
            chmod touch timeout sleep readlink realpath id tput stty mktemp \
            install xargs diff; do
  src="$(command -v "$tool" 2>/dev/null)" || continue
  # An if, not A && B || C: `|| true` after a failed ln would also swallow a
  # failure of the test itself, and this loop is what makes dialog unreachable.
  if [ -n "$src" ]; then
    ln -sf "$src" "$BIN/$tool" 2>/dev/null || true
  fi
done

if PATH="$BIN" command -v dialog >/dev/null 2>&1; then
  note "dialog is reachable on the test PATH; this suite would prove nothing"
else
  pass
fi

run_isolated() {
  # MOCK_* reach the mock adb; ANDROID_RESCUE_UI is not set, so the backend is
  # chosen by whether dialog is found, which is the thing under test.
  env -i \
    PATH="$BIN" HOME="$WORK/home" TERM=dumb \
    MOCK_DEVICE="$DEVICE" MOCK_WORK="$WORK" \
    ANDROID_RESCUE_PROGRESS=never \
    bash "$@"
}

# --- restore ----------------------------------------------------------------

BACKUP="$WORK/backup"
mkdir -p "$BACKUP/shared/DCIM" "$BACKUP/shared/Download"
printf 'restored photo\n' >"$BACKUP/shared/DCIM/IMG_9999.jpg"
printf 'restored doc\n'   >"$BACKUP/shared/Download/doc.txt"

# Cancelling must not write to the phone, and must not be mistaken for success.
out="$(printf 'q\n' | run_isolated tools/android_restore_dialog.sh "$BACKUP" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then pass; else note "a cancelled restore exited 0"; fi
if printf '%s' "$out" | grep -qi 'dialog is required\|command not found'; then
  note "restore still demands dialog: $(printf '%s' "$out" | head -1)"
else
  pass
fi
if [ -e "$DEVICE/storage/emulated/0/DCIM/IMG_9999.jpg" ]; then
  note "a cancelled restore wrote to the phone anyway"
else
  pass
fi

# Accepting the defaults must actually push.
out="$(printf '\n' | run_isolated tools/android_restore_dialog.sh "$BACKUP" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then pass; else note "restore exited $rc with dialog absent: $(printf '%s' "$out" | tail -3)"; fi
if [ -f "$DEVICE/storage/emulated/0/DCIM/IMG_9999.jpg" ]; then
  pass
else
  note "restore completed but the photo never reached the phone"
fi
if [ -f "$DEVICE/storage/emulated/0/Download/doc.txt" ]; then
  pass
else
  note "restore did not push the Downloads folder"
fi

# Deselecting everything is a completed run that copies nothing, distinct from
# a cancel. A phone must never be written to because a menu was misread.
rm -f "$DEVICE/storage/emulated/0/DCIM/IMG_9999.jpg" "$DEVICE/storage/emulated/0/Download/doc.txt"
out="$(printf 'n\n\n' | run_isolated tools/android_restore_dialog.sh "$BACKUP" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then pass; else note "an empty selection exited $rc, not 0"; fi
if [ -e "$DEVICE/storage/emulated/0/DCIM/IMG_9999.jpg" ]; then
  note "an empty selection still pushed files"
else
  pass
fi

# --- backup -----------------------------------------------------------------

DEST="$WORK/out"
out="$(printf '\n\n' | run_isolated tools/android_backup_dialog.sh "$DEST" 2>&1)"
rc=$?
if printf '%s' "$out" | grep -qi 'dialog is required\|dialog: command not found'; then
  note "the backup flow still demands dialog"
else
  pass
fi
if [ "$rc" -eq 0 ]; then pass; else note "the backup flow exited $rc with dialog absent: $(printf '%s' "$out" | tail -3)"; fi
# Shared storage, not the photo sweep: photos are found through a MediaStore
# content query the mock does not answer, and test_photo_backup.sh covers that
# path against a mock that does. What matters here is that a flow which cannot
# draw a single dialog still reached the phone and wrote what it read.
if [ -f "$DEST/shared/Download/file.txt" ]; then
  pass
else
  note "the backup completed but copied nothing from the phone"
  find "$DEST" -type f 2>/dev/null | head -5 | sed 's/^/    wrote: /' >&2
fi

if [ -f "$DEST/backup_manifest.txt" ]; then
  pass
else
  note "no manifest was written, so the run did not finish its bookkeeping"
fi

# --- and the same flows still work when dialog IS present -------------------
#
#     The fallback must not become the only path that works. dialog is driven
#     here by a stub that answers, rather than one that fails.

cat >"$BIN/dialog" <<'STUB'
#!/usr/bin/env bash
# Answers whatever is asked: the tags for a checklist, the default for a
# radiolist, empty for the rest. Enough to prove the dialog branch is still
# wired to the same code underneath.
args=("$@")
for i in "${!args[@]}"; do
  case "${args[$i]}" in
    --checklist)
      # After --checklist come text, height, width and list-height; the
      # tag/desc/state triples start at i+5. Getting this off by one made the
      # stub return a description instead of a tag, and the flow selected
      # nothing while reporting success.
      shift_at=$((i + 5))
      while [ "$shift_at" -lt "${#args[@]}" ]; do
        printf '%s\n' "${args[$shift_at]}"
        shift_at=$((shift_at + 3))
      done
      exit 0 ;;
    --radiolist|--menu)
      printf '%s\n' "${args[$((i + 5))]}"; exit 0 ;;
    --msgbox|--yesno) exit 0 ;;
    --inputbox|--passwordbox) printf '\n'; exit 0 ;;
  esac
done
exit 0
STUB
chmod +x "$BIN/dialog"

if PATH="$BIN" command -v dialog >/dev/null 2>&1; then pass; else note "the dialog stub was not installed"; fi

rm -f "$DEVICE/storage/emulated/0/DCIM/IMG_9999.jpg"
out="$(run_isolated tools/android_restore_dialog.sh "$BACKUP" </dev/null 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then pass; else note "restore through dialog exited $rc: $(printf '%s' "$out" | tail -3)"; fi
if [ -f "$DEVICE/storage/emulated/0/DCIM/IMG_9999.jpg" ]; then
  pass
else
  note "restore through dialog did not push anything"
fi

if [ "$failures" -eq 0 ]; then
  printf 'dialogless: %s checks passed\n' "$checks"
else
  printf 'dialogless: %s of %s checks FAILED\n' "$failures" "$((checks + failures))" >&2
  exit 1
fi
