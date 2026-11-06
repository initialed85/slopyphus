#!/bin/sh
# What bytes does a pane actually put on ttyd's websocket when a program prints an image sequence?
#
# The browser measurement (hack/image-cases.sh) answers "did a picture appear". It cannot answer "who ate
# it", because there are two independent ways to end up with a blank screen: the sequence never reached
# xterm.js, or it reached xterm.js and xterm.js refused it. Those have different fixes and different owners,
# so the byte stream has to be looked at directly.
#
# ttyd forwards everything the pane's pty produces to every websocket client, so a second client attached
# before the print sees exactly the bytes the browser sees. That is the whole trick: listen first, print
# second, then search the recorded stream for the protocol markers.
#
# Reported for each case: whether the OSC 1337 header survived, whether a sixel DCS survived, whether tmux's
# passthrough wrapper is still present, and whether doubled escapes were un-doubled on the way out. The
# last one is the tell for tmux: if the wrapper arrives with ESC ESC still in it, tmux never recognised it,
# and xterm.js then sees a malformed sequence rather than an image.
#
# Usage: hack/pane-byte-cases.sh [image tag] [case ...]
#   WITH_BROWSER=1 also opens the same pane in the shared Chromium and reports painted pixels alongside the
#   bytes, because the two views disagreed once and a tool that can only see one of them could not tell
#   which one was lying.
set -eu

