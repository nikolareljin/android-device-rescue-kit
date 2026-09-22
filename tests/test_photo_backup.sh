#!/usr/bin/env bash
# SCRIPT: test_photo_backup.sh
# DESCRIPTION: End-to-end tests for android_photo_backup.sh against a mock adb.
# USAGE: bash tests/test_photo_backup.sh
# EXAMPLE: bash tests/test_photo_backup.sh
#
# A fake device is built as a directory tree, and a mock `adb` on PATH answers
# `content query`, `find`, `stat` and `pull` from it. That makes the contract
# testable without hardware: discovery unions two sources, resume skips only
# what is already whole, and a file that cannot be copied makes the run fail
# and get named rather than pass quietly.
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
mkdir -p "$BIN"

# --- the fake device -------------------------------------------------------

build_device() {
  rm -rf "$DEVICE"
  mkdir -p "$DEVICE/storage/emulated/0/DCIM/Camera" \
           "$DEVICE/storage/emulated/0/DCIM/.thumbnails" \
           "$DEVICE/storage/emulated/0/Pictures/Screenshots" \
           "$DEVICE/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media/Images" \
           "$DEVICE/storage/1A2B-3C4D/DCIM"
  printf 'camera-one'    >"$DEVICE/storage/emulated/0/DCIM/Camera/IMG_001.jpg"
  printf 'camera-two'    >"$DEVICE/storage/emulated/0/DCIM/Camera/IMG_002.heic"
  printf 'a-screenshot'  >"$DEVICE/storage/emulated/0/Pictures/Screenshots/shot.png"
  printf 'received-pic'  >"$DEVICE/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media/Images/w.jpg"
  printf 'sdcard-photo'  >"$DEVICE/storage/1A2B-3C4D/DCIM/card.jpg"
  printf 'a-movie-file'  >"$DEVICE/storage/emulated/0/DCIM/Camera/VID_001.mp4"
  # Spaces in both the directory and the filename. This is the real shape of
  # /Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images/..., and it is
  # what broke on a device: adb shell joins argv into one string, so an
  # unquoted path became two arguments and no size was ever recorded.
  mkdir -p "$DEVICE/storage/emulated/0/Pictures/My Holiday Photos"
  printf 'spaced-photo' >"$DEVICE/storage/emulated/0/Pictures/My Holiday Photos/beach day.jpg"
  # Must be excluded:
  printf 'thumb'         >"$DEVICE/storage/emulated/0/DCIM/.thumbnails/t.jpg"
  # Must be ignored as non-media:
  printf 'notes'         >"$DEVICE/storage/emulated/0/DCIM/notes.pdf"
}

# MEDIASTORE_ONLY lists paths the sweep will not return, to prove the union
# matters. UNPULLABLE lists paths the mock refuses to copy.
: >"$WORK/mediastore_only"
: >"$WORK/sweep_only"
: >"$WORK/unpullable"

cat >"$BIN/adb" <<'MOCK'
#!/usr/bin/env bash
# Mock adb backed by a directory tree. Understands only what the script uses.
set -uo pipefail
DEVICE="${MOCK_DEVICE:?}"
WORK="${MOCK_WORK:?}"

dev_to_local() { printf '%s%s\n' "$DEVICE" "$1"; }

