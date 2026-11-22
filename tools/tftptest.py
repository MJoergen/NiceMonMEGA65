#!/usr/bin/env python3
"""Check nicemon.py tftpd, and BASIC's TFTP against it, without a board.

First it starts nicemon.py tftpd --listen 127.0.0.1:0 on a folder of test files and checks
it with a client of its own: files of 0, 511, 512, 513, and 140,000
bytes, more than 255 blocks; a name in another case; the listing of *
and of *.BIN; a pattern that matches none, a missing file, names outside
the folder, a symbolic link to a file outside it, which the listing
leaves out too, a write request, and a mode other than octet, each with
its ERROR; a lost ACK, after which the block comes again; a duplicate
ACK, which sends nothing again; a packet from another port, which gets
ERROR 5 while the transfer goes on; and an ERROR from the client, after
which nothing comes again.

Then it starts a second server, with --write, on a folder of its own
with the same files, and writes to it (issue #155): files of 0, 511,
512, 513, and 140,000 bytes; a file that is there, which is replaced,
and one that is there in another case, whose name is kept; names
outside the folder, with * or ?, of a directory, and a mode other than
octet, each with its ERROR; a lost DATA, after which the ACK comes
again, a DATA sent twice, whose ACK comes again, and the last DATA sent
again after its ACK, as when that ACK is lost, which is answered too; a
packet from another port, which gets ERROR 5; an ERROR from the client,
and a client that stops, after which no file is there, neither the
name nor a temporary file. curl -T writes a file too, when curl has
TFTP.

Then it runs the ROM of the tests, build/rom_test.bin, in
niceemu with --eth-udp and --eth-peer, whose frames go to a bridge in
this script: the bridge answers ARP for the server 10.0.0.2, and passes
the UDP datagrams to 10.0.0.2 on to tftpd.py on 127.0.0.1, port 69 to
the server's port, and back, so that niceemu and tftpd.py are on one
network. BASIC lists the folder of the server with --write with DIR,
loads a program of 300 lines with LOAD, which DUMP then shows, gets an
ERROR, and loads a file of lines that are skipped, passed over, and
loaded. Then it saves a program of two lines with SAVE, and 300, 256,
and 0 words with BSAVE, which are files of 5400, 4608, and 0 bytes,
the second of 9 full blocks, and the last of none, and loads the
program back; and SAVE to the server without --write gets its ERROR.
Its output must have the lines that the checks name, and the files
must be on the host.

It prints a line for each check, and last how many passed, and exits with
status 1 when one fails. niceemu must be built, with make -C
nice_cpu/emulator build, and so must the ROM of the tests, with make
build/rom_test.bin. Only the Python standard library is used.
"""

import os
import selectors
import socket
import struct
import subprocess
import sys
import tempfile
import threading
from typing import Dict, List, Optional, Tuple

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NICEEMU = os.path.join(REPO, "nice_cpu", "emulator", "zig-out", "bin", "niceemu")
MONITOR = os.path.join(REPO, "build", "rom_test.bin")
TFTPD = [sys.executable, os.path.join(REPO, "tools", "nicemon.py"), "tftpd"]

SERVER_IP = bytes([10, 0, 0, 2])
SERVER_MAC = bytes.fromhex("0A0000000002")
TIMEOUT = 0.3                            # tftpd.py's, so that a lost ACK is quick
LINK = "link.bin"                        # a symbolic link out of the folder, if one can be made

passed = 0
failed = 0
linked = False


def check(name: str, ok: bool, detail: str = "") -> None:
    global passed, failed
    print(f"[{'PASS' if ok else 'FAIL'}] {name}" + ("" if ok or not detail else f": {detail}"))
    if ok:
        passed += 1
    else:
        failed += 1


# The files of the folder served
def prog() -> bytes:
    """300 lines that write 9000 to 912B."""
    return b"".join(f"{0x9000 + i:08X} {i * 3:08X}\n".encode() for i in range(300))


def lines_bin() -> bytes:
    """Lines of issue #151's L1 and L2: A000, A006, and A007 load, a line
    of blanks only is passed over, and five are skipped from line 2: a
    DEL, a NUL, a byte from 0x80, a control code, and text after 80
    blanks. The 100 blanks after A006's word are dropped."""
    return b"".join([b"A000 1\n", b"A001 2\x7f\n", b"A002 3\x00\n", b"A003 4\x80\n",
                     b"A004\x01 5\n", b" " * 100 + b"\n", b" " * 80 + b"A005 6\n",
                     b"A006 7" + b" " * 100 + b"\n", b"A007 8\r\n"])


