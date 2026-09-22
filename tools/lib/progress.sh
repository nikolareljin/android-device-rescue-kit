#!/usr/bin/env bash
# SCRIPT: lib/progress.sh
# DESCRIPTION: One dialog session for a whole run: phases, counted tasks, notes.
# USAGE: source tools/lib/progress.sh
#
# Copying several thousand photos off a phone takes an hour, and the only
# feedback was one line per 250 files. Worse, the slow work before the copy --
# querying MediaStore, sweeping the filesystem, reading a size for every file --
# printed plain lines and only then handed the terminal to a progress bar, so
# the display changed shape twice in the middle of a rescue.
#
# The session is opened once and stays open:
#
#   progress_session_begin "Photo and video rescue"
#   progress_phase "Discovering photos through MediaStore..." 2
#   progress_task  "Copying" "$total" 25 55      # base 25%, spans 55%
#   progress_step  "DCIM/Camera/IMG_0001.jpg"    # once per item
#   progress_note  "MediaStore: 1532, sweep: 9461"
#   progress_session_end
#
# The gauge is fed through a FIFO rather than a pipe. `loop | dialog --gauge`
# puts the loop in a subshell, so every counter it increments is lost when the
# pipeline ends -- which for the photo backup would silently zero the copied,
# resumed and verified totals the run is judged by.

PROGRESS_ACTIVE=0
PROGRESS_FIFO=""
PROGRESS_PID=""
PROGRESS_TITLE=""
PROGRESS_PHASE=""
PROGRESS_PCT=0
PROGRESS_LAST_DRAWN=-1
PROGRESS_TOTAL=0
PROGRESS_DONE=0
PROGRESS_BASE=0
PROGRESS_SPAN=0
PROGRESS_NOTES=()
# The highest percentage already shown. A bar that goes backwards reads as
# something having gone wrong, which is the last thing to suggest to someone
# about to wipe a phone.
PROGRESS_FLOOR=0
PROGRESS_SINCE_DRAW=0

# ANDROID_RESCUE_PROGRESS: auto (default), never, always.
# "always" exists so the gauge itself can be tested; a harness has no terminal,
# so "auto" would only ever exercise the fallback.
progress_supported() {
    case "${ANDROID_RESCUE_PROGRESS:-auto}" in
        never) return 1 ;;
        always) ;;
        *) [ -t 1 ] || return 1 ;;
    esac
    command -v dialog >/dev/null 2>&1 || return 1
    return 0
}

# Truncate from the left: the tail of a path identifies the file, the head is
# the same /storage/emulated/0/DCIM prefix on every line.
progress_shorten() {
    local text="$1" width="${2:-56}"
    if [ "${#text}" -le "$width" ]; then
        printf '%s' "$text"
        return 0
    fi
    # Below four characters there is no room for the ellipsis, and the negative
    # offset would turn positive: "${text: -$((2 - 3))}" is "${text:1}", which
    # returned a string longer than the width it was asked for.
    if [ "$width" -lt 4 ]; then
        printf '%s' "${text: -width}"
        return 0
    fi
    printf '...%s' "${text: -$((width - 3))}"
}

progress_draw() {
    local detail="${1:-}"
    [ "$PROGRESS_ACTIVE" -eq 1 ] || return 0
    printf 'XXX\n%s\n%s\n\n%s\nXXX\n' \
        "$PROGRESS_PCT" \
        "$PROGRESS_PHASE" \
        "$(progress_shorten "$detail")" >&9 2>/dev/null || progress_session_end
}

