"""Load a .bin file into the board, or niceemu, through the debug link.

The core is held in reset, the ROM, if the bitstream has one, is hidden,
so that the RAM is at 0, and the memory is cleared to 0, as the
emulator's is at the start. The breakpoints are disabled, as a
connection to the emulator does, for the board keeps them until a reset.
Then the words of the file are written with W packets of the debug link
(nice_cpu/doc/DEBUG.md), and the core is started unless --hold is
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
0x8000 alone. Then SYS 0x8000 and CR are typed on the console, BASIC's
statement that runs the program. A bitstream without a ROM, and niceemu,
have no monitor: --rom FILE loads FILE at 0 in its place, such as
build/rom.bin, the monitor and BASIC, with the ROM hidden. The
variables at the top are the monitor's 4K words and BASIC's RAM below
them, as many words as the header of the BASIC says, that of FILE, or
else of the ROM's (doc/BASIC_ROM.md).

A ROM image loaded at 0 gets BASIC's flag "keep" set, with its checksum
again, so that the monitor runs that BASIC and does not replace it with
a card's BASIC*.ROM, which would also zero the RAM from 0x8000.

With --bas, FILE is the text of a BASIC program, as BASIC's LOAD "NAME"
reads a file: the memory is cleared as for --monitor, the monitor boots
cold with the ROM visible, and its BASIC gets the lines typed on the
console, then RUN and CR, as if they were typed on the keyboard. The
typing waits for BASIC's first READY., and each part of it for room in
the core's input buffer, so that no byte is lost. A line ends with CR LF,
LF, or CR, a TAB is a blank, and a line of blanks is passed over. A line
that does not start with its number, one longer than BASIC's 254
characters, and a byte that is no printable ASCII are refused before
the link opens, as LOAD would stop there, and so is a file with no line.
--rom FILE loads FILE at 0 in place of the ROM, as for --monitor
(issue #167).

With --basic, FILE is an image of BASIC, such as basic/build/basic.rom
or a release's BASIC-V2.4.ROM, which goes into BASIC's part of the ROM,
0x3000-0x7FFF, with "keep" set and every word of the part that it does
not fill zeroed, and is read back. The core is held, the memory
cleared, and the ROM shown, and the core started, unless --hold is
given, so the monitor boots cold with that BASIC. The ROM keeps it until
the FPGA is configured again. A ROM that does not take the writes, of a
bitstream older than V2.4, which takes none below 0x4000, or the
Nexys4DDR's, is refused, as is no ROM.

Usage: tools/nicemon.py load (--eth HOST[:PORT] | --port DEVICE [--baud 230400]
                             | --tcp [HOST:]PORT | --cosim PORT) [--hold]
                             [(--monitor | --bas) [--rom FILE] | --basic] FILE

One of --eth, --port, --tcp, and --cosim must be given. --port names the
serial device of the board's debug UART, such as /dev/ttyUSB1. --eth HOST talks to the board over TCP on its Ethernet port, at
its IP address HOST, on port 4510 unless HOST:PORT names another. --tcp
PORT talks to "niceemu --link PORT" instead, --tcp HOST:PORT to one on
another computer, and --cosim PORT to the
simulated system of "make -C sim cosim". Only the Python
standard library is used, so this runs on Linux and macOS. run.py and
tools/hwtest.py use the functions here, boardlink.py has the link,
and nice_cpu's debugger/nicebin.py reads the files and writes the words.
"""

import argparse
import re
import time

from lib.boardlink import (BRK_EN, CLEAR, CONTROL, HOLD, RAM, Link, LinkError,
                           add_arguments, fail, open_link)
# After boardlink, which puts nice_cpu's debugger/ on the path
import nicebin
from nicebin import Words, read_lines

import basic_rom
from lib import cli

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

# A BASIC program typed (read_bas): the statement that runs it, the most
# characters of a line that BASIC's line input takes, what BASIC prints
# when it waits for a line, and how long load waits for it after the
# start, which is longer than the monitor's cold start takes even in the
# simulation of make cosim
BAS_RUN = b"RUN\r"
BAS_LINE = 254
READY = b"READY."
READY_WAIT = 60.0


