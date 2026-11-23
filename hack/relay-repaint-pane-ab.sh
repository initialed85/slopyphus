#!/bin/bash
# Pane-level A/B of one thing: what a TUI's repaint costs when the relay's own CPU is the only variable.
#
# Two throwaway tmux sessions, both running the picture-printing stand-in (hack/anchor-lab-emit.py) with
# --reemit-on-resize, so every resize makes the program reprint the pictures it is holding - which is what a real
# TUI does, and is the case a rewrite in another language was proposed for. Twelve resizes, 250 ms apart, the shape
# of a browser drag. The child stamps the clock before and after its own write, so the reported time is how long a
# 1 MB repaint took to get through the relay into tmux, and nothing else.
#
# Run inside the pod, twice, to compare two relays:
#   RELAY=/usr/local/share/slopyphus/tmux-osc-wrap.py bash hack/relay-repaint-pane-ab.sh
#   RELAY=/workspace/slopyphus/tools/tmux-osc-wrap.py  bash hack/relay-repaint-pane-ab.sh
set -u
RELAY=${RELAY:-/usr/local/share/slopyphus/tmux-osc-wrap.py}
EMIT=${EMIT:-/workspace/slopyphus/hack/anchor-lab-emit.py}
IMAGES=${IMAGES:-12}
RESIZES=${RESIZES:-12}
TAG=${TAG:-ab}
echo "relay under test: $RELAY"

tmux kill-session -t "$TAG-byt" 2>/dev/null
tmux kill-session -t "$TAG-img" 2>/dev/null
rm -f "/tmp/repaint-$TAG-byt.log" "/tmp/repaint-$TAG-img.log"
rm -rf "/tmp/anchorlab/$TAG-byt" "/tmp/anchorlab/$TAG-img"
mkdir -p "/tmp/anchorlab/$TAG-byt" "/tmp/anchorlab/$TAG-img"

tmux new-session -d -s "$TAG-byt" -x 120 -y 60 -c "/tmp/anchorlab/$TAG-byt" -- \
	python3 "$RELAY" python3 "$EMIT" --images "$IMAGES" --text 4 --reemit-on-resize --quiet --repaint-log "/tmp/repaint-$TAG-byt.log"
tmux new-session -d -s "$TAG-img" -x 120 -y 60 -c "/tmp/anchorlab/$TAG-img" -- \
	python3 "$RELAY" --anchor python3 "$EMIT" --images "$IMAGES" --text 4 --reemit-on-resize --quiet --repaint-log "/tmp/repaint-$TAG-img.log"
sleep 2
tmux detach-client -s "$TAG-byt" 2>/dev/null
tmux detach-client -s "$TAG-img" 2>/dev/null

before=$(grep -m1 read_bytes /proc/$(tmux list-panes -t "$TAG-byt" -F '#{pane_pid}')/io 2>/dev/null | awk '{print $2}')
for ((i = 1; i <= RESIZES; i++)); do
	w=$((120 - i * 2)); h=$((60 - i))
	tmux resize-window -t "$TAG-byt:0" -x "$w" -y "$h"
	tmux resize-window -t "$TAG-img:0" -x "$w" -y "$h"
	sleep 0.25
done
tmux resize-window -t "$TAG-byt:0" -x 120 -y 60
tmux resize-window -t "$TAG-img:0" -x 120 -y 60
sleep 2

for side in byt img; do
	pid=$(tmux list-panes -t "$TAG-$side" -F '#{pane_pid}' 2>/dev/null)
	printf '%s  %-4s relay cpu=%s  repaints=%s\n' "$TAG-$side" "$side" "$(ps -o cputime= -p "$pid" 2>/dev/null | tr -d ' ')" "$(wc -l < /tmp/repaint-$TAG-$side.log 2>/dev/null)"
	awk '{n++; t += ($2 - $1); if (($2 - $1) * 1000 > mx) mx = ($2 - $1) * 1000} END {
		if (n == 0) { print "     no repaints recorded"; exit }
		printf "     %d repaints x 1.09 MB = %.1f MB drained, mean %.0f ms per repaint, worst %.0f ms\n", n, n * 1.092072, (t / n) * 1000, mx
	}' "/tmp/repaint-$TAG-$side.log" 2>/dev/null
	awk 'NR<=3 {printf "     repaint %d: %.0f ms (%s)\n", NR, ($2-$1)*1000, $5}' "/tmp/repaint-$TAG-$side.log" 2>/dev/null
done
tmux kill-session -t "$TAG-byt" 2>/dev/null
tmux kill-session -t "$TAG-img" 2>/dev/null
