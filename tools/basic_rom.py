#!/usr/bin/env python3
"""Fill in and check the header of BASIC's image (issue #153).

BASIC's image is a .bin file at 0x4000-0x7FFF (nice_cpu's ISA.md
section 10.4), whose header follows its two vectors (doc/BASIC_ROM.md,
"The image"):

  0x4004  the magic word, NBAS in packed ASCII
  0x4005  the interface: the version of the layout of the monitor's RAM
          in bits 31..16, and the entries that the image calls in 15..0
  0x4006  the length in words, from 0x4000
  0x4007  the checksum: the sum of the words over the length is 0
  0x4008  the address of the version text
  0x4009  the version as a number: major, minor, patch, and commits
  0x400A  the flags: bit 0 is "keep"
  0x400B  the words of BASIC's own RAM

The assembler writes the magic word, the interface, the address of the
text, and the words of the RAM, and 0 for the others, which this script
fills in after assembly:

  basic_rom.py fill IN OUT --version V [--keep]
      the length, from the last address of IN, the version as a number,
      from V, such as V2.3.1 or V2.3-12-gabcdef0-dirty, "keep" with
      --keep, and then the checksum, written to OUT
  basic_rom.py check FILE...
      checks each image's lines, addresses, header, and checksum, and
      prints its version, length, and flags

The check takes a file's lines as the monitor's loader takes them from
a card (monitor/monitor_basic.nasm), so that a file that passes here is
not refused there for its lines: each is an address and a word of 1 to
8 hex digits, of at most 76 characters, and the header's 12 words,
0x4000 to 0x400B, all have their lines. The loader alone knows whether
the image's interface is its monitor's.

tools/load.py and tools/hwtest.py use the functions here: set_keep() for
an image that a tool loads, ram_words() for the end of a program's RAM,
and text() for the banner.

Only the Python standard library is used.
"""

import argparse
import re
import sys

BASE = 0x4000
END = 0x8000
MAGIC = 0x5341424E      # NBAS, the first character in the low byte
H_MAGIC, H_IFACE, H_LENGTH, H_SUM, H_TEXT, H_VERSION, H_FLAGS, H_RAM = range(0x4004, 0x400C)
FLAG_KEEP = 1
MASK = 0xFFFFFFFF
# The words of BASIC's RAM that the monitor takes from the header, and
# what it takes from an image without the magic word or out of the range
# (monitor/common.nasm, BAS_RAM_MIN, BAS_RAM_MAX, and BASIC_WORDS)
RAM_MIN = 0x400
RAM_MAX = 0x2000
RAM_DEFAULT = 0x800
# A line as the monitor's loader takes it from a card (bl_getline of
# monitor/monitor_basic.nasm, and bin_parse of monitor/monitor.nasm): an
# address and a word, each of 1 to 8 hex digits, with blanks or TABs
# between them and around them, in at most LINE_MAX characters
LINE = re.compile(r"[ \t]*([0-9A-Fa-f]{1,8})[ \t]+([0-9A-Fa-f]{1,8})[ \t]*")
LINE_MAX = 76


class ImageError(Exception):
    pass


def read_image(path: str) -> dict[int, int]:
    """The words of an image, by address, with the rules of a file on a
    card: each line an address and a word as the loader takes them, and
    the addresses in 0x4000-0x7FFF, rising from line to line."""
    image: dict[int, int] = {}
    last = -1
    with open(path) as f:
        for number, line in enumerate(f, 1):
            line = line.rstrip("\r\n")
            if not line.strip(" \t"):
                continue
            m = LINE.fullmatch(line)
            if not m:
                raise ImageError(f"{path}:{number}: not an address and a word, "
                                 "each of 1 to 8 hex digits")
            if len(line) > LINE_MAX:
                raise ImageError(f"{path}:{number}: more than {LINE_MAX} characters")
            addr, word = int(m[1], 16), int(m[2], 16)
            if not BASE <= addr < END:
                raise ImageError(f"{path}:{number}: address {addr:08X} outside "
                                 f"{BASE:04X}-{END - 1:04X}")
            if addr <= last:
                raise ImageError(f"{path}:{number}: address {addr:08X} does not rise")
            image[addr] = word
            last = addr
    return image


def write_image(path: str, image: dict[int, int]) -> None:
    with open(path, "w") as f:
        for addr in sorted(image):
            f.write(f"{addr:08x} {image[addr]:08x}\n")


def version_number(text: str) -> int:
    """V2.3.2 as 0x02030200, and the commits since the tag, as git describe
    counts them, in bits 7..0, at most 255. A version that is not a tag's,
    such as a bare hash, is 0."""
    m = re.fullmatch(r"V(\d+)\.(\d+)(?:\.(\d+))?(?:-(\d+)-g[0-9a-f]+)?(?:-dirty)?", text)
    if not m:
        return 0
    major, minor, patch = int(m[1]), int(m[2]), int(m[3] or 0)
    if max(major, minor, patch) > 255:
        raise ImageError(f"version {text}: a number above 255")
    return major << 24 | minor << 16 | patch << 8 | min(int(m[4] or 0), 255)


