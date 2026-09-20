#!/usr/bin/env bash
# SCRIPT: test_photo_index.sh
# DESCRIPTION: Unit tests for the pure photo-index functions in tools/lib/photo_index.sh.
# USAGE: bash tests/test_photo_index.sh
# EXAMPLE: bash tests/test_photo_index.sh
#
# These cover the half of photo discovery that does not touch a device: parsing
# what adb returned, normalising it, excluding what should not be copied, and
# merging two sources into one index. The device-facing half is exercised
# separately through the mock adb in test_photo_backup.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tools/lib/photo_index.sh
source "$ROOT/tools/lib/photo_index.sh"

TESTS=0
FAILURES=0

fail() {
  FAILURES=$((FAILURES + 1))
  printf 'FAIL: %s\n' "$1" >&2
  printf '  expected: %s\n' "$2" >&2
  printf '  actual:   %s\n' "$3" >&2
}

assert_eq() {
  TESTS=$((TESTS + 1))
  if [ "$2" != "$3" ]; then fail "$1" "$2" "$3"; fi
}

assert_true() {
  TESTS=$((TESTS + 1))
  if ! eval "$2"; then fail "$1" "true" "false"; fi
}

assert_false() {
  TESTS=$((TESTS + 1))
  if eval "$2"; then fail "$1" "false" "true"; fi
}

# --- photo_parse_mediastore ------------------------------------------------

out=$(printf 'Row: 0 _data=/storage/emulated/0/DCIM/Camera/IMG_001.jpg\nRow: 1 _data=/storage/emulated/0/Pictures/Screenshots/shot.png\n' | photo_parse_mediastore)
assert_eq "mediastore: extracts both paths" \
  "/storage/emulated/0/DCIM/Camera/IMG_001.jpg
/storage/emulated/0/Pictures/Screenshots/shot.png" "$out"

# adb commonly allocates a PTY and appends CR. A trailing CR silently breaks
# every later path comparison and makes adb pull fail on a path that looks right.
out=$(printf 'Row: 0 _data=/sdcard/DCIM/a.jpg\r\n' | photo_parse_mediastore)
assert_eq "mediastore: strips trailing CR" "/storage/emulated/0/DCIM/a.jpg" "$out"

out=$(printf 'No result found.\n' | photo_parse_mediastore)
assert_eq "mediastore: empty result yields nothing" "" "$out"

# A filename containing a space must survive; these are common on Android.
out=$(printf 'Row: 0 _data=/sdcard/DCIM/my holiday.jpg\n' | photo_parse_mediastore)
assert_eq "mediastore: keeps spaces in filenames" "/storage/emulated/0/DCIM/my holiday.jpg" "$out"

# A row with other projected columns must still yield only the path.
out=$(printf 'Row: 0 _id=12, _data=/sdcard/DCIM/b.jpg, _size=4096\n' | photo_parse_mediastore)
assert_eq "mediastore: ignores neighbouring columns" "/storage/emulated/0/DCIM/b.jpg" "$out"

# --- photo_normalize_path --------------------------------------------------

assert_eq "normalize: /sdcard to emulated" \
  "/storage/emulated/0/DCIM/a.jpg" "$(photo_normalize_path /sdcard/DCIM/a.jpg)"
assert_eq "normalize: /storage/self/primary to emulated" \
  "/storage/emulated/0/DCIM/a.jpg" "$(photo_normalize_path /storage/self/primary/DCIM/a.jpg)"
assert_eq "normalize: already canonical is unchanged" \
  "/storage/emulated/0/DCIM/a.jpg" "$(photo_normalize_path /storage/emulated/0/DCIM/a.jpg)"
# normalize is public and is called directly by both parsers, so its own CR
# contract is asserted here rather than only through them.
assert_eq "normalize: strips trailing CR itself" \
  "/storage/emulated/0/DCIM/a.jpg" "$(photo_normalize_path "$(printf '/sdcard/DCIM/a.jpg\r')")"
# A removable card must NOT be rewritten to primary storage, or its files
# collide with identically-named files in internal storage.
assert_eq "normalize: leaves a removable card alone" \
  "/storage/1A2B-3C4D/DCIM/a.jpg" "$(photo_normalize_path /storage/1A2B-3C4D/DCIM/a.jpg)"

