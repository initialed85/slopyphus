#!/bin/sh
# Do pictures in a tmux pane survive everything tmux does to the pane?
#
# The question this harness exists to answer, asked the way it can actually be answered: not "did the image
# render" (hack/image-cases.sh already answers that) but "is the picture still there when the bytes that drew it
# are gone". tmux keeps cells and stores no copy of an inline image - measured in slopyphus with tmux 3.4,
# `capture-pane -p -e` on a pane that has just drawn one finds none of it - so a repaint, a reattach or a resize
# reprints the pane from text, and everything that was only ever a burst of bytes disappears with it.
#
# The mechanism under test is the pair the rest of this feature is built out of:
#
#   tools/tmux-osc-wrap.py --anchor   saves each picture it passes under the pane's working directory, named by
#                                     a prefix of its content hash, and prints one dimmed line of text on the row
#                                     below the rows it reserved: [[img:<10 hex>.<ext>:<rows>]]
#   ttyd (src/http.c)                 GET <base>/images/<name> serves that file and nothing else
#   the client addon (html/.../addons/image-anchor.ts) reads those lines out of the buffer and draws the file
#                                     they name, over the rows above the line, on every render
#
# Which is why the ordering in this file is the opposite of hack/image-cases.sh. That harness has to hold the
# print back until the browser is attached, because an image lives only in the frame that drew it. Here the
# browser is deliberately attached *after* the pane has printed, because a picture that arrives from a text
# anchor does not care when the viewer showed up: the grid still holds the line, and the line is the whole record.
# A late browser that still shows the flag is the claim itself, not a race to be worked around.
#
# Cases:
#
#   anchor-emit      the relay, with --anchor, relaying a program that prints Pi's own image bytes. The browser
#                    attaches afterwards. Evidence: the file on disk, the anchor line in tmux's grid, the flag on
#                    screen, and the drawn height against the anchor's own row count.
#   anchor-reattach  the same pane, looked at again by a second browser tab at a different viewport size - which
#                    is a client reattach and a pane resize at once, and the shape of every repaint tmux can do.
#                    The burst is long gone by then; only the text remains.
#   anchor-text-only the decisive one. The pane is given the anchor line and *no image bytes at any point*; the
#                    picture file is placed by this script. If the flag appears, the anchor is doing the work.
#
# Usage: hack/image-anchor-cases.sh [image tag] [case ...]
set -eu

