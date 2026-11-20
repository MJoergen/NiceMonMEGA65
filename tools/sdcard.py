#!/usr/bin/env python3
"""The files on the board's SD card, over the debug link, with no PC slot.

The host reaches the card through the SD controller's registers at
FFFFFFA0-AF (nice_cpu's DEVICES.md §5), which the link reaches while the
core is held, paused, or halted, and reads and writes its FAT32 file
system itself, as the monitor's monitor/monitor_fat.nasm does: sector 0 as a
FAT32 boot sector, or the first partition of type 0x0B or 0x0C of an
MBR, and in it only the folder NICE, the monitor's (#91), or the one
that --folder names:

    tools/nicemon.py sd --eth 192.168.1.65 ls
    tools/nicemon.py sd --eth 192.168.1.65 get HELLO.BIN [DEST]
    tools/nicemon.py sd --eth 192.168.1.65 put prog.bas [NAME]
    tools/nicemon.py sd --eth 192.168.1.65 del NAME
    tools/nicemon.py sd --eth 192.168.1.65 mkdir
    tools/nicemon.py sd --eth 192.168.1.65 --slot 0 format

ls prints the rows of BASIC's DIR, which shows a file's long name
where it has one, with its 8.3 name after its size. get takes the 8.3
name or the long name, in
either case, and writes the file to DEST, by default its name in the
current directory, or with DEST - to stdout: the long name, when it is a
plain file name, or else the 8.3 name, so that a card's name with a
path in it, such as ../x, writes nowhere else. put writes the host's file
SRC, or stdin for -, as the file NAME, by default SRC's own name, a long
name of up to 255 characters or an 8.3 name: it makes the file, or
truncates it when it is there, by either name. A new file gets
long-name entries and an 8.3 alias with a tail, MANDEL~1.BIN, as
monitor_fat.nasm makes them, unless its name is an 8.3 name in upper case, or in
lower case in a part. del deletes a file, by either name, with its
long-name entries. mkdir makes the folder in the root of a card that
has FAT32 but not the folder, which the monitor never makes, and says
so when it is there already; the folder's name must be an 8.3 name with
no extension, as NICE is.

format erases the whole card in the slot of --slot, which it needs,
and writes a new FAT32, as cards are sold: an MBR with one partition
of type 0x0C from sector 8192 to the end, two FATs, Microsoft's cluster
size for the size, the reserved sectors grown so that cluster 2 starts
on a boundary of 4 MB, the root at cluster 2 with the label, NICE by
default or --label's, and the folder at cluster 3. It shows the card's
size and what is on it first, and asks for the slot's number to be
typed, which --yes skips. It refuses a write-protected card, one too
small for 65525 clusters, one that is not blank, whose sector 0 is not
all zeros or all ones, without --force, and one with the MEGA65's
system partition, of type 0x41, without --system. It zeros the old MBR
and a GPT's header first, then writes the FATs, the root and the
folder, FSInfo, and the copies of the boot sector and FSInfo, and the
boot sector and the MBR last, so that a format that breaks off leaves a
card with no FAT32 rather than a broken one. The FATs' zeros, about
30000 sectors on most cards, go with the buffer loaded once and only
the sector's address and the Write sent for each.

The writes keep to monitor_fat.nasm's order, in which a reset at any point leaves
the card no worse than with lost clusters, which fsck.fat frees: FSInfo's
free count set to unknown before the first change of the FAT, a new
cluster marked as the end of its chain in every FAT before the one
before it is linked to it, a truncated file's entry emptied before its
clusters are freed, a new file's first cluster and size put into its
entry last, a new file's long-name entries written before its 8.3 entry,
and a deleted file's long-name entries marked before its entry. No
sector outside the partition is written, nor one below its first FAT
but FSInfo. mkdir takes the folder's cluster, its zeros and its entries
. and .. written first, before the root's entry of it, so that a reset
leaves a lost cluster at worst. The date and time of a new entry are
the host's.

The core: for ls and get, a running one is paused, and goes on after
them. While it is paused, by the tool or before, the tool keeps to the
rules of DEVICES.md §5 for the card of a paused program: it waits for the
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
program is lost. put, del, and mkdir hold a running or paused core
first, and start it again from reset after the write, as a program
such as the monitor keeps a sector of the FAT and its mount between
commands, which the write makes stale. format does so too.
A program in the middle of a write of its own loses it, as at a reset,
with lost clusters at worst. A held core stays held.

The tool exits with status 1 and a message on an error, as the monitor's
"File error N, ..." for one of the file system, with a hint for a card
with no FAT32 or without the folder. Only the Python standard
library is used, so this runs on Linux and macOS.

Usage: tools/nicemon.py sd (--eth HOST[:PORT] | --port DEVICE [--baud 230400]
                           | --tcp [HOST:]PORT | --cosim PORT)
                           [--slot N] [--folder NAME] [--hold]
                           (ls | get NAME [DEST] | put SRC [NAME] | del NAME
                            | mkdir | format [--label L] [--force]
                              [--system] [--yes])
"""

from __future__ import annotations

import argparse
import os
import struct
import sys
import time
from collections import OrderedDict
from dataclasses import dataclass, field
from types import TracebackType
from typing import Callable, Iterator

from boardlink import (CONTROL, HALTED, HOLD, PAUSE, RAM, Link, LinkError,
                       add_arguments, open_link)

# The SD card controller's registers (nice_cpu's DEVICES.md §5)
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
# The sectors that a Card keeps, the last read or written, so that the
# FAT and the directory are read once, while a file's data passes through
CACHE_SECTORS = 256

