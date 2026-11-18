#!/usr/bin/env python3
"""Check that BASIC reaches the monitor through the dispatch table alone.

Usage: test/sides.py [-v]

The ROM is one assembly, the cat of the Makefile's SOURCES, so every
file reaches every label. Issue #152 splits it into the monitor and
BASIC, which calls the monitor through the entries of the dispatch
table only, as a program does: their .EQUs in mon.nasm. Until the two
are assembled apart, this script keeps the boundary. The files are of
the monitor (MONITOR), of BASIC (BASIC), or shared (COMMON, with the
library of programs, LIBRARY), and each name is defined in the file
where a line starts with it. The script reports, with its file and its
line, each use of a routine or of data of one side by the other, and
each use by COMMON of a name of either side, and exits with status 1.
VECTORS are the two places in BASIC that the monitor goes to, at the
cold start and after a program, which become fixed vectors when BASIC
has an image of its own. A file of SOURCES in none of the lists, or one
in a list that SOURCES has not, is an error too.

A name defined with .EQU may still cross: the RAM's variables, which
both sides take from one map in monitor.nasm until the RAM map is split,
and the monitor's constants. -v lists them. Only the Python standard
library is used.
"""

import collections
import os
import re
import sys
from typing import Dict, List, Set

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MONITOR = ["monitor.nasm", "monitor_sd.nasm", "monitor_fat.nasm", "monitor_eth.nasm",
           "monitor_tcp.nasm", "monitor_clock.nasm"]
BASIC = ["basic.nasm", "monitor_cmd.nasm", "basic_net.nasm", "basic_time.nasm",
         "monitor_dis.nasm"]
COMMON = ["common.nasm"]
LIBRARY = ["monlib.nasm", "mon.nasm"]
VECTORS = {"bas_start", "bas_warm"}

NAME = re.compile(r"[A-Za-z_.][A-Za-z_0-9.]*")
TEXT = re.compile(r"'[^']*'|\"[^\"]*\"")


def lines(path: str) -> List[str]:
    with open(os.path.join(HERE, path)) as f:
        return f.read().split("\n")


def defined(paths: List[str]) -> Dict[str, bool]:
    """The names that the files define, each with True for an .EQU."""
    names: Dict[str, bool] = {}
    for path in paths:
        for line in lines(path):
            m = NAME.match(line)
            if m:
                names[m[0]] = bool(re.match(r"\S+\s+\.EQU\b", line))
    return names


def used(path: str) -> Dict[str, List[int]]:
    """The names that the file's lines use, past their labels, with the
    numbers of those lines; texts and comments left out."""
    uses: Dict[str, List[int]] = collections.defaultdict(list)
    for n, line in enumerate(lines(path), 1):
        code = TEXT.sub("", line).split(";")[0]
        m = NAME.match(code)
        if m:
            code = code[m.end():]
        for name in NAME.findall(code):
            uses[name].append(n)
    return uses


def sources() -> Set[str]:
    """The files of the Makefile's SOURCES."""
    with open(os.path.join(HERE, "Makefile")) as f:
        m = re.search(r"^SOURCES\s*=((?:.*\\\n)*.*)", f.read(), re.M)
    assert m, "no SOURCES in the Makefile"
    return set(m[1].replace("\\", " ").split())


def main() -> None:
    verbose = sys.argv[1:] == ["-v"]
    if sys.argv[1:] not in ([], ["-v"]):
        sys.exit(str(__doc__).split("\n\n")[1])
    listed = set(MONITOR + BASIC + COMMON + LIBRARY)
    if listed != sources():
        sys.exit(f"sides.py: SOURCES and the lists differ in {' '.join(sorted(listed ^ sources()))}")
    sides = {"monitor": defined(MONITOR), "BASIC": defined(BASIC), "common": defined(COMMON)}
    library: Set[str] = set(defined(LIBRARY))
    checks = [(MONITOR, "monitor", ["BASIC"]), (BASIC, "BASIC", ["monitor"]),
              (COMMON, "common", ["monitor", "BASIC"])]
    bad = 0
    equs: Dict[str, Set[str]] = collections.defaultdict(set)
    for paths, own, others in checks:
        mine = set(sides[own]) | library
        if own != "common":
            mine |= set(sides["common"])
        for path in paths:
            for name, numbers in sorted(used(path).items()):
                if name in mine or name in VECTORS:
                    continue
                for other in others:
                    if name not in sides[other]:
                        continue
                    if sides[other][name]:
                        equs[f"{own} uses the {other}'s"].add(name)
                        continue
                    for n in numbers:
                        print(f"{path}:{n}: {own} uses {name} of the {other}")
                        bad += 1
    if verbose:
        for what, names in sorted(equs.items()):
            print(f"{what} .EQUs: {' '.join(sorted(names))}")
    if bad:
        sys.exit(f"sides.py: {bad} uses across the boundary, which an entry must take")


if __name__ == "__main__":
    main()
