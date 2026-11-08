#!/usr/bin/env python3
"""The files on the board's SD card, over the debug link, with no PC slot.

The host reaches the card through the SD controller's registers at
FFFFFFA0-AF (nice_cpu's SYSTEM.md §5), which the link reaches while the
core is held, paused, or halted, and reads and writes its FAT32 file
system itself, as the monitor's monitor/fat32.c does: sector 0 as a
FAT32 boot sector, or the first partition of type 0x0B or 0x0C of an
MBR, and in it only the folder NICE, the monitor's (#91), or the one
that --folder names:

    tools/sdcard.py --eth 192.168.1.65 ls
    tools/sdcard.py --eth 192.168.1.65 get HELLO.BIN [DEST]
    tools/sdcard.py --eth 192.168.1.65 put prog.bas [NAME]
    tools/sdcard.py --eth 192.168.1.65 del NAME

ls prints the rows of the monitor's dir, with the long name, where a file
has one, after its row. get takes the 8.3 name or the long name, in
either case, and writes the file to DEST, by default the name in the
current directory, or with DEST - to stdout. put writes the host's file
SRC, or stdin for -, as the file NAME, by default SRC's own name, which
must be an 8.3 name: it makes the file, or truncates it when it is
there. del deletes a file, by either name, with its long name.

The writes keep to fat32.c's order, in which a reset at any point leaves
the card no worse than with lost clusters, which fsck.fat frees: FSInfo's
free count set to unknown before the first change of the FAT, a new
cluster marked as the end of its chain in every FAT before the one
before it is linked to it, a truncated file's entry emptied before its
clusters are freed, a new file's first cluster and size put into its
entry last, and a deleted file's long-name entries marked before its
entry. No sector outside the partition is written, nor one below its
first FAT but FSInfo. The date and time of a new entry are the host's.
Long names are not written, as the monitor writes none.

The core: for ls and get, a running one is paused, and goes on after
them. While it is paused, by the tool or before, the tool keeps to the
rules of SYSTEM.md §5 for the card of a paused program: it waits for the
program's command to end, uses only the program's slot, which must be
ready, does no Init, and restores SD_CHUNK, SD_LBA, and the buffer
before the program goes on. SD_ERROR and the error bit are the tool's
afterwards. While the core is held or has halted, it may do anything:
it selects the slot of --slot, or slot 0, or slot 1 when slot 0 has no
card, as the monitor's first mount does, and starts the card with Init
when it is not ready.

With --hold, ls and get hold a running or paused core too, as put and
del do, and start it again from reset afterwards, so that they reach
any slot, as while the core is held, whatever the program had: the
program is lost. put and del hold a running or paused core first, and
start it again from reset after the write, as a program such as the monitor keeps a sector
of the FAT and its mount between commands, which the write makes stale.
A program in the middle of a write of its own loses it, as at a reset,
with lost clusters at worst. A held core stays held.

The tool exits with status 1 and a message on an error, as the monitor's
"File error N, ..." for one of the file system. Only the Python standard
library is used, so this runs on Linux and macOS.

Usage: tools/sdcard.py (--eth HOST[:PORT] | --port DEVICE [--baud 230400]
                       | --tcp [HOST:]PORT | --cosim PORT)
                       [--slot N] [--folder NAME] [--hold]
                       (ls | get NAME [DEST] | put SRC [NAME] | del NAME)
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from dataclasses import dataclass, field
from types import TracebackType
from typing import Callable, Iterator

from boardlink import (CONTROL, HALTED, HOLD, PAUSE, RAM, Link, LinkError,
                       add_arguments, open_link)

# The SD card controller's registers (nice_cpu's SYSTEM.md §5)
SD_CSR, SD_LBA, SD_CHUNK, SD_ERROR, SD_SELECT, SD_LAST, SD_SLOTS = \
    range(0xFFFFFFA0, 0xFFFFFFA7)
SD_BUF = 0xFFFFFFA8
# The bits of SD_CSR
BUSY, ERROR, PRESENT, READY, CHANGED, PROTECTED = 1, 2, 4, 8, 16, 32
# The commands
INIT, READ, WRITE = 0, 1, 2
# How long a command may keep busy at 1: an Init takes up to hundreds of
# milliseconds, a Read about one, and a Write may take longer
INIT_WAIT = 3.0
READ_WAIT = 1.0
WRITE_WAIT = 2.0
# How long a pause waits for the p, x, or h that it brings
PAUSE_WAIT = 2.0

# The controller's errors in SD_ERROR, and the file system's of
# monitor/fat32.c, with the monitor's texts (monitor/monitor.nasm, E_FS*)
SD_ERRORS = {
    1: "no card",
    2: "the card is not ready",
    3: "timeout",
    4: "CRC error",
    5: "the card reported an error",
    6: "write-protected",
    7: "out of range",
    8: "Init failed",
}
FS_ERRORS = {
    16: "no FAT32 file system",
    17: "FAT12, which is not supported",
    18: "FAT16, which is not supported",
    19: "exFAT, which is not supported",
    20: "not an 8.3 name",
    21: "no such file",
    22: "a directory",
    26: "the FAT is damaged",
    27: "no such slot",
    29: "no folder {folder} on the card",
    30: "the card or the folder is full",
    32: "the file is read-only",
}
E_NOFS, E_FAT12, E_FAT16, E_EXFAT, E_NAME = 16, 17, 18, 19, 20
E_NOFILE, E_ISDIR, E_BADFAT, E_SLOT, E_NOFOLDER = 21, 22, 26, 27, 29
E_FULL, E_RDONLY = 30, 32

# The monitor's folder on the card unless the build sets another
FOLDER = "NICE"
# The FAT's entry at the end of a chain, and those from which an entry
# ends one
EOC = 0x0FFFFFFF
END = 0x0FFFFFF8
# The bytes of a directory at most, as fat32.c's DIR_MAX
DIR_MAX = 65536 * 32
# The characters that an 8.3 name may not have, beside those up to blank
# and from 0x7F (fat32.c's name83)
NOT_83 = set('"*+,./:;<=>?[\\]|')


class SdError(Exception):
    """A command of the SD controller failed, or the card cannot be used
    as the core's state is."""


