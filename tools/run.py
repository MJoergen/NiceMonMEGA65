#!/usr/bin/env python3
"""Run a program on the MEGA65 as niceemu runs it on the emulator.

The program is loaded into cleared memory with the command line, and
started. Its input is sent to the UART, and its output copied to stdout.
When it halts, the command line takes the UART again and prints a halt
message, and this prints what niceemu prints after a halt: why and after
how many steps the program halted, the registers, and the --dump and
--screen output. The exit status is that of niceemu, 0 after HALT and 2
after any other halt. So the output of the two can be compared:

    diff <(niceemu -i in.txt prog.bin) <(tools/run.py -i in.txt prog.bin)

Usage: tools/run.py [--port /dev/ttyUSB1] [--baud 115200] [-i FILE]
                    [-d ADDR:N]... [-s] [-2004] [--symbols FILE]
                    [--timeout SEC] FILE.bin

The input is stdin, or the file of -i. The bytes go to the UART in chunks
of 16, each sent before the next is read, so that little input is on its
way when the core halts, and the core's input FIFO holds 2048 bytes, so a program
must not fall more than that behind its input, or bytes are lost. At the
end of the input, a break on the UART ends the core's input too, so a read
returns 0x200, as in the emulator. Input that the program has not read when
it halts is dropped, as by the emulator.

The halt message is the same bytes that a program can print. Output that may
be its start is held back for at most 20 ms, and the message counts as a halt
only when nothing follows it for 100 ms. So a program that prints it and
then keeps running is copied, but one that prints it and then waits longer
than that is taken for halted, and the report then says the core has not.

The steps are the core's instruction counter, which the emulator's step
count equals, unless the program starts the timer, which counts clock
cycles here and steps in the emulator. But the emulator waits for each
input byte, and the core does not: while no byte has arrived, a read
returns 0. So a program that waits for input in a loop runs more steps
here. The memory has 64K words, repeated through the address space, so a
dump beyond them reads the same words again. --timeout gives up after SEC
seconds (60 by default), prints a line for the time limit, and exits with
status 3, as niceemu does after its step limit. It prints no registers and
no --dump or --screen output, and the core still runs, for the command line
cannot answer until the core halts or the board is reset. -2004 and
--no-cycle-counter are accepted and ignored: the screen is printed as the
80x25 characters in any case, and the cycle counter always runs.
--symbols FILE reads the labels that niceasm.py --symbols writes, and after
a halt other than HALT prints where the program was, "At label+0x1f", and
after a halt at ___wasm_trap, the default wasm trap handler, the trap's
code from R1 and its location from R2, as niceemu does. At the time limit
there are no registers, so no location, where niceemu prints one at its
step limit. Only the Python standard library is used.
"""

import argparse
import bisect
import os
import select
import sys
import termios
import time

from load import (HALT_MESSAGE, drain, fail, load_words, open_port, read_bin,
                  read_words, start)

HALT_WHY = 0xFFFFFFF1
INSTR_LO = 0xFFFFFF42
INSTR_HI = 0xFFFFFF43
REGS = 0xFFFFFFE0
CLI_ONLY_FIRST = 0xFFFFFFE0
CLI_ONLY_LAST = 0xFFFFFFF1
MAX_DUMP = 0x10000
INPUT_CHUNK = 16    # bytes of input sent before the next are read
HELD_QUIET = 0.02   # seconds without output that end a held start
HALT_QUIET = 0.1    # seconds without output after the halt message
SCREEN = 0xFFFF0000
SCREEN_WIDTH = 80
SCREEN_HEIGHT = 25

# The halt reasons that the control register at 0xFFFFFFF1 returns, as the
# emulator describes them
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
        try:
            with open(path) as f:
                text = f.read()
        except OSError as e:
            fail(f"cannot read {path}: {e.strerror}")
        symbols = []
        for line_no, line in enumerate(text.splitlines(), 1):
            fields = line.split()
            if not fields:
                continue
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
    try:
        addr, n = text.split(":")
        addr, n = number(addr), number(n)
    except ValueError as e:
        raise argparse.ArgumentTypeError(f"'{text}': {e}, want ADDR:N")
    if n > MAX_DUMP:
        raise argparse.ArgumentTypeError(
            f"'{text}': N is larger than {MAX_DUMP}, the words of the RAM")
    return addr, n


