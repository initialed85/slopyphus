#!/bin/sh
# Assert the browser file-upload path against a running ttyd, without a browser.
#
# What is being asserted, and why it is not the same thing as reading the C:
#
#   a paste or a drop in a pane has to end with bytes on the pane's own filesystem *and* with the saved
#   path arriving in the terminal, because the second half is what a TUI can act on. A file that lands
#   on disk while the program in the pane never learns where it is has solved the easy half of the
#   feature. Conversely a path typed into a pane with no file behind it is worse than nothing: the user
#   presses enter and the program reports "no such file".
#
# So every case measures both ends of one websocket connection. The probe plays the browser
# (hack/ttyd-ws-probe.mjs, the same frames the real client sends), and the pane is
#
#   bash -c 'stty raw -echo; cat > /tmp/pty.bin'
#
# which is the pty's stdin as a file. `stty raw -echo` matters: a cooked pane maps CR to LF on input and
# echoes what it reads, so a cooked pane would lie about what arrived.
#
# The refusals are asserted as hard as the success, because they are the parts a "works for me" run
# never sees: an oversize file, a readonly pane, a server started with --disable-upload, a transfer cut
# short, and a name that tries to climb out of the uploads directory. Each refusal is checked three ways
# - the result frame, that nothing was written to disk, and that nothing was typed into the pane.
#
# Usage:
#   hack/upload-gate.sh <image>                        # eg slopyphus-terminal-test:local
#   GATE_DOCKER_HOST=tcp://... hack/upload-gate.sh initialed85/slopyphus:<sha>
#
# Docker: like the other testbeds, the containers run on the dev CI node's dockerd over TCP, not on this
# pod. Everything the assertions need (node, ttyd, the payload files) is reached with docker exec inside
# the container under test, which is also why no port is published and no container-to-container reach is
# relied on: a gate that depends on crossing a docker bridge fails for reasons that have nothing to do
# with the feature being tested.
#
# In CI this runs from .woodpecker/ci.yaml in the docker:cli step, which is why nothing on the *calling*
# side needs node: the node in question lives in the image under test.
#
# One deliberate limit: this gate covers the server half and the wire format. The browser half - that a
# Ctrl+V in a pane reaches the upload path rather than xterm's text paste - is measured with
# hack/front-cdp.mjs driving a real Chrome against a testbed pane, because no amount of speaking the
# protocol proves the DOM listeners fire in the right order.
#
# A note on how the typed path is measured, because it is the part that is easy to get wrong:
# --expect in the probe matches the bytes ttyd *sends* to the client, which is the pane's stdout. The
# path an upload types goes the other way, into the pane's stdin, so the evidence is /tmp/pty.bin, read
# out of the container after the transfer. A raw-mode `cat` echoes nothing, and that is exactly why the
# file is the measurement and the websocket output stream is not.
#
# The probe also deliberately does not do what the browser client does after a refusal, which is stop
# sending frames. A server half is only worth trusting against a client that keeps pushing.

set -eu

