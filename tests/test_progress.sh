#!/usr/bin/env bash
# SCRIPT: test_progress.sh
# DESCRIPTION: One gauge for a whole run, and it never costs the caller its counters.
# USAGE: bash tests/test_progress.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

checks=0
fail() { printf 'FAIL: %s\n%s\n' "$1" "${2:-}" >&2; exit 1; }
pass() { checks=$((checks + 1)); }

mkdir -p "$WORK/bin"
# A dialog that behaves like --gauge: read stdin until it closes, keep it all.
cat >"$WORK/bin/dialog" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$WORK/gauge_args.txt"
cat >>"$WORK/gauge_stdin.txt"
EOF
chmod +x "$WORK/bin/dialog"
: >"$WORK/gauge_args.txt"
: >"$WORK/gauge_stdin.txt"

run_session() {
  PATH="$WORK/bin:$PATH" ANDROID_RESCUE_PROGRESS="$1" bash -c '
    source "'"$ROOT"'/tools/lib/common.sh"
    source "'"$ROOT"'/tools/lib/progress.sh"
    copied=0
    progress_session_begin "Photo and video rescue"
    progress_phase "Discovering photos through MediaStore..." 2
    progress_phase "Sweeping the filesystem..." 8
    progress_note "MediaStore: 1532, sweep: 9461, unique after merge: 4"
    progress_task "Copying photos and videos" 4 20 55
    for f in a b c d; do copied=$((copied + 1)); progress_step "/storage/emulated/0/DCIM/$f.jpg"; done
    progress_warn "1 file(s) failed; retry 1 of 2"
    progress_session_end
    printf "copied=%s\n" "$copied"
  ' 2>&1
}

# --- the gauge path --------------------------------------------------------
#
#     The counter assertion is the point of the whole file. `loop | dialog`
#     would run the loop in a subshell, so copied would read 0 here while every
#     file had in fact been copied -- and the number this tool reports at the
#     end is what someone wipes a phone on the strength of.

out="$(run_session always)" || fail 'gauge run exits 0' "$out"
grep -Fq 'copied=4' <<<"$out" || fail 'the caller keeps its counters' "$out"
pass

# One dialog for the whole run, not one per phase. Before this, discovery
# printed plain lines and only the copy got a bar, so the display changed shape
# twice mid-rescue.
started="$(grep -c -- '--gauge' "$WORK/gauge_args.txt")"
[ "$started" -eq 1 ] || fail "expected exactly one gauge for the session, got $started"
pass

# Every phase reached the open gauge rather than the terminal.
for needle in 'Discovering photos through MediaStore...' 'Sweeping the filesystem...' \
              'Copying photos and videos' 'MediaStore: 1532'; do
  grep -Fq "$needle" "$WORK/gauge_stdin.txt" || fail "phase reached the gauge: $needle" "$(cat "$WORK/gauge_stdin.txt")"
done
pass

# The bar only moves forwards, and a counted task lands inside its own band.
grep -Fxq '2' "$WORK/gauge_stdin.txt" || fail 'discovery sits at its percentage'
grep -Fxq '75' "$WORK/gauge_stdin.txt" || fail 'a full task reaches base + span (20 + 55)'
grep -Fq '4 of 4' "$WORK/gauge_stdin.txt" || fail 'the count is shown'
grep -Fq 'd.jpg' "$WORK/gauge_stdin.txt" || fail 'the file in flight is named'
pass

# Notes and warnings cannot be printed while the gauge owns the terminal, so
# they are repeated once it comes down. Otherwise the discovery counts would
# exist only in the report.
grep -Fq 'MediaStore: 1532, sweep: 9461' <<<"$out" || fail 'notes are replayed after the gauge' "$out"
grep -Fq '1 file(s) failed' <<<"$out" || fail 'warnings are replayed after the gauge' "$out"
pass

# Nothing may be printed to the terminal while it is open.
before_end="${out%%MediaStore: 1532*}"
grep -Fq 'Discovering photos' <<<"$before_end" && fail 'a phase was printed while the gauge was up' "$out"
pass

# Every FIFO it made must be gone.
leaked="$(find /tmp -maxdepth 1 -type p -newer "$WORK/gauge_args.txt" 2>/dev/null | wc -l)"
[ "$leaked" -eq 0 ] || fail "the gauge left $leaked FIFO(s) behind"
pass

# --- the fallback ----------------------------------------------------------

out="$(run_session never)" || fail 'fallback run exits 0' "$out"
grep -Fq 'copied=4' <<<"$out" || fail 'counters survive the fallback too' "$out"
grep -Fq 'Discovering photos through MediaStore' <<<"$out" || fail 'phases still print' "$out"
grep -Fq 'MediaStore: 1532' <<<"$out" || fail 'notes still print' "$out"
pass

# With no dialog on PATH at all, auto must not try to draw one.
out="$(env PATH="/usr/bin:/bin" ANDROID_RESCUE_PROGRESS=auto bash -c '
  source "'"$ROOT"'/tools/lib/common.sh"
  source "'"$ROOT"'/tools/lib/progress.sh"
  progress_session_begin "Rescue"
  progress_task "Copying" 2 0 100
  progress_step one; progress_step two
  progress_session_end
  printf "ok\n"
' 2>&1)" || fail 'no-dialog run exits 0' "$out"
grep -Fq 'ok' <<<"$out" || fail 'it completes without dialog' "$out"
pass

# A zero-item task must not divide by zero.
out="$(PATH="$WORK/bin:$PATH" ANDROID_RESCUE_PROGRESS=always bash -c '
  source "'"$ROOT"'/tools/lib/common.sh"
  source "'"$ROOT"'/tools/lib/progress.sh"
  progress_session_begin "Rescue"
  progress_task "Copying" 0 0 100
  progress_session_end
  printf "ok\n"
' 2>&1)" || fail 'zero-item run exits 0' "$out"
grep -Fq 'ok' <<<"$out" || fail 'zero items is handled' "$out"
pass

# Long device paths are shortened from the left: the tail identifies the file.
out="$(bash -c '
  source "'"$ROOT"'/tools/lib/progress.sh"
  progress_shorten "/storage/emulated/0/DCIM/Camera/a-very-long-name-that-keeps-going-IMG_20260921.jpg" 40
')"
[ "${#out}" -le 40 ] || fail "shortened text is ${#out} chars, wanted <= 40"
case "$out" in
  ...*IMG_20260921.jpg) ;;
  *) fail "shortening must keep the tail, got: $out" ;;
esac
pass

printf 'progress: %s checks passed\n' "$checks"
