#!/usr/bin/env python3
"""The tools of the monitor's tests of FAT32 that need more than mtools
(Makefile, INTERNALS.md, "The tests"), with the Python standard library
only. Each is a subcommand:

diff BASE IMAGE [--mask-times]
    What the monitor changed on a card: every byte of IMAGE that differs
    from BASE, the image that the test copied, decoded, so that a test
    checks a card exactly but does not depend on the bytes that the
    monitor never wrote. The lines are: the sectors outside the FAT32
    volume, and those of its reserved area, with FSInfo's free count and
    next-free hint by name; the FAT's entries, from the first copy, and
    whether every other copy has the same; every 32-byte entry of a
    directory that changed, as it was and as it is, with all its fields;
    and the data of the files whose sectors changed, as text when short,
    or else as their size and SHA-256, and what follows the size in the
    last sector written. --mask-times shows the times of the 8.3 entries,
    bytes 13 to 15 and 22 to 23, as **, for a test with the clock set and
    --step-time, whose seconds count the steps of the code.

order [--sd0 IMAGE] [--sd1 IMAGE]
    The SD controller's commands of a run, from niceemu -t on stdin: the
    writes to SD_SELECT, SD_LBA, and SD_CSR, as the order of the sector
    writes of fat32.c's header, which no other test sees. Each write is
    named by the geometry of the card of its slot: FSInfo, FAT1+k for
    sector k of the first FAT, FAT2+k, Cn for cluster n, or Cn+k for its
    sector k, and the sector's number elsewhere; a write to slot 1 has
    1: before it. An INIT is "mount N", and the reads are left out.

prog OPS
    The NICE assembly of the program of OPS, a file of fs_* calls, to be
    joined with mon.nasm (OPS below).

words OPS
    The words that the program of OPS logs in a run of each segment.

log OPS RAW
    RAW, niceemu's output for a run of the program of OPS, with the dump
    of its log, which a test makes with -d LOG:WORDS, replaced by the log
    decoded: a line for each call, with its arguments and its result, and
    what a read, an fs_readdir, or an fs_readname wrote.

OPS is a text file of lines, each an operation, its word, then its
arguments, separated by commas; ; starts a comment. seg starts a
segment, which is at 0x8000 + 0x400 * i for the i-th, so that SYS runs
each: it logs the segment's number, then each call's result, and
returns the words logged. An argument is a Python expression: a NAME is
a string literal, a character per word, with + and * for long ones
("n" * 251 + ".txt"); a VAR is 0 to 3, a word that holds a handle, so
that a call on a variable whose open failed passes the error on as the
handle.

    mount SLOT              fs_mount
    open VAR, NAME, MODE    fs_open, its result to VAR too
    read VAR, N             fs_read of up to N bytes
    write VAR, OFF, N       fs_write of N bytes of DATA from OFF
    writew VAR, W, W, ...   fs_write of these words, as they are
    close VAR               fs_close
    readdir VAR             fs_readdir
    readname VAR            fs_readname
    delete NAME             fs_delete
    select SLOT             SD_SELECT written, as a program may
    raw VAR, VALUE          VAR set to VALUE, a handle that is not

DATA is 4096 bytes: the letters A to Z, round again, but every 32nd byte
is an LF. The log is at LOG, and its pointer at LOGP, which the first
segment starts.

Usage: test/fat_tool.py diff|order|prog|words|log ...
"""

import argparse
import ast
import filecmp
import hashlib
import mmap
import re
import struct
import sys
from typing import Dict, Iterator, List, Optional, Tuple, Union

SECTOR = 512
END = 0x0FFFFFF8
LOG = 0x40000
LOGP = 0xBFF0
VARS = 0xBFF8
DATA = 0xC000
NAMES = 0xE000
SEG = 0x400


