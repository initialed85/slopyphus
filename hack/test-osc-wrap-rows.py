#!/usr/bin/env python3
"""Row reservation: the arithmetic, the byte-exactness of everything around it, and the agreement with a browser.

Run: python3 hack/test-osc-wrap-rows.py

The relay (tools/tmux-osc-wrap.py) reserves pane rows after an inline image because xterm.js does not move the
cursor for one. Two things have to be true for that to be worth shipping, and this file checks both:

  1. The wrapper is still byte-exact. The reservation is appended outside the tmux passthrough wrapper; nothing
     else about the bytes may change. The reference is hack/pi-image-bytes.mjs --wrap-tmux, which is the same
     wrapping done by a program that never runs anything.
  2. The row count agrees with what the renderer actually draws. That comparison uses numbers measured in a
     browser (hack/image-cases.sh + hack/image-rows-report.py, 2026-11-07, ttyd's own xterm.js client):
     they are quoted below as constants with their provenance, because a unit test cannot start a browser.
"""
import base64
import hashlib
import importlib.util
import math
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("osc_wrap", os.path.join(REPO, "tools", "tmux-osc-wrap.py"))
osc_wrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(osc_wrap)

fails = 0


def brief(v):
    """A failing byte comparison must not print a payload bigger than the log it is meant to explain."""
    r = repr(v)
    return r if len(r) <= 160 else r[:80] + f" ... {len(r) - 160} bytes elided ... " + r[-60:]


def check(label, got, want):
    global fails
    ok = got == want
    fails += 0 if ok else 1
    if ok:
        print(f"  ok   {label}")
    else:
        print(f"  FAIL {label:58} got {brief(got)} want {brief(want)}")


def near(label, got, want, tol):
    global fails
    ok = abs(got - want) <= tol
    fails += 0 if ok else 1
    print(f"  {'ok  ' if ok else 'FAIL'} {label:58} got {got:.2f} want {want:.2f} +/- {tol}")


def png(w, h):
    """A real PNG of the requested size, so image_dimensions is reading a genuine IHDR rather than a fixture."""
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    raw = b"".join(b"\x00" + b"\x00" * (w * 3) for _ in range(h))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(raw, 0)) + chunk(b"IEND", b""))


def payload(header, image):
    return b"\x1b]1337;File=" + header.encode() + b":" + base64.b64encode(image) + b"\x07"


def unwrap(wrapped):
    assert wrapped.startswith(b"\x1bPtmux;\x1b") and wrapped.endswith(b"\x1b\\")
    return wrapped[len(b"\x1bPtmux;\x1b"):-2].replace(b"\x1b\x1b", b"\x1b")


IMG = png(560, 280)

print("reading an image's inherent size out of its own header")
check("PNG 560x280", osc_wrap.image_dimensions(payload("inline=1", IMG)), (560, 280))
check("PNG 1x1", osc_wrap.image_dimensions(payload("inline=1", png(1, 1))), (1, 1))
gif = b"GIF89a" + struct.pack("<HH", 320, 200) + b"\x00" * 32
check("GIF 320x200", osc_wrap.image_dimensions(payload("inline=1", gif)), (320, 200))
# A real BMP, laid out the way a BMP actually is, so the check is about the reader and not about the fixture.
bmp = b"BM" + b"\x00" * 12 + struct.pack("<I", 40) + struct.pack("<ii", 64, -48) + b"\x00" * 8
check("BMP 64x48 with a negative height", osc_wrap.image_dimensions(payload("inline=1", bmp)), (64, 48))
jpeg = (b"\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
        + b"\xff\xdb\x00\x43" + b"\x00" * 65
        + b"\xff\xc0\x00\x11\x08\x00\xc8\x01\x90\x03\x01\x11\x00\x02\x11\x01\x03\x11\x01"
        + b"\xff\xd9")
check("JPEG 400x200, SOF0 reached past a DHT", osc_wrap.image_dimensions(payload("inline=1", jpeg)), (400, 200))
check("an unreadable format reserves nothing",
      osc_wrap.image_dimensions(payload("inline=1", b"notanimage" * 16)), None)
check("a payload bigger than the 2 KB peek still reads the header",
      osc_wrap.image_dimensions(payload("inline=1", png(1200, 900))), (1200, 900))

