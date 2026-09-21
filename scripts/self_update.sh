#!/usr/bin/env bash
# SCRIPT: self_update.sh
# DESCRIPTION: Move this installation to the latest release.
# USAGE: adrescue update [--check] [--force] [--ref <tag>]
#
# Exit codes are the contract:
#   0  updated, or already current
#   1  not a git checkout
#   2  usage error
#   3  development clone, refused
#   4  uncommitted changes, refused
#   5  remote unreachable
#   6  no release tags found
#   7  the new release is checked out, but a post-update step failed
set -euo pipefail

# Run from a copy outside the tree before touching git. Bash reads a script
# lazily by file offset, so a checkout that replaces this file underneath the
# running interpreter can execute garbage from the middle of the new one.
if [ "${ANDROID_RESCUE_UPDATE_DETACHED:-0}" != 1 ]; then
  __root="${ANDROID_RESCUE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  __tmp="$(mktemp -d)"
  cp "${BASH_SOURCE[0]}" "$__tmp/self_update.sh"
  export ANDROID_RESCUE_UPDATE_DETACHED=1
  export ANDROID_RESCUE_ROOT="$__root"
  export ANDROID_RESCUE_UPDATE_TMP="$__tmp"
  exec bash "$__tmp/self_update.sh" ${1+"$@"}
fi

trap 'rm -rf "${ANDROID_RESCUE_UPDATE_TMP:-}"' EXIT

ROOT="$ANDROID_RESCUE_ROOT"
MANAGED_INSTALL_DIR="${ANDROID_RESCUE_INSTALL_DIR:-$HOME/.local/share/android-device-rescue-kit}"
BIN_DIRECTORY="${ANDROID_RESCUE_BIN_DIR:-$HOME/.local/bin}"
UPDATE_SOURCE="${ANDROID_RESCUE_UPDATE_SOURCE:-auto}"

check_only=0
force=0
wanted_ref=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) check_only=1; shift ;;
    --force) force=1; shift ;;
    --ref) wanted_ref="${2:-}"; [ -n "$wanted_ref" ] || { printf -- '--ref needs a tag.\n' >&2; exit 2; }; shift 2 ;;
    -h|--help|help)
      printf 'Usage: adrescue update [--check] [--force] [--ref <tag>]\n'
      exit 0
      ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  printf 'This copy is not a git checkout (%s). Update it the way you installed it.\n' "$ROOT" >&2
  exit 1
fi

if [ "$ROOT" != "$MANAGED_INSTALL_DIR" ] && [ "$force" -eq 0 ]; then
  printf '%s is a development clone, not a managed install.\n' "$ROOT" >&2
  printf 'Use git directly, or pass --force to update this checkout anyway.\n' >&2
  exit 3
fi

# --force covers the development-clone guard only. A self-updater that throws
# away local edits on a flag is a data-loss bug waiting for a typo.
dirty="$(git -C "$ROOT" status --porcelain --untracked-files=no)"
if [ -n "$dirty" ]; then
  printf 'This checkout has uncommitted changes. Nothing was changed:\n' >&2
  printf '%s\n' "$dirty" >&2
  exit 4
fi

remote="${ANDROID_RESCUE_REMOTE:-}"
if [ -z "$remote" ]; then
  remote="$(git -C "$ROOT" config --get remote.origin.url || true)"
fi
if [ -z "$remote" ]; then
  printf 'No remote is configured for %s.\n' "$ROOT" >&2
  exit 5
fi

# Releases are the unprefixed X.Y.Z tags this repository creates on merge. The
# strict anchor drops v-prefixed, prerelease and named tags in one step.
latest_from_tags() {
  git ls-remote --tags --refs "$remote" 2>/dev/null \
    | awk '{ print $2 }' \
    | sed 's#refs/tags/##' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -t. -k1,1n -k2,2n -k3,3n \
    | tail -1
}

# The releases API is the only source that knows what a release is: it excludes
# drafts and prereleases by definition, where a tag listing cannot.
latest_from_api() {
  local slug body
  case "$remote" in
    *github.com[:/]*) ;;
    *) return 1 ;;
  esac
  command -v curl >/dev/null 2>&1 || return 1
  slug="${remote#*github.com}"
  slug="${slug#:}"
  slug="${slug#/}"
  slug="${slug%.git}"
  body="$(curl -fsSL --max-time 10 "https://api.github.com/repos/$slug/releases/latest" 2>/dev/null)" || return 1
  printf '%s' "$body" \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -1
}

