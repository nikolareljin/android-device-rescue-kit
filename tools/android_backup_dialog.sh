#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=tools/lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=tools/lib/device_screen.sh
source "$SCRIPT_DIR/lib/device_screen.sh"
# shellcheck source=tools/lib/progress.sh
source "$SCRIPT_DIR/lib/progress.sh"

require_tool adb || exit 1
# Before a destination is chosen or a single file is created. An unreachable
# phone used to leave an empty backup_manifest.txt behind, which reads like a
# backup that was attempted.
adb start-server >/dev/null 2>&1 || true
require_device || exit 1
# Was `require_dialog || exit 1`. The prompts fall back now, so there is
# nothing to refuse.
ui_init

# --- ui layer --------------------------------------------------------------
#
# Every prompt goes through these. In interactive mode they are dialog; with
# --non-interactive they return the supplied default without drawing anything.
# The point is that the two modes execute the same surrounding code, so a bug
# fixed in one is fixed in both.

ui_msg() { ui_msgbox "$1" "$2"; }

# ui_yesno and ui_msgbox come from tools/lib/ui.sh. There is no wrapper here:
# one named ui_yesno used to sit in this file, and once its body delegated to
# the library the function called itself. bash answers that with SIGSEGV, and
# the run dies with exit 139 and no message.


TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RECOVERY_PROFILE=0
# Whether --recovery-profile was passed, as distinct from whether the category
# ended up selected. The flag is an instruction; the checklist is a choice.
RECOVERY_PROFILE_REQUESTED=0
# Keep the readable profile alongside the encrypted archive.
#
# Default is 1: the plaintext profile is kept unless the owner says otherwise.
# --keep-plaintext removes the question entirely, which is what makes a test run
# deterministic -- both artifacts are guaranteed to exist without depending on
# how a dialog was answered.
KEEP_PLAINTEXT=1
NO_PROMPT_PLAINTEXT=0
# Encryption is on by default. --no-encrypt produces a readable profile and no
# archive, for the case where the destination is already trusted storage and the
# owner needs to read the files directly.
ENCRYPT_PROFILE=1
# Interactive by default. Non-interactive exists so the flow can be scripted and
# tested; both modes go through the same ui_* helpers below, so there is one code
# path rather than two that drift.
INTERACTIVE=1; UI_NONINTERACTIVE=0; export UI_NONINTERACTIVE
SELECTION=""
CREDENTIAL_EXPORTS=()
# Packages to open for an owner-run export. Empty means ask (interactive) or
# open nothing (unattended).
OPEN_MANAGERS=()
LIST_MANAGERS=0
# Writing to the phone's settings is opt-out. --no-screen-control leaves the
# device untouched, for a handset where the write is refused or unwelcome.
SCREEN_CONTROL=1
BACKUP_DESTINATION=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --recovery-profile) RECOVERY_PROFILE=1; RECOVERY_PROFILE_REQUESTED=1 ;;
    --keep-plaintext) KEEP_PLAINTEXT=1; NO_PROMPT_PLAINTEXT=1 ;;
    --discard-plaintext) KEEP_PLAINTEXT=0; NO_PROMPT_PLAINTEXT=1 ;;
    --no-encrypt) ENCRYPT_PROFILE=0 ;;
    --non-interactive) INTERACTIVE=0; UI_NONINTERACTIVE=1; export UI_NONINTERACTIVE ;;
    --select) SELECTION="${2:-}"; shift ;;
    --credential-export) CREDENTIAL_EXPORTS+=("${2:-}"); shift ;;
    --open-manager) OPEN_MANAGERS+=("${2:-}"); shift ;;
    --list-managers) LIST_MANAGERS=1 ;;
    --no-screen-control) SCREEN_CONTROL=0 ;;
    -h|--help)
      # Name the command the user actually types, not this script's path.
      cat <<USAGE
