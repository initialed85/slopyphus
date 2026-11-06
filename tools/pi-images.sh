#!/bin/sh
# Run Pi in a tmux pane so that its inline images reach the screen.
#
# Three separate facts have to be true at once, and this script supplies two of them:
#
#   1. Pi's fullscreen TUI switches its own image output off. beforeTerminalStart in the shipped bundle reads
#      capabilities.images === "iterm2" and calls setCapabilities({...capabilities, images: null}), so a
#      fullscreen Pi session never emits an inline image at all. --tui-mode regular is not an alt-screen UI, so
#      that code does not run and the images come back.
#   2. Pi decides whether a terminal supports images by asking it, and a terminal behind tmux does not answer
#      the way Pi expects, so the detected protocol is none. PI_IMAGE_PROTOCOL names the protocol outright and
#      skips the question. iterm2 is chosen because xterm.js draws iTerm inline images and tmux passes them
#      through untouched when they arrive inside tmux's own passthrough DCS.
#   3. tmux discards a bare OSC 1337 (grep -c 1337 input.c is 0), so the bytes have to arrive wrapped in
#      ESC P tmux ; ... ESC \. tmux-osc-wrap.py does that to a program that is running, which is the only shape
#      available when the program writing the sequences is Pi itself.
#
# Measured, in that order: a regular-mode Pi session reading a PNG emits one OSC 1337 (hack/fixtures), the same
# session under the relay emits ESC P tmux ; ESC ESC ESC ]1337;File=inline=1;size=342;width=60;height=auto:
# iVBORw0KGg..., and wrapped payloads of this shape paint 153965 pixels of the 560x280 test image through tmux
# against 155225 for the same bytes pre-wrapped and 155750 in a pane with no tmux at all.
#
# --tui-mode regular comes first so that a mode given later on the command line wins. That precedence is
# measured rather than assumed: a run with --tui-mode regular --tui-mode fullscreen enters the alternate screen
# (1 x ESC[?1049h, the same as fullscreen alone), while regular alone does not (0).

WRAP=${WRAP:-/usr/local/share/slopyphus/tmux-osc-wrap.py}
[ -n "${TMUX:-}" ] || echo "pi-images: not in a tmux pane, so nothing needs wrapping here" >&2
PI_IMAGE_PROTOCOL=${PI_IMAGE_PROTOCOL:-iterm2}
export PI_IMAGE_PROTOCOL
exec python3 "$WRAP" pi --tui-mode regular "$@"
