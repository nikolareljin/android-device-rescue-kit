#!/usr/bin/env bash
# SCRIPT: test_analysis_prompt.sh
# DESCRIPTION: The analysis prompt is private, and never written through a symlink.
# USAGE: bash tests/test_analysis_prompt.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

checks=0
fail() { printf 'FAIL: %s\n%s\n' "$1" "${2:-}" >&2; exit 1; }
pass() { checks=$((checks + 1)); }

if ! command -v rg >/dev/null 2>&1; then
  printf 'analysis_prompt: skipped, ripgrep is not installed\n'
  exit 0
fi

BUILD="$ROOT/tools/build_analysis_prompt.sh"

# A capture with its report already present, so the builder does not shell out
# to the analyzer and no device is needed.
make_capture() {
  local dir="$1"
  mkdir -p "$dir"
  printf 'ro.serialno=R5CT40EXAMPLE\n' >"$dir/getprop.txt"
  printf 'triage report\nreboot reason: watchdog\n' >"$dir/analysis_report.txt"
}

mode_of() {
  # %a is GNU stat; BSD stat spells it differently, so fall back.
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# Default output, inside the capture directory.
make_capture "$WORK/cap"
out="$(bash "$BUILD" "$WORK/cap" 2>&1)" || fail 'builder exits 0' "$out"
prompt="$WORK/cap/analysis_prompt.md"
[ -f "$prompt" ] || fail 'the prompt is written' "$out"
pass

# The prompt carries device serials, Wi-Fi identifiers and the app inventory.
# On a shared machine it must not be readable by other local users.
mode="$(mode_of "$prompt")"
[ "$mode" = 600 ] || fail "the default prompt must be mode 600, got $mode"
pass

# An explicit output path gets the same treatment. This is the one the old
# documentation pointed at /tmp, where any local user could read it.
make_capture "$WORK/cap2"
out="$(bash "$BUILD" "$WORK/cap2" "$WORK/chosen-prompt.md" 2>&1)" \
  || fail 'builder exits 0 with an explicit path' "$out"
[ -f "$WORK/chosen-prompt.md" ] || fail 'the chosen path is written' "$out"
mode="$(mode_of "$WORK/chosen-prompt.md")"
[ "$mode" = 600 ] || fail "an explicit output path must be mode 600, got $mode"
pass

# Content is really there: a private file that is empty proves nothing.
grep -q 'watchdog' "$WORK/chosen-prompt.md" || fail 'the prompt contains the report'
pass

# A symlink already at the output path would redirect the write somewhere the
# caller did not choose.
make_capture "$WORK/cap3"
printf 'untouched\n' >"$WORK/victim.md"
ln -s "$WORK/victim.md" "$WORK/link-prompt.md"
out="$(bash "$BUILD" "$WORK/cap3" "$WORK/link-prompt.md" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail 'writing through a symlink must fail' "$out"
grep -Fq 'symlink' <<<"$out" || fail 'it must say why' "$out"
grep -Fxq 'untouched' "$WORK/victim.md" || fail 'the symlink target must be untouched'
pass

printf 'analysis_prompt: %s checks passed\n' "$checks"
