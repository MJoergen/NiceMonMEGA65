#!/usr/bin/env python3
"""Run a program on the board as niceemu runs it on the emulator.

The program is loaded into cleared memory over the debug link
(nice_cpu/doc/DEBUG.md), and started. Its input is sent as console bytes,
and its output copied to stdout. When it halts, the link's halt notice
comes after its last byte, and this prints what niceemu prints after a
halt: why and after how many steps the program halted, the registers, and
the --dump and --screen output. So the output of the two can be compared:

    diff <(niceemu -i in.txt prog.bin) <(tools/run.py -i in.txt prog.bin)

Usage:
    tools/run.py (--eth HOST[:PORT] | --port DEVICE [--baud 2000000]
                 | --tcp PORT | --cosim PORT) [-i FILE] [-d ADDR:N]... [-s] [-2004]
                 [--symbols FILE] [--timeout SEC] FILE.bin

    One of --eth, --port, --tcp, and --cosim must be given. --eth HOST
    runs it on the board over its Ethernet port, and --port DEVICE on its
    debug UART, as for tools/load.py. --tcp PORT runs the program on "niceemu --link PORT" instead of the
    board, which checks this script and the link against the emulator.
    --cosim PORT runs it on the simulated system of "make -C sim cosim",
    which checks the RTL too.

Input:
    The input is stdin, or the file of -i. It goes out as fast as the
    program's input buffer takes it: before each part, the free-space
    register says how many bytes it has room for, so none is lost. At the
    end of the input, a break on the UART, or a half-close of the TCP
    connection, ends the program's input too, so a read returns 0x200, as
    in the emulator. Input that the program has not read when it halts is
    dropped, as by the emulator. The input file, the .bin file, and the
    link are checked before the core is started.

Output:
    After a halt, the lines of niceemu: the reason and the step count, the
    registers, and the --dump and --screen output. -2004 prints the screen
    from 0x400, as niceemu does, which is plain memory on the board, not
    the screen that the board shows. The memory has 64K words, repeated
    through the address space, so a dump beyond them reads the same words
    again.

    --symbols FILE reads the labels that niceasm.py --symbols writes. After
    a halt other than HALT it prints where the program was, "At
    label+0x1f", and after a halt at ___wasm_trap, the default wasm trap
    handler, the trap's code from R1 and its location from R2, as niceemu
    does. The .sym file is split into lines and fields as niceemu splits it.

    --no-cycle-counter is accepted and ignored, as the cycle counter
    always runs.

Time limit:
    --timeout gives up after SEC seconds (60 by default, 0 for none). It
    holds the core, prints a line for the time limit and the --dump and
    --screen output, and exits with status 3, as niceemu does after its
    step limit. It prints no registers, as a hold leaves them undefined
    (DEBUG.md §6), so --symbols has no location to name, where niceemu
    prints one at its step limit.

Exit status:
    0    the program halted with HALT
    1    a usage error, or a failure before or during the run: a file that
         cannot be read, a link that does not answer
    2    the program halted for another reason
    3    the time limit ran out first; the core is held in reset
    130  interrupted with Ctrl-C; the core is held in reset
    141  stdout closed early, as by "| head" (SIGPIPE's status, as with
         niceemu)
    Options are taken as niceemu takes them, each on its own with its value
    as the next argument, and a usage error exits 1, as there.

Notes:
    The steps are the core's instruction counter, which the emulator's step
    count equals, unless the program starts the timer, which counts clock
    cycles on the board and steps in the emulator. But the emulator waits
    for each input byte, and the board does not: while no byte has arrived,
    a read returns 0. So a program that waits for input in a loop runs more
    steps there.

    Only the Python standard library is used.
"""

import argparse
import bisect
import os
import select
import stat
import sys
import time
from typing import NoReturn

from load import load_words, read_bin, read_lines, start
from nicelink import (DEBUG_FIRST, FULL_WAIT, HALT_REASON, HOLD, RAM, REGS,
                      Link, LinkError, add_arguments, fail, open_link,
                      read_words)

INSTR_LO = 0xFFFFFF42
INSTR_HI = 0xFFFFFF43
MAX_DUMP = 0x10000
INPUT_CHUNK = 256   # the most bytes of input sent at once
SCREEN = 0xFFFF0000
SCREEN_2004 = 0x400  # where niceemu -2004 has the screen, as the 2004 IDE
SCREEN_WIDTH = 80
SCREEN_HEIGHT = 25

