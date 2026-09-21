#!/usr/bin/env bash
# SCRIPT: test_adrescue_dispatch.sh
# DESCRIPTION: Subcommand routing, argument forwarding and the restore gate.
# USAGE: bash tests/test_adrescue_dispatch.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

checks=0
fail() { printf 'FAIL: %s\n%s\n' "$1" "${2:-}" >&2; exit 1; }
pass() { checks=$((checks + 1)); }

mkdir -p "$WORK/root/tools" "$WORK/root/scripts" "$WORK/bin"
cp "$ROOT/adrescue" "$WORK/root/"
printf '9.9.9\n' >"$WORK/root/VERSION"

for tool in android_device_probe android_photo_backup android_backup_dialog \
            collect_android_dumps analyze_android_capture build_analysis_prompt \
            android_restore_dialog verify_recovery_archive; do
  cat >"$WORK/root/tools/$tool.sh" <<EOF
#!/usr/bin/env bash
printf '$tool %s\n' "\$*"
exit \${STUB_EXIT:-0}
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

# An isolated HOME and config, so a real one on this machine cannot change the
# answers.
export HOME="$WORK/home"
export XDG_CONFIG_HOME="$WORK/home/.config"
mkdir -p "$HOME"

ADRESCUE="$WORK/root/adrescue"

run() {
  local out rc
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  printf '%s' "$out"
  return "$rc"
}

expect_ok() {
  local name="$1" needle="$2"
  shift 2
  local out
  out="$(run "$@")" || fail "$name (exit $?)" "$out"
  grep -Fq "$needle" <<<"$out" || fail "$name" "$out"
  pass
}

expect_exit() {
  local name="$1" want="$2"
  shift 2
  local out rc
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  [ "$rc" -eq "$want" ] || fail "$name (exit $rc, wanted $want)" "$out"
  pass
}

# Routing.
expect_ok 'probe routes' 'android_device_probe' "$ADRESCUE" probe
expect_ok 'photos routes with a destination' "android_photo_backup $WORK/dest" \
  "$ADRESCUE" photos "$WORK/dest"
expect_ok 'data forwards flags' 'android_backup_dialog /mnt/b --recovery-profile' \
  "$ADRESCUE" data /mnt/b --recovery-profile
expect_ok 'verify forwards arguments' 'verify_recovery_archive /mnt/b --passphrase-fd 3' \
  "$ADRESCUE" verify /mnt/b --passphrase-fd 3
expect_ok 'prompt forwards both arguments' 'build_analysis_prompt captures/x out.md' \
  "$ADRESCUE" prompt captures/x out.md
expect_ok 'bootstrap routes' 'bootstrap ran' "$ADRESCUE" bootstrap
expect_ok 'deps aliases bootstrap' 'bootstrap ran' "$ADRESCUE" deps
expect_ok 'update routes to self-update' 'self_update ran' "$ADRESCUE" update

# log runs both tools against the same destination.
out="$(run "$ADRESCUE" log "$WORK/cap")" || fail 'log exits 0' "$out"
grep -Fq "collect_android_dumps $WORK/cap" <<<"$out" || fail 'log collects' "$out"
grep -Fq "analyze_android_capture $WORK/cap" <<<"$out" || fail 'log analyses' "$out"
pass

# Bare `adrescue data` must start. On bash 3.2 a bare "$@" with no positional
# parameters is an unbound-variable error under set -u, which killed the
# documented no-argument form before it ran.
expect_exit 'data with no arguments starts' 0 "$ADRESCUE" data

# Default destinations come from the data and work directories.
out="$(run "$ADRESCUE" photos)" || fail 'photos with no destination' "$out"
grep -Fq "$HOME/android-rescue/data/photos/" <<<"$out" || fail 'photos uses the data dir' "$out"
pass
out="$(run "$ADRESCUE" log)" || fail 'log with no destination' "$out"
grep -Fq "$HOME/android-rescue/work/captures/" <<<"$out" || fail 'log uses the work dir' "$out"
pass
out="$(run "$ADRESCUE" --data-dir "$WORK/flag" photos)" || fail 'photos honours --data-dir' "$out"
grep -Fq "$WORK/flag/photos/" <<<"$out" || fail '--data-dir wins' "$out"
pass
out="$(run env ANDROID_RESCUE_DATA_DIR="$WORK/envdir" "$ADRESCUE" photos)" \
  || fail 'photos honours the environment' "$out"
grep -Fq "$WORK/envdir/photos/" <<<"$out" || fail 'env var is used' "$out"
pass

# config: set, show the source, then override it with a flag.
expect_ok 'config set writes' "data-dir = $WORK/cfgdata" \
  "$ADRESCUE" config set data-dir "$WORK/cfgdata"
