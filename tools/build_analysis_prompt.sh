#!/usr/bin/env bash
set -u

CAPTURE_DIR="${1:-}"
OUTPUT_FILE="${2:-}"

if [ -z "$CAPTURE_DIR" ] || [ ! -d "$CAPTURE_DIR" ]; then
  printf 'Usage: %s <capture-directory> [output-prompt.md]\n' "$0" >&2
  exit 1
fi

if ! command -v rg >/dev/null 2>&1; then
  printf 'ripgrep (rg) is required.\n' >&2
  exit 1
fi

if [ -z "$OUTPUT_FILE" ]; then
  OUTPUT_FILE="$CAPTURE_DIR/analysis_prompt.md"
fi

REPORT="$CAPTURE_DIR/analysis_report.txt"

if [ ! -f "$REPORT" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  "$SCRIPT_DIR/analyze_android_capture.sh" "$CAPTURE_DIR" >/dev/null
fi

append_section() {
  local title="$1"
  local pattern="$2"
  local limit="${3:-80}"

  {
    printf '\n## %s\n\n' "$title"
    # See analyze_android_capture.sh: without --no-ignore the capture files
    # are skipped for the default in-repo capture path.
    rg -n -i --no-heading --no-ignore --hidden "$pattern" "$CAPTURE_DIR" 2>/dev/null | head -n "$limit" || true
  } >>"$OUTPUT_FILE"
}

{
  printf '# Android Device Failure Analysis Prompt\n\n'
  printf 'You are analyzing an Android diagnostic capture. Determine the most likely root cause of reboot loops, crashes, watchdog resets, severe performance problems, radio failures, storage failures, or thermal/power failures.\n\n'
  printf 'Use the excerpts below as evidence. Do not assume an app crash caused the reboot unless reset, kernel, watchdog, or system-server evidence supports that. Distinguish root cause from secondary symptoms.\n\n'
  printf 'Return:\n\n'
  printf '1. Most likely root cause with confidence.\n'
  printf '2. Evidence lines and file paths that support it.\n'
  printf '3. Competing explanations and why they are weaker.\n'
  printf '4. Immediate data-preservation steps.\n'
  printf '5. Repair or restore options, ordered from least destructive to most destructive.\n'
  printf '6. Extra dumps or commands needed if evidence is insufficient.\n\n'
  # The backticks here are Markdown, not command substitution, so the format
  # string is single-quoted on purpose and the value is passed as an argument.
  # shellcheck disable=SC2016
  printf 'Capture directory: `%s`\n\n' "$CAPTURE_DIR"
  # shellcheck disable=SC2016
  printf 'Generated: `%s`\n\n' "$(date +%Y-%m-%dT%H:%M:%S%z)"
  printf '## Available Files\n\n'
  find "$CAPTURE_DIR" -maxdepth 3 -type f -print 2>/dev/null
} >"$OUTPUT_FILE"

if [ -f "$REPORT" ]; then
  {
    printf '\n## Generated Triage Report\n\n'
    sed -n '1,260p' "$REPORT"
  } >>"$OUTPUT_FILE"
fi

append_section 'Reset And Boot Evidence' 'reset.reason|reset_reason|bootreason|boot reason|ro.boot|upload cause|rebooting|shutdown|secreboot' 80
append_section 'Kernel Panic Watchdog Evidence' 'kernel panic|panic - not syncing|watchdog bite|non_secure_wd|TZBSP_ERR|AOP_NON_SECURE|oops|BUG:|Call trace|Unable to handle' 100
append_section 'Storage Filesystem Evidence' 'f2fs|ext4|ufs|ufshcd|mmc|blk_update_request|I/O error|io error|write_end_io|read error|fsck' 100
append_section 'Radio Subsystem Evidence' 'modem|subsys|subsystem|SSR|glink|qmi|rild|radio.*fatal|CP crash|CP_CRASH' 80
append_section 'Thermal Battery Power Evidence' 'thermal shutdown|overheat|battery|pmic|vbat|brownout|poweroff|thermalservice' 80
append_section 'System Server App Crash Evidence' 'system_server|watchdog|ANR|FATAL EXCEPTION|native crash|tombstone|signal [0-9]+|Abort message' 80

{
  printf '\n## Privacy Reminder\n\n'
  printf 'This prompt may contain personal device metadata from the capture. Review or redact before sending to hosted services.\n'
} >>"$OUTPUT_FILE"

printf 'Prompt written to %s\n' "$OUTPUT_FILE"
