#!/usr/bin/env bash
set -u

OUT_DIR="${1:-captures/$(date +%Y%m%d-%H%M%S)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOGCAT_BUFFERS_FILE="${LOGCAT_BUFFERS_FILE:-$ROOT_DIR/config/logcat_buffers.txt}"
DROPBOX_TAGS_FILE="${DROPBOX_TAGS_FILE:-$ROOT_DIR/config/dropbox_tags.txt}"
DUMPSYS_SERVICES_FILE="${DUMPSYS_SERVICES_FILE:-$ROOT_DIR/config/dumpsys_services.txt}"

mkdir -p "$OUT_DIR"

run_capture() {
  local name="$1"
  shift

  printf 'Collecting %s...\n' "$name"
  if ! "$@" >"$OUT_DIR/$name" 2>"$OUT_DIR/$name.stderr"; then
    printf '  warning: failed to collect %s; see %s\n' "$name" "$OUT_DIR/$name.stderr" >&2
  fi
}

if ! command -v adb >/dev/null 2>&1; then
  printf 'adb was not found in PATH.\n' >&2
  exit 1
fi

adb start-server

printf 'Waiting for device...\n'
adb wait-for-device

printf 'Writing capture to %s\n' "$OUT_DIR"

printf 'Collecting bugreport...\n'
if ! adb bugreport "$OUT_DIR/bugreport.zip"; then
  printf '  warning: adb bugreport failed\n' >&2
fi

run_capture getprop.txt adb shell getprop

while IFS= read -r buffer; do
  [ -n "$buffer" ] || continue
  case "$buffer" in \#*) continue ;; esac
  run_capture "logcat_${buffer}.txt" adb shell logcat -b "$buffer" -d -v threadtime
done <"$LOGCAT_BUFFERS_FILE"

while IFS= read -r tag; do
  [ -n "$tag" ] || continue
  case "$tag" in \#*) continue ;; esac
  run_capture "dropbox_${tag}.txt" adb shell dumpsys dropbox --print "$tag"
done <"$DROPBOX_TAGS_FILE"

while IFS= read -r service; do
  [ -n "$service" ] || continue
  case "$service" in \#*) continue ;; esac
  safe_name="${service//./_}.txt"
  run_capture "dumpsys_${safe_name}" adb shell dumpsys "$service"
done <"$DUMPSYS_SERVICES_FILE"

run_capture batterystats_history.txt adb shell dumpsys batterystats --history

printf 'Capture complete: %s\n' "$OUT_DIR"
printf 'Reminder: captures are private and ignored by git.\n'
