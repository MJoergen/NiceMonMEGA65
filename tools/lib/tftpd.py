"""A TFTP server for BASIC's LOAD, DIR, SAVE, and BSAVE, with listings.

It serves the regular files of one folder, --dir, and nothing below or
above it, nor through a symbolic link, to read requests (RFC 1350) in
octet mode, and in netascii mode as octet, as the .bin files are text
already. A name is found as it is, or else without regard to case, when
that matches one file. The options of RFC 2347 are ignored, as the RFC
allows, so blocks are 512 bytes. The block number goes round from 65535
to 0, as most clients expect. Each transfer has a socket of its own,
its TID, and a thread, and reads the file a block at a time as it sends
it: a block with no ACK within --retry-wait seconds is sent again, up to
--tries times in all, an ERROR from the client ends the transfer, as
RFC 1350 says, and a packet from another TID is answered with ERROR 5
and passed over. At most MAX_TRANSFERS, 16, run at once, so that a
flood of requests takes no more than that; one more gets ERROR 0.

The extension: a name with * or ? is a pattern, and the server answers
it with a text file made on the spot, the listing of the files that
match it as fnmatch matches, without regard to case, sorted by name, a
line each: the name, padded to 24 columns, a blank, and the size in
bytes in 10 columns, and LF. Files whose names start with a dot are
left out. A pattern that matches none gets ERROR 1. No file of the
systems it runs on has * or ? in its name, so the listing hides none,
and a standard client gets it as a file too: curl 'tftp://HOST/*'.

Names with /, \\, or .., a name starting with a dot, and an empty one
get ERROR 2; a missing file gets ERROR 1.

Write requests (WRQ), of BASIC's SAVE "NAME", "IP" and BSAVE "NAME", A,
N, "IP", get ERROR 2 unless --write allows them, as TFTP has no login:
anyone who reaches the port may write. With --write, a file is written
to the folder in octet mode, and in netascii mode as octet, under the
name of the request, or under that of the one file that has it in
another case, as the SD card's FAT32 would; a file that is there is
replaced, as SAVE to the card replaces it. A name with * or ?, and one
that is there as a directory or a symbolic link, get ERROR 2. The
blocks go to a temporary file in the folder, whose name starts with a
dot, so that it is neither served nor listed, and which is renamed to
the name at the end, so that a transfer that fails leaves no half
file: an ERROR from the client, such as BASIC's at the break key, or no
DATA within --tries times --retry-wait seconds, after each of which the
last ACK is sent again. A DATA of the block before gets its ACK again.
After the last ACK, the server waits DALLY seconds for that block
again, whose ACK was lost, and answers it with the ACK again (RFC 1350,
section 6).

Port 69, the default, needs root on Linux, or the capability:
sudo setcap cap_net_bind_service=+ep $(readlink -f $(which python3)).
Another port, such as --listen 6969, needs none, and BASIC reaches it
with LOAD "NAME.BIN", "IP:6969". --listen ADDR:PORT listens on one
address of the host's only. Port 0 picks a free port and prints it on
stderr, for tests. A line on stderr reports each transfer. Ctrl-C
stops the server, with exit status 130. Only the
Python standard library is used.
"""

import argparse
import fnmatch
import io
import os
import secrets
import socket
import struct
import threading
import time
from typing import BinaryIO, Optional, Tuple

from lib import cli

RRQ, WRQ, DATA, ACK, ERROR = 1, 2, 3, 4, 5
BLOCK = 512
NAME_WIDTH = 24
MAX_TRANSFERS = 16
DALLY = 3.0                             # the seconds the last ACK of a write is kept for

Addr = Tuple[str, int]


