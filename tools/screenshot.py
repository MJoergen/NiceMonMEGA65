#!/usr/bin/env python3
"""Draw a program's screen in niceemu as a PNG picture.

The program runs in niceemu until it halts, and the 80x25 words of the
screen at 0xFFFF0000 and the cursor's registers at 0xFFFFFF80-82 are drawn
as the text display (src/video/text.vhd) shows them: 1280x800 pixels, the
font of src/video/font_pkg.vhd, each character in 16x32 pixels, and the
colors of 4 bits, each component n as the byte n * 0x11. A cursor that is
shown is drawn on, in the inverted colors, as large as its character or,
when small, its bottom 4 lines.

With --debugger, the strip of the on-board debugger (doc/DEBUGGER.md) is
drawn under the screen, 4 rows more, as MEGA+HELP shows it at the stop:
R0-R15; the state, PAUSED at the step limit of -n, as after F5, or HALTED
with its reason; the PC, the instruction word there, and the flags of
R14; the instruction decoded, as nicedis writes it; and the keys. The
rows are laid out as src/dbg/dbg.vhd writes them. niceemu runs the
program twice, the second time to read the words at the PC.

The pictures of doc/images/ are made from the demo of the release, with
its tag:

    make -C demo VERSION=V1.1
    printf 'Hello from the NICE CPU on the MEGA65!\\r' > in.txt
    tools/screenshot.py -i in.txt -o doc/images/demo.png demo/build/demo.bin

doc/images/ethernet.png, the demo's F11, with:

    printf '\\033[23~i192.168.1.65\\rm02:4E:49:43:45:00\\r' > in.txt
    tools/screenshot.py -i in.txt -n 3000000 -o doc/images/ethernet.png \\
        demo/build/demo.bin

and doc/images/debugger.png, the typewriter paused under the strip once
the line of the first in.txt is typed, with:

    tools/screenshot.py -i in.txt -n 10600 --debugger \\
        -o doc/images/debugger.png demo/build/demo.bin

Usage:
    tools/screenshot.py [-i FILE] [-n N] [--debugger] [-o FILE.png] FILE.bin

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

sys.path.insert(0, f"{REPO}/nice_cpu/assembler")
import nicedis  # noqa: E402

COLS = 80
ROWS = 25
W    = 16
H    = 32

# The strip: its colors and the layout of its rows, dbg.vhd's C_COLOR,
# C_COL_*, and C_STATE_LEN. The flags are bits 25 to 31 of R14.
STRIP_COLOR = 0x004FFF
COL_STATE, COL_PC, COL_INSTR, COL_FLAGS, COL_DEC = 1, 10, 20, 30, 46
STATE_LEN  = 9
DEC_LEN    = COLS - COL_DEC
FLAG_CHARS = "XCZNVEI"
KEYS_ROW   = (" F1 step  F3 go  F5 pause  F7 hold  F9 restart  F11 page"
              "  F12 keep strip: off")
# niceemu's halt reasons, and their numbers in DEBUG.md section 6
HALT_REASONS = {"HALT": 1, "reserved control instruction": 2,
                "INT inside an interrupt routine": 3,
                "RTI outside an interrupt routine": 4}


def load_font():
    """Returns the rows of the glyphs, by 32 * code + row."""
    font = {}
    for m in re.finditer(r'(\d+) => "([01]{16})"', open(FONT).read()):
        font[int(m.group(1))] = int(m.group(2), 2)
    return font


def run(args, dumps=()):
    """Runs the program; returns the words that niceemu dumps, R0-R15, and
    the stop: ("PAUSED", 0) at the step limit, or ("HALTED", reason)."""
    cmd = [NICEEMU, "-d", "0xFFFFFF80:3", "-d", f"0xFFFF0000:{COLS * ROWS}"]
    for d in dumps:
        cmd += ["-d", d]
    if args.input:
        cmd += ["-i", args.input]
    if args.max_steps:
        cmd += ["-n", str(args.max_steps)]
    r = subprocess.run(cmd + [args.file], stdin=subprocess.DEVNULL,
                       capture_output=True, text=True)
    if r.returncode not in (0, 3):
        sys.exit(f"screenshot.py: niceemu failed:\n{r.stderr}")
    mem, regs, stop = {}, {}, None
    for line in r.stdout.splitlines():
        m = re.match(r"([0-9a-f]{8}):((?: [0-9a-f]{8})+)$", line.strip())
        if m:
            addr = int(m.group(1), 16)
            for i, word in enumerate(m.group(2).split()):
                mem[addr + i] = int(word, 16)
        for m in re.finditer(r"\bR(\d+) +([0-9a-f]{8})\b", line):
            regs[int(m.group(1))] = int(m.group(2), 16)
        m = re.match(r"Halted \((.*)\) after", line)
        if m:
            if m.group(1) not in HALT_REASONS:
                sys.exit(f"screenshot.py: unknown halt reason {m.group(1)!r}")
            stop = ("HALTED", HALT_REASONS[m.group(1)])
        if line.startswith("Stopped at the step limit"):
            stop = ("PAUSED", 0)
    return mem, [regs.get(i, 0) for i in range(16)], stop


def screen_rows(mem):
    """The 25 rows of the screen, each the 80 words of its characters."""
    return [[mem[0xFFFF0000 + row * COLS + col] for col in range(COLS)]
            for row in range(ROWS)]


def strip_rows(regs, stop, mem):
    """The 4 rows of the strip at a stop, as dbg.vhd writes them: R0-R15,
    the state, the PC, the word there, the flags, the decode, and the keys."""
    if stop is None:
        sys.exit("screenshot.py: the program did not stop; give -n N")
    rows = [[" "] * COLS for _ in range(4)]

    def put(row, col, text):
        for i, ch in enumerate(text):
            rows[row][col + i] = ch

    put(0, 0, " R0-7")
    put(1, 0, " R8-15")
    for i in range(16):
        put(i // 8, 8 + 9 * (i % 8), f"{regs[i]:08X}")
    state, code = stop
    name = state.ljust(STATE_LEN)
    if state == "HALTED":
        name = name[:7] + f"{code:X}" + name[8:]
    put(2, COL_STATE, name)
    pc = regs[15]
    put(2, COL_PC, f"{pc:08X}")
    put(2, COL_INSTR, f"{mem[pc]:08X}")
    for i, ch in enumerate(FLAG_CHARS):
        put(2, COL_FLAGS + 2 * i, ch if regs[14] >> (25 + i) & 1 else ".")
    insn = nicedis.decode(pc, mem.get)
    text = "reserved" if insn.reserved else nicedis.statement(insn, lambda v: None)
    if len(text) > DEC_LEN:
        text = text[:DEC_LEN - 1] + ">"
    put(2, COL_DEC, text)
    put(3, 0, KEYS_ROW)
    return [[STRIP_COLOR << 8 | ord(ch) for ch in row] for row in rows]


def color(c):
    return bytes(((c >> s) & 15) * 0x11 for s in (8, 4, 0))


def draw(rows, cursor, font):
    """Returns the rows of pixels, 3 bytes each, of the rows of words, with
    the cursor (state, x, y) of the screen's registers drawn on."""
    state, cx, cy = cursor
    lines = []
    for y in range(len(rows) * H):
        row, r = divmod(y, H)
        line = bytearray()
        for col in range(COLS):
            word   = rows[row][col]
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
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", COLS * W, len(lines),
                                           8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        f.write(chunk(b"IEND", b""))


def main():
    p = argparse.ArgumentParser(
        description="Draw a program's screen in niceemu as a PNG picture.")
    p.add_argument("-i", "--input", help="the console input, as niceemu's -i")
    p.add_argument("-n", "--max-steps", type=int,
                   help="stop after N steps, as niceemu's --max-steps")
    p.add_argument("--debugger", action="store_true",
                   help="draw the on-board debugger's strip under the screen")
    p.add_argument("-o", "--output", default="screen.png",
                   help="the picture (default: screen.png)")
    p.add_argument("file", help="the program, a .bin file")
    args = p.parse_args()
    if not os.path.exists(NICEEMU):
        sys.exit(f"screenshot.py: {NICEEMU} is missing; run "
                 "make -C nice_cpu/emulator build")
    mem, regs, stop = run(args)
    rows = screen_rows(mem)
    if args.debugger:
        # The instruction at the PC and its constant words, in a second run
        mem, regs, stop = run(args, [f"0x{regs[15]:X}:4"])
        rows += strip_rows(regs, stop, mem)
    cursor = (mem[0xFFFFFF80], mem[0xFFFFFF81], mem[0xFFFFFF82])
    write_png(args.output, draw(rows, cursor, load_font()))


if __name__ == "__main__":
    main()
