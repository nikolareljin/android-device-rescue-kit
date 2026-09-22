#!/usr/bin/env bash
# SCRIPT: tools/lib/zip.sh
# DESCRIPTION: Read a zip with whatever this machine actually has.
# USAGE: source tools/lib/zip.sh
#
# Git for Windows ships no unzip, and the tar it does ship is GNU tar, which
# cannot read a zip. Windows itself provides bsdtar as tar.exe, which can.
#
# The reader is chosen by asking the binary, never by its name: `tar` is GNU on
# Linux and inside Git Bash, and bsdtar on macOS and on Windows outside Git
# Bash. Picking it by name would turn "no zip reader" into a silent empty
# extraction, which is worse, because the extraction is best-effort and a
# missing bugreport shows up only as a shorter report.
#
# This lives in one file because two copies drifted within an hour of being
# written: the installer probed only `tar`, so inside Git Bash it found GNU tar
# and told the user that `adrescue log` would skip the bugreport -- while the
# analyzer looked at /c/Windows/System32/tar.exe as well and would have
# extracted it fine. The installer was stating something false about the tool
# it had just installed.

# zip_reader -> prints the command to use, or returns 1.
#
# Not memoised. It was, with a variable set inside the function, and every
# caller invokes it as `r="$(zip_reader)"` -- a command substitution is a
# subshell, so the assignment was discarded every time and the cache was a
# comment describing something that never happened. It runs at most twice per
# capture; resolving twice is cheaper than a cache that lies.
zip_reader() {
  if command -v unzip >/dev/null 2>&1; then
    printf 'unzip\n'
    return 0
  fi
  local candidate
  for candidate in bsdtar tar /c/Windows/System32/tar.exe /mnt/c/Windows/System32/tar.exe; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    if "$candidate" --version 2>/dev/null | head -1 | grep -qi 'bsdtar\|libarchive'; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# zip_looks_readable <reader> <file>: is this actually a zip?
zip_looks_readable() {
  local reader="$1" file="$2"
  case "$reader" in
    unzip) unzip -t "$file" >/dev/null 2>&1 ;;
    *)     "$reader" -tf "$file" >/dev/null 2>&1 ;;
  esac
}

# zip_extract <reader> <zip> <dest> [pattern ...]
#
# The two disagree about argument order, and getting it wrong extracts nothing
# while reporting success: unzip takes the patterns before `-d <dest>`, bsdtar
# takes `-C <dest>` and the patterns last.
zip_extract() {
  local reader="$1" zip_file="$2" dest="$3"
  shift 3
  case "$reader" in
    unzip)
      unzip -qq -o "$zip_file" ${1+"$@"} -d "$dest" 2>/dev/null || true
      ;;
    *)
      "$reader" -xf "$zip_file" -C "$dest" ${1+"$@"} 2>/dev/null || true
      ;;
  esac
}