class Refused(Exception):
    """A request that gets an ERROR packet: its code and message."""

    def __init__(self, code: int, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class Ended(Exception):
    """The client's ERROR, which ends a transfer: what it said."""


def error_packet(code: int, message: str) -> bytes:
    return struct.pack(">HH", ERROR, code) + message.encode("ascii", "replace") + b"\0"


def parse_request(packet: bytes) -> Tuple[int, str, str]:
    """The opcode, the name, and the mode of an RRQ or WRQ; the options
    after them are ignored."""
    if len(packet) < 4:
        raise Refused(4, "Too short")
    op: int = struct.unpack(">H", packet[:2])[0]
    if op not in (RRQ, WRQ):
        raise Refused(4, "Not a request")
    fields = packet[2:].split(b"\0")
    if len(fields) < 3:
        raise Refused(4, "No name or mode")
    name = fields[0].decode("latin-1")
    mode = fields[1].decode("latin-1").lower()
    return op, name, mode


def served(folder: str, name: str) -> bool:
    """Whether name is a file the server gives out: a regular file of
    folder, not a symbolic link, whose name does not start with a dot."""
    path = os.path.join(folder, name)
    return (not name.startswith(".") and os.path.isfile(path)
            and not os.path.islink(path))


def listing(folder: str, pattern: str) -> bytes:
    """The text of the files of folder that match pattern."""
    names = []
    for name in os.listdir(folder):
        if (served(folder, name)
                and fnmatch.fnmatchcase(name.lower(), pattern.lower())):
            names.append(name)
    if not names:
        raise Refused(1, f"No file matches {pattern}")
    names.sort(key=str.lower)
    return b"".join(
        f"{name:<{NAME_WIDTH}} {os.path.getsize(os.path.join(folder, name)):>10}\n"
        .encode("utf-8", "replace") for name in names)


def check_name(name: str) -> None:
    """Refused unless name is that of a file in the folder."""
    if not name or name.startswith(".") or "/" in name or "\\" in name or ".." in name:
        raise Refused(2, "Only names of files in the folder")


def content(folder: str, name: str) -> Tuple[str, BinaryIO]:
    """The name served and the bytes of a request's name, the file open
    to read, or a listing, which the caller closes."""
    check_name(name)
    if "*" in name or "?" in name:
        return name, io.BytesIO(listing(folder, name))
    if not served(folder, name):
        same = [n for n in os.listdir(folder)
                if n.lower() == name.lower() and served(folder, n)]
        if len(same) != 1:
            raise Refused(1, "File not found")
        name = same[0]
    try:
        return name, open(os.path.join(folder, name), "rb")
    except OSError as e:
        raise Refused(2, e.strerror or "Cannot read") from None


def send_file(sock: socket.socket, client: Addr, src: BinaryIO, timeout: float,
              tries: int) -> Tuple[int, Optional[str]]:
    """src to client in blocks, read as they are sent, each sent again
    until its ACK comes. The bytes sent, and None when the last block's
    ACK came, or the reason the transfer ended before it."""
    sock.settimeout(timeout)
    n = sent = 0
    while True:
        chunk = src.read(BLOCK)         # the last block has less than 512
        n += 1
        block = n & 0xFFFF
        packet = struct.pack(">HH", DATA, block) + chunk
        for _ in range(tries):
            sock.sendto(packet, client)
            try:
                if wait_ack(sock, client, block):
                    break
            except Ended as e:
                return sent, str(e)
        else:
            return sent, f"no ACK of block {n}"
        sent += len(chunk)
        if len(chunk) < BLOCK:
            return sent, None


def wait_ack(sock: socket.socket, client: Addr, block: int) -> bool:
    """Whether the ACK of block comes from client before the timeout.
    ACKs of earlier blocks are passed over, so that a duplicate does not
    send a block again (the Sorcerer's Apprentice of RFC 1123). An ERROR
    from the client raises Ended."""
    while True:
        try:
            packet, addr = sock.recvfrom(BLOCK + 4)
        except socket.timeout:
            return False
        if addr != client:
            sock.sendto(error_packet(5, "Unknown transfer ID"), addr)
            continue
        if len(packet) < 4:
            continue
        op, n = struct.unpack(">HH", packet[:4])
        if op == ERROR:
            text = packet[4:].split(b"\0", 1)[0].decode("latin-1", "replace")
            raise Ended(f"the client's ERROR {n}, {text}")
        if op == ACK and n == block:
            return True


def target(folder: str, name: str) -> str:
    """The name that a write request's name is written to: itself, or
    the one file that has it in another case."""
    check_name(name)
    if "*" in name or "?" in name:
        raise Refused(2, "Not a name with * or ?")
    if not os.path.lexists(os.path.join(folder, name)):
        same = [n for n in os.listdir(folder)
                if n.lower() == name.lower() and served(folder, n)]
        if len(same) == 1:
            name = same[0]
    path = os.path.join(folder, name)
    if os.path.lexists(path) and not served(folder, name):
        raise Refused(2, "Not a file that may be replaced")
    return name


def receive_file(sock: socket.socket, client: Addr, folder: str, name: str,
                 timeout: float, tries: int) -> Tuple[int, Optional[str]]:
    """The blocks of client written to a temporary file of folder, which
    is renamed to name after the last. The bytes written, and None when
    the file is there, or the reason the transfer ended before it."""
    while True:                         # the umask applies, as to any new file
        temp = os.path.join(folder, f".tftpd-{secrets.token_hex(6)}")
        try:
            fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o666)
            break
        except FileExistsError:
            continue
    done = False
    try:
        with os.fdopen(fd, "wb") as dst:
            ack = struct.pack(">HH", ACK, 0)
            block = written = 0
            while True:
                try:
                    chunk = wait_data(sock, client, (block + 1) & 0xFFFF, ack,
                                      timeout, tries)
                except Ended as e:
                    return written, str(e)
                if chunk is None:
                    return written, f"no DATA of block {block + 1}"
                block += 1
                dst.write(chunk)
                written += len(chunk)
                ack = struct.pack(">HH", ACK, block & 0xFFFF)
                if len(chunk) < BLOCK:
                    break
        os.replace(temp, os.path.join(folder, name))
        done = True
        sock.sendto(ack, client)
        dally(sock, client, block & 0xFFFF, ack)
        return written, None
    finally:
        if not done:
            os.unlink(temp)