PROG=${0##*/}
IMAGE=${1:-}
[ -n "$IMAGE" ] || { printf '%s: usage: %s <image>\n' "$PROG" "$PROG" >&2; exit 2; }

export DOCKER_HOST=${GATE_DOCKER_HOST:-tcp://192.168.1.213:2375}
NAME=${GATE_NAME:-upload-gate}
PORT=${GATE_PORT:-7697}
# Matches the agent image: docker-entrypoint.sh starts ttyd with -w /workspace/<name>, so the gate uses a
# -w of its own instead of inheriting a WORKDIR and then asserting a path production never uses.
WORKDIR=${GATE_WORKDIR:-/workspace/gate}
UPLOADS=$WORKDIR/.slopyphus/uploads
HERE=$(cd "$(dirname "$0")" && pwd)
PROBE_SRC=$HERE/ttyd-ws-probe.mjs
SCRATCH=/tmp/upload-gate
fails=0
summary_file=$SCRATCH/summary.json

die() {
  printf '%s: %s\n' "$PROG" "$1" >&2
  exit 1
}

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

note() { printf '\n== %s\n' "$1"; }
ok() { printf '   ok: %s\n' "$1"; }
fail() {
  printf '   FAIL: %s\n' "$1"
  fails=$((fails + 1))
}

[ -s "$PROBE_SRC" ] || die "missing $PROBE_SRC"

# The payloads and the summariser are built here, then copied into the container. A real 1x1 PNG because
# the feature is about images; a ~700 KB pattern file because that is roughly what a phone screenshot
# weighs, and because it is the case that must travel as several frames rather than one.
make_payloads() {
  mkdir -p "$SCRATCH"
  printf 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==\n' |
    base64 -d >"$SCRATCH/gate-upload.png"

  i=0
  : >"$SCRATCH/gate-line.bin"
  while [ "$i" -lt 128 ]; do
    printf '%04d-slopyphus-upload-padding-line-for-a-file-that-needs-several-frames\n' "$i" >>"$SCRATCH/gate-line.bin"
    i=$((i + 1))
  done
  : >"$SCRATCH/gate-screenshot.bin"
  j=0
  while [ "$j" -lt 80 ]; do
    cat "$SCRATCH/gate-line.bin" >>"$SCRATCH/gate-screenshot.bin"
    j=$((j + 1))
  done

  # The summariser is where JSON becomes shell-friendly facts. It runs inside the image under test, next
  # to the probe, so a step image without node can still assert on what happened.
  cat >"$SCRATCH/summarise.mjs" <<'EOF'
import fs from 'node:fs';
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const last = (command) => (report.messages || []).filter((m) => m.command === command).pop();
const result = last('upload-result');
const capabilities = last('capabilities');
process.stdout.write(
  JSON.stringify({
    result: result ? JSON.parse(result.text) : null,
    // Every result frame, in order. A case that plays several uploads on one connection needs to know
    // that four of them failed, not just what the last one said.
    results: (report.messages || []).filter((m) => m.command === 'upload-result').map((m) => JSON.parse(m.text)),
    // Parsed, so that an assertion can grep "upload":true without tripping over the escaping a JSON
    // string inside a JSON string carries.
    capabilities: capabilities ? JSON.parse(capabilities.text) : null,
    sent: (report.uploads || []).map((u) => u.sent),
    declared: (report.uploads || []).map((u) => u.declared),
    receivedBytes: report.receivedBytes,
    expects: (report.expects || []).map((e) => e.found),
  }) + '\n'
);
EOF
}

# Start ttyd in the image under test with the given flags, with a pane whose stdin is a file.
serve() {
  flags=$1
  cleanup
  docker run -d --name "$NAME" --entrypoint bash "$IMAGE" -c \
    "ttyd -p $PORT -b /gate -w $WORKDIR $flags bash -c 'stty raw -echo; cat > /tmp/pty.bin'" >/dev/null ||
    die "could not start $NAME from $IMAGE"
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if docker exec "$NAME" bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT" 2>/dev/null; then
      docker cp "$PROBE_SRC" "$NAME:/tmp/probe.mjs" >/dev/null
      docker cp "$SCRATCH/summarise.mjs" "$NAME:/tmp/summarise.mjs" >/dev/null
      return 0
    fi
    sleep 1
  done
  docker logs "$NAME" 2>&1 | tail -20
  die "ttyd never listened on $PORT in $NAME"
}

# One upload played from the browser side. The summary lands in $summary_file as compact JSON with
# result / capabilities / sent / receivedBytes / expects, which is what the assertions below grep.
upload() {
  src=$1
  shift
  # Every extra probe argument is shell-quoted before it is interpolated into the container's command,
  # because the names worth testing are the ones a browser actually produces, and
  # "Screenshot 2026-11-06 at 15.30.05.png" is a name with spaces in it.
  quoted=''
  for arg in "$@"; do
    quoted="$quoted $(shell_quote "$arg")"
  done
  docker cp "$src" "$NAME:/tmp/upload-src" >/dev/null
  docker exec "$NAME" bash -c "
    . /root/.nvm/nvm.sh >/dev/null 2>&1 || exit 90
    node /tmp/probe.mjs --url ws://127.0.0.1:$PORT/gate --upload /tmp/upload-src$quoted > /tmp/probe.json 2>/tmp/probe.err
    probe_exit=\$?
    node /tmp/summarise.mjs /tmp/probe.json > /tmp/probe.summary 2>>/tmp/probe.err || exit 91
    printf '%d\n' \"\$probe_exit\" >> /tmp/probe.summary
    exit 0
  " || {
    docker exec "$NAME" sh -c 'tail -20 /tmp/probe.err' 2>/dev/null || true
    die "the probe could not run inside $NAME"
  }
  docker cp "$NAME:/tmp/probe.summary" "$summary_file" >/dev/null || die "no summary from $NAME"
  summary=$(cat "$summary_file")
  printf '   probe: %s\n' "$summary"
}

# What the pane actually received, with CRs folded away: the fact the feature lives on.
pty_text() { docker exec "$NAME" sh -c 'cat /tmp/pty.bin 2>/dev/null | tr -d "\r"' || true; }

uploads_count() { docker exec "$NAME" sh -c "find $UPLOADS -type f 2>/dev/null | wc -l" || echo 0; }

# Full paths, newest first, which is what cmp needs. `ls -1t <dir>` prints basenames, and a comparison
# against a basename is how a gate starts reporting "No such file or directory" for a file it found.
uploads_list() { docker exec "$NAME" sh -c "find $UPLOADS -type f 2>/dev/null | xargs -r ls -1t" || true; }

uploads_newest() { uploads_list | head -1; }

# POSIX single-quote escaping, because this script runs under /bin/sh and bash's printf %q is not there:
# wrapping in single quotes and rewriting any inner single quote as end-quote, a literal quote, reopen.
shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# A case is: start ttyd with these flags, run one upload, then compare this summary against what that
# case is supposed to do.
summary_has() { grep -qF "$1" "$summary_file"; }

make_payloads

note 'accepted upload: the file lands, and the path reaches the pane'
serve '-W'
upload "$SCRATCH/gate-upload.png" '--upload-name' 'Screenshot 2026-11-06 at 15.30.05.png'
summary_has '"ok":true' && ok 'the result frame said ok' || fail 'the upload did not report ok'
[ "$(uploads_count)" = 1 ] && ok "one file under $UPLOADS" || {
  fail "expected one uploaded file, found $(uploads_count)"
  uploads_list
}
docker exec "$NAME" sh -c "cmp /tmp/upload-src '$(uploads_newest)'" &&
  ok 'the bytes on disk are the bytes that were sent' || fail 'the saved file does not match what was uploaded'
if pty_text | grep -qF "$UPLOADS/"; then
  ok 'the saved path arrived on the pane stdin, typed as though the user had written it'
else
  fail 'no upload path reached the pane'
  pty_text | od -c | head -5
fi
newest=$(uploads_newest)
[ -n "$newest" ] && pty_text | grep -qF "$newest" &&
  ok 'the path typed into the pane is the file that exists' ||
  fail 'the path typed into the pane is not the path the file was written to'
# The separator matters as much as the path. A paste is usually the start of a sentence rather than the
# end of one, and without a space the user's own typing lands inside the filename.
pty_text | grep -qF "$newest " &&
  ok 'and a space follows it, so what the user types next is not glued onto the name' ||
  fail 'the typed path arrived with no trailing space'
case "$newest" in
  *-Screenshot-2026-11-06-at-15.30.05.png) ok "a browser name with spaces stored as $(basename "$newest")" ;;
  *) fail "expected the spaces in a macOS-style screenshot name to become dashes, got $(basename "$newest")" ;;
