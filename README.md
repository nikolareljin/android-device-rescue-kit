# Android Device Rescue Kit

`android-device-rescue-kit` is a small field toolkit for collecting, backing up, restoring, and triaging Android devices with failures such as reboot loops, kernel panics, watchdog resets, severe performance problems, radio crashes, and storage-related instability.

The repository is designed so public commits contain only tooling and documentation. Device captures are ignored by default because Android bugreports and logs can include personal data.

Current version: `0.1.1`. Versioning rules are documented in [Versioning](docs/versioning.md).

## What It Collects

The collection script uses `adb` to gather:

- Full Android bugreport
- `getprop`
- `logcat` from all, radio, crash, events, kernel, and main buffers where available
- Dropbox reset/crash entries such as `SYSTEM_LAST_KMSG`, tombstones, watchdogs, and boot records
- Battery, thermal, telephony, telecom, connectivity, Wi-Fi, activity, package, and disk stats

## Quick Start

Install helper scripts and host dependencies:

```bash
./update
```

Enable USB debugging on the device, connect it, then run:

```bash
./dump log
```

The script writes to `captures/<timestamp>/`, which is ignored by git.

To analyze a capture:

```bash
./prompt captures/<timestamp>
```

The dump command extracts useful files from a bugreport zip when present, searches for common reset causes, and writes a text report into the capture directory. The prompt command creates `analysis_prompt.md` for local or hosted model analysis.

For Android dump details and configurable capture targets, see [Android Dumping](docs/android_dumping.md).

For emergency user-data backup and shared-storage restore workflows, see [Backup And Restore](docs/backup_restore.md).

For the full dump, preserve, and prompt workflow, see [Usage Guide](docs/usage.md).

Backup destinations can be any writable directory visible to the computer running the script.

## Helper Dependency

This repository expects `script-helpers` at `scripts/script-helpers`. Run `scripts/bootstrap_script_helpers.sh` to clone it. The helper repo provides dependency installation, terminal dialog sizing, OS detection, and common logging functions used by the interactive backup and restore scripts.

This repository also expects `ci-helpers` at `scripts/ci-helpers`. Run `./update` to install both helper repositories, host dependencies, and local git hooks. CI workflows use `ci-helpers` for PR checks, release branch version checks, release tag checks, and secret scanning.

## Privacy Rule

Do not commit raw captures. Treat all bugreports, logcats, dumpsys output, kernel logs, tombstones, and extracted archives as private unless they have been reviewed and redacted.

Before publishing:

```bash
git status --short
git check-ignore -v captures/* s22_dumps/* analysis_kernel_logs/*
```

## Typical Root-Cause Clues

- Kernel panic: `Kernel panic`, `panic - not syncing`, `BUG:`, `Oops`, `Call trace`
- Storage/filesystem: `F2FS`, `EXT4`, `I/O error`, `ufs`, `ufshcd`, `mmc`, `blk_update_request`
- Watchdog: `watchdog bite`, `TZBSP_ERR_FATAL`, `AOP_NON_SECURE_WD_BITE`
- Modem/radio: `subsys`, `modem`, `SSR`, `fatal`, `glink`, `qmi`
- Thermal/battery: `thermal shutdown`, `overheat`, `battery`, `VBAT`, `PMIC`
- App/system-server failures: `system_server`, `watchdog`, `ANR`, `tombstone`, `FATAL EXCEPTION`

## Repository Name

Recommended public repository name: `android-device-rescue-kit`.

It is broad enough for backup/restore and performance triage, but still clear that this is an Android device recovery and debugging toolkit.
