#!/bin/sh
# A live-edit testbed for the front (Dockerfile.nginx + docker-entrypoint.nginx.sh + the two templates).
#
# Why it exists: the front's nginx.conf and index.html are rendered at container start, so the whole
# component is testable without building an image- put the templates from the checkout in a container,
# edit them, copy them back, restart (1s, the render runs again), screenshot what a browser sees.
#
# Docker: this pod has no docker.sock, so the CLI talks to the dev cluster CI node's dockerd over TCP
# (the same endpoint .woodpecker/ci.yaml uses, published by home-ops). Note what that means: the
# container and its published port live on that node, not here. Nothing on this pod is exposed, and the
# URL to point a browser (or chromium.dev) at is the NODE's address- 192.168.1.213:38137 below, which is
# the node's LAN IP. 127.0.0.1 and 172.17.0.1 are both wrong from here: 127.0.0.1 is this pod's loopback
# and 172.17.0.1 is that node's docker bridge gateway, which is not reachable from a pod.
#
# Chromium: https://chromium.dev.initialed85.cc is a headless Chrome with /render /screenshot /eval
# (home-ops SERVICES.md). It runs as a pod in this cluster, so it reaches the testbed over the node's
# LAN address like any other client. A 401 from it is the bearer-token gate, not an outage.
#
# Panes are deliberately configurable, because the two kinds the renderer distinguishes behave differently:
# an arbitrary origin (framed through nginx with its own Host/SNI, and same-origin with the page only
# because of that framing) and a ttyd terminal (websocket proxied under the agent's own base path, whose
# overflow is a different animal from a web page's). The default is origins, because a bare cluster Service
# name does not resolve from the CI node's docker network. For a terminal pane use the agent's ClusterIP -
# and see the warning below about pointing a headless browser at a live agent.
#
# One trap, measured: a headless browser that loads a live agent's ttyd pane attaches a client to that
# agent's tmux, and tmux sizes a window to its smallest client. Probing the deployed 20-pane desktop from
# an 800x600 headless tab therefore resizes every agent's terminal. Reproduce a layout with panes that are
# the same *names* pointing at https://example.com, and only point a pane at a real ttyd when it is your
# own agent.
#
# Usage: hack/front-testbed.sh [up|sync|down|logs|conf|html|push <file> [name]|probe <expr-file> [path]|cdp <front-cdp args>|shot [out.png]]
#
# Written for /bin/sh (this pod has bash, the front's container has busybox ash, keep it plain).

set -eu

