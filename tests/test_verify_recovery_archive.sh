#!/usr/bin/env bash
# SCRIPT: test_verify_recovery_archive.sh
# DESCRIPTION: Tests for verify_recovery_archive.sh using real gpg and tar.
# USAGE: bash tests/test_verify_recovery_archive.sh
# EXAMPLE: bash tests/test_verify_recovery_archive.sh
#
# No device is involved: the readable profile is an ordinary directory and the
# archive is made the same way the backup makes it. That covers the whole point
# of keeping both copies -- being able to prove they agree -- including the
# cases where they do not.
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

if ! command -v gpg >/dev/null 2>&1; then
  printf 'verify_recovery_archive: SKIPPED (gpg not installed)\n'
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS="test-passphrase"

build_profile() {
  local root="$1"
  rm -rf "$root"
  mkdir -p "$root/recovery_profile/imports"
  printf 'ssid-and-psk\n'      >"$root/recovery_profile/networks.txt"
  printf 'android_id=abc\n'    >"$root/recovery_profile/settings_secure.txt"
  printf 'user,pass\na,b\n'    >"$root/recovery_profile/imports/passwords.csv"
}

make_archive() {
  local root="$1"
  tar -C "$root" -cf - recovery_profile \
    | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 3 \
        --symmetric --cipher-algo AES256 --output "$root/recovery-profile.tar.gpg" 3<<<"$PASS"
}

run_verify() {
  ( cd "$ROOT" && bash tools/verify_recovery_archive.sh "$1" --passphrase-fd 3 3<<<"$PASS" \
      >"$WORK/out.txt" 2>&1 )
  printf '%s' "$?"
}

# --- 1. both copies present and agreeing ----------------------------------

BK="$WORK/ok"
build_profile "$BK"
make_archive "$BK"
rc=$(run_verify "$BK")
check "matching copies verify" "0" "$rc"
check "says both agree" "1" "$(grep -c 'Both copies agree' "$WORK/out.txt")"
check "counts all three files" "1" "$(grep -c '3 file(s)' "$WORK/out.txt")"

# --- 2. a file added to the readable tree after the archive was made ------
#        This is the real-world case: the archive is stale.

BK="$WORK/extra"
build_profile "$BK"
make_archive "$BK"
printf 'added-later\n' >"$BK/recovery_profile/bluetooth.txt"
rc=$(run_verify "$BK")
check "a file missing from the archive FAILS" "1" "$rc"
check "says they disagree" "1" "$(grep -c 'DISAGREE' "$WORK/out.txt")"
check "names the file that is only on disk" "1" \
  "$(grep -c 'bluetooth.txt' "$WORK/out.txt")"

# --- 3. a file changed size after the archive was made --------------------
#        Catches a truncated or edited copy, not just a missing one.

BK="$WORK/resized"
build_profile "$BK"
make_archive "$BK"
printf 'ssid-and-psk-plus-much-more-content\n' >"$BK/recovery_profile/networks.txt"
rc=$(run_verify "$BK")
check "a size change FAILS" "1" "$rc"
# Two lines, not one: a size change shows on both sides of the diff -- the size
# on disk and the size in the archive -- which is what makes it diagnosable.
check "names the resized file on both sides" "2" "$(grep -c 'networks.txt' "$WORK/out.txt")"

# --- 4. the readable copy is gone ------------------------------------------

BK="$WORK/noplain"
build_profile "$BK"
make_archive "$BK"
rm -rf "$BK/recovery_profile"
rc=$(run_verify "$BK")
check "missing readable profile FAILS" "1" "$rc"
check "says both must exist" "1" "$(grep -c 'Both copies must exist' "$WORK/out.txt")"

# --- 5. the archive is gone ------------------------------------------------

BK="$WORK/noarchive"
build_profile "$BK"
rc=$(run_verify "$BK")
check "missing archive FAILS" "1" "$rc"
check "names the absent archive" "1" "$(grep -c 'No encrypted archive' "$WORK/out.txt")"

# --- 6. wrong passphrase ---------------------------------------------------

BK="$WORK/badpass"
build_profile "$BK"
make_archive "$BK"
rc=$( ( cd "$ROOT" && bash tools/verify_recovery_archive.sh "$BK" --passphrase-fd 3 3<<<"wrong" \
        >"$WORK/out.txt" 2>&1 ); printf '%s' "$?" )
check "wrong passphrase FAILS" "1" "$rc"
check "says it could not decrypt" "1" "$(grep -c 'Could not decrypt' "$WORK/out.txt")"

# --- 7. a damaged archive --------------------------------------------------

BK="$WORK/corrupt"
build_profile "$BK"
make_archive "$BK"
printf 'garbage' | dd of="$BK/recovery-profile.tar.gpg" bs=1 seek=40 conv=notrunc status=none
rc=$(run_verify "$BK")
check "a damaged archive FAILS" "1" "$rc"

# ---------------------------------------------------------------------------

if [ "$FAILURES" -eq 0 ]; then
  printf 'verify_recovery_archive: %d checks passed\n' "$TESTS"
else
  printf 'verify_recovery_archive: %d of %d checks FAILED\n' "$FAILURES" "$TESTS" >&2
  exit 1
fi
