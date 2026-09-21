#!/usr/bin/env bash
# SCRIPT: test_self_update.sh
# DESCRIPTION: adrescue update, against a local bare repository. No network.
# USAGE: bash tests/test_self_update.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

checks=0
fail() { printf 'FAIL: %s\n%s\n' "$1" "${2:-}" >&2; exit 1; }
pass() { checks=$((checks + 1)); }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
: >"$GIT_CONFIG_GLOBAL"
git config --global advice.detachedHead false

SELF_UPDATE="$ROOT/scripts/self_update.sh"
REMOTE="$WORK/remote.git"
SEED="$WORK/seed"

git init --quiet --bare "$REMOTE"
git init --quiet -b main "$SEED"

seed_commit() {
  local version="$1"
  printf '%s\n' "$version" >"$SEED/VERSION"
  mkdir -p "$SEED/scripts"
  # The post-update steps record which tree they ran from, so the test can
  # prove they ran from the new one and not the old.
  cat >"$SEED/scripts/bootstrap.sh" <<EOF
#!/usr/bin/env bash
printf 'bootstrap from $version\n' >>"\${ANDROID_RESCUE_TEST_LOG:?}"
exit "\${ANDROID_RESCUE_FAIL_BOOTSTRAP:-0}"
EOF
  cat >"$SEED/scripts/link_launchers.sh" <<EOF
#!/usr/bin/env bash
printf 'link from $version\n' >>"\${ANDROID_RESCUE_TEST_LOG:?}"
EOF
  chmod +x "$SEED/scripts/bootstrap.sh" "$SEED/scripts/link_launchers.sh"
  cp "$SELF_UPDATE" "$SEED/scripts/self_update.sh"
  chmod +x "$SEED/scripts/self_update.sh"
  git -C "$SEED" add -A
  git -C "$SEED" commit --quiet -m "version $version"
}

for v in 0.1.0 0.2.0 0.9.0 0.10.0; do
  seed_commit "$v"
  git -C "$SEED" tag "$v"
done
# Decoys: a v-prefix, a prerelease and a name. None is a release here.
git -C "$SEED" tag v0.3.0
git -C "$SEED" tag 0.11.0-rc1
git -C "$SEED" tag nightly
git -C "$SEED" push --quiet --tags "$REMOTE" main

install_at() {
  local tag="$1" dir="$2" shallow="${3:-}"
  rm -rf "$dir"
  if [ "$shallow" = shallow ]; then
    # file:// is required, or git prints "--depth is ignored in local clones"
    # and the shallow branch is never exercised.
    git clone --quiet --depth 1 --branch "$tag" "file://$REMOTE" "$dir"
  else
    git clone --quiet --branch "$tag" "$REMOTE" "$dir"
  fi
}

update() {
  local dir="$1"
  shift
  env ANDROID_RESCUE_ROOT="$dir" \
      ANDROID_RESCUE_INSTALL_DIR="$dir" \
      ANDROID_RESCUE_REMOTE="$REMOTE" \
      ANDROID_RESCUE_BIN_DIR="$WORK/bin" \
      ANDROID_RESCUE_UPDATE_SOURCE=tags \
      ANDROID_RESCUE_TEST_LOG="$WORK/steps.log" \
      bash "$SELF_UPDATE" "$@"
}

run_update() {
  local out rc
  set +e
  out="$(update "$@" 2>&1)"
  rc=$?
  set -e
  printf '%s' "$out"
  return "$rc"
}

INSTALL="$WORK/install"

# 0.2.0 must reach 0.10.0. A lexical sort would stop at 0.9.0, and a loose tag
# filter would pick nightly or the release candidate.
: >"$WORK/steps.log"
install_at 0.2.0 "$INSTALL"
out="$(run_update "$INSTALL")" || fail 'update exits 0' "$out"
[ "$(git -C "$INSTALL" describe --tags --exact-match HEAD)" = 0.10.0 ] \
  || fail 'must check out 0.10.0' "$out"
