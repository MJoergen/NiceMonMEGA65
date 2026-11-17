#!/usr/bin/env python3
"""The suites of the monitor's tests of FAT32 that take more than one run
of niceemu each (Makefile, INTERNALS.md, "The tests"). They pin what
monitor_fat.nasm does, card by card and sector by sector, so that a
change of it shows (issue #149). Each suite is a list of runs; each run
puts copies of test/fat_image.py's images into the slots, types its
input, with the program of a file of fs_* calls of test/
(test/fat_tool.py, OPS) at 0x8000 when it has one, and shows:

- the console output, a CR before an LF left out, another control code
  as ^ and a letter, and a byte from 0x7F as \\xNN, and the exit status;
- the program's calls and their results (fat_tool.py log);
- each card against the image it was copied from (fat_tool.py diff),
  which is "the card as it was" when the run wrote nothing;
- with fsck, fsck.fat -n of the card of slot 0, without its first line
  and with the image's path as IMAGE;
- with order, the order of the sector writes (fat_tool.py order), from a
  second run with -t on fresh copies.

Every run has --step-time, so that it takes the same steps each time,
and the clock is not set, so that every date written is the fixed one.
The output of the suite SUITE is compared with test/SUITE.expected, and
written to BUILD/SUITE.out.

The behavior that is pinned here though it is odd, the possible bugs B2
to B8 of the audit of issue #149, is marked "known oddity" in the titles
of the runs and the comments of the OPS files: it stays until a change
of its own fixes it.

Usage: test/fat_runs.py NICEEMU MONITOR.bin BUILD SUITE...
"""

import contextlib
import io
import os
import re
import subprocess
import sys
from typing import Callable, List, NamedTuple, Optional

import fat_tool

HERE = os.path.dirname(os.path.abspath(__file__))
ASM = os.path.join(HERE, "..", "..", "nice_cpu", "assembler", "niceasm.py")
MON_NASM = os.path.join(HERE, "..", "mon.nasm")
STEPS = 20_000_000


class Run(NamedTuple):
    title: str
    sd0: Optional[str]          # an image of BUILD/fat, copied
    sd1: Optional[str] = None
    keys: str = "halt\r"        # the console input
    ops: Optional[str] = None   # a file of test/, the program at 0x8000
    ro1: bool = False           # slot 1's card write-protected
    fsck: bool = False
    order: bool = False
    steps: int = STEPS


RUN = "sys 0x8000\rhalt\r"
LOAD_WORDS = 'save "{}", 0x8000, {}\r'