# The halt reasons of the register at 0xFFFFFFF1, as the emulator describes
# them
REASONS = {
    1: "HALT",
    2: "reserved control instruction",
    3: "INT inside an interrupt routine",
    4: "RTI outside an interrupt routine",
}

# The default wasm trap handler, and the meaning of a trap's code in R1
# (nice_cpu/translator/WASM.md), as niceemu prints it
TRAP_HANDLER = "___wasm_trap"
TRAP_NAMES = {
    1: "unreachable",
    2: "memory access out of bounds",
    3: "division by zero",
    4: "integer overflow",
    5: "float to integer conversion",
    6: "call_indirect: bad index",
    7: "call_indirect: type mismatch",
}


class Symbols:
    """The labels of a file that niceasm.py --symbols writes, lines of
    "address name", for naming an address as niceemu does."""

    def __init__(self, path: str) -> None:
        symbols = []
        for line_no, fields in read_lines(path):
            where = f"{path}:{line_no}"
            if len(fields) == 1:
                fail(f"{where}: expected 'address name', found only "
                     f"'{fields[0]}'")
            if len(fields) > 2:
                fail(f"{where}: unexpected '{fields[2]}' after the name")
            addr, name = fields
            if not all(c in "0123456789abcdefABCDEF" for c in addr):
                fail(f"{where}: '{addr}' is not a hex number")
            if len(addr) > 8:
                fail(f"{where}: '{addr}' has more than 8 hex digits")
            symbols.append((int(addr, 16), name))
        # A stable sort keeps the file's order of the labels at one address
        symbols.sort(key=lambda s: s[0])
        self.addrs = [a for a, _ in symbols]
        self.names = [n for _, n in symbols]

    def before(self, addr: int) -> int | None:
        """The index of the label at or before addr, the first in the file
        of those at one address, or None when addr is before them all."""
        i = bisect.bisect_right(self.addrs, addr)
        if i == 0:
            return None
        i -= 1
        while i > 0 and self.addrs[i - 1] == self.addrs[i]:
            i -= 1
        return i

    def location(self, addr: int) -> str:
        """addr as niceemu prints it: the label at it, "label+0x1f" after
        one, or eight hex digits when no label is at or before it."""
        i = self.before(addr)
        if i is None:
            return f"{addr:08x}"
        if addr == self.addrs[i]:
            return self.names[i]
        return f"{self.names[i]}+0x{addr - self.addrs[i]:x}"


def where_lines(symbols: Symbols, regs: list[int]) -> list[str]:
    """What --symbols adds after a halt other than HALT: where the program
    was, the halting instruction at PC-1, and after a halt at the default
    wasm trap handler, the trap's code from R1 and its location from R2."""
    pc = (regs[15] - 1) & 0xFFFFFFFF
    lines = [f"At {symbols.location(pc)}"]
    i = symbols.before(pc)
    if (i is not None and symbols.addrs[i] == pc and
            symbols.names[i] == TRAP_HANDLER):
        code = regs[1]
        lines.append(f"Trap {code} ({TRAP_NAMES.get(code, 'unknown code')}) "
                     f"at {symbols.location(regs[2])}")
    return lines


def number(text: str) -> int:
    """A number of an option, decimal or hex after 0x, as niceemu takes it:
    digits only, no sign or underscore, and at most 32 bits."""
    hexadecimal = text[:2] in ("0x", "0X")
    digits = text[2:] if hexadecimal else text
    allowed = "0123456789abcdefABCDEF" if hexadecimal else "0123456789"
    if not digits or not all(c in allowed for c in digits):
        raise ValueError(f"bad number '{text}'")
    value = int(digits, 16 if hexadecimal else 10)
    if value > 0xFFFFFFFF:
        raise ValueError(f"'{text}' is larger than {0xFFFFFFFF}")
    return value


def dump_option(text: str) -> tuple[int, int]:
    if text.count(":") != 1:
        raise argparse.ArgumentTypeError(f"want ADDR:N, not '{text}'")
    try:
        addr, n = text.split(":")
        addr, n = number(addr), number(n)
    except ValueError as e:
        raise argparse.ArgumentTypeError(f"'{text}': {e}, want ADDR:N")
    if n > MAX_DUMP:
        raise argparse.ArgumentTypeError(
            f"'{text}': N is larger than {MAX_DUMP}, the words of the RAM")
    return addr, n