progress_session_begin() {
    PROGRESS_TITLE="$1"
    PROGRESS_PCT=0
    PROGRESS_LAST_DRAWN=-1
    PROGRESS_ACTIVE=0
    PROGRESS_NOTES=()
    PROGRESS_FLOOR=0
    PROGRESS_SINCE_DRAW=0

    progress_supported || return 0

    PROGRESS_FIFO="$(mktemp -u)"
    if ! mkfifo "$PROGRESS_FIFO" 2>/dev/null; then
        PROGRESS_FIFO=""
        return 0
    fi

    dialog --title "$PROGRESS_TITLE" \
        --gauge "Starting..." 11 "${DIALOG_WIDTH:-70}" 0 <"$PROGRESS_FIFO" &
    PROGRESS_PID=$!
    # Opening for write blocks until the reader is up, which keeps the first
    # updates from being written into a pipe nobody is reading yet.
    exec 9>"$PROGRESS_FIFO"
    PROGRESS_ACTIVE=1
}

# A step of the run with no count of its own: a query, a sweep, a merge.
progress_phase() {
    PROGRESS_PHASE="$1"
    PROGRESS_TOTAL=0
    if [ -n "${2:-}" ]; then
        PROGRESS_PCT="$2"
        [ "$PROGRESS_PCT" -lt "$PROGRESS_FLOOR" ] && PROGRESS_PCT="$PROGRESS_FLOOR"
        PROGRESS_FLOOR="$PROGRESS_PCT"
    fi
    if [ "$PROGRESS_ACTIVE" -eq 1 ]; then
        progress_draw ""
    else
        print_info "$PROGRESS_PHASE"
    fi
}

# A step of the run that can be counted. base and span place it on the session
# bar, so the bar only ever moves forwards across the whole run.
progress_task() {
    local base="${3:-0}" span="${4:-100}"
    PROGRESS_PHASE="$1"
    PROGRESS_TOTAL="${2:-0}"
    # A task can be re-entered behind where the bar already is: the verification
    # pass runs once, then again after every retry round, and its band sits
    # below the retry band. Left alone the bar jumped 99 -> 75 on each round.
    # The band is moved up to meet the bar and shrinks to whatever is left.
    if [ "$base" -lt "$PROGRESS_FLOOR" ]; then
        span=$((base + span - PROGRESS_FLOOR))
        [ "$span" -lt 0 ] && span=0
        base="$PROGRESS_FLOOR"
    fi
    PROGRESS_BASE="$base"
    PROGRESS_SPAN="$span"
    PROGRESS_DONE=0
    PROGRESS_PCT="$PROGRESS_BASE"
    PROGRESS_LAST_DRAWN=-1
    PROGRESS_SINCE_DRAW=0
    if [ "$PROGRESS_ACTIVE" -eq 1 ]; then
        progress_draw ""
    else
        print_info "$PROGRESS_PHASE ($PROGRESS_TOTAL items)..."
    fi
}

progress_active() { [ "$PROGRESS_ACTIVE" -eq 1 ]; }

# A stretch of the bar handed to one unit of work, when that work reports its
# own percentage rather than a count: an adb pull of a whole directory, say.
progress_band() {
    local base="${2:-0}" span="${3:-100}"
    PROGRESS_PHASE="$1"
    PROGRESS_TOTAL=0
    if [ "$base" -lt "$PROGRESS_FLOOR" ]; then
        span=$((base + span - PROGRESS_FLOOR))
        [ "$span" -lt 0 ] && span=0
        base="$PROGRESS_FLOOR"
    fi
    PROGRESS_BASE="$base"
    PROGRESS_SPAN="$span"
    PROGRESS_PCT="$base"
    PROGRESS_LAST_DRAWN=-1
    if [ "$PROGRESS_ACTIVE" -eq 1 ]; then
        progress_draw ""
    else
        print_info "$PROGRESS_PHASE"
    fi
}

# Progress reported by the work itself, 0-100, mapped into the current band.
# Callable from a subshell: it only draws. The percentage it sets does not
# survive back to the caller, which is why bands are laid out in advance.
progress_within() {
    local pct="$1" detail="${2:-}"
    [ "$PROGRESS_ACTIVE" -eq 1 ] || return 0
    PROGRESS_PCT=$((PROGRESS_BASE + pct * PROGRESS_SPAN / 100))
    [ "$PROGRESS_PCT" -gt 100 ] && PROGRESS_PCT=100
    [ "$PROGRESS_PCT" -lt "$PROGRESS_FLOOR" ] && PROGRESS_PCT="$PROGRESS_FLOOR"
    if [ "$PROGRESS_PCT" -ne "$PROGRESS_LAST_DRAWN" ]; then
        PROGRESS_LAST_DRAWN="$PROGRESS_PCT"
        progress_draw "$detail"
    fi
}