def wait_data(sock: socket.socket, client: Addr, block: int, ack: bytes,
              timeout: float, tries: int) -> Optional[bytes]:
    """ack sent, and the bytes of the DATA of block from client, sent
    again after each timeout, up to tries times in all, or None. A DATA
    of the block before gets ack again. An ERROR from the client raises
    Ended."""
    sock.settimeout(timeout)
    for _ in range(tries):
        sock.sendto(ack, client)
        while True:
            try:
                packet, addr = sock.recvfrom(BLOCK + 8)
            except socket.timeout:
                break
            if addr != client:
                sock.sendto(error_packet(5, "Unknown transfer ID"), addr)
                continue
            if len(packet) < 4:
                continue
            op, n = struct.unpack(">HH", packet[:4])
            if op == ERROR:
                text = packet[4:].split(b"\0", 1)[0].decode("latin-1", "replace")
                raise Ended(f"the client's ERROR {n}, {text}")
            if op != DATA:
                continue
            if n == block:
                if len(packet) > BLOCK + 4:
                    sock.sendto(error_packet(4, "A block of more than 512 bytes"), client)
                    raise Ended("a block of more than 512 bytes")
                return packet[4:]
            if n == (block - 1) & 0xFFFF:
                sock.sendto(ack, client)        # its ACK was lost
    return None


def dally(sock: socket.socket, client: Addr, block: int, ack: bytes) -> None:
    """ack sent again for each DATA of the last block that comes from
    client within DALLY seconds, as its ACK was lost."""
    end = time.monotonic() + DALLY
    while True:
        left = end - time.monotonic()
        if left <= 0:
            return
        sock.settimeout(left)
        try:
            packet, addr = sock.recvfrom(BLOCK + 8)
        except socket.timeout:
            return
        if (addr == client and len(packet) >= 4
                and struct.unpack(">HH", packet[:4]) == (DATA, block)):
            sock.sendto(ack, client)


