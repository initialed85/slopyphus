#!/bin/sh
# Two questions this answers, and the shape of the trap in each.
#
#   1. Does tmux re-emit a pane's SIXEL image to a client, and does it matter whether the client was attached
#      when the image was printed? Measured answer on tmux 3.6a: the pane hands tmux the sixel in every case
#      (pane_dcs=1) and a client attaching with plain TERM=xterm-256color receives none of it (client_dcs=0),
#      attached first or later, with or without `terminal-features 'xterm-256color:sixel'`. The same case
#      through ttyd visibly paints, so whatever gates re-emission is about the client, not the option.
#   2. Is the sixel code compiled into the tmux we ship? Yes, and the probe for that is easy to get wrong in
#      three distinct ways, all of which happened while writing this file.
#
# Traps, in the order they were discovered:
#
#   - `sixel_support` is a status-line *format variable* (tmux 3.6a format.c:3437, returning "1" only under
#     ENABLE_SIXEL). `tmux show-options -s sixel_support` answers "invalid option" for every build, compiled
#     with sixel or without. The probe is `tmux display -p '#{sixel_support}'`.
#   - A control build made by copying an already-built tree and re-running configure plus make is not a control:
#     make happily relinks the object files that are already there, so you get a binary compiled *with* sixel
#     from a configure run that asked for none. Clean tree, clean objects.
#   - The PNG has to arrive in the container. An early version built the base64 inside the container from a host
#     path, found nothing, wrote an empty file, and then reported zeros about a case that never printed an image.
#     Hence the placeholder below.
#
# Usage (the base64 is substituted here, on the machine that has the PNG):
#   PNG=$(base64 -w0 /tmp/image-test/flag.png)
#   sed "s|__PNG_B64__|$PNG|" hack/sixel-late-client.sh \
#     | docker run --rm -i --entrypoint bash <image> -s
#
# The build control, when one wants the compiled-in question settled directly (deps: build-essential autoconf
# automake pkg-config git curl bison libevent-dev libncurses-dev libprotobuf-c-dev):
#   tar xzf tmux-3.6a.tar.gz && cd tmux-3.6a
#   ./autogen.sh && ./configure            && make -j"$(nproc)" tmux  # expect sixel_support = 0
#   ./autogen.sh && ./configure --enable-sixel && make -j"$(nproc)" tmux  # expect sixel_support = 1
# Or without building anything: strings /usr/bin/tmux | grep -c "SIXEL flag is"  # the string is ifdef-guarded
set -u

cat > /tmp/emit-sixel.sh <<EM
echo '__PNG_B64__' | base64 -d > /tmp/flag.png
ls -l /tmp/flag.png
img2sixel /tmp/flag.png > /tmp/out.bin
wc -c /tmp/out.bin
cat /tmp/out.bin
echo SIXEL-WAS-PRINTED
EM

show() {
  python3 - "$1" <<'PY'
import sys
n = sys.argv[1]
pane = open(f"/tmp/{n}.pane.bin", "rb").read()
client = open(f"/tmp/{n}.log", "rb").read()
dcs = lambda b: b.count(b"\x1bP")
print(f"  {n:26} pane_dcs={dcs(pane):<3} client_dcs={dcs(client):<3} "
      f"pane_bytes={len(pane):<7} client_bytes={len(client):<7} "
      f"printed={client.count(b'SIXEL-WAS-PRINTED')}")
PY
}

run() {
  name=$1 attach_first=$2
  tmux -L "$name" kill-server >/dev/null 2>&1 || true
  tmux -L "$name" new-session -d -s w bash
  rm -f "/tmp/$name.log" "/tmp/$name.pane.bin"
  tmux -L "$name" pipe-pane -t w "cat > /tmp/$name.pane.bin"
  # Read against this case's own server: `tmux display -p` on a server that is not running yet just errors, and
  # a probe that prints "no server" where a number was expected is how the wrong conclusion got written down once.
  echo "  server compiled-in support in this case: #{sixel_support} = $(tmux -L "$name" display -p '#{sixel_support}')"
  # script(1) gets /dev/null on stdin or it swallows the rest of this file as terminal input, and the attach is
  # ended by its own timeout rather than by a pattern kill, which would take script down with it.
  if [ "$attach_first" = 1 ]; then
    TERM=xterm-256color script -q -a "/tmp/$name.log" -c "timeout -s TERM 10 tmux -L $name attach -t w" </dev/null >/dev/null 2>&1 &
    cap=$!; sleep 2
    tmux -L "$name" send-keys -t w "sh /tmp/emit-sixel.sh" Enter
    wait "$cap" >/dev/null 2>&1 || true
  else
    tmux -L "$name" send-keys -t w "sh /tmp/emit-sixel.sh" Enter
    sleep 3
    TERM=xterm-256color script -q -a "/tmp/$name.log" -c "timeout -s TERM 8 tmux -L $name attach -t w" </dev/null >/dev/null 2>&1 &
    cap=$!; wait "$cap" >/dev/null 2>&1 || true
  fi
  tmux -L "$name" kill-server >/dev/null 2>&1 || true
  sleep 1
  show "$name"
}

echo "== tmux $(tmux -V): sixel printed into a pane, client attached first vs attaching afterwards"
echo "== client TERM=xterm-256color (a plain attach, not ttyd's xterm.js), allow-passthrough off"
run attached-first 1
run late-client 0
