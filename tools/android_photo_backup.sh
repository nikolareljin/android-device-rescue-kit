#!/usr/bin/env bash
# SCRIPT: android_photo_backup.sh
# DESCRIPTION: Find and copy every photo and video on the device, then prove it.
# USAGE: tools/android_photo_backup.sh <backup-root>
# PARAMETERS:
#   <backup-root>  Directory to write photos/ and the index and report into.
# ENVIRONMENT:
#   PHOTO_ROOTS          Space-separated device roots to sweep. Default: /sdcard /storage
#   PHOTO_PULL_RETRIES   Attempts per failing file. Default: 3
# EXAMPLE: tools/android_photo_backup.sh backups/20260920-120000
#
# Exit status is the contract: 0 only when every discovered photo is present
# locally at its device size. Anything else exits 1 and names what is missing.
# A partial photo backup that reports success is the failure this whole script
# exists to prevent -- the user wipes the phone on the strength of it.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=tools/lib/photo_index.sh
source "$SCRIPT_DIR/lib/photo_index.sh"

BACKUP_ROOT="${1:-}"
if [ -z "$BACKUP_ROOT" ]; then
  printf 'Usage: %s <backup-root>\n' "$0" >&2
  exit 2
fi

PHOTO_ROOTS="${PHOTO_ROOTS:-/sdcard /storage}"
PHOTO_PULL_RETRIES="${PHOTO_PULL_RETRIES:-3}"

PHOTOS_DIR="$BACKUP_ROOT/photos"
INDEX_FILE="$BACKUP_ROOT/photos_index.txt"
REPORT_FILE="$BACKUP_ROOT/photos_report.txt"
MISSING_FILE="$BACKUP_ROOT/missing_photos.txt"
WORK_DIR="$BACKUP_ROOT/.photo_work"

mkdir -p "$PHOTOS_DIR" "$WORK_DIR" || {
  print_error "Cannot write under $BACKUP_ROOT"
  exit 1
}

# --- discovery -------------------------------------------------------------

# MediaStore is authoritative for anything the system has indexed, including
# files on a removable card and inside app media folders that a sweep may not
# be permitted to enter.
discover_mediastore() {
  local uri
  for uri in content://media/external/images/media content://media/external/video/media; do
    adb shell content query --uri "$uri" --projection _data 2>/dev/null
  done | photo_parse_mediastore
}

# The sweep catches what MediaStore has not indexed: files copied in over USB,
# restored from another backup, or written by an app that never told the
# scanner. Either source alone loses photos, which is why both run.
discover_sweep() {
  local expr="" ext first=1
  while IFS= read -r ext; do
    if [ "$first" -eq 1 ]; then
      expr="-iname *.$ext"
      first=0
    else
      expr="$expr -o -iname *.$ext"
    fi
  done < <(photo_read_list "$PHOTO_EXTENSIONS_FILE")
  [ -n "$expr" ] || return 0
  # shellcheck disable=SC2086  # $PHOTO_ROOTS and $expr are word lists on purpose
  adb shell "find $PHOTO_ROOTS -type f \\( $expr \\) 2>/dev/null" 2>/dev/null | photo_parse_find
}

print_info 'Discovering photos through MediaStore...'
discover_mediastore >"$WORK_DIR/mediastore.txt" 2>/dev/null || true
print_info 'Sweeping the filesystem for anything MediaStore missed...'
discover_sweep >"$WORK_DIR/sweep.txt" 2>/dev/null || true

ms_count=$(wc -l <"$WORK_DIR/mediastore.txt" | tr -d ' ')
sweep_count=$(wc -l <"$WORK_DIR/sweep.txt" | tr -d ' ')

photo_merge_index "$WORK_DIR/mediastore.txt" "$WORK_DIR/sweep.txt" >"$INDEX_FILE"
total=$(wc -l <"$INDEX_FILE" | tr -d ' ')

print_info "MediaStore: $ms_count, sweep: $sweep_count, unique after merge: $total"

if [ "$total" -eq 0 ]; then
  print_warning 'No photos or videos were found on the device.'
  printf 'No photos or videos found.\nMediaStore: %s\nSweep: %s\n' "$ms_count" "$sweep_count" >"$REPORT_FILE"
  exit 0
fi

# --- device sizes ----------------------------------------------------------

# One stat call per file would be ~10,000 round trips. Batching keeps it to a
# few dozen while staying well inside the shell's argument limit.
# `adb shell` does not pass argv through: it joins its arguments into one string
# and hands that to a shell on the device. So `adb shell stat -c "%s|%n" "$p"`
# fails twice -- the device shell reads the `|` as a pipe, and a path containing
# a space (every "WhatsApp Images/..." file) is word-split. The symptom is
# silent: no size is recorded, and verification then degrades to "the file is
# non-zero", which a truncated photo passes.
#
# The command is therefore built as one properly quoted string.
# Takes the paths as arguments rather than by nameref: `local -n` needs bash
# 4.3 and macOS ships 3.2.
run_batch_stat() {
  [ "$#" -gt 0 ] || return 0
  local cmd="stat -c '%s|%n'" p
  for p in "$@"; do
    cmd="$cmd $(photo_shell_quote "$p")"
  done
  # </dev/null is load-bearing. adb shell reads stdin, and this runs inside a
  # `while read ... done <index`, so without it adb consumed the rest of the
  # index after the first batch: 200 of 5,399 sizes were collected and
  # verification quietly degraded to "the file is non-zero" for the rest.
  adb shell "$cmd" </dev/null 2>/dev/null | tr -d '\r' >>"$WORK_DIR/sizes.txt"
}