progress_step() {
    local detail="${1:-}"
    PROGRESS_DONE=$((PROGRESS_DONE + 1))
    if [ "$PROGRESS_TOTAL" -gt 0 ]; then
        PROGRESS_PCT=$((PROGRESS_BASE + PROGRESS_DONE * PROGRESS_SPAN / PROGRESS_TOTAL))
        # A task can overrun the total it declared -- the retry round counts the
        # lines of a file that the round itself rewrites. Unclamped this walked
        # past 100 (102, 116, 130) and dialog was asked to draw it.
        [ "$PROGRESS_PCT" -gt $((PROGRESS_BASE + PROGRESS_SPAN)) ] \
            && PROGRESS_PCT=$((PROGRESS_BASE + PROGRESS_SPAN))
        [ "$PROGRESS_PCT" -gt 100 ] && PROGRESS_PCT=100
        [ "$PROGRESS_PCT" -lt "$PROGRESS_FLOOR" ] && PROGRESS_PCT="$PROGRESS_FLOOR"
        PROGRESS_FLOOR="$PROGRESS_PCT"
    fi

    if [ "$PROGRESS_ACTIVE" -eq 1 ]; then
        # Redrawing for every file of several thousand is wasted work and makes
        # the bar flicker; the percentage only ever has a hundred values. But a
        # band squeezed to nothing never changes percentage, and a bar frozen on
        # one file for minutes looks hung, so the detail line still moves.
        PROGRESS_SINCE_DRAW=$((PROGRESS_SINCE_DRAW + 1))
        if [ "$PROGRESS_PCT" -ne "$PROGRESS_LAST_DRAWN" ] || [ "$PROGRESS_SINCE_DRAW" -ge 25 ]; then
            PROGRESS_LAST_DRAWN="$PROGRESS_PCT"
            PROGRESS_SINCE_DRAW=0
            progress_draw "$PROGRESS_DONE of $PROGRESS_TOTAL   $detail"
        fi
        return 0
    fi

    if [ "$PROGRESS_TOTAL" -gt 0 ] && [ $((PROGRESS_DONE % 250)) -eq 0 ]; then
        print_info "  $PROGRESS_DONE / $PROGRESS_TOTAL"
    fi
}

# Something the operator must still see once the bar is gone. Printing it now
# would tear the gauge, so it is shown inside it and repeated afterwards.
progress_note() {
    local text="$1"
    if [ "$PROGRESS_ACTIVE" -eq 1 ]; then
        PROGRESS_NOTES+=("$text")
        progress_draw "$text"
    else
        print_info "$text"
    fi
}

progress_warn() {
    local text="$1"
    if [ "$PROGRESS_ACTIVE" -eq 1 ]; then
        PROGRESS_NOTES+=("! $text")
        progress_draw "$text"
    else
        print_warning "$text"
    fi
}

progress_session_end() {
    local note
    if [ "$PROGRESS_ACTIVE" -eq 1 ]; then
        PROGRESS_ACTIVE=0
        exec 9>&-
        [ -n "$PROGRESS_PID" ] && wait "$PROGRESS_PID" 2>/dev/null
        # Everything held back while the gauge owned the terminal. Without this
        # the counts and any warning would exist only in the manifest.
        for note in ${PROGRESS_NOTES+"${PROGRESS_NOTES[@]}"}; do
            case "$note" in
                '! '*) print_warning "${note#! }" ;;
                *) print_info "$note" ;;
            esac
        done
    fi
    PROGRESS_NOTES=()
    [ -n "$PROGRESS_FIFO" ] && rm -f "$PROGRESS_FIFO"
    PROGRESS_FIFO=""
    PROGRESS_PID=""
}
