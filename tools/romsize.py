#!/usr/bin/env python3
"""Measure the ROM's words, and keep their tables in monitor/INTERNALS.md.

The tables of "The ROM's words" in monitor/INTERNALS.md are this
script's output, between the comments <!-- romsize NAME --> and
<!-- /romsize NAME -->. The script joins the sources as the Makefile
does, with a label in front of each part and of each run of .ASCII
strings, assembles them with niceasm.py --symbols, and takes each
part's words from the labels' addresses. The words it assembles must
be those of the build's .bin, or it fails, so a label never moves a
word.

  romsize.py monitor --bin B --c C [--c C...] --doc D [--write] SOURCES...
      the monitor's table; SOURCES are the files that the monitor's
      Makefile joins, in its order, rom_c.nasm among them, and C the
      files of ROM_C, which split rom_c.nasm's functions
  romsize.py demo --bin B --monitor M --demo-at A --doc D [--write] SOURCES...
      the demo's table, and the table of the ROM, with the monitor's
      .bin M and the address A of the demo's number of words

Without --write, it compares the tables with those in D, and exits with
1 when they differ: make -C monitor test and make -C demo test run it
so. With --write, it writes them into D: make romsize. Only the Python
standard library is used.
"""

import argparse
import difflib
import os
import re
import subprocess
import sys
import tempfile
from typing import NamedTuple

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NICEASM = os.path.join(REPO, "nice_cpu", "assembler", "niceasm.py")

# The monitor's sources, by their names, and what each one is
MONITOR_PARTS = {
    "monitor.nasm": "The dispatch table, the HAL, the cold start, and the traps",
    "monitor_cmd.nasm": "The main loop and the commands",
    "monitor_dis.nasm": "The disassembler of `u`",
    "monitor_sd.nasm": "The sector routines",
    "monitor_eth.nasm": "The network",
    "monlib.nasm": "The routines that programs join",
    "mon.nasm": "The stubs of the entries",
    "lib.nasm": "The runtime of the C code",
    "muldiv_mpu.nasm": "Multiply and divide",
    "folder.nasm": "The error of a card without the folder",
    "version_test.nasm": "The version in the banner, the tests' `V9.9`",
}
# The C files of ROM_C, by their names, and what each one is
C_PARTS = {
    "fat32.c": "FAT32",
    "clock.c": "The clock and `time`",
}
# The sources that are nice_cpu's
NICE_CPU_SOURCES = {"lib.nasm", "muldiv_mpu.nasm", "demo.nasm"}
# The demo's parts: the label that starts each, what it is, and whether
# it is code. The words before the first label are the entry's.
DEMO_PARTS = [
    ("TYPEW", "F1, the typewriter, with `CELL`, `FILL`, and `PRINT`, "
     "which the other demos call too", True),
    ("KCODES", "F3, the key codes", True),
    ("CHARS", "F5, the characters and the colors", True),
    ("COUNTS", "F7, the counters and the prime sieve, with `DEC64`, "
     "which F9 and F11 call too", True),
    ("GAME", "F9, the comet", True),
    ("BOARD", "F11, the self-tests and the network's addresses", True),
    ("MONITOR", "F12, the return to the monitor", True),
    ("POLL", "The keys and their escape sequences, the frame of the "
     "screen, and the scroll", True),
    ("FKEYS", "The function keys, the menu, the title bar, and the welcome", False),
    ("K_TEXTS", "The texts of F3", False),
    ("C_TEXTS", "The texts and the colors of F5", False),
    ("P_TEXTS", "The texts of F7", False),
    ("G_TEXTS", "The texts and the steps of F9, and the shifts of F11's "
     "MAC address", False),
    ("S_TEXTS", "The texts of F11", False),
    ("MATH", "The script of F11's test of the math unit", False),
]
DEMO_FILES = {
    "text.nasm": "The board's texts: the name, the welcome, the keys, and "
                 "the note on the clock",
    "version.nasm": "The version in the title bar, the tests' `V9.9`",
}


class Part(NamedTuple):
    """A part of an image: its source, what it is, its words, and how
    many of them are .ASCII text, or None where text is not counted."""
    source: str
    what: str
    words: int
    text: int | None


