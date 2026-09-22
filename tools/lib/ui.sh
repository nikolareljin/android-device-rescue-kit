#!/usr/bin/env bash
# SCRIPT: tools/lib/ui.sh
# DESCRIPTION: Prompts that work with or without dialog.
# USAGE: source tools/lib/ui.sh
#
# dialog is not available everywhere. Git for Windows ships a trimmed MSYS2
# userland with no package manager to install it with, and a minimal Linux
# image often has no curses packages at all. Before this file, restore had no
# path that did not go through dialog, so it could not run there in any form.
#
# The contract is dialog's, deliberately, because every caller was written
# against it:
#
#   - the answer goes to stdout, and nothing else does, so `x=$(ui_menu ...)`
#     captures the choice and not the menu
#   - prompts and errors go to stderr
#   - exit 0 means the user answered, non-zero means they cancelled
#
# Getting the first of those wrong is silent: the menu text ends up in the
# variable and the caller acts on a string that happens to contain the right
# word somewhere.
#
# Answers are read from stdin rather than /dev/tty. None of these tools reads
# data from stdin, it is what makes the fallback testable, and a pipe that
# supplies no answer gets EOF and a cancel rather than a hang. The one place
# that deliberately uses /dev/tty is the typed restore confirmation in
# `adrescue`, which must not be satisfiable by a pipe at all.

# Which backend is in use. Set once, so a run cannot switch halfway.
ui_backend() {
  if [ -n "${ANDROID_RESCUE_UI:-}" ]; then
    printf '%s\n' "$ANDROID_RESCUE_UI"
    return 0
  fi
  if command -v dialog >/dev/null 2>&1; then
    printf 'dialog\n'
  else
    printf 'text\n'
  fi
}

ui_is_dialog() { [ "$(ui_backend)" = "dialog" ]; }

# Replaces check_if_dialog_installed at the top of an interactive tool. There
# is nothing left to refuse: with dialog absent the prompts fall back instead
# of the command stopping, which is the whole point of this file.
ui_init() {
  if ui_is_dialog; then
    dialog_init
  else
    : "${DIALOG_WIDTH:=74}" "${DIALOG_HEIGHT:=24}"
    export DIALOG_WIDTH DIALOG_HEIGHT
  fi
  ui_dims
}

# Dimensions, when dialog is in use. dialog_init exports these; without it the
# fallback below keeps every widget inside a default terminal.
ui_dims() {
  : "${DIALOG_WIDTH:=74}" "${DIALOG_HEIGHT:=24}"
  UI_MSG_HEIGHT=$((DIALOG_HEIGHT < 20 ? DIALOG_HEIGHT : 20))
  UI_MSG_WIDTH=$((DIALOG_WIDTH < 74 ? DIALOG_WIDTH : 74))
  UI_LIST_HEIGHT=$((DIALOG_HEIGHT > 10 ? DIALOG_HEIGHT - 8 : 8))
}

# printf '%b' so that the \n in the existing call sites renders as a newline in
# both backends. They were written for dialog, which interprets them.
ui_say() { printf '%b\n' "$*" >&2; }
ui_rule() { printf '%s\n' "------------------------------------------------------------" >&2; }

ui_header() {
  local title="$1" text="$2"
  ui_rule
  printf '%s\n' "$title" >&2
  ui_rule
  [ -n "$text" ] && ui_say "$text"
}

# ui_msgbox <title> <text>
ui_msgbox() {
  local title="$1" text="$2"
  # UI_NONINTERACTIVE lives here rather than in a wrapper inside each tool.
  # android_backup_dialog.sh had its own ui_yesno that did this and then called
  # the widget; pointing that body at this file made the function call itself,
  # and bash answers unbounded recursion with SIGSEGV rather than an error.
  if [ "${UI_NONINTERACTIVE:-0}" -eq 1 ]; then
    printf '[%s] %s\n' "$title" "$(printf '%b' "$text" | tr '\n' ' ')" >&2
    return 0
  fi
  ui_dims
  if ui_is_dialog; then
    dialog --title "$title" --msgbox "$text" "$UI_MSG_HEIGHT" "$UI_MSG_WIDTH"
    return $?
  fi
  ui_header "$title" "$text"
  printf '\nPress Enter to continue. ' >&2
  # EOF is not an error here: there is nothing to answer.
  read -r _ || true
  return 0
}