[ "$(tr -d '[:space:]' <"$INSTALL/VERSION")" = 0.10.0 ] || fail 'VERSION must be 0.10.0'
git -C "$INSTALL" symbolic-ref -q HEAD >/dev/null && fail 'HEAD must be detached at the tag'
pass

# The post-update steps must run, and from the new tree.
grep -Fq 'bootstrap from 0.10.0' "$WORK/steps.log" || fail 'bootstrap ran from the new tree'
grep -Fq 'link from 0.10.0' "$WORK/steps.log" || fail 'relink ran from the new tree'
pass

# Already current is a no-op.
before="$(git -C "$INSTALL" rev-parse HEAD)"
out="$(run_update "$INSTALL")" || fail 'already-current exits 0' "$out"
grep -Fq 'Already at the latest release' <<<"$out" || fail 'says it is current' "$out"
[ "$(git -C "$INSTALL" rev-parse HEAD)" = "$before" ] || fail 'already-current must not move HEAD'
pass

# --check reports and changes nothing.
install_at 0.2.0 "$INSTALL"
: >"$WORK/steps.log"
before="$(git -C "$INSTALL" rev-parse HEAD)"
out="$(run_update "$INSTALL" --check)" || fail '--check exits 0' "$out"
grep -Fq '0.10.0' <<<"$out" || fail '--check names the latest release' "$out"
[ "$(git -C "$INSTALL" rev-parse HEAD)" = "$before" ] || fail '--check must not move HEAD'
[ -s "$WORK/steps.log" ] && fail '--check must not run the post-update steps'
pass

# A dirty tree is refused, and --force does not override that.
printf 'local edit\n' >>"$INSTALL/VERSION"
before="$(git -C "$INSTALL" rev-parse HEAD)"
set +e
out="$(update "$INSTALL" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 4 ] || fail "dirty tree must exit 4, got $rc" "$out"
[ "$(git -C "$INSTALL" rev-parse HEAD)" = "$before" ] || fail 'dirty tree must not move HEAD'
grep -Fq 'local edit' "$INSTALL/VERSION" || fail 'the local edit must survive'
set +e
out="$(update "$INSTALL" --force 2>&1)"
rc=$?
set -e
[ "$rc" -eq 4 ] || fail "--force must not override a dirty tree, got $rc" "$out"
pass
git -C "$INSTALL" checkout --quiet -- VERSION

# A shallow install stays reachable: install.sh clones --depth 1, so the tags
# are not present locally and a plain fetch --tags would not find them.
install_at 0.2.0 "$WORK/shallow" shallow
# --absolute-git-dir: the plain --git-dir prints ".git", relative to the
# caller's directory, not the clone's.
[ -f "$(git -C "$WORK/shallow" rev-parse --absolute-git-dir)/shallow" ] \
  || fail 'fixture must actually be a shallow clone'
: >"$WORK/steps.log"
out="$(env ANDROID_RESCUE_ROOT="$WORK/shallow" ANDROID_RESCUE_INSTALL_DIR="$WORK/shallow" \
  ANDROID_RESCUE_REMOTE="file://$REMOTE" ANDROID_RESCUE_BIN_DIR="$WORK/bin" \
  ANDROID_RESCUE_UPDATE_SOURCE=tags ANDROID_RESCUE_TEST_LOG="$WORK/steps.log" \
  bash "$SELF_UPDATE" 2>&1)" || fail 'shallow update exits 0' "$out"
[ "$(git -C "$WORK/shallow" describe --tags --exact-match HEAD)" = 0.10.0 ] \
  || fail 'shallow install must reach 0.10.0' "$out"
pass

# An unreachable remote changes nothing.
install_at 0.2.0 "$INSTALL"
before="$(git -C "$INSTALL" rev-parse HEAD)"
set +e
out="$(env ANDROID_RESCUE_ROOT="$INSTALL" ANDROID_RESCUE_INSTALL_DIR="$INSTALL" \
  ANDROID_RESCUE_REMOTE="$WORK/nope.git" ANDROID_RESCUE_UPDATE_SOURCE=tags \
  ANDROID_RESCUE_TEST_LOG="$WORK/steps.log" bash "$SELF_UPDATE" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 5 ] || fail "unreachable remote must exit 5, got $rc" "$out"