# The controller's errors in SD_ERROR, and the file system's of
# monitor/monitor_fat.nasm, with the monitor's texts (basic/basic_cmd.nasm, E_FS*)
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
    20: "not a valid name",
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
# What to do about a card that the tool cannot use as it is
FORMAT = "; format it with the command format, or as FAT32 on a PC"
HINTS = {
    E_NOFS: FORMAT, E_FAT12: FORMAT, E_FAT16: FORMAT, E_EXFAT: FORMAT,
    E_NOFOLDER: "; make it with the command mkdir",
}

# The monitor's folder on the card unless the build sets another
FOLDER = "NICE"
# The FAT's entry at the end of a chain, and those from which an entry
# ends one
EOC = 0x0FFFFFFF
END = 0x0FFFFFF8
# The bytes of a directory at most, as monitor_fat.nasm's DIR_MAX
DIR_MAX = 65536 * 32
# The characters that no name may have, beside those below blank and
# from 0x7F (monitor_fat.nasm's isbad), and those that a long name may have, but an
# 8.3 name not (monitor_fat.nasm's isu)
BAD = set('"*/:<>?\\|')
NOT_83 = set(" +,.;=[]")
# The characters of a long name at most, and its long-name entries
NAME_MAX = 255
LFN_MAX = 20
# The bytes of a long-name entry that hold its 13 characters, UTF-16
LFN_AT = (1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30)
# The columns of the name in a row of dir, as monitor_fat.nasm's DIR_NAME
DIR_NAME = 24


class SdError(Exception):
    """A command of the SD controller failed, or the card cannot be used
    as the core's state is."""


class FileError(Exception):
    """An error of the file system, with the number that the monitor's
    monitor_fat.nasm gives it, negated."""

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
    the timeout. SD_ERROR is read only when the error bit is 1, as it is 0
    otherwise (DEVICES.md §5), which saves a round trip of the link."""
    end = time.monotonic() + timeout
    while True:
        csr = link.read_word(SD_CSR)
        if csr & BUSY == 0:
            return csr, link.read_word(SD_ERROR) if csr & ERROR else 0
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
        self.cache: OrderedDict[int, bytes] = OrderedDict()

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
                # the controller (DEVICES.md §5)
                self.restart = False
                sd_wait(link, WRITE_WAIT)
                link.control(self.ctl & RAM)
                sys.stdout.flush()
                print("sdcard.py: the core was started again from reset",
                      file=sys.stderr)

    def _keep(self, lba: int, data: bytes) -> None:
        """data as the sector lba's, the last used, and the oldest let go
        when more than CACHE_SECTORS are kept."""
        self.cache[lba] = data
        self.cache.move_to_end(lba)
        if len(self.cache) > CACHE_SECTORS:
            self.cache.popitem(last=False)

    def read(self, lba: int) -> bytes:
        """The 512 bytes of the sector lba."""
        got = self.cache.get(lba)
        if got is not None:
            self.cache.move_to_end(lba)
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
        self._keep(lba, data)
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
        self._keep(lba, bytes(data))

    def protected(self) -> bool:
        """Whether the card's write-protect switch is set."""
        return bool(self.link.read_word(SD_CSR) & PROTECTED)

    def zero(self, first: int, count: int,
             progress: Callable[[int], None] | None = None) -> None:
        """Writes zeros to the count sectors from first, with the buffer
        loaded once and only SD_LBA and the Write sent for each sector,
        and progress called with the sectors written so far."""
        if not self.writes:
            raise SdError("a write in a session for reads")
        if count and first + count - 1 > self.last:
            raise SdError(f"sector {first + count - 1:#x} is after the "
                          f"card's last, {self.last:#x}")
        write_buffer(self.link, [0] * 128)
        for lba in range(first, first + count):
            self.cache.pop(lba, None)
            self.link.write(SD_LBA, [lba])
            done = sd_command(self.link, WRITE, WRITE_WAIT)
            if done is None or done[1]:
                raise SdError(f"Write of sector {lba:#x} in slot "
                              f"{self.slot}: {sd_said(done)}")
            if progress is not None:
                progress(lba - first + 1)


def u16(b: bytes | bytearray, at: int) -> int:
    return int.from_bytes(b[at:at + 2], "little")


def u32(b: bytes | bytearray, at: int) -> int:
    return int.from_bytes(b[at:at + 4], "little")


def put16(b: bytearray, at: int, v: int) -> None:
    b[at:at + 2] = (v & 0xFFFF).to_bytes(2, "little")


def put32(b: bytearray, at: int, v: int) -> None:
    b[at:at + 4] = (v & 0xFFFFFFFF).to_bytes(4, "little")


def boot_kind(b: bytes) -> int:
    """What the sector b is, as monitor_fat.nasm's kind says: 0 for a FAT32 boot
    sector, a FileError's code for another file system, and 1 for no boot
    sector, or one without the 55 AA signature. The type is told by the
    count of clusters."""
    if b[3:11] == b"EXFAT   ":
        return E_EXFAT
    spc, rsvd, nfats = b[13], u16(b, 14), b[16]
    fatsz = u16(b, 22) or u32(b, 36)
    if (b[0] not in (0xEB, 0xE9) or u16(b, 11) != 512 or spc == 0
            or spc & (spc - 1) or rsvd == 0 or nfats == 0 or fatsz == 0
            or b[510:512] != b"\x55\xaa"):
        return 1
    rootsecs = (u16(b, 17) * 32 + 511) // 512
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


def bad(c: str) -> bool:
    """A character that no name may have (monitor_fat.nasm's isbad)."""
    return c < " " or c >= "\x7f" or c in BAD