latest=""
source_used=""
if [ -n "$wanted_ref" ]; then
  latest="$wanted_ref"
  source_used="--ref"
else
  case "$UPDATE_SOURCE" in
    api|auto) latest="$(latest_from_api || true)"; [ -n "$latest" ] && source_used="GitHub releases" ;;
  esac
  if [ -z "$latest" ]; then
    latest="$(latest_from_tags || true)"
    [ -n "$latest" ] && source_used="remote tags"
  fi
fi

if [ -z "$latest" ]; then
  if ! git ls-remote --exit-code "$remote" >/dev/null 2>&1; then
    printf 'Could not reach %s. Nothing was changed.\n' "$remote" >&2
    exit 5
  fi
  printf 'No release tags found at %s.\n' "$remote" >&2
  exit 6
fi

current="$(git -C "$ROOT" describe --tags --exact-match HEAD 2>/dev/null || true)"
if [ -z "$current" ] && [ -r "$ROOT/VERSION" ]; then
  current="$(tr -d '[:space:]' <"$ROOT/VERSION")"
fi
[ -n "$current" ] || current="unknown"

printf 'Installed: %s\nLatest release: %s (%s)\n' "$current" "$latest" "$source_used"

if [ "$current" = "$latest" ]; then
  printf 'Already at the latest release (%s).\n' "$latest"
  exit 0
fi

if [ -z "$wanted_ref" ] && git -C "$ROOT" merge-base --is-ancestor "$latest" HEAD 2>/dev/null; then
  printf 'This copy is ahead of the latest release (%s). Nothing to do.\n' "$latest"
  exit 0
fi

if [ "$check_only" -eq 1 ]; then
  printf 'Run "adrescue update" to move to %s.\n' "$latest"
  exit 0
fi

git_dir="$(git -C "$ROOT" rev-parse --git-dir)"
case "$git_dir" in
  /*) ;;
  *) git_dir="$ROOT/$git_dir" ;;
esac

# Fetch the one tag by name, never a bare `git fetch <remote>`: without a
# refspec git asks for the remote HEAD, which not every remote publishes.
if [ -f "$git_dir/shallow" ]; then
  # Stay shallow. A rescue laptop on a phone hotspot should not pull the whole
  # history to move one patch version. Test the file, not
  # `git rev-parse --is-shallow-repository`, which needs git 2.15.
  git -C "$ROOT" fetch --depth 1 --force "$remote" "refs/tags/$latest:refs/tags/$latest"
else
  git -C "$ROOT" fetch --force "$remote" "refs/tags/$latest:refs/tags/$latest"
fi

# --quiet: git otherwise prints its detached-HEAD lecture on every update,
# which is noise for someone who only asked for a newer version.
git -C "$ROOT" checkout --detach --quiet "refs/tags/$latest"

# From the new tree: a release may add a dependency or a launcher.
#
# Neither step may abort this script through `set -e`. The checkout has already
# happened, so dying here leaves the new release installed with stale launchers,
# no "Updated" line, and an exit code outside the contract above. Relinking in
# particular must still run when dependency installation fails, because that is
# what points ~/.local/bin at the new tree.
post_update_failed=0

if [ -x "$ROOT/scripts/bootstrap.sh" ]; then
  bash "$ROOT/scripts/bootstrap.sh" || {
    post_update_failed=1
    printf 'Installing host dependencies failed.\n' >&2
  }
fi
if [ -x "$ROOT/scripts/link_launchers.sh" ]; then
  bash "$ROOT/scripts/link_launchers.sh" "$ROOT" "$BIN_DIRECTORY" || {
    post_update_failed=1
    printf 'Updating the launchers in %s failed.\n' "$BIN_DIRECTORY" >&2
  }
fi

printf 'Updated %s -> %s\n' "$current" "$latest"

if [ "$post_update_failed" -eq 1 ]; then
  printf '\n%s is installed, but a step after the update did not finish.\n' "$latest" >&2
  printf 'The toolkit may be missing a dependency. Run: adrescue bootstrap\n' >&2
  exit 7
fi
