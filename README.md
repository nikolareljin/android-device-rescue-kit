# Android Device Rescue Kit

<p align="center">
  <img src="docs/assets/logo.svg" width="88" alt="Android Device Rescue Kit logo">
</p>

<p align="center">
  <img src="docs/assets/readme-hero.svg" alt="Android Device Rescue Kit showing an Android phone and local recovery terminal" width="960">
</p>

`android-device-rescue-kit` is a small field toolkit for collecting, backing up, restoring, and triaging Android devices with failures such as reboot loops, kernel panics, watchdog resets, severe performance problems, radio crashes, and storage-related instability.

The repository is designed so public commits contain only tooling and documentation. Device captures are ignored by default because Android bugreports and logs can include personal data.

Current version: `0.3.1`. Versioning rules are documented in [Versioning](docs/versioning.md).

## Documentation Site

The GitHub Pages site provides a visual quick start, command reference, and recovery-profile safety guidance. It is published from `docs/` after changes reach `main`.

## What It Collects

The collection script uses `adb` to gather:

- Full Android bugreport
- `getprop`
- `logcat` from all, radio, crash, events, kernel, and main buffers where available
- Dropbox reset/crash entries such as `SYSTEM_LAST_KMSG`, tombstones, watchdogs, and boot records
- Battery, thermal, telephony, telecom, connectivity, Wi-Fi, activity, package, and disk stats

## Install

Install from Linux or macOS:

```bash
curl -fsSL https://raw.githubusercontent.com/nikolareljin/android-device-rescue-kit/main/install.sh | bash
```

For Windows through WSL 2, use the PowerShell one-liner and platform notes in [Installation](docs/installation.md).

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

Use `./dump data [destination] --recovery-profile` for an opt-in encrypted recovery profile containing available settings, network details, installed-app guidance, and owner-exported password-manager data. It never bypasses Android or app security controls.

For the full dump, preserve, and prompt workflow, see [Usage Guide](docs/usage.md).

Backup destinations can be any writable directory visible to the computer running the script.

## Helper Dependency

This repository expects `script-helpers` at `scripts/script-helpers`. Run `scripts/bootstrap_script_helpers.sh` to clone it. The helper repo provides dependency installation, terminal dialog sizing, OS detection, and common logging functions used by the interactive backup and restore scripts.

This repository also expects `ci-helpers` at `scripts/ci-helpers`. Run `./update` to install both helper repositories, host dependencies, and local git hooks. CI workflows use `ci-helpers` for PR checks, release branch version checks, release tag checks, automatic release tagging, and secret scanning.

Both helper repositories track their `production` release ref rather than a pinned commit, so a fresh clone picks up the current release of each.

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

---

## Clone traffic

![Clone traffic](https://raw.githubusercontent.com/nikolareljin/stats/main/charts/android-device-rescue-kit.svg)

_Updated daily. Total and unique cloners over the last 14 days._
