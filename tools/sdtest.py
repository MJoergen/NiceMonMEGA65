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

On a held core, ls must list what is in NICE, with its sizes and long
names, and the counts, and get must give each file's bytes, by its 8.3
name and by its long name, in either case, to a file and to stdout. A
missing file, a directory, and --slot of a slot with no card are errors,
with status 1. With the image in slot 1 only, the tool takes slot 1.

On a running core, sim/sdhold.nasm, which has read sector 5 and left
SD_CHUNK at 3: ls must work, the core must run on afterwards, and SD_LBA,
SD_CHUNK, and the buffer must be as they were. --slot 1 is refused
there, and so is a card that the program has not started up, with the
core left running.

It prints a line for each check, and last how many passed, and exits with
status 1 when one fails. niceemu must be built first, with make -C
nice_cpu/emulator build. Only the Python standard library is used, and
the tools of dosfstools, util-linux, and mtools.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
import time

from boardlink import CONTROL, HOLD, PAUSE, RAM, Link, Tcp
from load import load_words, read_bin
import nicelink
from sdcard import (SD_CHUNK, SD_LBA, Volume, read_buffer, to_bytes)

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NICEEMU = os.path.join(REPO, "nice_cpu", "emulator", "zig-out", "bin",
                       "niceemu")
SDCARD = os.path.join(REPO, "tools", "sdcard.py")
HOLD_PROG = os.path.join(REPO, "sim", "sdhold.nasm")
MB = 1024 * 1024

passed = 0
failed = 0


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


def make_images(tmp: str) -> dict[str, str]:
    """The images of the header, by name."""
    imgs = {n: os.path.join(tmp, n + ".img")
            for n in ("super", "mbr", "nonice", "fat16")}
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
    return imgs


def sfdisk(img: str, part: str) -> None:
    subprocess.run(["sfdisk", "-q", img], input=f"label: dos\n{part}\n",
                   text=True, check=True, stdout=subprocess.DEVNULL)


class Emu:
    """niceemu --link on a free port, with images in its slots."""

    def __init__(self, sd0: str | None, sd1: str | None = None) -> None:
        cmd = [NICEEMU]
        if sd0:
            cmd += ["--sd0", sd0]
        if sd1:
            cmd += ["--sd1", sd1]
        self.proc = subprocess.Popen(cmd + ["--link", "0"],
                                     stdout=subprocess.DEVNULL,
                                     stderr=subprocess.PIPE)
        assert self.proc.stderr is not None
        first = self.proc.stderr.readline().decode(errors="replace")
        m = re.search(r"link: port (\d+)", first)
        if not m:
            self.close()
            sys.exit(f"sdtest.py: niceemu --link printed {first!r}")
        self.port = m.group(1)

    def tool(self, *args: str) -> subprocess.CompletedProcess[bytes]:
        """sdcard.py --tcp on the port with args. niceemu refuses a new
        host until it has seen the last one close, so a run that got no
        connection is tried again for a while."""
        end = time.monotonic() + 2
        while True:
            r = subprocess.run([sys.executable, SDCARD, "--tcp", self.port,
                                *args], capture_output=True, timeout=60)
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
        for row in ("HELLO    TXT          12", "EMPTY    TXT           0",
                    "BIG      BIN       20000", "FRAG     BIN        3000",
                    "SUB           <DIR>",
                    "ALONGF~1 DAT         768  A long file name.dat"):
            check(f"ls: {row!r}", row in rows, out)
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
    for name, want in (("mbr", "HELLO    TXT          12"),
                       ("nonice", "File error 29, no folder NICE on the card"),
                       ("fat16", "File error 18, FAT16, which is not "
                        "supported")):
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
              "HELLO    TXT          12" in text(r), text(r))
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
    finally:
        emu.close()


def main() -> None:
    if not os.path.exists(NICEEMU):
        sys.exit(f"sdtest.py: no {NICEEMU}; make -C nice_cpu/emulator build")
    with tempfile.TemporaryDirectory() as tmp:
        imgs = make_images(tmp)
        test_fragmented(imgs["super"])
        test_held(imgs, tmp)
        test_running(imgs, tmp)
    print(f"{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