IMAGE=${1:-slopyphus-terminal-test:local}
if [ $# -ge 1 ]; then shift; fi
CASES=${*:-"anchor-emit anchor-text-only"}

DOCKER_HOST=${DOCKER_HOST:-tcp://192.168.1.213:2375}
export DOCKER_HOST
BASE_PORT=${BASE_PORT:-38240}
NODE=${TESTBED_NODE:-192.168.1.213}
WORK=/tmp/anchor-cases
SHOTS=$WORK/shots
TEST_IMAGE=${TEST_IMAGE:-/tmp/image-test/flag.png}
mkdir -p "$SHOTS"

[ -n "$(docker images -q "$IMAGE" 2>/dev/null)" ] || {
  echo "image $IMAGE not found; build it first (docker build -t $IMAGE .)" >&2
  exit 2
}
[ -f "$TEST_IMAGE" ] || { echo "no test image at $TEST_IMAGE (hack/make-test-image.py makes it)" >&2; exit 2; }

PNG_B64=$(base64 -w0 "$TEST_IMAGE")
SEQ_B64=$(node hack/pi-image-bytes.mjs "$TEST_IMAGE" | base64 -w0)
SHIM_B64=$(base64 -w0 tools/tmux-osc-wrap.py)
# The name the relay would have written, worked out here so the text-only case can name a file that already
# exists. Same rule as save_image in the relay: sha256 of the picture's bytes, first ten hex digits.
NAME=$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest()[:10])' "$TEST_IMAGE").png
# How many rows the relay will reserve for this picture at the pane's cell, which the case prints into the pane
# for the harness to read back. The anchor carries the number; this checks the number against what the browser
# then draws.
ROWS_CLAIM=$WORK/rows.txt

start_container() {
  # Prefixed locals on purpose. A POSIX shell function has no local variables, and this helper used to assign
  # plain `name` - the same word its caller was using for the case - so the caller's case name silently became
  # the container name for the rest of the run, which is how the reattach check stopped running at all while
  # everything else still looked plausible.
  cname=$1
  cport=$2
  cscript=$3
  cpreplace=${4:-0}
  docker rm -f "$cname" >/dev/null 2>&1 || true
  # The pane's shell is started from /workspace, which is also ttyd's -w directory. That is not cosmetic: the
  # relay writes to <its cwd>/.slopyphus/images and the server reads <its -w>/.slopyphus/images, and the feature
  # only works when those are the same directory. In production both are the agent's own working directory
  # (docker-entrypoint.sh: ttyd -w /workspace/$NAME, and Pi is launched there); in a harness they have to be
  # lined up by hand or the browser will ask for a picture the server cannot see.
  #
  # The pane waits for its case script to appear rather than running it at once, because the script is copied
  # into a container that lives on another machine, and a pane that starts before the copy lands is a pane that
  # ran nothing.
  docker run -d --name "$cname" --label managed-by=slopyphus-testbed \
    -p "0.0.0.0:$cport:7681" --entrypoint /bin/sh "$IMAGE" -c \
    "cd /workspace && tmux new-session -d -s pane 'cd /workspace; until [ -f /tmp/case.sh ]; do sleep 0.3; done; sh /tmp/case.sh; touch /tmp/case-done.txt; sleep 120' && exec /usr/bin/ttyd -p 7681 -b /pane -w /workspace -W -t enableSixel=true bash -c 'exec tmux attach -t pane'" >/dev/null
  sleep 1
  docker cp "$WORK/$cscript" "$cname:/tmp/case.sh" >/dev/null
  docker exec "$cname" sh -c 'mkdir -p /workspace/.slopyphus/images' >/dev/null
  if [ "$cpreplace" = 1 ]; then
    # The text-only case has no relay in it and no image bytes anywhere, so the picture has to arrive by way of
    # the file system alone. That is the point of the case, and it is also how a picture drawn days later would
    # work, if the file were still there.
    docker exec -i "$cname" sh -c "cat > /workspace/.slopyphus/images/$NAME" < "$TEST_IMAGE"
  fi
}

write_cases() {
  cat >"$WORK/case-anchor-emit.sh" <<EOS
echo "CASE-SIZE \$(tput cols 2>/dev/null || echo ??)x\$(tput lines 2>/dev/null || echo ??)" > /tmp/case-size.txt
echo CASE-BEFORE-MARKER
echo '$SEQ_B64' | base64 -d > /tmp/pi-seq.bin
echo '$SHIM_B64' | base64 -d > /tmp/osc-wrap.py
python3 /tmp/osc-wrap.py --anchor sh -c 'cat /tmp/pi-seq.bin; echo CASE-AFTER-MARKER'
echo CASE-RAN-MARKER
EOS

  # Nothing in this case is an image. The pane's entire graphics content is one line of text and a file the
  # harness put on disk before the pane started.
  cat >"$WORK/case-anchor-text-only.sh" <<EOS
echo "CASE-SIZE \$(tput cols 2>/dev/null || echo ??)x\$(tput lines 2>/dev/null || echo ??)" > /tmp/case-size.txt
echo CASE-BEFORE-MARKER
# The blank rows come from the same claim the anchor makes, so the grid the browser sees has room for the
# picture the anchor says belongs there. Nothing here reserves anything; the anchor is the only instruction.
i=0
while [ \$i -lt ROWSPLACEHOLDER ]; do printf '\r\n'; i=\$((i + 1)); done
printf '\033[2m[[img:$NAME:ROWSPLACEHOLDER]]\033[0m\r\n'
echo CASE-AFTER-MARKER
echo CASE-RAN-MARKER
EOS
}

# What the browser is asked. An IIFE: evaluating a bare "()" serialises as an empty object, which is how the
# first version of hack/image-cases.sh reported zero everywhere. The point of this one is the canvas the addon
# owns - ttyd renders text with the WebGL addon, whose canvas has no 2D context, so getContext('2d') returning
# pixels is already a canvas that is not the text layer.
write_dom() {
  cat >"$WORK/dom.js" <<'EOS'
(async () => {
  const term = window.term;
  const canvases = Array.from(document.querySelectorAll('canvas')).map((c) => {
    const info = { className: c.className || '(none)', width: c.width, height: c.height };
    const ctx = c.getContext('2d', { willReadFrequently: true });
    if (!ctx) {
      info.context2d = false;
      return info;
    }
    const data = ctx.getImageData(0, 0, c.width, c.height).data;
    let painted = 0, red = 0, blue = 0;
    let left = c.width, top = c.height, right = -1, bottom = -1;
    for (let i = 0; i < data.length; i += 4) {
      if (data[i + 3] === 0) continue;
      painted++;
      const x = (i / 4) % c.width, y = Math.floor((i / 4) / c.width);
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
    if (painted > 0) info.box = { left, top, right, bottom, w: right - left + 1, h: bottom - top + 1 };
    return info;
  });
  const overlay = canvases.filter((c) => (c.className || '').indexOf('slopyphus-image-anchor') !== -1);
  const screen = document.querySelector('.xterm-screen');
  const rect = screen ? screen.getBoundingClientRect() : null;

  // Read the record the same way the addon does. If the addon draws nothing and this finds the line, the
  // difference is inside the addon; if this finds nothing either, tmux never put the line where a viewer looks.
  const buffer = term.buffer.active;
  const anchors = [];
  for (let y = buffer.viewportY; y < buffer.viewportY + term.rows; y++) {
    const line = buffer.getLine(y);
    const text = line ? line.translateToString(true) : '';
    if (text.indexOf('[[') !== -1) anchors.push({ row: y, text: text.trim().slice(0, 60) });
  }
  // And ask for the bytes the way the addon does, in the open, so a picture that never arrives has a status
  // code attached to it rather than a hypothesis.
  let fetchResult = null;
  if (anchors.length) {
    const m = anchors[0].text.match(/\[\[img:([^\]]+)\]\]/);
    if (m) {
      const name = m[1].split(':')[0];
      const path = window.location.pathname.replace(/[/]+$/, '');
      const url = path + '/images/' + name;
      try {
        const res = await fetch(url);
        fetchResult = { url, status: res.status, contentType: res.headers.get('content-type'), bytes: (await res.blob()).size };
      } catch (e) {
        fetchResult = { url, error: String(e) };
      }
    }
  }
  const above = [];
  if (anchors.length) {
    for (let y = Math.max(0, anchors[0].row - 25); y < anchors[0].row; y++) {
      const line = buffer.getLine(y);
      above.push(line ? line.translateToString(true).trim() : '');
    }
  }
  // Painted pixels are not the same thing as visible pixels, and the difference is a stacking question rather
  // than a drawing one. elementFromPoint does not answer it: this canvas is pointer-events: none, which is what
  // lets the pane keep selecting text and hovering links under a picture, and it is also what makes elementFromPoint
  // step straight over it. So the stack is worked out the way the browser would: among the positioned layers of
  // .xterm-screen, z-index wins, DOM order breaks ties, and `auto` behaves as 0 - measured values, not guesses.
  const stack = Array.from(screen.children).map((el, i) => {
    const z = getComputedStyle(el).zIndex;
    return { i, tag: el.tagName, className: el.className || '(none)', z: z === 'auto' ? 0 : parseInt(z, 10) || 0 };
  }).sort((a, b) => (a.z - b.z) || (a.i - b.i));
  // Only the layers that can paint. .xterm-helpers sits at z-index 5 and paints nothing at all - it is the hidden
  // textarea an IME composes into and the row-measuring divs - so ranking it above a picture would be a check
  // that fails on a working page. The canvases are what competes for what the eye sees.
  const paint = stack.filter((l) => l.tag === 'CANVAS');
  const top = paint.length ? paint[paint.length - 1] : null;
  return {
    canvases,
    overlay,
    grid: { cols: term.cols, rows: term.rows, viewportY: buffer.viewportY, baseY: buffer.baseY, length: buffer.length },
    screen: rect ? { w: Math.round(rect.width), h: Math.round(rect.height) } : null,
    anchors,
    rowsAboveAnchor: above,
    fetchResult,
    stack,
    paint,
    top,
  };
})()
EOS
}

fails=0
case_index=0
results=$WORK/results.txt
: >"$results"

# What the browser reported, read as JSON rather than with grep. The first version of this pulled values out of
# the file with grep, which found nothing in front-cdp.mjs's pretty-printed multi-line output and so reported a
# feature that was working as one that was broken. Everything comes out on one line so the shell can compare it.
read_summary() {
  python3 - "$1" <<'EOS'
import json, re, sys
d = json.load(open(sys.argv[1]))
v = d.get("value") or {}
o = (v.get("overlay") or [{}])[0]
box = o.get("box") or {}
fetch = v.get("fetchResult") or {}
anchors = v.get("anchors") or []
grid = v.get("grid") or {}
screen = v.get("screen") or {}
claim = 0
if anchors:
    m = re.search(r"img:[^:]+:(\d+)", anchors[0].get("text", ""))
    if m:
        claim = int(m.group(1))
cell_h = (screen.get("h", 0) / grid["rows"]) if grid.get("rows") else 0
top = v.get("top") or {}
print("painted=%s red=%s blue=%s box=%sx%s@%s anchors=%s claim=%s cellH=%.1f claimH=%.1f fetch=%s/%sB top=%s" % (
    o.get("paintedPixels", 0), o.get("red", 0), o.get("blue", 0),
    box.get("w", 0), box.get("h", 0), box.get("top", -1), len(anchors), claim, cell_h, claim * cell_h,
    fetch.get("status", "-"), fetch.get("bytes", "-"), top.get("className") or top.get("tag") or "-"))
for c in d.get("console", []):
    if "anchor" in c.get("text", ""):
        print("console:", c["text"])
EOS
}

look() {
  # look <container> <port> <shot-name> [extra cdp args...] : attach a browser, measure, screenshot.
  container=$1
  port=$2
  label=$3
  shift 3
  json=$WORK/$label.json
  shot=$SHOTS/$label.png
  hack/front-testbed.sh cdp --url "http://$NODE:$port/pane/" --wait-ms 12000 \
    --expression-file "$WORK/dom.js" --shot "$shot" --capture-console "$@" >"$json" 2>&1
  summary=$(read_summary "$json")
  echo "   $label: $summary"
  painted=$(echo "$summary" | sed -n 's/.*painted=\([0-9]*\).*/\1/p')
  colors=$(echo "$summary" | sed -n 's/.*red=\([0-9]*\).*/\1/p')
  boxh=$(echo "$summary" | sed -n 's/.*box=[0-9]*x\([0-9]*\).*/\1/p')
  claimh=$(echo "$summary" | sed -n 's/.*claimH=\([0-9.]*\).*/\1/p')
  if [ "${painted:-0}" -lt 100 ] || [ "${colors:-0}" -lt 100 ]; then
    echo "      the addon drew nothing, or drew something that is not the flag"
    fails=$((fails + 1))
  fi
  # Who is on top of the middle of the reserved rows. The canvas can hold the picture and still be underneath the
  # text layer, which is a bug this harness has already been fooled by once.
  top=$(echo "$summary" | sed -n 's/.*top=\([^ ]*\).*/\1/p')
  case "$top" in
    slopyphus-image-anchor) ;;
    *)
      echo "      something other than the picture layer is on top of the rows it drew: ${top:-nothing}"
      fails=$((fails + 1))
      ;;
  esac
  # The drawn height against the height the anchor's own row count implies. The relay reserved rows in cells for a
  # cell size it could not know and the browser measured the cell it was actually given; if the picture lands on
  # the rows the anchor says it owns, the two agreed about a number neither of them could have measured alone.
  if [ -n "$boxh" ] && [ -n "$claimh" ]; then
    echo "      drawn height ${boxh}px against the ${claimh}px the anchor's row count implies: $(python3 -c "import sys;print('%s%% apart' % round(abs(float(sys.argv[1]) - float(sys.argv[2])) / float(sys.argv[2]) * 100, 1))" "$boxh" "$claimh")"
    python3 -c "import sys; sys.exit(0 if abs(float(sys.argv[1]) - float(sys.argv[2])) <= 0.15 * float(sys.argv[2]) else 1)" "$boxh" "$claimh" || {
      echo "      the picture is not the size the anchor reserved"
      fails=$((fails + 1))
    }
  fi
  printf '%s\n' "$label $summary" >>"$results"
}