class FileError(Exception):
    """An error of the file system, with the number that the monitor's
    fat32.c gives it, negated."""

    def __init__(self, code: int, folder: str = FOLDER) -> None:
        self.code = code
        text = FS_ERRORS.get(code, "unknown").format(folder=folder)
        super().__init__(f"File error {code}, {text}")


def sd_command(link: Link, cmd: int,
               timeout: float) -> tuple[int, int] | None:
    """Starts an SD card command, and waits for busy to fall: the status
    and the error after it, or None after the timeout."""
    link.write(SD_CSR, [cmd])
    return sd_wait(link, timeout)


def sd_wait(link: Link, timeout: float) -> tuple[int, int] | None:
    """Waits for busy to be 0: the status and SD_ERROR then, or None after
    the timeout."""
    end = time.monotonic() + timeout
    while True:
        csr = link.read_word(SD_CSR)
        if csr & BUSY == 0:
            return csr, link.read_word(SD_ERROR)
        if time.monotonic() > end:
            return None


def read_buffer(link: Link) -> list[int]:
    """The 128 words of the buffer, read a chunk at a time. SD_CHUNK is
    left at 15."""
    words: list[int] = []
    for c in range(16):
        link.write(SD_CHUNK, [c])
        words += link.read(SD_BUF, 8)
    return words


def write_buffer(link: Link, words: list[int]) -> None:
    """Writes the 128 words of the buffer, a chunk at a time. SD_CHUNK is
    left at 15."""
    for c in range(16):
        link.write(SD_CHUNK, [c])
        link.write(SD_BUF, words[8 * c:8 * c + 8])


def to_bytes(words: list[int]) -> bytes:
    """The bytes of a sector from the words of the buffer, 4 to a word,
    little-endian."""
    return b"".join(w.to_bytes(4, "little") for w in words)


def to_words(data: bytes) -> list[int]:
    """The words of the buffer for the 512 bytes of a sector."""
    return [int.from_bytes(data[i:i + 4], "little") for i in range(0, 512, 4)]


def sd_said(got: tuple[int, int] | None) -> str:
    """What sd_command returned, for a message."""
    if got is None:
        return "busy too long"
    return f"error {got[1]}, {SD_ERRORS.get(got[1], 'unknown')}"