def dump_address(addr: int) -> int:
    """The address to read a dumped word at. The command line sees R0-R15, the
    control register, and the halt reason at 0xFFFFFFE0-F1, where the core and
    niceemu see memory, and that memory is the RAM word at 0x0000FFE0-F1."""
    if CLI_ONLY_FIRST <= addr <= CLI_ONLY_LAST:
        return addr & 0xFFFF
    return addr


def run(fd: int, infd: int, timeout: float) -> bool:
    """Copies the input to the UART and the UART to stdout until the halt
    message, which is not copied. Returns False if the time is up first.

    The halt message is the bytes that the command line prints, and a program
    can print them too. So the bytes that may be the start of the message, or
    the message itself, are held back only while the board is busy: a pause of
    HELD_QUIET ends the wait for the rest of a start, and the message counts
    as a halt only if nothing follows it for HALT_QUIET. The input goes out
    in chunks, each sent before the next is read, so that little of it is
    outstanding at the halt, where it would reach the command line."""
    out = sys.stdout.buffer
    held = b""      # output that may be the start of the halt message
    pending = b""   # input that is read and not yet sent
    end = time.monotonic() + timeout if timeout else None
    sent = False
    halted = False
    while not halted:
        if pending:
            os.write(fd, pending[:INPUT_CHUNK])
            termios.tcdrain(fd)
            pending = pending[INPUT_CHUNK:]
            sent = True
        wait = [fd] + ([infd] if infd >= 0 and not pending else [])
        left = end - time.monotonic() if end else None
        if left is not None and left <= 0:
            out.write(held)
            out.flush()
            return False
        quiet = HALT_QUIET if held == HALT_MESSAGE else HELD_QUIET
        wake = quiet if held else None
        if left is not None and (wake is None or left < wake):
            wake = left
        if pending:
            wake = 0
        ready, _, _ = select.select(wait, [], [], wake)
        if not ready and held and not pending and wake == quiet:
            if held == HALT_MESSAGE:
                halted = True
            else:
                out.write(held)
                out.flush()
                held = b""
            continue
        if infd in ready:
            data = os.read(infd, 256)
            if data:
                pending = data
            else:
                # The end of the input: a break, after the bytes before it.
                termios.tcdrain(fd)
                termios.tcsendbreak(fd, 0)
                infd = -1
        if fd in ready:
            held += os.read(fd, 4096)
            while (i := held.find(HALT_MESSAGE)) >= 0:
                if i + len(HALT_MESSAGE) == len(held):
                    break
                # Something follows it, so it was the program's output.
                j = i + len(HALT_MESSAGE)
                out.write(held[:j])
                held = held[j:]
            if held.endswith(HALT_MESSAGE):
                out.write(held[:-len(HALT_MESSAGE)])
                held = HALT_MESSAGE
            else:
                # Keep back only what may be the start of the halt message.
                keep = next((k for k in range(len(HALT_MESSAGE) - 1, 0, -1)
                             if held.endswith(HALT_MESSAGE[:k])), 0)
                out.write(held[:len(held) - keep])
                held = held[len(held) - keep:]
            out.flush()
    if sent:
        # Input sent after the halt reached the command line. A CR ends what
        # it has of a line, and the answer is dropped.
        time.sleep(0.05)
        os.write(fd, b"\r")
        drain(fd, 0.2)
    return True


