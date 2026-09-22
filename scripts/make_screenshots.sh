#!/usr/bin/env bash
# SCRIPT: make_screenshots.sh
# DESCRIPTION: Screenshots of the real tools driven against an invented phone.
# USAGE: scripts/make_screenshots.sh [output-directory]
# EXAMPLE: scripts/make_screenshots.sh docs/assets/screenshots
#
# These are not mock-ups. The actual scripts run, drawing the actual dialog
# gauges, against a fake device built here: every file name, package and
# destination below is invented. Nothing from a real phone or a real disk can
# reach a screenshot taken this way, and because it is the real program, a
# screenshot cannot quietly drift away from what the tool does.
#
# Requires Xvfb, xterm and ImageMagick's import. Nothing is captured from the
# operator's own display.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-$ROOT/docs/assets/screenshots}"
DISPLAY_NUM="${SCREENSHOT_DISPLAY:-:97}"
# At font size 14 an xterm cell measures about 12x24 px, so the window must be
# sized against the virtual screen or it overflows it: 146 columns produced a
# 1756px window on a 1280px screen, and dialog then centred its box off the
# right-hand edge.
SCREEN="${SCREENSHOT_SCREEN:-1440x900}"
GEOMETRY="${SCREENSHOT_GEOMETRY:-116x36+0+0}"
FONT_SIZE="${SCREENSHOT_FONT_SIZE:-14}"

for tool in Xvfb xterm import; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'Missing %s. Install xvfb, xterm and imagemagick.\n' "$tool" >&2
    exit 1
  }
done

WORK="$(mktemp -d)"
# Destinations appear verbatim in the summary line, and a mktemp path there
# reads like someone's real disk half-redacted. This one is obviously a demo.
DEST_BASE="${SCREENSHOT_DEST:-/tmp/rescue-drive}"
# A synthetic home as well: `adrescue config` prints the path of its config
# file, and the operator's real username has no business in documentation.
DEMO_HOME="${SCREENSHOT_HOME:-/tmp/rescue-demo-home}"
rm -rf "$DEST_BASE" "$DEMO_HOME"
mkdir -p "$DEST_BASE" "$DEMO_HOME"
DEVICE="$WORK/device"
BIN="$WORK/bin"
mkdir -p "$OUT_DIR" "$BIN"