SUITES = {
    # P3: what the cold start and a program's return keep
    "fatstate": [
        Run("A handle across SYS 0, which closes it; both handles in use after a "
            "return, so LOAD and SAVE get error 23 and DIR and TAB work; then the "
            "program's handles still read", "super.img",
            keys='sys 0x8000\rsys 0\rsys 0x8400\rsys 0x8800\rload "hello.bin"\r'
                 'save "x", 0x8000, 1\rdir\rload h\t\003sys 0x8C00\rhalt\r',
            ops="fatstate.ops"),
        Run("SYS 0 forgets the mount of slot 1: DIR mounts slot 0 again",
            "lfn.img", "super.img", keys="dir 1\rsys 0\rdir\rhalt\r"),
        Run("DIR 0 mounts the mounted slot again and closes the program's handle",
            "super.img", keys="sys 0x9000\rdir 0\rsys 0x9400\rhalt\r", ops="fatstate.ops"),
    ],
    # P4: LOAD's lines
    "fatload": [
        Run("LOAD of CR LF, of blank lines only, of a chain cut after its second "
            "cluster, and of lines of every kind", "lines.img",
            keys='load "crlf.bin"\rdump 0x8100, 4\rdump 0xFFFFF079, 5\r'
                 'load "blank.bin"\rdump 0xFFFFF079, 5\r'
                 'load "cut.bin"\rdump 0xFFFFF079, 5\rdump 0x9036, 4\r'
                 'load "lines.bin"\rdump 0x8000, 0x14\rdump 0x8020, 1\rdump 0xFFFFF079, 5\r'
                 'halt\r'),
    ],
    # P5: TAB, and the cases of issue #145
    "fattab": [
        Run("TAB after a quote, in another case and in the same, of an alias, in "
            "words after blanks and strings, and a list longer than the screen",
            "lfn.img",
            keys='load "MY\t\003load "mand\t\003load _\t\003load MYPROG\t\003load ""\t\003'
                 'dir "my\t\003  load my\t\003 load  "my\t\003load x"my\t\003'
                 'load "my prog.bin" my\t\003load "Mixed.b\t\003load "across a s\t\003'
                 'load "\t\003load p\t\003load pad\t\003halt\r'),
        Run("TAB with slot 1 mounted by DIR 1: its names, a directory left out, "
            "and names that end at the line's end, 76 characters, or past it",
            "lfn.img", "tab1.img",
            keys='dir 1\rload h\t\003load hd\t\003load a\t\003load b\t\003load "a\t\003'
                 'load "b\t\003halt\r'),
        Run("TAB after SAVE and DELETE", "super.img",
            keys='load z\t\003save "zebra", 0x8000, 1\rload z\t\003save "Hz", 0x8000, 1\r'
                 'load h\t\003delete "zebra.bin"\rload z\t\003halt\r', order=True),
    ],
    # P6: a mount dropped under open files
    "fatdrop": [
        Run("SD_SELECT written under open files, and fs_mount under a file open "
            "to write", "super.img", "super.img", keys="sys 0x8000\rdir\rhalt\r",
            ops="fatdrop.ops", fsck=True, order=True),
    ],
    # P7: damaged chains
    "fatchain": [
        Run("Reads, opens, and deletes of damaged chains; SAVE over a file whose "
            "chain meets a free cluster, which ends it (issue #151, B3)", "chains.img",
            keys='sys 0x8000\rsave "free.txt", 0x8000, 1\rdir\rhalt\r',
            ops="fatchain.ops", fsck=True, order=True),
    ],
    # P8: long names on the card
    "fatlfn": [
        Run("Long names of 13 and 26 characters, which fill their entries",
            "super.img", keys=RUN, ops="fatlfn_new.ops", fsck=True, order=True),
        Run("Damaged entries: 0x05 for 0xE5, orphan long-name entries, a label, a "
            "broken set, a name of 256 characters, and a byte from 0x80 in an "
            "8.3 name, reached as DIR shows them (issue #151, B5)", "lfnx.img",
            keys="dir\rsys 0x8000\rhalt\r", ops="fatlfn_bad.ops"),
        Run("DELETE of long names across a sector and a cluster, and of an 8.3 "
            "name whose long name's checksum is wrong, which leaves it as an "
            "orphan (known oddity B2)", "lfn.img",
            keys='delete "badsum~1.bin"\rdelete "across a cluster.bin"\r'
                 'delete "ACROSS A SECTOR.BIN"\rhalt\r', fsck=True, order=True),
    ],
    # P9: mounting, and cards that are not FAT32
    "fatmount": [Run(f"DIR of {img}", img, keys="dir\rhalt\r") for img in (
        "m_fat12.img", "m_fat16.img", "m_fat12p.img", "m_nopart.img", "m_zero.img",
        "m_p83.img", "m_pb.img", "m_nosig.img", "m_jump.img", "m_bps.img", "m_spc0.img",
        "m_spc3.img", "m_rsvd0.img", "m_nfats0.img", "m_fatsz0.img", "m_fatszbig.img",
        "m_nodata.img", "m_fat16sz.img", "m_rootent.img", "m_c4084.img", "m_c4085.img",
        "m_c65524.img", "m_c65525.img", "m_root1.img", "m_roottop.img", "m_nicecl.img",
        "m_fatwrap.img", "m_baddir.img")] + [
        Run("No card in either slot", None, keys='dir\rdir 0\rload "x.bin"\rhalt\r'),
        Run("DIR with a slot of 2^31 and more has no such slot (issue #151, B1)",
            "lfn.img", "super.img",
            keys="dir 1\rdir 2147483648\rdir 4294967295\rdir 2\rhalt\r"),
    ],
    # P10: other geometries
    "fatgeo": [Run(f"SAVE, LOAD, DIR, and DELETE on {img}", img,
                   keys='save "big", 0x8000, 2000\rsave "a long name of a file.bin", 0x8000, 3\r'
                        'save "two", 0x8000, 2\rdelete "two.bin"\rload "big.bin"\r'
                        'load "A LONG NAME OF A FILE.BIN"\rdir\rhalt\r',
                   fsck=True, order=True)
               for img in ("spc8.img", "spc64.img", "fat1.img")],
    # P11: FSInfo, and the FAT's entries
    "fatinfo": [Run(title, img, keys=keys, ops="fatinfo.ops", order=True) for title, img, keys in (
        ("A file of 3 clusters from FSInfo's hint", "super.img", RUN),
        ("The file, then its delete, which moves the hint back", "super.img",
         "sys 0x8000\rsys 0x8400\rhalt\r"),
        ("The hint at the last cluster, which is free, so the hint goes round",
         "i_last.img", RUN),
        ("The hint at the last cluster, which is in use, so the search goes round",
         "i_wrap.img", RUN),
        ("The hint 0xFFFFFFFF, which is no cluster", "i_ff.img", RUN),
        ("FSInfo without its signature, which is left alone", "i_nosig.img", RUN),
        ("No FSInfo in the boot sector: 0", "i_bpb0.img", RUN),
        ("No FSInfo in the boot sector: 0xFFFF, past the reserved sectors",
         "i_bpbff.img", RUN),
        ("The free entries 32 to 39 with their top 4 bits set", "i_top.img", RUN),
        ("The same, the file deleted", "i_top.img", "sys 0x8000\rsys 0x8400\rhalt\r"),
        ("A volume larger than its FATs: the last cluster that they hold, and "
         "the one after it", "i_total.img", "sys 0x8800\rhalt\r"))],
    # P12: a full card, and a full folder
    "fatfull": [
        Run("fs_write on a card with 3 free clusters", "full.img", keys=RUN,
            ops="fatfull_card.ops", fsck=True, order=True),
        Run("A folder of 65535 entries and one free", "bigdir.img", keys=RUN,
            ops="fatfull_dir.ops", steps=400_000_000),
    ],
    # P13: DIR's rows
    "fatrows": [
        Run("DIR of names of 23 to 26 characters, a hidden empty file, a system "
            "file, a directory, and a size of 10 digits", "rows.img", keys="dir\rhalt\r"),
    ],
    # P14 to P16: the file entries' small cases
    "fatapi": [
        Run("Names and modes, reads of 0 bytes and of a file open twice, words "
            "above 0xFF written, and a directory handle's sector", "super.img",
            keys="sys 0x8000\rsys 0x8400\rsys 0x8800\rhalt\r", ops="fatapi.ops",
            fsck=True, order=True),
        Run("Mode 1 of a directory, the order of the errors with both handles in "
            "use, and fs_delete of a file open to write", "fat32.img",
            keys="sys 0x8C00\rhalt\r", ops="fatapi.ops", order=True),
    ],
}