def dump_address(link: Link, addr: int) -> int:
    """The address to read a dumped word at. The link sees its debug
    registers at 0xFFFFFFE0-FF, where the core and niceemu see memory. On
    the board that memory is the RAM word at 0x0000FFE0-FF, which the link
    reads instead. The emulator's memory there is out of the link's reach."""
    if addr >= DEBUG_FIRST:
        if not link.board:
            fail(f"the link cannot read {addr:08x} of the emulator's memory, "
                 f"where it has its debug registers")
        return addr & 0xFFFF
    return addr


def run(link: Link, infd: int, timeout: float) -> bool:
    """Copies the input to the program and its output to stdout until it
    halts. Returns False if the time is up first."""
    out = sys.stdout.buffer
    pending = b""   # input that is read and not yet sent
    end = time.monotonic() + timeout if timeout else None
    while True:
        out.write(link.take_console())
        out.flush()
        if link.halts:
            return True
        now = time.monotonic()
        if end is not None and now >= end:
            return False
        if pending:
            n = min(len(pending), INPUT_CHUNK, link.free())
            if n:
                link.send_console(pending[:n], paced=False)
                pending = pending[n:]
            else:
                # The program's input buffer is full: wait FULL_WAIT
                # for it to take bytes, or for output to arrive
                link.poll(FULL_WAIT)
            continue
        # Wake at least every 0.5 s, to see the time limit and the link
        wake = 0.5 if end is None else min(0.5, end - now)
        reading = infd >= 0
        ready, _, _ = select.select([link.fileno()] + ([infd] if reading else []),
                                    [], [], wake)
        if infd in ready:
            data = os.read(infd, 4096)
            if data:
                pending = data
            else:
                link.end_input()
                infd = -1
        if link.fileno() in ready:
            link.poll()


def dump_lines(link: Link, dumps: list[tuple[int, int]], screen: bool,
               screen_base: int) -> list[str]:
    """The --dump and --screen output, with the screen at screen_base."""
    lines = []
    for addr, n in dumps:
        words = read_words(link, [dump_address(link, (addr + i) & 0xFFFFFFFF)
                                  for i in range(n)])
        for i in range(0, n, 8):
            lines.append(f"{(addr + i) & 0xFFFFFFFF:08x}:" +
                         "".join(f" {w:08x}" for w in words[i:i + 8]))
    if screen:
        words = link.read(screen_base, SCREEN_WIDTH * SCREEN_HEIGHT)
        chars = "".join(chr(w & 0xFF) if 0x20 < w & 0xFF < 0x7F else " "
                        for w in words)
        rows = [chars[y * SCREEN_WIDTH:(y + 1) * SCREEN_WIDTH].rstrip()
                for y in range(SCREEN_HEIGHT)]
        while rows and not rows[-1]:
            rows.pop()
        lines.append("Screen:")
        lines += [f"|{row}" for row in rows]
    return lines


def report(link: Link, dumps: list[tuple[int, int]], screen: bool,
           screen_base: int, symbols: Symbols | None) -> int:
    """Prints what niceemu prints after a halt, and returns its exit
    status. The dumps are read before the instruction counter, as niceemu
    prints them after its report, so that a dump of the counter's high word
    shows the snapshot that the program left, as niceemu's does. The low word
    is read before the high word, which on the board is the snapshot that
    the read of the low word takes. With symbols, a halt other than HALT
    names where the program was, if the file has any labels, as niceemu
    does."""
    why = link.read_word(HALT_REASON)
    regs = link.read(REGS, 16)
    if why not in REASONS:
        fail(f"the core has not halted (reason {why})")
    extra = dump_lines(link, dumps, screen, screen_base)
    lo, hi = link.read(INSTR_LO, 2)
    lines = [f"Halted ({REASONS[why]}) after {hi << 32 | lo} steps, "
             f"PC={regs[15]:08x}"]
    if symbols is not None and symbols.addrs and why != 1:
        lines += where_lines(symbols, regs)
    for row in range(4):
        lines.append(" ".join(f"R{i:<2} {regs[i]:08x}"
                              for i in range(4 * row, 4 * row + 4)))
    print("\n".join(lines + extra), flush=True)
    return 0 if why == 1 else 2


def report_timeout(link: Link, timeout: float, dumps: list[tuple[int, int]],
                   screen: bool, screen_base: int) -> int:
    """Holds the core, prints the time limit and the dumps, and returns
    niceemu's exit status for the step limit. A hold leaves the registers
    undefined, so there are none, and no location for --symbols either."""
    link.control(HOLD | RAM)
    out = link.take_console()
    sys.stdout.buffer.write(out)
    lines = [f"Stopped at the time limit after {timeout:g} s"]
    lines += dump_lines(link, dumps, screen, screen_base)
    print("\n".join(lines), flush=True)
    print("run.py: the core is held in reset", file=sys.stderr)
    return 3


