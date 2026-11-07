#!/bin/bash
# What a pane's application actually receives for the clipboard keys, measured as bytes on its own stdin.
#
#   hack/keys-case.sh --key ctrl+v --key meta+v --key ctrl+shift+v
#   hack/keys-case.sh --seed-clipboard --key ctrl+v --key-commands paste
#
# The pane runs `stty raw -echo; cat > /tmp/keys.bin`, so whatever arrives is the application's own bytes with
# no line discipline rewriting them on the way in -- the same condition a TUI runs under, and the reason the
# Shift+Enter measurement in vendor/ttyd/html/src/components/terminal/xterm/index.ts insists on raw mode. The
# keys travel through Chrome's real input pipeline (hack/front-cdp.mjs --key), not through an event built in
# JavaScript, which is the only way to see whether the browser intends to paste.
#
# --seed-clipboard puts a known string in the browser's clipboard before the keys are sent, using the same
# scratch-textarea-and-execCommand('copy') trick ttyd itself falls back to when navigator.clipboard is absent
# (a pane served over plain http is not a secure context). Combined with --key-commands paste it asks the
# question the keyboard alone cannot: does the browser's own paste, triggered by the real Ctrl+V key event,
# reach the application.
#
# This script runs on the pod (bash); the container it starts runs busybox ash, so the command handed to docker stays plain sh.

set -eu

PROG=${0##*/}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

export DOCKER_HOST=${DOCKER_HOST:-tcp://192.168.1.213:2375}
IMAGE=${KEYS_IMAGE:-slopyphus-terminal-test:local}
NAME=${KEYS_NAME:-keys-case}
PORT=${KEYS_PORT:-38760}
URL=http://192.168.1.213:$PORT/pane/
# PASTED-* is a word a running shell could never produce by accident, so seeing it in the pane's recorded
# bytes means it arrived as a paste.
SEED=${KEYS_SEED:-PASTED-BY-CTRL-V}

cdp_args=()
seed=""
file_given=""
while [ $# -gt 0 ]; do
  case "$1" in
    --key) cdp_args+=(--key "$2"); shift 2 ;;
    --key-commands) cdp_args+=(--key-commands "$2"); shift 2 ;;
    # A control measurement in the same run: a text paste built in the page and dispatched at xterm's own
    # helper textarea. If this reaches the pane and the keystroke does not, the difference is the browser's
    # decision about the keystroke and nothing else.
    --paste-text) cdp_args+=(--paste-text "$2"); shift 2 ;;
    --paste-file) cdp_args+=(--paste-file "$2"); file_given=yes; shift 2 ;;
    --seed-clipboard) seed=yes; shift ;;
    --keep) KEYS_KEEP=yes; shift ;;
    -h | --help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *) echo "$PROG: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[ -n "$(docker images -q "$IMAGE" 2>/dev/null)" ] || {
  echo "$PROG: image $IMAGE not found; build it first (docker build -t $IMAGE .)" >&2
  exit 2
}

docker rm -f "$NAME" >/dev/null 2>&1 || true

# tmux's server has to be started by the container's own command, not by the shell ttyd spawns for a client:
# attaching to a session that already exists keeps the pane under a pty tmux can see, which is the difference
# between a measurement and a blank screen (measured in hack/image-cases.sh).
docker run -d --name "$NAME" --label managed-by=slopyphus-testbed -p "0.0.0.0:$PORT:7681" \
  --entrypoint /bin/sh "$IMAGE" -c "
tmux new-session -d -s pane 'stty raw -echo; cat > /tmp/keys.bin; sleep 60'
exec /usr/bin/ttyd -p 7681 -b /pane -w /workspace -W -t enableResize=true -t enableSixel=true bash -c 'exec tmux attach -t pane'
" >/dev/null

sleep 3

if [ "$seed" = yes ]; then
  # Focus is what routes a key event, and a headless page has nothing focused; the clipboard seeding rides on
  # the same expression front-cdp evaluates immediately before it dispatches keys.
  cdp_args+=(--focus-expression "(() => {
    const scratch = document.createElement('textarea');
    scratch.value = '$SEED';
    document.body.appendChild(scratch);
    scratch.focus();
    scratch.select();
    const copied = document.execCommand('copy');
    scratch.remove();
    const t = document.querySelector('.xterm-helper-textarea');
    t && t.focus();
    return { copied, focused: !!t };
  })()")
fi

echo "== keys case: $IMAGE at $URL"
printf '   cdp: %s\n' "${cdp_args[*]:-no keys given}"
hack/front-testbed.sh cdp --url "$URL" --wait-ms 3500 "${cdp_args[@]}" \
  | sed -n '1,12p'

sleep 2
echo "== what the pane's application recorded on its own stdin"
if docker exec "$NAME" sh -c 'test -f /tmp/keys.bin' 2>/dev/null; then
  docker exec "$NAME" od -An -tx1z -v /tmp/keys.bin | sed 's/^/   /'
else
  echo "   (no keys.bin: the pane never ran, so this measurement is about nothing)"
fi

# Where a pasted file actually lands. ttyd's upload path answers with the directory it wrote, and the pane's
# own tree is where an agent would find it, so the harness shows it rather than trusting either side.
if [ "$file_given" = yes ]; then
  echo "== files the pane picked up"
  docker exec "$NAME" sh -c 'ls -l /workspace/.slopyphus/uploads 2>/dev/null' | sed 's/^/   /'
fi

if [ "${KEYS_KEEP:-}" = yes ]; then
  echo "== kept: docker exec $NAME cat /tmp/keys.bin ; docker rm -f $NAME"
else
  docker rm -f "$NAME" >/dev/null 2>&1 || true
fi
