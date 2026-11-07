#!/usr/bin/env python3
"""Run a program in a pty of a stated size and log everything it prints, without touching this terminal.

Used by hack/live-pi-wrap.sh: the relay has to run attached to a tmux client in a pty whose size is known, and
what it emits has to be captured rather than printed into somebody's pane. The forking is spelled out by hand
rather than using pty.spawn(), because pty.spawn() also relays the pty to *this* process's own stdin and stdout,
which is exactly the thing a measurement harness must not do - it smears a redraw across the terminal that is
trying to report on it.
"""
import argparse
import fcntl
import os
import pty
import select
import struct
import sys
import termios

ap = argparse.ArgumentParser()
ap.add_argument("--cols", type=int, default=160)
ap.add_argument("--rows", type=int, default=52)
ap.add_argument("--log", default="/tmp/pty-bytes.bin")
ap.add_argument("--seconds", type=float, default=30.0, help="how long to keep reading, counting from the last output")
ap.add_argument("command", nargs=argparse.REMAINDER)
a = ap.parse_args()
if a.command[:1] == ["--"]:
    a.command = a.command[1:]
if not a.command:
    sys.exit("pty-drive.py: no command given")

master, slave = pty.openpty()
fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", a.rows, a.cols, 0, 0))

child = os.fork()
if child == 0:
    os.setsid()
    try:
        fcntl.ioctl(slave, termios.TIOCSCTTY, 1)
    except OSError:
        pass
    for fd in (0, 1, 2):
        os.dup2(slave, fd)
    for fd in (master, slave):
        try:
            os.close(fd)
        except OSError:
            pass
    try:
        os.execvp(a.command[0], a.command)
    except OSError as exc:
        sys.stderr.write(f"pty-drive: cannot run {a.command[0]}: {exc}\n")
        os._exit(127)
os.close(slave)

log = open(a.log, "wb")
left = a.seconds
while True:
    r, _, _ = select.select([master], [], [], left)
    if not r:
        break
    try:
        data = os.read(master, 65536)
    except OSError:
        break
    if not data:
        break
    log.write(data)
    log.flush()
    left = 3.0  # the first wait covers the program starting; after that, a short idle means it is done

log.close()
try:
    os.kill(child, 15)
except ProcessLookupError:
    pass
