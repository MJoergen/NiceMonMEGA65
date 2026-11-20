#!/usr/bin/env python3
"""The board's SD card as a block device of the host, over the debug link.

An NBD server (the protocol of Linux's network block device,
https://github.com/NetworkBlockDevice/nbd/blob/master/doc/proto.md)
whose disk is the card in a slot of the board: each read and write of
the host is a read or write of the card's sectors through the SD
controller's registers at FFFFFFA0-AF, with sdcard.py's Card. Linux's
nbd-client connects /dev/nbd0 to it, and the kernel's own vfat mounts
the card's FAT32, every folder of it, as a folder of the host:

    tools/nicemon.py nbd --eth 192.168.1.65 &
    sudo modprobe nbd
    sudo nbd-client -N sd localhost /dev/nbd0
    sudo mount -o uid=$(id -u),gid=$(id -g) /dev/nbd0p1 /mnt
    ... copy files to and from /mnt ...
    sudo umount /mnt
    sudo nbd-client -d /dev/nbd0
    kill %1

/dev/nbd0p1 is the first partition of an MBR, and /dev/nbd0 itself is
the file system of a card without one.

The core is held from the start until the server ends, on Ctrl-C or
SIGTERM, and then started again from reset, as after sdcard.py's put:
the kernel keeps the card's FAT and folders in its own cache, so a
program that read the card at the same time would see it stale, and the
core keeps the program's own. A held core stays held. The server takes
one connection at a time, and another after it, for the whole time.

With --read-only, writes are refused, and the core is paused instead of
held, as for sdcard.py's ls, and goes on at the end: the card is the
paused program's, in its slot, which it must have started up. --hold
holds it anyway, so that any slot is read. Mount it with -o ro.

The kernel writes in its own order, not in the careful order of
sdcard.py's and monitor_fat.nasm's, so a link that breaks while a write is in
flight can leave the card's FAT inconsistent: unmount, which writes back
all that the kernel kept, before the server stops. The writes are made
when they come, so a flush has nothing to wait for.

On an R6, the card reads at about 115 KB a second over Ethernet and
writes at about 80 KB a second; over the serial port it is a hundred
times slower. Only the Python standard library is used.

Usage: tools/nicemon.py nbd (--eth HOST[:PORT] | --port DEVICE [--baud 230400]
                            | --tcp [HOST:]PORT | --cosim PORT)
                            [--slot N] [--read-only] [--hold]
                            [--listen [HOST:]PORT]
"""

from __future__ import annotations

import argparse
import signal
import socket
import struct
import sys
from types import FrameType

from boardlink import LinkError, add_arguments, open_link
import cli
from sdcard import Card, FileError, SdError

# The handshake (proto.md, "Fixed newstyle negotiation")
NBDMAGIC = b"NBDMAGIC"
IHAVEOPT = 0x49484156454F5054
REPLY_MAGIC = 0x0003E889045565A9
FLAG_FIXED_NEWSTYLE, FLAG_NO_ZEROES = 1, 2
# The options, and the replies to them
OPT_EXPORT_NAME, OPT_ABORT, OPT_LIST, OPT_INFO, OPT_GO = 1, 2, 3, 6, 7
REP_ACK, REP_SERVER, REP_INFO = 1, 2, 3
REP_ERR_UNSUP, REP_ERR_INVALID = 0x80000001, 0x80000003
INFO_EXPORT, INFO_BLOCK_SIZE = 0, 3
# The transmission flags of the export
TF_HAS_FLAGS, TF_READ_ONLY, TF_SEND_FLUSH = 1, 2, 4
# The requests of the transmission, and the simple reply
REQUEST_MAGIC, SIMPLE_MAGIC = 0x25609513, 0x67446698
CMD_READ, CMD_WRITE, CMD_DISC, CMD_FLUSH = 0, 1, 2, 3
EPERM, EIO, EINVAL = 1, 5, 22
# The largest request taken, as the block size info says
MAX_REQUEST = 32 * 1024 * 1024
# The port of NBD
NBD_PORT = 10809
SECTOR = 512


class Closed(Exception):
    """The client closed the connection."""


def recv_exact(conn: socket.socket, n: int) -> bytes:
    data = bytearray()
    while len(data) < n:
        got = conn.recv(n - len(data))
        if not got:
            raise Closed()
        data += got
    return bytes(data)


