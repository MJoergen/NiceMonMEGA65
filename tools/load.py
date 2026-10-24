#!/usr/bin/env python3
"""Load a .bin file into the board, or niceemu, through the debug link.

The core is held in reset, the ROM with the monitor, if the bitstream has
one, is hidden, so that the RAM is at 0, and the memory is cleared to 0, as
the emulator's is at the start. Then the words of the file are written with
W packets of the debug link (nice_cpu/doc/DEBUG.md), and the core is started
unless --no-run is given. The ROM stays hidden until the reset button is
pressed, which boots the monitor again.

Usage: tools/load.py [--port /dev/ttyUSB1] [--baud 115200] [--tcp PORT]
                     [--no-run] FILE.bin

--port names the serial device of the board's debug UART, /dev/ttyUSB1 by
default. --tcp PORT talks to "niceemu --link PORT" instead. Only the Python
standard library is used, so this runs on Linux and macOS. tools/run.py and
tools/hwtest.py use the functions here, and tools/nicelink.py has the link.
"""

import argparse

from nicelink import (CLEAR, HOLD, RAM, Link, LinkError, add_arguments, fail,
                      open_link)

# The words that the board has: the RAM, which is 64K words from 0, and the
# screen, of which both boards have the first 8K (the MEGA65 has 32K). Any
# other address would alias a word of the RAM, mod 64K, or reach a register
# of the I/O page, where the emulator has memory of its own.
RAM_WORDS = 0x10000
SCREEN_BASE = 0xFFFF0000
SCREEN_WORDS = 0x2000


def hex_field(path: str, line_no: int, text: str) -> int:
    """A field of a .bin file: 1 to 8 hex digits, as niceemu takes them."""
    if not text or not all(c in "0123456789abcdefABCDEF" for c in text):
        fail(f"{path}:{line_no}: '{text}' is not a hex number")
    if len(text) > 8:
        fail(f"{path}:{line_no}: '{text}' has more than 8 hex digits")
    return int(text, 16)


def read_lines(path: str) -> list[tuple[int, list[str]]]:
    """The lines of a .bin or .sym file that are not blank, as (line number,
    fields), split as niceemu splits them: lines at LF only, with blanks,
    tabs, and CRs stripped, and fields at blanks and tabs only. A byte that
    is not ASCII stays in its field as an escape, which no field takes."""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        fail(f"cannot read {path}: {e.strerror}")
    lines = []
    for line_no, raw in enumerate(data.split(b"\n"), 1):
        line = raw.strip(b" \t\r").decode("ascii", "backslashreplace")
        fields = [f for f in line.replace("\t", " ").split(" ") if f]
        if fields:
            lines.append((line_no, fields))
    return lines


def read_bin(path: str) -> list[tuple[int, int]]:
    """The words of a .bin file, as (address, word). It takes the lines that
    niceemu takes, and rejects an address that the board has no memory at."""
    words: list[tuple[int, int]] = []
    seen: dict[int, int] = {}
    for line_no, fields in read_lines(path):
        if len(fields) < 2:
            fail(f"{path}:{line_no}: expected 'address word', "
                 f"found only '{fields[0]}'")
        if len(fields) > 2:
            fail(f"{path}:{line_no}: unexpected '{fields[2]}' after the word")
        addr = hex_field(path, line_no, fields[0])
        word = hex_field(path, line_no, fields[1])
        if addr in seen:
            fail(f"{path}:{line_no}: address {addr:08x} is already "
                 f"loaded by line {seen[addr]}")
        if not (addr < RAM_WORDS
                or SCREEN_BASE <= addr < SCREEN_BASE + SCREEN_WORDS):
            fail(f"{path}:{line_no}: address {addr:08x} is not in the RAM "
                 f"(0 to {RAM_WORDS - 1:x}) or the screen ({SCREEN_BASE:x} "
                 f"to {SCREEN_BASE + SCREEN_WORDS - 1:x}), so the board "
                 f"cannot load it as the emulator does")
        seen[addr] = line_no
        words.append((addr, word))
    if not words:
        fail(f"{path}: no words to load")
    return words


def load_words(link: Link, words: list[tuple[int, int]]) -> None:
    """Holds the core, hides the ROM, clears the memory, and writes the
    words, with one W for each run of consecutive addresses."""
    link.control(HOLD | CLEAR | RAM)
    words = sorted(words)
    i = 0
    while i < len(words):
        j = i + 1
        while j < len(words) and words[j][0] == words[j - 1][0] + 1:
            j += 1
        link.write(words[i][0], [w for _, w in words[i:j]])
        i = j


def start(link: Link) -> None:
    """Starts the core, with the ROM hidden. load_words() has held it, so
    this one write starts it (DEBUG.md §6)."""
    link.control(RAM)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    add_arguments(parser)
    parser.add_argument("--no-run", action="store_true",
                        help="leave the core held in reset after loading")
    parser.add_argument("file")
    args = parser.parse_args()

    words = read_bin(args.file)
    link = open_link(args)
    try:
        load_words(link, words)
        print(f"load.py: loaded {len(words)} words from {args.file}")
        if not args.no_run:
            start(link)
            print("load.py: started the core")
    except LinkError as e:
        fail(str(e))
    link.close()


if __name__ == "__main__":
    main()
