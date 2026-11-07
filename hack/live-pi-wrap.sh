#!/usr/bin/env bash
# Live measurement of the anchor: a Pi-shaped image burst through the relay into a scratch tmux pane, and the
# pane's grid read back after each kind of repaint.
#
# Why this exists. `capture-pane -p -e` on a pane that has just drawn an inline image reports no copy of it: the
# picture was bytes travelling through the pane to whoever was looking, never a thing the pane kept. So every
# repaint is destructive - `WheelUpPane -> copy-mode -e` reprints a history slice, a resize reprints the pane,
# MouseDown3Pane's display-menu draws over it, a reattach reprints for the new client - and the only way a
# picture comes back is the application emitting the bytes again. The row reservation survives all of it because
# it is ordinary text. The proposed anchor is a text line naming a saved picture, and this script is how
# "survives" is measured rather than asserted: the real relay, in a pty of a known size, fed the bytes Pi
# itself prints, with the grid read back after each repaint.
#
# Run: hack/live-pi-wrap.sh
#      OSC_WRAP_ANCHOR=on hack/live-pi-wrap.sh     (the anchor is off by default until the browser reads it)
# Needs node (for the Pi byte reference), python3, tmux, and the fixture from hack/make-test-image.py.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOCKET=live-$$
SESSION=pi-live
TEST_IMAGE=${TEST_IMAGE:-/tmp/image-test/flag.png}
ANCHOR=${OSC_WRAP_ANCHOR:-off}
WORK=$(mktemp -d /tmp/live-wrap-XXXX)
PAYLOAD=$WORK/payload.bin
OUTER=$WORK/outer-bytes.bin

[ -r "$TEST_IMAGE" ] || { echo "no $TEST_IMAGE; run hack/make-test-image.py first" >&2; exit 2; }
node "$REPO/hack/pi-image-bytes.mjs" "$TEST_IMAGE" > "$PAYLOAD"
echo "payload: $(wc -c < "$PAYLOAD") bytes, the sequence Pi prints for $TEST_IMAGE"
echo "anchor: $ANCHOR (the relay's own default is off)"

# The relay runs *inside* the pane, wrapping the program that prints the image, which is where it runs in
# production. Putting it outside tmux instead - relaying the client rather than the application - produces nothing
# worth measuring: a pane's OSC 1337 reaches the tmux server unparsed and tmux has no handling for 1337 at all, so
# it is discarded before any client sees it. The relay's whole purpose is to turn it into a DCS tmux will carry.
tmux -L "$SOCKET" new-session -d -s "$SESSION" -c "$PWD" -x 160 -y 52 \
  "$REPO/tools/tmux-osc-wrap.py" --force bash
python3 "$REPO/hack/pty-drive.py" --cols 160 --rows 52 --seconds 30 --log "$OUTER" -- \
  tmux -L "$SOCKET" attach -t "$SESSION" &
driver=$!
sleep 2

grid() {
  echo "--- $1"
  tmux -L "$SOCKET" capture-pane -p -t "$SESSION" | grep -n '' | tail -16
  echo "    anchor lines in the pane's grid: $(tmux -L "$SOCKET" capture-pane -p -t "$SESSION" | grep -c 'img:' || true)"
}

gap_before() {
  # Blank rows immediately above the first line matching a pattern. The reservation is only visible in the grid
  # when something is printed after it: capture-pane drops trailing blank lines, and a picture at the bottom of a
  # pane reserves rows that are all trailing.
  tmux -L "$SOCKET" capture-pane -p -t "$SESSION" | awk -v pat="$1" '
    $0 ~ pat { print "    blank rows directly above /" pat "/: " b; exit }
    /^[[:space:]]*$/ { b++; next }
    { b = 0 }'
}

tmux -L "$SOCKET" send-keys -t "$SESSION" "cat $PAYLOAD; echo RESERVATION_END" Enter
sleep 2
grid "after the burst"
gap_before '^RESERVATION_END$'
gap_before 'img:'
echo "    rows the relay thinks this image covers: $(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("osc_wrap", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.reserve_rows(open(sys.argv[2], "rb").read(), 160, 52))' "$REPO/tools/tmux-osc-wrap.py" "$PAYLOAD")"
echo "    OSC 1337 introducers in what the client received: $(grep -ac '1337' "$OUTER" || true) (tmux unwraps the DCS: the wrapper is for tmux's input side, a client still sees the original sequence)"
echo "    anchor lines in what the client received: $(grep -ac 'img:' "$OUTER" || true)"
echo "    saved pictures under $PWD/.slopyphus/images: $(ls .slopyphus/images 2>/dev/null | wc -l)"

tmux -L "$SOCKET" copy-mode -e -t "$SESSION"
tmux -L "$SOCKET" copy-mode -q -t "$SESSION"
grid "after a wheel-up into copy-mode and back"

tmux -L "$SOCKET" resize-pane -t "$SESSION" -x 90
grid "after narrowing the pane to 90 columns"

tmux -L "$SOCKET" resize-pane -t "$SESSION" -x 160
grid "after widening it back to 160"

tmux -L "$SOCKET" capture-pane -p -e -t "$SESSION" | grep -c '1337' || echo "    copies of the image bytes in the pane's history: 0"

kill "$driver" 2>/dev/null || true
tmux -L "$SOCKET" kill-server 2>/dev/null || true
echo "client-side bytes kept at $OUTER"