print("\nheader parsing, mirroring IIPHeaderParser (split at the first colon, ; between fields)")
check("Pi's real spelling", osc_wrap.header_fields(payload("inline=1;size=342;width=60;height=auto", IMG)),
      {"inline": "1", "size": "342", "width": "60", "height": "auto"})
name = base64.b64encode(b"a file.png").decode()
check("name= is base64, padding and all", osc_wrap.header_fields(payload(f"inline=1;name={name};width=10", IMG)),
      {"inline": "1", "name": name, "width": "10"})

print("\nrow arithmetic with an explicitly stated cell (100 cols x 30 rows, ratio 0.6, cell 17px)")
r, px = 0.6, 17.0
check("width=60 height=auto        -> ceil(60*0.6*280/560)",
      osc_wrap.reserve_rows(payload("inline=1;width=60;height=auto", IMG), 100, 30, ratio=r, cell_px=px), 18)
check("height=40, aspect off       -> the requested rows, when the pane has room",
      osc_wrap.reserve_rows(payload("inline=1;width=60;height=40;preserveAspectRatio=0", IMG), 100, 50,
                            ratio=r, cell_px=px), 40)
check("width=60 height=40, aspect on -> width wins, as IIPHandler._resize does",
      osc_wrap.reserve_rows(payload("inline=1;width=60;height=40", IMG), 100, 30, ratio=r, cell_px=px), 18)
check("both auto                   -> fits the canvas, one row left for the cursor",
      osc_wrap.reserve_rows(payload("inline=1", IMG), 100, 30, ratio=r, cell_px=px), 29)
check("height=10% of a 30-row pane -> 3 rows",
      osc_wrap.reserve_rows(payload("inline=1;height=10%", IMG), 100, 30, ratio=r, cell_px=px), 3)
check("width=340px, aspect on      -> ceil(340/560*280/17)",
      osc_wrap.reserve_rows(payload("inline=1;width=340px", IMG), 100, 30, ratio=r, cell_px=px), 10)
check("a reservation is capped to the pane",
      osc_wrap.reserve_rows(payload("inline=1;width=200;height=auto", IMG), 100, 30, ratio=r, cell_px=px), 30)
check("square image at width=10    -> ceil(10*0.6)",
      osc_wrap.reserve_rows(payload("inline=1;width=10", png(200, 200)), 100, 30, ratio=r, cell_px=px), 6)
check("no header fields            -> nothing reserved",
      osc_wrap.reserve_rows(b"\x1b]1337;File=" + base64.b64encode(IMG) + b"\x07", 100, 30, ratio=r, cell_px=px), 0)
check("an unreadable image         -> nothing reserved",
      osc_wrap.reserve_rows(payload("inline=1;width=60", b"notanimage" * 64), 100, 30, ratio=r, cell_px=px), 0)

# Measured in the browser rather than derived (hack/image-cases.sh slopyphus-terminal-test:local rows-baseline
# rows-fix, 2026-11-07, ttyd's own client at -t defaults; read back by hack/image-rows-report.py):
#   bare pane  160 cols x 52 rows in a 1120x780 viewport  -> 7.00px x 15.00px per cell, ratio 0.467
#   tmux pane  160 cols x 51 rows in a 1120x780 viewport  -> 7.00px x 15.29px per cell, ratio 0.458
#   Pi's sequence for the 560x280 test image: File=inline=1;size=342;width=80;height=auto, inherent 160x80,
#   drawn by the addon 560x280 px = 80 x 7.00px, which covers 18.7 rows bare and 18.3 rows under tmux.
print("\nthe shipped defaults, against the browser that was actually measured")
FIXTURE = "/tmp/image-test/flag.png"
if not os.path.exists(FIXTURE):
    # The measured comparison below is only as good as the file Pi was measured against, and a freshly started
    # container has no /tmp/image-test. hack/make-test-image.py is in the repository, so the fixture is rebuilt
    # rather than the comparison quietly skipped.
    subprocess.run([sys.executable, os.path.join(REPO, "hack", "make-test-image.py")], capture_output=True)
pi_seq = subprocess.run(["node", os.path.join(REPO, "hack", "pi-image-bytes.mjs"), FIXTURE],
                        capture_output=True)
