#!/usr/bin/env bash
# SCRIPT: test_ui_fallback.sh
# DESCRIPTION: The prompts behave the same with dialog absent.
# USAGE: bash tests/test_ui_fallback.sh
#
# The contract these have to keep is dialog's, because every caller was written
# against it: the answer on stdout and nothing else, prompts on stderr, and a
# non-zero exit for cancel. The first of those is the one that fails silently.
# A fallback that printed its menu to stdout would put the menu into the
# caller's variable, and `case "$mode" in full) ...` would match the word
# "full" in the menu text rather than the user's choice.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

checks=0
failures=0
pass() { checks=$((checks + 1)); }
note() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

# Text mode, whether or not dialog is installed on the machine running this.
export ANDROID_RESCUE_UI=text

WORK_UI="$(mktemp -d)"
trap 'rm -rf "$WORK_UI"' EXIT

ui() {
  # Answers on stdin, answer captured from stdout, prompts discarded.
  local input="$1"; shift
   printf '%b' "$input" | (source "$ROOT/tools/lib/ui.sh"; "$@") 2>/dev/null
}
ui_rc() {
  local input="$1"; shift
   printf '%b' "$input" | (source "$ROOT/tools/lib/ui.sh"; "$@") >/dev/null 2>&1
}
ui_err() {
  # stderr in, stdout discarded: the opposite of ui(). The order is the point
  # and shellcheck cannot tell a deliberate swap from the common mistake.
  local input="$1"; shift
  # shellcheck disable=SC2069  # the swap is the point: keep stderr, drop stdout
  printf '%b' "$input" | (source "$ROOT/tools/lib/ui.sh"; "$@") 2>&1 >/dev/null
}

# --- the stdout/stderr split ------------------------------------------------

out="$(ui '2\n' ui_menu "Pick" "Choose one" full "Everything" quick "Just photos")"
if [ "$out" = "quick" ]; then pass; else note "ui_menu returned '$out', expected 'quick'"; fi

# Nothing but the tag. This is the check that a prompt-to-stdout bug fails.
if [ "$(printf '%s' "$out" | wc -l)" -eq 0 ] && ! printf '%s' "$out" | grep -q 'Everything'; then
  pass
else
  note "ui_menu put prompt text on stdout: $out"
fi

err="$(ui_err '2\n' ui_menu "Pick" "Choose one" full "Everything" quick "Just photos")"
if printf '%s' "$err" | grep -q 'Everything'; then pass; else note "ui_menu did not draw the menu on stderr"; fi

# --- cancel and EOF ---------------------------------------------------------

if ui_rc 'q\n' ui_menu "Pick" "t" a "A" b "B"; then
  note "ui_menu exited 0 on q (cancel)"
else
  pass
fi

# A closed pipe is a cancel, not a hang and not an accidental selection.
if ui_rc '' ui_menu "Pick" "t" a "A" b "B"; then
  note "ui_menu exited 0 on EOF"
else
  pass
fi

if ui_rc 'q\n' ui_checklist "Pick" "t" a "A" on b "B" off; then
  note "ui_checklist exited 0 on q"
else
  pass
fi

# --- menu input validation --------------------------------------------------

# "1x" must not be read as 1.
out="$(ui '1x\n2\n' ui_menu "Pick" "t" a "A" b "B")"
if [ "$out" = "b" ]; then pass; else note "ui_menu accepted '1x' as a number (got '$out')"; fi

# Rejected by the input guard, not by `[` failing on it. Without the guard the
# outcome is the same and this file cannot tell the difference: `[ 1x -ge 1 ]`
# is already false. What changes is what the user is shown -- bash's
# "integer expression expected" on stderr instead of a sentence. The guard is
# only observable here, so this is the check that holds it in place.
err="$(ui_err '1x\n2\n' ui_menu "Pick" "t" a "A" b "B")"
if printf '%s' "$err" | grep -q 'Enter one of the numbers'; then
  pass
else
  note "ui_menu did not say why '1x' was rejected"
fi
if printf '%s' "$err" | grep -qi 'integer expression'; then
  note "ui_menu let bash report the bad input: $(printf '%s' "$err" | grep -i 'integer expression')"
else
  pass
