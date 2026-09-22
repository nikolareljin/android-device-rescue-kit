#!/usr/bin/env bash
# SCRIPT: tests/lib/test_env.sh
# DESCRIPTION: Optional local test settings, from a gitignored .env.
# USAGE: source tests/lib/test_env.sh
#
# A real device serial is a device identifier, and this repository is public.
# None is written in the code: the fixtures use an obviously fake one, and a
# real handset is named only in a .env that is never committed.
#
#   cp env.example .env
#   # then edit .env
#
# Nothing here is required. With no .env the suite runs exactly as it does in
# CI, against the mock device.

# Parsed with an allowlist rather than sourced. A .env is a file people copy
# between machines and paste into; `source` would execute whatever is in it.
test_env_load() {
    local file="${1:-}" line key value
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) continue ;;
        esac
        key="${line%%=*}"
        value="${line#*=}"
        # Strip one layer of surrounding quotes, and any trailing comment on
        # an unquoted value.
        case "$value" in
            \"*\") value="${value#\"}"; value="${value%\"}" ;;
            \'*\') value="${value#\'}"; value="${value%\'}" ;;
        esac
        case "$key" in
            ANDROID_RESCUE_TEST_SERIAL|ANDROID_RESCUE_TEST_MODEL|ANDROID_RESCUE_TEST_DEVICE)
                # An existing environment variable wins, so a one-off run can
                # override the file without editing it.
                # Indirect expansion rather than eval. The key is already
                # constrained to the three names above, but eval on a line
                # read from a file is a habit worth not having.
                if [ -z "${!key:-}" ]; then
                    export "$key=$value"
                fi
                ;;
            *) ;;
        esac
    done <"$file"
}

TEST_ENV_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_env_load "$TEST_ENV_ROOT/.env"

# The fixtures' defaults. Deliberately not the shape of any real serial.
TEST_SERIAL="${ANDROID_RESCUE_TEST_SERIAL:-FAKEPHONE0001}"
TEST_MODEL="${ANDROID_RESCUE_TEST_MODEL:-Fake Phone}"
export TEST_SERIAL TEST_MODEL

# Are the tests that need a real handset switched on?
test_env_wants_device() { [ "${ANDROID_RESCUE_TEST_DEVICE:-0}" = "1" ]; }

# Point every adb call at the configured handset, and nothing else. ANDROID_SERIAL
# is adb's own variable, so this reaches the tools without any of them knowing
# about .env -- and it matters: `adb shell` with two phones attached fails
# outright, and with one other phone attached it would talk to the wrong one.
#
# Only in device mode. Exporting it while the mock is in use would pin a serial
# the mock does not report.
test_env_target_device() {
    test_env_wants_device || return 0
    [ -n "${ANDROID_RESCUE_TEST_SERIAL:-}" ] || return 0
    export ANDROID_SERIAL="$ANDROID_RESCUE_TEST_SERIAL"
}
