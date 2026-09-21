#!/usr/bin/env bash
# SCRIPT: verify_recovery_archive.sh
# DESCRIPTION: Prove the encrypted recovery archive matches the readable profile.
# USAGE: tools/verify_recovery_archive.sh <backup-root> [--passphrase-fd N]
# PARAMETERS:
#   <backup-root>       Directory holding recovery_profile/ and recovery-profile.tar.gpg
#   --passphrase-fd N   Read the passphrase from this file descriptor instead of prompting.
# EXAMPLE: tools/verify_recovery_archive.sh backups/20260920-120000
#
# Both copies are kept by default, which is only useful if you can confirm they
# say the same thing. This decrypts the archive and compares its file list and
# per-file sizes against the readable tree.
#
# Exit status: 0 when every file in the readable profile is present in the
# archive at the same size. Non-zero otherwise, naming what differs.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

BACKUP_ROOT="${1:-}"
shift || true
PASSPHRASE_FD=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --passphrase-fd) PASSPHRASE_FD="${2:-}"; shift ;;
    *) print_error "Unknown option: $1"; exit 2 ;;
  esac
  shift
done

if [ -z "$BACKUP_ROOT" ]; then
  printf 'Usage: %s <backup-root> [--passphrase-fd N]\n' "${ANDROID_RESCUE_CMD:-tools/verify_recovery_archive.sh}" >&2
  exit 2
fi

PROFILE_DIR="$BACKUP_ROOT/recovery_profile"
ARCHIVE="$BACKUP_ROOT/recovery-profile.tar.gpg"

missing=0
[ -d "$PROFILE_DIR" ] || { print_error "No readable profile at $PROFILE_DIR"; missing=1; }
[ -f "$ARCHIVE" ] || { print_error "No encrypted archive at $ARCHIVE"; missing=1; }
if [ "$missing" -ne 0 ]; then
  print_error "Both copies must exist to compare them."
  exit 1
fi

require_tool gpg || exit 1
require_tool tar || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ -n "$PASSPHRASE_FD" ]; then
  gpg --batch --quiet --pinentry-mode loopback --passphrase-fd "$PASSPHRASE_FD" \
    --decrypt "$ARCHIVE" 2>/dev/null >"$WORK/archive.tar"
else
  gpg --quiet --decrypt "$ARCHIVE" 2>/dev/null >"$WORK/archive.tar"
fi
if [ ! -s "$WORK/archive.tar" ]; then
  print_error "Could not decrypt $ARCHIVE (wrong passphrase, or the archive is damaged)."
  exit 1
fi

# size<TAB>path, relative to the profile directory, for both sides.
tar -tvf "$WORK/archive.tar" 2>/dev/null \
  | awk '$1 !~ /^d/ { size=$3; path=$NF; sub(/^recovery_profile\//, "", path); if (path != "") print size "\t" path }' \
  | LC_ALL=C sort >"$WORK/in_archive.txt"

# A read loop rather than `xargs -I{} sh -c`: interpolating a filename into a
# shell string breaks on quotes and spaces and would run whatever a filename
# contained.
# No `find -printf` and no `sed -z`: both are GNU-only and this repository
# supports macOS, whose find is BSD. The leading ./ is stripped in the loop.
while IFS= read -r -d '' f; do
  f="${f#./}"
  [ -n "$f" ] || continue
  printf '%s\t%s\n' "$(wc -c <"$PROFILE_DIR/$f" | tr -d ' ')" "$f"
done < <(cd "$PROFILE_DIR" && find . -type f -print0) \
  | LC_ALL=C sort >"$WORK/on_disk.txt"

archive_n=$(wc -l <"$WORK/in_archive.txt" | tr -d ' ')
disk_n=$(wc -l <"$WORK/on_disk.txt" | tr -d ' ')

if diff -u "$WORK/on_disk.txt" "$WORK/in_archive.txt" >"$WORK/diff.txt" 2>&1; then
  print_success "Both copies agree: $disk_n file(s), identical sizes."
  printf '  readable:  %s\n' "$PROFILE_DIR"
  printf '  encrypted: %s\n' "$ARCHIVE"
  exit 0
fi

print_error "The readable profile and the encrypted archive DISAGREE."
printf '  readable profile : %s file(s)\n' "$disk_n"
printf '  encrypted archive: %s file(s)\n' "$archive_n"
printf '\n  -  only on disk / different size\n  +  only in archive / different size\n\n'
grep -E '^[+-][^+-]' "$WORK/diff.txt" | head -40
exit 1