# ui_yesno <title> <text> [yes|no]   exit 0 = yes
ui_yesno() {
  local title="$1" text="$2" default="${3:-yes}" reply
  if [ "${UI_NONINTERACTIVE:-0}" -eq 1 ]; then
    [ "$default" = "yes" ]
    return $?
  fi
  ui_dims
  if ui_is_dialog; then
    if [ "$default" = "no" ]; then
      dialog --defaultno --title "$title" --yesno "$text" "$UI_MSG_HEIGHT" "$UI_MSG_WIDTH"
    else
      dialog --title "$title" --yesno "$text" "$UI_MSG_HEIGHT" "$UI_MSG_WIDTH"
    fi
    return $?
  fi
  ui_header "$title" "$text"
  while :; do
    if [ "$default" = "no" ]; then
      printf '\n[y/N] ' >&2
    else
      printf '\n[Y/n] ' >&2
    fi
    # EOF takes the default rather than looping forever on a closed pipe.
    if ! read -r reply; then reply=""; fi
    [ -z "$reply" ] && { [ "$default" = "yes" ]; return $?; }
    case "$reply" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      [Nn]|[Nn][Oo])     return 1 ;;
      *) ui_say "Answer y or n." ;;
    esac
  done
}

# ui_menu <title> <text> <tag> <desc> [<tag> <desc> ...]   -> stdout: tag
ui_menu() {
  local title="$1" text="$2"; shift 2
  local -a tags=() descs=()
  while [ "$#" -ge 2 ]; do
    tags+=("$1"); descs+=("$2"); shift 2
  done
  ui_dims
  if ui_is_dialog; then
    local -a args=()
    local i
    for i in "${!tags[@]}"; do args+=("${tags[$i]}" "${descs[$i]}"); done
    dialog --stdout --title "$title" --menu "$text" \
      "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$UI_LIST_HEIGHT" ${args[@]+"${args[@]}"}
    return $?
  fi

  ui_header "$title" "$text"
  local i
  for i in "${!tags[@]}"; do
    printf '  %2d) %-22s %s\n' "$((i + 1))" "${tags[$i]}" "${descs[$i]}" >&2
  done
  local reply
  while :; do
    printf '\nNumber, or q to cancel: ' >&2
    if ! read -r reply; then return 1; fi
    case "$reply" in
      [Qq]|[Qq][Uu][Ii][Tt]) return 1 ;;
      # A bare number only. "1x" must not be read as 1.
      *[!0-9]*|'') ui_say "Enter one of the numbers above, or q." ; continue ;;
    esac
    if [ "$reply" -ge 1 ] && [ "$reply" -le "${#tags[@]}" ]; then
      printf '%s\n' "${tags[$((reply - 1))]}"
      return 0
    fi
    ui_say "There is no option $reply."
  done
}

# ui_radiolist <title> <text> <tag> <desc> <on|off> [...]   -> stdout: one tag
#
# Same shape as a checklist but exactly one answer, and unlike ui_menu it
# carries a default, which Enter accepts. The destination chooser depends on
# that: the common case is "the default location", and making someone type a
# number for it is how a wrong path gets picked in a hurry.
ui_radiolist() {
  local title="$1" text="$2"; shift 2
  local -a tags=() descs=()
  local default_index=0 i=0
  while [ "$#" -ge 3 ]; do
    tags+=("$1"); descs+=("$2")
    [ "$3" = "on" ] && default_index="$i"
    i=$((i + 1)); shift 3
  done
  ui_dims
  if ui_is_dialog; then
    local -a args=()
    for i in "${!tags[@]}"; do
      if [ "$i" -eq "$default_index" ]; then
        args+=("${tags[$i]}" "${descs[$i]}" on)
      else
        args+=("${tags[$i]}" "${descs[$i]}" off)
      fi
    done
    dialog --stdout --title "$title" --radiolist "$text" \
      "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$UI_LIST_HEIGHT" ${args[@]+"${args[@]}"}
    return $?
  fi

  ui_header "$title" "$text"
  for i in "${!tags[@]}"; do
    if [ "$i" -eq "$default_index" ]; then
      printf '  %2d) (*) %-22s %s\n' "$((i + 1))" "${tags[$i]}" "${descs[$i]}" >&2
    else
      printf '  %2d) ( ) %-22s %s\n' "$((i + 1))" "${tags[$i]}" "${descs[$i]}" >&2
    fi
  done
  local reply
  while :; do
    printf '\nNumber, Enter for %s, q to cancel: ' "${tags[$default_index]}" >&2
    if ! read -r reply; then return 1; fi
    case "$reply" in
      '') printf '%s\n' "${tags[$default_index]}"; return 0 ;;
      [Qq]) return 1 ;;
      *[!0-9]*) ui_say "Enter one of the numbers above, or q." ; continue ;;
    esac
    if [ "$reply" -ge 1 ] && [ "$reply" -le "${#tags[@]}" ]; then
      printf '%s\n' "${tags[$((reply - 1))]}"
      return 0
    fi
    ui_say "There is no option $reply."
  done
}