class Card:
    """The card in a slot of the board, over the link, for a with block.
    For reads, it pauses a running core at the start, and at the end
    restores what the program had and lets the core go on; for writes,
    and for reads with hold, it holds a running or paused core, and starts
    it again at the end, as the header says."""

    def __init__(self, link: Link, slot: int | None = None,
                 write: bool = False, hold: bool = False) -> None:
        self.link = link
        self.want = slot
        self.writes = write
        self.hold = hold or write
        self.slot = 0
        self.last = 0
        self.ctl = 0
        self.paused_here = False
        self.restart = False
        self.saved: tuple[int, int, list[int]] | None = None
        self.cache: dict[int, bytes] = {}

    def __enter__(self) -> Card:
        try:
            self._start()
        except BaseException:
            self._end()
            raise
        return self

    def __exit__(self, kind: type[BaseException] | None,
                 value: BaseException | None,
                 trace: TracebackType | None) -> None:
        self._end()

    def _pause(self) -> None:
        """Pauses the running core, and waits for the notice."""
        link = self.link
        pauses, halts = link.pauses, len(link.halts)
        link.control(PAUSE | (self.ctl & RAM))
        self.paused_here = True
        end = time.monotonic() + PAUSE_WAIT
        while link.pauses == pauses and len(link.halts) == halts:
            if time.monotonic() >= end:
                raise SdError("the core did not pause")
            link.poll(end - time.monotonic())

    def _start(self) -> None:
        link = self.link
        self.ctl = link.read_word(CONTROL)
        if self.hold and not self.ctl & (HOLD | HALTED):
            # A running or paused program's state of the card goes stale,
            # or the tool takes the card as it wants it
            link.control(HOLD | (self.ctl & RAM))
            self.restart = True
        elif not self.ctl & (HOLD | HALTED | PAUSE):
            self._pause()
        ctl = link.read_word(CONTROL)
        free = bool(ctl & (HOLD | HALTED))
        if sd_wait(link, INIT_WAIT) is None:
            raise SdError("the SD controller stays busy")
        slots = link.read_word(SD_SLOTS)
        if not free:
            # A paused program's card: its slot, no Init, and what it
            # has in the registers kept for the end
            self.slot = link.read_word(SD_SELECT)
            if self.want is not None and self.want != self.slot:
                raise SdError(
                    f"the paused program uses slot {self.slot}; hold the "
                    f"core to read the card in slot {self.want}, or give "
                    "--hold, which starts it again from reset")
            # SD_CHUNK before the buffer, whose read moves it
            lba = link.read_word(SD_LBA)
            chunk = link.read_word(SD_CHUNK)
            self.saved = (lba, chunk, read_buffer(link))
            csr = link.read_word(SD_CSR)
            if not csr & PRESENT:
                raise SdError(
                    f"the paused program uses slot {self.slot}, which has "
                    "no card; type dir SLOT on the board first, or give "
                    "--hold, which starts the core again from reset")
            if not csr & READY or csr & CHANGED:
                raise SdError(
                    f"the card in slot {self.slot} is not started up, and "
                    "the tool does no Init while a program is paused; type "
                    "dir on the board first, or give --hold, which starts "
                    "the core again from reset")
        else:
            slot = self.want
            if slot is None:
                link.write(SD_SELECT, [0])
                slot = 0 if link.read_word(SD_CSR) & PRESENT or slots < 2 \
                    else 1
            if slot >= slots:
                raise FileError(E_SLOT)
            self.slot = slot
            link.write(SD_SELECT, [slot])
            csr = link.read_word(SD_CSR)
            if not csr & PRESENT:
                raise SdError(f"slot {slot} has no card")
            if not csr & READY or csr & CHANGED:
                got = sd_command(link, INIT, INIT_WAIT)
                if got is None or got[1]:
                    raise SdError(f"Init of the card in slot {slot}: "
                                  f"{sd_said(got)}")
        self.last = link.read_word(SD_LAST)

    def _end(self) -> None:
        link = self.link
        try:
            if self.saved is not None:
                lba, chunk, words = self.saved
                if sd_wait(link, READ_WAIT) is not None:
                    write_buffer(link, words)
                    link.write(SD_LBA, [lba])
                link.write(SD_CHUNK, [chunk])
                self.saved = None
        finally:
            if self.paused_here:
                self.paused_here = False
                link.control(self.ctl & RAM)
            if self.restart:
                # A Write that runs ends before the start, which resets
                # the controller (SYSTEM.md §5)
                self.restart = False
                sd_wait(link, WRITE_WAIT)
                link.control(self.ctl & RAM)
                print("sdcard.py: the core was started again from reset",
                      file=sys.stderr)

    def read(self, lba: int) -> bytes:
        """The 512 bytes of the sector lba."""
        got = self.cache.get(lba)
        if got is not None:
            return got
        if lba > self.last:
            raise SdError(f"sector {lba:#x} is after the card's last, "
                          f"{self.last:#x}")
        self.link.write(SD_LBA, [lba])
        done = sd_command(self.link, READ, READ_WAIT)
        if done is None or done[1]:
            raise SdError(f"Read of sector {lba:#x} in slot {self.slot}: "
                          f"{sd_said(done)}")
        data = to_bytes(read_buffer(self.link))
        self.cache[lba] = data
        return data

    def write(self, lba: int, data: bytes) -> None:
        """Writes the 512 bytes data to the sector lba."""
        if not self.writes:
            raise SdError("a write in a session for reads")
        if lba > self.last:
            raise SdError(f"sector {lba:#x} is after the card's last, "
                          f"{self.last:#x}")
        self.cache.pop(lba, None)
        write_buffer(self.link, to_words(data))
        self.link.write(SD_LBA, [lba])
        done = sd_command(self.link, WRITE, WRITE_WAIT)
        if done is None or done[1]:
            raise SdError(f"Write of sector {lba:#x} in slot {self.slot}: "
                          f"{sd_said(done)}")
        self.cache[lba] = bytes(data)