class Marker:
    """Joins sources with labels in front of the parts and the runs of
    .ASCII strings, and gives each part's words and text once the joined
    file is assembled."""

    def __init__(self) -> None:
        self.lines: list[str] = []
        self.parts: list[tuple[str, str, bool]] = []
        self.runs = 0
        self.in_run = False

    def part(self, source: str, what: str, count_text: bool = True) -> None:
        self.end_run()
        self.lines.append(f"ZZP_{len(self.parts)}\n")
        self.parts.append((source, what, count_text))

    def end_run(self) -> None:
        if self.in_run:
            self.lines.append(f"ZZE_{self.runs}\n")
            self.runs += 1
            self.in_run = False

    def line(self, line: str) -> None:
        is_text = re.match(r"^\S*\s+\.ASCII", line) is not None
        if is_text and not self.in_run:
            self.lines.append(f"ZZT_{self.runs}_{len(self.parts) - 1}\n")
            self.in_run = True
        elif not is_text and self.in_run and line.strip() \
                and not line.lstrip().startswith(";"):
            self.end_run()
        self.lines.append(line if line.endswith("\n") else line + "\n")

    def measure(self, bin_path: str) -> list[Part]:
        """Assemble, check the words against bin_path, and give the parts."""
        self.end_run()
        self.lines.append("ZZP_END\n")
        with tempfile.TemporaryDirectory() as tmp:
            src = os.path.join(tmp, "all.nasm")
            out = os.path.join(tmp, "all.bin")
            sym = os.path.join(tmp, "all.sym")
            with open(src, "w") as f:
                f.writelines(self.lines)
            subprocess.run([sys.executable, NICEASM, "--symbols", sym, "-o", out, src],
                           check=True)
            if words(out) != words(bin_path):
                sys.exit(f"romsize.py: the measured words differ from {bin_path}")
            labels: dict[str, int] = {}
            with open(sym) as f:
                for entry in f:
                    hex_addr, name = entry.split()
                    if name.startswith("ZZ"):
                        labels[name] = int(hex_addr, 16)
        text = [0] * len(self.parts)
        for name, start in labels.items():
            if name.startswith("ZZT_"):
                _, run, part = name.split("_")
                text[int(part)] += labels[f"ZZE_{run}"] - start
        ends = [labels[f"ZZP_{i}"] for i in range(1, len(self.parts))] + [labels["ZZP_END"]]
        return [Part(source, what, ends[i] - labels[f"ZZP_{i}"],
                     text[i] if count_text else None)
                for i, (source, what, count_text) in enumerate(self.parts)]


def words(path: str) -> list[tuple[int, int]]:
    """The address and word pairs of a .bin file."""
    with open(path) as f:
        return [(int(a, 16), int(w, 16)) for a, w in (line.split() for line in f if line.strip())]


def source_name(path: str) -> str:
    """The name of a source in the tables: nice_cpu's as such, the
    build's with build/, and the others as they are."""
    base = os.path.basename(path)
    if base in NICE_CPU_SOURCES:
        return f"nice_cpu's `{base}`"
    if os.path.basename(os.path.dirname(os.path.abspath(path))) in ("build", "test"):
        return f"`build/{base}`"
    return f"`{base}`"


def c_functions(path: str) -> set[str]:
    """The names of the functions that a C file defines, from the lines
    that start a definition at the first column."""
    names = set()
    with open(path) as f:
        for line in f:
            m = re.match(r"^(?!return\b)[A-Za-z_][\w \t*]*?\b(\w+)\s*\([^;]*$", line)
            if m:
                names.add(m[1])
    return names


def join_rom_c(marker: Marker, path: str, c_files: list[str]) -> None:
    """rom_c.nasm, split into nicewasm's start, each C file's functions,
    the C library's, nicewasm's helpers, and the initial values."""
    defined = {os.path.basename(c): c_functions(c) for c in c_files}
    marker.part("`nicewasm`", "`___wasm_start`, which copies the C code's data to the RAM",
                False)
    current = ""
    in_functions = False
    for line in open(path):
        m = re.match(r"^; Function \d+: (\w+)", line)
        if m:
            in_functions = True
            # The linker keeps the files' functions in the order of the
            # files, and two files may each have a static function of one
            # name, so the owner is the first file from the current one on
            # that defines the name
            files = list(defined)
            start = files.index(current) if current in files else 0
            owner = next((c for c in files[start:] if m[1] in defined[c]), "lib")
            if owner != current:
                current = owner
                if owner == "lib":
                    marker.part("nice_cpu's C library", "", False)
                else:
                    marker.part(f"`{owner}`", C_PARTS[owner], False)
            if owner == "lib":
                source, what, count_text = marker.parts[-1]
                names = what.split(", ") if what else []
                marker.parts[-1] = (source, ", ".join(names + [f"`{m[1]}`"]), count_text)
        elif in_functions and re.match(r"^; W\.\w+", line):
            in_functions = False
            marker.part("`nicewasm`", "The helpers of the translated code: loads, stores, "
                        "and traps", False)
        elif line.startswith("W.init"):
            marker.part("`nicewasm`", "The initial values of the C code's data: its strings "
                        "and tables", False)
        marker.line(line)


def table(parts: list[Part]) -> list[str]:
    rows = ["| Source | What it is | Words | Text |", "|---|---|---:|---:|"]
    for p in parts:
        rows.append(f"| {p.source} | {p.what} | {p.words} | "
                    f"{'' if p.text is None else p.text} |")
    total_text = sum(p.text or 0 for p in parts)
    rows.append(f"| In all | | {sum(p.words for p in parts)} | {total_text} |")
    return rows


def monitor_tables(args: argparse.Namespace) -> dict[str, list[str]]:
    marker = Marker()
    for path in args.sources:
        base = os.path.basename(path)
        if base == "rom_c.nasm":
            join_rom_c(marker, path, args.c)
            continue
        marker.part(source_name(path), MONITOR_PARTS[base])
        for line in open(path):
            marker.line(line)
    parts = marker.measure(args.bin)
    return {"monitor": table(parts)}


