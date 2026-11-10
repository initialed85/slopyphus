#!/usr/bin/env bash
# Plugin integration layer: turn one wheel report into *queued demand*, not a private animation.
#
# A report buys a signed line count appended to the pane's `state` file. Five reports from one phone swipe
# therefore merge into one animation instead of five animations competing for the pane, and a report the other
# way can cancel outstanding demand - possibly through zero and into the opposite direction - so the pane
# answers the thumb that is moving rather than the thumb that moved a second ago. Total queued demand is
# capped by @smooth-scroll-max-pending, which is the "don't let me overtake the current state" rule: queued
# work stays bounded, so a pane is never left flushing a backlog the rider gave up on.
#
# Coordination:
#   `state` is a ledger of signed line counts. Producers append demand to it under the file's own lock, which
#     they hold for the instant an append takes; the animator sums it, moves the lines in its own count, and
#     writes the balance back. A report is never delayed by an animation in progress - only by a microsecond.
#   `.lock` names the animator, not the demand: held EXCLUSIVE for the animator's whole life, claimed by a
#     producer's single `flock -n`, which is both the busy test and the spawn claim in one atomic act. It
#     releases itself if the animator is killed, so nothing can leave a pane permanently un-animated.

source "$(dirname "$0")/config.sh"

DIRECTION=$1
SCROLL_TYPE=$2

TARGET_PANE="${TMUX_PANE:-}"
TARGET_ARG=()
[ -n "$TARGET_PANE" ] && TARGET_ARG=(-t "$TARGET_PANE")

# Pane height is only wanted for the page-sized scroll types; asking for it on every report was a tmux round
# trip spent on a number most reports never use.
case "$SCROLL_TYPE" in
    halfpage) LINES="$(config__halfpage_lines "$(tmux display-message "${TARGET_ARG[@]}" -p '#{pane_height}')")" ;;
    fullpage) LINES="$(config__fullpage_lines "$(tmux display-message "${TARGET_ARG[@]}" -p '#{pane_height}')")" ;;
    normal)   LINES="$(config__normal_lines)" ;;
    small)    LINES=1 ;;
    *)        LINES="$SCROLL_TYPE" ;;
esac
case "$LINES" in ''|*[!0-9]*) exit 0 ;; esac
[ "$LINES" -gt 0 ] || exit 0
DELTA=$LINES
[ "$DIRECTION" = "down" ] && DELTA=$((-LINES))

DIR="$(config__pane_dir "$TARGET_PANE")"
STATE="$DIR/state"
mkdir -p "$DIR" 2>/dev/null

# File the demand. Both sides touch the ledger under its own lock: the animator rewrites it as it drains, so a
# bare O_APPEND could otherwise be truncated away between that rewrite's read and its write. The animator holds
# the lock for microseconds rather than for the length of a pass, and the timeout is only a refusal to be held
# hostage by something wedged - the demand is appended either way.
( flock -w 200 9; printf '%s\n' "$DELTA" >> "$STATE" ) 9<>"$STATE"
if [ -n "${TSS_DEBUG:-}" ]; then
    printf 'fire dir=%s lines=%s pane=%s size=%s\n' "$DIRECTION" "$LINES" "$TARGET_PANE" "$(wc -c < "$STATE")" >> "$TSS_DEBUG"
fi

# Hand the report to the animator and let *it* decide whether it becomes the runner: the claim is one
# non-blocking `flock` inside animator.pl, so there is no gap between testing and taking that a second report
# could slip into. A redundant report pays only a fork and an exit - its demand is already filed, which is the
# whole point of filing it before any of this.
exec "$SRC_DIR/animate.sh" "$DIRECTION" "$LINES" "$(config__base_delay_us)" \
     "$(config__easing_mode)" "$TARGET_PANE" "$STATE" "$DIR/.lock" "$(config__max_pending)"
