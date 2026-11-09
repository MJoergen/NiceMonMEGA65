#!/usr/bin/env python3
"""Check the monitor's scrollback ring in niceemu at the sizes of the
screen's memory of the boards.

Usage: test/ring.py NICEEMU MONITOR.bin:WORDS ...

Each MONITOR.bin is the monitor of the tests, built to take WORDS as the
size of the screen's memory (Makefile): 32768, as niceemu and the MEGA65
have it, 8192, as the Nexys4DDR has, and 2048, which leaves no room for
the history. For each, the monitor runs with d 8000 N, for an N whose
rows fill part of the history and one whose rows go round its ring, and
with Page Up more times than there are rows back, then the same and
three Page Downs, then the same and five cursor keys up and two down, a
row each, then the same and v, which shows the screen again.
niceemu has no display offset, so the rows that a board would show are
read from the dump of the screen's memory, at the offset the monitor
set, modulo WORDS. They must be the rows of the console output, which
the screen shows too, as many rows back as V_BACK says. V_HSIZE, V_HCAP,
V_HCOUNT, and V_BACK are checked against WORDS and the number of rows.
The runs end at niceemu's step limit, as the monitor waits for a key.
Exits with status 1 when a check fails. Only the Python standard library
is used.
"""

import re
import subprocess
import sys
import tempfile

SCREEN = 0xFFFF0000
VARS = 0xFFFFF000
SCR_CTL = 0xFFFFFF80
SCR_OFFS = 0xFFFFFF85
ROWS, COLS = 25, 80
PAGE = 24                   # the rows of a Page Up (monitor.nasm, PAGE)
HIST_SHOWN = 0x400          # SCR_CTL while the history is shown
PAGE_UP, PAGE_DOWN = b"\x1b[5~", b"\x1b[6~"
UP, DOWN = b"\x1b[A", b"\x1b[B"   # a row each
STEPS = 20_000_000
# The d counts for each size: one whose rows leave part of the history
# empty, and one whose rows go round the ring
COUNTS = {32768: [0x100, 0x800], 8192: [0x100, 0x200], 2048: [0x100]}

failed = False


def check(name: str, ok: bool, detail: str = "") -> None:
    global failed
    print(f"[{'PASS' if ok else 'FAIL'}] {name}"
          + (f": {detail}" if not ok else ""))
    failed = failed or not ok


def run(emu: str, monitor: str, words: int, keys: bytes,
        tmp: str) -> tuple[list[str], dict[int, int]]:
    """Runs the monitor with the keys, and returns the rows of the console
    output, the last the line being typed, and the dumped words: the
    variables, the screen's registers, and the screen's memory."""
    path = f"{tmp}/keys.txt"
    with open(path, "wb") as f:
        f.write(keys)
    out = subprocess.run([emu, "-n", str(STEPS), "-i", path,
                          "-d", f"0x{VARS:X}:12", "-d", f"0x{SCR_CTL:X}:6",
                          "-d", f"0x{SCREEN:X}:{words}", monitor],
                         capture_output=True, text=True).stdout
    # niceemu's report of the step limit follows the line being typed,
    # and the registers follow it; the dumps come last
    text, mem, ended = [], {}, False
    for line in out.split("\n"):
        m = re.match(r"^([0-9a-f]{8}):((?: [0-9a-f]{8})+)$", line)
        if m:
            addr = int(m.group(1), 16)
            for i, w in enumerate(m.group(2).split()):
                mem[addr + i] = int(w, 16)
        elif not ended:
            line = line.replace("\r", "")
            end = line.find("Stopped at the step limit")
            if end >= 0:
                line, ended = line[:end], True
            text.append(line)
    return text, mem


def shown(mem: dict[int, int], words: int) -> list[str]:
    """The rows a board shows: the 2000 words from the display offset, if
    it is on, modulo the size of the memory, with a blank for a word that
    is no printable character."""
    offset = mem[SCR_OFFS] if mem[SCR_CTL] & HIST_SHOWN else 0
    rows = []
    for r in range(ROWS):
        chars = (mem.get(SCREEN + (offset + COLS * r + c) % words, 0) & 0xFF
                 for c in range(COLS))
        rows.append("".join(chr(ch) if 0x20 <= ch < 0x7F else " "
                            for ch in chars).rstrip())
    return rows


def expected(text: list[str], back: int) -> list[str]:
    """The rows of the console output that the screen shows, back rows
    back from its last 25."""
    first = len(text) - ROWS - back
    return [text[i].rstrip() if i >= 0 else ""
            for i in range(first, first + ROWS)]


def test(emu: str, monitor: str, words: int, tmp: str) -> None:
    hcap = max(0, (words - 2000) // COLS)
    for count in COUNTS[words]:
        base = f"d 8000 {count:X}\r".encode()
        ups = PAGE_UP * 20
        downs = ups + PAGE_DOWN * 3
        rows = downs + UP * 5 + DOWN * 2
        stages = [("20 Page Ups", base + ups),
                  ("20 Page Ups and 3 Page Downs", base + downs),
                  ("then 5 ups and 2 downs", base + rows),
                  ("then v", base + rows + b"v\r")]
        want_back = 0
        for i, (name, keys) in enumerate(stages):
            text, mem = run(emu, monitor, words, keys, tmp)
            v = [mem.get(VARS + j, -1) for j in range(12)]
            hsize, hcap_got, hcount, back = v[5], v[6], v[8], v[9]
            scrolled = max(0, len(text) - ROWS)
            if i == 0:
                want_back = min(20 * PAGE, min(scrolled, hcap))
            elif i == 1:
                want_back = max(0, want_back - 3 * PAGE)
            elif i == 2:
                want_back = min(want_back + 5, min(scrolled, hcap))
                want_back = max(0, want_back - 2)
            else:
                want_back = 0
            what = f"{words} words, d 8000 {count:X}, {name}"
            check(f"{what}: V_HSIZE {words}, V_HCAP {hcap}",
                  (hsize, hcap_got) == (words, hcap),
                  f"got {hsize}, {hcap_got}")
            check(f"{what}: V_HCOUNT {min(scrolled, hcap)} of {scrolled} rows "
                  f"scrolled", hcount == min(scrolled, hcap), f"got {hcount}")
            check(f"{what}: V_BACK {want_back}", back == want_back,
                  f"got {back}")
            on = bool(mem[SCR_CTL] & HIST_SHOWN)
            check(f"{what}: the history {'shown' if want_back else 'left'}",
                  on == (want_back > 0),
                  f"SCR_CTL {mem[SCR_CTL]:08X}, SCR_OFFS {mem[SCR_OFFS]}")
            got, want = shown(mem, words), expected(text, back)
            diff = [f"row {r}: {g!r}, not {w!r}"
                    for r, (g, w) in enumerate(zip(got, want)) if g != w]
            check(f"{what}: the rows shown", not diff, "; ".join(diff[:3]))


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit(__doc__.split("\n\n")[1])
    emu = sys.argv[1]
    with tempfile.TemporaryDirectory() as tmp:
        for arg in sys.argv[2:]:
            monitor, words = arg.rsplit(":", 1)
            test(emu, monitor, int(words), tmp)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
