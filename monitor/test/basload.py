#!/usr/bin/env python3
"""The test of the loader of BASIC's image from a card (issue #153,
monitor_basic.nasm, doc/BASIC_ROM.md, "The cold start").

It takes the ROM of the tests, build/rom_test.bin, whose BASIC has the
flag "keep", and makes the ROM of this test from it, the same BASIC
with "keep" clear, as a release's ROM has it. It makes variants of that
BASIC, as files BASIC*.ROM, each with a version of its own, and with
the text of its version, a word at the address of the header's
BAS_H_TEXT, changed, so that the banner shows which BASIC runs. Some
are broken on purpose. Each run puts them on cards of their own,
FAT32 images that mkfs.fat and mtools make, in the folder NICE, and
runs the ROM in niceemu with the run's input. Its console output, with
the Halted line and the registers left out, and the words that the run
dumps, are compared with test/basload.expected, and written to
BUILD/basload.out.

The ROM in niceemu is RAM, so the loader finds BASIC's half open at
every cold start: SYS 0 loads again, where a board finds it locked.

Usage: test/basload.py NICEEMU ROM_TEST.bin BUILD
"""

import os
import shutil
import subprocess
import sys
from typing import Callable, NamedTuple, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(HERE, "..", "..")
sys.path.insert(0, os.path.join(REPO, "tools"))
import basic_rom  # noqa: E402

ASM = os.path.join(REPO, "nice_cpu", "assembler", "niceasm.py")
STEPS = 60_000_000
Image = dict[int, int]


def text_word(text: str) -> int:
    """Up to 3 characters, packed as .ASCII_B packs them, with a 0 byte."""
    assert len(text) <= 3
    return sum(ord(c) << (8 * i) for i, c in enumerate(text))


def variant(base: Image, version: int, text: str, keep: bool = False,
            ram: Optional[int] = None, entries: Optional[int] = None,
            layout: Optional[int] = None) -> Image:
    """BASIC with another version, text, flags, RAM, or interface, and
    its checksum right."""
    image = dict(base)
    image[basic_rom.H_VERSION] = version
    image[image[basic_rom.H_TEXT]] = text_word(text)
    image[basic_rom.H_FLAGS] = basic_rom.FLAG_KEEP if keep else 0
    if ram is not None:
        image[basic_rom.H_RAM] = ram
    iface = image[basic_rom.H_IFACE]
    if entries is not None:
        iface = iface & 0xFFFF0000 | entries
    if layout is not None:
        iface = layout << 16 | iface & 0xFFFF
    image[basic_rom.H_IFACE] = iface
    image[basic_rom.H_SUM] = 0
    image[basic_rom.H_SUM] = -basic_rom.checksum_of(image, image[basic_rom.H_LENGTH]) \
        & basic_rom.MASK
    return image


def lines(image: Image) -> list[str]:
    return [f"{a:08x} {w:08x}\n" for a, w in sorted(image.items())]


# The breaks of a file, each on the lines of a valid one
def bad_sum(ls: list[str]) -> list[str]:
    a, w = ls[100].split()
    return ls[:100] + [f"{a} {int(w, 16) ^ 1:08x}\n"] + ls[101:]


def bad_magic(ls: list[str]) -> list[str]:
    return ls[:4] + ["00004004 12345678\n"] + ls[5:]


def out_of_place(ls: list[str]) -> list[str]:
    return ls[:6] + ls[7:]          # no line for 0x4006


def outside(ls: list[str]) -> list[str]:
    return ls + ["00008000 00000001\n"]


def falling(ls: list[str]) -> list[str]:
    return ls[:200] + [ls[201], ls[200]] + ls[202:]


def cut_short(ls: list[str]) -> list[str]:
    return ls[:-100]


def bad_line(ls: list[str]) -> list[str]:
    return ls[:300] + ["zz\n"] + ls[300:]


def crlf_blank(ls: list[str]) -> list[str]:
    """CR LF line ends, blank lines, and TABs, which the loader takes."""
    return ["\r\n"] + [line.replace(" ", "\t").replace("\n", "\r\n\r\n") for line in ls]


class File(NamedTuple):
    name: str
    image: Image
    brk: Optional[Callable[[list[str]], list[str]]] = None


