#!/usr/bin/env python3
"""Measure the ROM's words, and keep their tables in monitor/INTERNALS.md.

The tables of "The ROM's words" in monitor/INTERNALS.md are this
script's output, between the comments <!-- romsize NAME --> and
<!-- /romsize NAME -->. The ROM is two images, assembled apart, the
monitor's and BASIC's (issue #152), and each has a table. The script
joins the sources of each as the Makefile does, with a label in front of each part and of each run of .ASCII
strings, with the .DAT 0 that ends a packed one, assembles them with
niceasm.py --symbols, and takes each part's words from the labels'
addresses. The words it assembles must
be those of the build's .bin, or it fails, so a label never moves a
word.

  romsize.py rom --doc D [--write] --monitor B SOURCES... --basic B SOURCES...
      the tables of the monitor and of BASIC, and the table of the ROM;
      after each option, the image's .bin, then the files that the
      monitor's Makefile joins into it, in its order
  romsize.py demo --bin B --doc D [--write] SOURCES...
      the demo's table, of demo.bin, which is not in the ROM (#129), in
      demo/README.md

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

# The sources of the two images, by their names, and what each one is
ROM_PARTS = {
    "monitor.nasm": "The dispatch table, the HAL, and the cold start",
    "basic.nasm": "The vectors, the main loop, the scanner, the keywords, the messages, "
                  "and the help",
    "basic_cmd.nasm": "The routines of the statements that were the commands",
    "basic_net.nasm": "`DHCP`, `NTP`, and TFTP",
    "basic_time.nasm": "`TIME`, and the clock's side of `NTP`",
    "basic_dis.nasm": "The disassembler of `DIS`",
    "monitor_sd.nasm": "The sector routines",
    "monitor_fat.nasm": "FAT32, the file entries, and TAB",
    "monitor_eth.nasm": "The network, and its entries",
    "monitor_tcp.nasm": "TCP",
    "monitor_clock.nasm": "The clock: `clock_set`, the dates of files, and the real-time clock",
    "common.nasm": "What the monitor and BASIC share: texts, IP addresses, and dates",
    "monlib.nasm": "The routines that programs join",
    "mon.nasm": "The stubs of the entries",
    "folder.nasm": "The folder's name",
    "basic_folder.nasm": "The texts with the folder's name: `DIR`'s, and the error of a "
                         "card without it",
    "version_test.nasm": "The version in the banner, the tests' `V9.9`",
}
# The sources that are nice_cpu's
NICE_CPU_SOURCES = {"demo.nasm"}
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
    "colors.nasm": "The names of the colors, which take no words",
    "text.nasm": "The board's texts: the name, the welcome, the keys, and "
                 "the note on the clock",
    "version.nasm": "The version in the title bar, the tests' `V9.9`",
}


class Part(NamedTuple):
    """A part of an image: its source, what it is, its words, and how
    many of them are .ASCII text."""
    source: str
    what: str
    words: int
    text: int


class Marker:
    """Joins sources with labels in front of the parts and the runs of
    .ASCII strings, and gives each part's words and text once the joined
    file is assembled."""

    def __init__(self) -> None:
        self.lines: list[str] = []
        self.parts: list[tuple[str, str]] = []
        self.runs = 0
        self.in_run = False

    def part(self, source: str, what: str) -> None:
        self.end_run()
        self.lines.append(f"ZZP_{len(self.parts)}\n")
        self.parts.append((source, what))

    def end_run(self) -> None:
        if self.in_run:
            self.lines.append(f"ZZE_{self.runs}\n")
            self.runs += 1
            self.in_run = False

    def line(self, line: str) -> None:
        # A .DAT 0 right after a text is its end, the 0 byte of a packed
        # text whose length is a multiple of 4 (monitor/monitor.nasm)
        is_text = re.match(r"^\S*\s+\.ASCII", line) is not None or (
            self.in_run and re.match(r"^\s+\.DAT\s+0\s*(;.*)?$", line) is not None)
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
        return [Part(source, what, ends[i] - labels[f"ZZP_{i}"], text[i])
                for i, (source, what) in enumerate(self.parts)]


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


def table(parts: list[Part]) -> list[str]:
    rows = ["| Source | What it is | Words | Text |", "|---|---|---:|---:|"]
    for p in parts:
        rows.append(f"| {p.source} | {p.what} | {p.words} | {p.text} |")
    rows.append(f"| In all | | {sum(p.words for p in parts)} | "
                f"{sum(p.text for p in parts)} |")
    return rows


def image_table(bin_path: str, sources: list[str]) -> tuple[list[str], int, int]:
    """The table of an image, and its first address and its end."""
    marker = Marker()
    for path in sources:
        marker.part(source_name(path), ROM_PARTS[os.path.basename(path)])
        for line in open(path):
            marker.line(line)
    parts = marker.measure(bin_path)
    addrs = [a for a, _ in words(bin_path)]
    first, end = min(addrs), max(addrs) + 1
    # The first part starts at 0, before its .ORG, BASIC's at 0x4000
    parts[0] = parts[0]._replace(words=parts[0].words - first)
    if sum(p.words for p in parts) != end - first:
        sys.exit(f"romsize.py: the parts of {bin_path} do not add up to its words")
    return table(parts), first, end


def rom_tables(args: argparse.Namespace) -> dict[str, list[str]]:
    monitor, mon_first, mon_end = image_table(args.monitor[0], args.monitor[1:])
    basic, bas_first, bas_end = image_table(args.basic[0], args.basic[1:])
    rom = 0x8000
    if mon_first != 0 or mon_end > bas_first or bas_end > rom:
        sys.exit("romsize.py: the images overlap, or pass the ROM")
    layout = [
        "| Part | Address | Words |",
        "|---|---|---:|",
        f"| The monitor | `0x0000`–`0x{mon_end - 1:04X}` | {mon_end} |",
        f"| Free | `0x{mon_end:04X}`–`0x{bas_first - 1:04X}` | {bas_first - mon_end} |",
        f"| BASIC | `0x{bas_first:04X}`–`0x{bas_end - 1:04X}` | {bas_end - bas_first} |",
        f"| Free | `0x{bas_end:04X}`–`0x{rom - 1:04X}` | {rom - bas_end} |",
    ]
    return {"layout": layout, "monitor": monitor, "basic": basic}


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
        f"The code is {n_code} words, and the texts and tables {span - n_code}. "
        f"They are at `0x{first:04X}`–`0x{first + span - 1:04X}`, in {len(demo)} "
        "lines of `demo.bin`, one for each word but the unused ones, which "
        "the assembler skips.",
    ]
    return {"demo": demo_rows}


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
    parser.add_argument("image", choices=["rom", "demo"])
    parser.add_argument("--bin", help="the demo's .bin, which must match")
    parser.add_argument("--monitor", nargs="+", metavar="FILE",
                        help="the monitor's .bin, which must match, and its sources")
    parser.add_argument("--basic", nargs="+", metavar="FILE",
                        help="BASIC's .bin, which must match, and its sources")
    parser.add_argument("--doc", required=True, help="the Markdown file with the tables")
    parser.add_argument("--write", action="store_true", help="write the tables into it")
    parser.add_argument("sources", nargs="*")
    # The demo's sources follow its options
    args = parser.parse_intermixed_args()
    if args.image == "rom":
        if not args.monitor or len(args.monitor) < 2 or not args.basic or len(args.basic) < 2:
            parser.error("rom needs --monitor and --basic, each with a .bin and its sources")
        tables = rom_tables(args)
    else:
        if not args.bin or not args.sources:
            parser.error("demo needs --bin and its sources")
        tables = demo_tables(args)
    ok = update(args.doc, tables, args.write)
    if ok and not args.write:
        print(f"PASS romsize {args.image}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