expect_ok 'config show reports the file as the source' "$XDG_CONFIG_HOME/android-device-rescue-kit/config" \
  "$ADRESCUE" config
out="$(run "$ADRESCUE" photos)" || fail 'photos after config set' "$out"
grep -Fq "$WORK/cfgdata/photos/" <<<"$out" || fail 'config value is used' "$out"
pass
expect_exit 'config rejects an unknown key' 2 "$ADRESCUE" config set nonsense /tmp
expect_ok 'config unset clears' 'data-dir cleared' "$ADRESCUE" config unset data-dir

# --help must be answered by the dispatcher. Only the backup dialog handles it
# itself; android_photo_backup.sh would treat --help as the destination and
# create a directory with that name.
# Exit 0 is not enough: a subcommand that forwards --help to its tool would
# also exit 0 while doing the real work. The output has to be usage text.
for sub in probe photos log verify restore prompt config update bootstrap; do
  out="$(run "$ADRESCUE" "$sub" --help)" || fail "$sub --help exits 0" "$out"
  grep -Fq 'Usage:' <<<"$out" || fail "$sub --help must print usage" "$out"
  pass
done
[ -e "$WORK/root/--help" ] && fail 'photos --help created a directory named --help'
[ -e "./--help" ] && fail 'photos --help created a directory in the test cwd'
pass

# Exit status passes through: probe exits 2, photos exits 1, and those contracts
# are the point of both commands.
expect_exit 'probe exit status passes through' 2 env STUB_EXIT=2 "$ADRESCUE" probe
expect_exit 'photos exit status passes through' 1 env STUB_EXIT=1 "$ADRESCUE" photos "$WORK/d2"

expect_exit 'unknown command exits 1' 1 "$ADRESCUE" nonsense
out="$("$ADRESCUE" nonsense 2>&1 >/dev/null)" || true
grep -Fq 'Unknown command' <<<"$out" || fail 'unknown command writes to stderr' "$out"
pass

# Every subcommand must appear in the help, or a new one is unreachable in
# practice.
out="$(run "$ADRESCUE" --help)" || fail 'help exits 0' "$out"
for sub in probe photos data log verify restore prompt config update bootstrap; do
  grep -Fq "  $sub" <<<"$out" || fail "help lists $sub" "$out"
done
pass
expect_ok 'version reports VERSION' '9.9.9' "$ADRESCUE" --version

# --- restore gate ------------------------------------------------------------

mkdir -p "$WORK/backup/shared/DCIM" "$WORK/bin"
printf 'x\n' >"$WORK/backup/shared/DCIM/a.jpg"

write_adb_stub() {
  cat >"$WORK/bin/adb" <<EOF
#!/usr/bin/env bash
if [ "\$1" = devices ]; then
  printf 'List of devices attached\n'
  printf '%s\n' $1
  exit 0
fi
printf 'stub\n'
EOF
  chmod +x "$WORK/bin/adb"
}

write_adb_stub "\$'AAA\tdevice' \$'BBB\tdevice'"
out="$(PATH="$WORK/bin:$PATH" run "$ADRESCUE" restore "$WORK/backup")" && \
  fail 'restore must refuse two devices' "$out"
grep -Fq 'Disconnect all but the one' <<<"$out" || fail 'restore names the problem' "$out"
grep -Fq 'AAA' <<<"$out" || fail 'restore lists the first device' "$out"
grep -Fq 'BBB' <<<"$out" || fail 'restore lists the second device' "$out"
pass

write_adb_stub "\$'AAA\tdevice'"
out="$(printf 'yes\n' | PATH="$WORK/bin:$PATH" "$ADRESCUE" restore "$WORK/backup" 2>&1)" && \
  fail 'restore must reject a piped answer' "$out"
grep -Fq 'android_restore_dialog' <<<"$out" && fail 'restore ran the tool without confirmation' "$out"
pass

out="$(PATH="$WORK/bin:$PATH" run "$ADRESCUE" restore "$WORK/backup" --yes)" && \
  fail 'restore --yes without --serial must fail' "$out"
grep -Fq 'requires --serial' <<<"$out" || fail 'restore explains why --yes failed' "$out"
pass

expect_ok 'restore --yes --serial runs the tool' 'android_restore_dialog' \
  env PATH="$WORK/bin:$PATH" "$ADRESCUE" restore "$WORK/backup" --serial AAA --yes

out="$(PATH="$WORK/bin:$PATH" run "$ADRESCUE" restore "$WORK/backup" --serial ZZZ --yes)" && \
  fail 'restore must reject an absent serial' "$out"
grep -Fq 'No attached phone has serial ZZZ' <<<"$out" || fail 'restore names the bad serial' "$out"
pass

printf 'adrescue_dispatch: %s checks passed\n' "$checks"
