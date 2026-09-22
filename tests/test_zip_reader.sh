#!/usr/bin/env bash
# SCRIPT: test_zip_reader.sh
# DESCRIPTION: The bugreport zip is read by whatever this machine has.
# USAGE: bash tests/test_zip_reader.sh
#
# Git for Windows ships no unzip, and the tar it ships is GNU tar, which cannot
# read a zip. Left to unzip alone, `adrescue log` on Windows printed one line
# and skipped the bugreport -- which is where last_kmsg, the tombstones and the
# recovery logs are. The report came out smaller with nothing to say why.
#
# Windows itself provides bsdtar as tar.exe, which does read zip, so the reader
# is chosen by asking the binary rather than by its name: `tar` is GNU on Linux
# and inside Git Bash, bsdtar on macOS and Windows.
#
# The bsdtar branch is exercised through a stub, because no bsdtar is installed
# on the machine this suite normally runs on. That proves the selection and the
# argument shape, not bsdtar's own behaviour; a windows-latest job is what
# would prove the rest.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

checks=0
failures=0
pass() { checks=$((checks + 1)); }
note() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A bugreport-shaped zip: two members the extractor wants, one it does not.
python3 - "$WORK/bugreport.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("FS/data/last_kmsg", "kernel panic here\n")
    z.writestr("FS/data/tombstone_01", "native crash here\n")
    z.writestr("FS/data/unrelated.txt", "not wanted\n")
PY

# Source just the reader, with the surrounding script's variables stubbed.
reader_env() {
  WORK_DIR="$1" REPORT="$2" bash -c '
    WORK_DIR="$WORK_DIR" REPORT="$REPORT"
    # The functions live near the top; sourcing the whole tool would run it.
    eval "$(sed -n "/^ANDROID_RESCUE_ZIP_READER=/,/^}$/p;/^zip_looks_readable()/,/^}$/p;/^zip_extract()/,/^}$/p;/^extract_bugreport_artifacts()/,/^}$/p" '"$ROOT"'/tools/analyze_android_capture.sh)"
    '"$3"'
  '
}

# --- with unzip present -----------------------------------------------------

if command -v unzip >/dev/null 2>&1; then
  got="$(reader_env "$WORK" "$WORK/report.txt" 'zip_reader')"
  if [ "$got" = "unzip" ]; then pass; else note "unzip present but reader chose '$got'"; fi

  out="$WORK/out_unzip"; mkdir -p "$out"
  reader_env "$WORK" "$WORK/report.txt" "zip_extract unzip '$WORK/bugreport.zip' '$out' '*last_kmsg*' '*tombstone*'" >/dev/null 2>&1
  if find "$out" -name 'last_kmsg' | grep -q .; then pass; else note "unzip did not extract last_kmsg"; fi
  if find "$out" -name 'unrelated.txt' | grep -q .; then
    note "unzip extracted a member the patterns did not ask for"
  else
    pass
  fi
else
  printf 'zip_reader: no unzip here, skipping its half\n' >&2
fi

# --- with unzip absent and a bsdtar-identifying tar -------------------------

BIN="$WORK/bin"
mkdir -p "$BIN"
cat >"$BIN/tar" <<'STUB'
#!/usr/bin/env bash
# Identifies as bsdtar, and extracts with python so the branch does something
# observable. Not bsdtar: it proves which reader was chosen and how it was
# called, not that bsdtar behaves this way.
if [ "$1" = "--version" ]; then printf 'bsdtar 3.7.2 - libarchive 3.7.2\n'; exit 0; fi
printf '%s\n' "$*" >>"${STUB_CALLS:-/dev/null}"
dest=""; archive=""; patterns=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -xf) archive="$2"; shift 2 ;;
    -tf) archive="$2"; shift 2; python3 -c "import sys,zipfile; zipfile.ZipFile(sys.argv[1])" "$archive" 2>/dev/null; exit $? ;;
    -C)  dest="$2"; shift 2 ;;
    *)   patterns+=("$1"); shift ;;
  esac
done
python3 - "$archive" "$dest" ${patterns[@]+"${patterns[@]}"} <<'PY'
import sys, zipfile, fnmatch, os
archive, dest, pats = sys.argv[1], sys.argv[2], sys.argv[3:]
with zipfile.ZipFile(archive) as z:
    for name in z.namelist():
        if pats and not any(fnmatch.fnmatch(name, p) for p in pats):
            continue
        target = os.path.join(dest, name)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "wb") as fh:
            fh.write(z.read(name))
PY
STUB
chmod +x "$BIN/tar"

# A PATH with the stub tar and no unzip.
NOUNZIP="$WORK/nounzip"
mkdir -p "$NOUNZIP"
for tool in bash sh python3 find sed grep printf mkdir cat rm gzip head; do
  src="$(type -P "$tool" 2>/dev/null)" || continue
  ln -sf "$src" "$NOUNZIP/$tool"
done
ln -sf "$BIN/tar" "$NOUNZIP/tar"

got="$(PATH="$NOUNZIP" reader_env "$WORK" "$WORK/report.txt" 'zip_reader' 2>/dev/null)"
if [ "$got" = "tar" ]; then pass; else note "with no unzip and a bsdtar-identifying tar, reader chose '$got'"; fi

# Chosen is not the same as called correctly. bsdtar takes the destination with
# -C and the patterns last; unzip takes -d and the patterns before it. Handing
# bsdtar unzip's argument order extracts nothing and reports success, because
# the extraction is `|| true` -- a smaller report and no error, which is the
# failure this whole file exists to stop.
out="$WORK/out_bsdtar"
mkdir -p "$out"
PATH="$NOUNZIP" reader_env "$WORK" "$WORK/report.txt" \
  "zip_extract tar '$WORK/bugreport.zip' '$out' '*last_kmsg*' '*tombstone*'" >/dev/null 2>&1
if find "$out" -name 'last_kmsg' | grep -q .; then
  pass
else
  note "the bsdtar branch extracted nothing; check the argument order"
fi
if find "$out" -name 'tombstone_01' | grep -q .; then
  pass
else
  note "the bsdtar branch missed the second pattern"
fi
if find "$out" -name 'unrelated.txt' | grep -q .; then
  note "the bsdtar branch ignored the patterns and extracted everything"
else
  pass
fi

# GNU tar must not be chosen: it cannot read a zip, and picking it would turn a
# clear "no zip reader" into a silent empty extraction.
cat >"$NOUNZIP/tar" <<'GNU'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then printf 'tar (GNU tar) 1.35\n'; exit 0; fi
exit 1
GNU
chmod +x "$NOUNZIP/tar"
if PATH="$NOUNZIP" reader_env "$WORK" "$WORK/report.txt" 'zip_reader' >/dev/null 2>&1; then
  note "GNU tar was accepted as a zip reader"
else
  pass
fi

# And with nothing, the report says so rather than going quiet.
rm -f "$NOUNZIP/tar"
: >"$WORK/report2.txt"
PATH="$NOUNZIP" reader_env "$WORK/w2" "$WORK/report2.txt" \
  "mkdir -p '$WORK/w2'; extract_bugreport_artifacts '$WORK/bugreport.zip'" >/dev/null 2>&1
if grep -q 'No zip reader' "$WORK/report2.txt"; then
  pass
else
  note "with no zip reader the report did not say so: $(cat "$WORK/report2.txt")"
fi

if [ "$failures" -eq 0 ]; then
  printf 'zip_reader: %s checks passed\n' "$checks"
else
  printf 'zip_reader: %s of %s checks FAILED\n' "$failures" "$((checks + failures))" >&2
  exit 1
fi
