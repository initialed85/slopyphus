#!/usr/bin/env bash
# Argument gate and launcher for the animator that owns one pane's queue.
#
# The claim on a pane lives in animator.pl, not here: it is one non-blocking `flock` inside the process that
# will actually do the work, so there is no interval between testing for a runner and becoming one. This script
# only refuses nonsense before a fork is wasted - upstream's callers pass a direction and a line count and those
# still have to be sane, even though the demand itself is already filed in the ledger by the time we run.
#
# Only the pane claim is held for the duration of an animation. The demand file is touched in microsecond
# windows, so a report never waits for a scroll in progress; and flock releases the claim if this process is
# killed, so a pane can never be left permanently un-animated.

DIRECTION=$1
LINES=$2
BASE_DELAY_US=$3
EASING_MODE=${4}
TARGET_PANE=${5:-}
STATE=${6:-}
LOCK=${7:-}

MAX_PENDING=${8:-30}

case "$DIRECTION" in up|down) ;; *) exit 1 ;; esac
case "$LINES" in ''|*[!0-9]*) exit 1 ;; esac
case "$BASE_DELAY_US" in ''|*[!0-9]*) exit 1 ;; esac
case "$EASING_MODE" in linear|sine|quad) ;; *) exit 1 ;; esac
case "$MAX_PENDING" in ''|*[!0-9]*) MAX_PENDING=30 ;; esac
[ -n "$STATE" ] || exit 1
[ "$LINES" -ge 1 ] || exit 1
[ "$BASE_DELAY_US" -ge 1 ] || exit 1

exec "$(dirname "$0")/animator.pl" "$BASE_DELAY_US" "$EASING_MODE" "$TARGET_PANE" "$STATE" \
     "$MAX_PENDING" "$LOCK"
