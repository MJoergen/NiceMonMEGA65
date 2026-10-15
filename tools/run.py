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
                    [-d ADDR:N]... [-s] [--timeout SEC] FILE.bin

The input is stdin, or the file of -i. Each byte goes to the UART as soon
as it is read, and the core's input FIFO holds 2048 bytes, so a program
must not fall more than that behind its input, or bytes are lost. At the
end of the input, a break on the UART ends the core's input too, so a read
returns 0x200, as in the emulator. Input that the program has not read when
it halts is dropped, as by the emulator.

The steps are the core's instruction counter, which the emulator's step
count equals, as no interrupts are raised. But the emulator waits for each
input byte, and the core does not: while no byte has arrived, a read
returns 0. So a program that waits for input in a loop runs more steps
here. The memory has 64K words,
repeated through the address space, so a dump beyond them reads the same
words again. --timeout gives up after SEC seconds, with exit status 3, and
leaves the core running. Only the Python standard library is used.
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
INSTR_LO = 0xFFFFFF12
INSTR_HI = 0xFFFFFF13
REGS = 0xFFFFFFE0
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
    """A number of an option, decimal or hex after 0x, as niceemu takes."""
    if text[:2] in ("0x", "0X"):
        return int(text[2:], 16)
    if not text.isdigit():
        raise ValueError(text)
    return int(text)


def dump_option(text: str) -> tuple[int, int]:
    try:
        addr, n = text.split(":")
        return number(addr) & 0xFFFFFFFF, number(n)
    except ValueError:
        raise argparse.ArgumentTypeError(f"'{text}' is not ADDR:N")


def run(fd: int, infd: int, timeout: float) -> None:
    """Copies the input to the UART and the UART to stdout until the halt
    message, which is not copied."""
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
            print(f"run.py: no halt after {timeout} s; the core still runs",
                  file=sys.stderr)
            sys.exit(3)
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


def report(fd: int, dumps: list[tuple[int, int]], screen: bool) -> int:
    """Prints what niceemu prints after a halt, and returns its exit
    status. The low word of the instruction counter is read before the high
    word, which is the snapshot that the read of the low word takes."""
    why, lo, hi, *regs = read_words(fd, [HALT_WHY, INSTR_LO, INSTR_HI] +
                                    [REGS + i for i in range(16)])
    if why not in REASONS:
        fail(f"the core has not halted (reason {why})")
    lines = [f"Halted ({REASONS[why]}) after {hi << 32 | lo} steps, "
             f"PC={regs[15]:08x}"]
    for row in range(4):
        lines.append(" ".join(f"R{i:<2} {regs[i]:08x}"
                              for i in range(4 * row, 4 * row + 4)))
    for addr, n in dumps:
        words = read_words(fd, [(addr + i) & 0xFFFFFFFF for i in range(n)])
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
    print("\n".join(lines), flush=True)
    return 0 if why == 1 else 2


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
    parser.add_argument("--timeout", type=float, default=0,
                        help="give up after SEC seconds, with exit status 3")
    parser.add_argument("file")
    args = parser.parse_args()

    words = read_bin(args.file)
    infd = 0 if args.input == "-" else os.open(args.input, os.O_RDONLY)
    fd = open_port(args.port, args.baud)
    load_words(fd, words)
    start(fd)
    try:
        run(fd, infd, args.timeout)
    except KeyboardInterrupt:
        print("\nrun.py: interrupted; the core still runs", file=sys.stderr)
        sys.exit(130)
    status = report(fd, args.dump, args.screen)
    os.close(fd)
    sys.exit(status)


if __name__ == "__main__":
    main()