fi

out="$(ui '9\n1\n' ui_menu "Pick" "t" a "A" b "B")"
if [ "$out" = "a" ]; then pass; else note "ui_menu accepted out-of-range 9 (got '$out')"; fi

# --- checklist --------------------------------------------------------------

# Enter accepts the defaults, one tag per line, in declaration order.
out="$(ui '\n' ui_checklist "Pick" "t" photos "P" on music "M" off docs "D" on)"
if [ "$out" = "$(printf 'photos\ndocs')" ]; then pass; else note "ui_checklist defaults wrong: $(printf '%s' "$out" | tr '\n' ' ')"; fi

out="$(ui '2\n\n' ui_checklist "Pick" "t" photos "P" on music "M" off)"
if [ "$out" = "$(printf 'photos\nmusic')" ]; then pass; else note "toggling 2 on did not work: $(printf '%s' "$out" | tr '\n' ' ')"; fi

out="$(ui '1\n\n' ui_checklist "Pick" "t" photos "P" on music "M" off)"
if [ -z "$out" ]; then pass; else note "toggling 1 off did not work: $out"; fi

out="$(ui 'a\n\n' ui_checklist "Pick" "t" photos "P" off music "M" off)"
if [ "$out" = "$(printf 'photos\nmusic')" ]; then pass; else note "'a' did not select all: $(printf '%s' "$out" | tr '\n' ' ')"; fi

out="$(ui 'n\n\n' ui_checklist "Pick" "t" photos "P" on music "M" on)"
if [ -z "$out" ]; then pass; else note "'n' did not clear the selection: $out"; fi

# Several toggles in one line.
out="$(ui '1 2\n\n' ui_checklist "Pick" "t" a "A" off b "B" off c "C" off)"
if [ "$out" = "$(printf 'a\nb')" ]; then pass; else note "multi-toggle wrong: $(printf '%s' "$out" | tr '\n' ' ')"; fi

# Selecting nothing is a valid answer and exits 0, distinct from cancelling.
if ui_rc 'n\n\n' ui_checklist "Pick" "t" a "A" on; then pass; else note "an empty selection was treated as a cancel"; fi

# --- yes/no -----------------------------------------------------------------

if ui_rc 'y\n' ui_yesno "T" "t" no; then pass; else note "y was not yes"; fi
if ui_rc 'n\n' ui_yesno "T" "t" yes; then note "n was not no"; else pass; fi
if ui_rc '\n'  ui_yesno "T" "t" yes; then pass; else note "Enter did not take the yes default"; fi
if ui_rc '\n'  ui_yesno "T" "t" no; then note "Enter did not take the no default"; else pass; fi
# EOF takes the default rather than looping on a closed pipe.
if ui_rc ''    ui_yesno "T" "t" yes; then pass; else note "EOF did not take the yes default"; fi
if ui_rc ''    ui_yesno "T" "t" no; then note "EOF did not take the no default"; else pass; fi
# A junk answer re-asks rather than being read as either.
if ui_rc 'maybe\nn\n' ui_yesno "T" "t" yes; then note "'maybe' was accepted as yes"; else pass; fi

# --- radiolist --------------------------------------------------------------

# Enter takes the default. The destination chooser leans on this.
out="$(ui '\n' ui_radiolist "Where" "t" local "Default place" on custom "Somewhere else" off)"
if [ "$out" = "local" ]; then pass; else note "ui_radiolist default not taken by Enter: '$out'"; fi

out="$(ui '2\n' ui_radiolist "Where" "t" local "Default place" on custom "Somewhere else" off)"
if [ "$out" = "custom" ]; then pass; else note "ui_radiolist choice 2 gave '$out'"; fi

if ui_rc 'q\n' ui_radiolist "Where" "t" local "L" on custom "C" off; then
  note "ui_radiolist exited 0 on q"
else
  pass
fi

# Exactly one tag, never several.
if [ "$(ui '\n' ui_radiolist "Where" "t" a "A" on b "B" off | wc -l)" -eq 1 ]; then
  pass
else
  note "ui_radiolist returned more than one line"
fi

# --- input and password -----------------------------------------------------