Usage: ${ANDROID_RESCUE_CMD:-tools/android_backup_dialog.sh} [destination] [options]

  --recovery-profile          Collect settings, networks, app guidance and
                              owner-exported credentials.
  --no-encrypt                Do not build the encrypted archive. The profile is
                              written readable and stays that way.
  --keep-plaintext            Keep the readable copy without asking (default).
  --discard-plaintext         Keep credentials only inside the verified archive.
  --non-interactive           Ask nothing. Requires --select; uses --credential-export
                              for credential files and accepts defaults elsewhere.
  --select a,b,c              What to back up. Any of:
                              photos, downloads, whatsapp, snapchat, screenshots,
                              music, app_inventory, recovery_profile, adb_backup
  --credential-export PATH    Device path of an exported credential file.
                              Repeatable. Implies no prompting for them.
  --open-manager PACKAGE      Open this password manager on the phone so its own
                              export can be run. Repeatable. Without it the
                              interactive run offers a list and an unattended one
                              opens nothing.
  --list-managers             Print the managers installed on the attached phone
                              and exit.
  --no-screen-control         Do not touch the phone's screen settings. By
                              default the steps that need someone at the handset
                              hold the screen awake and put the setting back
                              afterwards.
USAGE
      exit 0 ;;
    --*) print_error "Unknown option: $1"; exit 1 ;;
    *) [ -z "$BACKUP_DESTINATION" ] || { print_error "Only one backup destination may be supplied."; exit 1; }; BACKUP_DESTINATION="$1" ;;
  esac
  shift
done
RECOVERY_PROFILE_DEFAULT="off"
if [ "$RECOVERY_PROFILE" -eq 1 ]; then
  RECOVERY_PROFILE_DEFAULT="on"
fi

# --list-managers: what is actually installed, so --open-manager has something
# real to name. Queries the phone directly rather than a captured profile,
# because it runs before any backup.
if [ "$LIST_MANAGERS" -eq 1 ]; then
  RECOVERY_APPS_FILE="${RECOVERY_APPS_FILE:-$ANDROID_RESCUE_ROOT/config/recovery_apps.txt}"
  installed="$(adb shell cmd package list packages 2>/dev/null | tr -d '\r')"
  if [ -z "$installed" ]; then
    print_error "No device, or the package list could not be read."
    exit 1
  fi
  found=0
  printf 'Password managers and authenticators on this device:\n\n'
  while IFS='|' read -r pkg name hint; do
    case "$pkg" in ''|\#*) continue ;; esac
    printf '%s\n' "$installed" | grep -Fxq "package:$pkg" || continue
    found=$((found + 1))
    printf '  %s\n      %s\n      %s\n\n' "$name" "$pkg" "$hint"
  done < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$RECOVERY_APPS_FILE" 2>/dev/null)
  if [ "$found" -eq 0 ]; then
    printf '  none recognised. config/recovery_apps.txt lists what is known.\n'
  else
    printf 'Open one with:  --open-manager <package>\n'
  fi
  exit 0
fi

select_backup_root() {
  if [ -n "${1:-}" ]; then
    printf '%s\n' "$1"
    return 0
  fi

  # Where a bare `adrescue data` writes. The dispatcher resolves the data
  # directory and passes it in; on its own this script keeps the old
  # cwd-relative path.
  local default_root="${ANDROID_RESCUE_DEFAULT_BACKUP_ROOT:-backups/$TIMESTAMP}"

  # No terminal to answer a dialog. Previously this ran `dialog` anyway, which
  # failed, and an unattended backup with no destination reported "cancelled".
  if [ "$INTERACTIVE" -eq 0 ]; then
    printf '%s\n' "$default_root"
    return 0
  fi

  local mode base_dir
  mode=$(ui_radiolist \
    "Backup Destination" \
    "Choose where to store the backup. Custom paths must already be mounted on this computer." \
    local "$default_root" on \
    custom "Custom destination path" off)

  if [ $? -ne 0 ]; then
    return 1
  fi

  case "$mode" in
    local)
      printf '%s\n' "$default_root"
      ;;
    custom)
      base_dir=$(ui_inputbox \
        "Destination Path" \
        "Enter a destination directory. A timestamped subfolder will be created inside it." \
        "${ANDROID_BACKUP_DEST:-/mnt/nas/android-backups}")
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
  ui_msg "Backup Destination Unusable" "Cannot write to:\n$BACKUP_ROOT\n\nCheck the path is mounted and writable, then run the backup again. Nothing has been backed up."
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
  local pull_status=0 pct

  if adb_shell_exists "$source_path"; then
    mkdir -p "$(dirname "$target_path")"
    if progress_active; then
      # adb prints its own progress -- "[ 11%] /sdcard/Download/zoom.apk: 98%"
      # -- straight to the terminal, which tore through the gauge. Its overall
      # percentage is read back out and drawn instead.
      #
      # The reader runs in a subshell, which is fine here: it only draws. The
      # pull's exit status comes from PIPESTATUS, because this script runs
      # without pipefail on purpose.
      progress_phase "Pulling $(basename "$source_path")" ""
      adb pull -a "$source_path" "$target_path" 2>&1 | while IFS= read -r line; do
        case "$line" in
          \[*%\]*)
            pct="${line#\[}"; pct="${pct%%%*}"; pct="${pct// /}"
            case "$pct" in
              ''|*[!0-9]*) ;;
              *) progress_within "$pct" "${line#*] }" ;;
            esac
            ;;
        esac
      done
      pull_status="${PIPESTATUS[0]}"
    else
      print_info "Pulling $source_path -> $target_path"
      adb pull -a "$source_path" "$target_path"
      pull_status=$?
    fi
    if [ "$pull_status" -eq 0 ]; then
      log_manifest "OK $source_path -> shared/$target_name"
    else
      log_manifest "FAILED $source_path -> shared/$target_name"
      BACKUP_FAILURES=$((BACKUP_FAILURES + 1))
    fi
  else
    # print_warning would write straight to the terminal underneath an open
    # gauge. A phone without WhatsApp Business or Snapchat produces a dozen of
    # these, and they shredded the display into overlapping fragments.
    progress_warn "Skipping missing path: $source_path"
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