def demo_tables(args: argparse.Namespace) -> dict[str, list[str]]:
    marker = Marker()
    code = {label for label, _, is_code in DEMO_PARTS if is_code}
    whats = {label: what for label, what, _ in DEMO_PARTS}
    seen: list[str] = []
    for path in args.sources:
        base = os.path.basename(path)
        if base == "demo.nasm":
            for line in open(path):
                m = re.match(r"^([A-Z_][A-Z0-9_]*)\b", line)
                if m and m[1] in whats and ".EQU" not in line:
                    marker.part(f"`demo.nasm`, `{m[1]}`", whats[m[1]])
                    seen.append(m[1])
                marker.line(line)
                # The image starts here; the .ORG and .RES before it are
                # the variables, which are not in it
                if re.match(r"^\s+\.ORG\s+0x8000\b", line):
                    marker.part("`demo.nasm`, from `0x8000`",
                                "The entry, the vector of the timer's interrupt at "
                                "`0x8041`, and the unused words before it")
        else:
            marker.part(f"`demo/{base}`" if base == "text.nasm" else source_name(path),
                        DEMO_FILES[base])
            for line in open(path):
                marker.line(line)
    missing = [label for label in whats if label not in seen]
    if missing:
        sys.exit(f"romsize.py: no label {', '.join(missing)} in demo.nasm; "
                 "update DEMO_PARTS")
    parts = marker.measure(args.bin)
    demo = words(args.bin)
    first = min(a for a, _ in demo)
    span = max(a for a, _ in demo) + 1 - first
    if sum(p.words for p in parts) != span:
        sys.exit("romsize.py: the demo's parts do not add up to its words")
    n_code = parts[0].words + sum(
        p.words for p in parts if any(p.source.endswith(f"`{c}`") for c in code))
    demo_rows = table(parts) + [
        "",
        f"The code is {n_code} words, and the texts and tables {span - n_code}.",
    ]
    monitor_end = max(a for a, _ in words(args.monitor)) + 1
    at = int(args.demo_at, 0)
    demo_end = at + 1 + span
    rom = 0x8000
    layout = [
        "| Part | Address | Words |",
        "|---|---|---:|",
        f"| The monitor | `0x0000`–`0x{monitor_end - 1:04X}` | {monitor_end} |",
        f"| Free | `0x{monitor_end:04X}`–`0x{at - 1:04X}` | {at - monitor_end} |",
        f"| The demo, with its number of words in front | `0x{at:04X}`–`0x{demo_end - 1:04X}` "
        f"| {span + 1} |",
        f"| Free | `0x{demo_end:04X}`–`0x{rom - 1:04X}` | {rom - demo_end} |",
        "",
        f"Without the demo, {rom - monitor_end} words are free. The demo's words "
        f"in the ROM are the {span} of `0x{first:04X}`–`0x{first + span - 1:04X}`, "
        "after the word with their number.",
    ]
    return {"layout": layout, "demo": demo_rows}


def update(doc: str, tables: dict[str, list[str]], write: bool) -> bool:
    """Compare the tables with those of doc, or write them into it.
    True when they were the same."""
    with open(doc) as f:
        old = f.read()
    new = old
    for name, rows in tables.items():
        pattern = re.compile(rf"(<!-- romsize {name} -->\n).*?(<!-- /romsize {name} -->)",
                             re.S)
        if not pattern.search(new):
            sys.exit(f"romsize.py: no <!-- romsize {name} --> in {doc}")
        new = pattern.sub(lambda m: m[1] + "\n".join(rows) + "\n" + m[2], new)
    if new == old:
        return True
    if write:
        with open(doc, "w") as f:
            f.write(new)
        print(f"romsize.py: wrote the tables of {', '.join(tables)} into {doc}")
        return True
    sys.stdout.writelines(difflib.unified_diff(old.splitlines(True), new.splitlines(True),
                                               doc, "measured"))
    print(f"FAIL romsize: the tables of {doc} differ from the build; run make romsize")
    return False


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("image", choices=["monitor", "demo"])
    parser.add_argument("--bin", required=True, help="the build's .bin, which must match")
    parser.add_argument("--doc", required=True, help="the Markdown file with the tables")
    parser.add_argument("--write", action="store_true", help="write the tables into it")
    parser.add_argument("--c", action="append", default=[],
                        help="a C file of rom_c.nasm, once for each")
    parser.add_argument("--monitor", help="the monitor's .bin, for the demo's table of the ROM")
    parser.add_argument("--demo-at", help="the address of the demo in the ROM")
    parser.add_argument("sources", nargs="+")
    args = parser.parse_args()
    if args.image == "monitor":
        tables = monitor_tables(args)
    else:
        if not args.monitor or not args.demo_at:
            parser.error("demo needs --monitor and --demo-at")
        tables = demo_tables(args)
    ok = update(args.doc, tables, args.write)
    if ok and not args.write:
        print(f"PASS romsize {args.image}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