out="$(ui '/mnt/drive\n' ui_inputbox "Where" "Destination")"
if [ "$out" = "/mnt/drive" ]; then pass; else note "ui_inputbox returned '$out'"; fi

out="$(ui '\n' ui_inputbox "Where" "Destination" "/default/path")"
if [ "$out" = "/default/path" ]; then pass; else note "ui_inputbox did not use the default: '$out'"; fi

out="$(ui 'hunter2\n' ui_passwordbox "Pass" "Passphrase")"
if [ "$out" = "hunter2" ]; then pass; else note "ui_passwordbox returned '$out'"; fi

# The passphrase must not appear in anything the terminal shows.
err="$(ui_err 'hunter2\n' ui_passwordbox "Pass" "Passphrase")"
if printf '%s' "$err" | grep -q 'hunter2'; then
  note "ui_passwordbox echoed the passphrase to stderr"
else
  pass
fi

# --- the passphrase prompt leaves the caller's traps alone ------------------
#
#     Traps belong to the shell, not to the function that sets one. The prompt
#     turns terminal echo off and needs a trap so a Ctrl-C does not leave it
#     off, and `trap - INT TERM EXIT` on the way out cleared the caller's too.
#     android_backup_dialog.sh restores the phone's stay_on_while_plugged_in
#     through an EXIT trap: losing it leaves the screen permanently awake, and
#     that setting survives a reboot.
#
#     Only reachable with a real terminal, because the trap is installed only
#     when stdin is one. Piped, the branch never runs and this passes without
#     testing anything -- which is how it read as fine the first time.

# script(1) comes in two incompatible flavours and this repository supports
# both platforms: util-linux takes `script -qec CMD /dev/null`, BSD and macOS
# take `script -q /dev/null CMD ARGS` and reject -e outright. Probed rather
# than sniffed from a version string, because the probe is the thing that has
# to work.
pty_bash() {
  if [ "${PTY_FLAVOUR:-}" = "gnu" ]; then
    script -qec "bash -c '$1'" /dev/null
  else
    script -q /dev/null bash -c "$1"
  fi
}

PTY_FLAVOUR=""
if script -qec true /dev/null >/dev/null 2>&1; then
  PTY_FLAVOUR=gnu
elif script -q /dev/null true >/dev/null 2>&1; then
  PTY_FLAVOUR=bsd
fi

if [ -n "$PTY_FLAVOUR" ]; then
  # shellcheck disable=SC2016  # the $( ) inside must expand in the pty's shell
  trap_probe="$(printf 'secret\n' | pty_bash '
    set -u
    source tools/lib/ui.sh
    trap "printf CALLER_EXIT_RAN\\n" EXIT
    [ -t 0 ] || { printf "no-tty\n"; exit 0; }
    ui_passwordbox T t >/dev/null 2>&1
    printf "exit-trap-lines:%s\n" "$(trap -p EXIT | wc -l)"
  ' 2>&1 | tr -d '\r')"

  case "$trap_probe" in
    *no-tty*)
      # A skip, not a failure. script(1) exists but could not allocate a pty --
      # a container with no /dev/ptmx, say. The check has proved nothing, and
      # nothing is not evidence of a bug. A gate that fires on correct input is
      # worse than one that misses, because it gets switched off.
      printf 'ui_fallback: script(1) gave no pty, skipping the terminal trap check\n' >&2 ;;
    *exit-trap-lines:0*)
      note "ui_passwordbox cleared the caller's EXIT trap" ;;
    *exit-trap-lines:1*)
      pass
      case "$trap_probe" in
        *CALLER_EXIT_RAN*) pass ;;
        *) note "the caller's EXIT trap survived but did not run" ;;
      esac
      ;;
    *)
      note "the trap check gave no usable answer: $(printf '%s' "$trap_probe" | tr '\n' ' ')" ;;
  esac
else
  printf 'ui_fallback: no usable script(1), skipping the terminal trap check\n' >&2
fi

# --- an empty list ----------------------------------------------------------
#
#     Not reachable today: open_recovery_apps returns before it prompts when
#     nothing was detected. It is guarded anyway, because the library is what
#     the next caller uses, the text backend otherwise drew an empty list and
#     asked which of no options to pick, and bash before 4.4 -- the bash macOS
#     ships -- errors on "${!arr[@]}" for an empty array under set -u.

