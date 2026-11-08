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

On a held core, ls must list what is in NICE, with its sizes and long
names, and the counts, and get must give each file's bytes, by its 8.3
name and by its long name, in either case, to a file and to stdout. A
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
put of 20 files, which the folder grows by a cluster for; and put into
the clusters that del freed. The errors: a name that is not 8.3, put
over and del of a directory and of a read-only file, and del of a
missing one. A card that fills up keeps what fitted, with error 30, and
a write-protected card is left as it was, with the controller's error 6.

On a running core, put holds it, and starts it again from reset, which
sim/sdhold.nasm shows by reading sector 5 again. Last, the monitor of
the tests, monitor/build/monitor_test.bin, lists the card with dir, the
tool puts a .bin file, and the monitor, started again, lists it and
loads it; then the tool deletes it, and dir no longer lists it.

It prints a line for each check, and last how many passed, and exits with
status 1 when one fails. niceemu must be built first, with make -C
nice_cpu/emulator build, and so must the monitor of the tests, with
make -C monitor build/monitor_test.bin. Only the Python standard library is used, and
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
from sdcard import (SD_CHUNK, SD_LBA, Volume, lfn_sum, read_buffer,
                    to_bytes)

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NICEEMU = os.path.join(REPO, "nice_cpu", "emulator", "zig-out", "bin",
                       "niceemu")
SDCARD = os.path.join(REPO, "tools", "sdcard.py")
HOLD_PROG = os.path.join(REPO, "sim", "sdhold.nasm")
MONITOR = os.path.join(REPO, "monitor", "build", "monitor_test.bin")
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
              "HELLO    TXT          12" in text(r), text(r))
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
              "ALONGF~1 DAT         768  ../evil.dat" in text(r), text(r))
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
              "Deleted ALONGF~1.DAT" in r.stdout.decode(), text(r))
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
        check("ls lists 27 files", "Files: 27, directories: 1" in
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
        r = emu.tool("put", os.path.join(tmp, "toolongname.txt"))
        check("put of a host file whose name is not 8.3",
              r.returncode == 1 and "File error 20, not an 8.3 name" in
              r.stderr.decode(), text(r))
        r = emu.tool("put", src, "A.B.C")
        check("put as A.B.C: File error 20", r.returncode == 1 and
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
    prog = os.path.join(tmp, "prog.bin")
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
        check("put PROG.BIN while the monitor runs", r.returncode == 0 and
              "started again" in r.stderr.decode(), text(r))
        link = emu.link()
        try:
            out = console(link, "dir")
            check("the monitor, started again, lists PROG.BIN",
                  "PROG     BIN          28" in out and
                  "Files: 6, directories: 1" in out, repr(out))
            out = console(link, "load prog.bin")
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
        r = emu.tool("del", "prog.bin")
        check("del PROG.BIN", r.returncode == 0, text(r))
        link = emu.link()
        try:
            out = console(link, "dir")
            check("dir no longer lists it", "PROG" not in out and
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
    print(f"{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
