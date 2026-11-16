#!/usr/bin/env python3
"""What a test of FAT32 writing left on a card (Makefile, doc/SDCARD.md,
"Testing"): fsck.fat -n of its FAT32, the names in its folder NICE, from
mdir -b, and the text of the files given, from mtype, so that the
monitor's writes are checked against dosfstools and mtools. With
--stamps, the dates and the times of the 8.3 entries in NICE of those
names follow, as the entries hold them, to the two seconds and the
hundredths that mdir does not show: the creation's, with its hundredths,
and the last write's. The other files' are left out, as the images get
the time of their build.

The FAT32 is at the start of IMAGE, or in its partition from sector
START when one is given, which is copied out for fsck.fat. fsck.fat's
first line, its version, is left out, and the image's path is IMAGE.

Usage: test/fat_check.py IMAGE [--start START] [--stamps NAME...] [FILE...]
"""

import argparse
import os
import struct
import subprocess
import sys

SECTOR = 512


def out(cmd: list[str]) -> str:
    p = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return p.stdout + (f"(exit {p.returncode})\n" if p.returncode else "")


def stamp(date: int, time: int) -> str:
    """A date and a time of an entry, as FAT holds them."""
    return (f"{1980 + (date >> 9):04d}-{date >> 5 & 15:02d}-{date & 31:02d} "
            f"{time >> 11:02d}:{time >> 5 & 63:02d}:{2 * (time & 31):02d}")


def stamps(image: str, start: int, names: list[str]) -> str:
    """The dates and the times of the 8.3 entries of names, such as
    NEW.BIN, in the folder NICE of the FAT32 at sector start of image, in
    the order of the folder, one line each: the name, the
    creation's date and time, its hundredths over the even second, byte
    13 of the entry, and the last write's date and time."""
    with open(image, "rb") as f:
        f.seek(start * SECTOR)
        boot = f.read(SECTOR)
        size, per, reserved, fats = struct.unpack_from("<HBHB", boot, 11)
        fat_words = struct.unpack_from("<I", boot, 36)[0]
        root = struct.unpack_from("<I", boot, 44)[0]
        f.seek((start + reserved) * size)
        fat = f.read(fat_words * size)
        data = start + reserved + fats * fat_words

        def folder(cluster: int) -> list[bytes]:
            entries = []
            while 2 <= cluster < 0x0FFFFFF8:
                f.seek((data + (cluster - 2) * per) * size)
                block = f.read(per * size)
                entries += [block[i:i + 32] for i in range(0, len(block), 32)]
                cluster = struct.unpack_from("<I", fat, 4 * cluster)[0] & 0x0FFFFFFF
            return entries

        def live(entries: list[bytes]) -> list[bytes]:
            out = []
            for e in entries:
                if e[0] == 0:
                    break
                if e[0] != 0xE5 and e[11] & 0x0F != 0x0F:
                    out.append(e)
            return out

        nice = [e for e in live(folder(root)) if e[:11] == b"NICE       "]
        if not nice:
            return "No folder NICE\n"
        cluster = struct.unpack_from("<H", nice[0], 20)[0] << 16 | \
            struct.unpack_from("<H", nice[0], 26)[0]
        rows = []
        for e in live(folder(cluster)):
            if e[11] & 0x10:
                continue
            ctime, cdate = struct.unpack_from("<HH", e, 14)
            wtime, wdate = struct.unpack_from("<HH", e, 22)
            name = e[:8].decode("latin-1").rstrip() + "." + e[8:11].decode("latin-1").rstrip()
            if name not in names:
                continue
            rows.append(f"{name:12} created {stamp(cdate, ctime)} +{e[13]:3d}/100, "
                        f"written {stamp(wdate, wtime)}")
        return "".join(row + "\n" for row in rows)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("image")
    parser.add_argument("--start", type=int, default=0,
                        help="the first sector of the FAT32 partition")
    parser.add_argument("--stamps", nargs="+", default=[], metavar="NAME",
                        help="the dates and the times of these entries in NICE")
    parser.add_argument("files", nargs="*")
    args = parser.parse_intermixed_args()
    img = args.image
    if args.start:
        img = args.image + ".part"
        with open(args.image, "rb") as f, open(img, "wb") as g:
            f.seek(args.start * SECTOR)
            g.write(f.read())
    fsck = out(["fsck.fat", "-n", img]).replace(img, "IMAGE").splitlines(keepends=True)
    sys.stdout.write("fsck.fat -n:\n" + "".join(fsck[1:]))
    at = f"{args.image}@@{args.start * SECTOR}"
    names = out(["mdir", "-b", "-i", at, "::NICE"]).replace("::/NICE/", "")
    sys.stdout.write("Files in NICE: " + " ".join(names.split()) + "\n")
    for name in args.files:
        sys.stdout.write(f"{name}:\n" + out(["mtype", "-i", at, f"::NICE/{name}"]))
    if args.stamps:
        sys.stdout.write("Dates and times in NICE:\n" + stamps(args.image, args.start, args.stamps))
    if img != args.image:
        os.remove(img)


if __name__ == "__main__":
    main()
