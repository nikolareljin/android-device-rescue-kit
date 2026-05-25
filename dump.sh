#!/usr/bin/env bash
set -euo pipefail

exec "$(dirname "$0")/tools/collect_android_dumps.sh" "$@"
