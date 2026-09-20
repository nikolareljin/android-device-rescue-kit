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
RECOVERY_PROFILE_DEFAULT="off"
if [ "$RECOVERY_PROFILE" -eq 1 ]; then
  RECOVERY_PROFILE_DEFAULT="on"
fi

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

# A backup that cannot be written must stop here, loudly. Without this check an
# unmounted /mnt/nas, a read-only card or a typo'd destination let every mkdir,
# every adb pull and every manifest append fail in turn while the run still
# finished with "Backup Complete" -- and the phone then got wiped.
if ! mkdir -p "$BACKUP_ROOT/shared" "$BACKUP_ROOT/device" 2>/dev/null; then
  print_error "Cannot create backup directories under: $BACKUP_ROOT"
  dialog --title "Backup Destination Unusable" --msgbox "Cannot write to:\n$BACKUP_ROOT\n\nCheck the path is mounted and writable, then run the backup again. Nothing has been backed up." "$MESSAGE_HEIGHT" "$MESSAGE_WIDTH"
  exit 1
fi
if ! : >>"$MANIFEST" 2>/dev/null; then
  print_error "Cannot write the manifest: $MANIFEST"
  exit 1
fi

# Number of captures that failed. The final success message is conditional on
# this being zero, so a partial backup can never present itself as a complete one.
BACKUP_FAILURES=0

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
      BACKUP_FAILURES=$((BACKUP_FAILURES + 1))
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
    BACKUP_FAILURES=$((BACKUP_FAILURES + 1))
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
  if ! require_tool gpg; then
    log_manifest "SKIPPED recovery profile: gpg unavailable"
    return 1
  fi
  # Create the profile files private from the start. They were written at the
  # default 0644 and only chmod'ed 600 after the later `mv`, leaving a window in
  # which Wi-Fi records and device identifiers were world-readable.
  #
  # umask is process-wide, so the previous value is captured and restored on
  # every return path below rather than leaking into the rest of the backup.
  local prior_umask
  prior_umask="$(umask)"
  # RETURN trap rather than a restore at each exit: this function has five
  # return paths below and a missed one would leak 077 into the rest of the run.
  trap 'umask "$prior_umask"' RETURN
  umask 077
  capture_text recovery_profile/settings_system.txt adb shell settings list system
  capture_text recovery_profile/settings_secure.txt adb shell settings list secure
  capture_text recovery_profile/settings_global.txt adb shell settings list global
  capture_text recovery_profile/networks.txt adb shell dumpsys wifi
  capture_text recovery_profile/connectivity.txt adb shell dumpsys connectivity
  capture_text recovery_profile/bluetooth.txt adb shell dumpsys bluetooth_manager
  capture_text recovery_profile/apps.txt adb shell cmd package list packages
  mv "$BACKUP_ROOT/device/recovery_profile/"* "$profile_root/"
  find "$profile_root" -maxdepth 1 -type f -exec chmod 600 {} +
  printf "%s\n" "Android recovery actions" "" "Use each providers own export or transfer flow. This tool never bypasses screen locks, app protections, or security prompts." "" >"$profile_root/recovery_actions.txt"
  # adb commonly allocates a PTY and returns CRLF, so `grep -Fx "package:x"`
  # never matched "package:x\r" and the guidance below was silently skipped.
  has_package() { tr -d '\r' < "$profile_root/apps.txt" | grep -Fxq "package:$1"; }
  if has_package com.android.chrome; then
    printf "%s\n" "Chrome / Google Password Manager: complete the owner-approved password export on the unlocked phone, then provide its exact path." >>"$profile_root/recovery_actions.txt"
  fi
  for app in com.bitwarden com.onepassword.android com.lastpass.lpandroid com.dashlane com.google.android.apps.authenticator2 com.azure.authenticator; do
    if has_package "$app"; then printf "%s\n" "$app: use its official export, backup, or transfer workflow before wiping." >>"$profile_root/recovery_actions.txt"; fi
  done
  chmod 600 "$profile_root/recovery_actions.txt"
  if adb shell "su -c id" >/dev/null 2>&1; then
    dialog --defaultno --title "Root-only System Sources" --yesno "Root is available. Collect only readable known Android Wi-Fi system records? No app-private database scan will be performed." "$MESSAGE_HEIGHT" "$MESSAGE_WIDTH" && {
      for source_path in /data/misc/apexdata/com.android.wifi/WifiConfigStore.xml /data/misc/wifi/WifiConfigStore.xml; do
        case "$source_path" in
          /data/misc/apexdata/*) target_path="$profile_root/root_system/WifiConfigStore.apex.xml" ;;
          *) target_path="$profile_root/root_system/WifiConfigStore.legacy.xml" ;;
        esac
        if adb shell "su -c test\ -r\ $source_path" >/dev/null 2>&1; then adb exec-out su -c "cat $source_path" >"$target_path" 2>"$target_path.stderr" && chmod 600 "$target_path" && log_manifest "OK root system source $source_path"; else log_manifest "UNAVAILABLE root system source $source_path"; fi
      done
    }
  else
    log_manifest "SKIPPED root-only system sources: root unavailable"
  fi
  dialog --defaultno --title "Open Recovery Apps" --yesno "Open detected recovery apps for owner-approved export or transfer? The tool will never enter secrets or approve prompts." "$MESSAGE_HEIGHT" "$MESSAGE_WIDTH" && {
    for app in com.android.chrome com.bitwarden com.onepassword.android com.lastpass.lpandroid com.dashlane com.google.android.apps.authenticator2 com.azure.authenticator; do
      if has_package "$app"; then adb shell monkey -p "$app" 1 >/dev/null 2>&1 || print_warning "Could not open $app; follow recovery_actions.txt."; dialog --title "Recovery action" --msgbox "Complete the export or transfer in $app on the phone, then return here. The tool will not enter secrets or approve prompts." "$MESSAGE_HEIGHT" "$MESSAGE_WIDTH"; fi
    done
  }
  # Several exports, not one.
  #
  # A phone routinely has more than one: the browser's passwords, a password
  # manager's vault, an authenticator's seeds. The previous single prompt kept
  # whichever was typed and there was no way to add a second. It also copied the
  # file to credentials.txt, leaving the same secret in plaintext twice; the
  # import under imports/ is now the only readable copy.
  #
  # Format is deliberately not checked. Managers export csv, json, 1pux and
  # kdbx, so requiring a CSV would reject valid vaults. What is checked is that
  # the file arrived whole.
  mkdir -p "$profile_root/imports"
  credential_count=0
  # Prefill the example path on the first prompt only; an already-imported path
  # offered again just invites a duplicate.
  credential_prefill="/sdcard/Download/passwords.csv"
  while :; do
    export_path=$(dialog --stdout --title "Credential Export ($credential_count imported)" --inputbox "Exact phone path of an owner-exported password file (csv, json, 1pux, kdbx).\n\nLeave empty and press OK when there are no more." "$MESSAGE_HEIGHT" "$MESSAGE_WIDTH" "$credential_prefill") || export_path=""
    credential_prefill=""
    [ -n "$export_path" ] || break

    if ! adb_shell_exists "$export_path"; then
      log_manifest "MISSING credential export $export_path"
      BACKUP_FAILURES=$((BACKUP_FAILURES + 1))
      dialog --title "Not Found" --msgbox "No file at:\n$export_path\n\nCheck the path on the phone and try again." "$MESSAGE_HEIGHT" "$MESSAGE_WIDTH"
      continue
    fi

    import_name="$(basename "$export_path")"
    # Two managers both exporting "passwords.csv" must not overwrite each other.
    if [ -e "$profile_root/imports/$import_name" ]; then
      import_name="$(date +%s)-$import_name"
    fi
    imported_path="$profile_root/imports/$import_name"

    if ! adb pull -a "$export_path" "$imported_path" >/dev/null 2>&1; then
      log_manifest "FAILED credential export $export_path"
      BACKUP_FAILURES=$((BACKUP_FAILURES + 1))
      continue
    fi
    chmod 600 "$imported_path"

    # An empty or short file here is the dangerous case: it looks imported, and
    # the user is later invited to delete the phone's copy.
    local_size=$(wc -c <"$imported_path" 2>/dev/null | tr -d ' ')
    device_size=$(adb shell "stat -c %s '$export_path' 2>/dev/null || wc -c <'$export_path'" 2>/dev/null | tr -dc '0-9')
    if [ -z "$local_size" ] || [ "$local_size" -eq 0 ]; then
      log_manifest "FAILED credential export empty after copy $export_path"
      BACKUP_FAILURES=$((BACKUP_FAILURES + 1))
      rm -f "$imported_path"
      dialog --title "Empty File" --msgbox "$export_path copied as 0 bytes and was discarded.\n\nRe-export it on the phone, then add it again." "$MESSAGE_HEIGHT" "$MESSAGE_WIDTH"
      continue
    fi
    if [ -n "$device_size" ] && [ "$device_size" -ne "$local_size" ]; then
      log_manifest "FAILED credential export size mismatch $export_path (device=$device_size local=$local_size)"
      BACKUP_FAILURES=$((BACKUP_FAILURES + 1))
      rm -f "$imported_path"
      dialog --title "Incomplete Copy" --msgbox "$export_path copied incompletely and was discarded.\n\nReconnect the phone and add it again." "$MESSAGE_HEIGHT" "$MESSAGE_WIDTH"
      continue
    fi

    credential_count=$((credential_count + 1))
    log_manifest "OK owner-exported credentials $export_path -> imports/$import_name ($local_size bytes)"
    printf '%s\t%s\t%s bytes\n' "$import_name" "$export_path" "$local_size" >>"$profile_root/credential_exports.txt"
  done
  if [ "$credential_count" -gt 0 ]; then
    chmod 600 "$profile_root/credential_exports.txt"
  fi
  log_manifest "Credential exports imported: $credential_count"
  passphrase=$(dialog --stdout --title "Encrypt Recovery Profile" --passwordbox "Create a passphrase for the encrypted recovery archive." "$MESSAGE_HEIGHT" "$MESSAGE_WIDTH") || { log_manifest "CANCELLED recovery profile encryption"; return 1; }
  confirmation=$(dialog --stdout --title "Confirm Passphrase" --passwordbox "Re-enter the recovery archive passphrase." "$MESSAGE_HEIGHT" "$MESSAGE_WIDTH") || { log_manifest "CANCELLED recovery profile encryption confirmation"; return 1; }
  if [ -z "$passphrase" ] || [ "$passphrase" != "$confirmation" ]; then unset passphrase confirmation; log_manifest "FAILED recovery profile encryption: passphrase mismatch"; return 1; fi
  # This script runs without pipefail, so `tar | gpg` reported only gpg's status.
  # If tar died part-way -- destination full, an unreadable file, a partial adb
  # pull, a NAS hiccup -- gpg happily encrypted the truncated stream and exited
  # 0. The archive was logged OK and the user was then invited to delete the
  # only readable copy of their exported passwords. So: check both halves via
  # PIPESTATUS, then prove the archive actually extracts before trusting it.
  archive_ok=0
  tar -C "$BACKUP_ROOT" -cf - recovery_profile |
    gpg --batch --yes --pinentry-mode loopback --passphrase-fd 3 --symmetric --cipher-algo AES256 --output "$BACKUP_ROOT/recovery-profile.tar.gpg" 3<<<"$passphrase"
  pipe_status=("${PIPESTATUS[@]}")
  if [ "${pipe_status[0]}" -eq 0 ] && [ "${pipe_status[1]}" -eq 0 ]; then
    if gpg --batch --quiet --pinentry-mode loopback --passphrase-fd 3 --decrypt "$BACKUP_ROOT/recovery-profile.tar.gpg" 3<<<"$passphrase" 2>/dev/null | tar -tf - >/dev/null 2>&1; then
      archive_ok=1
    else
      log_manifest "FAILED recovery profile archive did not verify"
    fi
  else
    log_manifest "FAILED recovery profile encryption (tar=${pipe_status[0]} gpg=${pipe_status[1]})"
  fi
  if [ "$archive_ok" -eq 1 ]; then chmod 600 "$BACKUP_ROOT/recovery-profile.tar.gpg"; log_manifest "OK recovery-profile.tar.gpg verified"; else log_manifest "FAILED recovery profile encryption"; dialog --title "Recovery Profile Encryption Failed" --msgbox "The encrypted archive was not created. The recovery profile remains at:\n$profile_root\n\nMove it to secure storage or retry the backup before wiping the phone." "$MESSAGE_HEIGHT" "$MESSAGE_WIDTH"; return 1; fi
  unset passphrase confirmation
  if [ "$credential_count" -gt 0 ]; then
    if dialog --defaultno --title "Retain Plaintext Credentials?" --yesno "$credential_count readable credential export(s) sit under:\n$profile_root/imports/\n\nKeep them beside the encrypted archive? Choose No to keep them only inside the archive, which has already been verified to extract." "$MESSAGE_HEIGHT" "$MESSAGE_WIDTH"; then
      log_manifest "RETAINED $credential_count plaintext credential export(s) by owner confirmation"
    else
      # Only reached when the archive verified, so this cannot be the last copy.
      rm -f "$profile_root"/imports/* "$profile_root/credential_exports.txt"
      rmdir "$profile_root/imports" 2>/dev/null || true
      log_manifest "REMOVED $credential_count plaintext credential export(s) after verified encryption"
    fi
  fi
}
adb start-server
print_info 'Waiting for device...'
adb wait-for-device
print_info "Writing backup to $BACKUP_ROOT"

cat >"$MANIFEST" <<EOF
Android backup manifest
Started: $(date +%Y-%m-%dT%H:%M:%S%z)
Destination: $BACKUP_ROOT

EOF

CHOICES=$(dialog --stdout --separate-output \
  --title "Android Backup" \
  --checklist "Select data to preserve. Private app databases usually require the app's official transfer feature." \
  "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$LIST_HEIGHT" \
  photos "Every photo and video on the device, found and verified" on \
  downloads "Downloads and documents from shared storage" on \
  whatsapp "WhatsApp visible media and local shared backup folders" on \
  snapchat "Snapchat exported/shared media folders" on \
  screenshots "Screenshots and screen recordings" on \
  music "Music, podcasts, ringtones, notifications" off \
  app_inventory "Installed app inventory, permissions, device properties" on \
  recovery_profile "Recovery profile: settings, networks, app guidance, owner-exported credentials" "$RECOVERY_PROFILE_DEFAULT" \
  adb_backup "Try deprecated adb backup for app data where still allowed" off)

if [ $? -ne 0 ]; then
  printf 'Backup cancelled.\n'
  exit 1
fi

# Reset before reading the checklist. The --recovery-profile flag sets this to
# 1 up front so the box starts checked; without clearing it here, unchecking
# the box left it at 1 and the profile was collected against the user's
# explicit choice.
RECOVERY_PROFILE=0

for choice in $CHOICES; do
  case "$choice" in
    photos)
      # Discovery, not a path list. DCIM/Pictures/Movies misses the removable
      # card, vendor gallery folders, received app media and any folder the
      # owner made themselves. android_photo_backup.sh enumerates through
      # MediaStore and a filesystem sweep, then verifies every file it claims.
      if "$SCRIPT_DIR/android_photo_backup.sh" "$BACKUP_ROOT"; then
        log_manifest "OK photos verified (see photos_report.txt)"
      else
        log_manifest "FAILED photos incomplete (see missing_photos.txt)"
        BACKUP_FAILURES=$((BACKUP_FAILURES + 1))
      fi
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
    recovery_profile)
      RECOVERY_PROFILE=1
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

if [ "$RECOVERY_PROFILE" -eq 1 ] && ! collect_recovery_profile; then
  print_error "Recovery profile was not completed. Review backup_manifest.txt before wiping the phone."
  exit 1
fi

cat >>"$MANIFEST" <<EOF

Finished: $(date +%Y-%m-%dT%H:%M:%S%z)

Manual app actions still recommended:
- WhatsApp: verify built-in chat transfer or Google Drive encrypted backup.
- Snapchat: verify Memories sync/export inside Snapchat.
- Signal/authenticators/banking apps: use each app's official transfer/export.
EOF

if [ "$BACKUP_FAILURES" -gt 0 ]; then
  dialog --title "Backup Incomplete" --msgbox "$BACKUP_FAILURES item(s) FAILED.\n\nBackup root:\n$BACKUP_ROOT\n\nOpen backup_manifest.txt and search for FAILED before wiping the phone." "$MESSAGE_HEIGHT" "$MESSAGE_WIDTH"
  print_error "Backup incomplete: $BACKUP_FAILURES item(s) failed. See $MANIFEST"
  exit 1
fi

dialog --title "Backup Complete" --msgbox "Backup written to:\n$BACKUP_ROOT\n\nReview backup_manifest.txt before wiping or restoring the phone." "$MESSAGE_HEIGHT" "$MESSAGE_WIDTH"
print_success "Backup complete: $BACKUP_ROOT"