esac
# Spaces matter specifically because the path is *typed*: in any shell pane a space would end the
# argument, so an upload that preserved them would hand over a path that does not name the file.
case "$newest" in
  *' '*) fail "the stored path contains a space: $newest" ;;
  *) ok 'no spaces in the typed path' ;;
esac
summary_has '"upload":true' &&
  ok 'the server told the client an upload is possible here' || fail 'no capabilities frame, so a client cannot decide whether to accept a paste'

note 'a file that needs several frames, which is what a real screenshot is'
serve '-W'
size=$(wc -c <"$SCRATCH/gate-screenshot.bin")
[ "$size" -gt 400000 ] || die "the multi-frame payload is only $size bytes, which would not exercise chunking"
upload "$SCRATCH/gate-screenshot.bin" '--upload-name' 'gate-screenshot.bin' '--upload-chunk' 196608
sent=$(printf '%s' "$summary" | sed -n 's/.*"sent":\[\([0-9][0-9]*\).*/\1/p')
[ "$sent" = "$size" ] && ok "the declared $size bytes all went out in 196608-byte frames" ||
  fail "expected $size bytes sent, the summary said $sent"
[ "$(uploads_count)" = 1 ] && ok 'one file from several frames' || fail 'a chunked upload did not produce exactly one file'
docker exec "$NAME" sh -c "cmp /tmp/upload-src '$(uploads_newest)'" &&
  ok "$size bytes reassembled byte for byte" || fail 'a chunked upload wrote the wrong bytes'