def in_screen(addr: int) -> bool:
    """Whether addr is in the screen that both boards have."""
    return SCREEN_BASE <= addr < SCREEN_BASE + SCREEN_WORDS


def basic_image(words: Words) -> dict[int, int]:
    """The words of words in BASIC's part of the ROM, by address."""
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
    return rom_words(rom) + words


def read_bas(path: str) -> bytes:
    """The lines of the BASIC program in the file, each ended by CR, as
    they are typed. A line ends with CR LF, LF, or CR, a TAB is a blank,
    a line of blanks is passed over, and the blanks before a line's
    number, and all but one after it, are dropped, as BASIC's LOAD
    "NAME" reads a file: SAVE writes LIST's indent there, which does not
    count toward BAS_LINE. A line that LOAD would stop at is refused:
    one that does not start with its number, one longer than BAS_LINE,
    and one with a byte that is not printable ASCII. So is a file
    without a line."""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        fail(f"cannot read {path}: {e.strerror}")
    lines = data.replace(b"\r\n", b"\n").replace(b"\r", b"\n").split(b"\n")
    typed = []
    for line_no, line in enumerate(lines, 1):
        line = line.replace(b"\t", b" ").lstrip(b" ")
        if not line:
            continue
        number = re.match(rb"\d+ +", line)
        if number:
            line = number.group().rstrip(b" ") + b" " + line[number.end():]
        bad = [b for b in line if not 0x20 <= b < 0x7F]
        if bad:
            fail(f"{path}:{line_no}: the byte {bad[0]:#04x} is no "
                 f"printable ASCII character, which BASIC does not take")
        if len(line) > BAS_LINE:
            fail(f"{path}:{line_no}: the line has {len(line)} characters, "
                 f"more than the {BAS_LINE} of a line of BASIC")
        if not line[:1].isdigit():
            fail(f"{path}:{line_no}: the line does not start with its "
                 f"number; a program has only numbered lines")
        typed.append(line + b"\r")
    if not typed:
        fail(f"{path}: no line of a program")
    return b"".join(typed)


def wait_ready(link: Link, timeout: float = READY_WAIT) -> None:
    """Waits for the READY. that BASIC prints after the cold start, which
    start() has begun. Until then the monitor does not read the console,
    and a paced send would give up on the full input buffer."""
    text = b""
    end = time.monotonic() + timeout
    while READY not in text:
        if time.monotonic() >= end:
            fail(f"BASIC did not print {READY.decode()} within "
                 f"{timeout:g} s of the start")
        link.poll(0.1)
        text += link.take_console()


def type_bas(link: Link, typed: bytes, timeout: float = READY_WAIT) -> None:
    """Types the lines of read_bas() and RUN for BASIC, after its READY.,
    each part when the core's input buffer has room for it, and waits
    until BASIC has read them all: the close of the link is a break over
    TCP, after which the board drops the line's bytes."""
    wait_ready(link, timeout)
    empty = link.free()
    link.send_console(typed)
    end = time.monotonic() + timeout
    while link.free() < empty:
        if time.monotonic() >= end:
            fail(f"BASIC did not read the lines typed within {timeout:g} s")
        link.poll(0.05)
        link.take_console()


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
    part of the ROM, shown, with "keep" set, or as it is when keep is False,
    and 0 in every word of the part that it does not fill, and reads the
    part back. A bitstream without a ROM, or whose ROM does not take the
    writes, is refused: the Nexys4DDR's takes none, nor does one older
    than V2.3.1, and V2.3.1 and V2.3.2, with BASIC at 0x4000, take none
    below it. start(link, rom=True) then boots the monitor with it."""
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
    if read_part(link) != words:
        fail("BASIC's part of the ROM did not keep the words written: the "
             "ROM takes no writes, as on the Nexys4DDR, or none below "
             "0x4000, as in a bitstream older than V2.4")


def read_part(link: Link) -> list[int]:
    """The words of BASIC's part of the ROM, shown, with the core held."""
    out: list[int] = []
    for a in range(basic_rom.BASE, basic_rom.END, 1024):
        out += link.read(a, 1024)
    return out


def start(link: Link, rom: bool = False) -> None:
    """Starts the core, with the ROM hidden, or with rom, visible.
    load_words() has held it, so this one write starts it (DEBUG.md §6)."""
    link.control(0 if rom else RAM)