def name83(name: str) -> tuple[bytes, int] | None:
    """The 11 bytes of the 8.3 name name, in upper case, as monitor_fat.nasm's
    name83 makes them: a base of 1 to 8 characters, and an extension of
    1 to 3 after a dot, if any; and the flags of byte 12 for a part in
    lower case, or -1 for a part in mixed case. None when name is no 8.3
    name."""
    base, dot, ext = name.partition(".")
    if not base or dot and not ext or len(base) > 8 or len(ext) > 3:
        return None
    if any(bad(c) or c in NOT_83 for c in base + ext):
        return None
    lower = 0
    for part, flag in ((base, 0x08), (ext, 0x10)):
        if part != part.upper():
            lower = -1 if part != part.lower() or lower < 0 else lower | flag
    return (base.upper().ljust(8) + ext.upper().ljust(3)).encode("ascii"), lower


def long_ok(name: str) -> bool:
    """name as the long name of a new file (monitor_fat.nasm's longok): 1 to 255
    characters that bad() lets through, not ending in a blank or a dot."""
    return (0 < len(name) <= NAME_MAX and not any(bad(c) for c in name)
            and name[-1] not in " .")


def basis(name: str) -> tuple[bytes, bool]:
    """The basis of name's 8.3 alias, as monitor_fat.nasm's basis makes it: the
    base from the characters before the last dot, and the extension from
    those after it, in upper case, without blanks and dots, and with _ for
    +,;=[]; and whether that lost a character, or cut a part, so that the
    alias needs a tail. A name whose dots are all at its start has no
    extension."""
    dot = len(name)
    seen = False
    for i, c in enumerate(name):
        if c == ".":
            dot = i if seen else len(name)
        elif c != " ":
            seen = True
    parts = ["", ""]
    lossy = False
    for i, c in enumerate(name):
        if i == dot:
            continue
        k = int(i > dot)
        if c in " ." or len(parts[k]) == (3 if k else 8):
            lossy = True
            continue
        if c in NOT_83:
            c = "_"
            lossy = True
        parts[k] += c.upper()
    return (parts[0].ljust(8) + parts[1].ljust(3)).encode("ascii"), lossy


def with_tail(raw: bytes, t: int) -> bytes:
    """The basis raw with the tail ~t, the base cut to make room for it."""
    base = raw[:8].rstrip(b" ")
    tail = b"~%d" % t
    return (base[:8 - len(tail)] + tail).ljust(8) + raw[8:]


def lfn_entries(name: str, raw: bytes) -> list[bytes]:
    """The long-name entries of name for the 8.3 name raw, in the order
    on the card: the last part first, its number with bit 6 set, then
    down to 1, the characters after the name a 0 and then 0xFFFF."""
    n = (len(name) + 12) // 13
    s = lfn_sum(raw)
    out = []
    for m in range(n, 0, -1):
        e = bytearray(32)
        e[0] = m | (0x40 if m == n else 0)
        e[11] = 0x0F
        e[13] = s
        for j, at in enumerate(LFN_AT):
            pos = 13 * (m - 1) + j
            put16(e, at, ord(name[pos]) if pos < len(name)
                  else 0 if pos == len(name) else 0xFFFF)
        out.append(bytes(e))
    return out


