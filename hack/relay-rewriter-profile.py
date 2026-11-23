#!/usr/bin/env python3
"""Profile the relay's own hot path (`Rewriter.feed`) on an image-heavy repaint, with no pty and no tmux in the way.

    python3 hack/relay-rewriter-profile.py                 # 12 pictures, 12 repaints, all three modes
    python3 hack/relay-rewriter-profile.py --images 120 --repaints 3
    python3 hack/relay-rewriter-profile.py --profile       # cProfile top functions for the anchor path

Why this exists: the pane-level measurement (hack/anchor-resize-lab.sh) says a 12-picture repaint is 1.09 MB and
takes roughly 0.8 s end to end, and it takes that long whether the relay anchors or not. That single fact decides
whether a rewrite in another language is worth anything: if the time is the pipe draining, no language helps; if it
is `feed()` doing work on the bytes, the hot function can be named instead of guessed at. Feeding the rewriter the
same 64 KiB chunks the relay loop uses keeps the comparison honest.
"""

import argparse
import cProfile
import importlib.util
import io
import os
import pstats
import sys
import time

RELAY = os.environ.get("RELAY", "/usr/local/share/slopyphus/tmux-osc-wrap.py")
if not os.path.exists(RELAY):
    RELAY = os.path.join(os.path.dirname(__file__), "..", "tools", "tmux-osc-wrap.py")

def _load_emit():
    """anchor-lab-emit.py has hyphens in its name, so it is loaded by path rather than imported."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "anchor-lab-emit.py")
    spec = importlib.util.spec_from_file_location("anchorlabemit", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_emit = _load_emit()
png, seq_for = _emit.png, _emit.seq_for  # the same pictures the lab panes print

READ_SIZE = 65536


def load_relay():
    spec = importlib.util.spec_from_file_location("oscwrap", RELAY)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def payloads(count: int, w: int, h: int, width_px: int) -> list:
    out = []
    for i in range(count):
        raw = png(w, h, i)
        out.append((seq_for(raw, w, h) + "\n").encode())
    return out


def feed_all(rw, chunks) -> int:
    emitted = 0
    for c in chunks:
        emitted += len(rw.feed(c))
    emitted += len(rw.idle())
    return emitted


def chunk(payload: bytes) -> list:
    return [payload[i:i + READ_SIZE] for i in range(0, len(payload), READ_SIZE)]


def measure(mod, mode: str, payload: bytes, repaints: int) -> dict:
    anchor, inline = {"byte": (False, True), "anchor": (True, False), "raw": (False, None)}[mode]
    t0 = time.perf_counter()
    cpu0 = os.times()
    emitted = 0
    for _ in range(repaints):
        rw = mod.Rewriter(True, reserve=True, anchor=anchor, inline=inline, term_size=(120, 60))
        emitted += feed_all(rw, chunk(payload))
    wall = time.perf_counter() - t0
    cpu = os.times()
    busy = (cpu[0] - cpu0[0]) + (cpu[1] - cpu0[1]) + (cpu[2] - cpu0[2]) + (cpu[3] - cpu0[3])
    return {
        "mode": mode,
        "in_mb": round(len(payload) * repaints / 1e6, 2),
        "out_mb": round(emitted / 1e6, 2),
        "wall_ms": round(wall * 1000, 1),
        "cpu_ms": round(busy * 1000, 1),
        "blocked_ms": round((wall - busy) * 1000, 1),
        "mb_per_cpu_s": round(len(payload) * repaints / 1e6 / busy, 1) if busy > 0 else None,
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--images", type=int, default=12)
    ap.add_argument("--repaints", type=int, default=12)
    ap.add_argument("--w", type=int, default=200)
    ap.add_argument("--h", type=int, default=120)
    ap.add_argument("--width-px", type=int, default=100)
    ap.add_argument("--profile", action="store_true")
    ap.add_argument("--cwd", default="/tmp/anchorlab/profile", help="where the anchor path writes its files")
    args = ap.parse_args()

    os.makedirs(args.cwd, exist_ok=True)
    os.chdir(args.cwd)
    mod = load_relay()
    payload = b"".join(payloads(args.images, args.w, args.h, args.width_px))
    print("relay: %s" % RELAY)
    print("one repaint: %d pictures, %.2f MB of base64 through the relay" % (args.images, len(payload) / 1e6))
    print("%-7s %8s %8s %9s %9s %11s" % ("mode", "in MB", "out MB", "wall ms", "cpu ms", "MB/cpu-s"))
    for mode in ("raw", "byte", "anchor"):
        r = measure(mod, mode, payload, args.repaints)
        print("%-7s %8s %8s %9s %9s %11s" % (r["mode"], r["in_mb"], r["out_mb"], r["wall_ms"], r["cpu_ms"], r["mb_per_cpu_s"]))
        if r["blocked_ms"] > 0.5 * r["wall_ms"]:
            print("        (%.0f%% of wall was the relay *not* running: it was waiting, not working)" % (100 * r["blocked_ms"] / r["wall_ms"]))

    if args.profile:
        rw = mod.Rewriter(True, reserve=True, anchor=True, inline=False, term_size=(120, 60))
        pr = cProfile.Profile()
        pr.enable()
        feed_all(rw, chunk(payload))
        pr.disable()
        s = pstats.Stats(pr, stream=io.StringIO())
        s.sort_stats("tottime")
        buf = io.StringIO()
        s.stream = buf
        s.print_stats(12)
        print("\ncProfile of one anchored repaint:")
        print("\n".join(buf.getvalue().splitlines()[:22]))


if __name__ == "__main__":
    main()
