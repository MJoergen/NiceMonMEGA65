#!/usr/bin/env python3
"""Check tools/sdcard.py on niceemu --link with images of a card, without
a board.

The images are made with mkfs.fat, sfdisk, and mtools, as the monitor's
tests make theirs (monitor/test/fat_image.py), so that the tool's FAT32
is checked against them:

- super.img: FAT32 on the whole card, with clusters of one sector, and in
  its folder NICE a short file, an empty one, a file with a long name, a
  file of 20,000 bytes, which takes 40 clusters, a fragmented one, whose
  chain the script checks is not contiguous, and a subdirectory. The root
  has a file of its own, which the tool does not reach.
- mbr.img: an MBR with one FAT32 partition, with the same NICE/HELLO.TXT.
- nonice.img: FAT32 with no folder NICE, which the tool rejects with the
  monitor's error 29, as --folder OTHER does on super.img.
- fat16.img: an MBR with a FAT16 partition, error 18.
- nosig.img: super.img without the boot sector's 55 AA signature, which
  the monitor refuses with error 16, so the tool must too.
- evil.img: super.img with the long name of ALONGF~1.DAT rewritten as
  ../evil.dat, a path, as a card from elsewhere may spell one: get must
  write the file under its 8.3 name, here or in the directory given,
  and nowhere else.

On a held core, ls must list what is in NICE as the monitor's dir does,
with its long names and sizes, the 8.3 names after them, and the
counts, and get must give each file's bytes, by its 8.3 name and by its
long name, in either case, to a file and to stdout. A
missing file, a directory, and --slot of a slot with no card are errors,
with status 1. With the image in slot 1 only, the tool takes slot 1.

On a running core, sim/sdhold.nasm, which has read sector 5 and left
SD_CHUNK at 3: ls must work, the core must run on afterwards, and SD_LBA,
SD_CHUNK, and the buffer must be as they were. --slot 1 is refused
there, and so is a card that the program has not started up, with the
core left running. --hold reads both, and starts the program again from
reset, and leaves a held core held.

The writes, on copies of super.img, each checked afterwards with
fsck.fat -n, which may report only FSInfo's free count as unknown, and
with mtype: put of a new file, of an empty one, and of one of 60
clusters; put over a file, shorter and longer; del of a file with a long
name, whose long-name entries must go too, and of the fragmented one;
put of long names: one with blanks, one in mixed case that fits 8.3, one
in lower case, which needs none, two that share their first 6 letters,
for the tails ~1 and ~2, one with characters that an 8.3 name may not
have, and one of 255 characters, and put over one by its 8.3 name, with
the 8.3 names and the rows that ls shows, and the files that mdir and
mtype see; put of 20 files, which the folder grows by a cluster for; and
put into the clusters that del freed. The errors: names that are not
valid, put
over and del of a directory and of a read-only file, and del of a
missing one. A card that fills up keeps what fitted, with error 30, and
a write-protected card is left as it was, with the controller's error 6.

On a running core, put holds it, and starts it again from reset, which
sim/sdhold.nasm shows by reading sector 5 again. Last, the monitor of
the tests, monitor/build/monitor_test.bin, lists the card with dir, the
tool puts a .bin file with a long name, my prog.bin, and the monitor,
started again, lists it and loads it by that name; then the tool
deletes it, and dir no longer lists it.

It prints a line for each check, and last how many passed, and exits with
status 1 when one fails. niceemu must be built first, with make -C
nice_cpu/emulator build, and so must the monitor of the tests, with
make -C monitor build/monitor_test.bin. Only the Python standard library is used, and
the tools of dosfstools, util-linux, and mtools.
"""

from __future__ import annotations

import os
import re
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time

from boardlink import CONTROL, HOLD, PAUSE, RAM, Link, Tcp
from load import load_words, read_bin
import nicelink
from sdcard import (SD_CHUNK, SD_LBA, Volume, lfn_sum, read_buffer,
                    to_bytes)

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NICEEMU = os.path.join(REPO, "nice_cpu", "emulator", "zig-out", "bin",
                       "niceemu")
SDCARD = os.path.join(REPO, "tools", "sdcard.py")
SDNBD = os.path.join(REPO, "tools", "sdnbd.py")
HOLD_PROG = os.path.join(REPO, "sim", "sdhold.nasm")
MONITOR = os.path.join(REPO, "monitor", "build", "monitor_test.bin")
MB = 1024 * 1024

passed = 0
failed = 0


def row(name: str, size: int | str) -> str:
    """A row of the monitor's dir: the name in 24 columns, and the size
    or <DIR> in 12."""
    return f"{name:<24}{size:>12}"


def check(name: str, ok: bool, detail: str = "") -> bool:
    global passed, failed
    if ok:
        passed += 1
        print(f"  ok    {name}")
    else:
        failed += 1
        print(f"  FAIL  {name}" + (f": {detail}" if detail else ""))
    return ok


def run(*cmd: str) -> None:
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL,
                   stderr=subprocess.PIPE)


def put(img: str, data: bytes, name: str, tmp: str,
        offset: int = 0) -> None:
    """Copies data to the file name of the FAT at the byte offset of
    img."""
    src = os.path.join(tmp, "src")
    with open(src, "wb") as f:
        f.write(data)
    run("mcopy", "-i", f"{img}@@{offset}", "-D", "o", src, f"::{name}")


def unhint(img: str) -> None:
    """Sets FSInfo's next-free hint of the FAT32 at the start of img to
    unknown, so that mtools takes the first free cluster next."""
    with open(img, "r+b") as f:
        boot = f.read(512)
        f.seek(512 * int.from_bytes(boot[48:50], "little") + 492)
        f.write(b"\xff\xff\xff\xff")