FILES = {
    "empty.bin": b"",
    "f511.bin": (bytes(range(256)) * 2)[:511],
    "f512.bin": (bytes(range(256)) * 2)[:512],
    "f513.txt": (bytes(range(256)) * 3)[:513],
    "big.dat": bytes((i * 7) & 0xFF for i in range(140_000)),
    "prog.bin": prog(),
    "lines.bin": lines_bin(),
    ".hidden": b"secret",
}


def request(op: int, name: str, mode: str = "octet") -> bytes:
    return struct.pack(">H", op) + name.encode() + b"\0" + mode.encode() + b"\0"


Result = Tuple[str, bytes, int]         # "data" or "error", the bytes or message, the code
Addr = Tuple[str, int]


def get(port: int, name: str, mode: str = "octet", op: int = 1) -> Result:
    """A file, or an ERROR, from tftpd.py at port."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(5)
        sock.sendto(request(op, name, mode), ("127.0.0.1", port))
        data = b""
        expect = 1
        while True:
            packet, addr = sock.recvfrom(1024)
            op_, n = struct.unpack(">HH", packet[:4])
            if op_ == 5:
                return "error", packet[4:].rstrip(b"\0"), n
            if n == expect:
                data += packet[4:]
                expect = (expect + 1) & 0xFFFF
            sock.sendto(struct.pack(">HH", 4, n), addr)
            if len(packet) < 516:
                return "data", data, 0


def test_server(port: int) -> None:
    for name, content in FILES.items():
        if name.startswith("."):
            continue
        res = get(port, name)
        check(f"tftpd {name}, {len(content)} bytes", res == ("data", content, 0),
              str(res)[:80])
    res = get(port, "PROG.BIN")
    check("tftpd PROG.BIN, prog.bin in another case", res == ("data", FILES["prog.bin"], 0))
    res = get(port, "prog.bin", "netascii")
    check("tftpd netascii, as octet", res == ("data", FILES["prog.bin"], 0))
    names = sorted((n for n in FILES if not n.startswith(".")), key=str.lower)
    text = b"".join(f"{n:<24} {len(FILES[n]):>10}\n".encode() for n in names)
    res = get(port, "*")
    check("tftpd *, the listing", res == ("data", text, 0), str(res)[:200])
    text = b"".join(f"{n:<24} {len(FILES[n]):>10}\n".encode() for n in names
                    if n.endswith(".bin"))
    res = get(port, "*.BIN")
    check("tftpd *.BIN, the listing of the .bin files", res == ("data", text, 0))
    res = get(port, "f51?.*")
    check("tftpd f51?.*, ? and *", res[0] == "data" and res[1].count(b"\n") == 3)
    for name, op, mode, code in (("*.xyz", 1, "octet", 1), ("nosuch.bin", 1, "octet", 1),
                                 ("../tftpd.py", 1, "octet", 2), ("a/b", 1, "octet", 2),
                                 (".hidden", 1, "octet", 2), ("", 1, "octet", 2),
                                 ("new.bin", 2, "octet", 2), ("prog.bin", 1, "mail", 0)):
        res = get(port, name, mode, op)
        check(f"tftpd {'WRQ' if op == 2 else 'RRQ'} {name!r} {mode}: ERROR {code}",
              res[0] == "error" and res[2] == code, str(res))
    if linked:
        res = get(port, LINK)
        check("tftpd a symbolic link out of the folder: ERROR 1",
              res[0] == "error" and res[2] == 1, str(res))
    test_lost(port)
    test_abort(port)


def test_lost(port: int) -> None:
    """A lost ACK, a duplicate ACK, and another TID, on big.dat."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock, \
            socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as other:
        sock.settimeout(5)
        other.settimeout(5)
        sock.sendto(request(1, "big.dat"), ("127.0.0.1", port))
        packet, addr = sock.recvfrom(1024)
        first = packet
        packet, addr2 = sock.recvfrom(1024)   # no ACK: block 1 again
        check("tftpd a lost ACK: the block again", packet == first and addr2 == addr)
        sock.sendto(struct.pack(">HH", 4, 1), addr)
        packet, _ = sock.recvfrom(1024)
        sock.sendto(struct.pack(">HH", 4, 1), addr)  # a duplicate ACK of 1
        sock.sendto(struct.pack(">HH", 4, 2), addr)
        packet, _ = sock.recvfrom(1024)
        check("tftpd a duplicate ACK: block 3 next, not 2 again",
              struct.unpack(">HH", packet[:4]) == (3, 3))
        other.sendto(struct.pack(">HH", 4, 3), addr)
        packet, _ = other.recvfrom(1024)
        check("tftpd another TID: ERROR 5", struct.unpack(">HH", packet[:4]) == (5, 5))
        sock.sendto(struct.pack(">HH", 4, 3), addr)
        packet, _ = sock.recvfrom(1024)
        check("tftpd after another TID: block 4",
              struct.unpack(">HH", packet[:4]) == (3, 4))
        sock.sendto(struct.pack(">HH", 5, 0) + b"done\0", addr)  # the end


