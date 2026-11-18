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

A word beyond the board's RAM, which 0xFFFFFF9E reads after the hold,
is refused, as it would overwrite another.

With --monitor, the program runs under the monitor in the ROM
(monitor/README.md, "Programs"): it must be at 0x8000 or above, as a
program for the monitor is assembled, and below the monitor's variables
at the top of the RAM, and the ROM stays visible. The top words below
the variables are the stack that the monitor and the program share,
which the monitor uses before the program runs, so a word there is
overwritten; a program leaves room for the stack anyway. A word in the
screen is refused, as the monitor clears the screen when it boots. The
memory is cleared and the program written with the core held, and the
core is started, so the monitor boots cold, which leaves the RAM from
0x8000 alone. Then r and CR are typed on the console, the monitor's
command that runs the program. A bitstream without a ROM, and niceemu,
have no monitor: --rom FILE loads FILE at 0 in its place, such as
build/rom.bin, the monitor and BASIC, with the ROM hidden. The
variables at the top are the monitor's 4K words and BASIC's RAM below
them, as many words as the header of the BASIC says, that of FILE, or
else of the ROM's (doc/BASIC_ROM.md).

A ROM image loaded at 0 gets BASIC's flag "keep" set, with its checksum
again, so that the monitor runs that BASIC and does not replace it with
a card's BASIC*.ROM, which would also zero the RAM from 0x8000.

With --basic, FILE is an image of BASIC, such as basic/build/basic.rom
or a release's BASIC-V2.3.1.ROM, which goes into BASIC's half of the ROM,
0x4000-0x7FFF, with "keep" set and every word of the half that it does
not fill zeroed, and is read back. The core is held, the memory
cleared, and the ROM shown, and the core started, unless --no-run is
given, so the monitor boots cold with that BASIC. The ROM keeps it until
the FPGA is configured again. A bitstream older than V2.3.1, whose ROM
takes no writes, is refused, as is one without a ROM.

Usage: tools/load.py (--eth HOST[:PORT] | --port DEVICE [--baud 230400]
                     | --tcp [HOST:]PORT | --cosim PORT) [--no-run]
                     [--monitor [--rom FILE] | --basic] FILE

One of --eth, --port, --tcp, and --cosim must be given. --port names the
serial device of the board's debug UART, such as /dev/ttyUSB1. --eth HOST talks to the board over TCP on its Ethernet port, at
its IP address HOST, on port 4510 unless HOST:PORT names another. --tcp
PORT talks to "niceemu --link PORT" instead, --tcp HOST:PORT to one on
another computer, and --cosim PORT to the
simulated system of "make -C sim cosim". Only the Python
standard library is used, so this runs on Linux and macOS. tools/run.py and
tools/hwtest.py use the functions here, tools/boardlink.py has the link,
and nice_cpu's debugger/nicebin.py reads the files and writes the words.
"""

import argparse

from boardlink import (BRK_EN, CLEAR, CONTROL, HOLD, RAM, Link, LinkError,
                       add_arguments, fail, open_link)
# After boardlink, which puts nice_cpu's debugger/ on the path
import nicebin
from nicebin import Words, read_lines

import basic_rom

# The words that a board has: the RAM from 0, 128K words on the MEGA65 and
# 64K on the Nexys4DDR, and the screen, of which both boards have the
# first 8K (the MEGA65 has 32K). Any other address would alias a word of
# the RAM, or reach a register of the I/O page, where the emulator has
# memory of its own. A .bin file must fit the largest RAM, MAX_RAM_WORDS,
# and load_words() checks it against the board's, which RAM_SIZE reads,
# 0 in niceemu, where there is no limit.
MAX_RAM_WORDS = 0x20000
RAM_SIZE = 0xFFFFFF9E
SCREEN_BASE = 0xFFFF0000
SCREEN_WORDS = 0x2000

# A program under the monitor: where it starts, above the ROM, the words
# of the monitor's variables at the top of the RAM, at 0xFFFFF000, below
# which BASIC's RAM is, of the size that BASIC's header gives, and the
# statement of the ROM's BASIC that runs it (monitor/README.md)
PROGRAM = 0x8000
MON_VARS = 0x1000
RUN_COMMAND = b"SYS 0x8000\r"


def in_screen(addr: int) -> bool:
    """Whether addr is in the screen that both boards have."""
    return SCREEN_BASE <= addr < SCREEN_BASE + SCREEN_WORDS


def basic_image(words: Words) -> dict[int, int]:
    """The words of words in BASIC's half of the ROM, by address."""
    return {a: w for a, w in words if basic_rom.BASE <= a < basic_rom.END}


