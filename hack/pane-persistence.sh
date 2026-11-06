#!/usr/bin/env sh
# Does the program in a pane keep running when nobody is looking at it?
#
# Every agent pane in this fleet runs under tmux, and the reason given for that is that Pi has to survive a
# browser closing a tab. Whether ttyd needs that help is a fact about ttyd rather than a matter of taste, and
# it decides whether an image-capable bare pane is possible at all: inline images survive tmux only inside a
# passthrough wrapper (hack/image-cases.sh), while a bare pane renders what Pi prints as-is.
#
# The command in the pane appends one line per second to a file. A websocket client attaches for a while and
# then goes away. Counting the file while no client is attached answers the question directly, and a second
# client attaching later shows whether the same process is still there or a fresh one was started.
#
# Usage: hack/pane-persistence.sh [image tag]
set -eu

IMAGE=${1:-slopyphus-terminal-test:local}
DOCKER_HOST=${DOCKER_HOST:-tcp://192.168.1.213:2375}
export DOCKER_HOST
BASE_PORT=${BASE_PORT:-38500}
WORK=/tmp/pane-persistence
mkdir -p "$WORK"

[ -n "$(docker images -q "$IMAGE" 2>/dev/null)" ] || {
  echo "image $IMAGE not found; build it first (docker build -t $IMAGE .)" >&2
  exit 2
}

# A tick line carries the second and nanosecond so two clients seeing the same counter can be told apart
# from two processes that each started counting at zero. It lives in a file rather than in a nested shell
# string, because the tmux variant has to pass its pane command through two layers of quoting.
TICKER=$WORK/ticker.sh
cat >"$TICKER" <<'EOS'
n=0
while :; do
  n=$((n + 1))
  printf 'tick %s %s\n' "$n" "$(date +%S.%N)" | tee -a /tmp/ticks.log
  sleep 1
done
EOS

docker cp hack/ttyd-ws-probe.mjs /tmp/ttyd-probe-stage.mjs 2>/dev/null || cp hack/ttyd-ws-probe.mjs /tmp/ttyd-probe-stage.mjs

run_variant() {
  variant=$1
  port=$((BASE_PORT + case_index))
  container="persist-$variant"

  docker rm -f "$container" >/dev/null 2>&1 || true
  case "$variant" in
    bare)
      docker run -d --name "$container" --label managed-by=slopyphus-testbed \
        -p "0.0.0.0:$port:7681" --entrypoint /usr/bin/ttyd "$IMAGE" \
        -p 7681 -b /pane -w /workspace -W sh /tmp/ticker.sh >/dev/null
      ;;
    tmux)
      docker run -d --name "$container" --label managed-by=slopyphus-testbed \
        -p "0.0.0.0:$port:7681" --entrypoint /usr/bin/ttyd "$IMAGE" \
        -p 7681 -b /pane -w /workspace -W \
        bash -c 'tmux new-session -d -s pane "sh /tmp/ticker.sh"; exec tmux attach -t pane' >/dev/null
      ;;
  esac
  docker cp "$TICKER" "$container:/tmp/ticker.sh" >/dev/null
  sleep 6

  # Nothing has connected yet, so a bare ttyd has not even started the command. That is worth recording
  # because it means the pane process is tied to a client from the very first moment.
  before=$(docker exec "$container" sh -c 'wc -l < /tmp/ticks.log 2>/dev/null || echo 0' | tr -d ' ')

  docker cp hack/ttyd-ws-probe.mjs "$container:/tmp/probe.mjs" >/dev/null
  docker exec "$container" bash -c '
    . /root/.nvm/nvm.sh >/dev/null 2>&1 || exit 90
    node /tmp/probe.mjs --url ws://127.0.0.1:7681/pane --collect-ms 8000 --raw > /tmp/probe-1.json 2>&1
  ' >/dev/null 2>&1 || true
  attached=$(docker exec "$container" sh -c 'wc -l < /tmp/ticks.log 2>/dev/null || echo 0' | tr -d ' ')

  # Six seconds with no client at all: long enough that a killed process cannot have merely been slow.
  sleep 6
  detached=$(docker exec "$container" sh -c 'wc -l < /tmp/ticks.log 2>/dev/null || echo 0' | tr -d ' ')

  # A second client attaching later: same counter continuing means the same process, a counter starting at 1
  # or a fresh screen means the pane was rebuilt.
  docker exec "$container" bash -c '
    . /root/.nvm/nvm.sh >/dev/null 2>&1 || exit 90
    node /tmp/probe.mjs --url ws://127.0.0.1:7681/pane --collect-ms 5000 --raw > /tmp/probe-2.json 2>&1
  ' >/dev/null 2>&1 || true
  docker cp "$container:/tmp/probe-1.json" "$WORK/$variant-probe-1.json" >/dev/null 2>&1 || :
  docker cp "$container:/tmp/probe-2.json" "$WORK/$variant-probe-2.json" >/dev/null 2>&1 || :
  latest=$(docker exec "$container" sh -c 'tail -1 /tmp/ticks.log 2>/dev/null' || true)
  docker rm -f "$container" >/dev/null 2>&1 || true

  printf '== %s\n   ticks before any client: %s\n   ticks while a client was attached: %s\n   ticks in the 6 seconds after it left: %s\n   last tick recorded: %s\n' \
    "$variant" "$before" "$attached" "$((detached - attached))" "${latest:-none}"

  node - "$WORK/$variant-probe-1.json" "$WORK/$variant-probe-2.json" <<'EOS'
const fs = require('node:fs');
const read = (p) => {
  try { return JSON.parse(fs.readFileSync(p, 'utf8')).received ?? ''; } catch { return ''; };
};
const ticks = (s) => (s.match(/tick [0-9]+ [0-9.]+/g) ?? []);
for (const [label, p] of [['first client', process.argv[2]], ['second client', process.argv[3]]]) {
  const found = ticks(read(p));
  const last = found.at(-1) ?? 'none';
  console.log(`   ${label} saw ${found.length} tick lines, last: ${last}`);
}
EOS
}

case_index=0
echo "== does a pane outlive its viewer ($IMAGE)"
for variant in bare tmux; do
  run_variant "$variant"
  case_index=$((case_index + 1))
done
