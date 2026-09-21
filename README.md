# Android Device Rescue Kit

<p align="center">
  <img src="docs/assets/logo.svg" width="88" alt="Android Device Rescue Kit logo">
</p>

<p align="center">
  <img src="docs/assets/readme-hero.svg" alt="Android Device Rescue Kit showing an Android phone and local recovery terminal" width="960">
</p>

`android-device-rescue-kit` is a small field toolkit for collecting, backing up, restoring, and triaging Android devices with failures such as reboot loops, kernel panics, watchdog resets, severe performance problems, radio crashes, and storage-related instability.

The repository is designed so public commits contain only tooling and documentation. Device captures are ignored by default because Android bugreports and logs can include personal data.

Current version: `0.3.2`. Versioning rules are documented in [Versioning](docs/versioning.md).

## Documentation Site

The GitHub Pages site provides a visual quick start, command reference, and recovery-profile safety guidance. It is published from `docs/` after changes reach `main`.

## What It Collects

The collection script uses `adb` to gather:

- Full Android bugreport
- `getprop`
- Every photo and video on the device, verified against the phone after copying
- `logcat` from all, radio, crash, events, kernel, main, and system buffers where available
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

### Photos and videos

Photos are the thing most people cannot replace, so finding all of them is
treated as a guarantee rather than a best effort:

```bash
./dump photos
```

Every photo and video is discovered twice over -- through Android's MediaStore,
which knows the removable card and every app folder, and through a filesystem
sweep, which catches files copied in over USB that MediaStore has not indexed.
The two lists are merged into `photos_index.txt`, each file is copied with the
device's directory structure preserved, and then every copy is re-measured
against its size on the phone.

The command exits non-zero unless all of them are present and whole. Anything
missing is listed in `missing_photos.txt` with the reason. An interrupted run
can simply be repeated: files already copied at the right size are skipped, and
a file left truncated is copied again.

Thumbnails, caches and trashed files are excluded; the lists live in
`config/photo_extensions.txt` and `config/photo_exclude_patterns.txt`.

### Credentials and settings

Use `./dump data [destination] --recovery-profile` for an opt-in recovery
profile containing available settings, network details, installed-app guidance,
and owner-exported password-manager data. It never bypasses Android or app
security controls: passwords come from a file you export on the phone, and the
tool verifies that file arrived whole rather than extracting anything itself.

By default the profile is encrypted to `recovery-profile.tar.gpg` and the
readable copy is kept alongside it. Two flags change that:

```bash
# Readable only, no archive. For a destination that is already trusted storage.
./dump data /mnt/backup --recovery-profile --no-encrypt

# Keep credentials only inside the archive, which is verified to extract first.
./dump data /mnt/backup --recovery-profile --discard-plaintext
```

`tools/verify_recovery_archive.sh <backup-root>` compares the archive against
the readable tree, file by file and size by size, so "both copies exist" can be
upgraded to "both copies agree".

### Running unattended

`--non-interactive` runs the whole backup with no prompts, for scripting or for
a machine with no terminal:

```bash
./dump data /mnt/backup --non-interactive \
  --select downloads,whatsapp,screenshots,app_inventory,recovery_profile \
  --recovery-profile --no-encrypt \
  --credential-export /sdcard/Download/passwords.csv
```

### What this does to the phone

The credential step is the only part needing someone at the handset, so it runs
**first**, before the long copies. For that step only, the tool holds the screen
awake by setting `stay_on_while_plugged_in` to the USB bit, and **puts the
previous value back** when the step ends — including on Ctrl-C, since that
setting survives a reboot and leaving it changed on someone else's phone would
not be acceptable. `--no-screen-control` skips all of it.

If the phone stays locked, the export cannot be reached, so the credential step
is skipped and said so plainly — at the time and again in the closing summary —
while the rest of the backup completes normally.

Nothing else on the phone is modified. The tool never unlocks the device,
enters a secret or approves a prompt.

See what the attached phone actually has, then open the one you use:

```bash
./dump data --list-managers
./dump data /mnt/backup --recovery-profile --open-manager com.samsung.android.samsungpass
```

Known managers live in `config/recovery_apps.txt` — package, display name, how
its export is reached, and optionally how to open it. Adding a line is all it
takes to support another one. Samsung Pass has no launcher icon of its own, so
its line names the Settings screen it lives behind; an app with neither a
launcher nor a launch spec is reported as such rather than retried.

`--select` is required in this mode. `--credential-export` is repeatable, since
a phone usually holds more than one export. Anything that needs a person at the
handset — collecting root-only Wi-Fi records, opening a password manager to
complete an export — defaults to *no* when unattended.

For the full dump, preserve, and prompt workflow, see [Usage Guide](docs/usage.md).

Backup destinations can be any writable directory visible to the computer running the script.

## Broken Screen, Or USB Debugging Turned Off

Every command in this toolkit needs USB debugging, and that switch is behind
the phone's own screen. **ADB cannot enable ADB** — if a computer could turn it
on without someone agreeing on the handset, a stolen phone would be an open
book.

Run `./dump probe` as soon as the cable is connected. It immediately tells you whether this computer is already authorised; it never waits or changes a phone setting. An `unauthorized` result still needs approval on the phone.

The way through is hardware: give the phone a monitor and a mouse over USB-C,
unlock it there, and enable debugging by hand. Many phones output video through
their USB-C port — Samsung calls the desktop interface DeX — and a cracked or
entirely dead panel stops mattering once the picture is on a monitor.

**[Recovering a phone with a broken screen](https://nikolareljin.github.io/android-device-rescue-kit/cracked-screen.html)**
covers existing cloud and microSD copies, non-Samsung USB-C video, the
accessibility route when it was already configured, data-preserving temporary
screen repair, the mouse-only route when part of the display still works, and
the approaches that sound like they would work but cannot.

## Helper Dependency

This repository expects `script-helpers` at `scripts/script-helpers`. Run `scripts/bootstrap_script_helpers.sh` to clone it. The helper repo provides dependency installation, terminal dialog sizing, OS detection, and common logging functions used by the interactive backup and restore scripts.

This repository also expects `ci-helpers` at `scripts/ci-helpers`. Run `./update` to install both helper repositories, host dependencies, and local git hooks. CI workflows use `ci-helpers` for PR checks, release branch version checks, release tag checks, automatic release tagging, and secret scanning.

Both helper repositories track their `production` release ref rather than a pinned commit, so a fresh clone picks up the current release of each.

## Privacy Rule

Do not commit raw captures. Treat all bugreports, logcats, dumpsys output, kernel logs, tombstones, and extracted archives as private unless they have been reviewed and redacted.

Before publishing:

```bash
git status --short
git status --ignored --short
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
