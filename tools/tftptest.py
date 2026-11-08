#!/usr/bin/env python3
"""Check tools/tftpd.py, and the monitor's tftp against it, without a board.

First it starts tftpd.py --port 0 on a folder of test files and checks
it with a client of its own: files of 0, 511, 512, 513, and 140,000
bytes, more than 255 blocks; a name in another case; the listing of *
and of *.BIN; a pattern that matches none, a missing file, names outside
the folder, a symbolic link to a file outside it, which the listing
leaves out too, a write request, and a mode other than octet, each with
its ERROR; a lost ACK, after which the block comes again; a duplicate
ACK, which sends nothing again; a packet from another port, which gets
ERROR 5 while the transfer goes on; and an ERROR from the client, after
which nothing comes again.

Then it runs the monitor of the tests, monitor/build/monitor_test.bin, in
niceemu with --eth-udp and --eth-peer, whose frames go to a bridge in
this script: the bridge answers ARP for the server 10.0.0.2, and passes
the UDP datagrams to 10.0.0.2 on to tftpd.py on 127.0.0.1, port 69 to
the server's port, and back, so that niceemu and tftpd.py are on one
network. The monitor lists the folder, loads a program of 300 lines,
which d then shows, and gets an ERROR. Its output must have the lines
that the checks name.

It prints a line for each check, and last how many passed, and exits with
status 1 when one fails. niceemu must be built, with make -C
nice_cpu/emulator build, and so must the monitor, with make -C monitor
build/monitor_test.bin. Only the Python standard library is used.
"""

import os
import selectors
import socket
import struct
import subprocess
import sys
import tempfile
import threading
from typing import Dict, Tuple

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NICEEMU = os.path.join(REPO, "nice_cpu", "emulator", "zig-out", "bin", "niceemu")
MONITOR = os.path.join(REPO, "monitor", "build", "monitor_test.bin")
TFTPD = os.path.join(REPO, "tools", "tftpd.py")

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


FILES = {
    "empty.bin": b"",
    "f511.bin": (bytes(range(256)) * 2)[:511],
    "f512.bin": (bytes(range(256)) * 2)[:512],
    "f513.txt": (bytes(range(256)) * 3)[:513],
    "big.dat": bytes((i * 7) & 0xFF for i in range(140_000)),
    "prog.bin": prog(),
    ".hidden": b"secret",
}


def request(op: int, name: str, mode: str = "octet") -> bytes:
    return struct.pack(">H", op) + name.encode() + b"\0" + mode.encode() + b"\0"


Result = Tuple[str, bytes, int]         # "data" or "error", the bytes or message, the code


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


def test_monitor(server_port: int, tmp: str) -> None:
    bridge = Bridge(server_port)
    bridge.emu_port = free_port()
    thread = threading.Thread(target=bridge.run, daemon=True)
    thread.start()
    inp = os.path.join(tmp, "input")
    with open(inp, "w") as f:
        f.write("i 10.0.0.9\rtftp 10.0.0.2\rtftp 10.0.0.2 PROG.BIN\rd 9000 4\r"
                "d 912B 1\rtftp 10.0.0.2 nosuch.bin\rh\r")
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
    at = lines.index("> tftp 10.0.0.2") + 1 if "> tftp 10.0.0.2" in lines else -1
    check("monitor: tftp 10.0.0.2 lists the folder",
          at > 0 and lines[at:at + len(want)] == want, "\n".join(lines[at:at + 9]))
    for line in ("Words loaded: 300, 00009000 to 0000912B",
                 "00009000 00000000 00000003 00000006 00000009",
                 "0000912B 00000381",
                 "TFTP error 1, File not found"):
        check(f"monitor: {line}", line in lines, out[-600:])


def main() -> None:
    for path, how in ((NICEEMU, "make -C nice_cpu/emulator build"),
                      (MONITOR, "make -C monitor build/monitor_test.bin")):
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
        server = subprocess.Popen(
            [sys.executable, TFTPD, "--dir", folder, "--port", "0",
             "--addr", "127.0.0.1", "--timeout", str(TIMEOUT)],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        try:
            assert server.stderr is not None
            line = server.stderr.readline()
            port = int(line.split()[-1])
            test_server(port)
            test_monitor(port, tmp)
        finally:
            server.terminate()
            server.wait()
    print(f"{passed} of {passed + failed} checks passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
