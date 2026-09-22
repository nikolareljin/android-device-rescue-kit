#!/usr/bin/env bash
# SCRIPT: install.sh
# DESCRIPTION: Install the Android Device Rescue Kit for one user, no sudo.
# USAGE: curl -fsSL .../install.sh | bash
set -euo pipefail

REPOSITORY_URL="https://github.com/nikolareljin/android-device-rescue-kit.git"
INSTALL_DIRECTORY="${ANDROID_RESCUE_INSTALL_DIR:-$HOME/.local/share/android-device-rescue-kit}"
BIN_DIRECTORY="${ANDROID_RESCUE_BIN_DIR:-$HOME/.local/bin}"

usage() {
  cat <<'USAGE'
Usage: install.sh [--dry-run]

Installs the Android Device Rescue Kit for Linux, macOS or Git Bash on
Windows, for the current user
only. No sudo, nothing written outside your home directory. It clones the latest
release, installs the documented host dependencies, creates the command

  adrescue

and puts its directory on PATH if it is not there already.

The launchers android-rescue-dump, android-rescue-prompt and
android-rescue-update are also created, for anyone who installed before
adrescue existed.

Optional environment variables:
  ANDROID_RESCUE_INSTALL_DIR  Repository location
  ANDROID_RESCUE_BIN_DIR      Launcher location
USAGE
}

dry_run=0
case "${1:-}" in
  '') ;;
  --dry-run) dry_run=1 ;;
  -h|--help|help) usage; exit 0 ;;
  *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac

# install.ps1 hands over to this script, so Git Bash has to be accepted here.
# It was not: `uname -s` under Git for Windows reports MINGW64_NT-10.0, which
# fell into the catch-all and answered "run install.ps1 from PowerShell" to a
# user who had just run install.ps1 from PowerShell. The native Windows install
# could not complete at all, and nothing caught it because every Windows check
# was a grep for a string rather than a run of the script.
IS_WINDOWS=0
case "$(uname -s)" in
  Linux|Darwin) ;;
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;;
  *) printf 'Unsupported platform: %s\n' "$(uname -s)" >&2; exit 1 ;;
esac

if [ "$dry_run" -eq 1 ]; then
  printf 'Would install %s\n' "$REPOSITORY_URL"
  printf '  repository -> %s\n' "$INSTALL_DIRECTORY"
  printf '  launchers  -> %s\n' "$BIN_DIRECTORY"
  printf '      adrescue\n'
  printf '      android-rescue-dump\n'
  printf '      android-rescue-prompt\n'
  printf '      android-rescue-update\n'
  case ":${PATH}:" in
    *":${BIN_DIRECTORY}:"*) printf '  %s is already on PATH.\n' "$BIN_DIRECTORY" ;;
    *) printf '  would add %s to PATH in your shell startup file.\n' "$BIN_DIRECTORY" ;;
  esac
  exit 0
fi

ensure_git() {
  command -v git >/dev/null 2>&1 && return 0
  as_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"
    elif command -v sudo >/dev/null 2>&1; then sudo "$@"
    else printf 'Administrator permission is required to install git.\n' >&2; return 1
    fi
  }
  case "$(uname -s)" in
    Darwin)
      printf 'Installing Apple command-line tools. Run this installer again when it finishes.\n' >&2
      xcode-select --install
      exit 1
      ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then as_root apt-get update && as_root apt-get install -y git
      elif command -v dnf >/dev/null 2>&1; then as_root dnf install -y git
      elif command -v yum >/dev/null 2>&1; then as_root yum install -y git
      elif command -v pacman >/dev/null 2>&1; then as_root pacman -Sy --noconfirm git
      elif command -v zypper >/dev/null 2>&1; then as_root zypper --non-interactive install git
      elif command -v apk >/dev/null 2>&1; then as_root apk add git
      else printf 'No supported package manager found. Install git, then run this installer again.\n' >&2; exit 1
      fi
      ;;
  esac
  command -v git >/dev/null 2>&1 || { printf 'git installation failed.\n' >&2; exit 1; }
}

