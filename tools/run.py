#!/usr/bin/env python3
"""Run a program on the MEGA65 as niceemu runs it on the emulator.

The program is loaded into cleared memory through the debug link, and
started. Its input is sent to the UART, and its output copied to stdout.
When it halts, the link sends a stop notice after its last output, and
this prints what niceemu prints after a halt: why and after
how many steps the program halted, the registers, and the --dump and
--screen output. The exit status is that of niceemu, 0 after HALT and 2
after any other halt. So the output of the two can be compared:

    diff <(niceemu -i in.txt prog.bin) <(tools/run.py -i in.txt prog.bin)

Usage: tools/run.py [--port /dev/ttyUSB1] [--baud 2000000] [--wait X]
                    [-i FILE] [-d ADDR:N]... [-s] [--timeout SEC] FILE.bin

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
seconds, with exit status 3, and leaves the core running. --wait 1000
suits the simulation of "make -C sim cosim", where a break cannot be sent,
so the end of the input does not reach the program. Only the Python
standard library is used.
"""

import argparse
import os
import select
import sys
import termios
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import nicelink as nl                                    # noqa: E402

SCREEN_WIDTH = 80
SCREEN_HEIGHT = 25


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


def run(link: nl.Link, infd: int, timeout: float) -> None:
    """Copies the input to the UART and the console output to stdout until
    the stop notice."""
    out = sys.stdout.buffer
    end = time.monotonic() + timeout if timeout else None
    while not link.stops:
        out.write(link.console())
        out.flush()
        wait = [link.fd] + ([infd] if infd >= 0 else [])
        left = end - time.monotonic() if end else None
        if left is not None and left <= 0:
            print(f"run.py: no halt after {timeout} s; the core still runs",
                  file=sys.stderr)
            sys.exit(3)
        ready, _, _ = select.select(wait, [], [], left)
        if infd in ready:
            data = os.read(infd, 256)
            if data:
                link.send_console(data)
            else:
                # The end of the input: a break, after the bytes before it.
                termios.tcdrain(link.fd)
                try:
                    termios.tcsendbreak(link.fd, 0)
                except termios.error:
                    pass        # a pseudo-terminal, of the simulation
                infd = -1
        if link.fd in ready:
            link.pump(0)
    out.write(link.console())
    out.flush()


def report(link: nl.Link, dumps: list[tuple[int, int]], screen: bool) -> int:
    """Prints what niceemu prints after a halt, and returns its exit
    status. The low word of the instruction counter is read before the high
    word, which is the snapshot that the read of the low word takes."""
    why = link.read1(nl.HALT_WHY)
    lo, hi = link.read(nl.INSTR_LO, 2)
    regs = link.regs()
    if why not in nl.HALT_REASONS:
        nl.fail(f"the core has not halted (reason {why})")
    lines = [f"Halted ({nl.HALT_REASONS[why]}) after {hi << 32 | lo} steps, "
             f"PC={regs[15]:08x}"]
    for row in range(4):
        lines.append(" ".join(f"R{i:<2} {regs[i]:08x}"
                              for i in range(4 * row, 4 * row + 4)))
    for addr, n in dumps:
        words = link.read(addr, n)
        for i in range(0, n, 8):
            lines.append(f"{(addr + i) & 0xFFFFFFFF:08x}:" +
                         "".join(f" {w:08x}" for w in words[i:i + 8]))
    if screen:
        words = link.read(nl.SCREEN, SCREEN_WIDTH * SCREEN_HEIGHT)
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
    parser.add_argument("--port", default=nl.PORT)
    parser.add_argument("--baud", type=int, default=nl.BAUD)
    parser.add_argument("--wait", type=float, default=1.0)
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

    image = nl.read_bin(args.file)
    infd = 0 if args.input == "-" else os.open(args.input, os.O_RDONLY)
    link = nl.Link.open(args.port, args.baud, args.wait)
    try:
        link.sync()
        link.load(image)
        link.start()
        try:
            run(link, infd, args.timeout)
        except KeyboardInterrupt:
            print("\nrun.py: interrupted; the core still runs", file=sys.stderr)
            sys.exit(130)
        status = report(link, args.dump, args.screen)
    except nl.LinkError as e:
        nl.fail(str(e))
    link.close()
    sys.exit(status)


if __name__ == "__main__":
    main()
