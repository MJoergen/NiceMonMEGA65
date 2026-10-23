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
                    [-d ADDR:N]... [-s] [-2004] [--timeout SEC] FILE.bin

The input is stdin, or the file of -i. Each byte goes to the UART as soon
as it is read, and the core's input FIFO holds 2048 bytes, so a program
must not fall more than that behind its input, or bytes are lost. At the
end of the input, a break on the UART ends the core's input too, so a read
returns 0x200, as in the emulator. Input that the program has not read when
it halts is dropped, as by the emulator.

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
80x25 characters in any case, and the cycle counter always runs. Only the
Python standard library is used.
"""

import argparse
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
    message, which is not copied. Returns False if the time is up first."""
    out = sys.stdout.buffer
    held = b""      # output that may be the start of the halt message
    end = time.monotonic() + timeout if timeout else None
    sent = False
    while True:
        wait = [fd] + ([infd] if infd >= 0 else [])
        left = end - time.monotonic() if end else None
        if left is not None and left <= 0:
            out.write(held)
            out.flush()
            return False
        ready, _, _ = select.select(wait, [], [], left)
        if infd in ready:
            data = os.read(infd, 256)
            if data:
                os.write(fd, data)
                sent = True
            else:
                # The end of the input: a break, after the bytes before it.
                termios.tcdrain(fd)
                termios.tcsendbreak(fd, 0)
                infd = -1
        if fd in ready:
            held += os.read(fd, 4096)
            i = held.find(HALT_MESSAGE)
            if i >= 0:
                out.write(held[:i])
                out.flush()
                break
            # Keep back only what may be the start of the halt message.
            keep = next((k for k in range(len(HALT_MESSAGE) - 1, 0, -1)
                         if held.endswith(HALT_MESSAGE[:k])), 0)
            out.write(held[:len(held) - keep])
            out.flush()
            held = held[len(held) - keep:]
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


def report(fd: int, dumps: list[tuple[int, int]], screen: bool) -> int:
    """Prints what niceemu prints after a halt, and returns its exit
    status. The dumps are read before the instruction counter, as niceemu
    prints them after its report, so that a dump of the counter's high word
    shows the snapshot that the program left, as niceemu's does. The low word
    is read before the high word, which is the snapshot that the read of the
    low word takes."""
    why, *regs = read_words(fd, [HALT_WHY] + [REGS + i for i in range(16)])
    if why not in REASONS:
        fail(f"the core has not halted (reason {why})")
    extra = dump_lines(fd, dumps, screen)
    lo, hi = read_words(fd, [INSTR_LO, INSTR_HI])
    lines = [f"Halted ({REASONS[why]}) after {hi << 32 | lo} steps, "
             f"PC={regs[15]:08x}"]
    for row in range(4):
        lines.append(" ".join(f"R{i:<2} {regs[i]:08x}"
                              for i in range(4 * row, 4 * row + 4)))
    print("\n".join(lines + extra), flush=True)
    return 0 if why == 1 else 2


def report_timeout(timeout: float) -> int:
    """Prints the time limit, and returns niceemu's exit status for the step
    limit. The core still runs, and the command line cannot answer."""
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
    parser.add_argument("--timeout", type=float, default=60,
                        help="give up after SEC seconds, with exit status 3 "
                        "(default 60, 0 for none)")
    parser.add_argument("file")
    args = parser.parse_args()

    words = read_bin(args.file)
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
        status = report(fd, args.dump, args.screen)
    else:
        status = report_timeout(args.timeout)
    os.close(fd)
    sys.exit(status)


if __name__ == "__main__":
    main()