run_case() {
  name=$1
  port=$((BASE_PORT + case_index))
  container="anchor-$name"
  case_index=$((case_index + 1))

  start_container "$container" "$port" "case-$name.sh" "$([ "$name" = anchor-text-only ] && echo 1 || echo 0)"

  # The pane runs its case before the browser exists (see the ordering note at the top of this file), so give
  # it time, and check it finished from the pane's own side rather than inferring it from the browser.
  sleep 6
  if ! docker exec "$container" test -f /tmp/case-done.txt 2>/dev/null; then
    echo "   the pane never finished its case; nothing below means anything"
    fails=$((fails + 1))
  fi

  # Text in the grid is the record, so read the record from the thing that stores it.
  docker exec "$container" tmux capture-pane -p > "$WORK/$name.grid" 2>/dev/null || true
  docker exec "$container" cat /tmp/case-size.txt > "$WORK/$name.size" 2>/dev/null || true
  anchor=$(grep -o '\[\[img:[^]]*\]\]' "$WORK/$name.grid" | head -1)
  files=$(docker exec "$container" sh -c 'ls /workspace/.slopyphus/images 2>/dev/null' | tr '\n' ' ')
  echo "   grid: ${anchor:-no anchor line}  files: ${files:-none}"
  [ -n "$anchor" ] || { echo "      the relay left no anchor in the grid"; fails=$((fails + 1)); }
  [ -n "$files" ] || { echo "      the relay saved nothing where the server reads"; fails=$((fails + 1)); }

  look "$container" "$port" "$name-attach"

  if [ "$name" = anchor-emit ]; then
    # A second tab, at a different viewport: tmux reprints the pane for the new client at the new size, which
    # is the same class of event as a wheel scroll into copy-mode or a pane menu - the grid is reprinted from
    # text and any picture that was only bytes is finished.
    echo "   (looking again from a second client at 900x500)"
    look "$container" "$port" "$name-reattach" --width 900 --height 500
  fi

  docker rm -f "$container" >/dev/null 2>&1 || true
}

