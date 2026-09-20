#!/usr/bin/env bash
# SCRIPT: photo_index.sh
# DESCRIPTION: Pure functions for building the index of photos to back up.
# USAGE: source tools/lib/photo_index.sh
#
# Nothing here talks to a device. Every function takes text in and gives text
# out, which is what makes the discovery logic testable without a phone --
# see tests/test_photo_index.sh. The device-facing half lives in
# tools/android_photo_backup.sh.
#
# Paths are compared constantly (dedupe, resume, verify), so they are
# normalised to one spelling the moment they enter the pipeline. Android
# exposes primary storage under at least three names and MediaStore does not
# agree with `find` about which to use.

PHOTO_INDEX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PHOTO_EXTENSIONS_FILE="${PHOTO_EXTENSIONS_FILE:-$PHOTO_INDEX_ROOT/config/photo_extensions.txt}"
PHOTO_EXCLUDE_FILE="${PHOTO_EXCLUDE_FILE:-$PHOTO_INDEX_ROOT/config/photo_exclude_patterns.txt}"

# Read a config list, dropping comments and blanks.
photo_read_list() {
  local file="$1"
  [ -f "$file" ] || return 0
  sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$file"
}

# The lists are read once and cached.
#
# They used to be re-read inside the per-path predicates, which meant a sed in a
# process substitution for every file twice over. On a real phone with ~11,000
# candidate paths that was about 22,000 subshells and over two minutes; caching
# makes it seconds. Indexed arrays and no ${var,,}, so this still runs on the
# bash 3.2 that macOS ships.
#
# The cache is keyed on the file it was read from, so pointing
# PHOTO_EXTENSIONS_FILE or PHOTO_EXCLUDE_FILE somewhere else reloads by itself.
# A separate "reset the cache" function would be one more thing a caller has to
# remember, and forgetting it would mean silently filtering against the wrong
# list.
_PHOTO_EXT_CACHED_FROM=""
_PHOTO_EXC_CACHED_FROM=""
_PHOTO_EXT_LIST=""
_PHOTO_EXC_PATTERNS=()

_photo_load_extensions() {
  [ "$_PHOTO_EXT_CACHED_FROM" = "$PHOTO_EXTENSIONS_FILE" ] && return 0
  local e
  _PHOTO_EXT_LIST=" "
  while IFS= read -r e; do
    [ -n "$e" ] && _PHOTO_EXT_LIST="$_PHOTO_EXT_LIST$e "
  done < <(photo_read_list "$PHOTO_EXTENSIONS_FILE")
  _PHOTO_EXT_CACHED_FROM="$PHOTO_EXTENSIONS_FILE"
}

_photo_load_exclusions() {
  [ "$_PHOTO_EXC_CACHED_FROM" = "$PHOTO_EXCLUDE_FILE" ] && return 0
  local pat
  _PHOTO_EXC_PATTERNS=()
  while IFS= read -r pat; do
    [ -n "$pat" ] && _PHOTO_EXC_PATTERNS+=("$pat")
  done < <(photo_read_list "$PHOTO_EXCLUDE_FILE")
  _PHOTO_EXC_CACHED_FROM="$PHOTO_EXCLUDE_FILE"
}