if pi_seq.returncode != 0:
    print("  (skip: hack/pi-image-bytes.mjs did not run; /tmp/image-test/flag.png is made by hack/make-test-image.py)")
    fails += 1
else:
    seq = pi_seq.stdout
    check("Pi's own header", osc_wrap.header_fields(seq),
          {"inline": "1", "size": "342", "width": "80", "height": "auto"})
    check("Pi's own inherent size (Pi resized the image on the way in)", osc_wrap.image_dimensions(seq), (160, 80))
    print(f"  defaults shipped: ratio {osc_wrap.CELL_RATIO}, cell {osc_wrap.CELL_HEIGHT_PX}px")
    near("bare 160x52 pane: reserved vs 18.7 rows drawn",
         osc_wrap.reserve_rows(seq, 160, 52), 18.7, 2.0)
    near("tmux 160x51 pane: reserved vs 18.3 rows drawn",
         osc_wrap.reserve_rows(seq, 160, 51), 18.3, 2.0)
    wrapped = osc_wrap.Rewriter(True, reserve=False, term_size=(160, 52)).feed(seq)
    reference = subprocess.run(["node", os.path.join(REPO, "hack", "pi-image-bytes.mjs"),
                                "/tmp/image-test/flag.png", "--wrap-tmux"], capture_output=True).stdout
    check("the wrapper alone is still byte-identical to hack/pi-image-bytes.mjs --wrap-tmux",
          wrapped, reference)
    full = osc_wrap.Rewriter(True, term_size=(160, 52)).feed(seq)
    check("the reservation is appended outside the wrapper, as ordinary newlines",
          full, reference + b"\r\n" * osc_wrap.reserve_rows(seq, 160, 52))

print("\nthe relay's own behaviour on a wrapped payload, and on text it must not touch")
r2 = osc_wrap.Rewriter(True, term_size=(100, 30))
check("text with no image passes through untouched",
      r2.feed(b"hello \x1b[31mred\x1b[0m\n"), b"hello \x1b[31mred\x1b[0m\n")
seq = payload("inline=1;width=60;height=auto", IMG)
head, tail = seq[:100], seq[100:]
check("a payload split across reads is held rather than half-written", r2.feed(head), b"")
rest = r2.feed(tail)
check("the reassembled payload is wrapped once", rest.count(b"\x1bPtmux;\x1b"), 1)
check("and followed by the rows it covers, outside the wrapper and after its single closing ST",
      rest.endswith(b"\x1b\\" + b"\r\n" * osc_wrap.reserve_rows(seq, 100, 30)), True)
check("the relay counted one image", r2.stats["images"], 1)
check("a --no-reserve relay reserves nothing", osc_wrap.Rewriter(True, reserve=False).stats["rows"], 0)
# Disabling the relay disables the wrapper, which is the tmux-specific half. The reservation is not
# tmux-specific: xterm.js leaves the cursor where an image began whether or not tmux was in the way, and the
# harness measured both halves of that (bare-rows-fix paints the picture with the text below it,
# bare-rows-baseline paints it with the text on top of it).
check("a disabled relay leaves the bytes alone but still reserves the rows",
      osc_wrap.Rewriter(False, term_size=(100, 30)).feed(seq),
      seq + b"\r\n" * osc_wrap.reserve_rows(seq, 100, 30))
check("the reservation is a separate switch from the wrapper",
      osc_wrap.Rewriter(False, reserve=False).feed(seq), seq)
# tmux has no handling for OSC 1337 at all (grep -c 1337 input.c is 0), so it discards every one of them, not
# only the image ones. Carrying a non-image 1337 through the wrapper is the same service; reserving rows for
# it would be inventing a picture that was never drawn.
check("an OSC 1337 that is not an image is still carried",
      osc_wrap.Rewriter(True, term_size=(100, 30)).feed(b"\x1b]1337;Framer=1\x07"),
      b"\x1bPtmux;\x1b\x1b\x1b]1337;Framer=1\x07\x1b\\")
check("and it reserves no rows", osc_wrap.Rewriter(True, term_size=(100, 30)).stats["rows"], 0)

