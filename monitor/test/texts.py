#!/usr/bin/env python3
"""Check that each packed text of the ROM ends with a 0 byte.

Usage: test/texts.py SOURCE...

niceasm.py's .ASCII_B adds no 0 after a text whose length is a multiple
of 4 (nice_cpu's ISA.md §10.3), and puts_b, which prints a text, stops
only at a 0 byte (monitor.nasm). So such a text needs a .DAT 0 on the
next line, and the script reports each one without it, with its file
and its line, and exits with status 1. Only the Python standard library
is used.
"""

import re
import sys

TEXT = re.compile(r"""^\S*\s+\.ASCII_B\s+(['"])(.*)\1\s*(;.*)?$""")
END = re.compile(r"^\s+\.DAT\s+0\s*(;.*)?$")


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(str(__doc__).split("\n\n")[1])
    bad = 0
    for path in sys.argv[1:]:
        with open(path) as f:
            lines = f.read().split("\n")
        for n, line in enumerate(lines):
            m = TEXT.match(line)
            if m and len(m[2]) % 4 == 0 and not (n + 1 < len(lines) and END.match(lines[n + 1])):
                print(f"{path}:{n + 1}: a text of {len(m[2])} characters needs a .DAT 0 after it")
                bad += 1
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
