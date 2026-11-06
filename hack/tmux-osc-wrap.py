#!/usr/bin/env python3
"""Run a program in this pane with its iTerm2 image sequences wrapped for tmux.

    tmux-osc-wrap.py pi                        # wrap only when $TMUX is set
    tmux-osc-wrap.py --force sh -c '...'       # wrap regardless
    tmux-osc-wrap.py --no-force pi             # pass through untouched

Why this exists: tmux 3.6a has no handler for OSC 1337 (input.c contains no reference to 1337, and there is no
kitty graphics support anywhere in the tree), so an image Pi prints straight at a tmux pane is parsed as an OSC
and thrown away - no placeholder, no trace, nothing. tmux does have one door for sequences it is not willing to
interpret itself: a DCS addressed to `tmux;`. A program that is about to print such a sequence can put it
through that door itself.

The spelling, measured in hack/pane-byte-cases.sh and hack/tmux-manpage-dcs-close.sh rather than read off the
man page:

    ESC P  t m u x ;  ESC   <payload with every ESC doubled>   ESC \\

The closing ST is single. tmux/input.c's dcs_escape state table dispatches on ESC followed by backslash and
reads ESC ESC as one literal ESC, so a doubled closing ST is payload, the wrapper never closes, and every byte
the program prints afterwards is swallowed - which looks like a broken terminal rather than a broken image, and
is the reason this file exists in the pane instead of further out.

Everything that is not an OSC 1337 sequence is forwarded byte for byte, including the program's cursor control,
its colours, its resize responses and its newline handling. The relay is a real pty pair, so the program sees a
terminal: window size changes are forwarded, signals are forwarded, and the child gets a controlling terminal.

Where the hold boundary is, and why it is not a timeout gamble: an introducer `ESC ] 1337 ;` is held until its
terminator (BEL or ST) arrives, which is what makes a payload split across ten reads still wrap. Text before a
possible introducer is emitted immediately, except a trailing partial introducer of up to six bytes. A hold that
never terminates is abandoned at 64 MiB by forwarding one byte and rescanning, and an idle stream is flushed
raw after 1.5 s of silence - an unfinished OSC 1337 that has produced no bytes for 1.5 s is not going to
produce an image, and forwarding it raw is exactly what the program would have printed without this script.
"""

import errno
import fcntl
import os
import pty
import select
import signal
import sys
import termios
import tty

INTRO = b"\x1b]1337;"
MAX_HOLD = 64 * 1024 * 1024
IDLE_S = 1.5
READ_SIZE = 65536


def wrap(payload: bytes) -> bytes:
    """The one wrapper spelling tmux 3.6a accepts: intro, doubled payload, single closing ST."""
    return b"\x1bPtmux;\x1b" + payload.replace(b"\x1b", b"\x1b\x1b") + b"\x1b\\"


def terminator(buf: bytearray, start: int) -> int:
    """Index just past the OSC terminator (BEL or ST), or -1 when it has not arrived yet."""
    i = start
    n = len(buf)
    while i < n:
        c = buf[i]
        if c == 0x07:
            return i + 1
        if c == 0x1B:
            if i + 1 < n and buf[i + 1] == 0x5C:
                return i + 2
            # A lone ESC at the very end may be the first half of an ST that has not been read yet.
        i += 1
    return -1


class Rewriter:
    """Streaming wrapper. feed() returns the bytes that are safe to send to the terminal now."""

    def __init__(self, enable=True):
        self.buf = bytearray()
        self.enable = enable

    def _flush_partial(self, out: bytearray):
        # Emit everything except a tail that could still turn out to be the start of an introducer.
        b = self.buf
        keep = 0
        for size in range(min(len(INTRO) - 1, len(b)), 0, -1):
            if b[-size:] == INTRO[:size]:
                keep = size
                break
        out += b[: len(b) - keep]
        del b[: len(b) - keep]

    def feed(self, data: bytes) -> bytes:
        out = bytearray()
        self.buf += data
        while True:
            b = self.buf
            if not b:
                break
            at = b.find(INTRO)
            if at == -1:
                self._flush_partial(out)
                break
            if at > 0:
                out += b[:at]
                del b[:at]
                continue
            end = terminator(b, len(INTRO))
            if end == -1:
                if len(b) > MAX_HOLD:
                    # No terminator in 64 MiB: this is not a well-formed image sequence. Forward one byte and
                    # rescan from there rather than wedging the pane behind a sequence that will not end.
                    out += b[:1]
                    del b[:1]
                    continue
                break  # wait for more of the payload
            payload = bytes(b[:end])
            del b[:end]
            out += wrap(payload) if self.enable else payload
        return bytes(out)

    def idle(self) -> bytes:
        """Nothing has arrived for a while. Whatever is held is not going to complete."""
        out = bytes(self.buf)
        self.buf = bytearray()
        return out