def fat_stamp(t: float) -> tuple[int, int]:
    """FAT's date and time of the local time t."""
    lt = time.localtime(t)
    date = (max(lt.tm_year - 1980, 0) << 9) | (lt.tm_mon << 5) | lt.tm_mday
    return date, (lt.tm_hour << 11) | (lt.tm_min << 5) | (lt.tm_sec // 2)


def dir_entry(raw: bytes, attr: int, clus: int, now: float) -> bytes:
    """A directory's entry of the 11 bytes raw, with the attributes attr,
    the first cluster clus, and the local time now as its creation, its
    last access, and its last write."""
    date, tod = fat_stamp(now)
    e = bytearray(32)
    e[0:11] = raw
    e[11] = attr
    put16(e, 14, tod)
    put16(e, 16, date)
    put16(e, 18, date)
    put16(e, 20, clus >> 16)
    put16(e, 22, tod)
    put16(e, 24, date)
    put16(e, 26, clus)
    return bytes(e)


def dot_entries(c: int, parent: int, now: float) -> bytes:
    """The entries . and .. of a new directory at cluster c, whose
    parent's first cluster is parent, or 0 for the root."""
    return (dir_entry(b".".ljust(11), 0x10, c, now) +
            dir_entry(b"..".ljust(11), 0x10, parent, now))


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
    case: int = 0

    @property
    def is_dir(self) -> bool:
        return bool(self.attr & 0x10)

    @property
    def short(self) -> str:
        """The 8.3 name as a name: HELLO.BIN."""
        base = self.raw[:8].decode("latin-1").rstrip()
        ext = self.raw[8:].decode("latin-1").rstrip()
        return base + "." + ext if ext else base

    @property
    def name(self) -> str:
        """The name as the monitor shows it, as monitor_fat.nasm's LNAME has it:
        the long name, or else the 8.3 name as a name, each part in lower
        case when byte 12 says so, with ? for a character outside
        ASCII."""
        if self.long is not None:
            return "".join(c if " " <= c < "\x7f" else "?"
                           for c in self.long)
        base = self.raw[:8].decode("latin-1").rstrip()
        ext = self.raw[8:].decode("latin-1").rstrip()
        if self.case & 0x08:
            base = base.lower()
        if self.case & 0x10:
            ext = ext.lower()
        text = base + "." + ext if ext else base
        return "".join(c if " " <= c < "\x7f" else "?" for c in text)

    def rows(self) -> list[str]:
        """The rows of BASIC's DIR: the name in DIR_NAME columns,
        or on a row of its own when it is that long or longer, and the
        size or <DIR> in 12."""
        name = self.name
        size = "<DIR>" if self.is_dir else str(self.size)
        if len(name) >= DIR_NAME:
            return [name, " " * DIR_NAME + f"{size:>12}"]
        return [f"{name:<{DIR_NAME}}{size:>12}"]


def lfn_sum(raw: bytes) -> int:
    """The checksum of an 8.3 name that its long-name entries carry."""
    s = 0
    for c in raw:
        s = (((s & 1) << 7) + (s >> 1) + c) & 0xFF
    return s


def lfn_text(parts: list[bytes], raw: bytes) -> str | None:
    """The long name of the long-name entries before an entry, in the
    order on the card, as monitor_fat.nasm's entry takes them: those from the
    last with bit 6 set in its number, or None when they are not those of
    raw: a wrong checksum, numbers out of sequence, more than LFN_MAX
    entries, or a name that is empty or longer than NAME_MAX."""
    starts = [i for i, p in enumerate(parts) if p[0] & 0x40]
    if not starts:
        return None
    parts = parts[starts[-1]:]
    n = len(parts)
    if parts[0][0] & 0x1F != n or n > LFN_MAX:
        return None
    units: list[int] = []
    for i, p in enumerate(reversed(parts)):
        if p[0] & 0x1F != i + 1 or p[13] != lfn_sum(raw):
            return None
        units += [u16(p, at) for at in LFN_AT]
    if 0 in units:
        units = units[:units.index(0)]
    if not 0 < len(units) <= NAME_MAX:
        return None
    return b"".join(struct.pack("<H", u) for u in units).decode(
        "utf-16-le", errors="replace")


class FolderError(Exception):
    """The folder cannot be made, as a file of the root has its name."""


class Volume:
    """A FAT32 file system on a card, read with read(lba) and written
    with write(lba, data), if given, mounted as monitor_fat.nasm mounts one, with
    its folder, and only that folder. With need False, a card without the
    folder mounts too, with dir 0, for mkdir."""

    def __init__(self, read: Callable[[int], bytes],
                 folder: str = FOLDER,
                 write: Callable[[int, bytes], None] | None = None,
                 now: float | None = None, need: bool = True) -> None:
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
        # changed since FSInfo was written (monitor_fat.nasm's V_UNKNOWN and V_CHANGED)
        self.hint = 0
        self.unknown = False
        self.changed = False
        root = u32(b, 44)
        if root < 2 or root >= self.top:
            raise FileError(E_BADFAT)
        self.root = root
        name = folder.upper().ljust(11).encode("latin-1")
        found = [e for e in self.entries(root) if e.raw == name]
        self.dir = 0
        if not found or not found[0].is_dir:
            if need:
                raise FileError(E_NOFOLDER, folder)
            return
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
        as monitor_fat.nasm's entry takes them: not deleted, not long-name
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
                            lba, at, where, e[12])
                parts, where = [], []

    def listing(self) -> list[Entry]:
        """The files and directories of the folder."""
        return list(self.entries(self.dir))

    def rows(self, listed: list[Entry] | None = None) -> list[str]:
        """The rows of BASIC's DIR, of the listing given or of the
        folder."""
        if listed is None:
            listed = self.listing()
        files = sum(not e.is_dir for e in listed)
        return ([f"Directory of {self.folder.upper()}"] +
                [r for e in listed for r in e.rows()] +
                [f"Files: {files}, directories: {len(listed) - files}"])

    def find(self, name: str) -> Entry:
        """The entry of the folder whose long name or 8.3 name is name, in
        either case."""
        e = self.lookup(name)
        if e is None:
            raise FileError(E_NOFILE)
        return e

    def lookup(self, name: str) -> Entry | None:
        """The entry of the folder whose long name or 8.3 name is name, in
        either case, or None."""
        want = name.casefold()
        for e in self.listing():
            if (e.long is not None and e.long.casefold() == want
                    or e.short.casefold() == want):
                return e
        return None

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

    # Writing, in monitor_fat.nasm's order

    def wr(self, lba: int, data: bytes) -> None:
        """A sector written, but none outside the partition, nor below its
        first FAT but FSInfo, when the volume has one, so never the MBR or
        the boot sector."""
        if self._write is None:
            raise SdError("a write to a volume mounted to read")
        if ((lba < self.fat and not (self.fsinfo and lba == self.fsinfo))
                or lba >= self.end):
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

    def make(self, raw: bytes, lower: int = 0,
             lfn: list[bytes] | None = None, parent: int = 0,
             attr: int = 0x20, first: int = 0) -> tuple[int, int]:
        """A new entry of the 8.3 name raw in the folder, or in the
        directory from cluster parent, if given, empty or with the first
        cluster first, with the attributes attr, archive by default, the
        flags lower in byte 12, and the long-name entries lfn before it,
        in the first run of free entries for all, which may go on into a
        new cluster of zeros added to the directory. The long-name entries
        are written first, then the 8.3 entry, a sector at a time, as
        monitor_fat.nasm's make writes them. Its sector and offset."""
        date, tod = fat_stamp(self.now)
        e = bytearray(32)
        e[:11] = raw
        e[11] = attr
        e[12] = lower
        put16(e, 14, tod)       # created,
        put16(e, 16, date)
        put16(e, 18, date)      # read,
        put16(e, 22, tod)       # and written
        put16(e, 24, date)
        put16(e, 20, first >> 16)
        put16(e, 26, first)
        todo = (lfn or []) + [bytes(e)]
        run: list[tuple[int, int]] = []
        pos, last = 0, 0
        clus = parent or self.dir
        while len(run) < len(todo):
            for k in range(self.spc):
                lba = self.first_sector(clus) + k
                b = self.read(lba)
                for at in range(0, 512, 32):
                    if len(run) == len(todo):
                        break
                    if pos >= DIR_MAX:
                        raise FileError(E_FULL)
                    if b[at] in (0, 0xE5):
                        run.append((lba, at))
                    else:
                        run = []
                    pos += 32
            if len(run) == len(todo):
                break
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
        sector = bytearray()
        for i, ((lba, at), data) in enumerate(zip(run, todo)):
            if i == 0 or lba != run[i - 1][0]:
                sector = bytearray(self.read(lba))
            sector[at:at + 32] = data
            if i == len(run) - 1 or run[i + 1][0] != lba:
                self.wr(lba, bytes(sector))
        return run[-1]

    def new_name(self, name: str) -> tuple[bytes, int, list[bytes]]:
        """The 8.3 name of a new file name, the flags of its byte 12, and
        its long-name entries, as monitor_fat.nasm's newname makes them: name
        itself when it is an 8.3 name in upper case, or in lower case in a
        part, with no long-name entries; or else its basis, with the first
        tail ~1, ~2, and on that no entry of the folder has, when it needs
        one."""
        got = name83(name)
        if got is not None and got[1] >= 0:
            return got[0], got[1], []
        if not long_ok(name):
            raise FileError(E_NAME)
        raw, lossy = basis(name)
        if lossy:
            taken = {e.raw for e in self.listing()}
            t = 1
            while with_tail(raw, t) in taken:
                t += 1
            raw = with_tail(raw, t)
        return raw, 0, lfn_entries(name, raw)

    def writable(self, e: Entry) -> None:
        if e.is_dir:
            raise FileError(E_ISDIR)
        if e.attr & 0x01:
            raise FileError(E_RDONLY)

    def put(self, name: str, data: bytes) -> int:
        """Writes data as the file name of the folder, its long name or
        its 8.3 name, made, or truncated when it is there, and returns its
        size. When the card fills up, the file keeps what fitted, and
        FileError 30 follows."""
        e = self.lookup(name)
        if e is not None:
            # Truncated: the entry emptied, then its clusters freed
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
            elba, eoff = self.make(*self.new_name(name))
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

    def mkdir(self) -> bool:
        """Makes the folder in the root, unless it is there, and returns
        whether it made it: a free cluster, its zeros with the entries .
        and .. written before it is taken, and the root's entry of the
        folder last, with that cluster, so that a reset at any point
        leaves no worse than a lost cluster. The name must be an 8.3 name
        with no extension, as the mount compares the entry's 11 bytes
        with it."""
        if self.dir:
            return False
        raw = self.folder.upper().ljust(11).encode("latin-1")
        got = name83(self.folder.upper())
        if got is None or got[0] != raw:
            raise FileError(E_NAME)
        if any(e.raw == raw for e in self.entries(self.root)):
            raise FolderError(f"a file of the root has the name "
                              f"{self.folder.upper()}; delete or rename it "
                              "first")
        c = self.search()
        first = dot_entries(c, 0, self.now).ljust(512, b"\0")
        lba = self.first_sector(c)
        self.wr(lba, first)
        for k in range(1, self.spc):
            self.wr(lba + k, bytes(512))
        self.take(0, c)
        self.make(raw, parent=self.root, attr=0x10, first=c)
        self.infodone()
        self.dir = c
        return True

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
    """The rows of BASIC's DIR, with the 8.3 name after those of a
    file whose name is a long name."""
    listed = vol.listing()
    rows = vol.rows(listed)
    print(rows[0])
    for e in listed:
        *first, last = e.rows()
        for row in first:
            print(row)
        print(last + (f"  {e.short}" if e.long is not None else ""))
    print(rows[-1])