# /sdcard and /storage/self/primary are the same volume as
# /storage/emulated/0. A removable card (/storage/1A2B-3C4D) is a different
# volume and must keep its own path, or its files collide with identically
# named files in internal storage.
photo_normalize_path() {
  local p="$1"
  p="${p%$'\r'}"
  case "$p" in
    /sdcard/*) p="/storage/emulated/0/${p#/sdcard/}" ;;
    /sdcard) p="/storage/emulated/0" ;;
    /storage/self/primary/*) p="/storage/emulated/0/${p#/storage/self/primary/}" ;;
    /mnt/sdcard/*) p="/storage/emulated/0/${p#/mnt/sdcard/}" ;;
  esac
  printf '%s\n' "$p"
}

# `content query` prints one "Row: N col=value, col=value" line per record.
# The path is whatever follows _data=, up to a comma that separates columns or
# the end of the line. Filenames contain spaces routinely, so the value is not
# whitespace-delimited.
photo_parse_mediastore() {
  local line path
  while IFS= read -r line; do
    line="${line%$'\r'}"
    case "$line" in
      *_data=*) ;;
      *) continue ;;
    esac
    path="${line#*_data=}"
    # Stop at a column separator if more columns were projected.
    case "$path" in
      *", "*) path="${path%%, *}" ;;
    esac
    [ -n "$path" ] || continue
    photo_normalize_path "$path"
  done
}

# `find` prints one path per line. Kept as its own function so the caller reads
# symmetrically and so CR stripping happens in exactly one place per source.
photo_parse_find() {
  local line
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [ -n "$line" ] || continue
    case "$line" in
      /*) photo_normalize_path "$line" ;;
    esac
  done
}

# Extension test against config/photo_extensions.txt, matched case-insensitively
# on the final component only -- "a.jpg.txt" is a text file, not a photo.
photo_has_media_extension() {
  local p="$1" base ext
  base="${p##*/}"
  case "$base" in
    *.*) ext="${base##*.}" ;;
    *) return 1 ;;
  esac
  _photo_load_extensions
  # nocasematch rather than `tr`: a subshell per path cost over a minute on a
  # phone with ~11,000 candidates. bash 3.2 has no ${var,,}, so this is the
  # portable way to compare without forking. The previous setting is restored,
  # so callers are not left with a changed shell option.
  local had_nocase=0 rc=1 known
  shopt -q nocasematch && had_nocase=1
  [ "$had_nocase" -eq 1 ] || shopt -s nocasematch
  for known in $_PHOTO_EXT_LIST; do
    if [[ "$ext" == "$known" ]]; then rc=0; break; fi
  done
  [ "$had_nocase" -eq 1 ] || shopt -u nocasematch
  return "$rc"
}

# Glob patterns from config/photo_exclude_patterns.txt. These remove machine
# artefacts -- thumbnails, caches, trashed files -- never user content.
photo_is_excluded() {
  local p="$1" pattern
  _photo_load_exclusions
  for pattern in ${_PHOTO_EXC_PATTERNS+"${_PHOTO_EXC_PATTERNS[@]}"}; do
    # shellcheck disable=SC2254  # the pattern is a glob on purpose
    case "$p" in
      $pattern) return 0 ;;
    esac
  done
  return 1
}

# Union of the given files, normalised, filtered and deduplicated.
#
# The union is the point: MediaStore knows about files whose directory `find`
# cannot enter, and `find` sees files copied in over USB that MediaStore has
# not indexed yet. Either source alone loses photos.
photo_merge_index() {
  local f
  {
    for f in "$@"; do
      [ -e "$f" ] || continue
      photo_parse_find <"$f"
    done
  } | while IFS= read -r p; do
        photo_has_media_extension "$p" || continue
        photo_is_excluded "$p" && continue
        printf '%s\n' "$p"
      done | LC_ALL=C sort -u
}

# Where a device path lands locally. The device tree is mirrored rather than
# flattened: ~10k files would collide on basename alone, and a mirrored tree
# makes the restore side obvious and the diff against the device readable.
photo_local_target() {
  local root="$1" device_path="$2"
  printf '%s/%s\n' "${root%/}" "${device_path#/}"
}

# Quote a path for a command string that will be run by a shell on the device.
#
# `adb shell` does not pass argv through -- it joins its arguments with spaces
# and hands the result to a shell on the phone. So every path has to arrive
# already quoted, or a name containing a space becomes two arguments and a
# format string containing `|` becomes a pipe.
photo_shell_quote() {
  local s="$1"
  # One substitution rather than a character loop: the loop cost about 10
  # seconds across the 5,399 paths on a real phone. Each embedded single quote
  # becomes '\'' -- close, escape, reopen.
  printf "'%s'" "${s//\'/\'\\\'\'}"
}