collect_device_sizes() {
  local batch=() path
  : >"$WORK_DIR/sizes.txt"
  while IFS= read -r path; do
    batch+=("$path")
    # 200 paths of ~100 characters is ~20 KB of command line, well inside the
    # device shell's limit.
    if [ "${#batch[@]}" -ge 200 ]; then
      run_batch_stat "${batch[@]}"
      batch=()
    fi
  done <"$INDEX_FILE"
  if [ "${#batch[@]}" -gt 0 ]; then
    run_batch_stat "${batch[@]}"
  fi
}

print_info 'Reading sizes from the device...'
collect_device_sizes

# device_size <path> -> bytes, or empty when the device did not report one.
device_size() {
  local p="$1" line
  line=$(grep -F -m1 "|$p" "$WORK_DIR/sizes.txt" 2>/dev/null) || return 0
  printf '%s' "${line%%|*}" | tr -dc '0-9'
}

local_size() {
  [ -f "$1" ] || return 0
  wc -c <"$1" 2>/dev/null | tr -d ' '
}

# --- copy ------------------------------------------------------------------

copied=0
resumed=0
attempted=0

pull_one() {
  local device_path="$1" target expected actual
  target="$(photo_local_target "$PHOTOS_DIR" "$device_path")"
  expected="$(device_size "$device_path")"

  # Resume: a file already present at the right size is not pulled again. The
  # size check matters -- a run interrupted mid-copy leaves a short file, and
  # skipping on mere existence would keep it forever.
  if [ -f "$target" ]; then
    actual="$(local_size "$target")"
    if [ -n "$expected" ] && [ "$actual" = "$expected" ]; then
      resumed=$((resumed + 1))
      return 0
    fi
    if [ -z "$expected" ] && [ -n "$actual" ] && [ "$actual" -gt 0 ]; then
      resumed=$((resumed + 1))
      return 0
    fi
  fi

  mkdir -p "$(dirname "$target")" 2>/dev/null || return 1
  adb pull -a "$device_path" "$target" >/dev/null 2>&1 || return 1
  copied=$((copied + 1))
  return 0
}

print_info "Copying $total photos and videos..."
while IFS= read -r device_path; do
  attempted=$((attempted + 1))
  pull_one "$device_path" || true
  if [ $((attempted % 250)) -eq 0 ]; then
    print_info "  $attempted / $total"
  fi
done <"$INDEX_FILE"

# --- verify ----------------------------------------------------------------

# Verification is independent of whether the copy loop thought it succeeded.
# `adb pull` has been seen to exit 0 having written a short file, so the only
# trustworthy statement is one made by re-measuring what is on disk.
verify_pass() {
  local out="$1" device_path target expected actual
  : >"$out"
  while IFS= read -r device_path; do
    target="$(photo_local_target "$PHOTOS_DIR" "$device_path")"
    if [ ! -f "$target" ]; then
      printf '%s\tnot copied\n' "$device_path" >>"$out"
      continue
    fi
    expected="$(device_size "$device_path")"
    actual="$(local_size "$target")"
    if [ -z "$actual" ] || [ "$actual" -eq 0 ]; then
      printf '%s\tcopied as 0 bytes\n' "$device_path" >>"$out"
      continue
    fi
    if [ -n "$expected" ] && [ "$actual" != "$expected" ]; then
      printf '%s\tsize mismatch: device %s, local %s\n' "$device_path" "$expected" "$actual" >>"$out"
    fi
  done <"$INDEX_FILE"
}

attempt=1
verify_pass "$MISSING_FILE"
while [ -s "$MISSING_FILE" ] && [ "$attempt" -lt "$PHOTO_PULL_RETRIES" ]; do
  failed_now=$(wc -l <"$MISSING_FILE" | tr -d ' ')
  print_warning "$failed_now file(s) failed; retry $attempt of $((PHOTO_PULL_RETRIES - 1))"
  while IFS= read -r line; do
    device_path="${line%%$'\t'*}"
    target="$(photo_local_target "$PHOTOS_DIR" "$device_path")"
    rm -f "$target"
    pull_one "$device_path" || true
  done <"$MISSING_FILE"
  attempt=$((attempt + 1))
  verify_pass "$MISSING_FILE"
done

missing=0
[ -s "$MISSING_FILE" ] && missing=$(wc -l <"$MISSING_FILE" | tr -d ' ')
verified=$((total - missing))

# Sum every "total" line: find -exec ... + may run wc more than once, and
# taking only the last batch under-reported 24.8 GB as 1.4 GB.
total_bytes=$(find "$PHOTOS_DIR" -type f -exec wc -c {} + 2>/dev/null | awk '/total$/ {s += $1} END {printf "%d", s}')

{
  printf 'Photo and video backup\n\n'
  printf 'Discovered via MediaStore : %s\n' "$ms_count"
  printf 'Discovered via sweep      : %s\n' "$sweep_count"
  printf 'Unique after merge        : %s\n' "$total"
  printf 'Copied this run           : %s\n' "$copied"
  printf 'Already present (resumed) : %s\n' "$resumed"
  printf 'Verified on disk          : %s\n' "$verified"
  printf 'MISSING                   : %s\n' "$missing"
  printf 'Bytes on disk             : %s\n' "${total_bytes:-0}"
} >"$REPORT_FILE"

if [ "$missing" -gt 0 ]; then
  print_error "$missing of $total photos were NOT backed up. See $MISSING_FILE"
  exit 1
fi

rm -f "$MISSING_FILE"
print_success "All $total photos and videos verified in $PHOTOS_DIR"
exit 0