def host_name(e: Entry) -> str:
    """The name that get writes the file of the entry e under: its long
    name when that is a plain file name, or else its 8.3 name, which
    always is. A card is not trusted with a path: a long name with / or
    \\, or . or .., would write outside the directory given."""
    long = e.long
    if (long is None or not long or long in (".", "..") or "/" in long
            or "\\" in long or "\0" in long):
        return e.short
    return long


def do_get(vol: Volume, name: str, dest: str | None) -> None:
    e = vol.find(name)
    data = vol.contents(e)
    if dest == "-":
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
        return
    if dest is None:
        dest = host_name(e)
    elif os.path.isdir(dest):
        dest = os.path.join(dest, host_name(e))
    with open(dest, "wb") as f:
        f.write(data)
    print(f"{e.short}: {len(data)} bytes to {dest}")


def put_name(src: str, name: str | None) -> str:
    """The name that put writes src as, checked before the link opens: an
    8.3 name, or a long name that monitor_fat.nasm's longok takes."""
    if name is None:
        if src == "-":
            raise FileError(E_NAME)
        name = os.path.basename(src)
    if name83(name) is None and not long_ok(name):
        raise FileError(E_NAME)
    return name


# The format: the first sector of the partition, as cards are sold, the
# alignment of the first cluster, 4 MB, the reserved sectors at least,
# and where in them the boot sector's copy and FSInfo's are
PART_START = 8192
ALIGN = 8192
RSVD_MIN = 32
BACKUP = 6
FSINFO = 1
NFATS = 2
# The fewest clusters of a FAT32, below which a FAT is FAT16
MIN_CLUSTERS = 65525
# The partition types, for the table that format shows; 0x41 is the
# MEGA65's system partition, on the card in slot 1
SYSTEM = 0x41
PART_TYPES = {
    0x01: "FAT12", 0x04: "FAT16", 0x06: "FAT16", 0x07: "NTFS or exFAT",
    0x0B: "FAT32", 0x0C: "FAT32", 0x0E: "FAT16", 0x0F: "extended",
    SYSTEM: "the MEGA65's system partition", 0x82: "Linux swap",
    0x83: "Linux", 0xEE: "GPT",
}