out="$(ui '' ui_checklist "Pick" "nothing here")"
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  pass
else
  note "an empty checklist gave rc=$rc out='$out'; wanted 0 and nothing"
fi

if ui_rc '' ui_menu "Pick" "nothing here"; then
  note "an empty menu exited 0, as though something had been chosen"
else
  pass
fi

if ui_rc '' ui_radiolist "Pick" "nothing here"; then
  note "an empty radiolist exited 0, as though something had been chosen"
else
  pass
fi

# It must not have prompted at all.
err="$(ui_err '' ui_checklist "Pick" "nothing here")"
if printf '%s' "$err" | grep -q 'Numbers to toggle'; then
  note "an empty checklist still asked the user to toggle nothing"
else
  pass
fi

# --- the backend is decided once --------------------------------------------
#
#     Resolved per call, the answer followed PATH: a run that gained or lost
#     dialog halfway would draw a curses screen for one question and a text
#     prompt for the next. The memo has to live outside a command substitution
#     or it is discarded with the subshell.

probe_dir="$WORK_UI/withdialog"
mkdir -p "$probe_dir"
printf '#!/bin/sh\nexit 0\n' >"$probe_dir/dialog"
chmod +x "$probe_dir/dialog"
clean_dir="$WORK_UI/nodialog"
mkdir -p "$clean_dir"
ln -sf "$(command -v bash)" "$clean_dir/bash"

# Driven the way the widgets drive it. `$(ui_backend)` cannot be used for this:
# a command substitution is a subshell, so the memo it takes is discarded with
# it and the next call resolves again. That is exactly why ui_is_dialog reads
# the variable instead of the output, and the test has to match.
got="$(unset ANDROID_RESCUE_UI; bash -c "
  set -u
  source '$ROOT/tools/lib/ui.sh'
  PATH='$clean_dir'
  ui_is_dialog && first=dialog || first=text
  PATH='$probe_dir:$clean_dir'
  ui_is_dialog && second=dialog || second=text
  printf '%s,%s\n' \"\$first\" \"\$second\"
")"
if [ "$got" = "text,text" ]; then
  pass
else
  note "the backend changed with PATH mid-run: $got"
fi

# And the other direction, so this is not just "text always wins".
got="$(unset ANDROID_RESCUE_UI; bash -c "
  set -u
  source '$ROOT/tools/lib/ui.sh'
  PATH='$probe_dir:$clean_dir'
  ui_is_dialog && first=dialog || first=text
  PATH='$clean_dir'
  ui_is_dialog && second=dialog || second=text
  printf '%s,%s\n' \"\$first\" \"\$second\"
")"
if [ "$got" = "dialog,dialog" ]; then
  pass
else
  note "the backend did not stay on dialog once chosen: $got"
fi

# --- backend selection ---# --- backend selection ------------------------------------------------------

if [ "$(ANDROID_RESCUE_UI=text bash -c 'source tools/lib/ui.sh; ui_backend')" = "text" ]; then
  pass
else
  note "ANDROID_RESCUE_UI=text was not honoured"
fi

if [ "$(ANDROID_RESCUE_UI=dialog bash -c 'source tools/lib/ui.sh; ui_backend')" = "dialog" ]; then
  pass
else
  note "ANDROID_RESCUE_UI=dialog was not honoured"
fi

# With no override the choice follows whether dialog is installed.
nodialog="$(mktemp -d)"
trap 'rm -rf "$nodialog"' EXIT
got="$(unset ANDROID_RESCUE_UI; bash -c '
  source tools/lib/ui.sh
  command() { if [ "${1:-}" = "-v" ] && [ "${2:-}" = "dialog" ]; then return 1; fi; builtin command "$@"; }
  ui_backend')"
if [ "$got" = "text" ]; then pass; else note "with dialog absent the backend was '$got', not text"; fi

if [ "$failures" -eq 0 ]; then
  printf 'ui_fallback: %s checks passed\n' "$checks"
else
  printf 'ui_fallback: %s of %s checks FAILED\n' "$failures" "$((checks + failures))" >&2
  exit 1
fi
