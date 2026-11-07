#!/usr/bin/env python3
"""Make the small test images the terminal probes print.

A 160x80 half-red half-blue flag is for looking at with human eyes. A 10x10 solid red square is for the
byte-level experiments, where the point is the escape sequence around the image rather than the image
itself. Keeping them tiny means a byte capture is readable.
"""
import os
import struct
import zlib


def chunk(tag, data):
    out = tag + data
    return struct.pack(">I", len(data)) + out + struct.pack(">I", zlib.crc32(out) & 0xFFFFFFFF)


def png(path, width, height, pattern):
    # The probes that read these files assume /tmp/image-test; a freshly started container has no such directory
    # and a probe that cannot make its own fixture is a probe that skips the check it was written for.
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    rows = b""
    for y in range(height):
        row = b""
        for x in range(width):
            if pattern == "flag":
                if x % 40 < 10 or x % 40 >= 30:
                    row += bytes((200, 30, 30))
                elif 12 <= y < 18:
                    row += bytes((250, 250, 250))
                else:
                    row += bytes((30, 60, 200))
            else:
                row += bytes((200, 30, 30))
        rows += b"\x00" + row
    data = (b"\x89PNG\r\n\x1a\n" +
            chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(rows, 6)) +
            chunk(b"IEND", b""))
    open(path, "wb").write(data)
    return data


if __name__ == "__main__":
    for path, width, height, pattern in (
        ("/tmp/image-test/flag.png", 160, 80, "flag"),
        ("/tmp/image-test/tiny.png", 10, 10, "solid"),
    ):
        data = png(path, width, height, pattern)
        print(f"{path}: {len(data)} bytes, {width}x{height}")
