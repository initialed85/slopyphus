#!/usr/bin/env python3
"""Measure who is actually slow when a tmux pane reflows: the relay, tmux, or the browser.

    python3 hack/osc-wrap-resize-bench.py                      # both modes, empty pane
    python3 hack/osc-wrap-resize-bench.py --fill 5000          # pane full of text
    python3 hack/osc-wrap-resize-bench.py --fill 5000 --images 8
    python3 hack/osc-wrap-resize-bench.py --throughput 20      # MB of text, relay vs plain

Why this exists: the relay's resize path is three syscalls (TIOCGWINSZ, TIOCSWINSZ, pane_size), so a claim that
"resizes are slow again" is a claim about something else until it is measured. The relay adds one thing that
tmux cares about - it prints blank rows to reserve the space an image occupies - and blank rows are grid content,
which tmux reflows on every size change. So the bench varies the amount of grid content and the presence of
reserved image rows, and compares the same resize against a pane with no relay in front of it.

What each number means:
  cmd_ms   wall time of the `tmux resize-window` call itself (tmux server work, no relay involved)
  lat_ms   resize command issued -> the pane's child sees SIGWINCH with the new size (the end-to-end reflow)
  cpu_s    CPU seconds the relay process burned between the first fill and the last resize
  mb_s     text the child pushed through the pipe per second, wrapped vs unwrapped

Runs in a throwaway tmux session named bench-* so a real agent pane is never resized.
"""

import argparse
import base64
import os
import subprocess
import sys
import time

PROBE = r'''
import base64, fcntl, os, signal, struct, sys, termios, time

# argv, not env: `tmux new-session` hands the pane the tmux SERVER's environment, which was captured when the
# server started (at the container entrypoint), so variables set here are invisible to the child.
LOG, FILL, IMAGES, THROUGH = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])
log = open(LOG, "a", buffering=1)
log.write("%.6f start\n" % time.time())

# A 1x1 PNG, because the bench needs a real OSC 1337 image, not a plausible-looking fake one.
PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
)

def image(px):
    # height/width in pixels, inline=1, and the byte count the addon reads before the payload.
    b64 = base64.b64encode(PNG).decode()
    return "\x1b]1337;File=size=%d;width=%dp;height=%dp;inline=1:%s\x07" % (
        len(PNG), px, px, b64
    )

def emit():
    t0 = time.time()
    if FILL:
        for i in range(FILL):
            sys.stdout.write("fill line %05d: a reflow of the pane grid moves every one of these cells\n" % i)
    if IMAGES:
        for _ in range(IMAGES):
            sys.stdout.write(image(400))
            sys.stdout.write("\n")
    if THROUGH:
        line = "x" * 79 + "\n"
        n = int(THROUGH * 1024 * 1024 / len(line))
        for _ in range(n):
            sys.stdout.write(line)
    sys.stdout.flush()
    log.write("%.6f emitted fill=%d images=%d mb=%.1f in %.3fs\n" % (
        time.time(), FILL, IMAGES, THROUGH, time.time() - t0))

def size():
    w = fcntl.ioctl(1, termios.TIOCGWINSZ, b"\0" * 8)
    rows, cols = struct.unpack("hhhh", w)[:2]
    return rows, cols

def winch(*_):
    log.write("%.6f winch %dx%d\n" % (time.time(), *size()))

signal.signal(signal.SIGWINCH, winch)
emit()
log.write("%.6f ready\n" % time.time())
time.sleep(60)
'''

SIZES = [(101, 31), (102, 32), (95, 27), (110, 35), (80, 24), (120, 40),
         (99, 29), (103, 33), (87, 26), (112, 36), (91, 28), (108, 34)]


def sh(*args: str) -> str:
    return subprocess.run(args, capture_output=True, text=True).stdout.strip()


def relay_cpu(pid: int) -> float:
    out = sh("ps", "-o", "cputime=", "-p", str(pid))
    parts = out.split(":")
    if len(parts) != 3:
        return 0.0
    h, m, s = parts
    return int(h) * 3600 + int(m) * 60 + int(s)