def vars_words(link: Link, words: Words) -> int:
    """The words of the variables at the top of the RAM under the monitor:
    the monitor's, and BASIC's RAM, as the header of the BASIC in words
    says, or else of the BASIC in the ROM, which the link reads with the
    ROM shown and the core held."""
    image = basic_image(words)
    if basic_rom.H_MAGIC not in image:
        first = basic_rom.H_MAGIC
        image = dict(zip(range(first, basic_rom.H_RAM + 1),
                         link.read(first, basic_rom.H_RAM + 1 - first)))
    return MON_VARS + basic_rom.ram_words(image)


def keep_basic(words: Words) -> Words:
    """words, with "keep" set in the BASIC among them, if any, and its
    checksum again, so that the monitor does not replace it with a card's
    (doc/BASIC_ROM.md, "The tools")."""
    image = basic_image(words)
    if image.get(basic_rom.H_MAGIC) != basic_rom.MAGIC:
        return words
    basic_rom.set_keep(image)
    return [(a, image.get(a, w)) for a, w in words]


def check_fit(link: Link, words: Words, monitor: bool) -> None:
    """Refuses words beyond the board's RAM, which would wrap onto the ROM,
    the variables, or the program's own words. Under the monitor, the
    program's RAM ends at the variables, BASIC's first, and
    monitor_words() has refused the screen. The link must reach RAM_SIZE:
    the core is held. It reads 0 in niceemu, which has no limit, and in
    a bitstream older than the register."""
    ram = link.read_word(RAM_SIZE)
    if not ram:
        return
    end = ram - vars_words(link, words) if monitor else ram
    high = [a for a, _ in words if a >= end and not in_screen(a)]
    if high:
        what = (f"the program's RAM under the monitor, {PROGRAM:x} to "
                f"{end - 1:x}, below the monitor's variables" if monitor
                else f"the RAM, 0 to {end - 1:x}")
        fail(f"address {high[0]:08x} is beyond {what}: the board has "
             f"{ram // 1024}K words of RAM, which repeat through the "
             f"address space, so the word would overwrite another")


def read_bin(path: str) -> Words:
    """The words of a .bin file, as (address, word). It takes the lines that
    niceemu takes, with nice_cpu's nicebin.read_bin(), and rejects an
    address that the board has no memory at. Each line that is not blank
    has one word, so the words are in the order of those lines."""
    words = nicebin.read_bin(path)
    for (line_no, _), (addr, _) in zip(read_lines(path), words):
        if not (addr < MAX_RAM_WORDS or in_screen(addr)):
            fail(f"{path}:{line_no}: address {addr:08x} is not in the RAM "
                 f"(0 to {MAX_RAM_WORDS - 1:x} on the MEGA65) or the "
                 f"screen ({SCREEN_BASE:x} to "
                 f"{SCREEN_BASE + SCREEN_WORDS - 1:x}), so the board "
                 f"cannot load it as the emulator does; move the "
                 f"program into those ranges")
    return words


def monitor_words(path: str, rom: str | None) -> Words:
    """The words of a program under the monitor, which must be at PROGRAM
    or above and not in the screen, which the monitor clears when it
    boots, and with rom, the words of that monitor, which must be below
    PROGRAM, as a ROM's are."""
    words = read_bin(path)
    low = [a for a, _ in words if a < PROGRAM]
    if low:
        fail(f"{path}: address {low[0]:08x} is below {PROGRAM:08x}, where "
             f"the ROM is; a program under the monitor is assembled at "
             f"{PROGRAM:08x}, with nice_cpu's start_mon.nasm or "
             f"nicebuild.py --monitor")
    screen = [a for a, _ in words if in_screen(a)]
    if screen:
        fail(f"{path}: address {screen[0]:08x} is in the screen, which the "
             f"monitor clears when it boots, so the word would be lost; a "
             f"program under the monitor writes the screen itself")
    if rom is None:
        return words
    rom_words = read_bin(rom)
    high = [a for a, _ in rom_words if a >= PROGRAM]
    if high:
        fail(f"{rom}: address {high[0]:08x} is not in the ROM, below "
             f"{PROGRAM:08x}")
    return rom_words + words