def console(raw: bytes) -> str:
    """niceemu's output as text, without the registers of the halt."""
    out = ""
    text = raw.replace(b"\r\n", b"\n")
    for c in text:
        if c == 0x0A or 0x20 <= c < 0x7F:
            out += chr(c)
        elif c < 0x20:
            out += "^" + chr(c + 64)
        else:
            out += f"\\x{c:02x}"
    return re.sub(r"Halted \(HALT\)[^\n]*\n(R[^\n]*\n)*?R12 [^\n]*\n", "", out)


def capture(f: Callable[..., None], *args: object) -> str:
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        f(*args)
    return buf.getvalue()


def run_one(emu: str, rom: str, build: str, suite: str, n: int, r: Run) -> str:
    work = os.path.join(build, "fat_runs")
    os.makedirs(work, exist_ok=True)
    stem = os.path.join(work, f"{suite}{n}")
    full = stem + ".full.bin"
    words = 0
    with open(full, "w") as f:
        f.write(open(rom).read())
        if r.ops:
            segs = fat_tool.ops(os.path.join(HERE, r.ops))
            words = fat_tool.words(segs) * max(1, r.keys.count("sys 0x"))
            with open(stem + ".nasm", "w") as g:
                g.write(fat_tool.program(segs) + open(MON_NASM).read())
            subprocess.run([sys.executable, ASM, "-o", stem + ".prog.bin", stem + ".nasm"],
                           check=True, stdout=subprocess.DEVNULL)
            f.write(open(stem + ".prog.bin").read())
    with open(stem + ".txt", "wb") as keys:
        keys.write(r.keys.encode("latin-1"))

    def cards() -> List[str]:
        opts = []
        for slot, img in ((0, r.sd0), (1, r.sd1)):
            if img:
                card = f"{stem}.{slot}.img"
                if os.path.exists(card):
                    os.chmod(card, 0o644)
                subprocess.run(["cp", "--sparse=always", os.path.join(build, "fat", img), card],
                               check=True)
                if slot == 1 and r.ro1:
                    os.chmod(card, 0o444)
                opts += [f"--sd{slot}", card]
        return opts

    cmd = [emu, "--step-time", "-n", str(r.steps), "-i", stem + ".txt"]
    p = subprocess.run(cmd + (["-d", f"0x{fat_tool.LOG:X}:{words + 16}"] if r.ops else [])
                       + cards() + [full], stdout=subprocess.PIPE)
    out = f"== {r.title}\n"
    if r.ops:
        with open(stem + ".raw", "wb") as raw:
            raw.write(p.stdout)
        out += console(capture(fat_tool.log, segs, stem + ".raw").encode("latin-1"))
    else:
        out += console(p.stdout)
    out += f"exit {p.returncode}\n"
    for slot, img in ((0, r.sd0), (1, r.sd1)):
        if img:
            out += f"Slot {slot}: " + capture(fat_tool.diff, os.path.join(build, "fat", img),
                                               f"{stem}.{slot}.img", False)
    if r.fsck and r.sd0:
        fsck = subprocess.run(["fsck.fat", "-n", f"{stem}.0.img"], stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True)
        lines = fsck.stdout.replace(f"{stem}.0.img", "IMAGE").splitlines(keepends=True)[1:]
        out += "fsck.fat -n:\n" + "".join(lines) + \
            (f"(exit {fsck.returncode})\n" if fsck.returncode else "")
    if r.order:
        t = subprocess.Popen(cmd + ["-t"] + cards() + [full], stdout=subprocess.PIPE)
        o = subprocess.run([sys.executable, os.path.join(HERE, "fat_tool.py"), "order"]
                           + [x for slot, img in (("--sd0", r.sd0), ("--sd1", r.sd1)) if img
                              for x in (slot, os.path.join(build, "fat", img))],
                           stdin=t.stdout, stdout=subprocess.PIPE, text=True, check=True)
        t.wait()
        out += o.stdout
    return out


def main() -> None:
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    emu, rom, build = sys.argv[1:4]
    fail = 0
    for suite in sys.argv[4:]:
        out = "".join(run_one(emu, rom, build, suite, n, r) for n, r in enumerate(SUITES[suite]))
        path = os.path.join(build, suite + ".out")
        with open(path, "w") as f:
            f.write(out)
        expected = os.path.join(HERE, suite + ".expected")
        if os.path.exists(expected) and open(expected).read() == out:
            print(f"PASS monitor {suite}")
        else:
            print(f"FAIL monitor {suite}")
            subprocess.run(["diff", expected, path])
            fail = 1
    sys.exit(fail)


if __name__ == "__main__":
    main()
