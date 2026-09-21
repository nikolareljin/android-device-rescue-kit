#!/usr/bin/env bash
# SCRIPT: ensure_bin_on_path.sh
# DESCRIPTION: Put the launcher directory on PATH, idempotently, in the user's own rc files.
# USAGE: scripts/ensure_bin_on_path.sh <bin-dir> [--dry-run]
#
# The installer used to print "add this to PATH" and stop, which left the one
# command it had just installed unusable on any distribution that does not seed
# ~/.local/bin. This writes the line instead.
set -euo pipefail

BIN_DIRECTORY="${1:-}"
DRY_RUN=0
case "${2:-}" in
  '') ;;
  --dry-run) DRY_RUN=1 ;;
  *) printf 'Unknown option: %s\n' "$2" >&2; exit 2 ;;
esac

if [ -z "$BIN_DIRECTORY" ]; then
  printf 'Usage: %s <bin-dir> [--dry-run]\n' "$0" >&2
  exit 2
fi

MARKER_OPEN='# >>> android-device-rescue-kit >>>'
MARKER_CLOSE='# <<< android-device-rescue-kit <<<'

# Write $HOME unexpanded when the directory is under it, so the rc file survives
# a moved or renamed home directory.
path_literal="$BIN_DIRECTORY"
case "$BIN_DIRECTORY" in
  "$HOME"/*) path_literal="\$HOME${BIN_DIRECTORY#"$HOME"}" ;;
esac

posix_block() {
  cat <<EOF
$MARKER_OPEN
# Added by the Android Device Rescue Kit installer. Delete this block to undo.
case ":\$PATH:" in
  *":$path_literal:"*) ;;
  *) PATH="$path_literal:\$PATH" ;;
esac
export PATH
$MARKER_CLOSE
EOF
}

fish_block() {
  cat <<EOF
$MARKER_OPEN
# Added by the Android Device Rescue Kit installer. Delete this file to undo.
if not contains $BIN_DIRECTORY \$PATH
    set -gx PATH $BIN_DIRECTORY \$PATH
end
$MARKER_CLOSE
EOF
}

# Two guards. The marker catches our own previous run; the literal path catches
# a user who already put the directory on PATH themselves, in which case there
# is nothing to add.
already_handled() {
  local rc="$1"
  [ -f "$rc" ] || return 1
  grep -Fq "$MARKER_OPEN" "$rc" && return 0
  grep -Fq "$BIN_DIRECTORY" "$rc" && return 0
  grep -Fq "$path_literal" "$rc" && return 0
  return 1
}

append_block() {
  local rc="$1" kind="$2"
  if already_handled "$rc"; then
    printf '  %s already handles it\n' "$rc"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  would append a PATH block to %s\n' "$rc"
    return 0
  fi
  mkdir -p "$(dirname "$rc")"
  # Append only. An rc file may be a symlink into a dotfiles repository, and
  # rewriting it would break that.
  {
    printf '\n'
    if [ "$kind" = fish ]; then fish_block; else posix_block; fi
  } >>"$rc"
  printf '  added to %s\n' "$rc"
  CHANGED=1
}

CHANGED=0

case ":${PATH}:" in
  *":${BIN_DIRECTORY}:"*)
    printf '%s is already on PATH.\n' "$BIN_DIRECTORY"
    exit 0
    ;;
esac

shell_name="$(basename -- "${SHELL:-}")"
case "$shell_name" in
  bash)
    if [ "$(uname -s)" = Darwin ]; then
      append_block "$HOME/.bash_profile" posix
    else
      append_block "$HOME/.bashrc" posix
    fi
    append_block "$HOME/.profile" posix
    ;;
  zsh)
    append_block "${ZDOTDIR:-$HOME}/.zshrc" posix
    append_block "$HOME/.profile" posix
    ;;
  sh|ksh|dash|'')
    append_block "$HOME/.profile" posix
    ;;
  fish)
    # Appending POSIX `export PATH=` to a fish config is a syntax error that
    # breaks every future shell start, so fish gets its own file and its own
    # syntax.
    append_block "$HOME/.config/fish/conf.d/android-device-rescue-kit.fish" fish
    ;;
  *)
    # An unrecognised shell is never edited: a wrong guess costs the user their
    # login shell.
    printf 'Unrecognised shell (%s). Add this to your shell startup file:\n' "${SHELL:-unset}"
    # shellcheck disable=SC2016  # printed for the user to paste, not expanded here
    printf '  PATH="%s:$PATH"\n' "$BIN_DIRECTORY"
    exit 0
    ;;
esac

if [ "$CHANGED" -eq 1 ]; then
  printf '%s was added to PATH. This terminal started before that:\n' "$BIN_DIRECTORY"
  # shellcheck disable=SC2016  # printed for the user to type, not expanded here
  printf '  exec $SHELL -l          # or open a new terminal\n'
fi
