#!/usr/bin/env bash
# SCRIPT: test_install_path.sh
# DESCRIPTION: PATH setup, launcher symlinks and the installer dry run.
# USAGE: bash tests/test_install_path.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

checks=0
fail() { printf 'FAIL: %s\n%s\n' "$1" "${2:-}" >&2; exit 1; }
pass() { checks=$((checks + 1)); }

ENSURE="$ROOT/scripts/ensure_bin_on_path.sh"
LINK="$ROOT/scripts/link_launchers.sh"

fresh_home() {
  local home="$WORK/$1"
  rm -rf "$home"
  mkdir -p "$home"
  printf '%s' "$home"
}

# BIN must not already be on PATH, or the script correctly short-circuits.
run_ensure() {
  local home="$1" shell_path="$2"
  shift 2
  env -u ZDOTDIR HOME="$home" SHELL="$shell_path" PATH="/usr/bin:/bin" \
    bash "$ENSURE" "$home/.local/bin" "$@"
}

# bash on Linux writes .bashrc and .profile.
home="$(fresh_home bash_home)"
run_ensure "$home" /bin/bash >/dev/null
[ -f "$home/.bashrc" ] || fail 'bash: .bashrc created'
[ -f "$home/.profile" ] || fail 'bash: .profile created'
grep -Fq '>>> android-device-rescue-kit >>>' "$home/.bashrc" || fail 'bash: marker in .bashrc'
grep -Fq '>>> android-device-rescue-kit >>>' "$home/.profile" || fail 'bash: marker in .profile'
pass

# Exactly one block per file, and a second run changes nothing.
[ "$(grep -c '>>> android-device-rescue-kit >>>' "$home/.bashrc")" -eq 1 ] \
  || fail 'bash: exactly one block'
cp "$home/.bashrc" "$WORK/bashrc.first"
cp "$home/.profile" "$WORK/profile.first"
run_ensure "$home" /bin/bash >/dev/null
cmp -s "$home/.bashrc" "$WORK/bashrc.first" || fail 'second run must not touch .bashrc'
cmp -s "$home/.profile" "$WORK/profile.first" || fail 'second run must not touch .profile'
pass

# The appended block has to be valid in both shells that will read it.
bash -n "$home/.bashrc" || fail '.bashrc must parse as bash'
sh -n "$home/.profile" || fail '.profile must parse as sh'
pass

# Sourcing twice must not put the directory on PATH twice: the block guards
# itself at runtime, which is the whole reason for the case statement.
# shellcheck disable=SC2016  # the sh -c body must expand in that shell, not here
count="$(env -i HOME="$home" PATH="/usr/bin:/bin" sh -c \
  '. "$HOME/.profile"; . "$HOME/.profile"; printf "%s" "$PATH"' \
  | tr ':' '\n' | grep -c "\.local/bin$")"
[ "$count" -eq 1 ] || fail "sourcing twice put .local/bin on PATH $count times"
pass

# A user who already added the directory gets nothing appended.
home="$(fresh_home own_home)"
# shellcheck disable=SC2016  # written literally, for the rc file to expand
printf 'export PATH="$HOME/.local/bin:$PATH"\n' >"$home/.bashrc"
cp "$home/.bashrc" "$WORK/own.first"
out="$(run_ensure "$home" /bin/bash)"
cmp -s "$home/.bashrc" "$WORK/own.first" || fail 'must not append over the user own PATH line'
grep -Fq 'already handles it' <<<"$out" || fail 'must say the rc already handles it' "$out"
pass

# zsh.
home="$(fresh_home zsh_home)"
run_ensure "$home" /bin/zsh >/dev/null
[ -f "$home/.zshrc" ] || fail 'zsh: .zshrc created'
[ -f "$home/.profile" ] || fail 'zsh: .profile created'
[ -f "$home/.bashrc" ] && fail 'zsh: .bashrc must not be touched'
pass