class Run(NamedTuple):
    title: str
    sd0: Optional[list[File]]
    sd1: Optional[list[File]] = None
    keys: str = "halt\r"
    rom_keep: bool = False      # the ROM's BASIC keeps "keep"
    prog: Optional[str] = None  # an assembly program, after the ROM
    dump: str = ""


# A program at 0xC000, above the staging area, which mon_exit, entry 1,
# leaves with R1 a word that it pushes at the top of its stack, below
# BASIC's RAM: at 0xFFFFDFFF for 4K words of it, and 0xFFFFE7FF for 2K.
EXIT = """                .ORG    0xC000
                MOVE    R1, 0x1234ABCD
                JMP     2
"""
# The RAM's words for bin_line, 128K as on the MEGA65
RAM128K = "FFFFFF9E 00020000\n"


def card(path: str, files: list[File]) -> None:
    with open(path, "wb") as img:
        img.truncate(40 * 1024 * 1024)
    subprocess.run(["mkfs.fat", "-F", "32", "-s", "1", "-i", "4E494345", path],
                   check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["mmd", "-i", path, "::NICE"], check=True)
    for i, f in enumerate(files):
        src = f"{path}.{i}"
        ls = lines(f.image)
        if f.brk:
            ls = f.brk(ls)
        with open(src, "w", newline="") as out:
            out.writelines(ls)
        subprocess.run(["mcopy", "-i", path, src, f"::NICE/{f.name}"], check=True)