cleanup() {
  [ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null
  rm -rf "$WORK" "$DEST_BASE" "$DEMO_HOME"
}
trap cleanup EXIT

# --- an invented phone -----------------------------------------------------
#
# Names chosen to be obviously synthetic while still looking like a phone: a
# camera roll, a screenshot folder, a messaging app's media, a download.

make_file() { mkdir -p "$(dirname "$1")"; head -c "$2" /dev/urandom >"$1"; }

SD="$DEVICE/storage/emulated/0"
i=0
while [ "$i" -lt 48 ]; do
  printf -v stamp '2024%02d%02d_%02d%02d%02d' $(( (i % 12) + 1 )) $(( (i % 27) + 1 )) \
    $(( i % 24 )) $(( i % 60 )) $(( (i * 7) % 60 ))
  make_file "$SD/DCIM/Camera/IMG_$stamp.jpg" $(( 180000 + i * 4096 ))
  i=$((i + 1))
done
i=0
while [ "$i" -lt 9 ]; do
  printf -v stamp '2024%02d%02d_%02d%02d%02d' $(( (i % 12) + 1 )) $(( (i % 27) + 1 )) \
    $(( i % 24 )) $(( i % 60 )) $(( (i * 5) % 60 ))
  make_file "$SD/DCIM/Camera/VID_$stamp.mp4" $(( 2400000 + i * 65536 ))
  i=$((i + 1))
done
make_file "$SD/Pictures/Screenshots/Screenshot_2024-06-02-21-14-08.png" 240000
make_file "$SD/Pictures/Screenshots/Screenshot_2024-06-11-08-02-51.png" 198000
make_file "$SD/Movies/ScreenRecord/screen-20240614-183000.mp4" 5400000
make_file "$SD/Android/media/com.example.messenger/Media/Images/received-0417.jpg" 320000
make_file "$SD/Android/media/com.example.messenger/Media/Video/received-0418.mp4" 1800000
make_file "$SD/Download/receipt-2024-06-02.pdf" 88000
make_file "$SD/Download/timetable.pdf" 42000
i=0
while [ "$i" -lt 26 ]; do
  make_file "$SD/Download/attachment-$(printf '%02d' "$i").pdf" $(( 40000 + i * 2048 ))
  i=$((i + 1))
done
make_file "$SD/Documents/notes.txt" 3000

cat >"$BIN/adb" <<'MOCK'
#!/usr/bin/env bash
set -uo pipefail
DEVICE="${MOCK_DEVICE:?}"
SLOW="${MOCK_SLOW:-0}"

dev_to_local() {
  local p="$1"
  case "$p" in
    /sdcard/*) p="/storage/emulated/0/${p#/sdcard/}" ;;
    /sdcard) p="/storage/emulated/0" ;;
  esac
  printf '%s%s\n' "$DEVICE" "$p"
}

case "${1:-}" in
  devices)
    printf 'List of devices attached\n'
    printf 'FAKEPHONE0001\tdevice\n'
    exit 0 ;;
  start-server|wait-for-device|kill-server) exit 0 ;;
  pull)
    shift; [ "${1:-}" = "-a" ] && shift
    src="$1"; dst="$2"
    l="$(dev_to_local "$src")"
    [ -e "$l" ] || exit 1
    if [ -d "$l" ]; then
      mkdir -p "$dst"
      n=0; tot=$(find "$l" -type f | wc -l)
      find "$l" -type f | while IFS= read -r f; do
        rel="${f#"$l"/}"
        mkdir -p "$dst/$(dirname "$rel")"
        cp "$f" "$dst/$rel"
        n=$((n + 1))
        printf '[%3d%%] %s/%s\n' $(( n * 100 / (tot > 0 ? tot : 1) )) "$src" "$rel"
        [ "$SLOW" = 1 ] && sleep 0.20
      done
      exit 0
    fi
    mkdir -p "$(dirname "$dst")"
    cp "$l" "$dst" || exit 1
    [ "$SLOW" = 1 ] && sleep 0.25
    exit 0 ;;
  shell)
    shift
    if [ ! -t 0 ]; then timeout 0.2 cat >/dev/null 2>&1 || true; fi
    cmd="$*"
    set -- $cmd
    case "${1:-}" in
      content)
        uri=""
        while [ "$#" -gt 0 ]; do [ "$1" = "--uri" ] && uri="$2"; shift; done
        case "$uri" in
          *images*) pattern='\.(jpg|jpeg|png|heic|webp|gif)$' ;;
          *video*)  pattern='\.(mp4|3gp|mkv|mov|webm)$' ;;
          *) exit 0 ;;
        esac
        i=0
        find "$DEVICE" -type f 2>/dev/null | sed "s|^$DEVICE||" | grep -Ei "$pattern" | sort \
        | while IFS= read -r p; do
            printf 'Row: %s _data=%s\r\n' "$i" "$p"
            i=$((i + 1))
          done
        ;;
      stat)
        rest="${cmd#stat }"
        case "$rest" in -c\ *) rest="${rest#-c }"; rest="${rest#* }" ;; esac
        eval "set -- $rest"
        for p in "$@"; do
          l="$(dev_to_local "$p")"
          [ -f "$l" ] || continue
          printf '%s|%s\n' "$(wc -c <"$l" | tr -d ' ')" "$p"
        done
        [ "$SLOW" = 1 ] && sleep 0.25
        ;;
      find)
        find "$DEVICE/storage" -type f 2>/dev/null | sed "s|^$DEVICE||"
        [ "$SLOW" = 1 ] && sleep 0.6
        ;;
      "test") p="${cmd#test -e }"; p="${p#\'}"; p="${p%\'}"
        [ -e "$(dev_to_local "$p")" ] && exit 0 || exit 1 ;;
      su) exit 1 ;;
      settings)
        case "$cmd" in
          "settings list"*) printf 'screen_brightness=120\nring_volume=4\n' ;;
          "settings get"*) printf '0\n' ;;
          *) ;;
        esac ;;
      dumpsys) printf 'a synthetic %s record\n' "${2:-service}" ;;
      cmd)
        case "$cmd" in
          "cmd package list packages"*)
            printf 'package:com.android.chrome\r\npackage:com.example.vault\r\n' ;;
          *) printf 'ok\n' ;;
        esac ;;
      getprop) printf 'fake-phone\n' ;;
      *) exit 0 ;;
    esac
    exit 0 ;;
esac
exit 0
MOCK
chmod +x "$BIN/adb"

# --- capture ---------------------------------------------------------------

Xvfb "$DISPLAY_NUM" -screen 0 "${SCREEN}x24" >/dev/null 2>&1 &
XVFB_PID=$!
sleep 1

# shot <name> <seconds-before-capture> <command...>
shot() {
  local name="$1" delay="$2"
  shift 2
  DISPLAY="$DISPLAY_NUM" xterm -geometry "$GEOMETRY" -fa 'Monospace' -fs "$FONT_SIZE" \
    -bg '#0b1a17' -fg '#e6f5eb' -title "$name" \
    -e bash -c "$*" >/dev/null 2>&1 &
  local xterm_pid=$!
  sleep "$delay"
  DISPLAY="$DISPLAY_NUM" import -window root "$OUT_DIR/$name.png" 2>/dev/null
  kill "$xterm_pid" 2>/dev/null
  wait "$xterm_pid" 2>/dev/null
  pkill -f "MOCK_DEVICE=$DEVICE" 2>/dev/null

  # An empty desktop compresses to almost nothing. Without this the run
  # reported six filenames and produced six black rectangles.
  local bytes
  bytes="$(wc -c <"$OUT_DIR/$name.png" 2>/dev/null || echo 0)"
  if [ "$bytes" -lt 3000 ]; then
    printf '  %s: captured an empty screen (%s bytes). The command under xterm\n' "$name" "$bytes" >&2
    printf '  probably exited before drawing. Nothing was written.\n' >&2
    rm -f "$OUT_DIR/$name.png"
    FAILED_SHOTS=$((FAILED_SHOTS + 1))
    return 1
  fi
  # Trim the desktop the terminal does not cover, then palette-reduce. A
  # terminal uses a handful of colours, so 32 is lossless to the eye and takes
  # the set from 252 KB to about 80 KB -- these live in a git repository.
  # Two trims. The first drops the desktop the terminal does not cover; the
  # second drops the unused rows below the output, so a three-line summary is
  # not published as a mostly-empty black rectangle. The border is taken from
  # the image's own corner so it works for both the dark terminal and dialog's
  # blue backdrop.
  local bg
  # Fuzz on this pass too: the captured window carries a dark edge that an
  # exact trim will not cross, which then blocks the content crop below.
  convert "$OUT_DIR/$name.png" -fuzz 12% -trim +repage "$OUT_DIR/$name.png" 2>/dev/null
  bg="$(convert "$OUT_DIR/$name.png" -format '%[pixel:p{2,2}]' info: 2>/dev/null)"
  # The one-pixel border first: trim needs a uniform frame to measure against,
  # and the captured window has a stray dark edge that stops it finding one.
  convert "$OUT_DIR/$name.png" -bordercolor "${bg:-black}" -border 1 \
    -fuzz 12% -trim +repage \
    -bordercolor "${bg:-black}" -border 24 -colors 32 +dither -strip \
    "$OUT_DIR/$name.png" 2>/dev/null
  printf '  %-22s %s bytes\n' "$name.png" "$bytes"
}

export MOCK_DEVICE="$DEVICE"
# Double quotes: single-quoting the value leaves $PATH literal, the shell then
# has no commands at all, and xterm exits before it draws anything -- which
# looks exactly like a screenshot tool that simply captured an empty desktop.
COMMON="export PATH=\"$BIN:\$PATH\" MOCK_DEVICE=\"$DEVICE\" ANDROID_RESCUE_PROGRESS=always PHOTO_ROOTS=/storage"

FAILED_SHOTS=0
printf 'Writing screenshots to %s\n' "$OUT_DIR"

shot "01-probe" 2 \
  "$COMMON; cd '$ROOT'; ./adrescue probe; sleep 20"

shot "02-photos-copying" 6 \
  "$COMMON MOCK_SLOW=1; cd '$ROOT'; ./adrescue photos '$DEST_BASE/phone-photos'; sleep 30"

# ANDROID_RESCUE_INSTALL_DIR makes adrescue treat this checkout as an
# installed copy, so the defaults shown are the ones a user of the one-line
# install actually gets, not the clone-relative ones.
shot "03-where-it-goes" 2 \
  "$COMMON HOME='$DEMO_HOME' ANDROID_RESCUE_INSTALL_DIR='$ROOT'; cd '$ROOT'; ./adrescue config; sleep 20"

shot "04-photos-summary" 14 \
  "$COMMON; cd '$ROOT'; ./adrescue photos '$DEST_BASE/phone-photos-3'; sleep 30"

shot "05-shared-data" 3 \
  "$COMMON MOCK_SLOW=1; cd '$ROOT'; ./adrescue data '$DEST_BASE/phone-backup' --non-interactive --select downloads,screenshots; sleep 30"


shot "06-help" 2 \
  "$COMMON; cd '$ROOT'; ./adrescue --help; sleep 20"
if [ "$FAILED_SHOTS" -gt 0 ]; then
  printf '%s screenshot(s) failed.\n' "$FAILED_SHOTS" >&2
  exit 1
fi
printf 'Done.\n'