def cluster_sectors(sectors: int) -> int:
    """The sectors of a cluster of a FAT32 of sectors sectors, from
    Microsoft's table (fatgen103), or 0 for one too small."""
    for top, spc in ((66600, 0), (532480, 1), (16777216, 8),
                     (33554432, 16), (67108864, 32)):
        if sectors <= top:
            return spc
    return 64


@dataclass
class Layout:
    """Where a format puts a FAT32 of a card of total sectors: its
    partition from base, of size sectors, with rsvd reserved sectors,
    FATs of fatsz sectors, clusters of spc sectors, and clusters of them,
    the root at cluster 2 and the folder at 3."""
    total: int
    base: int
    size: int
    spc: int
    rsvd: int
    fatsz: int
    clusters: int

    @property
    def fat(self) -> int:
        return self.base + self.rsvd

    @property
    def data(self) -> int:
        return self.fat + NFATS * self.fatsz

    def cluster(self, c: int) -> int:
        return self.data + (c - 2) * self.spc


def layout(total: int) -> Layout | None:
    """The layout of a format of a card of total sectors, or None for a
    card too small for a FAT32: the partition from sector 8192 to the
    end, Microsoft's cluster size and size of the FAT, and the reserved
    sectors grown so that cluster 2 starts on a boundary of 4 MB, unless
    that leaves too few clusters."""
    size = total - PART_START
    spc = cluster_sectors(size)
    if spc == 0:
        return None
    # fatgen103's size of the FAT, which may be a little large
    per = (256 * spc + NFATS) // 2
    fatsz = (size - RSVD_MIN + per - 1) // per
    for rsvd in (RSVD_MIN + (-(PART_START + RSVD_MIN + NFATS * fatsz))
                 % ALIGN, RSVD_MIN):
        clusters = (size - rsvd - NFATS * fatsz) // spc
        if clusters >= MIN_CLUSTERS and rsvd <= 0xFFFF:
            return Layout(total, PART_START, size, spc, rsvd, fatsz,
                          min(clusters, fatsz * 128 - 2))
    return None


def chs(lba: int) -> bytes:
    """The 3 bytes of an MBR's cylinder, head, and sector of lba, with 255
    heads and 63 sectors, or the largest for one beyond them."""
    c, rest = divmod(lba, 255 * 63)
    h, sec = divmod(rest, 63)
    if c > 1023:
        c, h, sec = 1023, 254, 62
    return bytes((h, (sec + 1) | ((c >> 2) & 0xC0), c & 0xFF))


def format_sectors(lay: Layout, label: str, folder: str, serial: int,
                   now: float) -> dict[str, bytes]:
    """The sectors of a format that are not all zeros: the MBR, the boot
    sector, FSInfo, the first sector of a FAT, the root's, with the
    volume's label and the folder, and the folder's, with . and .."""
    raw_label = label.upper().ljust(11).encode("latin-1")
    mbr = bytearray(512)
    put32(mbr, 440, serial)
    e = 446
    mbr[e + 1:e + 4] = chs(lay.base)
    mbr[e + 4] = 0x0C
    mbr[e + 5:e + 8] = chs(lay.base + lay.size - 1)
    put32(mbr, e + 8, lay.base)
    put32(mbr, e + 12, lay.size)
    mbr[510:512] = b"\x55\xaa"
    boot = bytearray(512)
    boot[0:3] = b"\xeb\x58\x90"
    boot[3:11] = b"NICEMON "
    put16(boot, 11, 512)
    boot[13] = lay.spc
    put16(boot, 14, lay.rsvd)
    boot[16] = NFATS
    boot[21] = 0xF8
    put16(boot, 24, 63)
    put16(boot, 26, 255)
    put32(boot, 28, lay.base)
    put32(boot, 32, lay.size)
    put32(boot, 36, lay.fatsz)
    put32(boot, 44, 2)
    put16(boot, 48, FSINFO)
    put16(boot, 50, BACKUP)
    boot[64] = 0x80
    boot[66] = 0x29
    put32(boot, 67, serial)
    boot[71:82] = raw_label
    boot[82:90] = b"FAT32   "
    boot[510:512] = b"\x55\xaa"
    info = bytearray(512)
    put32(info, 0, 0x41615252)
    put32(info, 484, 0x61417272)
    put32(info, 488, lay.clusters - 2)
    put32(info, 492, 4)
    put32(info, 508, 0xAA550000)
    fat = bytearray(512)
    for c, v in enumerate((0x0FFFFFF8, EOC, EOC, EOC)):
        put32(fat, 4 * c, v)
    root = (dir_entry(raw_label, 0x08, 0, now) +
            dir_entry(folder.upper().ljust(11).encode("latin-1"), 0x10, 3,
                      now))
    return {"mbr": bytes(mbr), "boot": bytes(boot), "info": bytes(info),
            "fat": bytes(fat), "root": root.ljust(512, b"\0"),
            "folder": dot_entries(3, 0, now).ljust(512, b"\0")}