# ui_checklist <title> <text> <tag> <desc> <on|off> [...]
#   -> stdout: selected tags, one per line (dialog --separate-output)
ui_checklist() {
  local title="$1" text="$2"; shift 2
  local -a tags=() descs=() state=()
  while [ "$#" -ge 3 ]; do
    tags+=("$1"); descs+=("$2"); state+=("$3"); shift 3
  done
  ui_dims
  if ui_is_dialog; then
    local -a args=()
    local i
    for i in "${!tags[@]}"; do
      args+=("${tags[$i]}" "${descs[$i]}" "${state[$i]}")
    done
    dialog --stdout --separate-output --title "$title" --checklist "$text" \
      "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$UI_LIST_HEIGHT" ${args[@]+"${args[@]}"}
    return $?
  fi

  ui_header "$title" "$text"
  local reply i n
  while :; do
    printf '\n' >&2
    for i in "${!tags[@]}"; do
      if [ "${state[$i]}" = "on" ]; then
        printf '  %2d) [x] %-22s %s\n' "$((i + 1))" "${tags[$i]}" "${descs[$i]}" >&2
      else
        printf '  %2d) [ ] %-22s %s\n' "$((i + 1))" "${tags[$i]}" "${descs[$i]}" >&2
      fi
    done
    printf '\nNumbers to toggle (space separated), a for all, n for none,\n' >&2
    printf 'Enter to accept what is ticked, q to cancel: ' >&2
    if ! read -r reply; then return 1; fi

    case "$reply" in
      '')
        for i in "${!tags[@]}"; do
          [ "${state[$i]}" = "on" ] && printf '%s\n' "${tags[$i]}"
        done
        return 0
        ;;
      [Qq]) return 1 ;;
      [Aa]) for i in "${!tags[@]}"; do state[$i]=on; done; continue ;;
      [Nn]) for i in "${!tags[@]}"; do state[$i]=off; done; continue ;;
    esac

    for n in $reply; do
      case "$n" in
        *[!0-9]*|'') ui_say "Not a number: $n"; continue ;;
      esac
      if [ "$n" -lt 1 ] || [ "$n" -gt "${#tags[@]}" ]; then
        ui_say "There is no option $n."
        continue
      fi
      i=$((n - 1))
      if [ "${state[$i]}" = "on" ]; then state[$i]=off; else state[$i]=on; fi
    done
  done
}

# ui_inputbox <title> <text> [default]   -> stdout: the value
ui_inputbox() {
  local title="$1" text="$2" default="${3:-}" reply
  ui_dims
  if ui_is_dialog; then
    dialog --stdout --title "$title" --inputbox "$text" \
      "$UI_MSG_HEIGHT" "$UI_MSG_WIDTH" "$default"
    return $?
  fi
  ui_header "$title" "$text"
  if [ -n "$default" ]; then
    printf '\n[%s] ' "$default" >&2
  else
    printf '\n> ' >&2
  fi
  if ! read -r reply; then return 1; fi
  [ -z "$reply" ] && reply="$default"
  printf '%s\n' "$reply"
  return 0
}

# ui_passwordbox <title> <text>   -> stdout: the value, never echoed
ui_passwordbox() {
  local title="$1" text="$2" reply saved=""
  ui_dims
  if ui_is_dialog; then
    dialog --stdout --title "$title" --passwordbox "$text" \
      "$UI_MSG_HEIGHT" "$UI_MSG_WIDTH"
    return $?
  fi
  ui_header "$title" "$text"
  printf '\n> ' >&2

  # Echo is restored through a trap as well as on the normal path: a Ctrl-C at
  # a passphrase prompt would otherwise leave the terminal with echo off, and
  # the user's next command is invisible as they type it.
  local saved_traps=""
  if [ -t 0 ]; then
    saved="$(stty -g 2>/dev/null || true)"
    if [ -n "$saved" ]; then
      # Traps are the shell's, not this function's. `trap - INT TERM EXIT` on
      # the way out would clear the caller's, and android_backup_dialog.sh
      # restores the phone's stay_on_while_plugged_in setting through an EXIT
      # trap -- clearing it leaves the screen permanently awake, a change to
      # the phone that survives a reboot. So whatever is installed is captured
      # first and put back verbatim.
      saved_traps="$(trap -p INT TERM EXIT)"
      # shellcheck disable=SC2064  # $saved must expand now, not when it fires
      trap "stty '$saved' 2>/dev/null" INT TERM EXIT
      stty -echo 2>/dev/null || true
    fi
  fi
  read -r reply
  local rc=$?
  if [ -n "$saved" ]; then
    stty "$saved" 2>/dev/null || true
    trap - INT TERM EXIT
    # Empty when the caller had none, which is the no-op it looks like.
    [ -n "$saved_traps" ] && eval "$saved_traps"
  fi
  printf '\n' >&2
  [ "$rc" -eq 0 ] || return 1
  printf '%s\n' "$reply"
  return 0
}