class Disk:
    """The card as bytes, from its sectors. A request that is not whole
    sectors reads the sectors at its ends, and writes them back with the
    request's bytes in them."""

    def __init__(self, card: Card, writable: bool) -> None:
        self.card = card
        self.writable = writable
        self.size = (card.last + 1) * SECTOR

    def read(self, offset: int, length: int) -> bytes:
        first, last = offset // SECTOR, (offset + length - 1) // SECTOR
        data = b"".join(self.card.read(lba)
                        for lba in range(first, last + 1))
        at = offset - first * SECTOR
        return data[at:at + length]

    def write(self, offset: int, data: bytes) -> None:
        pos = 0
        while pos < len(data):
            lba, at = divmod(offset + pos, SECTOR)
            n = min(SECTOR - at, len(data) - pos)
            if n == SECTOR:
                sector = data[pos:pos + SECTOR]
            else:
                b = bytearray(self.card.read(lba))
                b[at:at + n] = data[pos:pos + n]
                sector = bytes(b)
            self.card.write(lba, sector)
            pos += n


def opt_reply(conn: socket.socket, opt: int, kind: int,
              data: bytes = b"") -> None:
    conn.sendall(struct.pack(">QIII", REPLY_MAGIC, opt, kind, len(data))
                 + data)


def tflags(disk: Disk) -> int:
    return TF_HAS_FLAGS | TF_SEND_FLUSH | (0 if disk.writable
                                           else TF_READ_ONLY)


def negotiate(conn: socket.socket, disk: Disk) -> bool:
    """The handshake: True when the client goes on to the transmission,
    False when it aborts. The export has any name."""
    conn.sendall(NBDMAGIC + struct.pack(">QH", IHAVEOPT,
                                        FLAG_FIXED_NEWSTYLE | FLAG_NO_ZEROES))
    (cflags,) = struct.unpack(">I", recv_exact(conn, 4))
    if cflags & ~(FLAG_FIXED_NEWSTYLE | FLAG_NO_ZEROES):
        return False
    while True:
        magic, opt, n = struct.unpack(">QII", recv_exact(conn, 16))
        if magic != IHAVEOPT or n > 65536:
            return False
        data = recv_exact(conn, n)
        if opt == OPT_EXPORT_NAME:
            conn.sendall(struct.pack(">QH", disk.size, tflags(disk)) +
                         (b"" if cflags & FLAG_NO_ZEROES else bytes(124)))
            return True
        if opt == OPT_ABORT:
            opt_reply(conn, opt, REP_ACK)
            return False
        if opt == OPT_LIST:
            if n:
                opt_reply(conn, opt, REP_ERR_INVALID)
            else:
                opt_reply(conn, opt, REP_SERVER, struct.pack(">I", 0))
                opt_reply(conn, opt, REP_ACK)
        elif opt in (OPT_INFO, OPT_GO):
            if n < 6:
                opt_reply(conn, opt, REP_ERR_INVALID)
                continue
            (name_len,) = struct.unpack(">I", data[:4])
            if 4 + name_len + 2 > n:
                opt_reply(conn, opt, REP_ERR_INVALID)
                continue
            (count,) = struct.unpack(">H", data[4 + name_len:6 + name_len])
            if 6 + name_len + 2 * count > n:
                opt_reply(conn, opt, REP_ERR_INVALID)
                continue
            reqs = struct.unpack(f">{count}H",
                                 data[6 + name_len:6 + name_len + 2 * count])
            opt_reply(conn, opt, REP_INFO,
                      struct.pack(">HQH", INFO_EXPORT, disk.size,
                                  tflags(disk)))
            if INFO_BLOCK_SIZE in reqs:
                opt_reply(conn, opt, REP_INFO,
                          struct.pack(">HIII", INFO_BLOCK_SIZE, SECTOR,
                                      4096, MAX_REQUEST))
            opt_reply(conn, opt, REP_ACK)
            if opt == OPT_GO:
                return True
        else:
            opt_reply(conn, opt, REP_ERR_UNSUP)