tmp = tempfile.mkdtemp(prefix="osc-wrap-images-")
osc_wrap.IMAGES_DIR = tmp  # the relay reads the constant at import, so a test patches the constant
osc_wrap.IMAGE_KEEP = 3

print("\nanchoring: the picture saved under the pane's directory, and the line of text that records where it goes")
seq = payload("inline=1;width=40;height=auto", IMG)
want_rows = osc_wrap.reserve_rows(seq, 100, 30)
digest = hashlib.sha256(IMG).hexdigest()[:10]
before = osc_wrap.Rewriter(True, term_size=(100, 30)).feed(seq)
check("a relay with the anchor off - the shipped default - emits no anchor and saves nothing",
      (b"[[img:" in before, os.listdir(tmp)), (False, []))

r = osc_wrap.Rewriter(True, anchor=True, term_size=(100, 30))
out = r.feed(seq)
anchor_bytes = b"\x1b[2m[[img:" + digest.encode() + b".png:%d]]\x1b[0m\r\n" % want_rows
check("the anchor sits on the row below the reserved ones, dimmed and reset, carrying the rows it reserved",
      out.endswith(b"\r\n" * want_rows + anchor_bytes), True)
check("the row count in the anchor is the count the reservation used", want_rows > 0, True)
# The byte stream is what changed, and it changed on purpose. Two renderers drawing the same picture - the one the
# bytes drive, which attaches an image to its own buffer lines, and the one the anchor drives, which draws where
# the grid says - were measured disagreeing after a pane split, the picture ending up under the tmux status bar and
# over another pane's prompt. An anchor is grid text; it cannot end up anywhere but where the pane put it.
check("an anchored relay does not send the picture as bytes at all", (osc_wrap.INTRO in out, b"1337" in out), (False, False))
check("and it still reserves the rows the picture needs, in the pane's own grid", out, b"\r\n" * want_rows + anchor_bytes)
inline_out = osc_wrap.Rewriter(True, anchor=True, inline=True, term_size=(100, 30)).feed(seq)
check("asking for --inline sends the plain relay's bytes, in the plain relay's order, plus the anchor",
      inline_out, osc_wrap.wrap(seq) + b"\r\n" * want_rows + anchor_bytes)
check("the saved file is byte-identical to the picture that was passed", open(os.path.join(tmp, digest + ".png"), "rb").read(), IMG)
check("the id is a prefix of the content hash, so the same picture twice is one file", len(os.listdir(tmp)), 1)
r.feed(seq)
check("and feeding it twice refreshes rather than duplicates", (r.stats["anchors"], len(os.listdir(tmp))), (2, 1))

for w, h in ((11, 7), (13, 5), (17, 3)):
    osc_wrap.Rewriter(True, anchor=True, term_size=(100, 30)).feed(payload("inline=1;width=10", png(w, h)))
names = sorted(os.listdir(tmp))
check("four pictures in, IMAGE_KEEP=3 out", len(names), 3)
# Which one a live relay would drop depends on wall-clock granularity - several writes in the same second tie -
# so the retention rule is checked directly, with the ages stated rather than left to the clock.
base = 1_700_000_000
for i, name in enumerate(names):
    os.utime(os.path.join(tmp, name), (base + i, base + i))
osc_wrap.IMAGE_KEEP = 2
osc_wrap.prune_images()
check("pruning drops the oldest by mtime and keeps the rest", sorted(os.listdir(tmp)), sorted(names[1:]))

bogus = payload("inline=1;width=10", b"not a picture at all, no magic bytes here")
rb = osc_wrap.Rewriter(True, anchor=True, term_size=(100, 30))
bout = rb.feed(bogus)
check("an image whose size cannot be read gets no anchor: an unsized anchor is a picture drawn over text",
      (b"[[img:" in bout, rb.stats["anchors"], rb.stats["rows"]), (False, 0, 0))
check("so its bytes are sent anyway: an anchor that fails is a downgrade, not a disappearance",
      (osc_wrap.INTRO in bout, b"1337" in bout), (True, True))
check("and nothing is saved for it", len(os.listdir(tmp)), 2)  # three minus the one the retention check pruned
shutil.rmtree(tmp)

print()
if fails:
    print(f"{fails} check(s) failed")
    sys.exit(1)
print("every check passed")
