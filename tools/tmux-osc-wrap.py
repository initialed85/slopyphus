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

After an image the relay prints blank rows, and that is a separate fix from the wrapper. xterm.js draws an OSC
1337 image in its image layer, anchored at the cursor cell, and does not move the cursor: OSC carries no cursor
semantics, and `addon-image` -- the handler ttyd's client registers for OSC 1337 (`index.ts` loads `ImageAddon`,
which registers itself as the OSC 1337 osc handler) -- only calls `ImageStorage.addImage`, so the picture floats
over whatever rows it covers while the program that printed it is still where it was. The next line that program
prints lands on top of the picture. tmux cannot help: the wrapped sequence is written to whoever is looking and
never enters the pane's grid, so the pane itself believes those rows are empty. The relay reserves the rows an
image occupies by printing them as ordinary blank lines, which advances the browser's cursor and the pane's grid
together.

The row count mirrors the arithmetic the addon itself does rather than guessing at a layout. `addon-image`
reads `width`/`height` as `N` cells, `Npx`, `N%` or `auto` (`IIPHeaderParser.toSize`), resolves them in
`IIPHandler._resize`, and with `preserveAspectRatio` defaulting to 1 the width wins and the height is recomputed
from the image's own aspect ratio. Doing the same arithmetic in cells makes the pixel scale cancel:

    width=N cells, height=auto  ->  rows = ceil(N * ratio * img_h / img_w)
    width=auto, height=auto     ->  rows = min(cols * ratio * img_h / img_w, pane_rows - 1)
    height=N cells, aspect off  ->  rows = N

where `ratio` is a cell's width divided by its height. That is the one quantity a pane cannot report about
itself: a pty reports cells, not pixels. It comes from the environment (`OSC_WRAP_CELL_RATIO`) so a viewer that
disagrees can say so, and the `Npx` / `N%` spellings additionally need a cell height in CSS pixels
(`OSC_WRAP_CELL_HEIGHT_PX`), which is a stated assumption about whoever is looking rather than a measurement.
An image whose format the relay cannot read reserves nothing, which is the behaviour from before this fix rather
than a wrong guess.

