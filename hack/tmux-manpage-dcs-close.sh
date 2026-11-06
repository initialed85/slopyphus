#!/bin/sh
# A reproducer for tmux 3.6's passthrough-DCS terminator, written so that it can be run without ttyd,
# xterm.js, or any part of slopyphus in the picture. The claim it tests is tmux's alone.
#
# tmux.1 shows the closing of a passthrough DCS as ESC ESC backslash. tmux's own parser does not accept that.
# It matters because a program that follows the documentation does not merely fail to draw an image: with the
# wrapper left open, tmux keeps swallowing pane output, so the image and whatever was printed after it vanish
# from what the attached client is sent. The failure is silent, it looks like the image protocol being broken,
# and the fix is one character of man-page text.
#
# The parser, from tmux 3.6 input.c:
#   input_state_dcs_handler_table: 0x1b -> input_state_dcs_escape, the ESC is consumed rather than stored
#   input_state_dcs_escape_table:  0x5c -> input_dcs_dispatch, back to ground
#                                0x00-0x5b -> input_input (store), back to dcs_handler
#   so ESC ESC stores one literal ESC and the following backslash is then ordinary data: no dispatch.
#   A single ESC followed by backslash is what dispatches, which is why the payload's own escapes are doubled
#   while the wrapper's terminator is single.
#
# Each case creates a tmux session, records the pane's output as tmux receives it (pipe-pane), attaches a real
# client and captures everything that client is sent (script(1)), prints PLAINBEFORE, a wrapped OSC 1337 image,
# and PLAINAFTER, then reports the counts. PLAINAFTER is the load-bearing byte: it separates "the image is
# missing" from "the transport is destroyed".
#
# Measured on tmux 3.6 (Debian, slopyphus agent image) - see the table this script prints.
#
#   IMAGE=<tag> hack/tmux-manpage-dcs-close.sh      # default: slopyphus-terminal-test:local
set -eu

IMAGE=${IMAGE:-slopyphus-terminal-test:local}
DOCKER_HOST=${DOCKER_HOST:-tcp://192.168.1.213:2375}
export DOCKER_HOST

docker run --rm -i --entrypoint bash "$IMAGE" -s <<'INSIDE'
set -u
echo "== tmux under test: $(tmux -V)"
work=$(mktemp -d)

# Only the terminator differs between single.sh and doubled.sh. They are files rather than arguments so that
# nobody has to reason about four levels of shell quoting to read this reproducer.
cat > "$work/single.sh" <<'EMIT'
printf 'PLAINBEFORE\n'; printf '\033Ptmux;\033\033]1337;File=inline=1;size=8;width=1;height=1;preserveAspectRatio=0:AAAA\007\033\\'; printf '\nPLAINAFTER\n'
EMIT
cat > "$work/doubled.sh" <<'EMIT'
printf 'PLAINBEFORE\n'; printf '\033Ptmux;\033\033]1337;File=inline=1;size=8;width=1;height=1;preserveAspectRatio=0:AAAA\007\033\033\\'; printf '\nPLAINAFTER\n'
EMIT
cat > "$work/unwrap.sh" <<'EMIT'
printf 'PLAINBEFORE\n'; printf '\033]1337;File=inline=1;size=8;width=1;height=1;preserveAspectRatio=0:AAAA\007'; printf '\nPLAINAFTER\n'
EMIT

# scenario <case> <emitter> <allow-passthrough> <attach_first:1|0>
# Note the emitter name has no .sh suffix here; a first version of this file appended it twice and every case
# reported zeros for the simple reason that the pane was told to run a file that did not exist.
scenario() {
  name=$1 emit=$2 mode=$3 attach_first=$4
  tmux -L "$name" kill-server >/dev/null 2>&1 || true
  tmux -L "$name" new-session -d -s w bash
  tmux -L "$name" set -g allow-passthrough "$mode"
  rm -f "/tmp/$name.log" "/tmp/$name.pane.bin"
  tmux -L "$name" pipe-pane -t w "cat > /tmp/$name.pane.bin"

  # script(1) must be given /dev/null on stdin: it is started from a script whose own stdin may still carry
  # the remaining lines of this file, and it will happily eat them as terminal input.
  if [ "$attach_first" = 1 ]; then
    TERM=xterm-256color script -q -a "/tmp/$name.log" -c "timeout -s TERM 8 tmux -L $name attach -t w" \
      </dev/null >/dev/null 2>&1 &
    cap=$!
    sleep 2
    tmux -L "$name" send-keys -t w "sh $work/$emit.sh" Enter
    # No pkill: script's own command line contains the attach command, so a pattern kill takes script down
    # with it and the capture is closed before it holds anything. Let the timeout expire instead.
    wait "$cap" >/dev/null 2>&1 || true
  else
    tmux -L "$name" send-keys -t w "sh $work/$emit.sh" Enter
    sleep 2
    TERM=xterm-256color script -q -a "/tmp/$name.log" -c "timeout -s TERM 6 tmux -L $name attach -t w" \
      </dev/null >/dev/null 2>&1 &
    cap=$!
    wait "$cap" >/dev/null 2>&1 || true
  fi
  tmux -L "$name" kill-server >/dev/null 2>&1 || true
  sleep 1

  python3 - "$name" <<'PY'
import sys
name = sys.argv[1]
pane = open(f"/tmp/{name}.pane.bin", "rb").read()
client = open(f"/tmp/{name}.log", "rb").read()
image = client.count(b"\x1b]1337")
wrapped = pane.count(b"\x1bPtmux")
before = client.count(b"PLAINBEFORE")
after = client.count(b"PLAINAFTER")
print(f"  {name:24} pane_sent_wrapper={wrapped:<3} client_image={image:<3} "
      f"client_before={before:<3} client_after={after:<3} client_bytes={len(client)}")
PY
}

echo
echo "== what the client is sent, by terminator spelling, by allow-passthrough, by whether anyone was looking"
scenario single-close-on      single  on  1
scenario single-close-all     single  all 1
scenario doubled-close-on     doubled on  1
scenario doubled-close-all    doubled all 1
scenario unwrapped-on         unwrap  on  1
scenario single-close-then-look single all 0
INSIDE