def main() -> None:
    emu, rom_test, build = sys.argv[1:4]
    work = os.path.join(build, "basload")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    words: Image = {}
    with open(rom_test) as f:
        for line in f:
            if line.strip():
                a, w = line.split()
                words[int(a, 16)] = int(w, 16)
    monitor = {a: w for a, w in words.items() if a < basic_rom.BASE}
    base = {a: w for a, w in words.items() if basic_rom.BASE <= a < basic_rom.END}
    # The ROM's BASIC: the tests' V9.9, with "keep" clear, its text kept
    rom_bas = dict(base)
    rom_bas[basic_rom.H_FLAGS] = 0
    rom_bas[basic_rom.H_SUM] = 0
    rom_bas[basic_rom.H_SUM] = -basic_rom.checksum_of(rom_bas, rom_bas[basic_rom.H_LENGTH]) \
        & basic_rom.MASK

    def v(major: int, minor: int, text: str, keep: bool = False,
          ram: Optional[int] = None, entries: Optional[int] = None,
          layout: Optional[int] = None) -> Image:
        return variant(base, major << 24 | minor << 16, text, keep, ram, entries, layout)

    runs = [
        Run("no card: the ROM's BASIC", None, keys="ver\rhalt\r"),
        Run("a card with no BASIC*.ROM", [File("BASIC.BIN", v(10, 0, "A")),
                                          File("NOTBASIC.ROM", v(10, 0, "B"))]),
        Run("a newer BASIC: taken", [File("BASIC-V10.ROM", v(10, 0, "A"))], keys="ver\rhalt\r"),
        Run("its name in lower case, with CR LF, TABs, and blank lines",
            [File("basic-x.rom", v(10, 0, "A"), crlf_blank)]),
        Run("an older BASIC: taken, with a notice", [File("BASIC-V9.8.ROM", v(9, 8, "9.8"))]),
        Run("the ROM's BASIC with keep: no load", [File("BASIC-V10.ROM", v(10, 0, "A"))],
            rom_keep=True),
        Run("a bad checksum", [File("BASIC-1.ROM", v(10, 0, "A"), bad_sum)]),
        Run("no magic word", [File("BASIC-2.ROM", v(10, 0, "A"), bad_magic)]),
        Run("a header line out of place", [File("BASIC-3.ROM", v(10, 0, "A"), out_of_place)]),
        Run("more entries than the table has",
            [File("BASIC-4.ROM", v(10, 0, "A", entries=0xFFFF))]),
        Run("another layout of the monitor's RAM",
            [File("BASIC-5.ROM", v(10, 0, "A", layout=2))]),
        Run("too much RAM", [File("BASIC-6.ROM", v(10, 0, "A", ram=0x4000))]),
        Run("an address past BASIC's half", [File("BASIC-7.ROM", v(10, 0, "A"), outside)]),
        Run("addresses that fall", [File("BASIC-8.ROM", v(10, 0, "A"), falling)]),
        Run("a file cut short", [File("BASIC-9.ROM", v(10, 0, "A"), cut_short)]),
        Run("a bad line", [File("BASIC-10.ROM", v(10, 0, "A"), bad_line)]),
        Run("three versions: the newest", [File("BASIC-A.ROM", v(10, 1, "A1")),
                                           File("BASIC-B.ROM", v(10, 2, "A2")),
                                           File("BASIC-C.ROM", v(10, 0, "A0"))]),
        Run("the newest broken: the next", [File("BASIC-A.ROM", v(10, 1, "A1")),
                                            File("BASIC-B.ROM", v(10, 2, "A2"), bad_sum),
                                            File("BASIC-C.ROM", v(10, 0, "A0"))]),
        Run("all broken: the ROM's", [File("BASIC-A.ROM", v(10, 1, "A1"), cut_short),
                                      File("BASIC-B.ROM", v(10, 2, "A2"), bad_sum)]),
        Run("the same version on both slots: slot 0's",
            [File("BASIC-S.ROM", v(10, 0, "S0"))], [File("BASIC-S.ROM", v(10, 0, "S1"))]),
        Run("a newer one on slot 1", [File("BASIC-S.ROM", v(10, 0, "S0"))],
            [File("BASIC-S.ROM", v(10, 1, "S1"))]),
        Run("slot 1 only", [], [File("BASIC-S.ROM", v(10, 0, "S1"))]),
        Run("SYS 0 loads again in niceemu", [File("BASIC-V10.ROM", v(10, 0, "A"))],
            keys="sys 0\rhalt\r"),
        Run("a file with keep: taken, and SYS 0 keeps it",
            [File("BASIC-V10.ROM", v(10, 0, "A", keep=True))], keys="sys 0\rhalt\r"),
        Run("4K words of BASIC's RAM: mon_exit's stack, and LOAD's end",
            [File("BASIC-V10.ROM", v(10, 0, "A", ram=0x1000))],
            keys="sys 0xC000\rload\r1DFFF 5\r1E000 6\r\rhalt\r",
            prog=EXIT, dump="-d 0xFFFFDFFF:1 -d 0x1DFFF:2"),
        Run("2K words: the same", [File("BASIC-V10.ROM", v(10, 0, "A"))],
            keys="sys 0xC000\rload\r1E7FF 5\r1E800 6\r\rhalt\r",
            prog=EXIT, dump="-d 0xFFFFDFFF:1 -d 0xFFFFE7FF:1 -d 0x1E7FF:2"),
    ]

    out: list[str] = []
    for n, run in enumerate(runs):
        rom = os.path.join(work, f"rom{n}.bin")
        with open(rom, "w") as f:
            f.writelines(lines(monitor))
            f.writelines(lines(base if run.rom_keep else rom_bas))
            if run.prog:
                src = os.path.join(work, f"prog{n}.nasm")
                with open(src, "w") as p:
                    p.write(run.prog)
                subprocess.run([sys.executable, ASM, "-o", src + ".bin", src], check=True)
                with open(src + ".bin") as p:
                    f.write(p.read())
                f.write(RAM128K)
        args = [emu, "-s", "-n", str(STEPS), "-i", os.path.join(work, f"in{n}.txt")]
        with open(args[-1], "w") as f:
            f.write(run.keys)
        for slot, files in ((0, run.sd0), (1, run.sd1)):
            if files is not None:
                img = os.path.join(work, f"card{n}_{slot}.img")
                card(img, files)
                args += [f"--sd{slot}", img]
        args += run.dump.split()
        args.append(rom)
        res = subprocess.run(args, capture_output=True)
        out.append(f"== {run.title}\n")
        skip = False
        for line in res.stdout.decode("latin-1").replace("\r\n", "\n").splitlines():
            if line.startswith("Halted (HALT)"):
                skip = True
            elif skip and line.startswith("R12 "):
                skip = False
                continue
            if not skip:
                out.append(line + "\n")
        out.append(f"exit {res.returncode}\n")

    got = os.path.join(build, "basload.out")
    with open(got, "w") as f:
        f.writelines(out)
    want = os.path.join(HERE, "basload.expected")
    if not os.path.exists(want) or open(want).read() != "".join(out):
        subprocess.run(["diff", want, got])
        print("FAIL monitor basload")
        sys.exit(1)
    print("PASS monitor basload")


if __name__ == "__main__":
    main()
