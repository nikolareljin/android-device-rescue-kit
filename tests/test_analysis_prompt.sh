#!/usr/bin/env bash
# SCRIPT: test_analysis_prompt.sh
# DESCRIPTION: The analysis prompt is private, and never written through a symlink.
# USAGE: bash tests/test_analysis_prompt.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/test_env.sh
source "$ROOT/tests/lib/test_env.sh"
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
  printf 'ro.serialno=%s\n' "$TEST_SERIAL" >"$dir/getprop.txt"
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

# The umask used to create the prompt must not reach the analyzer this script
# shells out to. Left set, analysis_report.txt came out 600 here and 664 when
# `adrescue log` produced it: the same file with two modes depending on the
# path taken.
mkdir -p "$WORK/lazy"
printf 'ro.serialno=%s\n' "$TEST_SERIAL" >"$WORK/lazy/getprop.txt"
bash "$BUILD" "$WORK/lazy" >/dev/null 2>&1
mkdir -p "$WORK/direct"
printf 'ro.serialno=%s\n' "$TEST_SERIAL" >"$WORK/direct/getprop.txt"
bash "$ROOT/tools/analyze_android_capture.sh" "$WORK/direct" >/dev/null 2>&1
lazy_mode="$(mode_of "$WORK/lazy/analysis_report.txt")"
direct_mode="$(mode_of "$WORK/direct/analysis_report.txt")"
[ "$lazy_mode" = "$direct_mode" ] \
  || fail "analysis_report.txt mode depends on who wrote it: $lazy_mode vs $direct_mode"
[ "$(mode_of "$WORK/lazy/analysis_prompt.md")" = 600 ] \
  || fail 'the prompt is still 600 when the report is generated lazily'
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
