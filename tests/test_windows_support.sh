#!/usr/bin/env bash
# SCRIPT: test_windows_support.sh
# DESCRIPTION: The things that make the toolkit run under Git Bash on Windows.
# USAGE: bash tests/test_windows_support.sh
#
# None of this needs Windows. What it checks is the two decisions that make a
# Windows clone work at all, and both are observable from here: the line
# endings git will write, and the argument conversion the MSYS runtime applies.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

checks=0
failures=0
pass() { checks=$((checks + 1)); }
note() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

# --- line endings ----------------------------------------------------------
#
#     Git for Windows defaults to core.autocrlf=true. Without .gitattributes
#     every script is checked out with CRLF, and bash reports
#     "/usr/bin/env: 'bash\r': No such file or directory" on the first one the
#     user runs. Nothing in that message says "line endings".

if [ -f .gitattributes ]; then
  pass
else
  note ".gitattributes is missing; a Windows clone will get CRLF in every script"
fi

for entry in adrescue dump dump.sh prompt update install.sh; do
  eol="$(git check-attr eol -- "$entry" | sed 's/.*: //')"
  if [ "$eol" = "lf" ]; then
    pass
  else
    note "$entry is not pinned to eol=lf (got '$eol'); bash cannot run it with CRLF"
  fi
done

# PowerShell is read by Windows tools, which want CRLF.
eol="$(git check-attr eol -- install.ps1 | sed 's/.*: //')"
if [ "$eol" = "crlf" ]; then
  pass
else
  note "install.ps1 should be eol=crlf, got '$eol'"
fi

# A file bash has to read may not carry CRLF. The rule is per-file, taken from
# the attribute rather than assumed: install.ps1 is deliberately CRLF and is
# checked out that way, so an "in no file anywhere" rule fails on CI while
# passing on a working copy that has not been re-touched since.
crlf=0
while IFS= read -r f; do
  case "$f" in *.png|*.jpg|*.gif|*.ico|*.pdf|*.gpg|*.zip|*.gz) continue ;; esac
  [ -f "$f" ] || continue
  [ "$(git check-attr eol -- "$f" | sed 's/.*: //')" = "lf" ] || continue
  if grep -qU $'\r' "$f" 2>/dev/null; then
    note "$f is declared eol=lf but contains CRLF"
    crlf=$((crlf + 1))
  fi
done < <(git ls-files)
[ "$crlf" -eq 0 ] && pass

# --- MSYS argument conversion ----------------------------------------------
#
#     The MSYS2 runtime rewrites POSIX-looking arguments into Windows paths
#     before a native .exe sees them, so `adb shell ls /sdcard` arrives as
#     `ls C:/Program Files/Git/sdcard`. The phone answers "no such file" and
#     it reads as a device fault.
#
#     What follows checks that MSYS2_ARG_CONV_EXCL is set, and nothing more.
#     It does not check that a path survives conversion, and it cannot: the
#     rewrite happens when the MSYS2 runtime executes a native .exe, so on
#     Linux there is nothing to rewrite and the mock adb is a shell script
#     anyway. An assertion about a converted argument would neither pass nor
#     fail here, which is worse than absent -- nine green checks under a
#     heading that says "conversion" read as conversion being covered.
#
#     Proving the conversion needs a windows-latest job. Tracked separately;
#     until it exists, this section's guarantee is the variable only.

msys_env() {
  local uname_out="$1"
  local stub="$WORK/bin"
  mkdir -p "$stub"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\n' "$uname_out" >"$stub/uname"
  chmod +x "$stub/uname"
  PATH="$stub:$PATH" bash -c '
    source "'"$ROOT"'/tools/lib/common.sh" >/dev/null 2>&1
    printf "%s\n" "${MSYS2_ARG_CONV_EXCL:-unset}"
  ' 2>/dev/null
}

for sys in MINGW64_NT-10.0 MSYS_NT-10.0 CYGWIN_NT-10.0; do
  got="$(msys_env "$sys")"
  case "$got" in
    *"/sdcard"*) pass ;;
    *) note "under $sys, device paths are not excluded from conversion (got: $got)" ;;
  esac
done

# Every device prefix the tools actually pass to adb has to be covered, or the
# uncovered one is rewritten and the failure looks like a missing file.
got="$(msys_env MINGW64_NT-10.0)"
for prefix in /sdcard /storage /data; do
  case "$got" in
    *"$prefix"*) pass ;;
    *) note "$prefix is passed to adb but not excluded from MSYS conversion" ;;
  esac
done

# On Linux and macOS nothing should be set: the variable means nothing there,
# and setting it would be a lie about the environment.
for sys in Linux Darwin; do
  got="$(msys_env "$sys")"
  if [ "$got" = "unset" ]; then
    pass
  else
    note "MSYS2_ARG_CONV_EXCL should not be set on $sys, got: $got"
  fi