def size_text(sectors: int) -> str:
    """A size in sectors as cards are sold, in decimal megabytes or
    gigabytes."""
    n = sectors * 512
    if n >= 10 ** 9:
        return f"{n / 10 ** 9:.1f} GB"
    return f"{n / 10 ** 6:.0f} MB"


def fat_label(b: bytes) -> str | None:
    """The label of the boot sector b of a FAT, or None for none."""
    k = boot_kind(b)
    if k == 0:
        at = 71
    elif k in (E_FAT12, E_FAT16):
        at = 43
    else:
        return None
    if b[at - 5] != 0x29:
        return None
    return b[at:at + 11].decode("latin-1").rstrip()


def describe(read: Callable[[int], bytes], last: int) -> list[str]:
    """What is on the card, for the lines that format shows before it asks:
    its partitions, with their types, sizes, and FAT labels, or the file
    system on the whole card."""
    b = read(0)
    if all(x == 0 for x in b) or all(x == 0xFF for x in b):
        return ["  nothing: sector 0 is blank"]
    k = boot_kind(b)
    if k != 1:
        name = {0: "FAT32", E_FAT12: "FAT12", E_FAT16: "FAT16",
                E_EXFAT: "exFAT"}.get(k, "a file system")
        label = fat_label(b)
        return [f"  {name} on the whole card" +
                (f", label {label}" if label else "")]
    if b[510:512] != b"\x55\xaa":
        return ["  no partition table, and no file system that is known"]
    rows = []
    for i in range(4):
        p = b[446 + 16 * i:462 + 16 * i]
        if not p[4]:
            continue
        start, count = u32(p, 8), u32(p, 12)
        row = (f"  partition {i + 1}: type {p[4]:#04x}, "
               f"{PART_TYPES.get(p[4], 'unknown')}, {size_text(count)} "
               f"from sector {start}")
        if p[4] != 0xEE and 0 < start <= last:
            label = fat_label(read(start))
            if label:
                row += f", label {label}"
        rows.append(row)
    return rows or ["  an MBR with no partitions"]


def system_partition(b: bytes) -> bool:
    """Whether sector 0, b, is an MBR with the MEGA65's system
    partition."""
    return b[510:512] == b"\x55\xaa" and boot_kind(b) == 1 and any(
        b[446 + 16 * i + 4] == SYSTEM for i in range(4))


class Progress:
    """A line on stderr with the sectors written of a total, and the time
    left, at most a few times a second."""

    def __init__(self, total: int) -> None:
        self.total = total
        self.start = time.monotonic()
        self.shown = 0.0
        self.done = 0

    def __call__(self, n: int) -> None:
        self.done = n
        now = time.monotonic()
        if now - self.shown < 0.5 and n < self.total:
            return
        self.shown = now
        left = (now - self.start) / n * (self.total - n)
        print(f"\r  {n} of {self.total} sectors, "
              f"{100 * n // self.total}%, {left / 60:.0f} min left  ",
              end="", file=sys.stderr, flush=True)
        if n == self.total:
            print(file=sys.stderr)


def check_names(folder: str, label: str) -> None:
    """The folder's name, an 8.3 name with no extension, and the label, of
    up to 11 characters of an 8.3 name, or blanks, checked before
    format."""
    raw = folder.upper().ljust(11).encode("latin-1")
    got = name83(folder.upper())
    if got is None or got[0] != raw:
        raise FileError(E_NAME)
    if (len(label) > 11 or not label.strip() or
            any(bad(c) or c in NOT_83 - {" "} for c in label)):
        raise SdError(f"the label {label!r} is not valid: up to 11 "
                      "characters, of those of an 8.3 name, or blanks")


def do_format(card: Card, folder: str, label: str, force: bool,
              system: bool, yes: bool, serial_port: bool) -> None:
    """Writes a new FAT32 to the whole card, with the folder, after the
    checks and the typed confirmation. The old MBR goes first, then the
    FATs, the root and the folder, FSInfo and the copies, the boot sector,
    and the MBR last, so that a format that breaks off leaves a card with
    no FAT32 rather than a broken one."""
    check_names(folder, label)
    total = card.last + 1
    if card.protected():
        raise SdError(f"the card in slot {card.slot} is write-protected; "
                      "slide its switch away from LOCK first")
    print(f"The card in slot {card.slot}: {size_text(total)}, "
          f"{total} sectors")
    sector0 = card.read(0)
    for row in describe(card.read, card.last):
        print(row)
    lay = layout(total)
    if lay is None:
        raise SdError("the card is too small for FAT32, which needs "
                      f"{MIN_CLUSTERS} clusters")
    if system_partition(sector0) and not system:
        raise SdError(
            "the card has the MEGA65's system partition, which holds its "
            "own files; use the MEGA65's SD card utility on it, or give "
            "--system to erase it all the same")
    blank = all(x == 0 for x in sector0) or all(x == 0xFF for x in sector0)
    if not blank and not force:
        raise SdError("the card has been formatted, or holds data, and "
                      "format would erase all of it; give --force to erase "
                      "it all the same")
    print(f"It becomes FAT32 of {lay.clusters} clusters of "
          f"{lay.spc * 512} bytes, from sector {lay.base}, with the label "
          f"{label.upper()} and the folder {folder.upper()}.")
    zeros = NFATS * (lay.fatsz - 1) + 2 * (lay.spc - 1)
    if serial_port and zeros > 2000:
        print(f"It writes {zeros + 10} sectors; over the serial port that "
              "takes long, and --eth is much faster.")
    if not yes:
        try:
            typed = input(f"All of the card in slot {card.slot} is erased. "
                          "Type the slot's number to go on: ")
        except EOFError:
            typed = ""
        if typed.strip() != str(card.slot):
            raise SdError("not confirmed; the card is as it was")
    sec = format_sectors(lay, label, folder, int(time.time()) & 0xFFFFFFFF,
                         time.time())
    zero = bytes(512)
    # The old MBR or boot sector, and a GPT's header, so that a break
    # leaves no file system and no partitions
    card.write(0, zero)
    card.write(1, zero)
    sys.stdout.flush()
    progress = Progress(zeros)
    done = 0

    def step(n: int) -> None:
        progress(done + n)

    for k in range(NFATS):
        first = lay.fat + k * lay.fatsz
        card.write(first, sec["fat"])
        card.zero(first + 1, lay.fatsz - 1, step)
        done += lay.fatsz - 1
    for c, what in ((2, "root"), (3, "folder")):
        card.write(lay.cluster(c), sec[what])
        card.zero(lay.cluster(c) + 1, lay.spc - 1, step)
        done += lay.spc - 1
    card.write(lay.base + FSINFO, sec["info"])
    card.write(lay.base + BACKUP + FSINFO, sec["info"])
    card.write(lay.base + BACKUP, sec["boot"])
    card.write(lay.base, sec["boot"])
    card.write(0, sec["mbr"])
    vol = Volume(card.read, folder)
    print(f"Formatted: FAT32 with the folder {folder.upper()}, "
          f"{lay.clusters * lay.spc * 512 // 10 ** 6} MB free"
          if vol.dir else "Formatted, but the folder is missing")


