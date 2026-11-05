#!/bin/sh
# Rebuild ttyd's web client from the vendored forks and write the generated bundle back into
# vendor/ttyd/src/html.h.
#
# Why this exists: ttyd ships its browser UI as a generated header, `src/html.h` (the gzipped,
# inlined index.html that the binary embeds), and upstream commits the generated file. So the thing
# the agent image compiles is that header, and any change to the client has to be regenerated here
# first. This is the whole reason the client half of the desktop is forked twice over:
#
#   vendor/xterm.js  initialed85/xterm.js (fork of xtermjs/xterm.js, pinned to the version ttyd pins)
#   vendor/ttyd      initialed85/ttyd     (fork of tsl0922/ttyd)
#
# and this script is what joins them: it builds @xterm/xterm from vendor/xterm.js and makes ttyd's
# webpack resolve `@xterm/xterm` to that build instead of the npm tarball. Without the override, an
# edit to vendor/xterm.js would be invisible: ttyd's package.json asks for `^5.4.0` from the registry.
#
# Where it runs: in a container on the CI node's dockerd, not on this pod. Two reasons. The pod's node
# is v26 with no corepack, and ttyd's client is pinned to yarn 3.6.3 by its packageManager field, which
# corepack (bundled with Ubuntu's nodejs 22) supplies; xterm.js wants yarn 1 and its devDependencies
# include node-pty, whose native build fails on modern node, hence --ignore-scripts (nothing in the
# bundle needs it). The container is also what makes the result reproducible: same node, same yarn.
#
# Usage:
#   hack/build-ttyd-client.sh                 # regenerate vendor/ttyd/src/html.h
#   hack/build-ttyd-client.sh --check         # build into a scratch dir and report the diff, touch nothing
#
# Afterwards: the regenerated header is a change *to the fork*, so it is committed there, and the
# pin in slopyphus moves with it:
#
#   git -C vendor/ttyd commit -am 'client: ...'   # branch slopyphus
#   git -C vendor/ttyd push origin slopyphus
#   git add vendor/ttyd && git commit             # the new pin, in slopyphus
#
# The agent image build needs no node toolchain: it compiles the header that is committed.

set -eu