def open_input(path: str) -> int:
    """Opens the input file, or exits with a message as niceemu does. A
    directory opens, but every read of it fails."""
    try:
        infd = os.open(path, os.O_RDONLY)
    except OSError as e:
        fail(f"cannot read {path}: {e.strerror}")
    if stat.S_ISDIR(os.fstat(infd).st_mode):
        fail(f"cannot read {path}: it is a directory")
    return infd


class Parser(argparse.ArgumentParser):
    """An argument parser that takes options as niceemu does: each one
    whole and on its own, with its value as the next argument, and a usage
    error exits 1, niceemu's status for one, not 2, its status for a halt
    other than HALT."""

    def __init__(self, **kwargs) -> None:
        super().__init__(allow_abbrev=False, **kwargs)

    def error(self, message: str) -> NoReturn:
        self.print_usage(sys.stderr)
        self.exit(1, f"{self.prog}: error: {message}\n")

    def parse_args(self, args=None, namespace=None):
        args = sys.argv[1:] if args is None else args
        options = {s: a.nargs != 0 for a in self._actions
                   for s in a.option_strings}
        i = 0
        while i < len(args):
            arg = args[i]
            if arg in options:
                i += 2 if options[arg] else 1
                continue
            # Not "--dump=1:2", "-d1:2", "-sd", or "--", as argparse takes
            if len(arg) > 1 and arg.startswith("-"):
                self.error(f"unknown option '{arg}'")
            i += 1
        return super().parse_args(args, namespace)


def main() -> None:
    parser = Parser(description=__doc__.splitlines()[0])
    add_arguments(parser)
    parser.add_argument("-i", "--input", default="-",
                        help="read the console's input from FILE, not stdin")
    parser.add_argument("-d", "--dump", type=dump_option, action="append",
                        default=[], metavar="ADDR:N",
                        help="after halting, print N memory words from ADDR; "
                        "decimal, or hex after 0x, up to %d words" % MAX_DUMP)
    parser.add_argument("-s", "--screen", action="store_true",
                        help="after halting, print the 80x25 character screen")
    parser.add_argument("-2004", dest="ide2004", action="store_true",
                        help="like niceemu -2004: the screen is at 0x400, "
                        "plain memory on the board")
    parser.add_argument("--no-cycle-counter", action="store_true",
                        help="accepted and ignored: the cycle counter always "
                        "runs")
    parser.add_argument("--symbols", metavar="FILE",
                        help="read the labels of niceasm.py --symbols from "
                        "FILE, and name where a halt other than HALT, and a "
                        "wasm trap, happened")
    # 60 s is a limit so that a program that never halts does not hold the
    # board for good; 0 turns it off
    parser.add_argument("--timeout", type=float, default=60,
                        metavar="SEC",
                        help="give up after SEC seconds, with exit status 3 "
                        "(default %(default)s, 0 for none)")
    parser.add_argument("file",
                        help="a .bin file: one 'address word' hex pair per line")
    args = parser.parse_args()

    words = read_bin(args.file)
    symbols = Symbols(args.symbols) if args.symbols else None
    infd = 0 if args.input == "-" else open_input(args.input)
    screen_base = SCREEN_2004 if args.ide2004 else SCREEN
    link = open_link(args)
    try:
        load_words(link, words)
        start(link)
        try:
            halted = run(link, infd, args.timeout)
        except KeyboardInterrupt:
            link.control(HOLD | RAM)
            print("\nrun.py: interrupted; the core is held in reset", file=sys.stderr)
            sys.exit(130)
        if halted:
            status = report(link, args.dump, args.screen, screen_base, symbols)
        else:
            status = report_timeout(link, args.timeout, args.dump, args.screen,
                                    screen_base)
        if link.overflows:
            print(f"run.py: the program's input buffer overflowed "
                  f"{link.overflows} times", file=sys.stderr)
    except LinkError as e:
        fail(str(e))
    link.close()
    sys.exit(status)


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        # stdout closed early, as by "run.py ... | head": exit quietly with
        # the status of SIGPIPE, as niceemu does, and keep Python from
        # writing to the pipe again at exit
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        sys.exit(141)