It can also name the pictures it passes. `--anchor` writes each image under the pane's own working directory and
prints a dim line of text - `[[img:<10 hex>]]` - on the row below the space it reserved. That line is the point:
tmux's grid holds cells and stores no copy of an inline image, so every repaint (a wheel scroll, a pane resize, a
pane menu, a client reattach) erases a picture that was only ever a burst of bytes, while a line of text survives
all of them. The browser side is what turns the line back into the picture; until it exists the flag stays off,
because an anchor nobody understands is just text in someone's transcript.
"""

import base64
import errno
import fcntl
import hashlib
import math
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import tty

INTRO = b"\x1b]1337;"
MAX_HOLD = 64 * 1024 * 1024
IDLE_S = 1.5
READ_SIZE = 65536

# The two quantities a pane cannot report about itself: the aspect of one cell, and how tall a cell is in CSS
# pixels. Both come from the environment so a viewer that disagrees can say so.
#
# The defaults are measured, not guessed, for the stack this repository ships (measured 2026-11-07 with
# hack/image-cases.sh + hack/image-rows-report.py against ttyd's own xterm.js client at its default font:
# a 160x52 grid in a 1120x780 viewport, so 7.00px x 15.00px per cell, ratio 0.467 bare and 0.458 under tmux,
# and an image asking for width=80 cells drawn 560x280px, which is 80 x 7.00px and 18.7 rows tall). The ratio
# is rounded up to 0.5 deliberately: the error that matters is the one where text lands on top of the picture,
# and a reservation that is one or two rows too generous only leaves a gap. A front-end that sets a different
# font size changes the ratio, and can say so with OSC_WRAP_CELL_RATIO rather than being wrong.
CELL_RATIO = float(os.environ.get("OSC_WRAP_CELL_RATIO", "0.5"))
CELL_HEIGHT_PX = float(os.environ.get("OSC_WRAP_CELL_HEIGHT_PX", "15"))
RESERVE = os.environ.get("OSC_WRAP_RESERVE", "on").lower() not in ("off", "0", "no")

# Whether the relay also names the pictures it passes: save the bytes under the pane's own working directory and
# print the anchor line that says where the picture belongs. Off by default until the browser side understands the
# naming, because an anchor nothing understands is just a line of text in someone's transcript. Saving and
# anchoring are one switch on purpose - a file with no anchor is a picture nothing will ever ask for.
ANCHOR = os.environ.get("OSC_WRAP_ANCHOR", "off").lower() not in ("off", "0", "no")
# Relative to the relay's working directory, which is the pane's: ttyd starts the pane with -w /workspace/$NAME
# and the relay inherits that, so this lands beside the directory a browser paste writes into. Same place, same
# meaning: pictures belonging to this pane.
IMAGES_DIR = os.environ.get("OSC_WRAP_IMAGES_DIR", ".slopyphus/images")
IMAGE_KEEP = int(os.environ.get("OSC_WRAP_IMAGE_KEEP", "200"))


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

    def __init__(self, enable=True, reserve=RESERVE, anchor=ANCHOR, term_size=(80, 24)):
        self.buf = bytearray()
        self.enable = enable
        self.reserve = reserve
        self.anchor = anchor
        self.term_size = term_size
        self.stats = {"images": 0, "rows": 0, "anchors": 0}

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
            if self.reserve:
                cols, rows = self.term_size
                n = reserve_rows(payload, cols, rows)
                if n:
                    # Deliberately outside the wrapper. A newline tmux parses is a newline the pane's own grid
                    # keeps, which is what keeps the rows under a picture consistent when the pane redraws;
                    # inside the wrapper they would reach only whoever is looking.
                    out += reserve_newlines(n)
                    self.stats["images"] += 1
                    self.stats["rows"] += n
                    if self.anchor:
                        # An anchor is only worth printing when the room the picture needs is also known. An
                        # anchor the browser cannot size is a picture drawn over somebody's text.
                        raw, kind = decode_image(payload)
                        digest = save_image(raw, kind) if raw else ""
                        if digest:
                            out += anchor_line(digest)
                            self.stats["anchors"] += 1
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


def pane_size(fd: int = 0) -> tuple:
    """(cols, rows) of the terminal being printed into, for the row reservation. 80x24 if it cannot ask."""
    try:
        ws = fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\0" * 8)
        rows, cols = struct.unpack("hhhh", ws)[:2]
        if rows > 0 and cols > 0:
            return (cols, rows)
    except OSError:
        pass
    return (80, 24)


# --- how much of the screen one image will cover ------------------------------------------------------


def header_fields(payload: bytes) -> dict:
    """The `File=key=value;...` part of an OSC 1337 image, as strings.

    Split on the first colon only: `name=` is base64 so it carries no colon, and the addon stops parsing at that
    same first colon, so the two parsers see the same header.
    """
    body = payload[2:]  # drop ESC ]
    if not body.startswith(b"1337;File="):
        return {}
    head = body.split(b":", 1)[0]
    fields = {}
    for chunk in head[len(b"1337;File="):].split(b";"):
        if b"=" not in chunk:
            continue
        key, value = chunk.split(b"=", 1)
        fields[key.decode("latin-1")] = value.decode("latin-1")
    return fields


def image_dimensions(payload: bytes):
    """Inherent pixel size of the image in an OSC 1337 payload, or None when it cannot be read.

    Only the first 2 KB of base64 is decoded, which covers the header of every format handled here: PNG's IHDR,
    JPEG's start-of-frame, GIF's logical screen descriptor, BMP's DIB header.
    """
    body = payload[2:]
    at = body.find(b":")
    if at == -1:
        return None
    blob = body[at + 1:]
    end = 0
    while end < len(blob) and blob[end] not in (0x07, 0x1B):
        end += 1
    head = blob[: min(end, 2048)]
    trimmed = len(head) - (len(head) % 4)
    if trimmed < 8:
        return None
    try:
        raw = base64.b64decode(head[:trimmed], validate=False)
    except Exception:
        return None
    if len(raw) < 26:
        return None
    if raw[:8] == b"\x89PNG\r\n\x1a\n" and raw[12:16] == b"IHDR":
        w, h = struct.unpack(">II", raw[16:24])
        return (w, h)
    if raw[:6] in (b"GIF87a", b"GIF89a"):
        w, h = struct.unpack("<HH", raw[6:10])
        return (w, h)
    if raw[:2] == b"BM":
        w, h = struct.unpack("<ii", raw[18:26])
        return (abs(w), abs(h))
    if raw[:2] == b"\xff\xd8":
        # Walk the segments looking for a start-of-frame. SOF0..SOF3 carry the frame size; SOF4..SOF6 and the
        # DHT/DQT/DAC markers are skipped with the same length-field hop, and the standalone markers have no
        # length field at all.
        i = 2
        while i + 9 < len(raw):
            if raw[i] != 0xFF:
                i += 1
                continue
            marker = raw[i + 1]
            if 0xC0 <= marker <= 0xC3:
                h, w = struct.unpack(">HH", raw[i + 5: i + 9])
                return (w, h)
            if marker == 0x01 or marker == 0xD8 or 0xD0 <= marker <= 0xD7:
                i += 2
                continue
            seg_len = struct.unpack(">H", raw[i + 2: i + 4])[0]
            i += 2 + seg_len
        return None
    return None


def _dim(value, total_cells, cell_px):
    """Resolve one size field the way IIPHandler._dim does: cells, px, percent of the pane, or auto (0)."""
    if not value or value == "auto":
        return 0.0
    if value.endswith("%"):
        try:
            return float(value[:-1]) * total_cells * cell_px / 100.0
        except ValueError:
            return 0.0
    if value.endswith("px"):
        try:
            return float(value[:-2])
        except ValueError:
            return 0.0
    try:
        return float(value) * cell_px
    except ValueError:
        return 0.0


def reserve_rows(payload: bytes, cols: int, rows: int, ratio=CELL_RATIO, cell_px=CELL_HEIGHT_PX) -> int:
    """How many pane rows the image in this payload covers, mirroring addon-image's own resize arithmetic."""
    fields = header_fields(payload)
    if not fields:
        return 0
    dims = image_dimensions(payload)
    if not dims:
        return 0
    img_w, img_h = dims
    if img_w <= 0 or img_h <= 0:
        return 0

    cell_w = ratio * cell_px
    canvas_w = cols * cell_w
    canvas_h = rows * cell_px
    w_px = _dim(fields.get("width", "auto"), cols, cell_w)
    h_px = _dim(fields.get("height", "auto"), rows, cell_px)
    keep_aspect = int(fields.get("preserveAspectRatio", "1") or "1") != 0

    if not w_px and not h_px:
        # Both auto: the addon scales to fit the whole canvas, and its height formula keeps one row for the
        # cursor offset -- `(canvas_h - ch) / h` in IIPHandler._resize.
        drawn_h = img_h * min(canvas_w / img_w, (canvas_h - cell_px) / img_h)
    elif w_px and (keep_aspect or not h_px):
        drawn_h = img_h * w_px / img_w
    else:
        drawn_h = h_px
    if drawn_h <= 0:
        return 0
    return max(1, min(rows, int(math.ceil(drawn_h / cell_px))))


