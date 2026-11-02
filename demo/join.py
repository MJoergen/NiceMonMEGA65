#!/usr/bin/env python3
"""Join the demo behind the monitor, into the image of the ROM.

The monitor's x copies the demo from the ROM to 0x8000 and runs it there
(monitor/monitor.nasm, cmd_demo). So the ROM has the monitor from 0, and
at DEMO, an .EQU of monitor.nasm, the number of the demo's words, which
are assembled from 0x8000, and the words themselves after it. The words
that the assembler skipped are 0 in the ROM, and so after the copy. This
is for the time being (issue #65), as the demo is.

Usage: demo/join.py MONITOR.bin DEMO.bin -o ROM.bin
"""

import argparse
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MONITOR_NASM = os.path.join(REPO, "monitor", "monitor.nasm")
PROGRAM = 0x8000        # where the demo is assembled, and runs
ROM_WORDS = 0x8000      # the ROM, 0x0000-0x7FFF


def load(path: str) -> list[tuple[int, int]]:
    """The (address, word) pairs of a .bin file (ISA.md §10.4)."""
    words: list[tuple[int, int]] = []
    with open(path) as f:
        for line in f:
            if line.strip():
                a, w = line.split()
                words.append((int(a, 16), int(w, 16)))
    return words


def demo_address() -> int:
    """The value of DEMO in monitor.nasm."""
    with open(MONITOR_NASM) as f:
        m = re.search(r"^DEMO\s+\.EQU\s+(0x[0-9A-Fa-f]+)", f.read(), re.MULTILINE)
    if not m:
        sys.exit(f"join.py: no DEMO .EQU in {MONITOR_NASM}")
    return int(m.group(1), 16)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("monitor")
    parser.add_argument("demo")
    parser.add_argument("-o", dest="out", required=True)
    args = parser.parse_args()
    base = demo_address()
    monitor = load(args.monitor)
    demo = load(args.demo)
    if monitor and monitor[-1][0] >= base:
        sys.exit(f"join.py: the monitor reaches {monitor[-1][0]:08X}, "
                 f"past DEMO, {base:08X}")
    if not demo or demo[0][0] < PROGRAM:
        sys.exit(f"join.py: {args.demo} is not assembled from {PROGRAM:08X}")
    n = demo[-1][0] + 1 - PROGRAM
    if base + 1 + n > ROM_WORDS:
        sys.exit(f"join.py: the demo's {n} words do not fit the ROM "
                 f"from {base + 1:08X}")
    with open(args.out, "w") as f:
        for a, w in monitor:
            f.write(f"{a:08x} {w:08x}\n")
        f.write(f"{base:08x} {n:08x}\n")
        for a, w in demo:
            f.write(f"{a - PROGRAM + base + 1:08x} {w:08x}\n")


if __name__ == "__main__":
    main()
