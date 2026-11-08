#!/usr/bin/env python3
"""A TFTP server for the monitor's tftp, with listings of its folder.

It serves the regular files of one folder, --dir, and nothing below or
above it, nor through a symbolic link, to read requests (RFC 1350) in
octet mode, and in netascii mode as octet, as the .bin files are text
already. A name is found as it is, or else without regard to case, when
that matches one file. The options of RFC 2347 are ignored, as the RFC
allows, so blocks are 512 bytes. The block number goes round from 65535
to 0, as most clients expect. Each transfer has a socket of its own,
its TID, and a thread, and reads the file a block at a time as it sends
it: a block with no ACK within --timeout seconds is sent again, up to
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

Write requests get ERROR 2, and so do names with /, \\, or .., a name
starting with a dot, and an empty one; a missing file gets ERROR 1.

Port 69, the default, needs root on Linux, or the capability:
sudo setcap cap_net_bind_service=+ep $(readlink -f $(which python3)).
Another port, such as --port 6969, needs none, and the monitor reaches
it with tftp IP:6969 NAME. --port 0 picks a free port and prints it on
stderr, for tests. A line on stdout reports each transfer. Only the
Python standard library is used.
"""

import argparse
import fnmatch
import io
import os
import socket
import struct
import sys
import threading
from typing import BinaryIO, Optional, Tuple

RRQ, WRQ, DATA, ACK, ERROR = 1, 2, 3, 4, 5
BLOCK = 512
NAME_WIDTH = 24
MAX_TRANSFERS = 16

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


def content(folder: str, name: str) -> Tuple[str, BinaryIO]:
    """The name served and the bytes of a request's name, the file open
    to read, or a listing, which the caller closes."""
    if not name or name.startswith(".") or "/" in name or "\\" in name or ".." in name:
        raise Refused(2, "Only names of files in the folder")
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


def serve(client: Addr, packet: bytes, args: argparse.Namespace,
          lock: threading.Lock, slots: threading.BoundedSemaphore) -> None:
    """One request, on a socket of its own, in one of the slots."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.bind((args.addr, 0))
            name = "?"
            try:
                op, name, mode = parse_request(packet)
                if op == WRQ:
                    raise Refused(2, "Writing is not supported")
                if mode not in ("octet", "netascii"):
                    raise Refused(0, f"Mode {mode} is not supported")
                name, src = content(args.dir, name)
            except Refused as e:
                sock.sendto(error_packet(e.code, e.message), client)
                report(lock, client, name, f"error {e.code}, {e.message}")
                return
            with src:
                sent, reason = send_file(sock, client, src, args.timeout, args.tries)
            report(lock, client, name, reason or f"{sent} bytes")
    finally:
        slots.release()


def report(lock: threading.Lock, client: Addr, name: str, what: str) -> None:
    with lock:
        print(f"{client[0]}:{client[1]} {name}: {what}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dir", default=".", help="the folder served (default .)")
    parser.add_argument("--addr", default="0.0.0.0",
                        help="the address to listen on (default all)")
    parser.add_argument("--port", type=int, default=69,
                        help="the port, 69 by default; 0 picks one, printed on stderr")
    parser.add_argument("--timeout", type=float, default=1.0,
                        help="the seconds to wait for an ACK (default 1)")
    parser.add_argument("--tries", type=int, default=5,
                        help="the sends of a block in all (default 5)")
    args = parser.parse_args()
    if not os.path.isdir(args.dir):
        sys.exit(f"tftpd.py: no folder {args.dir}")
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.bind((args.addr, args.port))
    except PermissionError:
        sys.exit(f"tftpd.py: port {args.port} needs root, or the capability of "
                 "the header (--help); or use --port 6969 and tftp IP:6969 NAME")
    port = sock.getsockname()[1]
    print(f"tftpd.py: serving {os.path.abspath(args.dir)} on port {port}",
          file=sys.stderr, flush=True)
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
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
