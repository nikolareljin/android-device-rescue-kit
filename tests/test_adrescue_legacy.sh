#!/usr/bin/env bash
# SCRIPT: test_adrescue_legacy.sh
# DESCRIPTION: Old entrypoints keep working, including through a PATH symlink.
# USAGE: bash tests/test_adrescue_legacy.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

checks=0
fail() { printf 'FAIL: %s\n%s\n' "$1" "${2:-}" >&2; exit 1; }
pass() { checks=$((checks + 1)); }

# A throwaway install: the real entrypoints, stub tools. No adb, no network.
build_fixture() {
  mkdir -p "$WORK/root/tools" "$WORK/root/scripts" "$WORK/bin"
  cp "$ROOT/adrescue" "$ROOT/dump" "$ROOT/dump.sh" "$ROOT/prompt" "$ROOT/update" "$WORK/root/"
  cp "$ROOT/VERSION" "$WORK/root/VERSION"
  local tool
  for tool in android_device_probe android_photo_backup android_backup_dialog \
              collect_android_dumps analyze_android_capture build_analysis_prompt \
              android_restore_dialog verify_recovery_archive; do
    cat >"$WORK/root/tools/$tool.sh" <<EOF
#!/usr/bin/env bash
printf '$tool %s\n' "\$*"
EOF
    chmod +x "$WORK/root/tools/$tool.sh"
  done
  cat >"$WORK/root/scripts/bootstrap.sh" <<'EOF'
#!/usr/bin/env bash
printf 'bootstrap ran\n'
EOF
  cat >"$WORK/root/scripts/self_update.sh" <<'EOF'
#!/usr/bin/env bash
printf 'self_update ran\n'
EOF
  chmod +x "$WORK/root/scripts/bootstrap.sh" "$WORK/root/scripts/self_update.sh"
}

run() {
  local out rc
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  printf '%s' "$out"
  return "$rc"
}

expect_contains() {
  local name="$1" needle="$2"
  shift 2
  local out
  out="$(run "$@")" || fail "$name (exit $?)" "$out"
  grep -Fq "$needle" <<<"$out" || fail "$name" "$out"
  pass
}

build_fixture

# Local spellings.
expect_contains 'dump probe' 'android_device_probe' "$WORK/root/dump" probe
expect_contains 'dump.sh runs a log capture' 'collect_android_dumps' "$WORK/root/dump.sh"
expect_contains 'dump.sh with a destination' 'collect_android_dumps /tmp/x' "$WORK/root/dump.sh" /tmp/x
expect_contains 'prompt forwards a capture' 'build_analysis_prompt captures/x' \
  "$WORK/root/prompt" captures/x
expect_contains 'update still means bootstrap' 'bootstrap ran' "$WORK/root/update"

# The installed launchers. These resolve through a symlink, which is what
# dirname "$0" never did: the old root became ~/.local/bin and every
# "$ROOT/tools/..." lookup missed.
ln -s "$WORK/root/dump" "$WORK/bin/android-rescue-dump"
ln -s "$WORK/root/prompt" "$WORK/bin/android-rescue-prompt"
ln -s "$WORK/root/update" "$WORK/bin/android-rescue-update"
ln -s "$WORK/root/adrescue" "$WORK/bin/adrescue"

expect_contains 'android-rescue-dump resolves the real root' 'android_device_probe' \
  "$WORK/bin/android-rescue-dump" probe
expect_contains 'android-rescue-prompt resolves the real root' 'build_analysis_prompt captures/x' \
  "$WORK/bin/android-rescue-prompt" captures/x
expect_contains 'android-rescue-update runs bootstrap' 'bootstrap ran' \
  "$WORK/bin/android-rescue-update"
expect_contains 'adrescue resolves the real root' 'android_device_probe' \
  "$WORK/bin/adrescue" probe

# android-rescue-update must not have quietly become the self-updater.
out="$(run "$WORK/bin/android-rescue-update")" || fail 'legacy update exits 0' "$out"
if grep -Fq 'self_update ran' <<<"$out"; then
  fail 'android-rescue-update must keep meaning bootstrap, not self-update' "$out"
fi
pass

# Help says back the name the user typed.
out="$(run "$WORK/bin/adrescue" --help)" || fail 'adrescue --help exits 0' "$out"
grep -Eq '(^|[^./])adrescue probe' <<<"$out" || fail 'installed help shows bare adrescue' "$out"
grep -Fq './adrescue probe' <<<"$out" && fail 'installed help must not show ./adrescue' "$out"
pass

out="$(cd "$WORK/root" && run ./adrescue --help)" || fail 'clone help exits 0' "$out"
grep -Fq './adrescue probe' <<<"$out" || fail 'clone help shows ./adrescue' "$out"
pass

out="$(cd "$WORK/root" && run ./dump --help)" || fail 'dump --help exits 0' "$out"
grep -Fq './dump probe' <<<"$out" || fail 'dump help keeps the dump spelling' "$out"
pass

# The shims have to stay in the repository, or every installed symlink dangles.
for entry in adrescue dump dump.sh prompt update; do
  [ -x "$ROOT/$entry" ] || fail "$entry must exist and be executable"
  pass
done

printf 'adrescue_legacy: %s checks passed\n' "$checks"