def run_case(relay: bool, args, log: str) -> None:
    label = "relay" if relay else "plain"
    session = "bench-%s" % label
    tag = ""
    if args.fill:
        tag += " fill=%d" % args.fill
    if args.images:
        tag += " images=%d" % args.images
    if args.throughput:
        tag += " mb=%d" % args.throughput
    print("\n== %s%s" % (label, tag))

    for f in (log,):
        if os.path.exists(f):
            os.unlink(f)
    probe = [args.probe, log, str(args.fill), str(args.images), str(args.throughput)]
    quoted = " ".join("%s" % p for p in probe)
    if relay:
        cmd = ["bash", "-c", "exec python3 /usr/local/share/slopyphus/tmux-osc-wrap.py python3 " + quoted]
    else:
        cmd = ["bash", "-c", "exec python3 " + quoted]

    sh("tmux", "kill-session", "-t", session)
    sh("tmux", "new-session", "-d", "-s", session, "-x", "100", "-y", "30", "--", *cmd)
    pid = int(sh("tmux", "list-panes", "-t", session, "-F", "#{pane_pid}"))
    if not pid:
        print("  no pane pid, aborting")
        return

    deadline = time.time() + 40
    ready = False
    while time.time() < deadline:
        if os.path.exists(log) and "ready" in open(log).read():
            ready = True
            break
        time.sleep(0.1)
    if not ready:
        print("  probe never became ready")
        sh("tmux", "kill-session", "-t", session)
        return

    cpu0 = relay_cpu(pid)
    stamps = []
    for i in range(args.steps):
        w, h = SIZES[i % len(SIZES)]
        t0 = time.time()
        subprocess.run(["tmux", "resize-window", "-t", "%s:0" % session, "-x", str(w), "-y", str(h)],
                       capture_output=True)
        stamps.append((t0, time.time() - t0, "%dx%d" % (h, w)))
        time.sleep(args.gap)
    time.sleep(1.0)
    cpu1 = relay_cpu(pid)
    lines = [l.split() for l in open(log).read().splitlines() if l.strip()]
    sh("tmux", "kill-session", "-t", session)

    emit = [l for l in lines if l[1] == "emitted"]
    winches = [(float(l[0]), l[2]) for l in lines if l[1] == "winch"]
    if emit:
        print("  emit wall: %s" % " ".join(" ".join(l[2:]) for l in emit))
    if args.command_time:
        print("  tmux resize-window call times (ms): %s" % " ".join("%.0f" % (c * 1000) for _, c, _ in stamps))

    lats = []
    for t0, cmd, name in stamps:
        hits = [w for w in winches if t0 <= w[0] <= t0 + args.gap * 2 and w[1] == name]
        if hits:
            lats.append((name, (min(hits, key=lambda h: h[0])[0] - t0) * 1000, cmd * 1000))
    if lats:
        print("  resize -> child sees it (%d of %d resizes matched):" % (len(lats), len(stamps)))
        print("    %-9s %8s %8s" % ("size", "lat_ms", "cmd_ms"))
        for name, lat, cmd in lats:
            print("    %-9s %8.1f %8.1f" % (name, lat, cmd))
        lats_only = [l for _, l, _ in lats]
        print("    median %.1f ms  max %.1f ms  total reflow for %d resizes %.0f ms" % (
            sorted(lats_only)[len(lats_only) // 2], max(lats_only), len(lats), sum(lats_only)))
    if relay:
        print("  relay CPU burned during the run: %.3f s" % (cpu1 - cpu0))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--fill", type=int, default=0, help="lines of text to put in the pane first")
    ap.add_argument("--images", type=int, default=0, help="OSC 1337 images to print first")
    ap.add_argument("--throughput", type=int, default=0, help="MB of text the child pushes, timed")
    ap.add_argument("--steps", type=int, default=12, help="resizes to issue")
    ap.add_argument("--gap", type=float, default=0.25, help="seconds between resizes")
    ap.add_argument("--mode", choices=["both", "relay", "plain"], default="both")
    ap.add_argument("--command-time", action="store_true", help="print each tmux call time too")
    ap.add_argument("--probe", default="/tmp/osc-wrap-probe.py")
    args = ap.parse_args()

    if os.uname().sysname != "Linux":
        print("linux only (termios ioctls, tmux, ps)")
        return
    with open(args.probe, "w") as f:
        f.write(PROBE)
    log = "/tmp/osc-wrap-bench.log"
    modes = [True, False] if args.mode == "both" else [args.mode == "relay"]
    for relay in modes:
        run_case(relay, args, log)


if __name__ == "__main__":
    main()
