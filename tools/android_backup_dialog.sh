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
RECOVERY_PROFILE=0
BACKUP_DESTINATION=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --recovery-profile) RECOVERY_PROFILE=1 ;;
    -h|--help) printf "Usage: %s [destination] [--recovery-profile]\n" "$0"; exit 0 ;;
    --*) print_error "Unknown option: $1"; exit 1 ;;
    *) [ -z "$BACKUP_DESTINATION" ] || { print_error "Only one backup destination may be supplied."; exit 1; }; BACKUP_DESTINATION="$1" ;;
  esac
  shift
done

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

BACKUP_ROOT="$(select_backup_root "$BACKUP_DESTINATION")" || {
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
  mkdir -p "$(dirname "$BACKUP_ROOT/device/$name")"
  shift
  if "$@" >"$BACKUP_ROOT/device/$name" 2>"$BACKUP_ROOT/device/$name.stderr"; then
    log_manifest "OK device/$name"
  else
    log_manifest "FAILED device/$name"
  fi
}

write_app_note() {
  local name="$1"
  shift
  mkdir -p "$BACKUP_ROOT/app_notes"
  if printf '%s\n' "$@" >"$BACKUP_ROOT/app_notes/$name.txt"
  then
    log_manifest "OK app_notes/$name.txt"
  else
    log_manifest "FAILED app_notes/$name.txt"
  fi
}

backup_whatsapp() {
  pull_path /sdcard/Android/media/com.whatsapp/WhatsApp Android_media_com_whatsapp_WhatsApp
  pull_path /sdcard/Android/media/com.whatsapp.w4b/WhatsApp Android_media_com_whatsapp_w4b_WhatsApp
  pull_path "/sdcard/Android/media/com.whatsapp.w4b/WhatsApp Business" Android_media_com_whatsapp_w4b_WhatsApp_Business
  pull_path /sdcard/WhatsApp WhatsApp_legacy
  pull_path "/sdcard/WhatsApp Business" WhatsApp_Business_legacy
  pull_path /sdcard/Download/WhatsApp Download_WhatsApp
  pull_path /sdcard/Documents/WhatsApp Documents_WhatsApp

  write_app_note whatsapp \
    "WhatsApp backup notes" \
    "" \
    "ADB preserved shared-storage WhatsApp folders when present." \
    "This can include visible media, local backup database files, and exported chat archives." \
    "" \
    "ADB usually cannot copy WhatsApp private app data from /data/data on an unrooted phone." \
    "For reliable chat restore, also use WhatsApp's built-in chat transfer or encrypted cloud backup before wiping the device." \
    "" \
    "After restoring files, install WhatsApp, verify the same phone number/account, then use WhatsApp's official restore flow."
}

backup_snapchat() {
  pull_path /sdcard/Android/media/com.snapchat.android Android_media_com_snapchat_android
  pull_path /sdcard/DCIM/Snapchat DCIM_Snapchat
  pull_path /sdcard/Pictures/Snapchat Pictures_Snapchat
  pull_path /sdcard/Movies/Snapchat Movies_Snapchat
  pull_path /sdcard/Download/Snapchat Download_Snapchat
  pull_path /sdcard/Documents/Snapchat Documents_Snapchat
  pull_path /sdcard/Snapchat Snapchat_legacy

  write_app_note snapchat \
    "Snapchat backup notes" \
    "" \
    "ADB preserved shared-storage Snapchat folders when present." \
    "This can include exported photos, exported videos, and app media visible under shared storage." \
    "" \
    "ADB usually cannot copy Snapchat private app data, chats, or unsynced Memories from /data/data on an unrooted phone." \
    "Before wiping the device, open Snapchat and verify Memories are backed up/synced, or export important Memories to camera roll/shared storage." \
    "" \
    "If you downloaded a Snapchat My Data archive to Downloads, also select Downloads in this backup workflow."
}

