#!/usr/bin/env bash
# SCRIPT: test_device_probe.sh
# DESCRIPTION: Test immediate, read-only ADB device-state probing.
# USAGE: bash tests/test_device_probe.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
cat >"$WORK/bin/adb" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = devices ]; then
  printf 'List of devices attached\n%s\n' "${MOCK_ADB_ROW:-}"
fi
EOF
chmod +x "$WORK/bin/adb"

check() {
  local name="$1" expected="$2" row="$3" needle="$4" out rc
  set +e
  out="$(PATH="$WORK/bin:$PATH" MOCK_ADB_ROW="$row" "$ROOT/dump" probe 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne "$expected" ] || ! grep -Fq "$needle" <<<"$out"; then
    printf 'FAIL: %s (exit=%s, output=%s)\n' "$name" "$rc" "$out" >&2
    exit 1
  fi
}

check 'authorised phone starts backup path' 0 $'SERIAL\tdevice' 'Start the priority backup now'
check 'unapproved phone is not changed' 2 $'SERIAL\tunauthorized' 'cannot be enabled or authorised from this computer'
check 'absent phone gives screen-recovery route' 2 '' 'No ADB-capable phone was detected'
printf 'device_probe: 3 checks passed\n'