pty_text | grep -qF "$UPLOADS/" && ok 'and the path reached the pane' || fail 'a chunked upload did not type a path'

note 'oversize: refused before a byte is written'
serve '-W --upload-max-bytes 100000'
upload "$SCRATCH/gate-screenshot.bin" '--upload-name' 'gate-screenshot.bin'
summary_has '"ok":false' && ok 'refused' || fail 'an oversize file was accepted'
summary_has 'larger than the upload limit' && ok 'and said why' || fail 'the refusal did not name the limit'
[ "$(uploads_count)" = 0 ] && ok 'nothing was written to the workspace' ||
  fail 'an oversize upload left a file behind'
[ -z "$(pty_text)" ] && ok 'nothing was typed into the pane' || fail 'an oversize upload typed something anyway'
summary_has '"uploadMaxBytes":100000' &&
  ok 'the limit was advertised, so a client can refuse before sending a byte' || fail 'the capabilities frame did not carry the limit'

note 'a readonly pane: no upload channel, and the client is told before it tries'
serve ''
upload "$SCRATCH/gate-upload.png" '--upload-name' 'gate-upload.png'
summary_has '"ok":false' && ok 'refused on a readonly pane' || fail 'a readonly pane accepted an upload'
summary_has 'readonly' && ok 'and said why' || fail 'the readonly refusal did not say why'
summary_has '"upload":false' && ok 'capabilities said no, so no drop is offered at all' ||
  fail 'capabilities still advertised an upload on a readonly pane'

note '--disable-upload: the operator switch is honoured'
serve '-W --disable-upload'
upload "$SCRATCH/gate-upload.png" '--upload-name' 'gate-upload.png'
summary_has '"ok":false' && summary_has 'disabled' && ok 'refused, and said it was disabled' ||
  fail '--disable-upload did not refuse an upload'
[ "$(uploads_count)" = 0 ] && ok 'nothing written' || fail '--disable-upload still wrote a file'
summary_has '"upload":false' && ok 'capabilities said no' || fail 'capabilities advertised an upload despite --disable-upload'

note 'a name that tries to climb out of the uploads directory'
serve '-W'
upload "$SCRATCH/gate-upload.png" '--upload-name' '../../../../etc/evil.txt'
summary_has '"ok":true' && ok 'the upload itself succeeded, which is the point: the name is sanitised, not rejected' ||
  fail 'a hostile name was refused outright'
[ "$(uploads_count)" = 1 ] && ok 'still exactly one file, under the uploads directory' || {
  fail "unexpected file count for a hostile name: $(uploads_count)"
  uploads_list
}
docker exec "$NAME" sh -c 'test ! -e /etc/evil.txt' && ok '/etc/evil.txt was not created' ||
  fail 'the name escaped the uploads directory'
name=$(basename "$(uploads_newest)")
case "$name" in
  *'..'*) fail "the stored name still contains path traversal: $name" ;;
  *) ok "stored as $name" ;;
esac
pty_text | grep -qF '..' && fail 'a name containing .. was typed into the pane' ||
  ok 'nothing containing .. was typed into the pane'

note 'a transfer cut short: no half-written image left behind'
serve '-W'
upload "$SCRATCH/gate-screenshot.bin" '--upload-name' 'gate-screenshot.bin' '--upload-skip' 4096
summary_has '"ok":false' && ok 'the commit was refused' || fail 'a truncated upload was accepted'
summary_has 'stopped before the declared size' && ok 'and said why' || fail 'the truncation refusal did not say why'
summary_has '"path":""' && ok 'and the refusal stopped naming a file that does not exist' ||
  fail 'a failed upload still reported a path, which is the kind of thing a client then types into a pane'
[ "$(uploads_count)" = 0 ] && ok 'the partial file was unlinked' || fail 'a truncated upload left a partial file behind'
[ -z "$(pty_text)" ] && ok 'and nothing was typed for a file that does not exist' ||
  fail 'a truncated upload typed a path anyway'