def reserve_newlines(n: int) -> bytes:
    """Blank rows, printed the way any other output is printed, so the pane's grid advances along with them."""
    return b"\r\n" * max(0, n)


def image_kind(raw: bytes) -> str:
    """Name an image by its magic bytes. The set here is the set image_dimensions can measure the size of."""
    if raw[:8] == b"\x89PNG\r\n\x1a\n":
        return "png"
    if raw[:6] in (b"GIF87a", b"GIF89a"):
        return "gif"
    if raw[:2] == b"BM":
        return "bmp"
    if raw[:2] == b"\xff\xd8":
        return "jpg"
    return ""


def decode_image(payload: bytes):
    """The whole base64 of an OSC 1337 File= sequence as bytes, plus its format name, or (b"", "").

    image_dimensions reads only the first 2 KB of base64 because the row reservation only needs the header. Keeping
    a picture needs all of it, and the same scan for the terminator is deliberate: it is how the two halves of this
    file decide where the payload ends.
    """
    body = payload[2:]
    at = body.find(b":")
    if at == -1:
        return b"", ""
    blob = body[at + 1:]
    end = 0
    while end < len(blob) and blob[end] not in (0x07, 0x1B):
        end += 1
    try:
        raw = base64.b64decode(blob[:end], validate=False)
    except Exception:
        return b"", ""
    kind = image_kind(raw)
    return (raw, kind) if kind else (b"", "")