done

# An existing value must be extended rather than replaced: it belongs to the
# user, not to us.
stub="$WORK/bin2"
mkdir -p "$stub"
printf '#!/usr/bin/env bash\nprintf "MINGW64_NT-10.0\\n"\n' >"$stub/uname"
chmod +x "$stub/uname"
got="$(PATH="$stub:$PATH" MSYS2_ARG_CONV_EXCL='/opt/mine' bash -c '
  source "'"$ROOT"'/tools/lib/common.sh" >/dev/null 2>&1
  printf "%s\n" "${MSYS2_ARG_CONV_EXCL:-unset}"
' 2>/dev/null)"
case "$got" in
  */opt/mine*/sdcard*) pass ;;
  *) note "an existing MSYS2_ARG_CONV_EXCL was not preserved (got: $got)" ;;
esac

# --- the installer ---------------------------------------------------------

if [ -f install.ps1 ]; then
  # The native path must not require WSL. A -UseWsl switch may mention it.
  if grep -q 'UseWsl' install.ps1; then
    pass
  else
    note "install.ps1 has no -UseWsl switch; the fallback is meant to stay available"
  fi

  for id in Git.Git Google.PlatformTools BurntSushi.ripgrep.MSVC GnuPG.GnuPG; do
    if grep -q "$id" install.ps1; then
      pass
    else
      note "install.ps1 does not install $id"
    fi
  done

  # winget waits for a keypress without these, and a scripted install hangs.
  if grep -q 'accept-package-agreements' install.ps1 && grep -q 'accept-source-agreements' install.ps1; then
    pass
  else
    note "install.ps1 must pass --accept-package-agreements and --accept-source-agreements, or a silent install hangs"
  fi
fi

# --- the installer actually runs there --------------------------------------
#
#     Everything above this line, and every check in the first version of this
#     file, was a grep for a string. install.ps1 hands over to install.sh,
#     whose platform case answered MINGW64_NT-10.0 with "On Windows, run
#     install.ps1 from PowerShell" -- to a user who had just done that. The
#     native install could not complete, and four string checks passed.

run_with_uname() {
  local uname_out="$1"; shift
  local stub="$WORK/un_${uname_out%%_*}"
  mkdir -p "$stub"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\n' "$uname_out" >"$stub/uname"
  chmod +x "$stub/uname"
  PATH="$stub:$PATH" "$@"
}

for sys in MINGW64_NT-10.0 MSYS_NT-10.0 Linux Darwin; do
  out="$(run_with_uname "$sys" bash install.sh --dry-run 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -qi 'unsupported platform'; then
    pass
  else
    note "install.sh refuses to run under $sys (exit $rc): $(printf '%s' "$out" | head -1)"
  fi
done

# And still refuses something it genuinely cannot install onto, or the check
# above is satisfied by removing the gate rather than fixing it.
if run_with_uname 'Haiku' bash install.sh --dry-run >/dev/null 2>&1; then
  note "install.sh accepts an unknown platform; the gate no longer gates"
else
  pass
fi

# --- the shim forwards its arguments ----------------------------------------
#
#     The generated .cmd used $* where batch needs %*. cmd.exe leaves $* alone,
#     bash expands it against its own empty argument list, and every
#     `adrescue probe` arrived as a bare `adrescue`. No test could see it,
#     because no test looked at the line.

shim_line="$(grep -F -- '-lc "adrescue' install.ps1 || true)"
if [ -z "$shim_line" ]; then
  note "install.ps1 no longer writes a bash -lc line for the shim; this check is now blind"
else
  case "$shim_line" in
    *'%*'*) pass ;;
    *) note "the .cmd shim does not forward %*, so every argument is dropped: $shim_line" ;;
  esac
  case "$shim_line" in
    *'"adrescue $*"'*)
      note 'the .cmd shim uses $*, which cmd.exe does not expand: every argument is lost' ;;
    *) pass ;;
  esac
fi

# The shim must not be pointed at C:\Windows\System32\bash.exe, which is the
# WSL launcher and the one interpreter this whole decision avoids.
# Comments stripped first: the comment in install.ps1 explaining why this
# fallback is wrong matched the check looking for it, and the guard failed on
# its own documentation.
if sed 's/#.*//' install.ps1 | grep -q 'Get-Command bash'; then
  note "install.ps1 falls back to Get-Command bash, which finds WSL's launcher on a machine that has WSL"
else
  pass
fi

# --- launchers survive a platform without symlinks ---------------------------
#
#     Git for Windows does not enable symlinks by default and `ln -s` copies
#     instead. A copy has no chain for adrescue's readlink loop to follow, so
#     ROOT resolves to the bin directory and every tools/ lookup misses --
#     the original bug, back through a different door.

