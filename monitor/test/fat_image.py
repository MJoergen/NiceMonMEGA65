#!/usr/bin/env python3
"""The FAT images of the monitor's tests of FAT32 in niceemu (Makefile).

Each is made with the tools of dosfstools, util-linux, and mtools, as
doc/SDCARD.md says, so that the monitor's FAT32 is tested against them:

- fat32.img: an MBR with a FAT16 partition first, which is passed over,
  and a FAT32 partition second, of 64 MB, with clusters of one sector, so
  that the root directory and the files take several clusters. Its root
  has the volume label NICETEST, HELLO.BIN, the .bin file given, a
  subdirectory SUB with a file in it, a file with a long name, a file
  whose 8.3 name is in lower case, 20 files FILE01.TXT to FILE20.TXT,
  which take the root past its first cluster, two deleted files, and
  FRAG.BIN, 108 lines that write 9000 to 906B with 0 to 6B, in 4
  clusters, which is fragmented: its first two clusters are those of the
  deleted files, and the script checks that its chain is not contiguous.
- super.img: FAT32 on the whole card, with no partition table, with
  HELLO.BIN.
- fat16.img: an MBR with one FAT16 partition, which the monitor rejects.
- exfat.img: an MBR with one partition of type 7 whose boot sector is
  exFAT's, which the monitor rejects.

Usage: test/fat_image.py HELLO_BIN DIR
"""

import argparse
import os
import struct
import subprocess

SECTOR = 512
MB = 1024 * 1024


def run(*cmd: str, stdin: str | None = None) -> None:
    subprocess.run(cmd, input=stdin, text=True, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def blank(path: str, size: int) -> None:
    with open(path, "wb") as f:
        f.truncate(size)


def mcopy(img: str, offset: int, data: bytes, name: str, tmp: str) -> None:
    """Copies data to the file name on the FAT at the byte offset of img."""
    src = os.path.join(tmp, "src")
    with open(src, "wb") as f:
        f.write(data)
    run("mcopy", "-i", f"{img}@@{offset}", "-D", "o", src, f"::{name}")


def text(name: str, lines: int) -> bytes:
    return "".join(f"{name} line {i}\r\n" for i in range(lines)).encode()


def chain(img: str, offset: int, name: str) -> list[int]:
    """The clusters of the file name in the root of the FAT32 at offset."""
    with open(img, "rb") as f:
        f.seek(offset)
        boot = f.read(SECTOR)
        spc = boot[13]
        reserved, nfats = struct.unpack_from("<HB", boot, 14)
        fatsz, root = struct.unpack_from("<I4xI", boot, 36)
        fat_at = offset + reserved * SECTOR
        data_at = fat_at + nfats * fatsz * SECTOR

        def entry(c: int) -> int:
            f.seek(fat_at + 4 * c)
            value: int = struct.unpack("<I", f.read(4))[0] & 0x0FFFFFFF
            return value

        want = name.upper().split(".")
        short = want[0].ljust(8).encode() + want[1].ljust(3).encode()
        c = root
        while c < 0x0FFFFFF8:
            f.seek(data_at + (c - 2) * spc * SECTOR)
            for _ in range(spc * SECTOR // 32):
                e = f.read(32)
                if e[:11] == short:
                    hi, lo = struct.unpack_from("<H4xH", e, 20)
                    clusters = []
                    k = hi << 16 | lo
                    while k < 0x0FFFFFF8:
                        clusters.append(k)
                        k = entry(k)
                    return clusters
            c = entry(c)
    raise SystemExit(f"{img}: no {name}")


def unknown_hint(img: str, offset: int) -> None:
    """Sets FSInfo's next-free hint of the FAT32 at offset to unknown, so
    that mtools searches for free clusters from the start of the FAT."""
    with open(img, "r+b") as f:
        f.seek(offset + 48)
        fsinfo: int = struct.unpack("<H", f.read(2))[0]
        f.seek(offset + fsinfo * SECTOR + 492)
        f.write(b"\xff\xff\xff\xff")


def mbr(img: str, parts: str) -> None:
    run("sfdisk", "--no-reread", "--no-tell-kernel", "-q", img, stdin=parts)


def fat32(img: str, hello: bytes, tmp: str) -> None:
    blank(img, 100 * MB)
    mbr(img, "label: dos\nstart=2048, size=16MiB, type=6\n"
             "start=34816, size=64MiB, type=c\n")
    run("mkfs.fat", "-F", "16", "--offset", "2048", img, str(16 * 1024))
    off = 34816 * SECTOR
    run("mkfs.fat", "-F", "32", "-s", "1", "-i", "4E494345", "-n", "NICETEST", "--offset",
        "34816", img, str(64 * 1024))
    mcopy(img, off, hello, "HELLO.BIN", tmp)
    run("mmd", "-i", f"{img}@@{off}", "::SUB")
    mcopy(img, off, text("INNER", 3), "SUB/INNER.TXT", tmp)
    mcopy(img, off, text("LONG", 2), "A long name.txt", tmp)
    mcopy(img, off, text("README", 2), "readme.txt", tmp)
    for i in range(1, 21):
        mcopy(img, off, text(f"FILE{i:02}", 1), f"FILE{i:02}.TXT", tmp)
    # Two files of one cluster each, around a third, then deleted, so that
    # FRAG.BIN takes their clusters first and then clusters after the third
    mcopy(img, off, b"G" * SECTOR, "GAP1.TXT", tmp)
    mcopy(img, off, b"K" * SECTOR, "KEEP.TXT", tmp)
    mcopy(img, off, b"G" * SECTOR, "GAP2.TXT", tmp)
    run("mdel", "-i", f"{img}@@{off}", "::GAP1.TXT", "::GAP2.TXT")
    unknown_hint(img, off)
    frag = "".join(f"{0x9000 + i:08X} {i:08X}\n" for i in range(108))
    mcopy(img, off, frag.encode(), "FRAG.BIN", tmp)
    c = chain(img, off, "FRAG.BIN")
    if len(c) != 4 or all(b == a + 1 for a, b in zip(c, c[1:])):
        raise SystemExit(f"{img}: FRAG.BIN is not fragmented: {c}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("hello", help="the .bin file that HELLO.BIN holds")
    parser.add_argument("dir")
    args = parser.parse_args()
    with open(args.hello, "rb") as f:
        hello = f.read()
    tmp = args.dir
    fat32(os.path.join(args.dir, "fat32.img"), hello, tmp)

    img = os.path.join(args.dir, "super.img")
    blank(img, 64 * MB)
    run("mkfs.fat", "-F", "32", "-s", "1", "-i", "4E494345", img)
    mcopy(img, 0, hello, "HELLO.BIN", tmp)

    img = os.path.join(args.dir, "fat16.img")
    blank(img, 20 * MB)
    mbr(img, "label: dos\nstart=2048, type=6\n")
    run("mkfs.fat", "-F", "16", "--offset", "2048", img, str(16 * 1024))

    img = os.path.join(args.dir, "exfat.img")
    blank(img, 4 * MB)
    mbr(img, "label: dos\nstart=2048, type=7\n")
    boot = bytearray(SECTOR)
    boot[0:11] = b"\xeb\x76\x90EXFAT   "
    boot[510:512] = b"\x55\xaa"
    with open(img, "r+b") as f:
        f.seek(2048 * SECTOR)
        f.write(boot)
    os.remove(os.path.join(tmp, "src"))


if __name__ == "__main__":
    main()
