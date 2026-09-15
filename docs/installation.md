# Installation

The installer creates local launchers for the Android Device Rescue Kit. It installs
host dependencies and does not connect to an Android phone, collect device data, or
read credential exports.

## Linux and macOS

Run this one line in a terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/nikolareljin/android-device-rescue-kit/main/install.sh | bash
```

The installer clones the toolkit to `~/.local/share/android-device-rescue-kit` and
creates these commands in `~/.local/bin`:

```text
android-rescue-dump
android-rescue-prompt
android-rescue-update
```

Add `~/.local/bin` to `PATH` if the installer tells you it is missing, then open a
new terminal. On macOS, the first run can ask you to install Apple Command Line Tools;
finish that installation and run the one line again.

## Windows

Windows is supported through WSL 2, which supplies the Bash and terminal tools used
by the interactive backup and restore workflows. In an elevated PowerShell window,
install WSL if necessary:

```powershell
wsl --install -d Ubuntu
```

Complete the Linux first-run setup, then run this one line in PowerShell:

```powershell
irm https://raw.githubusercontent.com/nikolareljin/android-device-rescue-kit/main/install.ps1 | iex
```

Run the same commands through WSL. Use `/mnt/c/...` for a Windows drive:

```powershell
wsl ~/.local/bin/android-rescue-dump --help
wsl ~/.local/bin/android-rescue-dump data /mnt/c/AndroidBackups
wsl ~/.local/bin/android-rescue-prompt /mnt/c/AndroidCaptures/example
```

## Commands

```bash
android-rescue-dump log [destination]
android-rescue-dump data [destination] [--recovery-profile]
android-rescue-prompt [capture-directory] [output-prompt.md]
android-rescue-update
```

Use an unlocked phone you own or are authorized to recover, enable USB debugging, and
confirm it appears in `adb devices` before starting a capture or backup. See the
[Usage Guide](usage.md) for data scope and recovery-profile safeguards.

## Updating or relocating the installation

Run the installer again to perform a fast-forward update. To choose another repository
or launcher directory, set these environment variables before running it:

```bash
ANDROID_RESCUE_INSTALL_DIR=/opt/android-rescue \
ANDROID_RESCUE_BIN_DIR="$HOME/.local/bin" \
curl -fsSL https://raw.githubusercontent.com/nikolareljin/android-device-rescue-kit/main/install.sh | bash
```

The installer refuses to replace an existing non-git directory and does not overwrite
backups or captures.