case "${1:-}" in
  devices)
    # require_device reads this. A test can present an unauthorised or absent
    # phone by writing to device_state.
    printf 'List of devices attached\n'
    st="$(cat "${MOCK_WORK:-/nonexistent}/device_state" 2>/dev/null || echo device)"
    [ "$st" = "none" ] || printf 'MOCKSERIAL\t%s\n' "$st"
    exit 0 ;;
  shell)
    shift
    # Real adb shell reads stdin and forwards it to the device. The mock drains
    # it for the same reason: a caller that runs adb inside a `while read` loop
    # without </dev/null loses the rest of its input, which is how sizes were
    # collected for only the first 200 of 5,399 files on a real phone.
    # Bounded: a plain `cat` blocks forever when stdin has a writer that never
    # closes, which hangs the suite instead of failing it.
    if [ ! -t 0 ]; then timeout 0.2 cat >/dev/null 2>&1 || true; fi
    # Real adb does NOT pass argv through: it joins its arguments with spaces
    # and hands one string to a shell on the device. The mock does the same, so
    # a caller that forgets to quote a path containing a space fails here the
    # way it fails on a phone.
    cmd="$*"
    set -- $cmd
    case "${1:-}" in
      content)
        # content query --uri <uri> --projection _data
        uri=""
        while [ "$#" -gt 0 ]; do
          [ "$1" = "--uri" ] && uri="$2"
          shift
        done
        case "$uri" in
          *images*) pattern='\.(jpg|jpeg|png|heic|webp|gif)$' ;;
          *video*)  pattern='\.(mp4|3gp|mkv|mov|webm)$' ;;
          *) exit 0 ;;
        esac
        i=0
        # MediaStore reports CRLF, as a real device over a PTY does.
        find "$DEVICE" -type f 2>/dev/null | sed "s|^$DEVICE||" | grep -Ei "$pattern" | sort | while IFS= read -r p; do
          case "$p" in */.thumbnails/*) continue ;; esac
          # Files MediaStore has not indexed, e.g. copied in over USB.
          grep -Fxq "$p" "$WORK/sweep_only" 2>/dev/null && continue
          printf 'Row: %s _data=%s\r\n' "$i" "$p"
          i=$((i + 1))
        done
        ;;
      stat)
        # The device shell re-splits the joined string, honouring quotes. eval
        # is what reproduces that faithfully; the paths come from this file's
        # own fixture tree.
        rest="${cmd#stat }"
        case "$rest" in
          -c\ *) rest="${rest#-c }"; rest="${rest#* }" ;;
        esac
        eval "set -- $rest"
        for p in "$@"; do
          l="$(dev_to_local "$p")"
          [ -f "$l" ] || continue
          printf '%s|%s\n' "$(wc -c <"$l" | tr -d ' ')" "$p"
        done
        ;;
      *)
        # A single shell command string, which is how the sweep is issued.
        cmd="$*"
        case "$cmd" in
          find*)
            find "$DEVICE" -type f 2>/dev/null | sed "s|^$DEVICE||" | sort | while IFS= read -r p; do
              # Files listed as MediaStore-only are invisible to the sweep.
              grep -Fxq "$p" "$WORK/mediastore_only" 2>/dev/null && continue
              case "$p" in
                *.jpg|*.jpeg|*.png|*.heic|*.webp|*.gif|*.mp4|*.3gp|*.mkv|*.mov|*.webm) printf '%s\n' "$p" ;;
              esac
            done
            ;;
        esac
        ;;
    esac
    ;;
  pull)
    shift
    [ "${1:-}" = "-a" ] && shift
    src="$1"; dst="$2"
    grep -Fxq "$src" "$WORK/unpullable" 2>/dev/null && exit 1
    l="$(dev_to_local "$src")"
    [ -f "$l" ] || exit 1
    cp "$l" "$dst" || exit 1
    ;;
  start-server|wait-for-device) : ;;
esac
exit 0
MOCK
chmod +x "$BIN/adb"

export MOCK_DEVICE="$DEVICE" MOCK_WORK="$WORK"
# The fake phone is attached and authorised unless a test says otherwise.
printf 'device\n' >"$WORK/device_state"
export PATH="$BIN:$PATH"
export PHOTO_ROOTS="/storage"

run_backup() {
  local root="$1"
  ( cd "$ROOT" && bash tools/android_photo_backup.sh "$root" >"$WORK/out.txt" 2>&1 )
  printf '%s' "$?"
}

index_count() { wc -l <"$1/photos_index.txt" | tr -d ' '; }
copied_count() { find "$1/photos" -type f 2>/dev/null | wc -l | tr -d ' '; }

# --- 1. a clean run copies everything and verifies -------------------------

build_device
BK="$WORK/bk1"; mkdir -p "$BK"
rc=$(run_backup "$BK")
check "clean run exits 0" "0" "$rc"
check "index holds the 7 real media files" "7" "$(index_count "$BK")"
check "all 7 copied" "7" "$(copied_count "$BK")"
check "no missing_photos.txt on success" "absent" "$([ -f "$BK/missing_photos.txt" ] && echo present || echo absent)"
check "thumbnail excluded" "absent" \
  "$([ -f "$BK/photos/storage/emulated/0/DCIM/.thumbnails/t.jpg" ] && echo present || echo absent)"
check "pdf not treated as media" "absent" \
  "$([ -f "$BK/photos/storage/emulated/0/DCIM/notes.pdf" ] && echo present || echo absent)"
check "removable card kept on its own path" "present" \
  "$([ -f "$BK/photos/storage/1A2B-3C4D/DCIM/card.jpg" ] && echo present || echo absent)"
check "device tree mirrored" "camera-one" \
  "$(cat "$BK/photos/storage/emulated/0/DCIM/Camera/IMG_001.jpg" 2>/dev/null)"
# The spaced path must survive discovery, the size lookup and the copy. If the
# size lookup silently failed, verification would fall back to "non-zero" and a
# truncated file would pass -- so this also guards that degradation.
check "a path with spaces is copied" "spaced-photo" \
  "$(cat "$BK/photos/storage/emulated/0/Pictures/My Holiday Photos/beach day.jpg" 2>/dev/null)"

# --- 2. the union matters: a MediaStore-only file is still captured --------

build_device
printf '/storage/emulated/0/Pictures/Screenshots/shot.png\n' >"$WORK/mediastore_only"
BK="$WORK/bk2"; mkdir -p "$BK"
rc=$(run_backup "$BK")
check "union run exits 0" "0" "$rc"
check "file invisible to the sweep is still copied" "present" \
  "$([ -f "$BK/photos/storage/emulated/0/Pictures/Screenshots/shot.png" ] && echo present || echo absent)"
: >"$WORK/mediastore_only"

# --- 2b. the union matters the other way: a file MediaStore has not indexed
#         must still be swept up. This is the USB-copy case, and without the
#         sweep it is lost silently -- nothing else would notice.

build_device
printf 'unindexed-photo' >"$DEVICE/storage/emulated/0/DCIM/Camera/IMG_003.jpg"
printf '/storage/emulated/0/DCIM/Camera/IMG_003.jpg\n' >"$WORK/sweep_only"
BK="$WORK/bk2b"; mkdir -p "$BK"
rc=$(run_backup "$BK")
check "sweep-only run exits 0" "0" "$rc"
check "file MediaStore never indexed is still copied" "unindexed-photo" \
  "$(cat "$BK/photos/storage/emulated/0/DCIM/Camera/IMG_003.jpg" 2>/dev/null)"
check "index counts it" "8" "$(index_count "$BK")"
: >"$WORK/sweep_only"

# --- 3. an uncopyable file fails the run and is named ----------------------

build_device
printf '/storage/emulated/0/DCIM/Camera/IMG_002.heic\n' >"$WORK/unpullable"
BK="$WORK/bk3"; mkdir -p "$BK"
rc=$(PHOTO_PULL_RETRIES=2 run_backup "$BK")
check "a file that cannot be copied FAILS the run" "1" "$rc"
check "missing_photos.txt exists" "present" \
  "$([ -f "$BK/missing_photos.txt" ] && echo present || echo absent)"
check "the missing file is named" "1" \
  "$(grep -c 'IMG_002.heic' "$BK/missing_photos.txt" 2>/dev/null | tr -d ' ')"
check "report records the shortfall" "1" \
  "$(grep -c '^MISSING  *: 1$' "$BK/photos_report.txt" 2>/dev/null | tr -d ' ')"
check "the other photos still copied" "present" \
  "$([ -f "$BK/photos/storage/emulated/0/DCIM/Camera/IMG_001.jpg" ] && echo present || echo absent)"
: >"$WORK/unpullable"

# --- 4. resume: a whole file is not re-copied, a short one is -------------

build_device
BK="$WORK/bk4"; mkdir -p "$BK"
run_backup "$BK" >/dev/null
# Truncate one copy to simulate an interrupted pull, and leave another intact.
printf 'x' >"$BK/photos/storage/emulated/0/DCIM/Camera/IMG_001.jpg"
rc=$(run_backup "$BK")
check "second run exits 0" "0" "$rc"
check "the truncated file was re-copied whole" "camera-one" \
  "$(cat "$BK/photos/storage/emulated/0/DCIM/Camera/IMG_001.jpg" 2>/dev/null)"
check "resume reported for the untouched files" "1" \
  "$(grep -cE '^Already present \(resumed\) : [1-9]' "$BK/photos_report.txt" | tr -d ' ')"

# --- 4b. more files than one stat batch -----------------------------------
#
#     collect_device_sizes batches 200 paths per adb call. adb shell reads
#     stdin, and the batching loop reads the index from stdin, so without
#     </dev/null adb swallowed the rest of the index after the first batch:
#     sizes were collected for 200 files and verification silently degraded to
#     "the file is non-zero" for every one after that. A fixture smaller than
#     one batch cannot see it.

build_device
mkdir -p "$DEVICE/storage/emulated/0/DCIM/Bulk"
i=0
while [ "$i" -lt 250 ]; do
  printf 'bulk-%s' "$i" >"$DEVICE/storage/emulated/0/DCIM/Bulk/img_$i.jpg"
  i=$((i + 1))
done
BK="$WORK/bk_bulk"; mkdir -p "$BK"
rc=$(run_backup "$BK")
check "a run spanning several stat batches exits 0" "0" "$rc"
check "every file got a device size" "$(index_count "$BK")" \
  "$(wc -l <"$BK/.photo_work/sizes.txt" | tr -d ' ')"
# A file well past the first batch must be size-verified, not merely present.
printf 'x' >"$BK/photos/storage/emulated/0/DCIM/Bulk/img_240.jpg"
rc=$(run_backup "$BK")
check "a truncated file past batch 1 is repaired" "bulk-240" \
  "$(cat "$BK/photos/storage/emulated/0/DCIM/Bulk/img_240.jpg" 2>/dev/null)"
# Compared against the real on-disk sum rather than a threshold: taking only
# the last wc batch reported 24.8 GB as 1.4 GB on a real run.
check "byte total equals the actual bytes on disk" \
  "$(find "$BK/photos" -type f -exec wc -c {} + | awk '/total$/ {s += $1} END {printf "%d", s}')" \
  "$(awk '/^Bytes on disk/ {print $NF}' "$BK/photos_report.txt")"

# --- 4c. an unauthorised phone is not an empty phone ----------------------
#
#     Found by withholding the authorisation dialog on a real handset holding
#     5,399 photos: discovery returned nothing, the run reported "No photos or
#     videos were found on the device" and exited 0. "Could not ask" and
#     "asked, and there are none" must never read the same.

build_device
printf 'unauthorized\n' >"$WORK/device_state"
BK="$WORK/bk_unauth"; mkdir -p "$BK"
rc=$(ADB_WAIT_TIMEOUT=2 run_backup "$BK")
check "an unauthorised phone FAILS the run" "1" "$rc"
check "and says the phone has not authorised this computer" "1" \
  "$(grep -c 'NOT authorised' "$WORK/out.txt")"
check "it does NOT claim the phone is empty" "0" \
  "$(grep -c 'No photos or videos were found' "$WORK/out.txt")"
check "nothing is written" "0" "$(find "$BK" -type f 2>/dev/null | wc -l | tr -d ' ')"
printf 'device\n' >"$WORK/device_state"

# --- 5. a device with no photos is not an error ---------------------------

rm -rf "$DEVICE"; mkdir -p "$DEVICE/storage/emulated/0/DCIM"
BK="$WORK/bk5"; mkdir -p "$BK"
rc=$(run_backup "$BK")
check "empty device exits 0" "0" "$rc"
check "empty device says so" "1" \
  "$(grep -c 'No photos or videos found' "$BK/photos_report.txt" | tr -d ' ')"

# --- the same run, with the progress gauge drawing -------------------------
#
#     The gauge is fed through a FIFO rather than `loop | dialog --gauge`,
#     because a piped loop runs in a subshell and every counter it increments
#     dies with it. That would report "Copied this run: 0" for a run that
#     copied everything -- and the number this tool reports is the whole
#     contract: someone wipes a phone on the strength of it.

cat >"$BIN/dialog" <<'GAUGE'
#!/usr/bin/env bash
cat >/dev/null
GAUGE
chmod +x "$BIN/dialog"

GAUGE_ROOT="$WORK/gauge_backup"
mkdir -p "$GAUGE_ROOT"
rc="$(ANDROID_RESCUE_PROGRESS=always run_backup "$GAUGE_ROOT")"
check "gauge run exits 0" "0" "$rc"
check "gauge run copied every file" "$(index_count "$GAUGE_ROOT")" "$(copied_count "$GAUGE_ROOT")"
check "gauge run reports what it copied, not zero" "0" \
  "$(grep -cE '^Copied this run           : 0$' "$GAUGE_ROOT/photos_report.txt")"
check "gauge run verified every file" "0" \
  "$(grep -cE '^MISSING  *: [1-9]' "$GAUGE_ROOT/photos_report.txt")"
rm -f "$BIN/dialog"

# ---------------------------------------------------------------------------

if [ "$FAILURES" -eq 0 ]; then
  printf 'photo_backup: %d checks passed\n' "$TESTS"
else
  printf 'photo_backup: %d of %d checks FAILED\n' "$FAILURES" "$TESTS" >&2
  exit 1
fi