def write_all(fd: int, data: bytes):
    off = 0
    while off < len(data):
        off += os.write(fd, data[off:])


def main():
    argv = sys.argv[1:]
    force = None
    while argv and argv[0] in ("--force", "--no-force"):
        force = argv.pop(0) == "--force"
    if not argv or argv[0] in ("-h", "--help"):
        sys.stderr.write(
            "usage: tmux-osc-wrap.py [--force|--no-force] command [args...]\n"
            "Wraps OSC 1337 image sequences in tmux's passthrough DCS. Enabled only when $TMUX is set unless\n"
            "--force is given, because in a pane without tmux the wrapper is a sequence the outer terminal has\n"
            "no reason to understand.\n"
        )
        sys.exit(0 if argv and argv[0] == "--help" else 2)

    enable = force if force is not None else bool(os.environ.get("TMUX"))

    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        # No terminal to relay: nothing to wrap safely, so run the program as asked.
        sys.stderr.write("tmux-osc-wrap: stdin/stdout is not a tty, running the command unchanged\n")
        os.execvp(argv[0], argv)

    master, slave = pty.openpty()
    try:
        ws = fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0" * 8)
        fcntl.ioctl(master, termios.TIOCSWINSZ, ws)
    except OSError:
        pass

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
            if fd > 2:
                try:
                    os.close(fd)
                except OSError:
                    pass
        os.environ["TMUX_OSC_WRAP"] = "1"
        try:
            os.execvp(argv[0], argv)
        except OSError as exc:
            sys.stderr.write(f"tmux-osc-wrap: cannot run {argv[0]}: {exc}\n")
            os._exit(127)
    os.close(slave)

    saved_in = termios.tcgetattr(0)
    saved_out = termios.tcgetattr(1)
    tty.setraw(0)
    # OPOST off on our own output: the child's pty has already turned \n into \r\n, and the terminal driver
    # translating it a second time would put a stray carriage return in front of every line.
    out_attrs = termios.tcgetattr(1)
    out_attrs[1] &= ~termios.OPOST
    termios.tcsetattr(1, termios.TCSADRAIN, out_attrs)

    state = {"child": child, "winch": False}

    def forward(signum, _frame):
        try:
            os.kill(child, signum)
        except ProcessLookupError:
            pass

    def winch(_signum, _frame):
        state["winch"] = True

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGQUIT, signal.SIGHUP):
        signal.signal(sig, forward)
    signal.signal(signal.SIGWINCH, winch)

    rw = Rewriter(enable)
    closed = False
    while True:
        if state["winch"]:
            state["winch"] = False
            try:
                ws = fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0" * 8)
                fcntl.ioctl(master, termios.TIOCSWINSZ, ws)
            except OSError:
                pass
        try:
            r, _, _ = select.select([0, master], [], [], IDLE_S)
        except OSError as exc:
            if exc.errno == errno.EINTR:
                continue
            raise

        if master in r:
            try:
                data = os.read(master, READ_SIZE)
            except OSError:
                data = b""
            if data:
                out = rw.feed(data)
                if out:
                    write_all(1, out)
                continue
            closed = True
            break
        if 0 in r:
            try:
                data = os.read(0, READ_SIZE)
            except OSError:
                data = b""
            if data:
                write_all(master, data)
                continue
            # The pane's input side closed; the child will usually follow it.
            break
        # select timed out: nothing is moving, so stop holding a partial sequence.
        held = rw.idle()
        if held:
            write_all(1, held)

    tail = rw.idle()
    if tail:
        try:
            write_all(1, tail)
        except OSError:
            pass

    termios.tcsetattr(0, termios.TCSADRAIN, saved_in)
    termios.tcsetattr(1, termios.TCSADRAIN, saved_out)
    try:
        os.close(master)
    except OSError:
        pass
    try:
        _, status = os.waitpid(child, 0)
    except ChildProcessError:
        sys.exit(0)
    if os.WIFEXITED(status):
        sys.exit(os.WEXITSTATUS(status))
    if os.WIFSIGNALED(status):
        sys.exit(128 + os.WTERMSIG(status))
    sys.exit(0)


errno_EINTR = 4  # noqa: E305  (kept out of the relay loop; errno is imported for the real check)


if __name__ == "__main__":
    main()