def blank(path: str, size: int) -> None:
    with open(path, "wb") as f:
        f.truncate(size)


# The files of super.img's NICE: the name that mtools is given, and the
# bytes
FILES = {
    "HELLO.TXT": b"hello, card\n",
    "EMPTY.TXT": b"",
    "A long file name.dat": bytes(range(256)) * 3,
    "BIG.BIN": bytes((i * 7 + i // 512) & 0xFF for i in range(20000)),
    "FRAG.BIN": bytes((i * 13) & 0xFF for i in range(3000)),
}


def lfn_entry(seq: int, chars: list[int], csum: int) -> bytes:
    """A long-name entry: its sequence number, its 13 characters, and
    the checksum of the 8.3 name."""
    e = bytearray(32)
    e[0], e[11], e[13] = seq, 0x0F, csum
    text = b"".join(c.to_bytes(2, "little") for c in chars)
    e[1:11], e[14:26], e[28:32] = text[:10], text[10:22], text[22:26]
    return bytes(e)


def rename_long(img: str, short: str, long: str) -> None:
    """The long name of the file short of NICE in img set to long, of up
    to 13 characters, in the long-name entry right before the file's;
    its other long-name entries are marked deleted."""
    assert len(long) <= 13
    with open(img, "r+b") as f:
        def read(lba: int) -> bytes:
            f.seek(512 * lba)
            return f.read(512)
        e = Volume(read).find(short)
        assert e.lfn, f"{short} has no long name"
        chars = ([ord(c) for c in long] + [0] + [0xFFFF] * 12)[:13]
        for i, (lba, at) in enumerate(e.lfn):
            f.seek(512 * lba + at)
            if i == len(e.lfn) - 1:
                f.write(lfn_entry(0x41, chars, lfn_sum(e.raw)))
            else:
                f.write(b"\xe5")


def make_images(tmp: str) -> dict[str, str]:
    """The images of the header, by name."""
    imgs = {n: os.path.join(tmp, n + ".img")
            for n in ("super", "mbr", "nonice", "fat16", "nosig", "evil")}
    img = imgs["super"]
    blank(img, 64 * MB)
    run("mkfs.fat", "-F", "32", "-s", "1", "-n", "SDTEST", img)
    run("mmd", "-i", img, "::NICE", "::NICE/SUB")
    put(img, b"not NiceMon's\n", "ROOT.TXT", tmp)
    for name in ("HELLO.TXT", "EMPTY.TXT", "A long file name.dat", "BIG.BIN"):
        put(img, FILES[name], "NICE/" + name, tmp)
    # FRAG.BIN takes the clusters of two deleted files first, and then
    # the free ones after BIG.BIN.
    put(img, b"x" * 512, "NICE/GAP1.TXT", tmp)
    put(img, b"x" * 512, "NICE/KEEP.TXT", tmp)
    put(img, b"x" * 512, "NICE/GAP2.TXT", tmp)
    run("mdel", "-i", img, "::NICE/GAP1.TXT", "::NICE/GAP2.TXT")
    unhint(img)
    put(img, FILES["FRAG.BIN"], "NICE/FRAG.BIN", tmp)
    run("mdel", "-i", img, "::NICE/KEEP.TXT")
    img = imgs["mbr"]
    blank(img, 40 * MB)
    sfdisk(img, "2048,,c")
    run("mkfs.fat", "-F", "32", "--offset", "2048", img,
        str((40 * MB - MB) // 1024))
    run("mmd", "-i", f"{img}@@{MB}", "::NICE")
    put(img, FILES["HELLO.TXT"], "NICE/HELLO.TXT", tmp, MB)
    img = imgs["nonice"]
    blank(img, 40 * MB)
    run("mkfs.fat", "-F", "32", img)
    run("mmd", "-i", img, "::C64")
    img = imgs["fat16"]
    blank(img, 20 * MB)
    sfdisk(img, "2048,,6")
    run("mkfs.fat", "-F", "16", "--offset", "2048", img,
        str((20 * MB - MB) // 1024))
    img = copy(imgs["super"], imgs["nosig"])
    with open(img, "r+b") as f:
        f.seek(510)
        f.write(b"\0\0")
    rename_long(copy(imgs["super"], imgs["evil"]), "ALONGF~1.DAT",
                "../evil.dat")
    return imgs


def sfdisk(img: str, part: str) -> None:
    subprocess.run(["sfdisk", "-q", img], input=f"label: dos\n{part}\n",
                   text=True, check=True, stdout=subprocess.DEVNULL)


class Emu:
    """niceemu --link on a free port, with images in its slots."""

    def __init__(self, sd0: str | None, sd1: str | None = None,
                 prog: str | None = None) -> None:
        cmd = [NICEEMU]
        if sd0:
            cmd += ["--sd0", sd0]
        if sd1:
            cmd += ["--sd1", sd1]
        self.proc = subprocess.Popen(cmd + ["--link", "0"] +
                                     ([prog] if prog else []),
                                     stdout=subprocess.DEVNULL,
                                     stderr=subprocess.PIPE)
        assert self.proc.stderr is not None
        first = self.proc.stderr.readline().decode(errors="replace")
        m = re.search(r"link: port (\d+)", first)
        if not m:
            self.close()
            sys.exit(f"sdtest.py: niceemu --link printed {first!r}")
        self.port = m.group(1)

    def tool(self, *args: str,
             cwd: str | None = None) -> subprocess.CompletedProcess[bytes]:
        """sdcard.py --tcp on the port with args, in cwd if given. niceemu
        refuses a new host until it has seen the last one close, so a run
        that got no connection is tried again for a while."""
        end = time.monotonic() + 2
        while True:
            r = subprocess.run([sys.executable, SDCARD, "--tcp", self.port,
                                *args], capture_output=True, timeout=60,
                               cwd=cwd)
            err = r.stderr.decode(errors="replace")
            if (r.returncode == 0 or "no b notice" not in err and
                    "closed the connection" not in err or
                    time.monotonic() > end):
                return r
            time.sleep(0.05)

    def link(self) -> Link:
        end = time.monotonic() + 2
        while True:
            link = Link(Tcp(int(self.port)))
            try:
                deadline = time.monotonic() + 1
                while not link.boots and time.monotonic() < deadline:
                    link.poll(deadline - time.monotonic())
                if link.boots:
                    return link
            except nicelink.LinkError:
                pass
            link.close()
            if time.monotonic() > end:
                sys.exit("sdtest.py: no connection to niceemu --link")
            time.sleep(0.05)

    def close(self) -> None:
        self.proc.terminate()
        self.proc.wait()


def text(r: subprocess.CompletedProcess[bytes]) -> str:
    return r.stdout.decode(errors="replace") + r.stderr.decode(
        errors="replace")


def test_fragmented(img: str) -> None:
    """FRAG.BIN's chain is not contiguous, so that get follows the FAT."""
    with open(img, "rb") as f:
        def read(lba: int) -> bytes:
            f.seek(512 * lba)
            return f.read(512)
        vol = Volume(read)
        chain = list(vol.clusters(vol.find("FRAG.BIN").first))
    check(f"FRAG.BIN is fragmented: clusters {chain}",
          any(b != a + 1 for a, b in zip(chain, chain[1:])))


def test_held(imgs: dict[str, str], tmp: str) -> None:
    print("A held core, the card of super.img in slot 0")
    emu = Emu(imgs["super"])
    try:
        r = emu.tool("ls")
        out = r.stdout.decode()
        rows = out.splitlines()
        check("ls", r.returncode == 0, text(r))
        check("ls: the folder", rows[:1] == ["Directory of NICE"], out)
        check("ls: the counts", rows[-1:] == ["Files: 5, directories: 1"],
              out)
        for want in (row("HELLO.TXT", 12), row("EMPTY.TXT", 0),
                     row("BIG.BIN", 20000), row("FRAG.BIN", 3000),
                     row("SUB", "<DIR>"),
                     row("A long file name.dat", 768) + "  ALONGF~1.DAT"):
            check(f"ls: {want!r}", want in rows, out)
        check("ls: nothing of the root", "ROOT" not in out, out)
        for name, data in FILES.items():
            dest = os.path.join(tmp, "got")
            r = emu.tool("get", name, dest)
            with open(dest, "rb") as f:
                got = f.read()
            check(f"get {name!r}: {len(data)} bytes",
                  r.returncode == 0 and got == data, text(r))
        r = emu.tool("get", "alongf~1.dat", "-")
        check("get by the 8.3 name, in lower case, to stdout",
              r.returncode == 0 and r.stdout == FILES["A long file name.dat"],
              text(r))
        r = emu.tool("get", "A LONG FILE NAME.DAT", "-")
        check("get by the long name, in upper case",
              r.returncode == 0 and r.stdout == FILES["A long file name.dat"],
              text(r))
        os.makedirs(os.path.join(tmp, "dir"), exist_ok=True)
        r = emu.tool("get", "hello.txt", os.path.join(tmp, "dir"))
        check("get to a directory, under the file's name",
              r.returncode == 0 and
              os.path.exists(os.path.join(tmp, "dir", "HELLO.TXT")), text(r))
        cases = [
            (("get", "NOPE.TXT", "-"), "File error 21, no such file"),
            (("get", "SUB", "-"), "File error 22, a directory"),
            (("get", "ROOT.TXT", "-"), "File error 21, no such file"),
            (("--folder", "OTHER", "ls"),
             "File error 29, no folder OTHER on the card"),
            (("--slot", "1", "ls"), "slot 1 has no card"),
            (("--slot", "2", "ls"), "File error 27, no such slot"),
        ]
        for args, want in cases:
            r = emu.tool(*args)
            check(f"{' '.join(args)}: {want}",
                  r.returncode == 1 and want in r.stderr.decode(), text(r))
    finally:
        emu.close()
    for name, want in (("mbr", row("HELLO.TXT", 12)),
                       ("nonice", "File error 29, no folder NICE on the card"),
                       ("fat16", "File error 18, FAT16, which is not "
                        "supported"),
                       ("nosig", "File error 16, no FAT32 file system")):
        emu = Emu(imgs[name])
        try:
            r = emu.tool("ls")
            check(f"{name}.img: {want}", want in text(r), text(r))
            if name == "mbr":
                r = emu.tool("get", "HELLO.TXT", "-")
                check("mbr.img: get HELLO.TXT",
                      r.stdout == FILES["HELLO.TXT"], text(r))
        finally:
            emu.close()
    emu = Emu(None, imgs["mbr"])
    try:
        r = emu.tool("ls")
        check("the card in slot 1 only: ls takes slot 1",
              row("HELLO.TXT", 12) in text(r), text(r))
    finally:
        emu.close()
    # A long name that is a path: the file is written under its 8.3 name
    here = os.path.join(tmp, "here")
    os.makedirs(here, exist_ok=True)
    safe = os.path.join(here, "ALONGF~1.DAT")
    evil = os.path.join(tmp, "evil.dat")
    emu = Emu(imgs["evil"])
    try:
        r = emu.tool("ls")
        check("evil.img: ls shows the long name ../evil.dat",
              row("../evil.dat", 768) + "  ALONGF~1.DAT" in text(r), text(r))
        r = emu.tool("get", "ALONGF~1.DAT", cwd=here)
        check("evil.img: get writes ALONGF~1.DAT here, not ../evil.dat",
              r.returncode == 0 and os.path.exists(safe) and
              not os.path.exists(evil), text(r))
        os.remove(safe)
        r = emu.tool("get", "../evil.dat", here)
        check("evil.img: get by the long name to a directory, as "
              "ALONGF~1.DAT there",
              r.returncode == 0 and os.path.exists(safe) and
              not os.path.exists(evil), text(r))
    finally:
        emu.close()


def start_hold(emu: Emu, tmp: str, init: bool) -> None:
    """Loads sim/sdhold.nasm, with INIT as init, and starts it."""
    with open(HOLD_PROG) as f:
        src = f.read()
    src = src.replace("INIT            .EQU    1",
                      f"INIT            .EQU    {int(init)}")
    path = os.path.join(tmp, "sdhold.nasm")
    with open(path, "w") as f:
        f.write(src)
    binary = os.path.join(tmp, "sdhold.bin")
    subprocess.run([sys.executable,
                    os.path.join(REPO, "nice_cpu", "assembler", "niceasm.py"),
                    "-o", binary, path], check=True)
    link = emu.link()
    try:
        load_words(link, read_bin(binary))
        link.control(RAM)
        time.sleep(0.2)
    finally:
        link.close()


def paused_state(emu: Emu) -> tuple[int, int, int, bytes]:
    """The control register, then SD_LBA, SD_CHUNK, and the buffer read
    with the core paused, and the core let go on."""
    link = emu.link()
    try:
        ctl = link.read_word(CONTROL)
        pauses = link.pauses
        link.control(PAUSE | RAM)
        end = time.monotonic() + 2
        while link.pauses == pauses and time.monotonic() < end:
            link.poll(end - time.monotonic())
        lba = link.read_word(SD_LBA)
        chunk = link.read_word(SD_CHUNK)
        buf = to_bytes(read_buffer(link))
        link.write(SD_CHUNK, [chunk])
        link.control(ctl & RAM)
        return ctl, lba, chunk, buf
    finally:
        link.close()


def test_running(imgs: dict[str, str], tmp: str) -> None:
    print("A running core, sim/sdhold.nasm, with super.img in slot 0")
    with open(imgs["super"], "rb") as f:
        f.seek(5 * 512)
        sector5 = f.read(512)
    emu = Emu(imgs["super"])
    try:
        start_hold(emu, tmp, True)
        ctl, lba, chunk, buf = paused_state(emu)
        check("the program runs, with sector 5 in the buffer",
              ctl & (HOLD | PAUSE) == 0 and lba == 5 and chunk == 3 and
              buf == sector5, f"control {ctl:08X}, LBA {lba}, chunk {chunk}")
        r = emu.tool("ls")
        check("ls while it runs", r.returncode == 0 and
              "Files: 5, directories: 1" in r.stdout.decode(), text(r))
        r = emu.tool("get", "BIG.BIN", "-")
        check("get BIG.BIN while it runs",
              r.returncode == 0 and r.stdout == FILES["BIG.BIN"], text(r))
        ctl, lba, chunk, buf = paused_state(emu)
        check("the program runs on, with SD_LBA, SD_CHUNK, and the buffer "
              "as they were",
              ctl & (HOLD | PAUSE) == 0 and lba == 5 and chunk == 3 and
              buf == sector5, f"control {ctl:08X}, LBA {lba}, chunk {chunk}")
        r = emu.tool("--slot", "1", "ls")
        check("--slot 1 while the program uses slot 0 is refused",
              r.returncode == 1 and "hold the core" in r.stderr.decode(),
              text(r))
        ctl = paused_state(emu)[0]
        check("and the program runs on", ctl & (HOLD | PAUSE) == 0,
              f"control {ctl:08X}")
    finally:
        emu.close()
    emu = Emu(imgs["super"])
    try:
        start_hold(emu, tmp, False)
        r = emu.tool("ls")
        check("a card that the program has not started up is refused",
              r.returncode == 1 and "does no Init" in r.stderr.decode(),
              text(r))
        ctl, lba, chunk, _ = paused_state(emu)
        check("and the program runs on, with SD_LBA and SD_CHUNK as they "
              "were", ctl & (HOLD | PAUSE) == 0 and lba == 5 and chunk == 3,
              f"control {ctl:08X}, LBA {lba}, chunk {chunk}")
        r = emu.tool("--hold", "ls")
        check("ls --hold reads it, and starts the core again",
              r.returncode == 0 and "Files: 5, directories: 1" in
              r.stdout.decode() and "started again from reset" in
              r.stderr.decode(), text(r))
        ctl, lba, chunk, _ = paused_state(emu)
        check("and the program ran again from the start",
              ctl & (HOLD | PAUSE) == 0 and lba == 5 and chunk == 3,
              f"control {ctl:08X}, LBA {lba}, chunk {chunk}")
    finally:
        emu.close()
    emu = Emu(None, imgs["super"])
    try:
        start_hold(emu, tmp, True)
        r = emu.tool("--slot", "1", "get", "HELLO.TXT", "-")
        check("get --slot 1 while the program has slot 0 is refused",
              r.returncode == 1 and "hold the core" in r.stderr.decode(),
              text(r))
        r = emu.tool("--hold", "--slot", "1", "get", "HELLO.TXT", "-")
        check("get --hold --slot 1 reads it",
              r.returncode == 0 and r.stdout == FILES["HELLO.TXT"], text(r))
        ctl = paused_state(emu)[0]
        check("and the core runs again", ctl & (HOLD | PAUSE) == 0,
              f"control {ctl:08X}")
    finally:
        emu.close()
    emu = Emu(imgs["super"])
    try:
        r = emu.tool("--hold", "ls")
        check("ls --hold on a held core leaves it held",
              r.returncode == 0 and "started again" not in
              r.stderr.decode(), text(r))
        link = emu.link()
        try:
            ctl = link.read_word(CONTROL)
        finally:
            link.close()
        check("the core is still held", bool(ctl & HOLD), f"{ctl:08X}")
    finally:
        emu.close()


def fsck(img: str) -> list[str]:
    """What fsck.fat -n says of the FAT32 of img but its version, its
    summary, and FSInfo's free count left unknown, which the monitor's
    writes leave so too."""
    r = subprocess.run(["fsck.fat", "-n", img], capture_output=True,
                       text=True)
    return [line for line in (r.stdout + r.stderr).splitlines()[1:]
            if line and not line.startswith(img + ":")
            and not line.startswith("Free cluster summary uninitialized")]


def mtype(img: str, name: str) -> bytes | None:
    r = subprocess.run(["mtype", "-i", img, f"::NICE/{name}"],
                       capture_output=True)
    return r.stdout if r.returncode == 0 else None


def mnames(img: str) -> list[str]:
    r = subprocess.run(["mdir", "-b", "-i", img, "::NICE"],
                       capture_output=True, text=True)
    return [n.replace("::/NICE/", "") for n in r.stdout.split()]


def copy(src: str, dst: str) -> str:
    with open(src, "rb") as f, open(dst, "wb") as g:
        g.write(f.read())
    return dst


def check_card(img: str, what: str) -> None:
    errors = fsck(img)
    check(f"{what}: fsck.fat -n finds nothing", not errors,
          "; ".join(errors))


def test_writes(imgs: dict[str, str], tmp: str) -> None:
    print("put and del on a held core, a copy of super.img")
    img = copy(imgs["super"], os.path.join(tmp, "w.img"))
    data = {
        "NEW.TXT": b"a new file\n",
        "NEW0.TXT": b"",
        "NEW60.BIN": bytes((i * 31 + i // 300) & 0xFF for i in range(30000)),
        "BIG.BIN": b"shorter now\n",
        "HELLO.TXT": bytes((i * 5) & 0xFF for i in range(5000)),
    }
    src = os.path.join(tmp, "src.dat")
    emu = Emu(img)
    try:
        for name, body in data.items():
            with open(src, "wb") as f:
                f.write(body)
            r = emu.tool("put", src, name)
            check(f"put {name}: {len(body)} bytes",
                  r.returncode == 0 and
                  f"{name}: {len(body)} bytes written" in r.stdout.decode(),
                  text(r))
        r = emu.tool("del", "a long FILE name.dat")
        check("del by the long name", r.returncode == 0 and
              "Deleted A long file name.dat" in r.stdout.decode(), text(r))
        r = emu.tool("del", "frag.bin")
        check("del FRAG.BIN", r.returncode == 0, text(r))
    finally:
        emu.close()
    check_card(img, "after put and del")
    for name, body in data.items():
        check(f"mtype {name}", mtype(img, name) == body)
    names = mnames(img)
    check("mdir: the deleted files and their long names are gone",
          not any(n.lower().startswith(("a long", "alongf", "frag"))
                  for n in names), " ".join(names))
    print("long names written")
    longs = {
        "a long name.bin": b"long\n",
        "mixed.Bin": b"mixed\n",
        "lower.txt": b"lower\n",
        "mandelbrot1.txt": b"one\n",
        "mandelbrot2.txt": b"two\n",
        "a+b;c.txt": b"plus\n",
        "n" * 251 + ".txt": b"n\n",
    }
    emu = Emu(img)
    try:
        for name, body in longs.items():
            with open(src, "wb") as f:
                f.write(body)
            r = emu.tool("put", src, name)
            check(f"put {name[:20]!r}", r.returncode == 0, text(r))
        r = emu.tool("get", "A LONG NAME.BIN", "-")
        check("get by the long name in upper case",
              r.returncode == 0 and r.stdout == b"long\n", text(r))
        with open(src, "wb") as f:
            f.write(b"over\n")
        r = emu.tool("put", src, "MIXED.BIN")
        check("put over mixed.Bin by its 8.3 name", r.returncode == 0,
              text(r))
        longs["mixed.Bin"] = b"over\n"
        r = emu.tool("ls")
        for want in (row("a long name.bin", 5) + "  ALONGN~1.BIN",
                     row("mixed.Bin", 5) + "  MIXED.BIN",
                     row("lower.txt", 6),
                     row("mandelbrot1.txt", 4) + "  MANDEL~1.TXT",
                     row("mandelbrot2.txt", 4) + "  MANDEL~2.TXT",
                     row("a+b;c.txt", 5) + "  A_B_C~1.TXT"):
            check(f"ls: {want!r}", want in r.stdout.decode(), text(r))
    finally:
        emu.close()
    check_card(img, "after the long names")
    for name, body in longs.items():
        check(f"mtype {name[:20]!r}", mtype(img, name) == body)
    names = mnames(img)
    check("mdir: the long names", all(n in names for n in longs if " " not in n),
          " ".join(names))
    print("20 files, which grow the folder, and the freed clusters taken")
    emu = Emu(img)
    try:
        ok = True
        for i in range(1, 21):
            with open(src, "wb") as f:
                f.write(f"file {i}\n".encode() * i)
            r = emu.tool("put", src, f"F{i:02d}.TXT")
            ok = ok and r.returncode == 0
        check("put F01.TXT to F20.TXT", ok)
        body = bytes((i * 3) & 0xFF for i in range(8000))
        with open(src, "wb") as f:
            f.write(body)
        r = emu.tool("put", src, "REUSE.BIN")
        check("put REUSE.BIN, 16 clusters", r.returncode == 0, text(r))
        r = emu.tool("get", "f20.txt", "-")
        check("get F20.TXT back", r.stdout == b"file 20\n" * 20, text(r))
        r = emu.tool("ls")
        check("ls lists 34 files", "Files: 34, directories: 1" in
              r.stdout.decode(), text(r))
    finally:
        emu.close()
    check_card(img, "after 21 more files")
    with open(img, "rb") as g:
        def read(lba: int) -> bytes:
            g.seek(512 * lba)
            return g.read(512)
        vol = Volume(read)
        grown = len(list(vol.clusters(vol.dir)))
        chain = list(vol.clusters(vol.find("REUSE.BIN").first))
    check(f"the folder has grown to {grown} clusters", grown >= 2)
    check("REUSE.BIN takes the clusters that del freed, below BIG.BIN's "
          f"old ones: {chain[:4]}...", chain[0] < 60, str(chain))
    check("mtype F20.TXT and REUSE.BIN",
          mtype(img, "F20.TXT") == b"file 20\n" * 20 and
          mtype(img, "REUSE.BIN") == body)
    print("the errors of put and del")
    run("mattrib", "-i", img, "+r", "::NICE/NEW.TXT")
    with open(img, "rb") as g:
        before = g.read()
    emu = Emu(img)
    try:
        r = emu.tool("put", os.path.join(tmp, "a:b.txt"))
        check("put of a host file whose name is not valid",
              r.returncode == 1 and "File error 20, not a valid name" in
              r.stderr.decode(), text(r))
        for bad in ("a*b", "end.", "end "):
            r = emu.tool("put", src, bad)
            check(f"put as {bad!r}: File error 20", r.returncode == 1 and
                  "File error 20" in r.stderr.decode(), text(r))
        for args, want in ((("put", src, "SUB"), "File error 22"),
                           (("del", "SUB"), "File error 22"),
                           (("put", src, "NEW.TXT"), "File error 32"),
                           (("del", "NEW.TXT"), "File error 32"),
                           (("del", "NOPE.TXT"), "File error 21")):
            r = emu.tool(*args)
            check(f"{' '.join(args[:1] + args[-1:])}: {want}",
                  r.returncode == 1 and want in r.stderr.decode(), text(r))
    finally:
        emu.close()
    with open(img, "rb") as g:
        check("the errors change nothing on the card", g.read() == before)


def free_clusters(img: str) -> int:
    with open(img, "rb") as f:
        def read(lba: int) -> bytes:
            f.seek(512 * lba)
            return f.read(512)
        vol = Volume(read)
        return sum(vol.next(c) == 0 for c in range(2, vol.top))


def test_full(tmp: str) -> None:
    print("a card that fills up")
    img = os.path.join(tmp, "full.img")
    blank(img, 34 * MB)
    run("mkfs.fat", "-F", "32", "-s", "1", img)
    run("mmd", "-i", img, "::NICE")
    put(img, b"\0" * 512 * (free_clusters(img) - 4), "FILL.BIN", tmp)
    left = free_clusters(img)
    emu = Emu(img)
    try:
        src = os.path.join(tmp, "src.dat")
        body = bytes(range(256)) * 20
        with open(src, "wb") as f:
            f.write(body)
        r = emu.tool("put", src, "OVER.BIN")
        check(f"put of 10 clusters on {left} free: File error 30",
              r.returncode == 1 and "File error 30" in r.stderr.decode(),
              text(r))
    finally:
        emu.close()
    check_card(img, "the full card")
    got = mtype(img, "OVER.BIN")
    check(f"OVER.BIN keeps what fitted, {512 * left} bytes",
          got == body[:512 * left], f"{len(got or b'')} bytes")


def test_protected(imgs: dict[str, str], tmp: str) -> None:
    img = copy(imgs["super"], os.path.join(tmp, "ro.img"))
    os.chmod(img, 0o444)
    with open(img, "rb") as f:
        before = f.read()
    emu = Emu(img)
    try:
        r = emu.tool("put", HOLD_PROG, "X.TXT")
        check("put on a write-protected card: the controller's error 6",
              r.returncode == 1 and "error 6, write-protected" in
              r.stderr.decode(), text(r))
    finally:
        emu.close()
    with open(img, "rb") as f:
        check("and the card is as it was", f.read() == before)


def test_write_running(imgs: dict[str, str], tmp: str) -> None:
    print("put on a running core, sim/sdhold.nasm")
    img = copy(imgs["super"], os.path.join(tmp, "run.img"))
    emu = Emu(img)
    try:
        start_hold(emu, tmp, True)
        link = emu.link()
        try:
            link.control(PAUSE | RAM)
            time.sleep(0.1)
            link.write(SD_LBA, [9])
            link.control(RAM)
        finally:
            link.close()
        r = emu.tool("put", HOLD_PROG, "HOLD.TXT")
        check("put while it runs, and the core started again",
              r.returncode == 0 and "started again from reset" in
              r.stderr.decode(), text(r))
        time.sleep(0.2)
        ctl, lba, chunk, _ = paused_state(emu)
        check("the program ran again from the start: SD_LBA 5, not 9",
              ctl & (HOLD | PAUSE) == 0 and lba == 5 and chunk == 3,
              f"control {ctl:08X}, LBA {lba}, chunk {chunk}")
    finally:
        emu.close()
    with open(HOLD_PROG, "rb") as f:
        check("mtype HOLD.TXT", mtype(img, "HOLD.TXT") == f.read())
    check_card(img, "after put on a running core")


class NbdClient:
    """A client of sdnbd.py's NBD server, as nbd-client and the kernel
    speak to it: the fixed newstyle handshake, with NBD_OPT_GO, or the
    old NBD_OPT_EXPORT_NAME, and then the requests, with simple replies."""

    def __init__(self, port: int, go: bool = True) -> None:
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=60)
        hello = self.recv(18)
        assert hello[:8] == b"NBDMAGIC", hello
        self.sock.sendall(struct.pack(">I", 3))
        self.block: tuple[int, int, int] | None = None
        if go:
            data = struct.pack(">I", 2) + b"sd" + struct.pack(">HH", 1, 3)
            self.sock.sendall(struct.pack(">QII", 0x49484156454F5054, 7,
                                          len(data)) + data)
            while True:
                _, _, kind, n = struct.unpack(">QIII", self.recv(20))
                reply = self.recv(n)
                if kind == 1:
                    break
                assert kind == 3, f"reply {kind:#x}"
                (info,) = struct.unpack(">H", reply[:2])
                if info == 0:
                    self.size, self.flags = struct.unpack(">QH", reply[2:])
                elif info == 3:
                    self.block = struct.unpack(">III", reply[2:])
        else:
            self.sock.sendall(struct.pack(">QII", 0x49484156454F5054, 1, 0))
            self.size, self.flags = struct.unpack(">QH", self.recv(10))
        self.cookie = 0

    def recv(self, n: int) -> bytes:
        data = b""
        while len(data) < n:
            got = self.sock.recv(n - len(data))
            if not got:
                raise ConnectionError("sdnbd.py closed the connection")
            data += got
        return data

    def request(self, kind: int, offset: int, length: int,
                data: bytes = b"") -> tuple[int, bytes]:
        """The error of the reply, and the bytes of a read."""
        self.cookie += 1
        self.sock.sendall(struct.pack(">IHHQQI", 0x25609513, 0, kind,
                                      self.cookie, offset, length) + data)
        magic, error, cookie = struct.unpack(">IIQ", self.recv(16))
        assert magic == 0x67446698 and cookie == self.cookie
        return error, (self.recv(length) if kind == 0 and not error
                       else b"")

    def read(self, offset: int, length: int) -> bytes:
        error, data = self.request(0, offset, length)
        assert not error, f"read error {error}"
        return data

    def close(self) -> None:
        self.sock.sendall(struct.pack(">IHHQQI", 0x25609513, 0, 2, 0, 0, 0))
        self.sock.close()


def start_nbd(emu: Emu, *args: str) -> tuple[subprocess.Popen[bytes], int]:
    """sdnbd.py on the link of emu, on a free port: the process, and the
    port. niceemu takes a new host only after it has seen the last one
    close, so a start that got no connection is tried again for a while."""
    end = time.monotonic() + 2
    while True:
        proc = subprocess.Popen([sys.executable, SDNBD, "--tcp", emu.port,
                                 "--listen", "127.0.0.1:0", *args],
                                stderr=subprocess.PIPE)
        assert proc.stderr is not None
        line = proc.stderr.readline().decode(errors="replace")
        m = re.search(r" on 127\.0\.0\.1:(\d+)", line)
        if m:
            proc.stderr.readline()
            return proc, int(m.group(1))
        proc.wait()
        if time.monotonic() > end:
            sys.exit(f"sdtest.py: sdnbd.py printed {line!r}")
        time.sleep(0.05)


def stop_nbd(proc: subprocess.Popen[bytes]) -> str:
    """Stops sdnbd.py, as Ctrl-C does: what it printed after its start."""
    proc.send_signal(signal.SIGTERM)
    assert proc.stderr is not None
    err = proc.stderr.read().decode(errors="replace")
    proc.wait()
    return err


def test_nbd(imgs: dict[str, str], tmp: str) -> None:
    print("sdnbd.py, the card as a block device, on a running core, "
          "sim/sdhold.nasm")
    img = copy(imgs["super"], os.path.join(tmp, "nbd.img"))
    # What a host's mount would write: a new folder and file, made with
    # mtools on a copy, whose sectors that differ are written over NBD
    want = copy(img, os.path.join(tmp, "nbdwant.img"))
    run("mmd", "-i", want, "::NICE/HOSTDIR")
    put(want, bytes((i * 11) & 0xFF for i in range(5000)),
        "NICE/HOSTDIR/From the host.bin", tmp)
    with open(img, "rb") as f:
        old = f.read()
    with open(want, "rb") as f:
        new = f.read()
    changed = [lba for lba in range(len(new) // 512)
               if old[512 * lba:512 * lba + 512] !=
               new[512 * lba:512 * lba + 512]]
    emu = Emu(img)
    start_hold(emu, tmp, True)
    proc, port = start_nbd(emu)
    try:
        c = NbdClient(port)
        check("NBD_OPT_GO: the card's size, writable",
              c.size == len(old) and c.flags & 2 == 0,
              f"{c.size} bytes, flags {c.flags:#x}")
        check("NBD_OPT_GO: block sizes of 512, 4096, and 32 MB",
              c.block == (512, 4096, 32 * MB), str(c.block))
        check("read sector 0", c.read(0, 512) == old[:512])
        check("read 3000 bytes from byte 1000",
              c.read(1000, 3000) == old[1000:4000])
        check("read the last sector",
              c.read(len(old) - 512, 512) == old[-512:])
        error, _ = c.request(0, len(old) - 512, 1024)
        check("read past the end: EINVAL", error == 22, str(error))
        ok = True
        for lba in changed:
            # Each sector in two writes, split off its boundaries
            at = 512 * lba
            for a, b in ((at, at + 100), (at + 100, at + 512)):
                error, _ = c.request(1, a, b - a, new[a:b])
                ok = ok and error == 0
        check(f"write {len(changed)} sectors, in parts", ok)
        ok = all(c.read(512 * lba, 512) == new[512 * lba:512 * lba + 512]
                 for lba in changed)
        check("and read them back", ok)
        error, _ = c.request(3, 0, 0)
        check("flush", error == 0, str(error))
        c.close()
        c = NbdClient(port, go=False)
        check("a second connection, with NBD_OPT_EXPORT_NAME",
              c.size == len(old) and c.read(0, 512) == new[:512])
        c.close()
    finally:
        err = stop_nbd(proc)
        emu.close()
    check("stopped, and the core started again from reset",
          proc.returncode == 0 and "started again from reset" in err, err)
    with open(img, "rb") as f:
        check("the card is as mtools made the copy", f.read() == new)
    check("mtype what the host wrote",
          mtype(img, "HOSTDIR/From the host.bin") ==
          bytes((i * 11) & 0xFF for i in range(5000)))
    check_card(img, "after the writes over NBD")
    print("sdnbd.py --read-only")
    emu = Emu(imgs["mbr"])
    proc, port = start_nbd(emu, "--read-only")
    try:
        c = NbdClient(port)
        check("read-only", c.flags & 2 == 2, f"flags {c.flags:#x}")
        with open(imgs["mbr"], "rb") as f:
            mbr = f.read(MB + 512)
        check("read the MBR and the partition's boot sector",
              c.read(0, 512) == mbr[:512] and
              c.read(MB, 512) == mbr[MB:])
        error, _ = c.request(1, 0, 512, bytes(512))
        check("a write: EPERM", error == 1, str(error))
        c.close()
    finally:
        err = stop_nbd(proc)
        emu.close()
    check("stopped, the held core left held",
          proc.returncode == 0 and "started again" not in err, err)
    with open(imgs["mbr"], "rb") as f:
        check("and the card is as it was", f.read(MB + 512) == mbr)


def prompt(emu_link: Link, wait: float = 2.0) -> None:
    """Waits for the monitor's first prompt, after its start."""
    out = b""
    end = time.monotonic() + wait
    while time.monotonic() < end and not out.endswith(b"> "):
        emu_link.poll(0.05)
        out += emu_link.take_console()


def console(emu_link: Link, line: str, wait: float = 2.0) -> str:
    """Types a line into the monitor, and what it printed until its next
    prompt."""
    emu_link.take_console()
    emu_link.send_console(line.encode() + b"\r")
    out = b""
    end = time.monotonic() + wait
    while time.monotonic() < end and not out.endswith(b"> "):
        emu_link.poll(0.05)
        out += emu_link.take_console()
    return out.decode(errors="replace")


def test_monitor(imgs: dict[str, str], tmp: str) -> None:
    print("the monitor of the tests, and put and del")
    if not os.path.exists(MONITOR):
        check(f"{MONITOR} is built", False,
              "make -C monitor build/monitor_test.bin")
        return
    img = copy(imgs["super"], os.path.join(tmp, "mon.img"))
    emu = Emu(img, prog=MONITOR)
    prog = os.path.join(tmp, "my prog.bin")
    with open(prog, "w") as f:
        f.write("8000 12345678\n8001 9ABCDEF0\n")
    try:
        link = emu.link()
        try:
            link.control(RAM)
            prompt(link)
            out = console(link, "dir")
            check("the monitor's dir", "Files: 5, directories: 1" in out,
                  repr(out))
        finally:
            link.close()
        r = emu.tool("put", prog)
        check("put my prog.bin while the monitor runs", r.returncode == 0 and
              "started again" in r.stderr.decode(), text(r))
        link = emu.link()
        try:
            out = console(link, "dir")
            check("the monitor, started again, lists my prog.bin",
                  row("my prog.bin", 28) in out and
                  "Files: 6, directories: 1" in out, repr(out))
            out = console(link, 'load "my prog.bin"')
            check("and loads it", "Words loaded: 2, 00008000 to 00008001"
                  in out, repr(out))
            pauses = link.pauses
            link.control(PAUSE | RAM)
            end = time.monotonic() + 2
            while link.pauses == pauses and time.monotonic() < end:
                link.poll(0.1)
            words = link.read(0x8000, 2)
            check("the words loaded", words == [0x12345678, 0x9ABCDEF0],
                  str(words))
            link.control(RAM)
        finally:
            link.close()
        r = emu.tool("del", "MY PROG.BIN")
        check("del my prog.bin", r.returncode == 0, text(r))
        link = emu.link()
        try:
            out = console(link, "dir")
            check("dir no longer lists it", "prog" not in out and
                  "Files: 5, directories: 1" in out, repr(out))
        finally:
            link.close()
    finally:
        emu.close()
    check_card(img, "after the monitor's test")


def main() -> None:
    if not os.path.exists(NICEEMU):
        sys.exit(f"sdtest.py: no {NICEEMU}; make -C nice_cpu/emulator build")
    with tempfile.TemporaryDirectory() as tmp:
        imgs = make_images(tmp)
        test_fragmented(imgs["super"])
        test_held(imgs, tmp)
        test_running(imgs, tmp)
        test_writes(imgs, tmp)
        test_full(tmp)
        test_protected(imgs, tmp)
        test_write_running(imgs, tmp)
        test_monitor(imgs, tmp)
        test_nbd(imgs, tmp)
    print(f"{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
