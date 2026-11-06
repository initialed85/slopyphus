#!/bin/sh
# Does an inline image actually appear in a slopyphus pane, and what does tmux do to it on the way out?
#
# The claim this exists to test is the one that sounds obvious: "ttyd loads @xterm/addon-image, therefore
# images work". The addon is only the far end of a chain. A pane's bytes are produced by the program in the
# pane, then interpreted by tmux - which has a text screen model and no notion of graphics - then re-emitted
# by the tmux client into ttyd's pty, then handed to xterm.js. Anything tmux parses and dislikes never
# reaches the addon, so "the addon is loaded" is not evidence of anything.
#
# Ordering is the trap that made the first version of this file report zero for every case. An image is
# painted into xterm's image layer and is NOT part of the text buffer, so a browser that attaches after the
# print gets the current screen and nothing else: it sees a prompt and no image, which looks exactly like
# "the protocol failed" and is not. Every case therefore holds the print back until the browser is attached:
#
#   1. the pane waits for /tmp/go, which does not exist yet
#   2. the browser starts reading
#   3. the case script is copied in and /tmp/go appears; the pane sleeps a little more, then prints
#
# What is measured, and why each case is here:
#
#   iterm           a hand-written OSC 1337 with inline= and size=, the spelling xterm's iTerm handler
#                   accepts. The first version of this file omitted size= and every iTerm case came back
#                   blank, which was the handler refusing the header, not the transport failing.
#   pi-iterm        the bytes Pi itself would put on the wire, extracted from Pi's shipped bundle by
#                   hack/pi-image-bytes.mjs rather than guessed by me. Pi sends width=<columns> and
#                   height=auto, and whether a browser tolerates that is a measurement.
#   pi-iterm-mux    Pi's bytes wrapped in tmux's passthrough DCS, the only spelling that can survive tmux.
#   sixel           img2sixel output, which is a DCS of its own, so tmux sees it before anybody else can.
#   sixel-mux       sixel inside the passthrough wrapper.
#   *-scroll        the image followed by 40 lines of text, because an image that renders and is then erased
#                   by the next screen update is not a usable feature.
#
# The answer is read out of the browser: which canvases exist and which are 2D with painted pixels. ttyd's
# text renderer is WebGL and getContext('2d') on a WebGL canvas is null, so a 2D canvas carrying pixels can
# only be the image layer. A bounding box comes back too, since "rendered" and "rendered in the right place
# at the right size" are different claims. A screenshot accompanies every case because a number that says
# "painted" is not the same as a person seeing the flag.
#
# Usage: hack/image-cases.sh [image tag] [case ...]
set -eu