echo "== anchor cases against $IMAGE  (test picture named $NAME)"
write_cases
# The text-only case has to state a row count, and the honest number is the one the relay's own arithmetic
# produces for this picture at a pane of this size. Compute it with the shipped defaults rather than guessing.
ROWS=$(python3 - "$TEST_IMAGE" <<'EOS'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("osc_wrap", "tools/tmux-osc-wrap.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
raw = open(sys.argv[1], "rb").read()
# The relay reserves for the *emitted* header (width in cells, height=auto), which is what Pi asks for. The
# text-only case is a hand-written anchor, so it borrows the same arithmetic for the same picture.
seq = b"\x1b]1337;File=inline=1;width=40;height=auto:" + __import__("base64").b64encode(raw) + b"\x07"
print(m.reserve_rows(seq, 100, 30))
EOS
)
sed -i "s/ROWSPLACEHOLDER/$ROWS/" "$WORK/case-anchor-text-only.sh"
echo "   the text-only case claims $ROWS rows for a 100x30 cell"
write_dom
for name in $CASES; do
  printf '== %s\n' "$name"
  run_case "$name"
done

echo
echo "== summary"
echo "   shots and json in $SHOTS"
cat "$results"
if [ "$fails" = 0 ]; then
  echo "   every anchor case put a picture on screen"
else
  echo "   $fails anchor check(s) failed"
fi
exit 0
