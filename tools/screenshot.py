#!/usr/bin/env python3
"""Draw a program's screen in niceemu as a PNG picture.

The program runs in niceemu until it halts, and the 80x25 words of the
screen at 0xFFFF0000 and the cursor's registers at 0xFFFFFF80-82 are drawn
as the text display (src/video/text.vhd) shows them: 1280x800 pixels, the
font of src/video/font_pkg.vhd, each character in 16x32 pixels, and the
colors of 4 bits, each component n as the byte n * 0x11. A cursor that is
shown is drawn on, in the inverted colors, as large as its character or,
when small, its bottom 4 lines. The picture of doc/images/demo.png was
made with:

    make -C demo VERSION=V1.0
    printf 'Hello from the NICE CPU on the MEGA65!\\r' > in.txt
    tools/screenshot.py -i in.txt -o doc/images/demo.png demo/build/demo.bin

and that of doc/images/ethernet.png, the demo's F11, with V1.1 and:

    printf '\\033[23~i192.168.1.66\\rm02:4E:49:43:45:00\\r' > in.txt
    tools/screenshot.py -i in.txt -n 3000000 -o doc/images/ethernet.png \\
        demo/build/demo.bin

Usage:
    tools/screenshot.py [-i FILE] [-n N] [-o FILE.png] FILE.bin

    -i FILE is the console input, as niceemu's -i, and -n N stops the
    program after N steps, as niceemu's --max-steps. The picture goes to
    screen.png, or the file of -o.
"""

import argparse
import os
import re
import struct
import subprocess
import sys
import zlib

REPO    = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NICEEMU = f"{REPO}/nice_cpu/emulator/zig-out/bin/niceemu"
FONT    = f"{REPO}/src/video/font_pkg.vhd"

COLS = 80
ROWS = 25
W    = 16
H    = 32


def load_font():
    """Returns the rows of the glyphs, by 32 * code + row."""
    font = {}
    for m in re.finditer(r'(\d+) => "([01]{16})"', open(FONT).read()):
        font[int(m.group(1))] = int(m.group(2), 2)
    return font


def run(args):
    """Returns the words that niceemu dumps after the program halts."""
    cmd = [NICEEMU, "-d", "0xFFFFFF80:3", "-d", f"0xFFFF0000:{COLS * ROWS}"]
    if args.input:
        cmd += ["-i", args.input]
    if args.max_steps:
        cmd += ["-n", str(args.max_steps)]
    r = subprocess.run(cmd + [args.file], stdin=subprocess.DEVNULL,
                       capture_output=True, text=True)
    if r.returncode not in (0, 3):
        sys.exit(f"screenshot.py: niceemu failed:\n{r.stderr}")
    mem = {}
    for line in r.stdout.splitlines():
        m = re.match(r"([0-9a-f]{8}):((?: [0-9a-f]{8})+)$", line.strip())
        if m:
            addr = int(m.group(1), 16)
            for i, word in enumerate(m.group(2).split()):
                mem[addr + i] = int(word, 16)
    return mem


def color(c):
    return bytes(((c >> s) & 15) * 0x11 for s in (8, 4, 0))


def draw(mem, font):
    """Returns the rows of pixels, 3 bytes each."""
    state, cx, cy = mem[0xFFFFFF80], mem[0xFFFFFF81], mem[0xFFFFFF82]
    lines = []
    for y in range(ROWS * H):
        row, r = divmod(y, H)
        line = bytearray()
        for col in range(COLS):
            word   = mem[0xFFFF0000 + row * COLS + col]
            fg, bg = color(word >> 8), color(word >> 20)
            if (state & 0x40 and (col, row) == (cx, cy)
                    and (not state & 0x10 or r >= H - 4)):
                fg, bg = bg, fg
            glyph = font.get((word & 0xFF) * H + r, 0)
            for x in range(W):
                line += fg if glyph >> (W - 1 - x) & 1 else bg
        lines.append(bytes(line))
    return lines


def write_png(path, lines):
    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data)))
    raw = b"".join(b"\0" + line for line in lines)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", COLS * W, ROWS * H,
                                           8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        f.write(chunk(b"IEND", b""))


def main():
    p = argparse.ArgumentParser(
        description="Draw a program's screen in niceemu as a PNG picture.")
    p.add_argument("-i", "--input", help="the console input, as niceemu's -i")
    p.add_argument("-n", "--max-steps", type=int,
                   help="stop after N steps, as niceemu's --max-steps")
    p.add_argument("-o", "--output", default="screen.png",
                   help="the picture (default: screen.png)")
    p.add_argument("file", help="the program, a .bin file")
    args = p.parse_args()
    if not os.path.exists(NICEEMU):
        sys.exit(f"screenshot.py: {NICEEMU} is missing; run "
                 "make -C nice_cpu/emulator build")
    write_png(args.output, draw(run(args), load_font()))


if __name__ == "__main__":
    main()
