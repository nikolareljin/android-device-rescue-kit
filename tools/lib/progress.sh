#!/usr/bin/env bash
# SCRIPT: lib/progress.sh
# DESCRIPTION: A dialog --gauge progress bar that degrades to plain lines.
# USAGE: source tools/lib/progress.sh
#
# Copying 5,399 photos off a phone takes a long time, and the only feedback was
# one line per 250 files. That is roughly twenty lines over an hour, with no way
# to tell a slow copy from a stalled one.
#
#   progress_begin "Copying photos and videos" 5399
#   progress_step "DCIM/Camera/IMG_0001.jpg"     # once per item
#   progress_end
#
# The gauge is fed through a FIFO rather than a pipe. `loop | dialog --gauge`
# puts the loop in a subshell, so every counter it increments is lost when the
# pipeline ends -- which for the photo backup would silently zero the copied,
# resumed and verified totals that the run is judged by.

PROGRESS_ACTIVE=0
PROGRESS_TOTAL=0
PROGRESS_DONE=0
PROGRESS_LABEL=""
PROGRESS_FIFO=""
PROGRESS_PID=""
PROGRESS_LAST_PCT=-1

# A gauge is only drawn when there is a terminal to draw it on and a dialog to
# draw it with. Unattended runs, pipes and CI keep the plain lines, which are
# also what ends up in a log worth reading afterwards.
# ANDROID_RESCUE_PROGRESS: auto (default), never, always.
# "always" exists so the gauge itself can be tested; a test harness has no
# terminal, so "auto" would only ever exercise the fallback.
progress_supported() {
    case "${ANDROID_RESCUE_PROGRESS:-auto}" in
        never) return 1 ;;
        always) ;;
        *) [ -t 1 ] || return 1 ;;
    esac
    command -v dialog >/dev/null 2>&1 || return 1
    return 0
}

progress_begin() {
    PROGRESS_LABEL="$1"
    PROGRESS_TOTAL="${2:-0}"
    PROGRESS_DONE=0
    PROGRESS_LAST_PCT=-1
    PROGRESS_ACTIVE=0

    [ "$PROGRESS_TOTAL" -gt 0 ] || return 0
    progress_supported || {
        print_info "$PROGRESS_LABEL ($PROGRESS_TOTAL items)..."
        return 0
    }

    PROGRESS_FIFO="$(mktemp -u)"
    if ! mkfifo "$PROGRESS_FIFO" 2>/dev/null; then
        PROGRESS_FIFO=""
        print_info "$PROGRESS_LABEL ($PROGRESS_TOTAL items)..."
        return 0
    fi

    dialog --title "$PROGRESS_LABEL" \
        --gauge "Starting..." 10 "${DIALOG_WIDTH:-70}" 0 <"$PROGRESS_FIFO" &
    PROGRESS_PID=$!
    # Opening for write blocks until the reader is up, which is what keeps the
    # first steps from being written into a pipe nobody is reading yet.
    exec 9>"$PROGRESS_FIFO"
    PROGRESS_ACTIVE=1
}

# Truncate from the left: the tail of a path identifies the file, the head is
# the same /storage/emulated/0/DCIM prefix on every line.
progress_shorten() {
    local text="$1" width="${2:-56}"
    if [ "${#text}" -le "$width" ]; then
        printf '%s' "$text"
    else
        printf '...%s' "${text: -$((width - 3))}"
    fi
}

progress_step() {
    local detail="${1:-}" pct=0
    PROGRESS_DONE=$((PROGRESS_DONE + 1))
    [ "$PROGRESS_TOTAL" -gt 0 ] && pct=$((PROGRESS_DONE * 100 / PROGRESS_TOTAL))

    if [ "$PROGRESS_ACTIVE" -eq 1 ]; then
        # Redrawing on every file of several thousand is wasted work and makes
        # the bar flicker; the percentage only ever has a hundred values.
        if [ "$pct" -ne "$PROGRESS_LAST_PCT" ] || [ -n "$detail" ]; then
            PROGRESS_LAST_PCT="$pct"
            printf 'XXX\n%s\n%s\n%s\nXXX\n' \
                "$pct" \
                "$PROGRESS_DONE of $PROGRESS_TOTAL" \
                "$(progress_shorten "$detail")" >&9 2>/dev/null || progress_end
        fi
        return 0
    fi

    if [ "$PROGRESS_TOTAL" -gt 0 ] && [ $((PROGRESS_DONE % 250)) -eq 0 ]; then
        print_info "  $PROGRESS_DONE / $PROGRESS_TOTAL"
    fi
}

progress_end() {
    if [ "$PROGRESS_ACTIVE" -eq 1 ]; then
        PROGRESS_ACTIVE=0
        exec 9>&-
        [ -n "$PROGRESS_PID" ] && wait "$PROGRESS_PID" 2>/dev/null
    fi
    [ -n "$PROGRESS_FIFO" ] && rm -f "$PROGRESS_FIFO"
    PROGRESS_FIFO=""
    PROGRESS_PID=""
}