def add_monitor_arguments(parser: argparse.ArgumentParser) -> None:
    """--monitor, --bas, and --rom, which load.py and run.py share."""
    parser.add_argument("--monitor", action="store_true",
                        help="run the program, at 0x8000, under the monitor "
                        "in the ROM, which boots and gets SYS 0x8000 and CR")
    parser.add_argument("--bas", action="store_true",
                        help="the file is a BASIC program's text: type it "
                        "into the ROM's BASIC, which boots, then RUN and CR")
    parser.add_argument("--rom", metavar="FILE",
                        help="with --monitor or --bas, load FILE at 0 in "
                        "place of the ROM, such as build/rom.bin")


def rom_words(path: str) -> Words:
    """The words of a ROM image for --rom, which must be below PROGRAM, as
    a ROM's are."""
    words = read_bin(path)
    high = [a for a, _ in words if a >= PROGRAM]
    if high:
        fail(f"{path}: address {high[0]:08x} is not in the ROM, below "
             f"{PROGRAM:08x}")
    return words


def program_words(parser: argparse.ArgumentParser,
                  args: argparse.Namespace) -> tuple[Words, bytes]:
    """The words to load for args.file, with --monitor, --bas, and --rom,
    and what to type on the console after the start."""
    if args.monitor and args.bas:
        parser.error("--monitor and --bas do not go together")
    if args.rom and not (args.monitor or args.bas):
        parser.error("--rom needs --monitor or --bas")
    if args.monitor:
        return monitor_words(args.file, args.rom), RUN_COMMAND
    if args.bas:
        typed = read_bas(args.file) + BAS_RUN
        return (rom_words(args.rom) if args.rom else []), typed
    return read_bin(args.file), b""


DESCRIPTION = __doc__.splitlines()[0]


def add_options(parser: argparse.ArgumentParser) -> None:
    """The options of nicemon.py load."""
    add_arguments(parser)
    parser.add_argument("--hold", action="store_true",
                        help="leave the core held in reset after loading")
    add_monitor_arguments(parser)
    parser.add_argument("--basic", action="store_true",
                        help="the file is an image of BASIC, for BASIC's "
                        "part of the ROM, with \"keep\" set")
    parser.add_argument("file",
                        help="a .bin file: one 'address word' hex pair per "
                        "line, or with --bas a BASIC program's text")


def command(parser: argparse.ArgumentParser, args: argparse.Namespace) -> None:
    """nicemon.py load, on the options of add_options."""
    if args.basic:
        if args.monitor or args.bas:
            parser.error("--basic does not go with --monitor or --bas")
        image = read_basic(args.file)
        link = open_link(args)
        try:
            load_basic(link, image)
            cli.note(f"wrote BASIC {basic_rom.text(image)} from "
                     f"{args.file} into the ROM, {len(image)} words, with "
                     f"\"keep\", and read it back")
            if not args.hold:
                start(link, rom=True)
                cli.note("started the core, with the ROM")
        except LinkError as e:
            fail(str(e))
        link.close()
        return
    if args.hold and args.bas:
        parser.error("--hold and --bas do not go together, as a held core "
                     "cannot take the lines")
    words, typed = program_words(parser, args)
    under = args.monitor or args.bas
    in_rom = under and not args.rom
    link = open_link(args)
    try:
        load_words(link, words, rom=in_rom, monitor=under)
        if args.bas:
            cli.note("cleared the memory"
                     + (f", and loaded {args.rom} at 0" if args.rom else ""))
        else:
            cli.note(f"loaded {len(words)} words from {args.file}"
                     + (f" and {args.rom}" if args.rom else ""))
        if not args.hold:
            start(link, rom=in_rom)
            cli.note("started the core")
            if args.monitor:
                link.send_console(typed)
                cli.note("typed SYS 0x8000 for the monitor")
            elif args.bas:
                type_bas(link, typed)
                lines = typed.count(b"\r") - 1
                cli.note(f"typed the {lines} lines of {args.file} and RUN "
                         f"for BASIC")
    except LinkError as e:
        fail(str(e))
    link.close()
