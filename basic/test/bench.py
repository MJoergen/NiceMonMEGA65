#!/usr/bin/env python3
"""Run BASIC's benchmarks in niceemu, check their output, and count their steps.

Usage: test/bench.py [--table] NICEEMU ROM.bin BENCH.bas ...

Each BENCH.bas is typed into BASIC after a NEW, as its lines are, and
run with RUN. Its steps are those of the instruction counter, which PEEK
reads at 0xFFFFFF42 in a direct line before RUN and in one after it,
less the same for an empty program, so that the program is as it is
written. The output between RUN and READY. must be S and E for
Rugg/Feldman's, and 1 ITERATION and 1899 PRIMES for the sieve. Prints a
PASS or FAIL line for each, with its steps, or with --table the rows of
a Markdown table of the steps, as doc/BASIC.md has it. Exits with
status 1 when a check fails.
Only the Python standard library is used.
"""

import os
import subprocess
import sys

MAX_STEPS = 100_000_000
PEEK = "? PEEK(0xFFFFFF42)"
EXPECTED = {"sieve": ["1 ITERATION", "1899 PRIMES"]}


def run(emu: str, rom: str, lines: list[str]) -> tuple[list[str], int]:
    """The output of the program between RUN and READY., and its steps
    with those of RUN and READY."""
    keys = ["NEW"] + lines + [PEEK, "RUN", PEEK, "HALT"]
    out = subprocess.run([emu, "-n", str(MAX_STEPS), "-i", "-", rom],
                         input="\r".join(keys) + "\r", capture_output=True,
                         text=True, check=False).stdout
    rows = [r.rstrip("\r") for r in out.split("\n")]
    run_at = rows.index("RUN")
    ready = rows.index("READY.", run_at)
    peeks = [int(rows[i + 1]) for i, r in enumerate(rows) if r == PEEK]
    if len(peeks) != 2:
        sys.exit(f"bench.py: no steps in the output of {lines[:1]}")
    return rows[run_at + 1:ready], peeks[1] - peeks[0]


def main() -> None:
    args = sys.argv[1:]
    table = args[:1] == ["--table"]
    if table:
        args = args[1:]
    if len(args) < 3:
        sys.exit(__doc__)
    emu, rom, paths = args[0], args[1], args[2:]
    _, base = run(emu, rom, [])
    fail = False
    for path in paths:
        name = os.path.splitext(os.path.basename(path))[0]
        with open(path) as f:
            lines = [ln.rstrip("\n") for ln in f if ln.strip()]
        output, steps = run(emu, rom, lines)
        steps -= base
        ok = output == EXPECTED.get(name, ["S", "E"])
        fail |= not ok
        if table:
            print(f"| {name} | {steps} |")
        else:
            print(f"{'PASS' if ok else 'FAIL'} basic bench {name}: {steps} steps")
        if not ok:
            print(f"  output: {output}")
    sys.exit(1 if fail else 0)


if __name__ == "__main__":
    main()