def test_abort(port: int) -> None:
    """An ERROR from the client ends the transfer: the block does not come
    again, as it would after a lost ACK."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(5)
        sock.sendto(request(1, "big.dat"), ("127.0.0.1", port))
        packet, addr = sock.recvfrom(1024)
        sock.sendto(struct.pack(">HH", 5, 3) + b"Disk full\0", addr)
        sock.settimeout(3 * TIMEOUT)
        try:
            packet, _ = sock.recvfrom(1024)
            check("tftpd an ERROR from the client: nothing more", False,
                  f"got {struct.unpack('>HH', packet[:4])}")
        except socket.timeout:
            check("tftpd an ERROR from the client: nothing more", True)


def put(port: int, name: str, content: bytes, mode: str = "octet") -> Result:
    """content written to tftpd.py at port as name: ("data", b"", 0), or
    an ERROR."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(5)
        sock.sendto(request(2, name, mode), ("127.0.0.1", port))
        res, addr = expect_ack(sock, 0)
        if res is not None:
            return res
        for n in range(len(content) // 512 + 1):
            sock.sendto(struct.pack(">HH", 3, (n + 1) & 0xFFFF)
                        + content[512 * n:512 * (n + 1)], addr)
            res, _ = expect_ack(sock, (n + 1) & 0xFFFF)
            if res is not None:
                return res
        return "data", b"", 0


def expect_ack(sock: socket.socket, block: int) -> Tuple[Optional[Result], Addr]:
    """None and the server's address when the ACK of block comes, which
    passes over others; or an ERROR."""
    while True:
        packet, addr = sock.recvfrom(1024)
        op, n = struct.unpack(">HH", packet[:4])
        if op == 5:
            return ("error", packet[4:].rstrip(b"\0"), n), addr
        if op == 4 and n == block:
            return None, addr


def temps(folder: str) -> List[str]:
    return [n for n in os.listdir(folder) if n.startswith(".tftpd-")]


def test_write(port: int, folder: str) -> None:
    """The writes of tftpd.py --write to folder, whose files are FILES."""
    for size in (0, 511, 512, 513, 140_000):
        content = bytes((i * 5 + size) & 0xFF for i in range(size))
        name = f"put{size}.bin"
        res = put(port, name, content)
        with open(os.path.join(folder, name), "rb") as f:
            got = f.read()
        check(f"tftpd --write {name}, {size} bytes", res == ("data", b"", 0) and got == content,
              str(res)[:80])
    res = put(port, "f512.bin", b"replaced\n")
    with open(os.path.join(folder, "f512.bin"), "rb") as f:
        check("tftpd --write f512.bin, which is there: replaced", f.read() == b"replaced\n",
              str(res))
    res = put(port, "PROG.BIN", b"00009000 00000001\n")
    with open(os.path.join(folder, "prog.bin"), "rb") as f:
        check("tftpd --write PROG.BIN: prog.bin replaced, with its name",
              f.read() == b"00009000 00000001\n" and "PROG.BIN" not in os.listdir(folder),
              str(res))
    os.mkdir(os.path.join(folder, "sub"))
    for name, mode, code in (("a/b", "octet", 2), (".x", "octet", 2), ("", "octet", 2),
                             ("../x.bin", "octet", 2), ("*.bin", "octet", 2),
                             ("a?.bin", "octet", 2), ("sub", "octet", 2),
                             ("x.bin", "mail", 0)):
        res = put(port, name, b"x", mode)
        check(f"tftpd --write WRQ {name!r} {mode}: ERROR {code}",
              res[0] == "error" and res[2] == code, str(res))
    check("tftpd --write the refused names: no file",
          not os.path.exists(os.path.join(folder, "x.bin"))
          and not os.path.exists(os.path.join(os.path.dirname(folder), "x.bin")))
    test_write_lost(port, folder)
    test_write_end(port, folder)


def test_write_lost(port: int, folder: str) -> None:
    """A lost DATA, a DATA twice, a lost last ACK, and another TID."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock, \
            socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as other:
        sock.settimeout(5)
        other.settimeout(5)
        sock.sendto(request(2, "lost.bin"), ("127.0.0.1", port))
        packet, addr = sock.recvfrom(1024)
        first = packet
        packet, addr2 = sock.recvfrom(1024)   # no DATA 1: ACK 0 again
        check("tftpd --write a lost DATA: the ACK again",
              packet == first == struct.pack(">HH", 4, 0) and addr2 == addr)
        block1, block2 = bytes(range(256)) * 2, b"the end\n"
        sock.sendto(struct.pack(">HH", 3, 1) + block1, addr)
        packet, _ = sock.recvfrom(1024)
        sock.sendto(struct.pack(">HH", 3, 1) + block1, addr)
        packet, _ = sock.recvfrom(1024)
        check("tftpd --write DATA 1 twice: ACK 1 again", packet == struct.pack(">HH", 4, 1))
        other.sendto(struct.pack(">HH", 3, 2) + b"other\n", addr)
        packet, _ = other.recvfrom(1024)
        check("tftpd --write another TID: ERROR 5", struct.unpack(">HH", packet[:4]) == (5, 5))
        sock.sendto(struct.pack(">HH", 3, 2) + block2, addr)
        packet, _ = sock.recvfrom(1024)
        sock.sendto(struct.pack(">HH", 3, 2) + block2, addr)  # as if ACK 2 was lost
        packet2, _ = sock.recvfrom(1024)
        check("tftpd --write the last DATA again: ACK 2 again",
              packet == packet2 == struct.pack(">HH", 4, 2))
    with open(os.path.join(folder, "lost.bin"), "rb") as f:
        check("tftpd --write lost.bin, after the losses", f.read() == block1 + block2)


def test_write_end(port: int, folder: str) -> None:
    """An ERROR from the client, and a client that stops: no file."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(5)
        sock.sendto(request(2, "abort.bin"), ("127.0.0.1", port))
        packet, addr = sock.recvfrom(1024)
        sock.sendto(struct.pack(">HH", 3, 1) + bytes(512), addr)
        packet, _ = sock.recvfrom(1024)
        sock.sendto(struct.pack(">HH", 5, 0) + b"Break\0", addr)
        sock.sendto(request(2, "stop.bin"), ("127.0.0.1", port))
        acks = 0
        sock.settimeout(3 * TIMEOUT)
        try:
            while True:
                packet, _ = sock.recvfrom(1024)
                acks += packet == struct.pack(">HH", 4, 0)
        except socket.timeout:
            pass
    check("tftpd --write a client that stops: ACK 0 sent 5 times", acks == 5, str(acks))
    check("tftpd --write an ERROR from the client, and a client that stops: no file",
          not os.path.exists(os.path.join(folder, "abort.bin"))
          and not os.path.exists(os.path.join(folder, "stop.bin")) and not temps(folder),
          str(os.listdir(folder)))


def test_curl(port: int, folder: str, tmp: str) -> None:
    """curl -T, a standard client, when it has TFTP."""
    try:
        res = subprocess.run(["curl", "-V"], capture_output=True, text=True)
    except OSError:
        res = None
    if res is None or " tftp" not in res.stdout:
        print("[SKIP] tftpd --write curl -T: no curl with TFTP")
        return
    src = os.path.join(tmp, "curl.bin")
    content = bytes((i * 11) & 0xFF for i in range(1300))
    with open(src, "wb") as f:
        f.write(content)
    res = subprocess.run(["curl", "-sS", "-T", src, f"tftp://127.0.0.1:{port}/curl.bin"],
                         capture_output=True, text=True)
    with open(os.path.join(folder, "curl.bin"), "rb") as f:
        check("tftpd --write curl -T curl.bin, 1300 bytes",
              res.returncode == 0 and f.read() == content, res.stderr)


# The bridge between niceemu's frames and the host's UDP
def checksum(header: bytes) -> int:
    total: int = sum(struct.unpack(f">{len(header) // 2}H", header))
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return ~total & 0xFFFF


class Bridge:
    """ARP for SERVER_IP, and UDP to it passed to 127.0.0.1."""

    def __init__(self, server_port: int) -> None:
        self.server_port = server_port
        self.emu = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.emu.bind(("127.0.0.1", 0))
        self.emu_port = 0               # niceemu's, set before run
        self.sel = selectors.DefaultSelector()
        self.sel.register(self.emu, selectors.EVENT_READ, None)
        self.hosts: Dict[int, socket.socket] = {}  # the board's port: a socket
        self.board_mac = b""
        self.board_ip = b""
        self.stop = False

    def to_emu(self, frame: bytes) -> None:
        self.emu.sendto(frame, ("127.0.0.1", self.emu_port))

    def run(self) -> None:
        while not self.stop:
            for key, _ in self.sel.select(0.1):
                if key.data is None:
                    self.from_emu(self.emu.recv(2048))
                else:
                    sock: socket.socket = key.fileobj  # type: ignore[assignment]
                    data, addr = sock.recvfrom(2048)
                    self.from_host(key.data, data, addr[1])

    def from_emu(self, f: bytes) -> None:
        kind = f[12:14]
        if kind == b"\x08\x06" and f[20:22] == b"\x00\x01" and f[38:42] == SERVER_IP:
            self.to_emu(f[6:12] + SERVER_MAC + b"\x08\x06" + bytes.fromhex("0001080006040002")
                        + SERVER_MAC + SERVER_IP + f[22:28] + f[28:32])
            return
        if kind != b"\x08\x00" or f[23] != 17 or f[30:34] != SERVER_IP:
            return
        ihl = (f[14] & 15) * 4
        u = 14 + ihl
        sport, dport, ulen = struct.unpack(">HHH", f[u:u + 6])
        self.board_mac, self.board_ip = f[6:12], f[26:30]
        if sport not in self.hosts:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.bind(("127.0.0.1", 0))
            self.hosts[sport] = sock
            self.sel.register(sock, selectors.EVENT_READ, sport)
        to = self.server_port if dport == 69 else dport
        self.hosts[sport].sendto(f[u + 8:u + ulen], ("127.0.0.1", to))

    def from_host(self, board_port: int, data: bytes, port: int) -> None:
        sport = 69 if port == self.server_port else port
        udp = struct.pack(">HHHH", sport, board_port, 8 + len(data), 0) + data
        hdr = struct.pack(">BBHHHBBH4s4s", 0x45, 0, 20 + len(udp), 0, 0, 64, 17, 0,
                          SERVER_IP, self.board_ip)
        hdr = hdr[:10] + struct.pack(">H", checksum(hdr)) + hdr[12:]
        self.to_emu(self.board_mac + SERVER_MAC + b"\x08\x00" + hdr + udp)


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.bind(("127.0.0.1", 0))
        port: int = s.getsockname()[1]
        return port


def test_monitor(server_port: int, folder: str, readonly: str, ro_port: int,
                 tmp: str) -> None:
    bridge = Bridge(server_port)
    bridge.emu_port = free_port()
    thread = threading.Thread(target=bridge.run, daemon=True)
    thread.start()
    inp = os.path.join(tmp, "input")
    with open(inp, "w") as f:
        f.write('IP "10.0.0.9"\rDIR "10.0.0.2"\rLOAD "PROG.BIN", "10.0.0.2"\r'
                'DUMP 0x9000, 4\rDUMP 0x912B, 1\rLOAD "nosuch.bin", "10.0.0.2"\r'
                'LOAD "lines.bin", "10.0.0.2"\rDUMP 0xA000, 8\rNEW\r'
                '10 PRINT "SAVED"\r20 END\rSAVE "hi", "10.0.0.2"\r'
                'BSAVE "words", 0x9000, 300, "10.0.0.2"\r'
                'BSAVE "w256", 0x9000, 256, "10.0.0.2"\rBSAVE "w0", 0x9000, 0, "10.0.0.2"\r'
                f'SAVE "ro", "10.0.0.2:{ro_port}"\rNEW\rLOAD "hi", "10.0.0.2"\rLIST\r'
                'HALT\r')
    try:
        res = subprocess.run(
            [NICEEMU, "-i", inp, "--eth-udp", f"127.0.0.1:{bridge.emu_port}",
             "--eth-peer", f"127.0.0.1:{bridge.emu.getsockname()[1]}", MONITOR],
            capture_output=True, timeout=120)
        out = res.stdout.decode("latin-1").replace("\r", "")
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode("latin-1").replace("\r", "")
        check("monitor: niceemu halts", False, "timeout")
    bridge.stop = True
    thread.join()
    lines = out.split("\n")
    want = [f"{n:<24} {len(FILES[n]):>10}" for n in
            sorted((n for n in FILES if not n.startswith(".")), key=str.lower)]
    listed = 'DIR "10.0.0.2"'
    at = lines.index(listed) + 1 if listed in lines else -1
    check("monitor: DIR \"10.0.0.2\" lists the folder",
          at > 0 and lines[at:at + len(want)] == want, "\n".join(lines[at:at + 9]))
    for line in ("Words loaded: 300, 00009000 to 0000912B",
                 "00009000 00000000 00000003 00000006 00000009",
                 "0000912B 00000381",
                 "TFTP error 1, File not found",
                 "Words loaded: 3, 0000A000 to 0000A007",
                 "0000A000 00000001 00000000 00000000 00000000",
                 "0000A004 00000000 00000000 00000007 00000008",
                 "Words saved: 300, 00009000 to 0000912B",
                 "Words saved: 256, 00009000 to 000090FF",
                 "Words saved: 0",
                 "TFTP error 2, Writing is not allowed: tftpd --write allows it",
                 '10 PRINT "SAVED"',
                 "20 END"):
        check(f"monitor: {line}", line in lines, out[-600:])
    words = b"".join(f"{0x9000 + i:08x} {i * 3:08x}\n".encode() for i in range(300))
    for name, content in (("hi.BAS", b'10 PRINT "SAVED"\n20 END\n'), ("words.BIN", words),
                          ("w256.BIN", words[:256 * 18]), ("w0.BIN", b"")):
        path = os.path.join(folder, name)
        got = open(path, "rb").read() if os.path.exists(path) else None
        check(f"monitor: SAVE and BSAVE {name}, {len(content)} bytes, on the host",
              got == content, str(got)[:80])
    check("monitor: SAVE to the server without --write: no file",
          not any(n.lower().startswith("ro.") for n in os.listdir(readonly)))
    check("monitor: LOAD lines.bin skips 5 lines from line 2",
          any(x.startswith("Lines skipped: 5, first line 2;") for x in lines), out[-600:])


def start(servers: List["subprocess.Popen[str]"], folder: str, *opts: str) -> int:
    """tftpd.py on folder, added to servers: its port."""
    server = subprocess.Popen(
        [*TFTPD, "--dir", folder, "--listen", "127.0.0.1:0",
         "--retry-wait", str(TIMEOUT), *opts],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    servers.append(server)
    assert server.stderr is not None
    line = server.stderr.readline()
    # The reports of the transfers, which would fill the pipe
    threading.Thread(target=server.stderr.read, daemon=True).start()
    return int(line.split()[-1])


def main() -> None:
    for path, how in ((NICEEMU, "make -C nice_cpu/emulator build"),
                      (MONITOR, "make build/rom_test.bin")):
        if not os.path.exists(path):
            sys.exit(f"tftptest.py: no {path}; {how} builds it")
    with tempfile.TemporaryDirectory() as tmp:
        folder = os.path.join(tmp, "srv")
        os.mkdir(folder)
        for name, content in FILES.items():
            with open(os.path.join(folder, name), "wb") as f:
                f.write(content)
        outside = os.path.join(tmp, "outside.bin")
        with open(outside, "wb") as f:
            f.write(b"not served\n")
        global linked
        try:
            os.symlink(outside, os.path.join(folder, LINK))
            linked = True
        except (OSError, NotImplementedError):
            pass
        wfolder = os.path.join(tmp, "wsrv")
        os.mkdir(wfolder)
        for name, content in FILES.items():
            with open(os.path.join(wfolder, name), "wb") as f:
                f.write(content)
        servers: List["subprocess.Popen[str]"] = []
        try:
            port = start(servers, folder)
            wport = start(servers, wfolder, "--write")
            test_server(port)
            test_monitor(wport, wfolder, folder, port, tmp)
            test_write(wport, wfolder)
            test_curl(wport, wfolder, tmp)
        finally:
            for server in servers:
                server.terminate()
                server.wait()
    print(f"{passed} of {passed + failed} checks passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