def transmit(conn: socket.socket, disk: Disk) -> None:
    """The requests until the client disconnects."""
    while True:
        magic, _, kind, cookie, offset, length = struct.unpack(
            ">IHHQQI", recv_exact(conn, 28))
        if magic != REQUEST_MAGIC:
            raise Closed()
        if kind == CMD_WRITE and length > MAX_REQUEST:
            # Its data is not read, so the connection ends with the reply
            conn.sendall(struct.pack(">IIQ", SIMPLE_MAGIC, EINVAL, cookie))
            raise Closed()
        data = recv_exact(conn, length) if kind == CMD_WRITE else b""
        if kind == CMD_DISC:
            return
        error, out = 0, b""
        if kind in (CMD_READ, CMD_WRITE):
            if offset + length > disk.size or length > MAX_REQUEST:
                error = EINVAL
            elif kind == CMD_WRITE and not disk.writable:
                error = EPERM
            elif length:
                try:
                    if kind == CMD_READ:
                        out = disk.read(offset, length)
                    else:
                        disk.write(offset, data)
                except (SdError, LinkError, OSError) as e:
                    cli.warn(str(e))
                    error, out = EIO, b""
        elif kind != CMD_FLUSH:
            error = EINVAL
        conn.sendall(struct.pack(">IIQ", SIMPLE_MAGIC, error, cookie) + out)


def serve(server: socket.socket, disk: Disk) -> None:
    """One connection after another, until the server is stopped. A
    signal that comes just before accept() blocks would wait for the next
    connection, so accept() waits a second at a time, and Python runs the
    handler of SIGTERM or Ctrl-C in between."""
    server.settimeout(1.0)
    while True:
        try:
            conn, peer = server.accept()
        except TimeoutError:
            continue
        cli.note(f"{peer[0]}:{peer[1]} connected")
        with conn:
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            try:
                if negotiate(conn, disk):
                    transmit(conn, disk)
            except (Closed, ConnectionError):
                pass
        cli.note(f"{peer[0]}:{peer[1]} disconnected")


def listen_on(where: tuple[str, int]) -> socket.socket:
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        server.bind(where)
    except OSError as e:
        cli.fail(f"{where[0]}:{where[1]}: {e}")
    server.listen(1)
    return server


class Stopped(Exception):
    """SIGTERM, which stops the server as Ctrl-C does, but exits 0."""


def stop(signum: int, frame: FrameType | None) -> None:
    raise Stopped()


DESCRIPTION = ("Serve the board's SD card over NBD, for nbd-client and a "
               "mount of its file system on the host.")


def add_options(parser: argparse.ArgumentParser) -> None:
    """The options of nicemon.py nbd."""
    add_arguments(parser)
    parser.add_argument("--slot", type=int, metavar="N",
                        help="the slot of the card (default 0, or 1 when 0 "
                        "has no card); with --read-only and no --hold, a "
                        "paused program's slot")
    parser.add_argument("--read-only", action="store_true",
                        help="refuse writes, and pause the core instead of "
                        "holding it")
    parser.add_argument("--hold", action="store_true",
                        help="with --read-only: hold the core all the same, "
                        "and start it again from reset at the end")
    parser.add_argument("--listen", default=f"127.0.0.1:{NBD_PORT}",
                        type=cli.listen_type("127.0.0.1"),
                        metavar="[HOST:]PORT",
                        help="where the server listens (default "
                        "%(default)s; port 0 picks a free one)")


def command(parser: argparse.ArgumentParser, args: argparse.Namespace) -> None:
    """nicemon.py nbd, on the options of add_options."""
    server = listen_on(args.listen)
    signal.signal(signal.SIGTERM, stop)
    link = open_link(args)
    interrupted = False
    try:
        writable = not args.read_only
        with Card(link, args.slot, writable, args.hold) as card:
            disk = Disk(card, writable)
            host, port = server.getsockname()
            cli.note(f"slot {card.slot}, {disk.size // SECTOR} sectors, "
                     f"{'read-only' if not writable else 'writable'}, "
                     f"on {host}:{port}")
            cli.note(f"sudo nbd-client -N sd {host} {port} /dev/nbd0")
            try:
                serve(server, disk)
            except KeyboardInterrupt:
                interrupted = True
                cli.note("stopped")
            except Stopped:
                cli.note("stopped")
    except (SdError, FileError, LinkError, OSError) as e:
        cli.fail(str(e))
    finally:
        server.close()
        link.close()
    if interrupted:
        sys.exit(cli.EXIT_INTERRUPT)


if __name__ == "__main__":
    # The old name, kept for one release (issue #156)
    import nicemon
    nicemon.old_name("nbd", sys.argv[1:])
