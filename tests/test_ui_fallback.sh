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

if command -v script >/dev/null 2>&1; then
  trap_probe="$(printf 'secret\n' | script -qec 'ANDROID_RESCUE_UI=text bash -c "
    set -u
    source tools/lib/ui.sh
    trap \"printf CALLER_EXIT_RAN\\\\n\" EXIT
    [ -t 0 ] || { printf \"no-tty\\n\"; exit 0; }
    ui_passwordbox T t >/dev/null 2>&1
    printf \"exit-trap-lines:%s\\n\" \"\$(trap -p EXIT | wc -l)\"
  "' /dev/null 2>&1 | tr -d '\r')"

  case "$trap_probe" in
    *no-tty*)
      note "the trap check could not get a terminal, so it proved nothing" ;;
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
  printf 'ui_fallback: no script(1), skipping the terminal trap check\n' >&2
fi

# --- backend selection ------------------------------------------------------

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
