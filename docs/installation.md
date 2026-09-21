# Installation

The installer sets up the Android Device Rescue Kit for one user. It installs
host dependencies and does not connect to an Android phone, collect device
data, or read credential exports.

## Linux and macOS

One line, no sudo:

```bash
curl -fsSL https://raw.githubusercontent.com/nikolareljin/android-device-rescue-kit/main/install.sh | bash
```

It clones the latest release into `~/.local/share/android-device-rescue-kit`,
puts one command in `~/.local/bin`:

```text
adrescue
```

and adds that directory to `PATH` in your shell's startup file if it is not
there already. The current terminal started before that change, so open a new
one, or run `exec $SHELL -l`. Then:

```bash
adrescue --help
```

On macOS the first run can ask you to install Apple Command Line Tools. Finish
that installation and run the one line again.

## Reading the commands in these docs

A leading `./` appears only where the shell needs one.

- `adrescue log` is the installed command, found on your `PATH`. This is what
  every guide shows, because it is what the one-line install gives you.
- `./adrescue log` is the same program, run as a file in the current
  directory. That is only correct inside a git clone, so it appears only in the
  contributor sections.
- `tools/android_restore_dialog.sh` and `scripts/lint.sh` are paths inside the
  repository. A path with a slash in it already runs without `./`, so these
  never carry one.

## Commands

| Command | What it does |
|---|---|
| `adrescue probe` | Says immediately whether the attached phone has authorised this computer. Never waits, never changes a phone setting. |
| `adrescue photos <dir>` | Finds and copies every photo and video, then verifies each copy against the phone. Exits non-zero if one is missing. |
| `adrescue data <dir> [--recovery-profile]` | The interactive backup checklist for shared storage, plus the opt-in recovery profile. |
| `adrescue log [dir]` | Collects bugreport, logcat, dropbox and dumpsys evidence and writes a triage report. |
| `adrescue verify <backup-root>` | Checks the encrypted recovery archive against the readable profile. |
| `adrescue restore <backup-root>` | Puts selected data back onto a phone. Names the target device and asks before writing. |
| `adrescue prompt [capture-dir]` | Builds `analysis_prompt.md` from a capture. Omitted, it uses the newest one. |
| `adrescue config` | Shows where photos, backups and captures are written, and how to change it. |
| `adrescue update` | Moves this installation to the latest release. |

Run `adrescue --help`, or `adrescue <command> --help`, for the full options.

Use an unlocked phone you own or are authorized to recover, enable USB
debugging, and confirm `adrescue probe` reports the phone as ready before
starting a capture or backup. See the [Usage Guide](usage.md) for data scope
and recovery-profile safeguards.

## Where your data is written

Two directories, so the files you cannot replace do not have to live on the
computer you are working from.

| Directory | Default | Holds |
|---|---|---|
| data | `~/android-rescue/data` | `photos/<timestamp>/`, `backups/<timestamp>/`, the encrypted recovery archive |
| work | `~/android-rescue/work` | `captures/<timestamp>/`: bugreport, logcat, dumpsys, the triage report and the analysis prompt |

Point the data directory at a mounted drive and rescued photos go straight
there:

```bash
adrescue config set data-dir /mnt/rescue/android
adrescue config
```

`adrescue config` prints each path and where the value came from, which is how
you tell a setting that took effect from one that did not. Settings are read
from, highest priority first:

1. an explicit destination argument, such as `adrescue photos /mnt/rescue`
2. `--data-dir` or `--work-dir`
3. `ANDROID_RESCUE_DATA_DIR` or `ANDROID_RESCUE_WORK_DIR`
4. `~/.config/android-device-rescue-kit/config`
5. the defaults above

Inside a git clone the defaults are instead `captures/`, `backups/` and
`photos/` beside the checkout, which the repository's `.gitignore` covers.

## Windows

Windows is supported through WSL 2, which supplies the Bash and terminal tools
used by the interactive backup and restore workflows. In an elevated PowerShell
window, install WSL if necessary:

```powershell
wsl --install -d Ubuntu
```

Complete the Linux first-run setup, then run this one line in PowerShell:

```powershell
irm https://raw.githubusercontent.com/nikolareljin/android-device-rescue-kit/main/install.ps1 | iex
```

Run the commands through a Linux shell. Use `/mnt/c/...` for a Windows drive:

```powershell
wsl bash -lc '~/.local/bin/adrescue --help'
wsl bash -lc '~/.local/bin/adrescue probe'
wsl bash -lc '~/.local/bin/adrescue data /mnt/c/AndroidBackups/phone-before-reset'
```

Inside a WSL shell it is just `adrescue probe`. The PowerShell examples use the
full path because it works whichever startup file the installer chose.

### Connect an Android phone from WSL

WSL 2 needs USB passthrough before its `adb` can see a phone connected by USB.
Install `usbipd-win`, then in an elevated PowerShell window run `usbipd list`,
bind the phone with `usbipd bind --busid <BUSID>`, and attach it with
`usbipd attach --wsl --busid <BUSID>`. In WSL, verify the phone with
`adrescue probe` before starting a backup.

## Upgrading

An installed copy upgrades itself:

```bash
adrescue update
```

It finds the newest release, moves your installation to it, and installs
anything that release newly requires. When you are already on the newest
release it says so and does nothing else. `adrescue update --check` reports the
current and latest versions without changing anything.

It refuses rather than guesses. A checkout with local edits, one that is not a
managed install, or a remote it cannot reach each stop the update and leave the
installation exactly as it was.

Re-running the one-line installer is not the way to upgrade. Use it only to
repair an installation: a deleted `~/.local/bin/adrescue`, or a `PATH` that was
never fixed.

Releases are the unprefixed `X.Y.Z` tags described in [Versioning](versioning.md).

### Upgrading a git clone

A clone does not update itself, and `adrescue update` is not the way to move
one forward. You choose the version with git, as with any checkout:

```bash
git -C android-device-rescue-kit fetch --tags
git -C android-device-rescue-kit checkout 0.6.0
```

or follow the default branch:

```bash
git -C android-device-rescue-kit checkout main
git -C android-device-rescue-kit pull --ff-only
```

If a release adds a host dependency, run the bootstrap afterwards:

```bash
./adrescue bootstrap
```

## Running from a git clone

For contributors, or if you would rather not pipe a script into bash:

```bash
git clone https://github.com/nikolareljin/android-device-rescue-kit.git
cd android-device-rescue-kit
./adrescue bootstrap
```

`bootstrap` clones the `script-helpers` and `ci-helpers` repositories into
`scripts/`, installs the host dependencies, and wires the local git hooks. It
is what the one-line installer runs for you, so an installed copy never needs
it.

Commands are then spelled `./adrescue probe` and run from inside the checkout.

## Relocating the installation

The install location and the launcher directory are chosen at install time:

```bash
curl -fsSL https://raw.githubusercontent.com/nikolareljin/android-device-rescue-kit/main/install.sh | ANDROID_RESCUE_INSTALL_DIR=/opt/android-rescue ANDROID_RESCUE_BIN_DIR="$HOME/.local/bin" bash
```

The installer refuses to replace an existing directory that is not a git
checkout, and does not overwrite backups or captures.

## If something is missing

- **`adrescue: command not found`.** The launcher directory is not on this
  shell's `PATH` yet. Open a new terminal, or run `exec $SHELL -l`. If it still
  fails, run the one-line installer again to repair the installation.
- **The installer said it could not edit a startup file.** It never edits a
  shell it does not recognise, because a wrong guess would break your login
  shell. Add `~/.local/bin` to `PATH` yourself in whatever file your shell
  reads.
- **`adb` is missing.** Run `adrescue bootstrap` to install the host
  dependencies.
- **A capture went somewhere unexpected.** Run `adrescue config` to see the
  resolved data and work directories and where each value came from.
