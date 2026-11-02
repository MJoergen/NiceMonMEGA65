#!/usr/bin/env python3
"""Load a .bin file into the board, or niceemu, through the debug link.

The core is held in reset, the ROM, if the bitstream has one, is hidden,
so that the RAM is at 0, and the memory is cleared to 0, as the
emulator's is at the start. The breakpoints are disabled, as a
connection to the emulator does, for the board keeps them until a reset.
Then the words of the file are written with W packets of the debug link
(nice_cpu/doc/DEBUG.md), and the core is started unless --no-run is
given. The ROM stays hidden until the reset button is pressed, which
boots the ROM's program again.

With --monitor, the program runs under the monitor in the ROM
(monitor/README.md, "Programs"): it must be at 0x8000 or above, as a
program for the monitor is assembled, and the ROM stays visible. The
memory is cleared and the program written with the core held, and the
core is started, so the monitor boots cold, which leaves the RAM from
0x8000 alone. Then r and CR are typed on the console, the monitor's
command that runs the program. A bitstream without a ROM, and niceemu,
have no monitor: --rom FILE loads FILE at 0 in its place, such as
monitor/build/monitor.bin, with the ROM hidden.

Usage: tools/load.py (--eth HOST[:PORT] | --port DEVICE [--baud 2000000]
                     | --tcp [HOST:]PORT | --cosim PORT) [--no-run]
                     [--monitor [--rom FILE]] FILE.bin

One of --eth, --port, --tcp, and --cosim must be given. --port names the
serial device of the board's debug UART, such as /dev/ttyUSB1. --eth HOST talks to the board over TCP on its Ethernet port, at
its IP address HOST, on port 4510 unless HOST:PORT names another. --tcp
PORT talks to "niceemu --link PORT" instead, --tcp HOST:PORT to one on
another computer, and --cosim PORT to the
simulated system of "make -C sim cosim". Only the Python
standard library is used, so this runs on Linux and macOS. tools/run.py and
tools/hwtest.py use the functions here, and tools/nicelink.py has the link.
"""

import argparse

from nicelink import (BRK_EN, CLEAR, CONTROL, HOLD, RAM, Link, LinkError,
                      add_arguments, fail, open_link)

# The words that the board has: the RAM, which is 64K words from 0, and the
# screen, of which both boards have the first 8K (the MEGA65 has 32K). Any
# other address would alias a word of the RAM, mod 64K, or reach a register
# of the I/O page, where the emulator has memory of its own.
RAM_WORDS = 0x10000
SCREEN_BASE = 0xFFFF0000
SCREEN_WORDS = 0x2000

# A program under the monitor: where it starts, above the ROM, and the
# monitor's command that runs it (monitor/README.md)
PROGRAM = 0x8000
RUN_COMMAND = b"r\r"


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
                 f"cannot load it as the emulator does; move the "
                 f"program into those ranges")
        seen[addr] = line_no
        words.append((addr, word))
    if not words:
        fail(f"{path}: no words to load; is it a .bin file, as niceasm.py "
             f"writes with -o?")
    return words


def monitor_words(path: str, rom: str | None) -> list[tuple[int, int]]:
    """The words of a program under the monitor, which must be at PROGRAM
    or above, and with rom, the words of that monitor, which must be
    below, as a ROM's are."""
    words = read_bin(path)
    low = [a for a, _ in words if a < PROGRAM]
    if low:
        fail(f"{path}: address {low[0]:08x} is below {PROGRAM:08x}, where "
             f"the ROM is; a program under the monitor is assembled at "
             f"{PROGRAM:08x}, with nice_cpu's start_mon.nasm or "
             f"nicebuild.py --monitor")
    if rom is None:
        return words
    rom_words = read_bin(rom)
    high = [a for a, _ in rom_words if a >= PROGRAM]
    if high:
        fail(f"{rom}: address {high[0]:08x} is not in the ROM, below "
             f"{PROGRAM:08x}")
    return rom_words + words


def load_words(link: Link, words: list[tuple[int, int]],
               rom: bool = False) -> None:
    """Holds the core, hides the ROM, clears the memory, disables the
    breakpoints, and writes the words, with one W for each run of
    consecutive addresses. A link of version 3 or older takes the write of
    the enable bits too, as a reserved word. With rom, the ROM stays
    visible, and a bitstream without one, which reads bit 3 as 1, is
    refused: the clear leaves the ROM alone, so its program boots cold at
    the start."""
    if rom:
        link.control(HOLD | CLEAR)
        if link.read_word(CONTROL) & RAM:
            fail("no ROM, so no monitor, as in a bitstream built without "
                 "one or in niceemu; --rom FILE loads one, such as "
                 "monitor/build/monitor.bin, in its place")
    else:
        link.control(HOLD | CLEAR | RAM)
    link.write(BRK_EN, [0])
    words = sorted(words)
    i = 0
    while i < len(words):
        j = i + 1
        while j < len(words) and words[j][0] == words[j - 1][0] + 1:
            j += 1
        link.write(words[i][0], [w for _, w in words[i:j]])
        i = j


def start(link: Link, rom: bool = False) -> None:
    """Starts the core, with the ROM hidden, or with rom, visible.
    load_words() has held it, so this one write starts it (DEBUG.md §6)."""
    link.control(0 if rom else RAM)


def add_monitor_arguments(parser: argparse.ArgumentParser) -> None:
    """--monitor and --rom, which load.py and run.py share."""
    parser.add_argument("--monitor", action="store_true",
                        help="run the program, at 0x8000, under the monitor "
                        "in the ROM, which boots and gets r and CR")
    parser.add_argument("--rom", metavar="FILE",
                        help="with --monitor, load FILE at 0 in place of the "
                        "ROM, such as monitor/build/monitor.bin")


def program_words(parser: argparse.ArgumentParser,
                  args: argparse.Namespace) -> list[tuple[int, int]]:
    """The words to load for args.file, with --monitor and --rom."""
    if args.rom and not args.monitor:
        parser.error("--rom needs --monitor")
    if args.monitor:
        return monitor_words(args.file, args.rom)
    return read_bin(args.file)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    add_arguments(parser)
    parser.add_argument("--no-run", action="store_true",
                        help="leave the core held in reset after loading")
    add_monitor_arguments(parser)
    parser.add_argument("file",
                        help="a .bin file: one 'address word' hex pair per line")
    args = parser.parse_args()

    words = program_words(parser, args)
    in_rom = args.monitor and not args.rom
    link = open_link(args)
    try:
        load_words(link, words, rom=in_rom)
        print(f"load.py: loaded {len(words)} words from {args.file}"
              + (f" and {args.rom}" if args.rom else ""))
        if not args.no_run:
            start(link, rom=in_rom)
            print("load.py: started the core")
            if args.monitor:
                link.send_console(RUN_COMMAND)
                print("load.py: typed r for the monitor")
    except LinkError as e:
        fail(str(e))
    link.close()


if __name__ == "__main__":
    main()