def serve(client: Addr, packet: bytes, args: argparse.Namespace,
          lock: threading.Lock, slots: threading.BoundedSemaphore) -> None:
    """One request, on a socket of its own, in one of the slots."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.bind((args.listen[0], 0))
            name = "?"
            try:
                op, name, mode = parse_request(packet)
                if op == WRQ and not args.write:
                    raise Refused(2, "Writing is not allowed: tftpd --write allows it")
                if mode not in ("octet", "netascii"):
                    raise Refused(0, f"Mode {mode} is not supported")
                if op == WRQ:
                    name = target(args.dir, name)
                else:
                    name, src = content(args.dir, name)
            except Refused as e:
                sock.sendto(error_packet(e.code, e.message), client)
                report(lock, client, name, f"error {e.code}, {e.message}")
                return
            if op == WRQ:
                got, reason = receive_file(sock, client, args.dir, name,
                                           args.retry_wait, args.tries)
                report(lock, client, name, reason or f"{got} bytes written")
                return
            with src:
                sent, reason = send_file(sock, client, src, args.retry_wait, args.tries)
            report(lock, client, name, reason or f"{sent} bytes")
    finally:
        slots.release()


def report(lock: threading.Lock, client: Addr, name: str, what: str) -> None:
    with lock:
        cli.note(f"{client[0]}:{client[1]} {name}: {what}")


DESCRIPTION = ("Serve the files of a folder to BASIC's LOAD and DIR over "
               "TFTP, with listings, and with --write take SAVE's and "
               "BSAVE's.")


def add_options(parser: argparse.ArgumentParser) -> None:
    """The options of nicemon.py tftpd."""
    parser.add_argument("--dir", default=".", metavar="DIR",
                        help="the folder served (default .)")
    parser.add_argument("--listen", type=cli.listen_type("0.0.0.0"),
                        default="0.0.0.0:69",
                        metavar="[ADDR:]PORT",
                        help="where the server listens (default %(default)s, "
                        "all addresses; port 0 picks one, printed on stderr)")
    parser.add_argument("--retry-wait", type=float, default=1.0,
                        metavar="SEC",
                        help="the seconds to wait for an ACK before a block "
                        "is sent again (default 1)")
    parser.add_argument("--tries", type=int, default=5, metavar="N",
                        help="the sends of a block, or of an ACK, in all "
                        "(default 5)")
    parser.add_argument("--write", action="store_true",
                        help="take write requests, of SAVE and BSAVE, which "
                        "replace a file that is there; TFTP has no login, so "
                        "anyone who reaches the port may write")


def command(parser: argparse.ArgumentParser, args: argparse.Namespace) -> None:
    """nicemon.py tftpd, on the options of add_options."""
    if not os.path.isdir(args.dir):
        cli.fail(f"no folder {args.dir}")
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.bind(args.listen)
    except PermissionError:
        cli.fail(f"port {args.listen[1]} needs root, or the capability of "
                 "the header of tools/lib/tftpd.py; or use --listen 6969 "
                 "and LOAD \"NAME.BIN\", \"IP:6969\"")
    except OSError as e:
        cli.fail(f"{args.listen[0]}:{args.listen[1]}: {e}")
    port = sock.getsockname()[1]
    writes = ", writes allowed," if args.write else ""
    cli.note(f"serving {os.path.abspath(args.dir)}{writes} on port {port}")
    lock = threading.Lock()
    slots = threading.BoundedSemaphore(MAX_TRANSFERS)
    try:
        while True:
            packet, client = sock.recvfrom(BLOCK + 4)
            if not slots.acquire(blocking=False):
                sock.sendto(error_packet(0, "Too many transfers"), client)
                report(lock, client, "?", "error 0, too many transfers")
                continue
            threading.Thread(target=serve, args=(client, packet, args, lock, slots),
                             daemon=True).start()
    finally:
        sock.close()
