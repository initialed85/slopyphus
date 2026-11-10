#!/usr/bin/env bash
# Centralized settings

SRC_DIR="$(dirname "$0")"

# Where a pane's queued scroll demand lives. Per pane, because scrolling is per pane: two panes scrolled at
# once must not queue into each other. Under a directory we create, keyed by the pane's own id.
config__pane_dir() {
    local pane="${1:-active}"
    pane="${pane#%}"                      # %12 -> 12, so the directory name is a plain token
    echo "${TMPDIR:-/tmp}/tmux-smooth-scroll/${pane:-active}"
}

# One tmux round trip per report rather than one per setting. A tmux client costs about 6 ms inside a container
# and a single report needs five settings, so asking for them one at a time made one phone flick pay five
# round trips before the pane moved. `-g` dumps the globals once and the plugin's own are picked out of it.
TSS_OPTIONS_LOADED=
TSS_OPTIONS=

config__load_options() {
    [ -n "$TSS_OPTIONS_LOADED" ] && return
    TSS_OPTIONS="$(tmux show-options -g 2>/dev/null | sed -n 's/^@smooth-scroll-\([a-z-]*\) \(.*\)$/\1\t\2/p')"
    TSS_OPTIONS_LOADED=1
}

# Look up one plugin setting by the part of its name after `@smooth-scroll-`; prints nothing when unset.
config__option() {
    config__load_options
    printf '%s\n' "$TSS_OPTIONS" | awk -F '\t' -v key="$1" '$1 == key { print $2; exit }'
}

# Speed: 0-1000 scale (lower = faster)
config__speed() {
    local speed="$(config__option speed)"
    echo "${speed:-100}"
}

# Base delay per line, in microseconds: 0-100 maps 1000us - 10000us linearly.
config__base_delay_us() {
    echo $((1000 + $(config__speed) * 90))
}

# The cap on queued-but-unexecuted scroll lines. This is the answer to "I overtook the animation and now I am
# stuck while it flushes": reports beyond the cap are simply not banked, so the backlog a pane can be left
# carrying is bounded by a screenful rather than by how fast the thumb was.
config__max_pending() {
    local max="$(config__option max-pending)"
    echo "${max:-30}"
}

# Scroll distances
config__normal_lines() {
    local lines="$(config__option normal)"
    echo "${lines:-3}"
}

config__halfpage_lines() {
    local lines="$(config__option halfpage)"
    local pane_height="${1:-$(tmux display-message -p '#{pane_height}')}"
    echo "${lines:-$((pane_height / 2))}"
}

config__fullpage_lines() {
    local lines="$(config__option fullpage)"
    local pane_height="${1:-$(tmux display-message -p '#{pane_height}')}"
    echo "${lines:-$pane_height}"
}

# Mouse wheel scrolling enabled (default: true)
config__mouse_scroll() {
    local mouse="$(config__option mouse)"
    echo "${mouse:-true}"
}

# Easing mode: linear, sine, quad
config__easing_mode() {
    local mode="$(config__option easing)"
    echo "${mode:-sine}"
}

# Auto-exit copy mode when scrolling past bottom (default: true)
config__exit_copy_mode_at_bottom() {
    local val="$(config__option exit-copy-mode-at-bottom)"
    echo "${val:-true}"
}