nolink="$WORK/nolink"
mkdir -p "$nolink"
cat >"$nolink/ln" <<'LNSTUB'
#!/usr/bin/env bash
# What Git Bash does with `ln -s` when symlinks are not enabled.
args=()
for a in "$@"; do case "$a" in -*) ;; *) args+=("$a") ;; esac; done
cp -f "${args[0]}" "${args[1]}"
LNSTUB
chmod +x "$nolink/ln"

bindir="$WORK/bin_nolink"
if PATH="$nolink:$PATH" bash scripts/link_launchers.sh "$ROOT" "$bindir" >/dev/null 2>&1; then
  pass
else
  note "link_launchers.sh fails when ln -s cannot create a symlink"
fi

if [ -x "$bindir/adrescue" ]; then pass; else note "no adrescue launcher was created without symlinks"; fi

# The point of the wrapper: it still finds the installation.
if out="$("$bindir/adrescue" --version 2>&1)" && [ -n "$out" ]; then
  pass
else
  note "the launcher written without symlinks cannot find its installation: $out"
fi

# Arguments have to reach it, which is what a plain copy would also fail at.
if "$bindir/adrescue" --help 2>&1 | grep -qi 'probe'; then
  pass
else
  note "the symlink-less launcher does not forward its arguments"
fi

# Running the installer twice must not refuse the launchers it wrote itself.
if PATH="$nolink:$PATH" bash scripts/link_launchers.sh "$ROOT" "$bindir" >/dev/null 2>&1; then
  pass
else
  note "a second install refuses the wrapper the first one wrote"
fi

# It must still refuse a binary that is not ours.
printf '#!/bin/sh\necho someone elses\n' >"$bindir/adrescue"
chmod +x "$bindir/adrescue"
if PATH="$nolink:$PATH" bash scripts/link_launchers.sh "$ROOT" "$bindir" >/dev/null 2>&1; then
  note "link_launchers.sh overwrote an unrelated binary named adrescue"
else
  pass
fi

# --- the interactive commands run with dialog absent ------------------------
#
#     dialog gates `data` and `restore`, and Git for Windows ships no package
#     manager to install it with. Until 0.9.0 restore had no path that did not
#     go through dialog, so it could not run there in any form. The prompts now
#     fall back to plain text.

# Nothing may call a dialog widget outside the UI layer. This is the check that
# keeps the fallback whole: one new `dialog --menu` added later in a tool would
# reintroduce exactly the old failure, in one flow, on a platform CI does not
# run.
# Scanned with the line continuations joined first, because a line-based grep
# cannot see these calls at all: every one is written across several lines,
#
#     picked=$(dialog --stdout --separate-output \
#       --title "..." \
#       --checklist "..." \
#
# so the line holding `dialog` has no widget on it and the line holding the
# widget has no `dialog`. Two earlier versions of this check were blind for
# that reason, and the second one passed while a real call site still went
# straight to dialog -- found only when the removed $LIST_HEIGHT broke it.
stray="$(python3 - <<'SCAN'
import re, pathlib
WIDGET = re.compile(r"--(checklist|menu|radiolist|msgbox|yesno|inputbox|passwordbox)\b")
for path in list(pathlib.Path("tools").rglob("*.sh")) + [pathlib.Path("adrescue")]:
    if path.as_posix() == "tools/lib/ui.sh" or not path.is_file():
        continue
    text = path.read_text(encoding="utf-8", errors="replace")
    # Join continuations, keeping a line number for the start of each command.
    joined, start, buf = [], 1, ""
    for n, line in enumerate(text.splitlines(), 1):
        if not buf:
            start = n
        buf += line.rstrip("\\")
        if line.rstrip().endswith("\\"):
            continue
        joined.append((start, buf))
        buf = ""
    if buf:
        joined.append((start, buf))
    for n, cmd in joined:
        if cmd.lstrip().startswith("#"):
            continue
        if re.search(r"\bdialog\b", cmd) and WIDGET.search(cmd):
            print(f"{path}:{n}: {cmd.strip()[:100]}")
SCAN
)"
if [ -z "$stray" ]; then
  pass
else
  note "a dialog widget is called outside tools/lib/ui.sh:"
  printf '%s\n' "$stray" | sed 's/^/    /' >&2
fi

# The gate that used to refuse is gone, rather than merely unused.
if grep -q 'require_dialog' tools/lib/common.sh; then
  note "require_dialog still exists in common.sh; a caller could reintroduce the refusal"
else
  pass
fi

for tool in tools/android_restore_dialog.sh tools/android_backup_dialog.sh; do
  if grep -q 'ui_init' "$tool"; then
    pass
  else
    note "$tool does not initialise the UI layer"
  fi
done

if [ "$failures" -eq 0 ]; then
  printf 'windows_support: %s checks passed\n' "$checks"
else
  printf 'windows_support: %s of %s checks FAILED\n' "$failures" "$((checks + failures))" >&2
  exit 1
fi
