#!/usr/bin/env bash
# SCRIPT: test_no_device_identifiers.sh
# DESCRIPTION: No real device identifier is written anywhere in this repository.
# USAGE: bash tests/test_no_device_identifiers.sh
#
# This repository is public, and a serial identifies one specific handset. A
# real one reached tests/test_device_state.sh once, captured verbatim from a
# phone while writing a fixture, and sat there through several releases: it
# looked exactly like the invented strings beside it.
#
# Real handsets are named in .env, which is gitignored. Nothing tracked may
# carry one, so this fails on the shapes the common vendors use.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

checks=0
failures=0
pass() { checks=$((checks + 1)); }
note() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

# Done in python so a match can be judged properly. An earlier ERE
# "\bR[0-9A-Za-z]{10}\b" flagged "replacement", "restriction" and
# "recommended": a guard that cries wolf on prose gets switched off.
scan_tree() {
  python3 - "$ROOT" <<'PYEOF'
import re, subprocess, sys

root = sys.argv[1]
files = subprocess.run(["git", "-C", root, "ls-files"],
                       capture_output=True, text=True).stdout.split()

ALLOW = ("FAKEPHONE0001", "MOCKSERIAL", "CUSTOMSERIAL", "TEST_SERIAL")
SKIP_PREFIX = ("scripts/script-helpers/", "scripts/ci-helpers/")
SKIP_FILES = ("env.example", "tests/test_no_device_identifiers.sh")

# Samsung-style: R plus ten uppercase alphanumerics, at least two of them
# digits, which is what separates R5CT2036VLW from a shouted English word.
samsung = re.compile(r"\bR[0-9A-Z]{10}\b")
# adb also reports 16-hex-digit ids, and emulator-NNNN.
hexid = re.compile(r"\b[0-9a-f]{16}\b")
emulator = re.compile(r"\bemulator-[0-9]{4}\b")

hits = []
for rel in files:
    if rel.startswith(SKIP_PREFIX) or rel in SKIP_FILES:
        continue
    try:
        text = open(f"{root}/{rel}", encoding="utf-8").read()
    except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
        continue
    for n, line in enumerate(text.splitlines(), 1):
        if any(a in line for a in ALLOW):
            continue
        for m in samsung.finditer(line):
            if sum(c.isdigit() for c in m.group()) >= 2:
                hits.append((rel, n, m.group()))
        for rx in (hexid, emulator):
            for m in rx.finditer(line):
                hits.append((rel, n, m.group()))

for rel, n, found in hits:
    print(f"{rel}:{n}: {found}")
sys.exit(1 if hits else 0)
PYEOF
}

if ! output="$(scan_tree)"; then
  note "the tracked tree carries what looks like a device identifier:"
  printf '%s\n' "$output" | sed 's/^/    /' >&2
  printf '  Put real handsets in .env instead; see env.example.\n' >&2
else
  pass
fi


# .env must never be tracked, whatever it contains.
if git ls-files --error-unmatch .env >/dev/null 2>&1; then
  note ".env is tracked; it must stay local and gitignored"
else
  pass
fi

# And the ignore rule has to actually work, or the guard above is the only
# thing standing between a real serial and a public commit.
if [ ! -f .gitignore ] || ! git check-ignore -q .env 2>/dev/null; then
  note ".gitignore does not ignore .env"
else
  pass
fi

# env.example must stay committed: it is how anyone learns the mechanism.
if git ls-files --error-unmatch env.example >/dev/null 2>&1; then
  pass
else
  note "env.example is not tracked, so the .env mechanism is undiscoverable"
fi

if [ "$failures" -eq 0 ]; then
  printf 'no_device_identifiers: %s checks passed\n' "$checks"
else
  printf 'no_device_identifiers: %s of %s checks FAILED\n' \
    "$failures" "$((checks + failures))" >&2
  exit 1
fi