# Offer the detected managers and open the chosen ones, one at a time, so the
# owner can run each app's own export.
#
# Nothing is opened unless it was asked for: --open-manager names a package
# when unattended, and the interactive path shows a checklist of what is
# actually installed rather than assuming.
# Open one detected app, by whichever route it actually has.
#
# `monkey -p` only works for an app with a LAUNCHER activity. Samsung Pass has
# none -- it is reached through Settings -- so on the first phone this was run
# against, monkey failed and the tool reported "could not open" for an app that
# was never openable that way. An app with no launcher gets its configured
# launch spec, and one with neither is said so plainly rather than retried.
launch_app() {
  local i="$1"
  local pkg="${DETECTED_APPS[$i]}" name="${DETECTED_NAMES[$i]}" launch="${DETECTED_LAUNCH[$i]}"

  if [ -n "$launch" ]; then
    # shellcheck disable=SC2086  # the spec is a word list from config
    if adb shell am start $launch >/dev/null 2>&1; then
      log_manifest "OPENED $pkg via $launch"
      return 0
    fi
    print_warning "Could not open $name; follow the steps in recovery_actions.txt."
    log_manifest "FAILED to open $pkg via $launch"
    return 1
  fi

  if ! adb shell "cmd package resolve-activity --brief -c android.intent.category.LAUNCHER $pkg" 2>/dev/null | tr -d '\r' | grep -q "^$pkg/"; then
    print_warning "$name has no launcher screen; follow the steps in recovery_actions.txt."
    log_manifest "NOT LAUNCHABLE $pkg (no launcher activity, no launch spec)"
    return 1
  fi

  if adb shell monkey -p "$pkg" 1 >/dev/null 2>&1; then
    log_manifest "OPENED $pkg for owner export"
    return 0
  fi
  print_warning "Could not open $name; follow the steps in recovery_actions.txt."
  log_manifest "FAILED to open $pkg"
  return 1
}

open_recovery_apps() {
  [ "${#DETECTED_APPS[@]}" -gt 0 ] || {
    if [ "${APPS_LIST_USABLE:-1}" -eq 0 ]; then
      log_manifest "SKIPPED opening recovery apps: the installed-app list could not be read"
    else
      log_manifest "SKIPPED opening recovery apps: none detected"
    fi
    return 0
  }

  local chosen=() i pkg name

  if [ "${#OPEN_MANAGERS[@]}" -gt 0 ]; then
    for pkg in "${OPEN_MANAGERS[@]}"; do
      local found=0
      for i in "${!DETECTED_APPS[@]}"; do
        [ "${DETECTED_APPS[$i]}" = "$pkg" ] && { chosen+=("$i"); found=1; break; }
      done
      [ "$found" -eq 1 ] || print_warning "--open-manager $pkg is not installed on this device; skipping."
    done
  elif [ "$INTERACTIVE" -eq 0 ]; then
    log_manifest "SKIPPED opening recovery apps: unattended and no --open-manager given"
    return 0
  else
    local args=()
    for i in "${!DETECTED_APPS[@]}"; do
      args+=("$i" "${DETECTED_NAMES[$i]}" off)
    done
    local picked
    picked=$(ui_checklist \
      "Open A Password Manager" \
      "Choose which to open on the phone so you can run its own export. Nothing is opened unless you pick it, and this tool never enters a secret or approves a prompt." \
      "${args[@]}") || picked=""
    for i in $picked; do chosen+=("$i"); done
  fi

  if [ "${#chosen[@]}" -eq 0 ]; then
    log_manifest "SKIPPED opening recovery apps: none selected"
    return 0
  fi

  for i in "${chosen[@]}"; do
    pkg="${DETECTED_APPS[$i]}"
    name="${DETECTED_NAMES[$i]}"
    launch_app "$i" || true
    ui_msg "$name" "Complete the export in $name on the phone, then return here.\n\n${DETECTED_HINTS[$i]}\n\nThis tool will not enter secrets or approve prompts."
  done
}