# --- photo_is_excluded -----------------------------------------------------

assert_true  "exclude: .thumbnails"      'photo_is_excluded "/storage/emulated/0/DCIM/.thumbnails/x.jpg"'
assert_true  "exclude: app cache"        'photo_is_excluded "/storage/emulated/0/Android/data/com.x/cache/y.jpg"'
assert_true  "exclude: dot-cache dir"    'photo_is_excluded "/storage/emulated/0/.cache/z.png"'
assert_true  "exclude: trashed file"     'photo_is_excluded "/storage/emulated/0/DCIM/.trashed-1699-a.jpg"'
assert_false "keep: ordinary camera photo" 'photo_is_excluded "/storage/emulated/0/DCIM/Camera/IMG_1.jpg"'
assert_false "keep: received app media"    'photo_is_excluded "/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media/Images/a.jpg"'
# "Cached" inside an ordinary user folder name must not trigger the cache rule.
assert_false "keep: folder merely containing the word cache" \
  'photo_is_excluded "/storage/emulated/0/Pictures/Cached Memories/a.jpg"'

# --- photo_has_media_extension ---------------------------------------------

assert_true  "ext: jpg"            'photo_has_media_extension "/x/a.jpg"'
assert_true  "ext: uppercase JPG"  'photo_has_media_extension "/x/a.JPG"'
assert_true  "ext: heic"           'photo_has_media_extension "/x/a.heic"'
assert_true  "ext: dng raw"        'photo_has_media_extension "/x/a.dng"'
assert_true  "ext: mp4 video"      'photo_has_media_extension "/x/a.mp4"'
assert_false "ext: pdf is not media" 'photo_has_media_extension "/x/a.pdf"'
assert_false "ext: no extension"     'photo_has_media_extension "/x/a"'
# A file whose NAME contains .jpg but ends differently must not be swept in.
assert_false "ext: .jpg.txt is not media" 'photo_has_media_extension "/x/a.jpg.txt"'

# --- photo_merge_index -----------------------------------------------------

a=$(printf '/sdcard/DCIM/a.jpg\n/sdcard/DCIM/b.jpg\n')
b=$(printf '/storage/emulated/0/DCIM/b.jpg\n/storage/emulated/0/DCIM/c.jpg\n')
out=$(photo_merge_index <(printf '%s\n' "$a") <(printf '%s\n' "$b"))
# b.jpg appears in both sources under two spellings and must appear once.
assert_eq "merge: unions and dedupes across spellings" \
  "/storage/emulated/0/DCIM/a.jpg
/storage/emulated/0/DCIM/b.jpg
/storage/emulated/0/DCIM/c.jpg" "$out"

out=$(photo_merge_index <(printf '/sdcard/DCIM/.thumbnails/t.jpg\n/sdcard/DCIM/a.jpg\n') <(printf ''))
assert_eq "merge: applies exclusions" "/storage/emulated/0/DCIM/a.jpg" "$out"

out=$(photo_merge_index <(printf '/sdcard/Download/notes.pdf\n/sdcard/DCIM/a.jpg\n') <(printf ''))
assert_eq "merge: drops non-media extensions" "/storage/emulated/0/DCIM/a.jpg" "$out"

out=$(photo_merge_index <(printf '') <(printf ''))
assert_eq "merge: two empty sources yield nothing" "" "$out"

# --- photo_local_target ----------------------------------------------------

assert_eq "target: mirrors the device tree under the root" \
  "/bk/photos/storage/emulated/0/DCIM/a.jpg" \
  "$(photo_local_target /bk/photos /storage/emulated/0/DCIM/a.jpg)"
assert_eq "target: keeps a removable card on its own path" \
  "/bk/photos/storage/1A2B-3C4D/DCIM/a.jpg" \
  "$(photo_local_target /bk/photos /storage/1A2B-3C4D/DCIM/a.jpg)"

# ---------------------------------------------------------------------------

if [ "$FAILURES" -eq 0 ]; then
  printf 'photo_index: %d assertions passed\n' "$TESTS"
else
  printf 'photo_index: %d of %d assertions FAILED\n' "$FAILURES" "$TESTS" >&2
  exit 1
fi