DESCRIPTION = ("List, copy, write, and delete the files of the folder NICE "
               "on the board's SD card, over the debug link.")


def add_options(parser: argparse.ArgumentParser) -> None:
    """The options of nicemon.py sd, with its own subcommands."""
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
    cmds.add_parser("ls", help="list the folder, as BASIC's DIR does, "
                    "with the 8.3 names of the long names")
    get = cmds.add_parser("get", help="copy a file of the folder to the host")
    get.add_argument("name", help="its 8.3 name or its long name")
    get.add_argument("dest", nargs="?",
                     help="the file or the directory to write it to, or - "
                     "for stdout (default: its name, here)")
    put = cmds.add_parser("put", help="write a file of the host to the "
                          "folder; holds the core, and starts it again")
    put.add_argument("src", help="the host's file, or - for stdin")
    put.add_argument("name", nargs="?",
                     help="the name on the card, a long name or an 8.3 "
                     "name (default: SRC's name)")
    rm = cmds.add_parser("del", help="delete a file of the folder; holds "
                         "the core, and starts it again")
    rm.add_argument("name", help="its 8.3 name or its long name")
    cmds.add_parser("mkdir", help="make the folder in the root of the "
                    "card, unless it is there; holds the core, and starts "
                    "it again")
    fmt = cmds.add_parser("format", help="erase the whole card of --slot, "
                          "and write a new FAT32 with the folder; holds the "
                          "core, and starts it again")
    fmt.add_argument("--label", default=FOLDER,
                     help="the volume's label (default %(default)s)")
    fmt.add_argument("--force", action="store_true",
                     help="erase a card that has been formatted")
    fmt.add_argument("--system", action="store_true",
                     help="erase a card with the MEGA65's system partition "
                     "too")
    fmt.add_argument("--yes", action="store_true",
                     help="ask for no typed confirmation")


def command(parser: argparse.ArgumentParser, args: argparse.Namespace) -> None:
    """nicemon.py sd, on the options of add_options."""
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
                 "put SRC prog.bas")
    except OSError as e:
        sys.exit(f"sdcard.py: {e}")
    if args.cmd == "format":
        if args.slot is None:
            sys.exit("sdcard.py: format needs --slot, the slot of the card "
                     "to erase, such as --slot 1 format")
        try:
            check_names(args.folder, args.label)
        except FileError as e:
            sys.exit(f"sdcard.py: {e}")
        except SdError as e:
            sys.exit(f"sdcard.py: {e}")
    link = open_link(args)
    try:
        writes = args.cmd in ("put", "del", "mkdir", "format")
        with Card(link, args.slot, writes, args.hold) as card:
            if args.cmd == "format":
                do_format(card, args.folder, args.label, args.force,
                          args.system, args.yes,
                          getattr(args, "port", None) is not None)
                return
            vol = Volume(card.read, args.folder,
                         card.write if writes else None,
                         need=args.cmd != "mkdir")
            if args.cmd == "mkdir":
                folder = args.folder.upper()
                if vol.mkdir():
                    print(f"Made the folder {folder}")
                else:
                    print(f"The folder {folder} is there already")
            elif args.cmd == "ls":
                do_ls(vol)
            elif args.cmd == "get":
                do_get(vol, args.name, args.dest)
            elif args.cmd == "put":
                n = vol.put(name, data)
                print(f"{name}: {n} bytes written")
            else:
                gone = vol.delete(args.name)
                print(f"Deleted {gone.name}")
    except FileError as e:
        sys.exit(f"sdcard.py: {e}{HINTS.get(e.code, '')}")
    except (SdError, FolderError, LinkError, OSError) as e:
        sys.exit(f"sdcard.py: {e}")
    finally:
        link.close()


if __name__ == "__main__":
    # The old name, kept for one release (issue #156)
    import nicemon
    nicemon.main(["sd", *sys.argv[1:]])
