#!/usr/bin/env bash
set -u

CAPTURE_DIR="${1:-}"

if [ -z "$CAPTURE_DIR" ] || [ ! -d "$CAPTURE_DIR" ]; then
  printf 'Usage: %s <capture-directory>\n' "$0" >&2
  exit 1
fi

if ! command -v rg >/dev/null 2>&1; then
  printf 'ripgrep (rg) is required for analysis.\n' >&2
  exit 1
fi

WORK_DIR="$CAPTURE_DIR/_analysis"
REPORT="$CAPTURE_DIR/analysis_report.txt"
mkdir -p "$WORK_DIR"

{
  printf '# Android Capture Analysis\n\n'
  printf 'Capture: %s\n' "$CAPTURE_DIR"
  printf 'Generated: %s\n\n' "$(date +%Y-%m-%dT%H:%M:%S%z)"
} >"$REPORT"

extract_bugreport_artifacts() {
  local zip_file="$1"
  local extract_dir="$WORK_DIR/bugreport"

  mkdir -p "$extract_dir"

  if ! command -v unzip >/dev/null 2>&1; then
    printf 'unzip not found; skipping bugreport extraction.\n' >>"$REPORT"
    return
  fi

  unzip -qq -o "$zip_file" \
    '*last_kmsg*' \
    '*last_kernel*' \
    '*last_all_history*' \
    '*dumpstate*lastkmsg*' \
    '*recovery*' \
    '*tombstone*' \
    '*getprop*' \
    -d "$extract_dir" 2>/dev/null || true

  find "$extract_dir" -type f -name '*.gz' -print | while IFS= read -r gz_file; do
    if gzip -t "$gz_file" >/dev/null 2>&1; then
      gzip -dc "$gz_file" >"${gz_file%.gz}" 2>/dev/null || true
    elif unzip -t "$gz_file" >/dev/null 2>&1; then
      unzip -qq -o "$gz_file" -d "${gz_file%.gz}_unzipped" 2>/dev/null || true
    fi
  done
}

# One glob: "bugreport.zip" (the name collect_android_dumps.sh always writes)
# matched both of the previous two, emitting the section twice.
for bugreport in "$CAPTURE_DIR"/*bugreport*.zip; do
  [ -f "$bugreport" ] || continue
  {
    printf '## Bugreport\n\n'
    printf 'Found: %s\n\n' "$bugreport"
  } >>"$REPORT"
  extract_bugreport_artifacts "$bugreport"
done

search_section() {
  local title="$1"
  local pattern="$2"

  {
    printf '## %s\n\n' "$title"
    # --no-ignore is required: the default capture directory is captures/<ts>
    # inside this repo, and .gitignore deliberately ignores logcat_*.txt,
    # dumpsys_*.txt and the bugreport. ripgrep applies ignore rules to a
    # directory it is given explicitly, so without this the kernel panic in
    # logcat is silently absent from the report.
    # $WORK_DIR lives inside $CAPTURE_DIR, so passing both searched and
    # printed every extracted artifact twice.
    rg -n -i --no-heading --no-ignore --hidden "$pattern" "$CAPTURE_DIR" 2>/dev/null | head -n 120 || true
    printf '\n'
  } >>"$REPORT"
}

search_section 'Reset And Boot Reasons' 'reset.reason|reset_reason|bootreason|boot reason|ro.boot|upload cause|secreboot|rebooting|shutdown'
search_section 'Kernel Panic And Watchdog' 'kernel panic|panic - not syncing|watchdog bite|non_secure_wd|TZBSP_ERR|AOP_NON_SECURE|oops|BUG:|Call trace|Unable to handle'
search_section 'Storage And Filesystem' 'f2fs|ext4|ufs|ufshcd|mmc|blk_update_request|I/O error|io error|write_end_io|read error|fsck'
search_section 'Radio And Subsystems' 'modem|subsys|subsystem|SSR|glink|qmi|rild|radio.*fatal|CP crash|CP_CRASH'
search_section 'Thermal Battery Power' 'thermal shutdown|overheat|battery|pmic|vbat|brownout|poweroff|thermalservice'
search_section 'System Server App Crashes' 'system_server|watchdog|ANR|FATAL EXCEPTION|native crash|tombstone|signal [0-9]+|Abort message'

{
  printf '## Next Manual Checks\n\n'
  printf '- If kernel panic lines exist, inspect the nearest preceding hardware or filesystem errors.\n'
  printf '- If the same panic repeats across reset counts, prefer kernel/storage/vendor failure over app-level explanations.\n'
  printf '- If only app crashes appear and no kernel/watchdog reset appears, inspect system_server and app tombstones first.\n'
  printf '- If thermal or battery shutdown appears, correlate timestamps with batterystats and thermalservice output.\n'
} >>"$REPORT"

printf 'Analysis written to %s\n' "$REPORT"