PROG=${0##*/}
ROOT=$(cd "$(dirname "$0")/.." && pwd)

# Every knob is TESTBED_* prefixed on purpose: a testbed script that reads a short name picks up
# whatever the calling shell already exports. Two measured collisions in this pod: NAME=slopyphus (the
# agent's own name), and Kubernetes service links for the in-cluster front Deployment, which export
# FRONT_SERVICE_HOST=10.43.228.21 and FRONT_PORT=tcp://10.43.228.21:80. A knob named FRONT_PORT is
# therefore a tcp:// URL where a port number is wanted.
# docker reads DOCKER_HOST from the environment, so it has to be exported, not just assigned.
export DOCKER_HOST=${TESTBED_DOCKER_HOST:-tcp://192.168.1.213:2375}
TESTBED_IMAGE=${TESTBED_IMAGE:-initialed85/slopyphus-nginx:latest}
TESTBED_NAME=${TESTBED_NAME:-front-test}
TESTBED_NODE=${TESTBED_NODE:-192.168.1.213}   # the node whose dockerd this runs on; the published port lives on it
TESTBED_PORT=${TESTBED_PORT:-38137}           # a high port chosen so it cannot collide with a NodePort (30000-32767)
TESTBED_URL=http://$TESTBED_NODE:$TESTBED_PORT

# The desktop under test: three columns, each an arbitrary origin. Any origin will do for measuring the
# layout (that is what the request for this testbed asked for), and nginx framing them under /name/ is
# what makes each pane same-origin with the page, which matters below.
#
# A ttyd pane is worth measuring too, because that is what the real desktop is made of, and a terminal's
# overflow is a different animal from a web page's. Cluster service names did not resolve from the CI
# node's docker network (NXDOMAIN from its embedded DNS), but a ClusterIP is reachable from a container
# on that node (measured: wget http://10.43.147.15:7681/rooter/ returned the ttyd page), so a terminal
# pane is spelled with the agent's IP and its own base path, which the renderer accepts as an agent:
#   TESTBED_COLUMNS='term=http://10.43.147.15:7681/rooter' hack/front-testbed.sh up
TESTBED_COLUMNS=${TESTBED_COLUMNS:-google=https://www.google.com,bing=https://www.bing.com,wiki=https://en.wikipedia.org}
TESTBED_ROWS=${TESTBED_ROWS:-}
TESTBED_LAYOUT=${TESTBED_LAYOUT:-columns_left}
TESTBED_PAGE_TITLE=${TESTBED_PAGE_TITLE:-front-test}
# Left at the container's own defaults (resolver auto-detected from its /etc/resolv.conf, no Service-name
# suffixing) because the default pane set names no bare hosts. For a bare Kubernetes Service name, nginx's
# resolver does not expand search domains, so the in-cluster front sets SVC_SUFFIX=<ns>.svc.cluster.local
# and RESOLVER=<cluster DNS>; pass those here to test that path too.
TESTBED_SVC_SUFFIX=${TESTBED_SVC_SUFFIX:-}
TESTBED_RESOLVER=${TESTBED_RESOLVER:-}

CHROMIUM=${CHROMIUM:-https://chromium.dev.initialed85.cc}
CHROMIUM_TOKEN=${CHROMIUM_TOKEN:-$(kubectl -n auth get secret api-tokens \
  -o jsonpath='{.data.API_TOKEN_EDWARD}' 2>/dev/null | base64 -d || true)}

die() {
  printf '%s: %s\n' "$PROG" "$1" >&2
  exit 1
}

docker_cmd() {
  docker "$@"
}

up() {
  docker_cmd rm -f "$TESTBED_NAME" >/dev/null 2>&1 || true
  docker_cmd run -d --name "$TESTBED_NAME" --label managed-by=slopyphus-testbed \
    -p "0.0.0.0:$TESTBED_PORT:80/tcp" \
    -e COLUMNS="$TESTBED_COLUMNS" -e ROWS="$TESTBED_ROWS" -e LAYOUT="$TESTBED_LAYOUT" \
    -e PAGE_TITLE="$TESTBED_PAGE_TITLE" -e SVC_SUFFIX="$TESTBED_SVC_SUFFIX" -e RESOLVER="$TESTBED_RESOLVER" \
    "$TESTBED_IMAGE" >/dev/null
  # The container's /usr/share/slopyphus is the checked-in templates baked into the image; sync() is
  # what replaces them with the working tree. Do it now so "up" alone already tests these files.
  sync_only
  printf 'front-test up: %s  (node %s, port %s)\n' "$TESTBED_URL" "$TESTBED_NODE" "$TESTBED_PORT"
  printf '  COLUMNS=%s\n  ROWS=%s\n  LAYOUT=%s\n' "$TESTBED_COLUMNS" "$TESTBED_ROWS" "$TESTBED_LAYOUT"
}

# Edit a template, then: sync. The container's writable layer survives a restart, and the entrypoint
# re-renders on start, so cp + restart is the whole rebuild loop.
sync_only() {
  docker_cmd cp "$ROOT/docker-entrypoint.nginx.sh" "$TESTBED_NAME:/docker-entrypoint.nginx.sh"
  docker_cmd cp "$ROOT/nginx.conf.template" "$TESTBED_NAME:/usr/share/slopyphus/nginx.conf.template"
  docker_cmd cp "$ROOT/index.html.template" "$TESTBED_NAME:/usr/share/slopyphus/index.html.template"
  # docker cp preserves the source file's mode, and a git checkout of this repo has the entrypoint 0644
  # (Dockerfile.nginx fixes that with COPY --chmod=0755). Without this the restart dies with
  # `exec: "/docker-entrypoint.nginx.sh": permission denied`.
  docker_cmd exec "$TESTBED_NAME" chmod 0755 /docker-entrypoint.nginx.sh
  docker_cmd restart "$TESTBED_NAME" >/dev/null
}

cmd=${1:-up}
case "$cmd" in
  up)
    up
    ;;
  sync)
    sync_only
    printf 'restarted; rendered config and page are from the working tree at %s\n' "$TESTBED_URL"
    ;;
  down)
    docker_cmd rm -f "$TESTBED_NAME" >/dev/null
    printf 'front-test removed\n'
    ;;
  logs)
    docker_cmd logs --tail 40 "$TESTBED_NAME"
    ;;
  conf)
    docker_cmd exec "$TESTBED_NAME" cat /etc/nginx/conf.d/default.conf
    ;;
  html)
    docker_cmd exec "$TESTBED_NAME" cat /usr/share/nginx/html/index.html
    ;;
  # push: put a file in the running container's html directory, no restart (default target index.html,
  # i.e. a scratch copy of the rendered desktop; pass a name for a scratch page like scrollbox.html).
  # The point of
  # not restarting is that the entrypoint re-renders on start, so a live edit lives only until the next
  # restart- iterate on the scratch file, then bake the result into index.html.template and sync.
  push)
    [ $# -ge 2 ] || die "push needs a file to put in the container's html directory"
    target=${3:-index.html}
    docker_cmd cp "$2" "$TESTBED_NAME:/usr/share/nginx/html/$target"
    printf 'pushed %s -> /usr/share/nginx/html/%s in %s (no restart: a restart re-renders and discards it)\n' "$2" "$target" "$TESTBED_NAME"
    ;;
  # cdp: drive the shared Chromium over a websocket instead of the one-shot routes, so the front can be
  # waited for (xterm only exists once ttyd's websocket opens), resized (the deployed desktop is 20 panes
  # wide, so pane width depends on the viewport), and probed after an expression has changed the page.
  # Extra arguments are passed through to hack/front-cdp.mjs.
  cdp)
    shift
    CHROMIUM_TOKEN="$CHROMIUM_TOKEN" node "$ROOT/hack/front-cdp.mjs" "$@"
    ;;
  # probe: run a synchronous expression against the front in the shared headless Chromium and print the
  # JSON reply. /eval does not await, so no Promises; see home-ops SERVICES.md for the caveats.
  probe)
    [ $# -ge 2 ] || die "probe needs an expression file"
    [ -n "$CHROMIUM_TOKEN" ] || die "no chromium token (kubectl -n auth get secret api-tokens)"
    # Optional path: probe a scratch page in the container rather than the desktop itself.
    probe_path=${3:-/}
    curl -sS -m 40 -H "authorization: Bearer $CHROMIUM_TOKEN" -X POST \
      --data-urlencode "url=$TESTBED_URL$probe_path" --data-urlencode "expression@$2" "$CHROMIUM/eval"
    printf '\n'
    ;;
  shot)
    [ -n "$CHROMIUM_TOKEN" ] || die "no chromium token (kubectl -n auth get secret api-tokens)"
    out=${2:-/tmp/front-test.png}
    curl -sS -m 40 -H "authorization: Bearer $CHROMIUM_TOKEN" -X POST \
      --data-urlencode "url=$TESTBED_URL/" "$CHROMIUM/screenshot" -o "$out"
    printf 'screenshot (800x600 headless viewport) -> %s\n' "$out"
    ;;
  *)
    die "unknown command '$cmd'"
    ;;
esac
