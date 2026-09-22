#!/usr/bin/env bash
# SCRIPT: test_progress.sh
# DESCRIPTION: The gauge feeds dialog correctly and never costs the caller its counters.
# USAGE: bash tests/test_progress.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

checks=0
fail() { printf 'FAIL: %s\n%s\n' "$1" "${2:-}" >&2; exit 1; }
pass() { checks=$((checks + 1)); }

mkdir -p "$WORK/bin"
# A dialog that behaves like --gauge: read stdin until it closes, keep it.
cat >"$WORK/bin/dialog" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$WORK/gauge_args.txt"
cat >>"$WORK/gauge_stdin.txt"
EOF
chmod +x "$WORK/bin/dialog"
: >"$WORK/gauge_args.txt"
: >"$WORK/gauge_stdin.txt"

# --- the gauge path --------------------------------------------------------
#
#     The counter assertion is the point of the whole file. `loop | dialog`
#     would run the loop in a subshell, so `copied` would read 0 here while
#     every file had in fact been copied -- and the photo backup's entire
#     contract is the number it reports at the end.

out="$(PATH="$WORK/bin:$PATH" ANDROID_RESCUE_PROGRESS=always bash -c '
  source "'"$ROOT"'/tools/lib/common.sh"
  source "'"$ROOT"'/tools/lib/progress.sh"
  copied=0
  progress_begin "Copying" 4
  for f in a b c d; do copied=$((copied + 1)); progress_step "/storage/emulated/0/DCIM/$f.jpg"; done
  progress_end
  printf "copied=%s\n" "$copied"
' 2>&1)" || fail 'gauge run exits 0' "$out"

grep -Fq 'copied=4' <<<"$out" || fail 'the caller keeps its counters' "$out"
pass

grep -Fq -- '--gauge' "$WORK/gauge_args.txt" || fail 'dialog was invoked as a gauge' "$(cat "$WORK/gauge_args.txt")"
pass

# dialog --gauge reads XXX-delimited blocks: percentage, then message lines.
grep -Fxq 'XXX' "$WORK/gauge_stdin.txt" || fail 'gauge blocks were written' "$(cat "$WORK/gauge_stdin.txt")"
grep -Fxq '100' "$WORK/gauge_stdin.txt" || fail 'it reaches 100 percent' "$(cat "$WORK/gauge_stdin.txt")"
grep -Fxq '4 of 4' "$WORK/gauge_stdin.txt" || fail 'it reports the count' "$(cat "$WORK/gauge_stdin.txt")"
grep -Fq 'd.jpg' "$WORK/gauge_stdin.txt" || fail 'it names the current file' "$(cat "$WORK/gauge_stdin.txt")"
pass

# Every FIFO it made must be gone: these are created with mktemp -u in /tmp.
leaked="$(find /tmp -maxdepth 1 -type p -newer "$WORK/gauge_args.txt" 2>/dev/null | wc -l)"
[ "$leaked" -eq 0 ] || fail "the gauge left $leaked FIFO(s) behind"
pass

# --- the fallback ----------------------------------------------------------

out="$(PATH="$WORK/bin:$PATH" ANDROID_RESCUE_PROGRESS=never bash -c '
  source "'"$ROOT"'/tools/lib/common.sh"
  source "'"$ROOT"'/tools/lib/progress.sh"
  n=0
  progress_begin "Copying" 500
  i=0; while [ $i -lt 500 ]; do n=$((n + 1)); progress_step "f$i"; i=$((i + 1)); done
  progress_end
  printf "n=%s\n" "$n"
' 2>&1)" || fail 'fallback run exits 0' "$out"
grep -Fq 'n=500' <<<"$out" || fail 'counters survive the fallback too' "$out"
grep -Fq '250 / 500' <<<"$out" || fail 'the fallback still prints periodic progress' "$out"
pass

# With no dialog on PATH at all, auto must not try to draw one.
out="$(env PATH="/usr/bin:/bin" ANDROID_RESCUE_PROGRESS=auto bash -c '
  source "'"$ROOT"'/tools/lib/common.sh"
  source "'"$ROOT"'/tools/lib/progress.sh"
  progress_begin "Copying" 2
  progress_step one; progress_step two
  progress_end
  printf "ok\n"
' 2>&1)" || fail 'no-dialog run exits 0' "$out"
grep -Fq 'ok' <<<"$out" || fail 'it completes without dialog' "$out"
pass

# A zero-item run must not draw a bar or divide by zero.
out="$(PATH="$WORK/bin:$PATH" ANDROID_RESCUE_PROGRESS=always bash -c '
  source "'"$ROOT"'/tools/lib/common.sh"
  source "'"$ROOT"'/tools/lib/progress.sh"
  progress_begin "Copying" 0
  progress_end
  printf "ok\n"
' 2>&1)" || fail 'zero-item run exits 0' "$out"
grep -Fq 'ok' <<<"$out" || fail 'zero items is handled' "$out"
pass

# Long device paths are shortened from the left: the tail identifies the file.
out="$(bash -c '
  source "'"$ROOT"'/tools/lib/progress.sh"
  progress_shorten "/storage/emulated/0/DCIM/Camera/a-very-long-file-name-that-keeps-going-and-going-IMG_20260921.jpg" 40
')"
[ "${#out}" -le 40 ] || fail "shortened text is ${#out} chars, wanted <= 40"
case "$out" in
  ...*IMG_20260921.jpg) ;;
  *) fail "shortening must keep the tail, got: $out" ;;
esac
pass

printf 'progress: %s checks passed\n' "$checks"