[ "$(git -C "$INSTALL" rev-parse HEAD)" = "$before" ] || fail 'unreachable remote must not move HEAD'
pass

# A development clone is refused by name, and --force proceeds.
before="$(git -C "$INSTALL" rev-parse HEAD)"
set +e
out="$(env ANDROID_RESCUE_ROOT="$INSTALL" ANDROID_RESCUE_INSTALL_DIR="$WORK/elsewhere" \
  ANDROID_RESCUE_REMOTE="$REMOTE" ANDROID_RESCUE_UPDATE_SOURCE=tags \
  ANDROID_RESCUE_TEST_LOG="$WORK/steps.log" bash "$SELF_UPDATE" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "development clone must exit 3, got $rc" "$out"
[ "$(git -C "$INSTALL" rev-parse HEAD)" = "$before" ] || fail 'development clone must not move HEAD'
out="$(env ANDROID_RESCUE_ROOT="$INSTALL" ANDROID_RESCUE_INSTALL_DIR="$WORK/elsewhere" \
  ANDROID_RESCUE_REMOTE="$REMOTE" ANDROID_RESCUE_BIN_DIR="$WORK/bin" \
  ANDROID_RESCUE_UPDATE_SOURCE=tags ANDROID_RESCUE_TEST_LOG="$WORK/steps.log" \
  bash "$SELF_UPDATE" --force 2>&1)" || fail '--force proceeds in a clone' "$out"
[ "$(git -C "$INSTALL" describe --tags --exact-match HEAD)" = 0.10.0 ] \
  || fail '--force must update the clone' "$out"
pass

# Not a git checkout at all.
mkdir -p "$WORK/plain"
set +e
out="$(env ANDROID_RESCUE_ROOT="$WORK/plain" ANDROID_RESCUE_INSTALL_DIR="$WORK/plain" \
  ANDROID_RESCUE_REMOTE="$REMOTE" bash "$SELF_UPDATE" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "a non-checkout must exit 1, got $rc" "$out"
pass

# A post-update step that fails must not abort the script: the checkout has
# already happened, so dying there leaves the new release installed with stale
# launchers, no "Updated" line, and an exit code outside the contract.
install_at 0.2.0 "$INSTALL"
cat >"$WORK/seedfail" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
: >"$WORK/steps.log"
set +e
out="$(env ANDROID_RESCUE_ROOT="$INSTALL" ANDROID_RESCUE_INSTALL_DIR="$INSTALL" \
  ANDROID_RESCUE_REMOTE="$REMOTE" ANDROID_RESCUE_BIN_DIR="$WORK/bin" \
  ANDROID_RESCUE_UPDATE_SOURCE=tags ANDROID_RESCUE_TEST_LOG="$WORK/steps.log" \
  ANDROID_RESCUE_FAIL_BOOTSTRAP=1 bash "$SELF_UPDATE" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 7 ] || fail "a failed post-update step must exit 7, got $rc" "$out"
[ "$(git -C "$INSTALL" describe --tags --exact-match HEAD)" = 0.10.0 ] \
  || fail 'the new release must still be checked out' "$out"
grep -Fq 'Updated 0.2.0 -> 0.10.0' <<<"$out" || fail 'it must still say what it did' "$out"
grep -Fq 'adrescue bootstrap' <<<"$out" || fail 'it must say how to recover' "$out"
grep -Fq 'link from 0.10.0' "$WORK/steps.log" \
  || fail 'relinking must still run when the bootstrap fails' "$out"
pass

# --ref moves to a named release rather than the latest.
install_at 0.2.0 "$INSTALL"
out="$(run_update "$INSTALL" --ref 0.9.0)" || fail '--ref exits 0' "$out"
[ "$(git -C "$INSTALL" describe --tags --exact-match HEAD)" = 0.9.0 ] \
  || fail '--ref must check out the named tag' "$out"
pass

printf 'self_update: %s checks passed\n' "$checks"
