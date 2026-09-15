#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_URL="https://github.com/nikolareljin/android-device-rescue-kit.git"
INSTALL_DIRECTORY="${ANDROID_RESCUE_INSTALL_DIR:-$HOME/.local/share/android-device-rescue-kit}"
BIN_DIRECTORY="${ANDROID_RESCUE_BIN_DIR:-$HOME/.local/bin}"

usage() {
  cat <<'USAGE'
Usage: install.sh [--dry-run]

Installs Android Device Rescue Kit for Linux or macOS. The installer clones the
public repository, installs its documented host dependencies, and creates:
  android-rescue-dump
  android-rescue-prompt
  android-rescue-update

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

case "$(uname -s)" in
  Linux|Darwin) ;;
  *) printf 'Unsupported platform. On Windows, run install.ps1 from PowerShell.\n' >&2; exit 1 ;;
esac

if [ "$dry_run" -eq 1 ]; then
  printf 'Would install %s into %s and create launchers in %s.\n' "$REPOSITORY_URL" "$INSTALL_DIRECTORY" "$BIN_DIRECTORY"
  exit 0
fi

ensure_git() {
  command -v git >/dev/null 2>&1 && return 0
  case "$(uname -s)" in
    Darwin)
      printf 'Installing Apple command-line tools. Run this installer again when it finishes.\n' >&2
      xcode-select --install
      exit 1
      ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then sudo apt-get update && sudo apt-get install -y git
      elif command -v dnf >/dev/null 2>&1; then sudo dnf install -y git
      elif command -v yum >/dev/null 2>&1; then sudo yum install -y git
      elif command -v pacman >/dev/null 2>&1; then sudo pacman -Sy --noconfirm git
      elif command -v zypper >/dev/null 2>&1; then sudo zypper --non-interactive install git
      elif command -v apk >/dev/null 2>&1; then sudo apk add git
      else printf 'No supported package manager found. Install git, then run this installer again.\n' >&2; exit 1
      fi
      ;;
  esac
  command -v git >/dev/null 2>&1 || { printf 'git installation failed.\n' >&2; exit 1; }
}

ensure_git

if [ -e "$INSTALL_DIRECTORY" ] && [ ! -d "$INSTALL_DIRECTORY/.git" ]; then
  printf 'Installation directory exists but is not a git checkout: %s\n' "$INSTALL_DIRECTORY" >&2
  exit 1
fi

if [ -d "$INSTALL_DIRECTORY/.git" ]; then
  printf 'Updating existing installation at %s\n' "$INSTALL_DIRECTORY"
  git -C "$INSTALL_DIRECTORY" pull --ff-only
else
  mkdir -p "$(dirname "$INSTALL_DIRECTORY")"
  git clone --depth 1 "$REPOSITORY_URL" "$INSTALL_DIRECTORY"
fi

"$INSTALL_DIRECTORY/update"

mkdir -p "$BIN_DIRECTORY"
for command_name in dump prompt update; do
  ln -sfn "$INSTALL_DIRECTORY/$command_name" "$BIN_DIRECTORY/android-rescue-$command_name"
done

case ":${PATH}:" in
  *":${BIN_DIRECTORY}:"*) ;;
  *) printf '\nAdd this directory to PATH, then open a new terminal:\n  %s\n' "$BIN_DIRECTORY" ;;
esac

printf '\nInstalled. Start with: android-rescue-dump --help\n'
