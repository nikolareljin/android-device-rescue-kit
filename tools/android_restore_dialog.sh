#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

BACKUP_ROOT="${1:-}"

require_tool adb || exit 1
check_if_dialog_installed || exit 1
MESSAGE_HEIGHT=$((DIALOG_HEIGHT < 12 ? DIALOG_HEIGHT : 12))
MESSAGE_WIDTH=$((DIALOG_WIDTH < 78 ? DIALOG_WIDTH : 78))
LIST_HEIGHT=$((DIALOG_HEIGHT > 10 ? DIALOG_HEIGHT - 8 : 8))

if [ -z "$BACKUP_ROOT" ] || [ ! -d "$BACKUP_ROOT/shared" ]; then
  printf 'Usage: %s <backup-directory>\n' "$0" >&2
  exit 1
fi

push_if_present() {
  local source_name="$1"
  local dest_path="$2"
  local source_path="$BACKUP_ROOT/shared/$source_name"
  local remote_dest

  if [ -e "$source_path" ]; then
    print_info "Restoring $source_path -> $dest_path"
    remote_dest="$(printf "%s" "$dest_path" | sed "s/'/'\\\\''/g")"
    adb shell "mkdir -p '$remote_dest'" >/dev/null 2>&1 || true
    adb push "$source_path/." "$dest_path/"
  else
    print_warning "Skipping missing backup item: $source_name"
  fi
}

adb start-server
print_info 'Waiting for device...'
adb wait-for-device

CHOICES=$(dialog --stdout --separate-output \
  --title "Android Restore" \
  --checklist "Select shared-storage data to restore. Install/sign in to apps separately for private app data." \
  "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$LIST_HEIGHT" \
  photos "Camera photos and videos" on \
  downloads "Downloads and documents" on \
  whatsapp "WhatsApp visible media/shared backup folders" on \
  snapchat "Snapchat exported/shared media folders" on \
  screenshots "Screenshots and screen recordings" on \
  music "Music, podcasts, ringtones, notifications" off)

if [ $? -ne 0 ]; then
  printf 'Restore cancelled.\n'
  exit 1
fi

for choice in $CHOICES; do
  case "$choice" in
    photos)
      push_if_present DCIM /sdcard/DCIM
      push_if_present Pictures /sdcard/Pictures
      push_if_present Movies /sdcard/Movies
      ;;
    downloads)
      push_if_present Download /sdcard/Download
      push_if_present Documents /sdcard/Documents
      ;;
    whatsapp)
      push_if_present Android_media_com_whatsapp_WhatsApp /sdcard/Android/media/com.whatsapp/WhatsApp
      push_if_present Android_media_com_whatsapp_w4b_WhatsApp /sdcard/Android/media/com.whatsapp.w4b/WhatsApp
      push_if_present Android_media_com_whatsapp_w4b_WhatsApp_Business "/sdcard/Android/media/com.whatsapp.w4b/WhatsApp Business"
      push_if_present WhatsApp_legacy /sdcard/WhatsApp
      push_if_present WhatsApp_Business_legacy "/sdcard/WhatsApp Business"
      push_if_present Download_WhatsApp /sdcard/Download/WhatsApp
      push_if_present Documents_WhatsApp /sdcard/Documents/WhatsApp
      ;;
    snapchat)
      push_if_present Android_media_com_snapchat_android /sdcard/Android/media/com.snapchat.android
      push_if_present DCIM_Snapchat /sdcard/DCIM/Snapchat
      push_if_present Pictures_Snapchat /sdcard/Pictures/Snapchat
      push_if_present Movies_Snapchat /sdcard/Movies/Snapchat
      push_if_present Download_Snapchat /sdcard/Download/Snapchat
      push_if_present Documents_Snapchat /sdcard/Documents/Snapchat
      push_if_present Snapchat_legacy /sdcard/Snapchat
      ;;
    screenshots)
      push_if_present Pictures_Screenshots /sdcard/Pictures/Screenshots
      push_if_present DCIM_Screenshots /sdcard/DCIM/Screenshots
      push_if_present Movies_ScreenRecord /sdcard/Movies/ScreenRecord
      ;;
    music)
      push_if_present Music /sdcard/Music
      push_if_present Podcasts /sdcard/Podcasts
      push_if_present Ringtones /sdcard/Ringtones
      push_if_present Notifications /sdcard/Notifications
      ;;
  esac
done

dialog --title "Restore Complete" --msgbox "Shared-storage restore finished.\n\nNow open apps such as WhatsApp, Snapchat, Signal, and authenticators and complete their official restore or sign-in flows." "$MESSAGE_HEIGHT" "$MESSAGE_WIDTH"
print_success "Restore complete from: $BACKUP_ROOT"