# fish gets fish syntax in its own conf.d file. Appending POSIX export PATH= to
# a fish config is a syntax error that breaks every future shell start.
home="$(fresh_home fish_home)"
run_ensure "$home" /usr/bin/fish >/dev/null
conf="$home/.config/fish/conf.d/android-device-rescue-kit.fish"
[ -f "$conf" ] || fail 'fish: conf.d file created'
grep -Fq 'export PATH=' "$conf" && fail 'fish: must not contain POSIX export PATH='
grep -Fq 'set -gx PATH' "$conf" || fail 'fish: must use fish syntax'
[ -f "$home/.profile" ] && fail 'fish: no POSIX rc may be touched'
[ -f "$home/.bashrc" ] && fail 'fish: no POSIX rc may be touched'
pass

# An unrecognised shell is never edited: a wrong guess costs the login shell.
home="$(fresh_home odd_home)"
out="$(run_ensure "$home" /opt/weird/shell)"
[ -f "$home/.profile" ] && fail 'unknown shell: nothing may be written'
[ -f "$home/.bashrc" ] && fail 'unknown shell: nothing may be written'
grep -Fq 'Unrecognised shell' <<<"$out" || fail 'unknown shell: says so' "$out"
pass

# No usable SHELL falls back to .profile only. SHELL is set empty rather than
# unset: bash assigns SHELL the login shell when it is missing, so `env -u
# SHELL` never actually reaches this branch.
home="$(fresh_home noshell_home)"
env -u ZDOTDIR SHELL= HOME="$home" PATH="/usr/bin:/bin" bash "$ENSURE" "$home/.local/bin" >/dev/null
[ -f "$home/.profile" ] || fail 'empty SHELL: .profile created'
[ -f "$home/.bashrc" ] && fail 'empty SHELL: .bashrc must not be created'
pass

# --dry-run writes nothing.
home="$(fresh_home dry_home)"
out="$(run_ensure "$home" /bin/bash --dry-run)"
[ -f "$home/.bashrc" ] && fail 'dry run must not create .bashrc'
grep -Fq 'would append' <<<"$out" || fail 'dry run says what it would do' "$out"
pass

# --- launchers ---------------------------------------------------------------

install_dir="$WORK/install"
bin_dir="$WORK/bin"
mkdir -p "$install_dir"
for entry in adrescue dump prompt update; do
  printf '#!/usr/bin/env bash\n' >"$install_dir/$entry"
  chmod +x "$install_dir/$entry"
done

bash "$LINK" "$install_dir" "$bin_dir" >/dev/null
for link in adrescue android-rescue-dump android-rescue-prompt android-rescue-update; do
  [ -L "$bin_dir/$link" ] || fail "link_launchers created $link"
done
pass

bash "$LINK" "$install_dir" "$bin_dir" >/dev/null
[ "$(find "$bin_dir" -maxdepth 1 -type l | wc -l)" -eq 4 ] || fail 'relinking must be idempotent'
pass

# A regular file with the same name is the user's binary, not ours to delete.
rm -f "$bin_dir/adrescue"
printf 'not ours\n' >"$bin_dir/adrescue"
set +e
out="$(bash "$LINK" "$install_dir" "$bin_dir" 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail 'link_launchers must refuse to clobber a regular file' "$out"
grep -Fq 'not ours' "$bin_dir/adrescue" || fail 'the existing file must survive'
pass

# --- installer dry run -------------------------------------------------------

home="$(fresh_home installer_home)"
out="$(env HOME="$home" ANDROID_RESCUE_INSTALL_DIR="$WORK/nothing" \
  ANDROID_RESCUE_BIN_DIR="$WORK/nobin" bash "$ROOT/install.sh" --dry-run)"
for needle in "$WORK/nothing" "$WORK/nobin" adrescue android-rescue-dump \
              android-rescue-prompt android-rescue-update; do
  grep -Fq "$needle" <<<"$out" || fail "dry run mentions $needle" "$out"
done
[ -e "$WORK/nothing" ] && fail 'dry run must not create the install directory'
[ -e "$WORK/nobin" ] && fail 'dry run must not create the launcher directory'
pass

set +e
out="$(bash "$ROOT/install.sh" --nope 2>&1)"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "install.sh --nope must exit 2, got $rc" "$out"
pass

out="$(bash "$ROOT/install.sh" --help)"
grep -Fq 'adrescue' <<<"$out" || fail 'install.sh --help advertises adrescue' "$out"
pass

printf 'install_path: %s checks passed\n' "$checks"