def u16(b: bytes | bytearray, at: int) -> int:
    return int.from_bytes(b[at:at + 2], "little")


def u32(b: bytes | bytearray, at: int) -> int:
    return int.from_bytes(b[at:at + 4], "little")


def put16(b: bytearray, at: int, v: int) -> None:
    b[at:at + 2] = (v & 0xFFFF).to_bytes(2, "little")


def put32(b: bytearray, at: int, v: int) -> None:
    b[at:at + 4] = (v & 0xFFFFFFFF).to_bytes(4, "little")


def boot_kind(b: bytes) -> int:
    """What the sector b is, as fat32.c's kind() says: 0 for a FAT32 boot
    sector, a FileError's code for another file system, and 1 for no boot
    sector. The type is told by the count of clusters."""
    if b[3:11] == b"EXFAT   ":
        return E_EXFAT
    spc, rsvd, nfats = b[13], u16(b, 14), b[16]
    if (b[0] not in (0xEB, 0xE9) or u16(b, 11) != 512 or spc == 0
            or spc & (spc - 1) or rsvd == 0 or nfats == 0):
        return 1
    rootsecs = (u16(b, 17) * 32 + 511) // 512
    fatsz = u16(b, 22) or u32(b, 36)
    total = u16(b, 19) or u32(b, 32)
    meta = rsvd + nfats * fatsz + rootsecs
    if total <= meta:
        return E_NOFS
    clusters = (total - meta) // spc
    if clusters < 4085:
        return E_FAT12
    if clusters < 65525:
        return E_FAT16
    if u16(b, 22) or u16(b, 17):
        return E_NOFS
    return 0


def name83(name: str) -> bytes:
    """The 11 bytes of the 8.3 name name, in upper case, as fat32.c's
    name83 makes them: a base of 1 to 8 characters, and an extension of
    1 to 3 after a dot, if any."""
    base, dot, ext = name.partition(".")
    if not base or dot and not ext or len(base) > 8 or len(ext) > 3:
        raise FileError(E_NAME)
    for c in base + ext:
        if c <= " " or c >= "\x7f" or c in NOT_83:
            raise FileError(E_NAME)
    return (base.upper().ljust(8) + ext.upper().ljust(3)).encode("ascii")


