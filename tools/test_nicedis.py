#!/usr/bin/env python3
"""Test nicedis.py: each program of nice_cpu is assembled, disassembled, and
assembled again, which must give the same words. Files that do not assemble,
such as the assembler's error tests, are skipped.

Usage: tools/test_nicedis.py
"""

import glob
import os
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TOOLS)
sys.path.insert(0, TOOLS)
sys.path.insert(0, f"{REPO}/nice_cpu/assembler")

import nicedis                                           # noqa: E402
import niceasm                                           # noqa: E402

def assemble(lines: list[str], name: str) -> dict[int, int]:
    asm = niceasm.Assembler()
    errors = asm.run(lines, name)
    if errors:
        raise ValueError(errors[0])
    return dict(asm.output())


def main() -> None:
    files = sorted(glob.glob(f"{REPO}/nice_cpu/**/*.nasm", recursive=True))
    tested = failed = 0
    for path in files:
        with open(path, encoding="latin-1") as f:
            lines = f.readlines()
        try:
            words = assemble(lines, path)
        except ValueError:
            continue
        if not words:
            continue
        tested += 1
        name = os.path.relpath(path, REPO)
        try:
            lines = [f"        {text}\n" for _, text in nicedis.listing(words)]
            again = assemble(lines, name + " (disassembled)")
        except ValueError as e:
            print(f"FAIL {name}: {e}")
            failed += 1
            continue
        if again != words:
            bad = next(a for a in sorted(words) if again.get(a) != words[a])
            print(f"FAIL {name}: the word at {bad:08x} is {again.get(bad, 0):08x}, "
                  f"not {words[bad]:08x}")
            failed += 1
    print(f"{'FAIL' if failed else 'PASS'} test_nicedis: {tested - failed} of "
          f"{tested} programs the same after disassembly")
    sys.exit(1 if failed or not tested else 0)


if __name__ == "__main__":
    main()
