#!/usr/bin/env bash
# SCRIPT: link_launchers.sh
# DESCRIPTION: Create the adrescue launcher, plus the legacy android-rescue-* names.
# USAGE: scripts/link_launchers.sh <install-dir> <bin-dir>
set -euo pipefail

INSTALL_DIRECTORY="${1:-}"
BIN_DIRECTORY="${2:-}"

if [ -z "$INSTALL_DIRECTORY" ] || [ -z "$BIN_DIRECTORY" ]; then
  printf 'Usage: %s <install-dir> <bin-dir>\n' "$0" >&2
  exit 2
fi

mkdir -p "$BIN_DIRECTORY"

link_one() {
  local target="$1" link="$2"
  # ln -sfn replaces a regular file without a word. adrescue is a short, generic
  # name, so something else may legitimately own it; that is the user's binary,
  # not ours to delete.
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    printf 'Refusing to replace an existing file: %s\n' "$link" >&2
    return 1
  fi
  ln -sfn "$target" "$link"
  printf '  %s -> %s\n' "$link" "$target"
}

link_one "$INSTALL_DIRECTORY/adrescue" "$BIN_DIRECTORY/adrescue"

# Kept working for anyone who installed before adrescue existed. Undocumented.
for command_name in dump prompt update; do
  link_one "$INSTALL_DIRECTORY/$command_name" "$BIN_DIRECTORY/android-rescue-$command_name"
done