def load_words(link: Link, words: Words, rom: bool = False,
               monitor: bool = False) -> None:
    """Holds the core, hides the ROM, clears the memory, checks that the
    words fit the board's RAM, under the monitor with monitor, disables the
    breakpoints, and writes the words, with nice_cpu's nicebin.load_words().
    A link of version 3 or older takes the write of the enable bits too, as
    a reserved word. With rom, the ROM stays visible, and a bitstream
    without one, which reads bit 3 as 1, is refused: the clear leaves the
    ROM alone, so its program boots cold at the start. A BASIC among the
    words, of a ROM image loaded at 0, gets "keep" (keep_basic)."""
    if not rom:
        words = keep_basic(words)
        nicebin.load_words(link, words,
                           lambda link, words: check_fit(link, words, monitor))
        return
    link.control(HOLD | CLEAR)
    if link.read_word(CONTROL) & RAM:
        fail("no ROM, so no monitor, as in a bitstream built without "
             "one or in niceemu; --rom FILE loads one, such as "
             "build/rom.bin, in its place")
    check_fit(link, words, monitor)
    link.write(BRK_EN, [0])
    nicebin.write_words(link, words)


def read_basic(path: str) -> dict[int, int]:
    """An image of BASIC, checked as basic_rom.py check checks it."""
    try:
        image = basic_rom.read_image(path)
        basic_rom.check(image)
    except (basic_rom.ImageError, ValueError) as e:
        fail(f"{path}: {e}")
    return image


def load_basic(link: Link, image: dict[int, int], keep: bool = True) -> None:
    """Holds the core, clears the memory, and writes the image into BASIC's
    half of the ROM, shown, with "keep" set, or as it is when keep is False,
    and 0 in every word of the half that it does not fill, and reads the
    half back. A bitstream without a ROM, or whose ROM takes no writes, is
    refused. start(link, rom=True) then boots the monitor with it."""
    image = dict(image)
    if keep:
        basic_rom.set_keep(image)
    link.control(HOLD | CLEAR)
    if link.read_word(CONTROL) & RAM:
        fail("no ROM, so no BASIC to replace, as in a bitstream built "
             "without one or in niceemu")
    words = [image.get(a, 0) for a in range(basic_rom.BASE, basic_rom.END)]
    nicebin.write_words(link, list(zip(range(basic_rom.BASE, basic_rom.END),
                                       words)))
    if read_half(link) != words:
        fail("BASIC's half of the ROM did not keep the words written: the "
             "bitstream is older than V2.3.1, whose ROM takes no writes")


def read_half(link: Link) -> list[int]:
    """The words of BASIC's half of the ROM, shown, with the core held."""
    out: list[int] = []
    for a in range(basic_rom.BASE, basic_rom.END, 1024):
        out += link.read(a, 1024)
    return out


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
                        "ROM, such as build/rom.bin")


def program_words(parser: argparse.ArgumentParser,
                  args: argparse.Namespace) -> Words:
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
    parser.add_argument("--basic", action="store_true",
                        help="FILE is an image of BASIC, for BASIC's half "
                        "of the ROM, with \"keep\" set")
    parser.add_argument("file",
                        help="a .bin file: one 'address word' hex pair per line")
    args = parser.parse_args()

    if args.basic:
        if args.monitor:
            parser.error("--basic and --monitor do not go together")
        image = read_basic(args.file)
        link = open_link(args)
        try:
            load_basic(link, image)
            print(f"load.py: wrote BASIC {basic_rom.text(image)} from "
                  f"{args.file} into the ROM, {len(image)} words, with "
                  f"\"keep\", and read it back")
            if not args.no_run:
                start(link, rom=True)
                print("load.py: started the core, with the ROM")
        except LinkError as e:
            fail(str(e))
        link.close()
        return
    words = program_words(parser, args)
    in_rom = args.monitor and not args.rom
    link = open_link(args)
    try:
        load_words(link, words, rom=in_rom, monitor=args.monitor)
        print(f"load.py: loaded {len(words)} words from {args.file}"
              + (f" and {args.rom}" if args.rom else ""))
        if not args.no_run:
            start(link, rom=in_rom)
            print("load.py: started the core")
            if args.monitor:
                link.send_console(RUN_COMMAND)
                print("load.py: typed SYS 0x8000 for the monitor")
    except LinkError as e:
        fail(str(e))
    link.close()


if __name__ == "__main__":
    main()