PROG=${0##*/}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export DOCKER_HOST=${TESTBED_DOCKER_HOST:-tcp://192.168.1.213:2375}
NAME=${TTYD_CLIENT_NAME:-ttyd-client-build}
IMAGE=${TTYD_CLIENT_IMAGE:-ubuntu:26.04}
# The path inside the container is what the package.json override points at, so it is not arbitrary.
XTERM_IN=/work/xterm.js
HTML_IN=/work/html

check=0
if [ "${1:-}" = "--check" ]; then
  check=1
fi

die_stub() {
  printf '%s: %s\n' "$PROG" "$1" >&2
  exit 1
}

for dir in vendor/ttyd vendor/xterm.js; do
  [ -e "$ROOT/$dir/CMakeLists.txt" ] || [ -e "$ROOT/$dir/package.json" ] || \
    die_stub "empty submodule: $dir (git submodule update --init --recursive)"
done

committed_html=$ROOT/vendor/ttyd/src/html.h
# Payload hashes, not file hashes: the gzip member carries an mtime, so an identical rebuild still
# produces different bytes in the header.
payload() {
  node "$ROOT/hack/html-h-payload.mjs" "$1" | sha256sum | cut -d' ' -f1
}
before=$(payload "$committed_html")

docker rm -f "$NAME" >/dev/null 2>&1 || true
# A container rather than an image build, because the inputs are working-tree files and the output is
# one file that has to come back out. HOME is moved onto a volume so that the three caches this build
# actually uses — corepack's downloaded yarns, yarn 1's package cache (xterm.js) and yarn berry's global
# cache (ttyd's client) — survive between runs. Doing it with env vars instead is a trap: berry rejects
# an unknown `globalCacheFolder` with "Unrecognized or legacy configuration settings", and its global
# path is not configurable anyway.
CACHE_VOL=${TTYD_CLIENT_CACHE:-slopyphus-ttyd-client-cache}
docker volume inspect "$CACHE_VOL" >/dev/null 2>&1 || docker volume create "$CACHE_VOL" >/dev/null
docker run -d --name "$NAME" --label managed-by=slopyphus-testbed \
  -e HOME=/cache -v "$CACHE_VOL:/cache" "$IMAGE" sleep 3600 >/dev/null
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT

# apt needs node; corepack is what supplies the yarn versions both trees pin. ca-certificates is not
# optional: without it every https request node makes fails UNABLE_TO_GET_ISSUER_CERT_LOCALLY, and
# corepack reports that as a network error, which is a very misleading way to spell "missing trust store".
for attempt in 1 2 3; do
  if docker exec "$NAME" bash -c "apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq --no-install-recommends nodejs ca-certificates git >/dev/null 2>&1; node --version; corepack --version; node -e \"require('https').get('https://registry.npmjs.org/yarn', r => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))\" && echo 'registry reachable over TLS'"; then
    break
  fi
  [ "$attempt" = 3 ] && die_stub "apt/node/registry check failed 3 times in $NAME"
  sleep 10
done
docker exec "$NAME" mkdir -p /work
docker cp "$ROOT/vendor/xterm.js/." "$NAME:/work/xterm.js"
docker cp "$ROOT/vendor/ttyd/html/." "$NAME:/work/html"
docker cp "$ROOT/vendor/ttyd/src/." "$NAME:/work/src"

docker exec -e CHECK=$check -e XTERM=$XTERM_IN -e HTML=$HTML_IN "$NAME" bash -euc '
cd "$XTERM"
echo "== @xterm/xterm $(node -p "require(\"$XTERM/package.json\").version") from the fork"
# --ignore-scripts: node-pty (a devDependency, used by the demo and the tests) cannot build against
# modern node, and neither the bundle nor tsc needs it.
# The retry is for the registry, not for the lockfile: corepack has failed mid-download from this node.
for attempt in 1 2 3; do
  if corepack yarn install --ignore-scripts >/tmp/xterm-install.log 2>&1; then break; fi
  echo "install attempt $attempt failed:"; tail -5 /tmp/xterm-install.log
  [ "$attempt" = 3 ] && exit 1
  sleep 15
done
node_modules/.bin/tsc -b src/browser/tsconfig.json src/headless/tsconfig.json
node_modules/.bin/webpack >/tmp/xterm-webpack.log 2>&1 || { tail -20 /tmp/xterm-webpack.log; exit 1; }
test -f lib/xterm.js
echo "== built $(wc -c <lib/xterm.js) bytes of lib/xterm.js"

cd "$HTML"
# The override is applied to the copy in the container, never to the checkout: ttyd has to stay
# buildable on its own, and this path only exists inside this script.
node -e "
const fs = require(\"fs\");
const p = JSON.parse(fs.readFileSync(\"package.json\", \"utf8\"));
p.dependencies[\"@xterm/xterm\"] = \"file:\" + process.env.XTERM;
p.resolutions = Object.assign({}, p.resolutions, {\"@xterm/xterm\": \"file:\" + process.env.XTERM});
fs.writeFileSync(\"package.json\", JSON.stringify(p, null, 2));
"
export YARN_ENABLE_IMMUTABLE_INSTALLS=false
for attempt in 1 2 3; do
  if corepack yarn install >/tmp/html-install.log 2>&1; then break; fi
  echo "html install attempt $attempt failed:"; tail -8 /tmp/html-install.log
  [ "$attempt" = 3 ] && exit 1
  sleep 15
done
readlink -f node_modules/@xterm/xterm
cmp -s node_modules/@xterm/xterm/lib/xterm.js "$XTERM/lib/xterm.js" || { echo "FAIL: the bundle did not resolve to the fork"; exit 1; }
echo "== ttyd client resolved @xterm/xterm to the fork"
corepack yarn build >/tmp/html-build.log 2>&1 || { tail -30 /tmp/html-build.log; exit 1; }
test -s ../src/html.h
echo "== wrote ../src/html.h ($(wc -c <../src/html.h) bytes)"
'

if [ "$check" = 1 ]; then
  docker cp "$NAME:/work/src/html.h" /tmp/html.h.new
  after=$(payload /tmp/html.h.new)
  if [ "$before" = "$after" ]; then
    printf '%s: --check: the committed html.h already matches what the forks build (%s)\n' "$PROG" "$before"
  else
    printf '%s: --check: html.h would change (%s -> %s); run without --check to write it\n' "$PROG" "$before" "$after"
    exit 3
  fi
else
  docker cp "$NAME:/work/src/html.h" "$committed_html"
  after=$(payload "$committed_html")
  printf '%s: vendor/ttyd/src/html.h rebuilt from vendor/xterm.js\n' "$PROG"
  printf '%s:   payload %s -> %s%s\n' "$PROG" "$before" "$after" \
    "$([ "$before" = "$after" ] && echo '  (unchanged: the fork matches the npm build it replaces)')"
  printf '%s: commit it in the fork, then re-pin the submodule here; the image build compiles this file\n' "$PROG"
fi