def dump_lines(fd: int, dumps: list[tuple[int, int]],
               screen: bool) -> list[str]:
    """The --dump and --screen output."""
    lines = []
    for addr, n in dumps:
        words = read_words(fd, [dump_address((addr + i) & 0xFFFFFFFF)
                                for i in range(n)])
        for i in range(0, n, 8):
            lines.append(f"{(addr + i) & 0xFFFFFFFF:08x}:" +
                         "".join(f" {w:08x}" for w in words[i:i + 8]))
    if screen:
        words = read_words(fd, [SCREEN + i
                                for i in range(SCREEN_WIDTH * SCREEN_HEIGHT)])
        chars = "".join(chr(w & 0xFF) if 0x20 < w & 0xFF < 0x7F else " "
                        for w in words)
        rows = [chars[y * SCREEN_WIDTH:(y + 1) * SCREEN_WIDTH].rstrip()
                for y in range(SCREEN_HEIGHT)]
        while rows and not rows[-1]:
            rows.pop()
        lines.append("Screen:")
        lines += [f"|{row}" for row in rows]
    return lines


def report(fd: int, dumps: list[tuple[int, int]], screen: bool,
           symbols: Symbols | None) -> int:
    """Prints what niceemu prints after a halt, and returns its exit
    status. The dumps are read before the instruction counter, as niceemu
    prints them after its report, so that a dump of the counter's high word
    shows the snapshot that the program left, as niceemu's does. The low word
    is read before the high word, which is the snapshot that the read of the
    low word takes. With symbols, a halt other than HALT names where the
    program was."""
    why, *regs = read_words(fd, [HALT_WHY] + [REGS + i for i in range(16)])
    if why not in REASONS:
        fail(f"the core has not halted (reason {why})")
    extra = dump_lines(fd, dumps, screen)
    lo, hi = read_words(fd, [INSTR_LO, INSTR_HI])
    lines = [f"Halted ({REASONS[why]}) after {hi << 32 | lo} steps, "
             f"PC={regs[15]:08x}"]
    if symbols is not None and why != 1:
        lines += where_lines(symbols, regs)
    for row in range(4):
        lines.append(" ".join(f"R{i:<2} {regs[i]:08x}"
                              for i in range(4 * row, 4 * row + 4)))
    print("\n".join(lines + extra), flush=True)
    return 0 if why == 1 else 2


def report_timeout(timeout: float) -> int:
    """Prints the time limit, and returns niceemu's exit status for the step
    limit. The core still runs, and the command line cannot answer, so there
    is no location for --symbols either."""
    print(f"Stopped at the time limit after {timeout:g} s", flush=True)
    print("run.py: the core still runs; reset the board to use the command "
          "line again", file=sys.stderr)
    return 3


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", default="/dev/ttyUSB1")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("-i", "--input", default="-",
                        help="read the console's input from FILE, not stdin")
    parser.add_argument("-d", "--dump", type=dump_option, action="append",
                        default=[], metavar="ADDR:N",
                        help="after halting, print N memory words from ADDR")
    parser.add_argument("-s", "--screen", action="store_true",
                        help="after halting, print the 80x25 character screen")
    parser.add_argument("-2004", dest="ide2004", action="store_true",
                        help="accepted and ignored, as the screen is the "
                        "same here")
    parser.add_argument("--no-cycle-counter", action="store_true",
                        help="accepted and ignored: the cycle counter always "
                        "runs")
    parser.add_argument("--symbols", metavar="FILE",
                        help="read the labels of niceasm.py --symbols from "
                        "FILE, and name where a halt other than HALT, and a "
                        "wasm trap, happened")
    parser.add_argument("--timeout", type=float, default=60,
                        help="give up after SEC seconds, with exit status 3 "
                        "(default 60, 0 for none)")
    parser.add_argument("file")
    args = parser.parse_args()

    words = read_bin(args.file)
    symbols = Symbols(args.symbols) if args.symbols else None
    infd = 0 if args.input == "-" else os.open(args.input, os.O_RDONLY)
    fd = open_port(args.port, args.baud)
    load_words(fd, words)
    start(fd)
    try:
        halted = run(fd, infd, args.timeout)
    except KeyboardInterrupt:
        print("\nrun.py: interrupted; the core still runs", file=sys.stderr)
        sys.exit(130)
    if halted:
        status = report(fd, args.dump, args.screen, symbols)
    else:
        status = report_timeout(args.timeout)
    os.close(fd)
    sys.exit(status)


if __name__ == "__main__":
    main()