def checksum_of(image: dict[int, int], length: int) -> int:
    """The sum of the words over the length, a missing word as 0."""
    return sum(image.get(BASE + i, 0) for i in range(length)) & MASK


def fill(image: dict[int, int], version: str, keep: bool) -> None:
    if image.get(H_MAGIC) != MAGIC:
        raise ImageError("no magic word NBAS at 0x4004")
    for addr in (H_LENGTH, H_SUM, H_VERSION, H_FLAGS):
        if image.get(addr, 0):
            raise ImageError(f"the header's word at {addr:04X} is not 0 before it is filled")
    image[H_LENGTH] = max(image) + 1 - BASE
    image[H_VERSION] = version_number(version)
    image[H_FLAGS] = FLAG_KEEP if keep else 0
    image[H_SUM] = 0
    image[H_SUM] = -checksum_of(image, image[H_LENGTH]) & MASK


def set_keep(image: dict[int, int], keep: bool = True) -> None:
    """Sets or clears "keep" in an image with the magic word, and its
    checksum again over its length; an image without it is left alone."""
    if image.get(H_MAGIC) != MAGIC:
        return
    flags = image.get(H_FLAGS, 0) & ~FLAG_KEEP
    image[H_FLAGS] = flags | (FLAG_KEEP if keep else 0)
    image[H_SUM] = 0
    image[H_SUM] = -checksum_of(image, image.get(H_LENGTH, 0)) & MASK


def ram_words(image: dict[int, int]) -> int:
    """The words of BASIC's RAM, as the monitor takes them from the
    header (monitor.nasm, bas_ram)."""
    ram = image.get(H_RAM, 0)
    if image.get(H_MAGIC) != MAGIC or not RAM_MIN <= ram <= RAM_MAX:
        return RAM_DEFAULT
    return ram


def text(image: dict[int, int]) -> str:
    """The version text of the header, a packed text up to a 0 byte,
    as the banner shows it."""
    out = ""
    addr = image.get(H_TEXT, 0)
    while BASE <= addr < END and len(out) < 64:
        word = image.get(addr, 0)
        for i in range(4):
            c = word >> (8 * i) & 255
            if not c:
                return out
            out += chr(c)
        addr += 1
    return out


def check(image: dict[int, int]) -> str:
    """Checks the header and the checksum; the version, the length, and
    the flags, for a line of output. The header's words must all be
    there, also one that is 0: the loader reads them from the file's
    first lines, each at its address, and takes no file without them."""
    if image.get(H_MAGIC) != MAGIC:
        raise ImageError("no magic word NBAS at 0x4004")
    for addr in range(BASE, H_RAM + 1):
        if addr not in image:
            raise ImageError(f"no line for the header's word at {addr:04X}")
    length = image.get(H_LENGTH, 0)
    if not H_RAM < BASE + length <= END:
        raise ImageError(f"length {length} out of range")
    if max(image) >= BASE + length:
        raise ImageError(f"a word at {max(image):04X}, past the length {length}")
    if not BASE + 12 <= image.get(H_TEXT, 0) < BASE + length:
        raise ImageError("the version text's address is outside the image")
    if not RAM_MIN <= image.get(H_RAM, 0) <= RAM_MAX:
        raise ImageError(f"the words of BASIC's RAM out of {RAM_MIN} to {RAM_MAX}")
    if checksum_of(image, length):
        raise ImageError("bad checksum")
    v = image.get(H_VERSION, 0)
    iface = image.get(H_IFACE, 0)
    return (f"version {v >> 24}.{v >> 16 & 255}.{v >> 8 & 255}+{v & 255}, "
            f"layout {iface >> 16}, {iface & 0xFFFF} entries, {length} words, "
            f"RAM {image.get(H_RAM, 0)} words, flags {image.get(H_FLAGS, 0)}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_fill = sub.add_parser("fill", help="fill in the header after assembly")
    p_fill.add_argument("input")
    p_fill.add_argument("output")
    p_fill.add_argument("--version", required=True, help="the version, such as V2.3.1")
    p_fill.add_argument("--keep", action="store_true", help='set the flag "keep"')
    p_check = sub.add_parser("check", help="check images")
    p_check.add_argument("files", nargs="+")
    args = parser.parse_args()
    try:
        if args.cmd == "fill":
            image = read_image(args.input)
            fill(image, args.version, args.keep)
            check(image)
            write_image(args.output, image)
        else:
            for path in args.files:
                print(f"{path}: {check(read_image(path))}")
    except (ImageError, OSError, ValueError) as e:
        sys.exit(f"basic_rom.py: {e}")


if __name__ == "__main__":
    main()
