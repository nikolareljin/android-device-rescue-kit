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