class Vol:
    """A FAT32 volume of an image: at its start, or in the first partition
    of the MBR of type 0x0B or 0x0C."""

    def __init__(self, path: str, write: bool = False) -> None:
        self.path = path
        with open(path, "r+b" if write else "rb") as f:
            self.img = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_WRITE if write else mmap.ACCESS_READ)
        self.start = 0
        if self.img[82:90] != b"FAT32   ":
            for k in range(4):
                p = self.img[446 + 16 * k:462 + 16 * k]
                if p[4] in (0x0B, 0x0C):
                    self.start = struct.unpack_from("<I", p, 8)[0]
                    break
        b = self.boot = self.sector(0)
        self.spc = b[13]
        self.rsvd, self.nfats = struct.unpack_from("<HB", b, 14)
        total, self.fatsz, _, self.root, self.fsinfo = struct.unpack_from("<IIIIH", b, 32)
        self.fat = self.rsvd
        self.data = self.rsvd + self.nfats * self.fatsz
        self.total = total
        self.top = min((total - self.data) // self.spc + 2, self.fatsz * 128)

    def sector(self, k: int) -> bytes:
        """Sector k of the volume."""
        at = (self.start + k) * SECTOR
        return self.img[at:at + SECTOR]

    def get(self, c: int, copy: int = 0) -> int:
        at = (self.start + self.fat + copy * self.fatsz) * SECTOR + 4 * c
        value: int = struct.unpack_from("<I", self.img, at)[0]
        return value

    def chain(self, c: int) -> List[int]:
        out: List[int] = []
        seen = set()
        while 2 <= c < self.top and c not in seen:
            out.append(c)
            seen.add(c)
            c = self.get(c) & 0x0FFFFFFF
        return out

    # The changes of a card damaged on purpose, for test/fat_image.py

    def put(self, at: int, fmt: str, *v: Union[int, bytes]) -> None:
        """Values packed at the byte at of the volume."""
        struct.pack_into(fmt, self.img, self.start * SECTOR + at, *v)

    def set(self, c: int, v: int) -> None:
        """The FAT entry of cluster c, in every copy."""
        for k in range(self.nfats):
            self.put((self.fat + k * self.fatsz) * SECTOR + 4 * c, "<I", v)

    def entry(self, name: bytes, folder: str = "NICE/") -> Tuple[int, bytes]:
        """The byte offset in the volume of the 8.3 entry name, 11 bytes,
        in folder, and the entry."""
        for path, chain in self.dirs():
            if path == folder:
                for k, e in self.entries(chain):
                    if e[:11] == name:
                        return k * 32, e
        raise KeyError(name)

    def cluster_of(self, k: int) -> Tuple[int, int]:
        """The cluster of data sector k of the volume, and its sector there."""
        return (k - self.data) // self.spc + 2, (k - self.data) % self.spc

    def dirs(self) -> Iterator[Tuple[str, List[int]]]:
        """Each directory, from the root down, with its chain."""
        todo = [("/", self.root)]
        seen = set()
        while todo:
            path, first = todo.pop(0)
            if first in seen:
                continue
            seen.add(first)
            chain = self.chain(first)
            yield path, chain
            for _, e in self.entries(chain):
                if e[0] in (0, 0xE5) or e[11] & 0x3F == 0x0F or e[0] == 0x2E:
                    continue
                if e[11] & 0x10:
                    name = e[:11].decode("latin-1")
                    todo.append(((path if path != "/" else "") + name.rstrip() + "/",
                                 cluster(e)))

    def entries(self, chain: List[int]) -> Iterator[Tuple[int, bytes]]:
        for c in chain:
            for k in range(self.spc):
                s = self.sector(self.data + (c - 2) * self.spc + k)
                for j in range(16):
                    yield (self.data + (c - 2) * self.spc + k) * 16 + j, s[32 * j:32 * j + 32]

    def files(self) -> Iterator[Tuple[str, bytes]]:
        """Each file's 8.3 entry, with its path."""
        for path, chain in self.dirs():
            for _, e in self.entries(chain):
                if e[0] == 0:
                    break
                if e[0] == 0xE5 or e[11] & 0x3F == 0x0F or e[11] & 0x18:
                    continue
                yield path + short(e), e

    def name(self, k: int) -> str:
        """The name of sector k of the volume, for order."""
        if self.fsinfo and k == self.fsinfo:
            return "FSInfo"
        if self.fat <= k < self.data:
            return f"FAT{(k - self.fat) // self.fatsz + 1}+{(k - self.fat) % self.fatsz}"
        if k >= self.data:
            c, s = self.cluster_of(k)
            return f"C{c}" + (f"+{s}" if self.spc > 1 else "")
        return f"sector {k}"


def cluster(e: bytes) -> int:
    hi, lo = struct.unpack_from("<H4xH", e, 20)
    value: int = hi << 16 | lo
    return value


def short(e: bytes) -> str:
    base = e[:8].decode("latin-1").rstrip()
    ext = e[8:11].decode("latin-1").rstrip()
    return base + ("." + ext if ext else "")


def text(b: bytes) -> str:
    """Bytes as a string that shows each of them."""
    out = ""
    for c in b:
        out += chr(c) if 0x20 <= c < 0x7F and c != 0x5C else f"\\x{c:02x}"
    return out


def date(d: int) -> str:
    return f"{1980 + (d >> 9):04d}-{d >> 5 & 15:02d}-{d & 31:02d}"


def time(t: int) -> str:
    return f"{t >> 11:02d}:{t >> 5 & 63:02d}:{2 * (t & 31):02d}"


def entry(e: bytes, mask: bool) -> str:
    """Every field of a directory entry."""
    if e == bytes(32):
        return "zeros"
    if e[11] == 0x0F:
        chars = ""
        for at in (1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30):
            u = struct.unpack_from("<H", e, at)[0]
            chars += chr(u) if 0x20 <= u < 0x7F and u != 0x5C else f"\\u{u:04x}"
        return (f"long {e[0]:02X} \"{chars}\" attr {e[11]:02X} type {e[12]:02X} "
                f"sum {e[13]:02X} cluster {struct.unpack_from('<H', e, 26)[0]:04X}")
    ct, cd, ad, wt, wd = struct.unpack_from("<HHH2xHH", e, 14)
    ctime = "**:**:** +**" if mask else f"{time(ct)} +{e[13]}"
    wtime = "**:**:**" if mask else time(wt)
    return (f"\"{text(e[:11])}\" attr {e[11]:02X} case {e[12]:02X} "
            f"created {date(cd)} {ctime} accessed {date(ad)} "
            f"written {date(wd)} {wtime} cluster {cluster(e)} size {struct.unpack_from('<I', e, 28)[0]}")


def runs(cs: List[int], vals: List[int]) -> Optional[str]:
    """Values of the FAT entries cs, which follow one another, as one: all
    the same, or each the next cluster but the last; None if neither."""
    if all(v == vals[0] for v in vals):
        return f"{vals[0]:08X}"
    if all(v == c + 1 for c, v in zip(cs[:-1], vals[:-1])):
        return f"each the next, the last {vals[-1]:08X}"
    return None


def changed(a: Vol, b: Vol) -> List[int]:
    """The sectors of the image b that differ from a's."""
    out: List[int] = []
    chunk = 1 << 20
    for at in range(0, len(b.img), chunk):
        if a.img[at:at + chunk] != b.img[at:at + chunk]:
            out += [k for k in range(at // SECTOR, min(at + chunk, len(b.img)) // SECTOR)
                    if a.img[k * SECTOR:(k + 1) * SECTOR] != b.img[k * SECTOR:(k + 1) * SECTOR]]
    return out


def diff(base: str, image: str, mask: bool) -> None:
    if filecmp.cmp(base, image, shallow=False):
        print(f"The card as {base.split('/')[-1]} was")
        return
    a, b = Vol(base), Vol(image)
    if len(a.img) != len(b.img) or (a.start, a.fat, a.data, a.spc) != (b.start, b.fat, b.data, b.spc):
        sys.exit(f"{image}: not the size or the geometry of {base}")
    print(f"What the card holds that {base.split('/')[-1]} did not:")
    sectors = changed(a, b)
    vol = [k - b.start for k in sectors if b.start <= k < b.start + b.total]
    outside = [k for k in sectors if not b.start <= k < b.start + b.total]
    print("Sectors changed outside the volume: " + (" ".join(map(str, outside)) or "none"))
    for k in [k for k in vol if k < b.fat]:
        name = "FSInfo" if k == b.fsinfo else f"reserved sector {k}"
        old, new = a.sector(k), b.sector(k)
        for at in range(0, SECTOR, 4):
            if old[at:at + 4] != new[at:at + 4]:
                what = {488: "free count", 492: "next free"}.get(at, f"bytes {at}-{at + 3}")
                print(f"{name} {what}: {struct.unpack_from('<I', old, at)[0]:08X} -> "
                      f"{struct.unpack_from('<I', new, at)[0]:08X}")
    # The FAT's entries, a run of them to a line, in the first copy
    rows: List[List[Tuple[int, int, int]]] = [[] for _ in range(b.nfats)]
    for k in [k for k in vol if b.fat <= k < b.data]:
        copy, s = divmod(k - b.fat, b.fatsz)
        for j in range(128):
            c = s * 128 + j
            was, now = a.get(c, copy), b.get(c, copy)
            if was != now:
                rows[copy].append((c, was, now))
    print(f"FAT entries changed: {len(rows[0])}")
    r = rows[0]
    i = 0
    while i < len(r):
        j = i
        while (j + 1 < len(r) and r[j + 1][0] == r[j][0] + 1
               and runs([x[0] for x in r[i:j + 2]], [x[1] for x in r[i:j + 2]])
               and runs([x[0] for x in r[i:j + 2]], [x[2] for x in r[i:j + 2]])):
            j += 1
        cs = [x[0] for x in r[i:j + 1]]
        print(f"  {r[i][0]}" + (f"-{r[j][0]}" if j > i else "") +
              f": {runs(cs, [x[1] for x in r[i:j + 1]])} -> {runs(cs, [x[2] for x in r[i:j + 1]])}")
        i = j + 1
    for copy in range(1, b.nfats):
        if rows[copy] == rows[0]:
            print(f"FAT {copy + 1}: the same changes")
        else:
            print(f"FAT {copy + 1}: other changes")
            for c, was, now in rows[copy]:
                print(f"  {c}: {was:08X} -> {now:08X}")
    # The directories' entries, in the directories of either image
    dirsecs: Dict[int, str] = {}
    for v in (b, a):
        for path, chain in v.dirs():
            for c in chain:
                for k in range(v.spc):
                    dirsecs.setdefault(v.data + (c - 2) * v.spc + k, path)
    olddirs = set()
    for path, chain in a.dirs():
        olddirs |= {a.data + (c - 2) * a.spc + k for c in chain for k in range(a.spc)}
    data = [k for k in vol if k >= b.data]
    for k in [k for k in data if k in dirsecs]:
        old, new = a.sector(k), b.sector(k)
        c, s = b.cluster_of(k)
        where = f"{dirsecs[k].rstrip('/') or '/'} C{c}" + (f"+{s}" if b.spc > 1 else "")
        if k not in olddirs:
            # a sector that no directory had: its entries as they are
            print(f"{where}, new to the directory:")
            zeros = 0
            for j in range(16):
                e = new[32 * j:32 * j + 32]
                if e == bytes(32):
                    zeros += 1
                else:
                    print(f"  entry {j}: " + entry(e, mask))
            print(f"  the other {zeros} entries zeros")
            continue
        for j in range(16):
            if old[32 * j:32 * j + 32] != new[32 * j:32 * j + 32]:
                print(f"{where} entry {j}:")
                print("  was " + entry(old[32 * j:32 * j + 32], mask))
                print("  now " + entry(new[32 * j:32 * j + 32], mask))
    # The files' data
    owner: Dict[int, Tuple[str, int, bytes]] = {}
    for path, e in b.files():
        for n, c in enumerate(b.chain(cluster(e))):
            owner[c] = (path, n, e)
    shown = set()
    for k in [k for k in data if k not in dirsecs]:
        c, s = b.cluster_of(k)
        if c not in owner:
            print(f"C{c}" + (f"+{s}" if b.spc > 1 else "") +
                  f", of no file: {sum(1 for x in b.sector(k) if x)} bytes not 0, "
                  f"SHA-256 {hashlib.sha256(b.sector(k)).hexdigest()[:16]}")
            continue
        path, n, e = owner[c]
        size = struct.unpack_from("<I", e, 28)[0]
        at = (n * b.spc + s) * SECTOR
        if path not in shown:
            shown.add(path)
            body = b"".join(b.sector(b.data + (x - 2) * b.spc + y)
                            for x in b.chain(cluster(e)) for y in range(b.spc))[:size]
            if size <= 64:
                print(f"{path}: {size} bytes, \"{text(body)}\"")
            else:
                print(f"{path}: {size} bytes, SHA-256 {hashlib.sha256(body).hexdigest()[:16]}")
        if at + SECTOR > size:
            rest = b.sector(k)[max(0, size - at):]
            what = "zeros" if rest == bytes(len(rest)) else f"\"{text(rest)}\""
            print(f"{path}: its sector {at // SECTOR} past the size: {len(rest)} bytes, {what}")


def order(images: List[Optional[Vol]]) -> None:
    pat = re.compile(r"\[ffffffa([014])\]=([0-9a-f]{8})")
    lba = sel = 0
    out: List[str] = []
    for line in sys.stdin.buffer:
        for m in pat.finditer(line.decode("latin-1")):
            reg, val = m.group(1), int(m.group(2), 16)
            if reg == "1":
                lba = val
            elif reg == "4":
                sel = val
            elif val == 0:
                out.append(f"mount {sel}")
            elif val == 2:
                v = images[sel] if sel < len(images) else None
                name = v.name(lba - v.start) if v and lba >= v.start else f"sector {lba}"
                out.append(("1:" if sel else "") + name)
    print(f"Sector writes, {sum(1 for w in out if not w.startswith('mount'))}:")
    row = ""
    i = 0
    while i < len(out):
        j = i
        while j + 1 < len(out) and out[j + 1] == out[i]:
            j += 1
        w = out[i] + (f" x{j - i + 1}" if j > i else "")
        if len(row) + len(w) + 2 > 72:
            print(row + ",")
            row = ""
        row += (", " if row else "") + w
        i = j + 1
    if row:
        print(row)


# The programs of OPS

Op = Tuple[str, List[Union[int, List[int]]]]


def value(node: ast.expr) -> Union[int, str]:
    if isinstance(node, ast.Constant) and isinstance(node.value, (int, str)):
        return node.value
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.USub):
        v = value(node.operand)
        if isinstance(v, int):
            return -v
    if isinstance(node, ast.BinOp):
        x, y = value(node.left), value(node.right)
        if isinstance(node.op, ast.Add) and isinstance(x, str) and isinstance(y, str):
            return x + y
        if isinstance(node.op, ast.Mult) and isinstance(x, str) and isinstance(y, int):
            return x * y
    raise SyntaxError(ast.dump(node))


def ops(path: str) -> List[List[Op]]:
    """The segments of the file OPS."""
    segs: List[List[Op]] = []
    with open(path) as f:
        for n, line in enumerate(f, 1):
            # ; outside a string starts the comment
            quote = escape = False
            for k, c in enumerate(line):
                if escape:
                    escape = False
                elif c == "\\":
                    escape = True
                elif c == '"':
                    quote = not quote
                elif c == ";" and not quote:
                    line = line[:k]
                    break
            word, _, rest = line.strip().partition(" ")
            if not word:
                continue
            if word == "seg":
                segs.append([])
                continue
            try:
                args: List[Union[int, List[int]]] = []
                tree = ast.parse("(" + rest + ",)" if rest.strip() else "()", mode="eval")
                assert isinstance(tree.body, ast.Tuple)
                for node in tree.body.elts:
                    v = value(node)
                    args.append([ord(c) for c in v] if isinstance(v, str) else v)
                if word == "writew":
                    args = [args[0], [x for x in args[1:] if isinstance(x, int)]]
            except (SyntaxError, ValueError) as e:
                sys.exit(f"{path}:{n}: {e}")
            if not segs:
                sys.exit(f"{path}:{n}: no seg before the first operation")
            segs[-1].append((word, args))
    return segs


def program(segs: List[List[Op]]) -> str:
    names: List[List[int]] = []

    def label(name: Union[int, List[int]]) -> str:
        assert isinstance(name, list)
        if name not in names:
            names.append(name)
        return f"FT_NAME{names.index(name)}"

    out: List[str] = []

    def asm(*lines: str) -> None:
        out.extend("                " + x for x in lines)

    for i, seg in enumerate(segs):
        out.append(f"                .ORG    0x{0x8000 + i * SEG:X}")
        first = len(out)
        asm(f"MOVE    R7, @0x{LOGP:X}", "TST     R7")
        out.append(f"        ?Z      MOVE    R7, 0x{LOG:X}")
        asm(f"MOVE    @R7++, 0x5E600000+{i}")
        for word, a in seg:
            v = [x if isinstance(x, int) else 0 for x in a]
            var = f"@0x{VARS + v[0]:X}" if a and isinstance(a[0], int) else ""
            if word == "mount":
                asm(f"MOVE    R1, {v[0]}", "CALL    _mon_fs_mount", "MOVE    @R7++, R1")
            elif word == "open":
                asm(f"MOVE    R1, {label(a[1])}", f"MOVE    R2, {v[2] & 0xFFFFFFFF}",
                    "CALL    _mon_fs_open", "MOVE    @R7++, R1", f"MOVE    {var}, R1")
            elif word == "read":
                asm(f"MOVE    R1, {var}", "ADD     R2, R7, 1", f"MOVE    R3, {v[1]}",
                    "CALL    _mon_fs_read", "MOVE    @R7, R1", f"ADD     R7, R7, {v[1] + 1}")
            elif word == "write":
                asm(f"MOVE    R1, {var}", f"MOVE    R2, 0x{DATA + v[1]:X}", f"MOVE    R3, {v[2]}",
                    "CALL    _mon_fs_write", "MOVE    @R7++, R1")
            elif word == "writew":
                words = a[1]
                assert isinstance(words, list)
                asm(f"MOVE    R1, {var}", f"MOVE    R2, {label(words)}", f"MOVE    R3, {len(words)}",
                    "CALL    _mon_fs_write", "MOVE    @R7++, R1")
            elif word == "close":
                asm(f"MOVE    R1, {var}", "CALL    _mon_fs_close", "MOVE    @R7++, R1")
            elif word == "readdir":
                asm(f"MOVE    R1, {var}", "ADD     R2, R7, 1", "CALL    _mon_fs_readdir",
                    "MOVE    @R7, R1", "ADD     R7, R7, 5")
            elif word == "readname":
                asm(f"MOVE    R1, {var}", "ADD     R2, R7, 1", "ADD     R3, R7, 5",
                    "CALL    _mon_fs_readname", "MOVE    @R7, R1", "ADD     R7, R7, 261")
            elif word == "delete":
                asm(f"MOVE    R1, {label(a[0])}", "CALL    _mon_fs_delete", "MOVE    @R7++, R1")
            elif word == "select":
                asm(f"MOVE    @0xFFFFFFA4, {v[0]}", "MOVE    @R7++, 0")
            elif word == "raw":
                asm(f"MOVE    {var}, {v[1] & 0xFFFFFFFF}")
            else:
                sys.exit(f"no operation {word}")
        asm(f"MOVE    @0x{LOGP:X}, R7", f"SUB     R1, R7, 0x{LOG:X}", "RET")
        # an instruction takes 3 words at most
        if 3 * (len(out) - first) >= SEG:
            sys.exit(f"segment {i} is too long")
    out.append(f"                .ORG    0x{DATA:X}")
    data = [0x0A if k % 32 == 31 else 0x41 + k % 26 for k in range(4096)]
    for j in range(0, len(data), 16):
        asm(".DAT    " + ", ".join(f"0x{x:02X}" for x in data[j:j + 16]))
    out.append(f"                .ORG    0x{NAMES:X}")
    for n, name in enumerate(names):
        out.append(f"FT_NAME{n}")
        for j in range(0, len(name) + 1, 16):
            asm(".DAT    " + ", ".join(f"0x{x & 0xFFFFFFFF:X}" for x in (name + [0])[j:j + 16]))
    return "\n".join(out) + "\n"


def words(segs: List[List[Op]]) -> int:
    n = 0
    for seg in segs:
        n += 1
        for word, a in seg:
            if word == "read":
                assert isinstance(a[1], int)
                n += a[1] + 1
            elif word != "raw":
                n += {"readdir": 5, "readname": 261}.get(word, 1)
    return n


def show_name(name: Union[int, List[int]]) -> str:
    assert isinstance(name, list)
    s = "".join(chr(c) if 0x20 <= c < 0x7F and c != 0x5C else f"\\u{c:04x}" for c in name)
    return f"\"{s}\"" if len(s) <= 40 else f"\"{s[:12]}...\" ({len(name)} characters)"


def signed(w: int) -> int:
    return w - (1 << 32) if w >= 1 << 31 else w


def log(segs: List[List[Op]], raw: str) -> None:
    dump = re.compile(r"^([0-9A-Fa-f]{8}):?((?: [0-9A-Fa-f]{8})+)$")
    w: List[int] = []
    for line in open(raw, encoding="latin-1"):
        m = dump.match(line.rstrip("\n"))
        if m and LOG <= int(m.group(1), 16) < LOG + 0x100000:
            w += [int(x, 16) for x in m.group(2).split()]
        else:
            sys.stdout.write(line)
    print("The calls:")
    i = 0
    while i < len(w) and w[i] & 0xFFFFFF00 == 0x5E600000:
        seg = segs[w[i] & 0xFF]
        print(f"segment {w[i] & 0xFF}")
        i += 1
        for word, a in seg:
            if word == "raw":
                continue
            r = signed(w[i])
            args = " ".join(show_name(x) if isinstance(x, list) and word != "writew"
                            else ",".join(f"{y:X}" for y in x) if isinstance(x, list)
                            else str(x) for x in a)
            more = ""
            if word == "read" and r > 0:
                b = bytes(x & 0xFF for x in w[i + 1:i + 1 + r])
                more = (f" \"{text(b)}\"" if r <= 48 else
                        f" \"{text(b[:16])}...{text(b[-16:])}\" SHA-256 {hashlib.sha256(b).hexdigest()[:16]}")
                if any(x > 0xFF for x in w[i + 1:i + 1 + r]):
                    more += " (a word above 0xFF)"
            elif word in ("readdir", "readname") and r == 1:
                e = b"".join(struct.pack("<I", x) for x in w[i + 1:i + 4])
                more = f" \"{text(e[:11])}\" attr {e[11]:02X} size {w[i + 4]}"
                if word == "readname":
                    nm: List[int] = []
                    for x in w[i + 5:i + 261]:
                        if x == 0:
                            break
                        nm.append(x)
                    more += " name " + show_name(nm)
            print(f"  {word} {args} -> {r}{more}")
            if word == "read" and isinstance(a[1], int):
                i += a[1] + 1
            else:
                i += {"readdir": 5, "readname": 261}.get(word, 1)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("diff")
    p.add_argument("base")
    p.add_argument("image")
    p.add_argument("--mask-times", action="store_true")
    p = sub.add_parser("order")
    p.add_argument("--sd0")
    p.add_argument("--sd1")
    for name in ("prog", "words", "log"):
        p = sub.add_parser(name)
        p.add_argument("ops")
        if name == "log":
            p.add_argument("raw")
    args = parser.parse_args()
    if args.cmd == "diff":
        diff(args.base, args.image, args.mask_times)
    elif args.cmd == "order":
        order([Vol(x) if x else None for x in (args.sd0, args.sd1)])
    elif args.cmd == "prog":
        sys.stdout.write(program(ops(args.ops)))
    elif args.cmd == "words":
        print(words(ops(args.ops)))
    else:
        log(ops(args.ops), args.raw)


if __name__ == "__main__":
    main()
