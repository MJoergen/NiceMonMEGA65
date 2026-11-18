#!/usr/bin/env python3
"""The FAT images of the monitor's tests of FAT32 in niceemu (Makefile).

Each is made with the tools of dosfstools, util-linux, and mtools, as
doc/SDCARD.md says, so that the monitor's FAT32 is tested against them:

- fat32.img: an MBR with a FAT16 partition first, which is passed over,
  and a FAT32 partition second, of 64 MB, with clusters of one sector, so
  that the directories and the files take several clusters. Its root has
  the volume label NICETEST, the folder C64 of another core, a HELLO.BIN
  that is not NiceMon's, which writes DEADBEEF to 8000, and the folder
  NICE, NiceMon's (monitor_fat.nasm, #91). NICE has HELLO.BIN, the .bin file
  given, a subdirectory SUB with a file in it, a file with a long name, a
  file whose 8.3 name is in lower case, 20 files FILE01.TXT to
  FILE20.TXT, which take NICE past its first cluster, two deleted files,
  and FRAG.BIN, 108 lines that write 9000 to 906B with 0 to 6B, in 4
  clusters, which is fragmented: its first two clusters are those of the
  deleted files, and the script checks that its chain is not contiguous.
- super.img: FAT32 on the whole card, with no partition table, with
  NICE/HELLO.BIN.
- nonice.img: FAT32 on the whole card with HELLO.BIN and the folder C64
  in its root, and no NICE, which the monitor rejects.
- nicefile.img: the same with a file named NICE, which is no folder, and
  which the monitor rejects too.
- fat16.img: an MBR with one FAT16 partition, which the monitor rejects.
- full.img: FAT32 on the whole card with NICE/HELLO.BIN, and every free
  cluster but the last FULL_FREE marked bad, so that a write fills it.
- lfn.img: FAT32 on the whole card with long names in NICE, as lfn()
  says.
- exfat.img: an MBR with one partition of type 7 whose boot sector is
  exFAT's, which the monitor rejects.

The images are the same bytes at every build, with the same versions of
the tools, so that the tests can compare what the monitor wrote to a
card exactly (test/fat_diff.py): mtools takes the time of every date it
writes from SOURCE_DATE_EPOCH, STAMP, in UTC, the volume IDs are given
with -i, and the MBRs' disk IDs with label-id. STAMP, 2025-06-15
12:34:56, is not the monitor's fixed date, 2026-01-01, so that a date
the monitor kept is told from one it wrote.

Usage: test/fat_image.py HELLO_BIN DIR
"""

import argparse
import os
import struct
import subprocess
from typing import List, Tuple

from fat_tool import Vol, cluster

SECTOR = 512
MB = 1024 * 1024
STAMP = "1749990896"
ENV = dict(os.environ, SOURCE_DATE_EPOCH=STAMP, TZ="UTC")


