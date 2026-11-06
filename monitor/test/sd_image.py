#!/usr/bin/env python3
"""The image of an SD card for the monitor's tests in niceemu (Makefile).

It has 4 sectors, so SD_LAST is 3: sector 0 ends with 55 AA, as a boot
sector does, sector 1 has the bytes 0 to 255 twice, which shows every
byte in hex and as text, and sectors 2 and 3 are 0. With --written, it is
the image after test/sd.nasm, whose sector 2 is sector 1 with ABCD in its
first 4 bytes.

Usage: test/sd_image.py [--written] FILE
"""

import argparse

SECTOR = 512


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--written", action="store_true",
                        help="the image after test/sd.nasm has written sector 2")
    parser.add_argument("file")
    args = parser.parse_args()
    img = bytearray(4 * SECTOR)
    img[SECTOR - 2:SECTOR] = b"\x55\xaa"
    pattern = bytes(i & 0xFF for i in range(SECTOR))
    img[SECTOR:2 * SECTOR] = pattern
    if args.written:
        img[2 * SECTOR:3 * SECTOR] = b"ABCD" + pattern[4:]
    with open(args.file, "wb") as f:
        f.write(img)


if __name__ == "__main__":
    main()