# Releases are the unprefixed X.Y.Z tags. The anchor drops v-prefixed,
# prerelease and named tags; the numeric sort keeps 0.10.0 above 0.9.0, which a
# lexical sort does not.
latest_release_tag() {
  git ls-remote --tags --refs "$REPOSITORY_URL" 2>/dev/null \
    | awk '{ print $2 }' \
    | sed 's#refs/tags/##' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -t. -k1,1n -k2,2n -k3,3n \
    | tail -1
}

ensure_git

if [ -e "$INSTALL_DIRECTORY" ] && [ ! -d "$INSTALL_DIRECTORY/.git" ]; then
  printf 'Installation directory exists but is not a git checkout: %s\n' "$INSTALL_DIRECTORY" >&2
  exit 1
fi

if [ -d "$INSTALL_DIRECTORY/.git" ]; then
  printf 'Updating existing installation at %s\n' "$INSTALL_DIRECTORY"
  if [ -x "$INSTALL_DIRECTORY/scripts/self_update.sh" ]; then
    # Not `git pull --ff-only`: adrescue update leaves the checkout detached at
    # a release tag, and pull has no branch to fast-forward there.
    "$INSTALL_DIRECTORY/scripts/self_update.sh" --force
  else
    git -C "$INSTALL_DIRECTORY" pull --ff-only
  fi
else
  mkdir -p "$(dirname "$INSTALL_DIRECTORY")"
  release_tag="$(latest_release_tag || true)"
  if [ -n "$release_tag" ]; then
    printf 'Installing release %s\n' "$release_tag"
    git clone --depth 1 --branch "$release_tag" "$REPOSITORY_URL" "$INSTALL_DIRECTORY"
  else
    printf 'No release tags found; installing the default branch.\n' >&2
    git clone --depth 1 "$REPOSITORY_URL" "$INSTALL_DIRECTORY"
  fi
fi

# scripts/bootstrap.sh is the name from 0.6.0 onwards; ./update is what older
# releases carry, and this installer may have just checked one of those out.
#
# On Windows the packages came from winget before this script was reached, and
# bootstrap's dependency step has no branch for the platform, so it would exit
# non-zero and take the install with it under `set -e`. The submodules and
# hooks it also does are still wanted, so the step runs and its status is
# reported rather than being fatal.
if [ -x "$INSTALL_DIRECTORY/scripts/bootstrap.sh" ]; then
  bootstrap_command="$INSTALL_DIRECTORY/scripts/bootstrap.sh"
else
  bootstrap_command="$INSTALL_DIRECTORY/update"
fi

if [ "$IS_WINDOWS" -eq 1 ]; then
  "$bootstrap_command" || printf 'Dependency bootstrap reported a problem; winget installed the packages already. Continuing.\n' >&2
else
  "$bootstrap_command"
fi

if [ -x "$INSTALL_DIRECTORY/scripts/link_launchers.sh" ]; then
  "$INSTALL_DIRECTORY/scripts/link_launchers.sh" "$INSTALL_DIRECTORY" "$BIN_DIRECTORY"
else
  mkdir -p "$BIN_DIRECTORY"
  for command_name in dump prompt update; do
    ln -sfn "$INSTALL_DIRECTORY/$command_name" "$BIN_DIRECTORY/android-rescue-$command_name"
  done
fi

if [ -x "$INSTALL_DIRECTORY/scripts/ensure_bin_on_path.sh" ]; then
  "$INSTALL_DIRECTORY/scripts/ensure_bin_on_path.sh" "$BIN_DIRECTORY"
else
  case ":${PATH}:" in
    *":${BIN_DIRECTORY}:"*) ;;
    *) printf '\nAdd this directory to PATH, then open a new terminal:\n  %s\n' "$BIN_DIRECTORY" ;;
  esac
fi

if [ -x "$INSTALL_DIRECTORY/adrescue" ]; then
  printf '\nInstalled. Start with: adrescue --help\n'
  printf 'Then plug in the phone and run: adrescue probe\n'
else
  printf '\nInstalled. Start with: android-rescue-dump --help\n'
fi