IMAGE=${1:-slopyphus-terminal-test:local}
if [ $# -ge 1 ]; then shift; fi
CASES=${*:-"iterm iterm-mux pi-iterm pi-iterm-mux pi-iterm-st pi-iterm-stmux sixel"}

DOCKER_HOST=${DOCKER_HOST:-tcp://192.168.1.213:2375}
export DOCKER_HOST
BASE_PORT=${BASE_PORT:-38300}
WORK=/tmp/pane-bytes
mkdir -p "$WORK"

[ -n "$(docker images -q "$IMAGE" 2>/dev/null)" ] || {
  echo "image $IMAGE not found; build it first" >&2
  exit 2
}
[ -f "/tmp/image-cases/case-iterm.sh" ] || {
  # The case bodies are the same ones hack/image-cases.sh builds, generated here too rather than read from
  # it, so that this file can be run on its own without inventing a shared library for four cases.
  echo "run hack/image-cases.sh first (it writes the case scripts to /tmp/image-cases)" >&2
  exit 2
}
CASEDIR=/tmp/image-cases

listen_case() {
  variant=$1
  name=$2
  port=$((BASE_PORT + case_index))
  container="bytes-$variant-$name"

  docker rm -f "$container" >/dev/null 2>&1 || true
  if [ "$variant" = bare ]; then
    docker run -d --name "$container" --label managed-by=slopyphus-testbed \
      -p "0.0.0.0:$port:7681" --entrypoint /usr/bin/ttyd "$IMAGE" \
      -p 7681 -b /pane -w /workspace -W -t enableSixel=true \
      bash -c 'until [ -f /tmp/go ]; do sleep 0.3; done; sleep 8; sh /tmp/case.sh; sleep 30' >/dev/null
  else
    docker run -d --name "$container" --label managed-by=slopyphus-testbed \
      -p "0.0.0.0:$port:7681" --entrypoint /usr/bin/ttyd "$IMAGE" \
      -p 7681 -b /pane -w /workspace -W -t enableSixel=true \
      bash -c 'until [ -f /tmp/go ]; do sleep 0.3; done; tmux new-session -d -s pane "sleep 4; sh /tmp/case.sh; sleep 30"; exec tmux attach -t pane' >/dev/null
  fi
  sleep 1
  docker cp "$CASEDIR/case-$name.sh" "$container:/tmp/case.sh" >/dev/null
  for payload in "$CASEDIR"/payload-*.bin; do
    docker cp "$payload" "$container:/tmp/" >/dev/null
  done
  docker cp hack/ttyd-ws-probe.mjs "$container:/tmp/probe.mjs" >/dev/null

  browser_pid=""
  if [ "${WITH_BROWSER:-0}" = 1 ]; then
    ( hack/front-testbed.sh cdp --url "http://192.168.1.213:$port/pane/" --wait-ms 9000 \
        --expression-file /tmp/image-cases/dom.js --shot "$WORK/$variant-$name.png" \
        >"$WORK/$variant-$name.browser.json" 2>&1 ) &
    browser_pid=$!
  fi

  # A listener with nothing to send: it only records what the pane emits. It is attached and confirmed
  # before /tmp/go exists, so the print cannot happen first.
  docker exec "$container" bash -c '
    . /root/.nvm/nvm.sh >/dev/null 2>&1 || exit 90
    node /tmp/probe.mjs --url ws://127.0.0.1:7681/pane --collect-ms 17000 --raw > /tmp/probe.json 2>&1 &
    sleep 1.2
    touch /tmp/go
    wait
  ' >/dev/null 2>&1 || { echo "   listener failed"; return; }

  docker cp "$container:/tmp/probe.json" "$WORK/$variant-$name.json" >/dev/null
  docker rm -f "$container" >/dev/null 2>&1 || true
  if [ -n "$browser_pid" ]; then
    wait "$browser_pid"
    painted=$(grep -o '"paintedPixels": *[0-9]*' "$WORK/$variant-$name.browser.json" | grep -o '[0-9]*' | sort -rn | head -1)
    box=$(grep -o '"box": *{[^}]*}' "$WORK/$variant-$name.browser.json" | head -1)
    echo "   browser saw painted=${painted:-0} ${box:-no image layer}"
  fi

  node - "$WORK/$variant-$name.json" <<'EOS'
const fs = require('node:fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const bytes = Buffer.from(report.received ?? '', 'utf8');
const text = report.received ?? '';
const has = (needle, label) => console.log(`   ${label}: ${text.includes(needle) ? 'yes' : 'no'}`);
has('CASE-RAN-MARKER', 'the case script actually ran');
console.log(`   pane emitted ${report.receivedBytes ?? 0} bytes`);
has('\x1b]1337;File=', 'OSC 1337 header survived');
has('\x1b\x1b]1337;', 'OSC 1337 arriving doubled (wrapper not recognised)');
has('\x1bPtmux;', 'tmux passthrough DCS still present');
has('\x1bP0;q', 'sixel DCS with its parameter introducer');
has('\x1bP0;', 'sixel DCS survived');
has('q\x1b\\', 'sixel ST terminator');
const sixel = text.match(/\x1bP[^\x1b]{0,40}q/);
console.log(`   sixel parameter text: ${sixel ? JSON.stringify(sixel[0]) : 'none'}`);
const osc = text.match(/\x1b\]1337;[^:]{0,120}/);
console.log(`   iTerm header as seen: ${osc ? JSON.stringify(osc[0]) : 'none'}`);
// An OSC that arrives but is never terminated is not an image: xterm.js keeps swallowing bytes looking for a
// terminator, which is how a sequence can be present and still paint nothing.
const start = text.indexOf('\x1b]1337;');
if (start >= 0) {
  const body = text.slice(start);
  const bel = body.indexOf('\x07');
  const st = body.indexOf('\x1b\\');
  const end = bel >= 0 && (st < 0 || bel < st) ? { what: 'BEL', at: bel } : { what: 'ST', at: st };
  console.log(`   OSC terminated by: ${end.at >= 0 ? `${end.what} after ${end.at} bytes` : 'nothing'}`);
  if (end.at >= 0) {
    console.log(`   bytes right after it: ${JSON.stringify(body.slice(end.at + 1, end.at + 30).replace(/[^\x20-\x7e]/g, '.'))}`);
  }
}
EOS
}

case_index=0
echo "== bytes a pane actually emits ($IMAGE)"
for name in $CASES; do
  for variant in bare tmux; do
    printf '== %s through %s\n' "$name" "$variant"
    listen_case "$variant" "$name"
    case_index=$((case_index + 1))
  done
done