def run(*cmd: str, stdin: str | None = None) -> None:
    subprocess.run(cmd, input=stdin, text=True, check=True, env=ENV,
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


def chain(img: str, offset: int, path: str) -> list[int]:
    """The clusters of the file or directory at path, such as NICE/FRAG.BIN,
    from the root of the FAT32 at offset."""
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

        def find(c: int, name: str) -> list[int]:
            want = (name.upper() + ".").split(".")
            short = want[0].ljust(8).encode() + want[1].ljust(3).encode()
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
            raise SystemExit(f"{img}: no {path}")

        clusters = [root]
        for name in path.split("/"):
            clusters = find(clusters[0], name)
        return clusters


def unknown_hint(img: str, offset: int) -> None:
    """Sets FSInfo's next-free hint of the FAT32 at offset to unknown, so
    that mtools searches for free clusters from the start of the FAT."""
    with open(img, "r+b") as f:
        f.seek(offset + 48)
        fsinfo: int = struct.unpack("<H", f.read(2))[0]
        f.seek(offset + fsinfo * SECTOR + 492)
        f.write(b"\xff\xff\xff\xff")


def fill(img: str) -> None:
    """Marks every free cluster of the FAT32 at offset 0 of img bad, but
    the last FULL_FREE, in each copy of the FAT, and gives FSInfo their
    count and the hint 2, from which a search goes through all the others."""
    with open(img, "r+b") as f:
        boot = f.read(SECTOR)
        spc = boot[13]
        reserved, nfats = struct.unpack_from("<HB", boot, 14)
        total, fatsz = struct.unpack_from("<II", boot, 32)
        fsinfo: int = struct.unpack_from("<H", boot, 48)[0]
        data = reserved + nfats * fatsz
        top = (total - data) // spc + 2
        f.seek(reserved * SECTOR)
        fat = bytearray(f.read(fatsz * SECTOR))
        for c in range(2, top - FULL_FREE):
            if struct.unpack_from("<I", fat, 4 * c)[0] & 0x0FFFFFFF == 0:
                struct.pack_into("<I", fat, 4 * c, 0x0FFFFFF7)
        for k in range(nfats):
            f.seek((reserved + k * fatsz) * SECTOR)
            f.write(fat)
        f.seek(fsinfo * SECTOR + 488)
        f.write(struct.pack("<II", FULL_FREE, 2))


def entries(img: str, offset: int, path: str) -> list[int]:
    """The byte offsets in img of the entries of the folder at path, up to
    the first free one with a 0, which ends it."""
    with open(img, "rb") as f:
        f.seek(offset)
        boot = f.read(SECTOR)
        spc = boot[13]
        reserved, nfats = struct.unpack_from("<HB", boot, 14)
        fatsz = struct.unpack_from("<I", boot, 36)[0]
        data_at = offset + (reserved + nfats * fatsz) * SECTOR
        at: list[int] = []
        for c in chain(img, offset, path):
            for k in range(spc * SECTOR // 32):
                where = data_at + (c - 2) * spc * SECTOR + 32 * k
                f.seek(where)
                if f.read(1) == b"\0":
                    return at
                at.append(where)
        return at


def pad(img: str, offset: int, path: str, slots: int, tmp: str) -> None:
    """Short files PAD01.TXT and on in the folder at path, until its next
    entry is the last of a run of slots entries, so that a name of two
    long-name entries after them has its first in the run and the rest
    after it."""
    k = 1
    while len(entries(img, offset, path)) % slots != slots - 1:
        mcopy(img, offset, text(f"PAD{k:02}", 1), f"{path}/PAD{k:02}.TXT", tmp)
        k += 1


def lfn(img: str, hello: bytes, tmp: str) -> None:
    """lfn.img: FAT32 on the whole card of 128 MB, with clusters of 2
    sectors, which are enough for FAT32, and
    long names in NICE: my prog.bin, the .bin file given, with a blank in
    its name; mixed.Bin, whose 8.3 name needs no tail; lower.bin, which
    mtools writes as an 8.3 name with the lower-case flags of byte 12;
    café.bin, an 8.3 name with a character of code page 850; λx.bin, a
    long name with a character outside ASCII and code page 850;
    mandelbrot1.txt and mandelbrot2.txt, which share their first 6
    letters, MANDEL~1.TXT and MANDEL~2.TXT; a name of 255 characters;
    two names whose long-name entries cross the end of a sector, and of a
    cluster, after the files PAD01.TXT and on; and bad sum.bin, whose
    long-name entry has a wrong checksum. The files that LOAD reads end
    with .bin, as LOAD takes no other, though they hold text."""
    blank(img, 128 * MB)
    run("mkfs.fat", "-F", "32", "-s", "2", "-i", "4E494345", img)
    run("mmd", "-i", f"{img}@@0", "::NICE")
    mcopy(img, 0, hello, "NICE/my prog.bin", tmp)
    for name in ("mixed.Bin", "lower.bin", "caf\u00e9.bin", "\u03bbx.bin",
                 "mandelbrot1.txt", "mandelbrot2.txt", "n" * 251 + ".txt"):
        mcopy(img, 0, text(name.split(".")[0][:8], 1), "NICE/" + name, tmp)
    pad(img, 0, "NICE", 16, tmp)
    mcopy(img, 0, text("SECTOR", 1), "NICE/across a sector.bin", tmp)
    pad(img, 0, "NICE", 32, tmp)
    mcopy(img, 0, text("CLUSTER", 1), "NICE/across a cluster.bin", tmp)
    if len(entries(img, 0, "NICE")) % 32 != 2:
        raise SystemExit(f"{img}: the long name does not cross a cluster")
    # bad sum.bin's one long-name entry, before its 8.3 entry, with its
    # checksum off by one, last, as mtools would take the entry for a
    # free one
    mcopy(img, 0, text("BADSUM", 1), "NICE/bad sum.bin", tmp)
    at = entries(img, 0, "NICE")[-2]
    with open(img, "r+b") as f:
        f.seek(at + 11)
        attr, _, check = f.read(3)
        if attr != 0x0F:
            raise SystemExit(f"{img}: no long-name entry before BADSUM~1.BIN")
        f.seek(at + 13)
        f.write(bytes([check ^ 1]))


def mbr(img: str, parts: str) -> None:
    """Writes the MBR of parts, an sfdisk script that starts with the
    label and a fixed disk ID."""
    run("sfdisk", "--no-reread", "--no-tell-kernel", "-q", img, stdin=parts)


# The free clusters of full.img, its last ones
FULL_FREE = 3

# The root's HELLO.BIN, which is not NiceMon's, so no test may load it
DECOY = b"00008000 DEADBEEF\n"


def others(img: str, off: int, tmp: str) -> None:
    """What other cores keep in the root: their folder, C64, with a file,
    and a HELLO.BIN of their own."""
    run("mmd", "-i", f"{img}@@{off}", "::C64")
    mcopy(img, off, text("C64", 1), "C64/GAME.PRG", tmp)
    mcopy(img, off, DECOY, "HELLO.BIN", tmp)


def fat32(img: str, hello: bytes, tmp: str) -> None:
    blank(img, 100 * MB)
    mbr(img, "label: dos\nlabel-id: 0x4e494345\nstart=2048, size=16MiB, type=6\n"
             "start=34816, size=64MiB, type=c\n")
    run("mkfs.fat", "-F", "16", "-i", "4E494345", "--offset", "2048", img, str(16 * 1024))
    off = 34816 * SECTOR
    run("mkfs.fat", "-F", "32", "-s", "1", "-i", "4E494345", "-n", "NICETEST", "--offset",
        "34816", img, str(64 * 1024))
    # mkfs.fat dates the label's entry, the root's first, with the host's
    # time: STAMP's, as FAT holds it
    with open(img, "r+b") as f:
        f.seek(off)
        boot = f.read(SECTOR)
        reserved, nfats = struct.unpack_from("<HB", boot, 14)
        fatsz = struct.unpack_from("<I", boot, 36)[0]
        f.seek(off + (reserved + nfats * fatsz) * SECTOR + 13)
        time, date = 12 << 11 | 34 << 5 | 28, 45 << 9 | 6 << 5 | 15
        f.write(struct.pack("<BHHH2xHH", 0, time, date, date, time, date))
    others(img, off, tmp)
    run("mmd", "-i", f"{img}@@{off}", "::NICE")
    mcopy(img, off, hello, "NICE/HELLO.BIN", tmp)
    run("mmd", "-i", f"{img}@@{off}", "::NICE/SUB")
    mcopy(img, off, text("INNER", 3), "NICE/SUB/INNER.TXT", tmp)
    mcopy(img, off, text("LONG", 2), "NICE/A long name.txt", tmp)
    mcopy(img, off, text("README", 2), "NICE/readme.txt", tmp)
    for i in range(1, 21):
        mcopy(img, off, text(f"FILE{i:02}", 1), f"NICE/FILE{i:02}.TXT", tmp)
    # Two files of one cluster each, around a third, then deleted, so that
    # FRAG.BIN takes their clusters first and then clusters after the third
    mcopy(img, off, b"G" * SECTOR, "NICE/GAP1.TXT", tmp)
    mcopy(img, off, b"K" * SECTOR, "NICE/KEEP.TXT", tmp)
    mcopy(img, off, b"G" * SECTOR, "NICE/GAP2.TXT", tmp)
    run("mdel", "-i", f"{img}@@{off}", "::NICE/GAP1.TXT", "::NICE/GAP2.TXT")
    unknown_hint(img, off)
    frag = "".join(f"{0x9000 + i:08X} {i:08X}\n" for i in range(108))
    mcopy(img, off, frag.encode(), "NICE/FRAG.BIN", tmp)
    c = chain(img, off, "NICE/FRAG.BIN")
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

    lfn(os.path.join(args.dir, "lfn.img"), hello, tmp)

    img = os.path.join(args.dir, "super.img")
    blank(img, 64 * MB)
    run("mkfs.fat", "-F", "32", "-s", "1", "-i", "4E494345", img)
    run("mmd", "-i", f"{img}@@0", "::NICE")
    mcopy(img, 0, hello, "NICE/HELLO.BIN", tmp)

    img = os.path.join(args.dir, "nonice.img")
    blank(img, 64 * MB)
    run("mkfs.fat", "-F", "32", "-s", "1", "-i", "4E494345", img)
    others(img, 0, tmp)

    img = os.path.join(args.dir, "nicefile.img")
    blank(img, 64 * MB)
    run("mkfs.fat", "-F", "32", "-s", "1", "-i", "4E494345", img)
    others(img, 0, tmp)
    mcopy(img, 0, text("NICE", 1), "NICE", tmp)

    img = os.path.join(args.dir, "full.img")
    blank(img, 34 * MB)
    run("mkfs.fat", "-F", "32", "-s", "1", "-i", "4E494345", img)
    run("mmd", "-i", f"{img}@@0", "::NICE")
    mcopy(img, 0, hello, "NICE/HELLO.BIN", tmp)
    fill(img)

    img = os.path.join(args.dir, "fat16.img")
    blank(img, 20 * MB)
    mbr(img, "label: dos\nlabel-id: 0x4e494345\nstart=2048, type=6\n")
    run("mkfs.fat", "-F", "16", "-i", "4E494345", "--offset", "2048", img, str(16 * 1024))

    img = os.path.join(args.dir, "exfat.img")
    blank(img, 4 * MB)
    mbr(img, "label: dos\nlabel-id: 0x4e494345\nstart=2048, type=7\n")
    boot = bytearray(SECTOR)
    boot[0:11] = b"\xeb\x76\x90EXFAT   "
    boot[510:512] = b"\x55\xaa"
    with open(img, "r+b") as f:
        f.seek(2048 * SECTOR)
        f.write(boot)
    extra(args.dir, tmp)
    os.remove(os.path.join(tmp, "src"))


def copy(src: str, dst: str) -> str:
    """A copy of the image src, as sparse as it is"""
    run("cp", "--sparse=always", src, dst)
    return dst


def fat32_of(img: str, mb: int, *opts: str) -> str:
    """FAT32 on the whole card of mb megabytes, with the folder NICE"""
    blank(img, mb * MB)
    run("mkfs.fat", "-F", "32", "-i", "4E494345", *opts, img)
    run("mmd", "-i", f"{img}@@0", "::NICE")
    return img


def letters(n: int) -> bytes:
    """n bytes of the letters A to Z, round again"""
    return bytes(65 + i % 26 for i in range(n))


def extra(d: str, tmp: str) -> None:
    """The images of test/fat_runs.py, each named for its suite and
    described there, made from super.img and lfn.img, or anew."""
    super_img = os.path.join(d, "super.img")

    def at(name: str) -> str:
        return os.path.join(d, name)

    # fatload: LOAD's lines
    img = copy(super_img, at("lines.img"))
    mcopy(img, 0, b"".join([
        b"00008000 00000001\n", b"\n", b"   \n", b"8001 2\n", b"\t8002\t3\t\n", b"8003 4 x\n",
        b"7FFF 5\n", b"123456789 6\n", b"8004 123456789\n", b"8005\n",
        b"8006 7" + b" " * 70 + b"\n", b"8007 8" + b" " * 71 + b"\n",
        b"8008 9\x01\x80\xff\n", b"8009 A\x7f\n", b"800A B\r", b"800B C\r\n", b"800C D\n", b"\r",
        b"FFFF0000 E\n", b"0x8010 1\n", b"800D  0000000F  \n", b"  800e Bc\n", b"8020 1\x00\x00\n",
        b" " * 100 + b"\n", b" " * 80 + b"8011 5\n", b"8012 6" + b" " * 100 + b"\n",
        b" " * 72 + b"8013 7\n", b"800F 11"]), "NICE/LINES.BIN", tmp)
    mcopy(img, 0, b"8100 1\r\n8101 2\r\n\r\n8102 3\rbad\n8103 4\n", "NICE/CRLF.BIN", tmp)
    mcopy(img, 0, b"\r\n\n   \n", "NICE/BLANK.BIN", tmp)
    mcopy(img, 0, "".join(f"{0x9000 + i:08X} {i:08X}\n" for i in range(100)).encode(),
          "NICE/CUT.BIN", tmp)
    v = Vol(img, write=True)
    _, e = v.entry(b"CUT     BIN")
    v.set(v.chain(cluster(e))[1], 0)
    # fattab: slot 1's card, with names of 68 and 69 characters, and a
    # directory
    img = copy(super_img, at("tab1.img"))
    mcopy(img, 0, b"", "NICE/" + "a" * 64 + ".bin", tmp)
    mcopy(img, 0, b"", "NICE/" + "b" * 65 + ".bin", tmp)
    run("mmd", "-i", f"{img}@@0", "::NICE/hdir")
    # fatchain: damaged chains, files of 1500 bytes, 3 clusters
    img = copy(super_img, at("chains.img"))
    for name in ("CUT", "FREE", "LONG", "ZERO", "LOOP", "BADC", "EDGE", "HIGH"):
        mcopy(img, 0, letters(1500 if name not in ("ZERO", "EDGE", "HIGH") else 10),
              f"NICE/{name}.TXT", tmp)
    v = Vol(img, write=True)

    def first(name: bytes) -> Tuple[int, List[int]]:
        k, e = v.entry(name)
        return k, v.chain(cluster(e))
    v.set(first(b"CUT     TXT")[1][1], 0)                 # the second cluster free
    v.set(first(b"FREE    TXT")[1][1], 0)                 # the same, for SAVE
    k, _ = first(b"LONG    TXT")
    v.put(k + 28, "<I", 3500)                             # a size past the chain
    for n83, c in ((b"ZERO    TXT", 0), (b"EDGE    TXT", v.top - 1), (b"HIGH    TXT", v.top)):
        k, ch = first(n83)
        v.set(ch[0], 0)
        v.put(k + 20, "<H", c >> 16)
        v.put(k + 26, "<H", c & 0xFFFF)
    _, ch = first(b"LOOP    TXT")
    v.set(ch[-1], ch[0])                                  # the last links to the first
    v.set(first(b"BADC    TXT")[1][1], 0x0FFFFFF7)        # a bad-cluster mark
    # fatlfn: lfn.img with its entries damaged
    img = copy(at("lfn.img"), at("lfnx.img"))
    v = Vol(img, write=True)
    v.put(v.entry(b"PAD01   TXT")[0], "B", 0x05)          # 0x05 for 0xE5
    v.put(v.entry(b"MYPROG~1BIN")[0], "B", 0xE5)          # orphan long-name entries
    v.put(v.entry(b"PAD02   TXT")[0] + 11, "B", 0x08)     # a volume label
    nice = [k for path, chain in v.dirs() if path == "NICE/" for k, _ in v.entries(chain)]
    k, _ = v.entry(b"MIXED   BIN")
    v.put(nice[nice.index(k // 32) - 1] * 32, "B", 0x42)  # numbered 2, not 1
    # the 255 characters of n...n.txt made 256: its last long-name entry,
    # 20 before the 8.3 entry, has the characters 248 to 255, then 0, then
    # 0xFFFF; the 256th, at byte 20, is x, and the 0 after it
    k, _ = v.entry(b"NNNNNN~1TXT")
    v.put(nice[nice.index(k // 32) - 20] * 32 + 20, "<HH", ord("x"), 0)
    # fatmount: cards that are no FAT32, or not quite
    img = blank_fat(at("m_fat12.img"), 2, "-F", "12")
    img = blank_fat(at("m_fat16.img"), 20, "-F", "16")
    img = at("m_fat12p.img")
    blank(img, 4 * MB)
    mbr(img, "label: dos\nlabel-id: 0x4e494345\nstart=2048, type=1\n")
    run("mkfs.fat", "-F", "12", "-i", "4E494345", "--offset", "2048", img, "1024")
    img = at("m_nopart.img")
    blank(img, MB)
    mbr(img, "label: dos\nlabel-id: 0x4e494345\n")
    blank(at("m_zero.img"), MB)
    for t in ("83", "b"):
        img = at(f"m_p{t}.img")
        blank(img, 80 * MB)
        mbr(img, f"label: dos\nlabel-id: 0x4e494345\nstart=2048, type={t}\n")
        run("mkfs.fat", "-F", "32", "-s", "1", "-i", "4E494345", "--offset", "2048", img,
            str(70 * 1024))
        run("mmd", "-i", f"{img}@@{2048 * SECTOR}", "::NICE")
    # super.img's boot sector changed: 32 reserved sectors, 2 FATs of 1009
    # sectors, 131072 sectors, so 2050 before the data and 129022 clusters
    for name, at_, fmt, val in (
            ("nosig", 510, "<H", 0), ("jump", 0, "B", 0), ("bps", 11, "<H", 1024),
            ("spc0", 13, "B", 0), ("spc3", 13, "B", 3), ("rsvd0", 14, "<H", 0),
            ("nfats0", 16, "B", 0), ("fatsz0", 36, "<I", 0),
            ("fatszbig", 36, "<I", 0x80000000), ("nodata", 32, "<I", 2050),
            ("fat16sz", 22, "<H", 1009), ("rootent", 17, "<H", 16),
            ("c4084", 32, "<I", 2050 + 4084), ("c4085", 32, "<I", 2050 + 4085),
            ("c65524", 32, "<I", 2050 + 65524), ("c65525", 32, "<I", 2050 + 65525),
            ("root1", 44, "<I", 1), ("roottop", 44, "<I", 129024),
            ("total", 32, "<I", 131073)):
        v = Vol(copy(super_img, at(f"m_{name}.img")), write=True)
        v.put(at_, fmt, val)
    # a 16-bit total of 65535, 1 reserved sector, and FATs of 1 sector,
    # 65532 clusters, which the layout checks pass with, though the 32-bit
    # total is the volume's (issue #151, B9)
    v = Vol(copy(super_img, at("m_total16.img")), write=True)
    v.put(19, "<H", 65535)
    v.put(14, "<H", 1)
    v.put(36, "<I", 1)
    # m_pb.img with its partition one sector shorter than its volume
    img = copy(at("m_pb.img"), at("m_psize.img"))
    with open(img, "r+b") as f:
        f.seek(446 + 12)
        f.write(struct.pack("<I", 70 * 1024 * 2 - 1))
    v = Vol(copy(super_img, at("m_nicecl.img")), write=True)
    v.put(v.entry(b"NICE       ", "/")[0] + 26, "<H", 0)
    # FATs of 2^25 sectors, whose 2^32 entries wrap to 0, in a volume that
    # has room for them, so that no cluster is in the volume
    v = Vol(copy(super_img, at("m_fatwrap.img")), write=True)
    v.put(36, "<I", 1 << 25)
    v.put(32, "<I", 32 + 2 * (1 << 25) + 70000)
    # the folder NICE of two clusters, 16 entries each, the second lost
    img = copy(super_img, at("m_baddir.img"))
    for i in range(1, 21):
        mcopy(img, 0, b"", f"NICE/F{i:02}.TXT", tmp)
    v = Vol(img, write=True)
    v.set(v.chain(cluster(v.entry(b"NICE       ", "/")[1]))[0], 0)
    # fatgeo: clusters of 8 and 64 sectors, and one FAT
    fat32_of(at("spc8.img"), 300, "-s", "8")
    fat32_of(at("spc64.img"), 2100, "-s", "64")
    fat32_of(at("fat1.img"), 64, "-s", "1", "-f", "1")
    # fatinfo: FSInfo and the FAT's entries; i_total.img has TOP1.TXT and
    # TOP2.TXT at the clusters 129151 and 129152, the last of its FATs of
    # 1009 sectors and the one after it, on a card and a volume of 1024
    # sectors more, so 130046 clusters
    img = copy(super_img, at("i_total.img"))
    mcopy(img, 0, b"0123456789", "NICE/TOP1.TXT", tmp)
    mcopy(img, 0, b"0123456789", "NICE/TOP2.TXT", tmp)
    v = Vol(img, write=True)
    for n83, c in ((b"TOP1    TXT", 129151), (b"TOP2    TXT", 129152)):
        k, e = v.entry(n83)
        v.set(cluster(e), 0)
        v.put(k + 20, "<H", c >> 16)
        v.put(k + 26, "<H", c & 0xFFFF)
    for name, at_, fmt, val in (
            ("i_last", SECTOR + 492, "<I", 129023), ("i_wrap", SECTOR + 492, "<I", 129023),
            ("i_ff", SECTOR + 492, "<I", 0xFFFFFFFF),
            ("i_nosig", SECTOR, "<I", 0), ("i_bpb0", 48, "<H", 0),
            ("i_bpbff", 48, "<H", 0xFFFF), ("i_total", 32, "<I", 131072 + 1024)):
        img = at(f"{name}.img")
        if name == "i_total":
            with open(img, "r+b") as f:
                f.truncate((131072 + 1024) * SECTOR)
        v = Vol(img if name == "i_total" else copy(super_img, img), write=True)
        v.put(at_, fmt, val)
        if name == "i_wrap":
            v.set(129023, 0x0FFFFFFF)   # the last cluster in use, though in no file
    v = Vol(copy(super_img, at("i_top.img")), write=True)
    for c in range(32, 40):
        v.set(c, 0x10000000)
    # fatfull: the folder NICE of 65536 entries, all used but the last, in
    # the clusters 3 and 1000 to 5094
    v = Vol(copy(super_img, at("bigdir.img")), write=True)
    chain = [3] + list(range(1000, 1000 + 4095))
    for a, b in zip(chain, chain[1:]):
        v.set(a, b)
    v.set(chain[-1], 0x0FFFFFFF)
    folder = bytearray()
    for k in range(65535):
        ent = bytearray(32)
        ent[0:11] = f"F{k:05d}  TXT".encode()
        ent[11] = 0x20
        folder += ent
    folder += bytes(32)
    for n, c in enumerate(chain):
        v.put((v.data + c - 2) * SECTOR, f"{SECTOR}s", bytes(folder[n * SECTOR:(n + 1) * SECTOR]))
    v.put(SECTOR + 488, "<II", 0xFFFFFFFF, 1000 + 4095)
    # fatrows: DIR's rows
    img = copy(super_img, at("rows.img"))
    mcopy(img, 0, b"", "NICE/EMPTY.TXT", tmp)
    mcopy(img, 0, b"12345", "NICE/SYS.TXT", tmp)
    run("mattrib", "-i", f"{img}@@0", "+h", "::NICE/EMPTY.TXT")
    run("mattrib", "-i", f"{img}@@0", "+s", "::NICE/SYS.TXT")
    for n in (23, 24, 25, 26):
        mcopy(img, 0, b"x" * n, "NICE/" + chr(ord("a") + n - 23) * (n - 4) + ".txt", tmp)
    run("mmd", "-i", f"{img}@@0", "::NICE/a dir")
    mcopy(img, 0, b"", "NICE/HUGE.BIN", tmp)
    v = Vol(img, write=True)
    v.put(v.entry(b"HUGE    BIN")[0] + 28, "<I", 0xFFFFFFFF)


def blank_fat(img: str, mb: int, *opts: str) -> str:
    """FAT12 or FAT16 on the whole card, with the folder NICE"""
    blank(img, mb * MB)
    run("mkfs.fat", "-i", "4E494345", *opts, img)
    run("mmd", "-i", f"{img}@@0", "::NICE")
    return img


if __name__ == "__main__":
    main()
