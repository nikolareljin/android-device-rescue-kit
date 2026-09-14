# Backup And Restore

This project includes a Dialog-based ADB workflow for preserving user-accessible Android data before a factory reset, firmware reinstall, or device replacement.

## Important Limits

ADB can usually copy shared storage such as photos, videos, downloads, screenshots, exported documents, and app media under `/sdcard`.

ADB usually cannot copy private app data from `/data/data/<package>` on an unrooted production phone. That affects apps such as WhatsApp, Signal, Snapchat, banking apps, authenticators, and many games.

For those apps, use their official migration/export feature in addition to this repository's ADB backup:

- WhatsApp: use WhatsApp's built-in chat transfer or encrypted Google Drive backup. Also preserve visible WhatsApp media from `/sdcard/Android/media/com.whatsapp/WhatsApp` where present.
- Snapchat: saved Memories are account/cloud-backed inside Snapchat. Locally exported photos/videos may be under DCIM, Pictures, Movies, or Snapchat folders.
- Signal: use Signal's own encrypted backup/transfer.
- Authenticator apps: export or transfer inside each app before wiping the phone.

## Backup

Install dependencies:

```bash
./update
```

Run:

```bash
tools/android_backup_dialog.sh
```

The script writes to `backups/<timestamp>/`, which is ignored by git.

For WhatsApp, the script preserves consumer and business shared-storage folders when present, including Android media folders, legacy folders, local backup folders, and common exported-chat folders. It still cannot guarantee private chat database preservation from an unrooted phone; use WhatsApp's official transfer or backup flow before wiping.

For Snapchat, the script preserves shared-storage app media and exported media folders when present. It cannot guarantee private chats or unsynced Memories; verify sync/export inside Snapchat before wiping.

The script also lets you choose a custom destination. Use any writable directory visible to the computer running the script, including already mounted external storage or network storage:

```bash
mkdir -p /mnt/android-backups
tools/android_backup_dialog.sh
```

You can also pass a destination explicitly:

```bash
tools/android_backup_dialog.sh /mnt/android-backups/s22-before-reset
```

ADB pulls data through the computer, so the destination must be a local filesystem path from the script's point of view, such as `/mnt/...`, `/media/...`, or another mounted path.

## Restore

On the restored or replacement phone, enable USB debugging and run:

```bash
tools/android_restore_dialog.sh backups/<timestamp>
```

The restore script pushes selected shared-storage folders back to `/sdcard`. Install and sign in to sensitive apps before expecting their cloud or official transfer mechanisms to finish restoring private content.

## Recovery Profile (opt-in)

For Android phones only, add `--recovery-profile` to preserve an owner-approved recovery profile alongside the ordinary shared-storage backup:

```bash
./dump data /mnt/android-backups/phone-before-reset --recovery-profile
```

The profile collects available network and settings information, an installed-app inventory, and owner-selected password-manager CSV exports. It can open detected recovery apps, but it never enters secrets, defeats device or app protections, or approves export prompts. On rooted phones it can optionally copy only known readable Android Wi-Fi system records; it does not scan app-private databases.

The tool creates an encrypted profile archive at `recovery-profile.tar.gpg`. Each run asks whether to retain the readable `recovery_profile/credentials.txt`; choose No unless an offline plaintext recovery copy is explicitly needed. Keep the archive passphrase separate from the backup. Authenticator seeds, passkeys, banking credentials, and provider-controlled recovery data require that providers official transfer or export flow.

Google Password Manager exports require owner authentication on the phone. After exporting, supply the exact phone path of the CSV when prompted. The tool copies only that selected file; it does not search the phone for credentials.
