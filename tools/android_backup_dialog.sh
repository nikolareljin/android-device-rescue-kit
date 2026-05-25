#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_tool adb || exit 1
check_if_dialog_installed || exit 1
MESSAGE_HEIGHT=$((DIALOG_HEIGHT < 12 ? DIALOG_HEIGHT : 12))
MESSAGE_WIDTH=$((DIALOG_WIDTH < 74 ? DIALOG_WIDTH : 74))
LIST_HEIGHT=$((DIALOG_HEIGHT > 10 ? DIALOG_HEIGHT - 8 : 8))

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

select_backup_root() {
  if [ -n "${1:-}" ]; then
    printf '%s\n' "$1"
    return 0
  fi

  local mode base_dir
  mode=$(dialog --stdout \
    --title "Backup Destination" \
    --radiolist "Choose where to store the backup. Custom paths must already be mounted on this computer." \
    "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 4 \
    local "Project backups folder: backups/$TIMESTAMP" on \
    custom "Custom destination path" off)

  if [ $? -ne 0 ]; then
    return 1
  fi

  case "$mode" in
    local)
      printf 'backups/%s\n' "$TIMESTAMP"
      ;;
    custom)
      base_dir=$(dialog --stdout \
        --title "Destination Path" \
        --inputbox "Enter a destination directory. A timestamped subfolder will be created inside it." \
        "$MESSAGE_HEIGHT" "$DIALOG_WIDTH" "${ANDROID_BACKUP_DEST:-/mnt/nas/android-backups}")
      if [ $? -ne 0 ] || [ -z "$base_dir" ]; then
        return 1
      fi
      printf '%s/android-backup-%s\n' "${base_dir%/}" "$TIMESTAMP"
      ;;
    *)
      return 1
      ;;
  esac
}

BACKUP_ROOT="$(select_backup_root "${1:-}")" || {
  print_warning 'Backup cancelled.'
  exit 1
}
MANIFEST="$BACKUP_ROOT/backup_manifest.txt"

mkdir -p "$BACKUP_ROOT/shared" "$BACKUP_ROOT/device"

log_manifest() {
  printf '%s\n' "$*" >>"$MANIFEST"
}

adb_shell_exists() {
  adb shell "test -e '$1'" >/dev/null 2>&1
}

pull_path() {
  local source_path="$1"
  local target_name="$2"
  local target_path="$BACKUP_ROOT/shared/$target_name"

  if adb_shell_exists "$source_path"; then
    mkdir -p "$(dirname "$target_path")"
    print_info "Pulling $source_path -> $target_path"
    if adb pull -a "$source_path" "$target_path"; then
      log_manifest "OK $source_path -> shared/$target_name"
    else
      log_manifest "FAILED $source_path -> shared/$target_name"
    fi
  else
    print_warning "Skipping missing path: $source_path"
    log_manifest "MISSING $source_path"
  fi
}

capture_text() {
  local name="$1"
  shift
  if "$@" >"$BACKUP_ROOT/device/$name" 2>"$BACKUP_ROOT/device/$name.stderr"; then
    log_manifest "OK device/$name"
  else
    log_manifest "FAILED device/$name"
  fi
}

adb start-server
print_info 'Waiting for device...'
adb wait-for-device
print_info "Writing backup to $BACKUP_ROOT"

cat >"$MANIFEST" <<EOF
Android backup manifest
Started: $(date -Iseconds)
Destination: $BACKUP_ROOT

EOF

CHOICES=$(dialog --stdout --separate-output \
  --title "Android Backup" \
  --checklist "Select data to preserve. Private app databases usually require the app's official transfer feature." \
  "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$LIST_HEIGHT" \
  photos "Camera photos and videos: DCIM, Pictures, Movies" on \
  downloads "Downloads and documents from shared storage" on \
  whatsapp "WhatsApp visible media and local shared backup folders" on \
  snapchat "Snapchat exported/shared media folders" on \
  screenshots "Screenshots and screen recordings" on \
  music "Music, podcasts, ringtones, notifications" off \
  app_inventory "Installed app inventory, permissions, device properties" on \
  adb_backup "Try deprecated adb backup for app data where still allowed" off)

if [ $? -ne 0 ]; then
  printf 'Backup cancelled.\n'
  exit 1
fi

for choice in $CHOICES; do
  case "$choice" in
    photos)
      pull_path /sdcard/DCIM DCIM
      pull_path /sdcard/Pictures Pictures
      pull_path /sdcard/Movies Movies
      ;;
    downloads)
      pull_path /sdcard/Download Download
      pull_path /sdcard/Documents Documents
      ;;
    whatsapp)
      pull_path /sdcard/Android/media/com.whatsapp/WhatsApp Android_media_com_whatsapp_WhatsApp
      pull_path /sdcard/WhatsApp WhatsApp_legacy
      ;;
    snapchat)
      pull_path /sdcard/DCIM/Snapchat DCIM_Snapchat
      pull_path /sdcard/Pictures/Snapchat Pictures_Snapchat
      pull_path /sdcard/Movies/Snapchat Movies_Snapchat
      pull_path /sdcard/Snapchat Snapchat_legacy
      ;;
    screenshots)
      pull_path /sdcard/Pictures/Screenshots Pictures_Screenshots
      pull_path /sdcard/DCIM/Screenshots DCIM_Screenshots
      pull_path /sdcard/Movies/ScreenRecord Movies_ScreenRecord
      ;;
    music)
      pull_path /sdcard/Music Music
      pull_path /sdcard/Podcasts Podcasts
      pull_path /sdcard/Ringtones Ringtones
      pull_path /sdcard/Notifications Notifications
      ;;
    app_inventory)
      capture_text getprop.txt adb shell getprop
      capture_text packages_user.txt adb shell cmd package list packages -3
      capture_text packages_all.txt adb shell cmd package list packages -f
      capture_text permissions.txt adb shell dumpsys package
      capture_text accounts_redaction_warning.txt printf 'Account details are intentionally not collected by this script.\n'
      ;;
    adb_backup)
      print_warning 'Trying deprecated adb backup. Confirm on the phone if prompted.'
      if adb backup -apk -obb -shared -all -f "$BACKUP_ROOT/adb_backup.ab"; then
        log_manifest "OK adb_backup.ab"
      else
        log_manifest "FAILED adb_backup.ab"
      fi
      ;;
  esac
done

cat >>"$MANIFEST" <<EOF

Finished: $(date -Iseconds)

Manual app actions still recommended:
- WhatsApp: verify built-in chat transfer or Google Drive encrypted backup.
- Snapchat: verify Memories sync/export inside Snapchat.
- Signal/authenticators/banking apps: use each app's official transfer/export.
EOF

dialog --title "Backup Complete" --msgbox "Backup written to:\n$BACKUP_ROOT\n\nReview backup_manifest.txt before wiping or restoring the phone." "$MESSAGE_HEIGHT" "$MESSAGE_WIDTH"
print_success "Backup complete: $BACKUP_ROOT"
