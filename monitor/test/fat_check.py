#!/usr/bin/env python3
"""What a test of FAT32 writing left on a card (Makefile, doc/SDCARD.md,
"Testing"): fsck.fat -n of its FAT32, the names in its folder NICE, from
mdir -b, and the text of the files given, from mtype, so that the
monitor's writes are checked against dosfstools and mtools.

The FAT32 is at the start of IMAGE, or in its partition from sector
START when one is given, which is copied out for fsck.fat. fsck.fat's
first line, its version, is left out, and the image's path is IMAGE.

Usage: test/fat_check.py IMAGE [--start START] [FILE...]
"""

import argparse
import os
import subprocess
import sys

SECTOR = 512


def out(cmd: list[str]) -> str:
    p = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return p.stdout + (f"(exit {p.returncode})\n" if p.returncode else "")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("image")
    parser.add_argument("--start", type=int, default=0,
                        help="the first sector of the FAT32 partition")
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
    if img != args.image:
        os.remove(img)


if __name__ == "__main__":
    main()