collect_recovery_profile() {
  local profile_root="$BACKUP_ROOT/recovery_profile" export_path imported_path passphrase confirmation
  mkdir -p "$profile_root/imports" "$profile_root/root_system"
  chmod 700 "$profile_root" "$profile_root/imports" "$profile_root/root_system"
  dialog --defaultno --title "Recovery Profile Consent" --yesno "This optional profile may contain passwords, network details, settings, and app inventory. Continue only for a phone you own or are authorized to recover." "$MESSAGE_HEIGHT" "$MESSAGE_WIDTH" || { log_manifest "SKIPPED recovery profile: consent declined"; return 0; }
  capture_text recovery_profile/settings_system.txt adb shell settings list system
  capture_text recovery_profile/settings_secure.txt adb shell settings list secure
  capture_text recovery_profile/settings_global.txt adb shell settings list global
  capture_text recovery_profile/networks.txt adb shell dumpsys wifi
  capture_text recovery_profile/connectivity.txt adb shell dumpsys connectivity
  capture_text recovery_profile/bluetooth.txt adb shell dumpsys bluetooth_manager
  capture_text recovery_profile/apps.txt adb shell cmd package list packages -3
  printf "%s\n" "Android recovery actions" "" "Use each providers own export or transfer flow. This tool never bypasses screen locks, app protections, or security prompts." "" >"$profile_root/recovery_actions.txt"
  if grep -Fx "package:com.android.chrome" "$BACKUP_ROOT/device/recovery_profile/apps.txt" >/dev/null 2>&1; then
    printf "%s\n" "Chrome / Google Password Manager: complete the owner-approved password export on the unlocked phone, then provide its exact path." >>"$profile_root/recovery_actions.txt"
  fi
  for app in com.bitwarden com.onepassword.android com.lastpass.lpandroid com.dashlane com.google.android.apps.authenticator2 com.azure.authenticator; do
    if grep -Fx "package:$app" "$BACKUP_ROOT/device/recovery_profile/apps.txt" >/dev/null 2>&1; then printf "%s\n" "$app: use its official export, backup, or transfer workflow before wiping." >>"$profile_root/recovery_actions.txt"; fi
  done
  chmod 600 "$profile_root/recovery_actions.txt"
  if adb shell "su -c id" >/dev/null 2>&1; then
    dialog --defaultno --title "Root-only System Sources" --yesno "Root is available. Collect only readable known Android Wi-Fi system records? No app-private database scan will be performed." "$MESSAGE_HEIGHT" "$MESSAGE_WIDTH" && {
      for source_path in /data/misc/apexdata/com.android.wifi/WifiConfigStore.xml /data/misc/wifi/WifiConfigStore.xml; do
        target_path="$profile_root/root_system/$(basename "$source_path")"
        if adb shell "su -c test\ -r\ $source_path" >/dev/null 2>&1; then adb exec-out su -c "cat $source_path" >"$target_path" 2>"$target_path.stderr" && chmod 600 "$target_path" && log_manifest "OK root system source $source_path"; else log_manifest "UNAVAILABLE root system source $source_path"; fi
      done
    }
  else
    log_manifest "SKIPPED root-only system sources: root unavailable"
  fi
  dialog --defaultno --title "Open Recovery Apps" --yesno "Open detected recovery apps for owner-approved export or transfer? The tool will never enter secrets or approve prompts." "$MESSAGE_HEIGHT" "$MESSAGE_WIDTH" && {
    for app in com.android.chrome com.bitwarden com.onepassword.android com.lastpass.lpandroid com.dashlane com.google.android.apps.authenticator2 com.azure.authenticator; do
      if grep -Fx "package:$app" "$BACKUP_ROOT/device/recovery_profile/apps.txt" >/dev/null 2>&1; then adb shell monkey -p "$app" 1 >/dev/null 2>&1 || print_warning "Could not open $app; follow recovery_actions.txt."; dialog --title "Recovery action" --msgbox "Complete the export or transfer in $app on the phone, then return here. The tool will not enter secrets or approve prompts." "$MESSAGE_HEIGHT" "$MESSAGE_WIDTH"; fi
    done
  }
  export_path=$(dialog --stdout --title "Credential Export" --inputbox "Enter the exact phone path of an owner-exported password CSV, or leave empty to skip. Example: /sdcard/Download/passwords.csv" "$MESSAGE_HEIGHT" "$MESSAGE_WIDTH" "/sdcard/Download/passwords.csv") || export_path=""
  if [ -n "$export_path" ] && adb_shell_exists "$export_path"; then
    imported_path="$profile_root/imports/$(basename "$export_path")"
    if adb pull -a "$export_path" "$imported_path"; then
      chmod 600 "$imported_path"
      { printf "%s\n\n" "Android recovery credentials" "Keep this file private. It contains plaintext passwords."; tail -n +2 "$imported_path" | while IFS=, read -r site username password; do printf "Service/Site: %s\nUsername: %s\nPassword: %s\n\n" "$site" "$username" "$password"; done; } >"$profile_root/credentials.txt"
      chmod 600 "$profile_root/credentials.txt"
      log_manifest "OK owner-exported credentials $export_path"
    else log_manifest "FAILED credential export $export_path"; fi
  elif [ -n "$export_path" ]; then log_manifest "MISSING credential export $export_path"; fi
  require_tool gpg || { log_manifest "FAILED recovery profile encryption: gpg unavailable"; return 0; }
  passphrase=$(dialog --stdout --insecure --title "Encrypt Recovery Profile" --passwordbox "Create a passphrase for the encrypted recovery archive." "$MESSAGE_HEIGHT" "$MESSAGE_WIDTH") || return 0
  confirmation=$(dialog --stdout --insecure --title "Confirm Passphrase" --passwordbox "Re-enter the recovery archive passphrase." "$MESSAGE_HEIGHT" "$MESSAGE_WIDTH") || return 0
  if [ -z "$passphrase" ] || [ "$passphrase" != "$confirmation" ]; then unset passphrase confirmation; log_manifest "FAILED recovery profile encryption: passphrase mismatch"; return 0; fi
  if tar -C "$BACKUP_ROOT" -cf - recovery_profile | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 3 --symmetric --cipher-algo AES256 --output "$BACKUP_ROOT/recovery-profile.tar.gpg" 3<<<"$passphrase"; then chmod 600 "$BACKUP_ROOT/recovery-profile.tar.gpg"; log_manifest "OK recovery-profile.tar.gpg"; else log_manifest "FAILED recovery profile encryption"; fi
  unset passphrase confirmation
  if [ -f "$profile_root/credentials.txt" ]; then dialog --defaultno --title "Retain Plaintext Credentials?" --yesno "A readable credentials.txt is highly sensitive. Keep it beside the encrypted archive? Choose No to retain it only in the encrypted archive." "$MESSAGE_HEIGHT" "$MESSAGE_WIDTH"; if [ $? -ne 0 ]; then rm -f "$profile_root/credentials.txt" "$profile_root"/imports/*; log_manifest "REMOVED plaintext credential files after encryption"; else log_manifest "RETAINED plaintext credentials by owner confirmation"; fi; fi
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
      backup_whatsapp
      ;;
    snapchat)
      backup_snapchat
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

if [ "$RECOVERY_PROFILE" -eq 1 ]; then
  collect_recovery_profile
fi

cat >>"$MANIFEST" <<EOF

Finished: $(date -Iseconds)

Manual app actions still recommended:
- WhatsApp: verify built-in chat transfer or Google Drive encrypted backup.
- Snapchat: verify Memories sync/export inside Snapchat.
- Signal/authenticators/banking apps: use each app's official transfer/export.
EOF

dialog --title "Backup Complete" --msgbox "Backup written to:\n$BACKUP_ROOT\n\nReview backup_manifest.txt before wiping or restoring the phone." "$MESSAGE_HEIGHT" "$MESSAGE_WIDTH"
print_success "Backup complete: $BACKUP_ROOT"