# Declining the passphrase is a choice, not a failure -- as long as there is
# nothing in the profile that needs an archive to stay secret.
#
# With no credential exports the profile holds settings, Wi-Fi records and an
# app list, already written 0600 inside a 0700 directory. Refusing to encrypt
# that is reasonable, and reporting "recovery profile was not completed" is
# simply untrue: everything asked for was captured.
#
# With exports present the profile holds someone's passwords in the clear, so
# the run still fails and says exactly why.
encryption_declined() {
  local reason="$1" count="$2" root="$3"
  log_manifest "$reason"
  if [ "$count" -gt 0 ]; then
    ui_msg "Encryption Cancelled" "$count readable credential export(s) are sitting at:\n$root/imports/\n\nNo encrypted archive was created. Move them to secure storage, or run the backup again and set a passphrase."
    return 1
  fi
  log_manifest "PLAINTEXT profile at $root (no credential exports to protect)"
  print_warning "No passphrase set, so no encrypted archive was created."
  print_info "The recovery profile is readable at: $root"
  return 0
}

collect_recovery_profile() {
  local profile_root="$BACKUP_ROOT/recovery_profile" export_path imported_path passphrase confirmation
  mkdir -p "$profile_root/imports" "$profile_root/root_system"
  chmod 700 "$profile_root" "$profile_root/imports" "$profile_root/root_system"
  # Non-interactive defaults to yes: asking for --recovery-profile on the
  # command line is the consent.
  ui_yesno "Recovery Profile Consent" "This optional profile may contain passwords, network details, settings, and app inventory. Continue only for a phone you own or are authorized to recover." yes \
    || { log_manifest "SKIPPED recovery profile: consent declined"; return 0; }
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
  printf "%s\n" "Android recovery actions" "" "Use each provider's own export or transfer flow. This tool never bypasses screen locks, app protections, or security prompts." "" >"$profile_root/recovery_actions.txt"
  # Some adb and device combinations allocate a PTY and return CRLF, which a
  # `grep -Fx "package:x"` would never match. Stripping CR costs nothing and
  # removes the difference between those devices and the rest.
  has_package() { tr -d '\r' < "$profile_root/apps.txt" | grep -Fxq "package:$1"; }

  # The known managers come from config/recovery_apps.txt rather than being
  # written out here. They used to be a hardcoded list repeated three times,
  # which is why Samsung Pass -- installed on the first phone this was run
  # against -- was missing from all three.
  RECOVERY_APPS_FILE="${RECOVERY_APPS_FILE:-$ANDROID_RESCUE_ROOT/config/recovery_apps.txt}"
  DETECTED_APPS=()
  DETECTED_NAMES=()
  DETECTED_HINTS=()
  DETECTED_LAUNCH=()
  while IFS='|' read -r pkg name hint launch; do
    case "$pkg" in ''|\#*) continue ;; esac
    has_package "$pkg" || continue
    DETECTED_APPS+=("$pkg")
    DETECTED_NAMES+=("$name")
    DETECTED_HINTS+=("$hint")
    DETECTED_LAUNCH+=("${launch:-}")
    printf '%s\n  %s\n' "$name ($pkg)" "$hint" >>"$profile_root/recovery_actions.txt"
  done < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$RECOVERY_APPS_FILE" 2>/dev/null)

  # An empty apps.txt answers every has_package with "no", so a phone whose
  # package list could not be read reported zero managers exactly like a phone
  # that has none. Seen on a real run: adb dropped the device for one command,
  # apps.txt came back empty, and the manifest recorded "Recovery apps
  # detected: 0" for a phone that had them. The owner is then never offered the
  # export step at all.
  APPS_LIST_USABLE=1
  if [ ! -s "$profile_root/apps.txt" ] || ! grep -q '^package:' "$profile_root/apps.txt"; then
    APPS_LIST_USABLE=0
    BACKUP_FAILURES=$((BACKUP_FAILURES + 1))
    log_manifest "FAILED recovery app detection: the installed-app list is empty or unreadable"
    printf '%s\n' "The installed-app list could not be read, so no password manager could be detected. Open yours by hand and run its export before wiping the phone." >>"$profile_root/recovery_actions.txt"
    progress_warn "Could not read the installed app list; no password manager could be detected."
  elif [ "${#DETECTED_APPS[@]}" -eq 0 ]; then
    printf '%s\n' "No known password manager or authenticator was detected on this device." >>"$profile_root/recovery_actions.txt"
  fi
  log_manifest "Recovery apps detected: ${#DETECTED_APPS[@]} (app list usable: $APPS_LIST_USABLE)"
  chmod 600 "$profile_root/recovery_actions.txt"
  if adb shell "su -c id" >/dev/null 2>&1; then
    ui_yesno "Root-only System Sources" "Root is available. Collect only readable known Android Wi-Fi system records? No app-private database scan will be performed." no && {
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
  # Defaults to no unattended: this drives the phone's UI and expects someone
  # standing at it to complete an export.
  # Which manager to open is a choice, not a sweep. A phone commonly has both
  # Chrome and Samsung Pass, and opening every detected app in turn means
  # sitting through prompts for ones the owner does not use.
  open_recovery_apps
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
  # Paths given on the command line are used verbatim and nothing is asked. This
  # is also the only way to supply them when running unattended.
  local supplied_idx=0 supplied_total=${#CREDENTIAL_EXPORTS[@]}
  while :; do
    if [ "$supplied_total" -gt 0 ]; then
      if [ "$supplied_idx" -ge "$supplied_total" ]; then break; fi
      export_path="${CREDENTIAL_EXPORTS[$supplied_idx]}"
      supplied_idx=$((supplied_idx + 1))
    elif [ "$INTERACTIVE" -eq 0 ]; then
      break
    else
      export_path=$(ui_inputbox "Credential Export ($credential_count imported)" "Exact phone path of an owner-exported password file (csv, json, 1pux, kdbx).\n\nLeave empty and press OK when there are no more." "$credential_prefill") || export_path=""
    fi
    credential_prefill=""
    [ -n "$export_path" ] || break

    if ! adb_shell_exists "$export_path"; then
      log_manifest "MISSING credential export $export_path"
      BACKUP_FAILURES=$((BACKUP_FAILURES + 1))
      ui_msg "Not Found" "No file at:\n$export_path\n\nCheck the path on the phone and try again."
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
      ui_msg "Empty File" "$export_path copied as 0 bytes and was discarded.\n\nRe-export it on the phone, then add it again."
      continue
    fi
    if [ -n "$device_size" ] && [ "$device_size" -ne "$local_size" ]; then
      log_manifest "FAILED credential export size mismatch $export_path (device=$device_size local=$local_size)"
      BACKUP_FAILURES=$((BACKUP_FAILURES + 1))
      rm -f "$imported_path"
      ui_msg "Incomplete Copy" "$export_path copied incompletely and was discarded.\n\nReconnect the phone and add it again."
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
  if [ "$ENCRYPT_PROFILE" -eq 0 ]; then
    # No archive by request. The readable profile is the deliverable, so say
    # exactly where it is and that nothing encrypted was produced.
    log_manifest "SKIPPED recovery profile encryption (--no-encrypt)"
    log_manifest "PLAINTEXT profile at $profile_root"
    if [ "$credential_count" -gt 0 ]; then
      log_manifest "RETAINED $credential_count readable credential export(s) under $profile_root/imports/"
    fi
    print_warning "Recovery profile written UNENCRYPTED to $profile_root"
    return 0
  fi

  # --non-interactive promises never to reach a dialog. Asking for a passphrase
  # here broke that promise and, with no terminal to answer it, made an
  # unattended --recovery-profile run impossible to complete unless
  # --no-encrypt was also passed. Treat it as a decline instead, which is
  # harmless with no credential exports and a named failure with them.
  if [ "$INTERACTIVE" -eq 0 ]; then
    encryption_declined "SKIPPED recovery profile encryption: unattended, no passphrase can be asked for" "$credential_count" "$profile_root"
    return $?
  fi
  if ! passphrase=$(ui_passwordbox "Encrypt Recovery Profile" "Create a passphrase for the encrypted recovery archive."); then
    encryption_declined "CANCELLED recovery profile encryption" "$credential_count" "$profile_root"
    return $?
  fi
  if ! confirmation=$(ui_passwordbox "Confirm Passphrase" "Re-enter the recovery archive passphrase."); then
    encryption_declined "CANCELLED recovery profile encryption confirmation" "$credential_count" "$profile_root"
    return $?
  fi
  # Two boxes typed blind, at the end of a long run. Getting it wrong threw
  # away the encrypted archive entirely and reported a failed profile, with no
  # way back but to run the whole backup again.
  passphrase_tries=1
  while [ -z "$passphrase" ] || [ "$passphrase" != "$confirmation" ]; do
    log_manifest "RETRY recovery profile passphrase (attempt $passphrase_tries did not match)"
    if [ "$passphrase_tries" -ge 3 ]; then
      unset passphrase confirmation
      log_manifest "FAILED recovery profile encryption: passphrase mismatch"
      return 1
    fi
    passphrase_tries=$((passphrase_tries + 1))
    if ! passphrase=$(ui_passwordbox "Passphrases Did Not Match" "The two entries were different, or empty.\n\nCreate a passphrase for the encrypted recovery archive."); then
      encryption_declined "CANCELLED recovery profile encryption" "$credential_count" "$profile_root"
      return $?
    fi
    if ! confirmation=$(ui_passwordbox "Confirm Passphrase" "Re-enter the recovery archive passphrase."); then
      encryption_declined "CANCELLED recovery profile encryption confirmation" "$credential_count" "$profile_root"
      return $?
    fi
  done
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
  if [ "$archive_ok" -eq 1 ]; then chmod 600 "$BACKUP_ROOT/recovery-profile.tar.gpg"; log_manifest "OK recovery-profile.tar.gpg verified"; log_manifest "PLAINTEXT profile retained at $profile_root"; else log_manifest "FAILED recovery profile encryption"; ui_msg "Recovery Profile Encryption Failed" "The encrypted archive was not created. The recovery profile remains at:\n$profile_root\n\nMove it to secure storage or retry the backup before wiping the phone."; return 1; fi
  unset passphrase confirmation
  if [ "$credential_count" -gt 0 ]; then
    keep_them=0
    if [ "$NO_PROMPT_PLAINTEXT" -eq 1 ]; then
      # Decided on the command line; asking again would only invite a mistake.
      [ "$KEEP_PLAINTEXT" -eq 1 ] && keep_them=1
    elif ui_yesno "Retain Plaintext Credentials?" "$credential_count readable credential export(s) sit under:\n$profile_root/imports/\n\nKeep them beside the encrypted archive?\n\nYes keeps both copies. No keeps them only inside the archive, which has already been verified to extract." yes; then
      keep_them=1
    fi
    if [ "$keep_them" -eq 1 ]; then
      log_manifest "RETAINED $credential_count plaintext credential export(s)"
    else
      # Only reached when the archive verified, so this cannot be the last copy.
      rm -f "$profile_root"/imports/* "$profile_root/credential_exports.txt"
      rmdir "$profile_root/imports" 2>/dev/null || true
      log_manifest "REMOVED $credential_count plaintext credential export(s) after verified encryption"
    fi
  fi
}
# The device was checked before any of this was created; see the top of the file.
print_info "Writing backup to $BACKUP_ROOT"

cat >"$MANIFEST" <<EOF
Android backup manifest
Started: $(date +%Y-%m-%dT%H:%M:%S%z)
Destination: $BACKUP_ROOT

EOF

if [ "$INTERACTIVE" -eq 0 ]; then
  if [ -z "$SELECTION" ]; then
    print_error "--non-interactive requires --select (see --help)."
    exit 2
  fi
  CHOICES="$(printf '%s' "$SELECTION" | tr ',' '\n')"
else
CHOICES=$(ui_checklist \
  "Android Backup" \
  "Select data to preserve. Private app databases usually require the app's official transfer feature." \
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
fi

# Reset before reading the checklist. The --recovery-profile flag sets this to
# 1 up front so the box starts checked; without clearing it here, unchecking
# the box left it at 1 and the profile was collected against the user's
# explicit choice.
RECOVERY_PROFILE=0

# The credential step runs first, before any bulk copy.
#
# It is the only part that needs someone at the handset, and it used to run
# last -- after a photo pull that took 45 minutes on the phone this was tested
# against. Whoever is standing there should be asked for what is needed while
# they are still standing there.
#
# CHOICES is scanned for it up front because the flag used to be set from inside
# the loop below, which is what put the step at the end.
case " $(printf '%s' "$CHOICES" | tr '\n' ' ') " in
  *" recovery_profile "*) RECOVERY_PROFILE=1 ;;
esac

# An explicit --recovery-profile is an instruction, not a default.
#
# Unchecking the box in the dialog must still turn it off -- that is a choice
# made after the flag. But a --select that simply omits the category, with the
# flag given on the same command line, was silently dropping the step somebody
# asked for by name. That is the shape of a backup that loses what it was told
# to keep.
if [ "$RECOVERY_PROFILE_REQUESTED" -eq 1 ] && [ "$RECOVERY_PROFILE" -eq 0 ] && [ "$INTERACTIVE" -eq 0 ]; then
  print_warning "--recovery-profile was given but --select omits recovery_profile; collecting it anyway."
  RECOVERY_PROFILE=1
fi

RECOVERY_SKIPPED=0
if [ "$RECOVERY_PROFILE" -eq 1 ]; then
  SCREEN_STATE_FILE="$BACKUP_ROOT/.screen_state"

  # stay_on_while_plugged_in survives a reboot, so an interrupted run must not
  # leave a stranger's phone set to never sleep while charging. The trap is
  # armed before the setting is touched and covers the signals a terminal
  # actually sends; screen_hold_end is idempotent, so the normal path calling it
  # too is harmless.
  trap 'screen_hold_end' EXIT
  trap 'screen_hold_end; exit 130' INT
  trap 'screen_hold_end; exit 143' TERM

  screen_hold_begin

  if screen_wait_unlock; then
    if ! collect_recovery_profile; then
      screen_hold_end
      # Not exit 1. The categories the user selected have not run yet, and
      # abandoning photos and downloads protects nothing that has already gone
      # wrong here. Count it like every other failure and let the closing
      # summary report it, after the rest of the backup has been written.
      BACKUP_FAILURES=$((BACKUP_FAILURES + 1))
      log_manifest "FAILED recovery profile"
      print_warning "Recovery profile was not completed. The rest of the backup continues; review backup_manifest.txt before wiping the phone."
    fi
  else
    # Not a failure of the backup: everything else still runs. But it must be
    # impossible to miss, because the phone may be wiped on the strength of it.
    RECOVERY_SKIPPED=1
    log_manifest "SKIPPED credential steps: phone stayed locked"
    print_warning "PHONE STAYED LOCKED — credentials and settings were NOT captured."
    ui_msg "Credentials Skipped" "The phone stayed locked, so the password export could not be reached.\n\nNO CREDENTIALS OR SETTINGS WERE CAPTURED.\n\nEverything else is still being backed up. To capture them, unlock the phone and run again with --recovery-profile."
  fi

  screen_hold_end
fi

# One gauge for the copying, opened only now: every prompt, consent and
# passphrase is behind us, and a dialog cannot be drawn over a dialog.
#
# A PIPE trap and nothing else. The EXIT, INT and TERM traps belong to
# screen_hold_end, which puts a phone's stay-awake setting back, and replacing
# them to add cleanup here would leave a stranger's phone set to never sleep.
# SIGPIPE is untaken, and without it a dialog that dies mid-copy kills this
# script outright before the manifest is finished.
trap 'progress_session_end' PIPE
progress_session_begin "Backing up shared data"
choice_total=0
for choice in $CHOICES; do choice_total=$((choice_total + 1)); done
[ "$choice_total" -gt 0 ] || choice_total=1
choice_index=0

for choice in $CHOICES; do
  choice_base=$((choice_index * 100 / choice_total))
  choice_span=$((100 / choice_total))
  choice_index=$((choice_index + 1))
  progress_band "$choice" "$choice_base" "$choice_span"
  case "$choice" in
    photos)
      # Discovery, not a path list. DCIM/Pictures/Movies misses the removable
      # card, vendor gallery folders, received app media and any folder the
      # owner made themselves. android_photo_backup.sh enumerates through
      # MediaStore and a filesystem sweep, then verifies every file it claims.
      # android_photo_backup.sh draws its own gauge, and two dialogs cannot
      # share one terminal. Ours comes down for the duration and goes back up
      # afterwards, so there is always exactly one bar on screen.
      photos_resume=0
      if progress_active; then
        progress_session_end
        photos_resume=1
      fi
      if "$SCRIPT_DIR/android_photo_backup.sh" "$BACKUP_ROOT"; then
        log_manifest "OK photos verified (see photos_report.txt)"
      else
        log_manifest "FAILED photos incomplete (see missing_photos.txt)"
        BACKUP_FAILURES=$((BACKUP_FAILURES + 1))
      fi
      if [ "$photos_resume" -eq 1 ]; then
        progress_session_begin "Backing up shared data"
        progress_band "$choice" "$choice_base" "$choice_span"
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
      # Already handled above, before the copies.
      ;;
    adb_backup)
      # adb backup prints its own deprecation warning and then asks the owner
      # to unlock the phone and confirm on the handset. Behind a gauge that
      # instruction is invisible, and the run looks hung at 88% while the phone
      # waits to be tapped. The bar steps aside, as it does for the photo tool.
      backup_resume=0
      if progress_active; then
        progress_session_end
        backup_resume=1
      fi
      print_warning 'Trying deprecated adb backup. Unlock the phone and confirm there when prompted.'
      if adb backup -apk -obb -shared -all -f "$BACKUP_ROOT/adb_backup.ab"; then
        log_manifest "OK adb_backup.ab"
      else
        log_manifest "FAILED adb_backup.ab"
      fi
      if [ "$backup_resume" -eq 1 ]; then
        progress_session_begin "Backing up shared data"
        progress_band "$choice" "$choice_base" "$choice_span"
      fi
      ;;
  esac
done

progress_session_end

cat >>"$MANIFEST" <<EOF

Finished: $(date +%Y-%m-%dT%H:%M:%S%z)

Manual app actions still recommended:
- WhatsApp: verify built-in chat transfer or Google Drive encrypted backup.
- Snapchat: verify Memories sync/export inside Snapchat.
- Signal/authenticators/banking apps: use each app's official transfer/export.
EOF

if [ "$BACKUP_FAILURES" -gt 0 ]; then
ui_msg "Backup Incomplete" "$BACKUP_FAILURES item(s) FAILED.\n\nBackup root:\n$BACKUP_ROOT\n\nOpen backup_manifest.txt and search for FAILED before wiping the phone."
  print_error "Backup incomplete: $BACKUP_FAILURES item(s) failed. See $MANIFEST"
  exit 1
fi

# Name both recovery-profile artifacts explicitly. During testing the point is
# to confirm the readable tree and the encrypted archive are BOTH present and
# agree; leaving that to be inferred from the manifest is how it goes unchecked.
completion_detail=""
# A skipped credential step is reported at the end as well as when it happens.
# The closing summary is the thing someone reads before wiping the phone, and it
# previously mentioned only outright failures.
if [ "$RECOVERY_SKIPPED" -eq 1 ]; then
  completion_detail="\n\nCREDENTIALS AND SETTINGS WERE NOT CAPTURED.\nThe phone stayed locked. Unlock it and run again with --recovery-profile\nbefore wiping this device."
  print_warning "Credentials and settings were NOT captured: the phone stayed locked."
fi
if [ "$RECOVERY_PROFILE" -eq 1 ] && [ -d "$BACKUP_ROOT/recovery_profile" ]; then
  if [ -f "$BACKUP_ROOT/recovery-profile.tar.gpg" ]; then
    completion_detail="\n\nRecovery profile, both copies:\n  readable:  $BACKUP_ROOT/recovery_profile/\n  encrypted: $BACKUP_ROOT/recovery-profile.tar.gpg\n\nConfirm they agree:\n  tools/verify_recovery_archive.sh $BACKUP_ROOT"
    print_info "Readable profile:  $BACKUP_ROOT/recovery_profile/"
    print_info "Encrypted archive: $BACKUP_ROOT/recovery-profile.tar.gpg"
    print_info "Verify they agree: tools/verify_recovery_archive.sh $BACKUP_ROOT"
  else
    completion_detail="\n\nRecovery profile is UNENCRYPTED at:\n  $BACKUP_ROOT/recovery_profile/\n\nAnything under imports/ is readable. Move it to trusted storage."
    print_warning "Recovery profile is UNENCRYPTED at $BACKUP_ROOT/recovery_profile/"
  fi
fi

ui_msg "Backup Complete" "Backup written to:\n$BACKUP_ROOT\n\nReview backup_manifest.txt before wiping or restoring the phone.$completion_detail"
print_success "Backup complete: $BACKUP_ROOT"
