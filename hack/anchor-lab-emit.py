#!/usr/bin/env python3
"""Print anchored pictures (or the same number of text rows) into a pane, then hold the pane open.

    python3 hack/anchor-lab-emit.py --images 12          # 12 pictures, then filler
    python3 hack/anchor-lab-emit.py --text 160           # the control: rows, no pictures
    python3 hack/anchor-lab-emit.py --images 12 --width-px 100 --sleep 900

Run it *under* the relay so the anchor lines exist (this is the pair the feature is made of):

    tmux new-session -d -s lab-img -c /tmp/anchorlab/img -- \
      python3 /usr/local/share/slopyphus/tmux-osc-wrap.py --anchor python3 hack/anchor-lab-emit.py --images 12

Why the knobs exist: the client-side cost per render is `rows` line translations for the scan plus one draw per
picture *visible in the viewport*. So the number of pictures that matter is bounded by the pane's rows and by how
many rows each picture reserves - and the reservation is driven by the width the sequence asks for. `--width-px`
is therefore the lever that sets how many pictures a single frame has to draw.
"""

import argparse
import base64
import signal
import struct
import sys
import time
import zlib


def png(width: int, height: int, seed: int) -> bytes:
    """A gradient PNG built by hand. No PIL in the agent images, and a gradient compresses small."""
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type 0 (none)
        for x in range(width):
            raw += bytes(((x * 255 // max(width - 1, 1) + seed * 17) % 256,
                          (y * 255 // max(height - 1, 1)) % 256,
                          ((x + y + seed * 31) % 256)))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 6))
            + chunk(b"IEND", b""))


def seq_for(raw: bytes, width: int, height: int) -> str:
    return "\x1b]1337;File=size=%d;width=%dpx;height=%dpx;inline=1:%s\x07" % (
        len(raw), width, height, base64.b64encode(raw).decode()
    )


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--images", type=int, default=0)
    ap.add_argument("--text", type=int, default=40)
    ap.add_argument("--w", type=int, default=200, help="picture width in pixels")
    ap.add_argument("--h", type=int, default=120, help="picture height in pixels")
    ap.add_argument("--width-px", type=int, default=100, help="width the sequence asks the pane to draw it at")
    ap.add_argument("--sleep", type=float, default=1800, help="keep the pane alive this long")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--repaint-log", default="", help="write start/end clock times of each repaint here")
    ap.add_argument("--reemit-on-resize", action="store_true",
                    help="re-print every picture on each SIGWINCH, the way a TUI repaints")
    args = ap.parse_args()

    pictures = [png(args.w, args.h, i) for i in range(args.images)]

    log = open(args.repaint_log, "a", buffering=1) if args.repaint_log else None

    def emit_pictures(tag: str) -> None:
        # The two timestamps are the measurement: a repaint of N pictures is a burst of bytes into a pty whose
        # consumer is tmux, and if tmux drains it slowly the write blocks. That stall is the thing a user feels
        # as "the pane is slow when I resize", and it is visible here as the gap between these two clock reads.
        payload = "".join(seq_for(raw, args.w, args.h) + "\n" for raw in pictures)
        t0 = time.time()
        sys.stdout.write(payload)
        sys.stdout.flush()
        t1 = time.time()
        if log:
            log.write("%.6f %.6f %s bytes=%d\n" % (t0, t1, tag, len(payload.encode())))
        if not args.quiet:
            sys.stdout.write("%s: re-emitted %d picture(s) because the pane resized\n" % (tag, len(pictures)))
            sys.stdout.flush()

    if args.reemit_on_resize:
        # The stand-in for what a TUI does on a resize: it repaints, and a repaint re-prints the pictures it is
        # holding. This is the case a relay rewrite would be aimed at, so it is measured rather than imagined.
        count = {"n": 0}

        def on_winch(*_):
            count["n"] += 1
            emit_pictures("repaint %d" % count["n"])

        signal.signal(signal.SIGWINCH, on_winch)

    for i, raw in enumerate(pictures):
        sys.stdout.write(seq_for(raw, args.w, args.h) + "\n")
        if not args.quiet:
            sys.stdout.write("picture %d: %d bytes, %dx%d px\n" % (i + 1, len(raw), args.w, args.h))
    for i in range(args.text):
        sys.stdout.write("row %03d: filler text that a reflow has to move, and nothing else\n" % i)
    sys.stdout.flush()
    time.sleep(args.sleep)


if __name__ == "__main__":
    main()
