#!/usr/bin/env python3
"""Wrap a file's terminal output in tmux's passthrough DCS and print it on stdout.

    wrap-tmux-dcs.py <file>            reads the file
    wrap-tmux-dcs.py -                 reads stdin

tmux hands the wrapped bytes to whatever is attached to the pane instead of parsing them itself, which is the
only way a sequence tmux would otherwise discard can reach the outer terminal. Inside the wrapper every escape
byte has to be doubled so tmux's parser does not mistake an inner sequence for the end of the wrapper. The one
escape that must NOT be doubled is the one closing the wrapper itself: tmux 3.6 ends a DCS at a single
ESC-backslash pair and never at the doubled pair the manual describes, measured in
hack/tmux-manpage-dcs-close.sh. Doubling the terminator is the failure that swallows everything a program
prints after its image, so the rule is stated in bytes rather than prose:

    b"\\x1bPtmux;\\x1b" + payload.replace(b"\\x1b", b"\\x1b\\x1b") + b"\\x1b\\"

See tools/tmux-osc-wrap.py for the same rule applied to a program that is still running.
"""
import sys


def wrap(payload: bytes) -> bytes:
    return b"\x1bPtmux;\x1b" + payload.replace(b"\x1b", b"\x1b\x1b") + b"\x1b\\"


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    data = sys.stdin.buffer.read() if argv[1] == "-" else open(argv[1], "rb").read()
    sys.stdout.buffer.write(wrap(data))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