def fat_stamp(t: float) -> tuple[int, int]:
    """FAT's date and time of the local time t."""
    lt = time.localtime(t)
    date = (max(lt.tm_year - 1980, 0) << 9) | (lt.tm_mon << 5) | lt.tm_mday
    return date, (lt.tm_hour << 11) | (lt.tm_min << 5) | (lt.tm_sec // 2)


@dataclass
class Entry:
    """A file or a directory of a directory: its 8.3 name as the 11 bytes
    of the entry, with 0x05 as 0xE5, and its long name, or None, and
    where the entry is, a sector and the offset in it, with its long-name
    entries before it."""
    raw: bytes
    long: str | None
    attr: int
    first: int
    size: int
    lba: int = 0
    off: int = 0
    lfn: list[tuple[int, int]] = field(default_factory=list)

    @property
    def is_dir(self) -> bool:
        return bool(self.attr & 0x10)

    @property
    def short(self) -> str:
        """The 8.3 name as a name: HELLO.BIN."""
        base = self.raw[:8].decode("latin-1").rstrip()
        ext = self.raw[8:].decode("latin-1").rstrip()
        return base + "." + ext if ext else base

    def row(self) -> str:
        """The row of the monitor's dir: the 8.3 name as its 11 bytes,
        with a blank between the two parts, and the size or <DIR>."""
        text = self.raw[:8].decode("latin-1") + " " + \
            self.raw[8:].decode("latin-1")
        if self.is_dir:
            return text + "  <DIR>"
        return f"{text}{self.size:12d}"


def lfn_sum(raw: bytes) -> int:
    """The checksum of an 8.3 name that its long-name entries carry."""
    s = 0
    for c in raw:
        s = (((s & 1) << 7) + (s >> 1) + c) & 0xFF
    return s


def lfn_text(parts: list[bytes], raw: bytes) -> str | None:
    """The long name of the long-name entries before an entry, in the
    order on the card, or None when they are not those of raw: a wrong
    checksum, or numbers out of sequence."""
    if not parts:
        return None
    n = len(parts)
    if parts[0][0] != 0x40 | n:
        return None
    text = b""
    for i, p in enumerate(reversed(parts)):
        if p[0] & 0x1F != i + 1 or p[13] != lfn_sum(raw):
            return None
        text += p[1:11] + p[14:26] + p[28:32]
    name = text.decode("utf-16-le", errors="replace")
    return name.split("\0", 1)[0]


class Volume:
    """A FAT32 file system on a card, read with read(lba) and written
    with write(lba, data), if given, mounted as fat32.c mounts one, with
    its folder, and only that folder."""

    def __init__(self, read: Callable[[int], bytes],
                 folder: str = FOLDER,
                 write: Callable[[int, bytes], None] | None = None,
                 now: float | None = None) -> None:
        self.read = read
        self._write = write
        self.folder = folder
        self.now = time.time() if now is None else now
        b = read(0)
        base = 0
        k = boot_kind(b)
        if k == 1:
            if b[510:512] != b"\x55\xaa":
                raise FileError(E_NOFS)
            other = 0
            for i in range(4):
                p = b[446 + 16 * i:462 + 16 * i]
                if p[4] in (0x0B, 0x0C):
                    base = u32(p, 8)
                    break
                if p[4] and not other:
                    other = u32(p, 8)
            if not base and not other:
                raise FileError(E_NOFS)
            b = read(base or other)
            k = boot_kind(b)
            if not base and not k:
                k = E_NOFS
        if k:
            raise FileError(E_NOFS if k == 1 else k)
        self.spc = b[13]
        self.fat = base + u16(b, 14)
        self.nfats = b[16]
        self.fatsz = u32(b, 36)
        self.data = self.fat + self.nfats * self.fatsz
        self.end = base + u32(b, 32)
        self.top = min((self.end - self.data) // self.spc + 2,
                       self.fatsz * 128)
        fsi = u16(b, 48)
        self.fsinfo = base + fsi if 1 <= fsi < u16(b, 14) else 0
        # The cluster to search for a free one from, 0 for FSInfo's;
        # whether FSInfo's free count is unknown, and whether the FAT has
        # changed since FSInfo was written (fat32.c's vol)
        self.hint = 0
        self.unknown = False
        self.changed = False
        root = u32(b, 44)
        if root < 2 or root >= self.top:
            raise FileError(E_BADFAT)
        name = folder.upper().ljust(11).encode("latin-1")
        found = [e for e in self.entries(root) if e.raw == name]
        if not found or not found[0].is_dir:
            raise FileError(E_NOFOLDER, folder)
        self.dir = found[0].first
        if self.dir < 2 or self.dir >= self.top:
            raise FileError(E_BADFAT)

    # Reading

    def next(self, clus: int) -> int:
        """The FAT's entry of cluster clus."""
        return u32(self.read(self.fat + (clus >> 7)), 4 * (clus & 127)) \
            & 0x0FFFFFFF

    def clusters(self, first: int) -> Iterator[int]:
        """The clusters of the chain from first, which must stay inside the
        volume and end."""
        clus, seen = first, 0
        while clus < END:
            if clus < 2 or clus >= self.top or seen >= self.top:
                raise FileError(E_BADFAT)
            yield clus
            seen += 1
            clus = self.next(clus)

    def first_sector(self, clus: int) -> int:
        return self.data + (clus - 2) * self.spc

    def sectors(self, first: int) -> Iterator[int]:
        for clus in self.clusters(first):
            lba = self.first_sector(clus)
            yield from range(lba, lba + self.spc)

    def entries(self, first: int) -> Iterator[Entry]:
        """The files and directories of the directory from cluster first,
        as fat32.c's entry() takes them: not deleted, not long-name
        entries, not the volume label, and not . and .., each with the
        long name of the entries right before it."""
        parts: list[bytes] = []
        where: list[tuple[int, int]] = []
        for lba in self.sectors(first):
            sector = self.read(lba)
            for at in range(0, 512, 32):
                e = sector[at:at + 32]
                if e[0] == 0:
                    return
                if e[0] != 0xE5 and e[11] == 0x0F:
                    parts.append(e)
                    where.append((lba, at))
                    continue
                if e[0] == 0xE5 or e[11] & 0x08 or e[0] == 0x2E:
                    parts, where = [], []
                    continue
                raw = (b"\xe5" + e[1:11]) if e[0] == 0x05 else e[:11]
                yield Entry(raw, lfn_text(parts, e[:11]), e[11],
                            u16(e, 20) << 16 | u16(e, 26), u32(e, 28),
                            lba, at, where)
                parts, where = [], []

    def listing(self) -> list[Entry]:
        """The files and directories of the folder."""
        return list(self.entries(self.dir))

    def rows(self, listed: list[Entry] | None = None) -> list[str]:
        """The rows of the monitor's dir, of the listing given or of the
        folder."""
        if listed is None:
            listed = self.listing()
        files = sum(not e.is_dir for e in listed)
        return ([f"Directory of {self.folder.upper()}"] +
                [e.row() for e in listed] +
                [f"Files: {files}, directories: {len(listed) - files}"])

    def find(self, name: str) -> Entry:
        """The entry of the folder whose long name or 8.3 name is name, in
        either case."""
        want = name.casefold()
        for e in self.listing():
            if (e.long is not None and e.long.casefold() == want
                    or e.short.casefold() == want):
                return e
        raise FileError(E_NOFILE)

    def contents(self, e: Entry) -> bytes:
        """The bytes of the file of the entry e."""
        if e.is_dir:
            raise FileError(E_ISDIR)
        data = bytearray()
        if e.size:
            for lba in self.sectors(e.first):
                data += self.read(lba)
                if len(data) >= e.size:
                    break
        if len(data) < e.size:
            raise FileError(E_BADFAT)
        return bytes(data[:e.size])

    # Writing, in fat32.c's order

    def wr(self, lba: int, data: bytes) -> None:
        """A sector written, but none outside the partition, nor below its
        first FAT but FSInfo, so never the MBR or the boot sector."""
        if self._write is None:
            raise SdError("a write to a volume mounted to read")
        if (lba < self.fat and lba != self.fsinfo) or lba >= self.end:
            raise FileError(E_BADFAT)
        self._write(lba, data)

    def info(self) -> None:
        """FSInfo's free count set to unknown, and its next-free hint to
        ours, or ours taken from it first."""
        if not self.fsinfo:
            return
        b = bytearray(self.read(self.fsinfo))
        if (u32(b, 0) != 0x41615252 or u32(b, 484) != 0x61417272
                or u32(b, 508) != 0xAA550000):
            return
        if not self.hint:
            self.hint = u32(b, 492)
        put32(b, 488, 0xFFFFFFFF)
        put32(b, 492, self.hint)
        self.wr(self.fsinfo, bytes(b))
        self.unknown = True
        self.changed = False

    def infodone(self) -> None:
        """FSInfo written after a change of the FAT."""
        if self.changed:
            self.info()

    def set(self, c: int, v: int) -> None:
        """The FAT's entry of cluster c set to v, in every copy of the FAT,
        after FSInfo's free count is unknown."""
        if not self.unknown:
            self.info()
        lba = self.fat + (c >> 7)
        b = bytearray(self.read(lba))
        at = 4 * (c & 127)
        put32(b, at, (u32(b, at) & 0xF0000000) | v)
        self.changed = True
        for k in range(self.nfats):
            self.wr(lba + k * self.fatsz, bytes(b))

    def search(self) -> int:
        """A free cluster, searched from the hint up to the last and then
        from 2, but not taken."""
        if not self.hint and self.fsinfo:
            self.info()
        k = self.hint if 2 <= self.hint < self.top else 2
        for _ in range(self.top - 2):
            if self.next(k) == 0:
                return k
            k = k + 1 if k + 1 < self.top else 2
        raise FileError(E_FULL)

    def take(self, prev: int, c: int) -> None:
        """The free cluster c taken as the end of a chain, and linked after
        prev, unless prev is 0."""
        self.set(c, EOC)
        if prev:
            self.set(prev, c)
        self.hint = c + 1 if c + 1 < self.top else 2

    def release(self, c: int) -> None:
        """The chain from cluster c freed, up to its end, or a cluster
        outside the volume; the hint goes back to the first freed below
        it."""
        while 2 <= c < self.top:
            n = self.next(c)
            if n == 0:
                raise FileError(E_BADFAT)
            self.set(c, 0)
            if c < self.hint:
                self.hint = c
            c = n

    def make(self, raw: bytes) -> tuple[int, int]:
        """A new entry of the 8.3 name raw in the folder, empty, in the
        first free entry, or in a new cluster of zeros added to the folder,
        written. Its sector and offset."""
        date, tod = fat_stamp(self.now)
        pos, last = 0, 0
        clus = self.dir
        while True:
            if pos >= DIR_MAX:
                raise FileError(E_FULL)
            for k in range(self.spc):
                lba = self.first_sector(clus) + k
                b = bytearray(self.read(lba))
                for at in range(0, 512, 32):
                    if b[at] in (0, 0xE5):
                        e = bytearray(32)
                        e[:11] = raw
                        e[11] = 0x20            # archive
                        put16(e, 14, tod)       # created,
                        put16(e, 16, date)
                        put16(e, 18, date)      # read,
                        put16(e, 22, tod)       # and written
                        put16(e, 24, date)
                        b[at:at + 32] = e
                        self.wr(lba, bytes(b))
                        return lba, at
                    pos += 32
            last = clus
            clus = self.next(clus)
            if clus >= END:
                # The end of the chain: a new cluster, its zeros written
                # before it is taken and linked
                clus = self.search()
                for k in range(self.spc):
                    self.wr(self.first_sector(clus) + k, bytes(512))
                self.take(last, clus)
            elif clus < 2 or clus >= self.top:
                raise FileError(E_BADFAT)

    def writable(self, e: Entry) -> None:
        if e.is_dir:
            raise FileError(E_ISDIR)
        if e.attr & 0x01:
            raise FileError(E_RDONLY)

    def put(self, name: str, data: bytes) -> int:
        """Writes data as the file name of the folder, an 8.3 name, made,
        or truncated when it is there, and returns its size. When the card
        fills up, the file keeps what fitted, and FileError 30 follows."""
        raw = name83(name)
        old = [e for e in self.listing() if e.raw == raw]
        if old:
            # Truncated: the entry emptied, then its clusters freed
            e = old[0]
            self.writable(e)
            b = bytearray(self.read(e.lba))
            put16(b, e.off + 20, 0)
            put16(b, e.off + 26, 0)
            put32(b, e.off + 28, 0)
            self.wr(e.lba, bytes(b))
            self.release(e.first)
            self.infodone()
            elba, eoff = e.lba, e.off
        else:
            elba, eoff = self.make(raw)
            self.infodone()
        first = clus = 0
        done = 0
        full = False
        cbytes = 512 * self.spc
        while done < len(data):
            try:
                c = self.search()
                self.take(clus, c)
            except FileError as err:
                if err.code != E_FULL:
                    raise
                full = True
                break
            first = first or c
            clus = c
            part = data[done:done + cbytes]
            for k in range(0, len(part), 512):
                self.wr(self.first_sector(c) + k // 512,
                        part[k:k + 512].ljust(512, b"\0"))
            done += len(part)
        # Closed: its first cluster and its size in its entry, then FSInfo
        date, tod = fat_stamp(self.now)
        b = bytearray(self.read(elba))
        put16(b, eoff + 20, first >> 16)
        put16(b, eoff + 26, first)
        put32(b, eoff + 28, done)
        put16(b, eoff + 18, date)
        put16(b, eoff + 22, tod)
        put16(b, eoff + 24, date)
        self.wr(elba, bytes(b))
        self.infodone()
        if full:
            raise FileError(E_FULL)
        return done

    def delete(self, name: str) -> Entry:
        """Deletes the file of the folder whose long or 8.3 name is name:
        its long-name entries marked free, then its entry, each sector
        written as it changes, then its clusters freed, then FSInfo."""
        e = self.find(name)
        self.writable(e)
        s = lfn_sum(e.raw if e.raw[0] != 0xE5 else b"\x05" + e.raw[1:])
        for lba, at in e.lfn:
            b = bytearray(self.read(lba))
            if b[at + 11] == 0x0F and b[at + 13] == s:
                b[at] = 0xE5
                self.wr(lba, bytes(b))
        b = bytearray(self.read(e.lba))
        b[e.off] = 0xE5
        self.wr(e.lba, bytes(b))
        self.release(e.first)
        self.infodone()
        return e


def do_ls(vol: Volume) -> None:
    """The rows of the monitor's dir, with the long names."""
    listed = vol.listing()
    rows = vol.rows(listed)
    print(rows[0])
    for e, row in zip(listed, rows[1:-1]):
        print(row + (f"  {e.long}" if e.long is not None else ""))
    print(rows[-1])


def do_get(vol: Volume, name: str, dest: str | None) -> None:
    e = vol.find(name)
    data = vol.contents(e)
    if dest == "-":
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
        return
    if dest is None:
        dest = e.long if e.long is not None else e.short
    elif os.path.isdir(dest):
        dest = os.path.join(dest, e.long if e.long is not None else e.short)
    with open(dest, "wb") as f:
        f.write(data)
    print(f"{e.short}: {len(data)} bytes to {dest}")


def put_name(src: str, name: str | None) -> str:
    """The 8.3 name that put writes src as, checked before the link
    opens."""
    if name is None:
        if src == "-":
            raise FileError(E_NAME)
        name = os.path.basename(src)
    name83(name)
    return name.upper()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="List, copy, write, and delete the files of the folder "
        "NICE on the board's SD card, over the debug link.")
    add_arguments(parser)
    parser.add_argument("--slot", type=int,
                        help="the slot of the card, while the core is held "
                        "or has halted, with --hold, and for put and del "
                        "(default 0, or 1 when 0 has no card); a paused "
                        "program's slot otherwise")
    parser.add_argument("--hold", action="store_true",
                        help="for ls and get: hold a running or paused core, "
                        "and start it again from reset afterwards, as put "
                        "and del do, so that any slot can be read")
    parser.add_argument("--folder", default=FOLDER,
                        help="the folder of the root that the files are in "
                        "(default %(default)s, the monitor's)")
    cmds = parser.add_subparsers(dest="cmd", required=True)
    cmds.add_parser("ls", help="list the folder, as the monitor's dir does, "
                    "with the long names")
    get = cmds.add_parser("get", help="copy a file of the folder to the host")
    get.add_argument("name", help="its 8.3 name or its long name")
    get.add_argument("dest", nargs="?",
                     help="the file or the directory to write it to, or - "
                     "for stdout (default: its name, here)")
    put = cmds.add_parser("put", help="write a file of the host to the "
                          "folder; holds the core, and starts it again")
    put.add_argument("src", help="the host's file, or - for stdin")
    put.add_argument("name", nargs="?",
                     help="the 8.3 name on the card (default: SRC's name)")
    rm = cmds.add_parser("del", help="delete a file of the folder; holds "
                         "the core, and starts it again")
    rm.add_argument("name", help="its 8.3 name or its long name")
    args = parser.parse_args()
    data = b""
    try:
        if args.cmd == "put":
            name = put_name(args.src, args.name)
            if args.src == "-":
                data = sys.stdin.buffer.read()
            else:
                with open(args.src, "rb") as f:
                    data = f.read()
    except FileError as e:
        sys.exit(f"sdcard.py: {e}; give the name on the card, such as "
                 "put SRC PROG.BAS")
    except OSError as e:
        sys.exit(f"sdcard.py: {e}")
    link = open_link(args)
    try:
        writes = args.cmd in ("put", "del")
        with Card(link, args.slot, writes, args.hold) as card:
            vol = Volume(card.read, args.folder,
                         card.write if writes else None)
            if args.cmd == "ls":
                do_ls(vol)
            elif args.cmd == "get":
                do_get(vol, args.name, args.dest)
            elif args.cmd == "put":
                n = vol.put(name, data)
                print(f"{name}: {n} bytes written")
            else:
                gone = vol.delete(args.name)
                print(f"Deleted {gone.short}")
    except (SdError, FileError, LinkError, OSError) as e:
        sys.exit(f"sdcard.py: {e}")
    finally:
        link.close()


if __name__ == "__main__":
    main()