def save_image(raw: bytes, kind: str) -> str:
    """Write the picture under the pane's own working directory and return the id its anchor carries.

    The name is a prefix of the content hash, so the same picture read twice is one file, a viewer can cache it
    forever, and nothing here needs a database or a manifest. Only files this function wrote are ever pruned.
    """
    digest = hashlib.sha256(raw).hexdigest()[:10]
    name = f"{digest}.{kind}"
    path = os.path.join(IMAGES_DIR, name)
    try:
        os.makedirs(IMAGES_DIR, mode=0o700, exist_ok=True)
        if os.path.exists(path):
            os.utime(path, None)  # a refresh counts as use, so the retained set is the most recent one
        else:
            with open(path, "wb") as handle:
                handle.write(raw)
            prune_images()
    except OSError as exc:
        sys.stderr.write(f"tmux-osc-wrap: could not save {name}: {exc}\n")
        return ""
    return digest


def prune_images():
    """Keep the newest IMAGE_KEEP pictures and drop the rest, oldest first. Only names this relay wrote."""
    pattern = re.compile(r"[0-9a-f]{10}\.(png|gif|bmp|jpg)\Z")
    try:
        names = [n for n in os.listdir(IMAGES_DIR) if pattern.fullmatch(n)]
        stat = sorted((os.stat(os.path.join(IMAGES_DIR, n)).st_mtime, n) for n in names)
    except OSError:
        return
    for _mtime, name in stat[: max(0, len(stat) - IMAGE_KEEP)]:
        try:
            os.remove(os.path.join(IMAGES_DIR, name))
        except OSError:
            pass


def anchor_line(digest: str) -> bytes:
    """Where a picture belongs, written as ordinary text so tmux keeps it.

    tmux's grid stores cells. `capture-pane -p -e` on a pane that has just drawn an inline image reports zero
    copies of it in the pane's history, so every repaint is destructive: `WheelUpPane -> copy-mode -e` reprints a
    history slice, a resize reprints the pane, `MouseDown3Pane`'s display-menu draws over it, a reattach reprints
    for the new client. Only the application re-emitting the bytes restores the picture, which is the "sometimes it
    comes back" behaviour the row reservation alone could not fix.

    A line of text is the one thing that survives all of that, so the record is text: dimmed so it reads as a
    marker rather than as content, on the row immediately below the reserved ones, carrying the id of the saved
    file. The browser draws the picture in the reserved rows above it, sized the way reserve_rows sized them here.
    """
    return b"\x1b[2m[[img:" + digest.encode("ascii") + b"]]\x1b[0m\r\n"


def main():
    argv = sys.argv[1:]
    force = None
    reserve = RESERVE
    anchor = ANCHOR
    while argv and argv[0] in ("--force", "--no-force", "--no-reserve", "--anchor", "--no-anchor"):
        arg = argv.pop(0)
        if arg == "--no-reserve":
            reserve = False
        elif arg == "--anchor":
            anchor = True
        elif arg == "--no-anchor":
            anchor = False
        else:
            force = arg == "--force"
    if not argv or argv[0] in ("-h", "--help"):
        sys.stderr.write(
            "usage: tmux-osc-wrap.py [--force|--no-force] [--no-reserve] [--anchor|--no-anchor] command [args...]\n"
            "Wraps OSC 1337 image sequences in tmux's passthrough DCS. Enabled only when $TMUX is set unless\n"
            "--force is given, because in a pane without tmux the wrapper is a sequence the outer terminal has\n"
            "no reason to understand. After an image it prints blank rows for the rows the picture covers,\n"
            "because xterm.js does not move the cursor for an inline image; --no-reserve turns that off.\n"
            "--anchor additionally saves each picture under the pane's working directory and prints the text line\n"
            "that records where it belongs; off until the browser side reads those lines.\n"
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

    rw = Rewriter(enable, reserve=reserve, anchor=anchor, term_size=pane_size())
    closed = False
    while True:
        if state["winch"]:
            state["winch"] = False
            try:
                ws = fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0" * 8)
                fcntl.ioctl(master, termios.TIOCSWINSZ, ws)
                rw.term_size = pane_size()
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