IMAGE=${1:-slopyphus-terminal-test:local}
if [ $# -ge 1 ]; then shift; fi
CASES=${*:-"plain-text iterm pi-iterm pi-iterm-st wrap-bel wrap-st wrap-st-only wrap-plain wrap-csi"}

DOCKER_HOST=${DOCKER_HOST:-tcp://192.168.1.213:2375}
export DOCKER_HOST
BASE_PORT=${BASE_PORT:-38200}
WORK=/tmp/image-cases
SHOTS=$WORK/shots
TEST_IMAGE=${TEST_IMAGE:-/tmp/image-test/flag.png}
mkdir -p "$SHOTS"

[ -n "$(docker images -q "$IMAGE" 2>/dev/null)" ] || {
  echo "image $IMAGE not found; build it first (docker build -t $IMAGE .)" >&2
  exit 2
}
[ -f "$TEST_IMAGE" ] || { echo "no test image at $TEST_IMAGE" >&2; exit 2; }

# The payloads travel as base64 inside the case scripts rather than as volume mounts: DOCKER_HOST points at
# another machine, so a bind mount would name a path on that machine instead of here.
PNG_B64=$(base64 -w0 "$TEST_IMAGE")
PNG_BYTES=$(wc -c <"$TEST_IMAGE" | tr -d ' ')
SEQ_B64=$(node hack/pi-image-bytes.mjs "$TEST_IMAGE" | base64 -w0)
SEQ_MUX_B64=$(node hack/pi-image-bytes.mjs "$TEST_IMAGE" --wrap-tmux | base64 -w0)
SEQ_ST_B64=$(node hack/pi-image-bytes.mjs "$TEST_IMAGE" --st | base64 -w0)
SEQ_ST_MUX_B64=$(node hack/pi-image-bytes.mjs "$TEST_IMAGE" --st --wrap-tmux | base64 -w0)
# The live shim rather than a pre-wrapped file: the pi-shim case hands the raw Pi sequence to a program running
# under hack/tmux-osc-wrap.py, which is the shape production would have if this works.
SHIM_B64=$(base64 -w0 hack/tmux-osc-wrap.py)

write_case_scripts() {
  # Each script recreates its own input inside the container, so a case is a single file that can be pasted
  # into a pane by hand and looked at with human eyes.
  # The control case: no graphics at all, just a line of text. If this one is not seen, nothing else in the
  # matrix means anything, because the pipeline under test is the one carrying the bytes.
  cat >"$WORK/case-plain-text.sh" <<EOS
echo HELLO-FROM-CASE
echo CASE-RAN-MARKER
EOS

  cat >"$WORK/case-iterm.sh" <<EOS
echo '$PNG_B64' | base64 -d > /tmp/flag.png
printf '\033]1337;File=inline=1;size=$PNG_BYTES;width=200;height=100;preserveAspectRatio=0:%s\007' "\$(base64 -w0 /tmp/flag.png)"
echo CASE-RAN-MARKER
EOS

  cat >"$WORK/case-pi-iterm.sh" <<EOS
echo '$SEQ_B64' | base64 -d > /tmp/pi-seq.bin
cat /tmp/pi-seq.bin
echo CASE-RAN-MARKER
EOS

  cat >"$WORK/case-pi-iterm-mux.sh" <<EOS
echo '$SEQ_MUX_B64' | base64 -d > /tmp/pi-seq.bin
cat /tmp/pi-seq.bin
echo CASE-RAN-MARKER
EOS

  cat >"$WORK/case-pi-iterm-st.sh" <<EOS
echo '$SEQ_ST_B64' | base64 -d > /tmp/pi-seq.bin
cat /tmp/pi-seq.bin
echo CASE-RAN-MARKER
EOS

  cat >"$WORK/case-pi-iterm-stmux.sh" <<EOS
echo '$SEQ_ST_MUX_B64' | base64 -d > /tmp/pi-seq.bin
cat /tmp/pi-seq.bin
echo CASE-RAN-MARKER
EOS

  cat >"$WORK/case-pi-shim.sh" <<EOS
# hack/tmux-osc-wrap.py relaying a program and wrapping OSC 1337 as it goes. It wraps only when TMUX is set, so
# the bare variant of this case is the raw Pi sequence through a relay that decided to do nothing, and the tmux
# variant is the same bytes wrapped. CASE-INNER-MARKER proves the relayed program ran to completion;
# CASE-RAN-MARKER proves the pane carried on after the image, which is what a wrong wrapper terminator destroys.
echo '$SEQ_B64' | base64 -d > /tmp/pi-seq.bin
echo '$SHIM_B64' | base64 -d > /tmp/osc-wrap.py
python3 /tmp/osc-wrap.py sh -c 'printf hello; cat /tmp/pi-seq.bin; echo CASE-INNER-MARKER'
echo CASE-RAN-MARKER
EOS

  cat >"$WORK/case-csi-mux.sh" <<EOS
# A control sequence wrapped the same way, with something visible after it, to separate "tmux forwards
# passthrough at all" from "tmux forwards this particular sequence". If \\e[42m reaches the pane, the
# wrapper spelling is right and the thing tmux objects to is the sequence inside it.
printf '\033Ptmux;\033\033[42mX\033\\'
echo CASE-RAN-MARKER
printf '\033Ptmux;\033\033[0mX\033\\'
echo done
EOS

  cat >"$WORK/case-sixel.sh" <<EOS
echo '$PNG_B64' | base64 -d > /tmp/flag.png
img2sixel /tmp/flag.png
echo CASE-RAN-MARKER
EOS

  cat >"$WORK/case-sixel-mux.sh" <<EOS
echo '$PNG_B64' | base64 -d > /tmp/flag.png
# Inside tmux's passthrough DCS every escape in the payload must be doubled, including the escapes the
# sixel sequence uses for its own parameter introducer and its own terminator.
{ printf '\033Ptmux;\033'; img2sixel /tmp/flag.png | sed 's/\x1b/\x1b\x1b/g'; printf '\033\\'; }
echo CASE-RAN-MARKER
EOS

  cat >"$WORK/case-pi-iterm-scroll.sh" <<EOS
echo '$SEQ_B64' | base64 -d > /tmp/pi-seq.bin
cat /tmp/pi-seq.bin
echo
seq 1 40
EOS

  cat >"$WORK/case-sixel-scroll.sh" <<EOS
echo '$PNG_B64' | base64 -d > /tmp/flag.png
img2sixel /tmp/flag.png
echo
seq 1 40
EOS

  # The wrapper-spelling cases are byte sequences rather than shell, so a node helper writes them. The same
  # helper is used by hack/tmux-passthrough-cases.sh, which is where the spellings were designed.
  python3 hack/make-test-image.py >/dev/null
  node hack/image-sequence-cases.mjs "$WORK" /tmp/image-test/tiny.png >/dev/null
}

# What the browser is asked about. An IIFE, because evaluating a bare "()" is a function expression and CDP
# serialises a function as an empty object, which is how the first version of this reported zero everywhere.
cat >"$WORK/dom.js" <<'EOS'
(() => {
  const canvases = Array.from(document.querySelectorAll('canvas')).map((c) => {
    const info = { className: c.className || '(none)', width: c.width, height: c.height };
    const ctx = c.getContext('2d', { willReadFrequently: true });
    if (!ctx) {
      info.context2d = false;
      return info;
    }
    try {
      const data = ctx.getImageData(0, 0, c.width, c.height).data;
      let painted = 0;
      let red = 0;
      let blue = 0;
      let left = c.width;
      let top = c.height;
      let right = -1;
      let bottom = -1;
      for (let i = 0; i < data.length; i += 4) {
        if (data[i + 3] === 0) continue;
        painted++;
        const x = (i / 4) % c.width;
        const y = Math.floor((i / 4) / c.width);
        if (x < left) left = x;
        if (x > right) right = x;
        if (y < top) top = y;
        if (y > bottom) bottom = y;
        if (data[i] > 150 && data[i + 2] < 100) red++;
        if (data[i + 2] > 150 && data[i] < 100) blue++;
      }
      info.paintedPixels = painted;
      info.red = red;
      info.blue = blue;
      if (painted > 0) {
        info.box = { left, top, right, bottom, w: right - left + 1, h: bottom - top + 1 };
      }
    } catch (e) {
      info.pixelError = String(e);
    }
    return info;
  });
  return {
    canvases,
    // Whether the pane shows a shell at all, so "no image" can be told apart from "no pane".
    text: (document.querySelector('.xterm-rows')?.textContent ?? '').trim().slice(0, 160),
  };
})()
EOS

fails=0
case_index=0
results=$WORK/results.txt
: >"$results"

run_case() {
  variant=$1
  name=$2
  port=$((BASE_PORT + case_index))
  container="image-$variant-$name"

  docker rm -f "$container" >/dev/null 2>&1 || true
  # Both variants wait for /tmp/go before doing anything, which is what makes step 1 above real. The tmux
  # variant sleeps inside the tmux pane so that tmux has attached and painted its screen first.
  if [ "$variant" = bare ]; then
    docker run -d --name "$container" --label managed-by=slopyphus-testbed \
      -p "0.0.0.0:$port:7681" --entrypoint /usr/bin/ttyd "$IMAGE" \
      -p 7681 -b /pane -w /workspace -W -t enableSixel=true \
      bash -c 'until [ -f /tmp/go ]; do sleep 0.3; done; sleep 8; sh /tmp/case.sh; sleep 40' >/dev/null
  else
    # ttyd does not start the pane command until a client attaches, which is the ordering primitive this
    # whole file was missing: attaching the browser is what starts the clock, so a short sleep after that is
    # enough for tmux to attach and finish asking the outer terminal what it supports. The session is created
    # detached and then attached because `new-session -A` silently ignores the command when a session of that
    # name already exists, and ttyd re-runs this command whenever a client reconnects.
    docker run -d --name "$container" --label managed-by=slopyphus-testbed \
      -p "0.0.0.0:$port:7681" --entrypoint /usr/bin/ttyd "$IMAGE" \
      -p 7681 -b /pane -w /workspace -W -t enableSixel=true \
      bash -c 'until [ -f /tmp/go ]; do sleep 0.3; done; tmux new-session -d -s pane "sleep 4; sh /tmp/case.sh; sleep 45"; exec tmux attach -t pane' >/dev/null
  fi
  sleep 1

  # The browser starts reading before the case is released and waits through the pane's own delay. POSIX sh
  # cannot capture the output of a background command, so the CDP run writes to the json file that is read
  # back once it finishes.
  shot="$SHOTS/$variant-$name.png"
  json="$SHOTS/$variant-$name.json"
  ( hack/front-testbed.sh cdp --url "http://192.168.1.213:$port/pane/" --wait-ms 16000 \
      --expression-file "$WORK/dom.js" --shot "$shot" --capture-console >"$json" 2>&1 ) &
  cdp_pid=$!
  sleep 2

  docker cp "$WORK/case-$name.sh" "$container:/tmp/case.sh" >/dev/null
  for payload in "$WORK"/payload-*.bin; do
    docker cp "$payload" "$container:/tmp/" >/dev/null
  done
  docker exec "$container" sh -c 'touch /tmp/go'

  wait "$cdp_pid"
  out=$(cat "$json")

  pick() { printf '%s' "$out" | grep -o "\"$1\": *[0-9]*" | grep -o '[0-9]*' | sort -rn | head -1; }
  painted=$(pick paintedPixels)
  painted=${painted:-0}
  box=$(printf '%s' "$out" | grep -o '"box": *{[^}]*}' | head -1)
  # A tmux case that painted nothing is only evidence if the pane really ran the case, so the pane's own
  # screen is asked. tmux knows what its pane contains even when the outer browser never got it. An image is
  # itself proof the case ran, since nothing else in the container can paint pixels.
  ran=unknown
  if [ "$variant" = tmux ]; then
    if docker exec "$container" tmux capture-pane -p -a -S -60 2>/dev/null | grep -q CASE-RAN-MARKER; then
      ran=capture
    elif [ "${painted:-0}" -ge 100 ]; then
      ran=pixels
    else
      ran=no
    fi
  fi
  line=$(printf '%-18s %-5s painted=%-6s pane-ran=%-7s %s' "$name" "$variant" "$painted" "$ran" "$box")
  echo "   $line"
  echo "$line" >>"$results"
  # plain-text is the control: it is supposed to paint no pixels.
  if [ "$name" != plain-text ] && [ "$painted" -lt 100 ]; then
    fails=$((fails + 1))
  fi
  if [ "$variant" = tmux ] && [ "$ran" = no ]; then
    echo "   the case neither painted nor left a trace in the pane, so this measurement is about nothing"
    fails=$((fails + 1))
  fi
}

echo "== inline image cases against $IMAGE"
write_case_scripts
for name in $CASES; do
  for variant in bare tmux; do
    printf '== %s through %s\n' "$name" "$variant"
    run_case "$variant" "$name"
    case_index=$((case_index + 1))
  done
done

echo
echo "== teardown"
for name in $CASES; do
  for variant in bare tmux; do
    docker rm -f "image-$variant-$name" >/dev/null 2>&1 || true
  done
done

echo
echo "== summary"
echo "   shots and full json in $SHOTS"
cat "$results"
if [ "$fails" = 0 ]; then
  echo "   every case put an image on screen"
else
  echo "   $fails case(s) put nothing on screen"
fi
exit 0