note 'frames back to back, which is how a browser sends them'
# A browser fires paste and then BEGIN, DATA, COMMIT in one tick: the frames land in the server's receive
# buffer together. Paced frames hide a decoder that reads to a NUL instead of to a length, because the
# byte after a paced frame happens to be nothing interesting. This case exists because that bug was
# measured in the browser and not in the paced probe: four of five uploads refused for "more bytes arrived
# than the client declared", with the server naming a chunk a few bytes larger than the file.
#
# Six uploads on this connection, not five: the helper always sends the file it copied as /tmp/upload-src,
# and the five named ones ride on the end of the same connection, which is exactly the shape a paste of
# several files makes.
serve '-W'
upload "$SCRATCH/gate-line.bin" '--upload-gap' 0 \
  '--upload' /tmp/upload-src '--upload-name' 'b2b two.txt' \
  '--upload' /tmp/upload-src '--upload-name' 'b2b three.txt' \
  '--upload' /tmp/upload-src '--upload-name' 'b2b four.txt' \
  '--upload' /tmp/upload-src '--upload-name' 'b2b five.txt' \
  '--upload' /tmp/upload-src '--upload-name' 'b2b six.txt'
if [ "$(grep -o '"ok":false' "$summary_file" | wc -l)" = 0 ]; then
  ok 'six uploads on one connection, sent back to back, none refused'
else
  fail 'an unpaced upload was refused, which is the frame-boundary bug reappearing'
fi
if [ "$(uploads_count)" = 6 ]; then
  ok 'six files on disk, one per upload'
else
  fail "expected six files, found $(uploads_count)"
fi
src_md5=$(docker exec "$NAME" sh -c 'md5sum /tmp/upload-src | cut -d" " -f1')
distinct_md5=$(docker exec "$NAME" sh -c "md5sum $UPLOADS/* | cut -d' ' -f1 | sort -u | wc -l")
if [ "$distinct_md5" = 1 ] && docker exec "$NAME" sh -c "md5sum $UPLOADS/* | cut -d' ' -f1 | sort -u" | grep -q "$src_md5"; then
  ok 'every one is byte for byte what was sent, so no frame boundary was crossed'
else
  fail 'a saved file does not match what was sent, so a frame boundary was crossed'
fi

note 'frames out of order: a client that misbehaves must not be able to kill a pane'
serve '-W'
docker cp "$SCRATCH/gate-upload.png" "$NAME:/tmp/upload-src" >/dev/null
docker exec "$NAME" bash -c "
  . /root/.nvm/nvm.sh >/dev/null 2>&1 || exit 90
  node -e '
    const fs = require(\"fs\");
    const socket = new WebSocket(\"ws://127.0.0.1:$PORT/gate\", [\"tty\"]);
    socket.binaryType = \"arraybuffer\";
    socket.addEventListener(\"open\", () => {
      socket.send(JSON.stringify({ AuthToken: \"\", columns: 80, rows: 24 }));
      const chunk = fs.readFileSync(\"/tmp/upload-src\").toString(\"base64\");
      socket.send(Buffer.concat([Buffer.from(\"5\"), Buffer.from(chunk)]));  // DATA with no BEGIN
      socket.send(Buffer.from(\"6\"));                                        // COMMIT with no BEGIN
      socket.send(Buffer.from(\"7\"));                                        // ABORT with nothing in flight
    });
    setTimeout(() => process.exit(0), 1500);
  '
" >/dev/null 2>&1 || fail 'a stray DATA/COMMIT/ABORT sequence took the pane down'
[ "$(uploads_count)" = 0 ] && ok 'a stray DATA/COMMIT/ABORT created nothing' ||
  fail 'a stray DATA/COMMIT/ABORT wrote a file'
[ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || echo gone)" = true ] &&
  ok 'and the pane survived it, which is the point: a bad client must not take a terminal down' ||
  fail 'a misordered frame killed the pane'

note 'summary'
cleanup
if [ "$fails" = 0 ]; then
  printf '   upload gate passed against %s\n' "$IMAGE"
else
  printf '   upload gate failed %d assertion(s) against %s\n' "$fails" "$IMAGE"
  exit 1
fi
