#!/usr/bin/env python3
"""Run the monitor's tftp in niceemu, against frames of --eth-in.

Usage: test/tftp.py NICEEMU MONITOR.bin EXPECTED OUT

Each run has --step-time, so that it takes the same steps each time, and
the port that udp_open picks from the microseconds is the same in each
run with the input RUN: i 10.0.0.9, tftp 10.0.0.2 prog.bin, d 9000 4, and
h. The first run, none, has only the server's ARP reply: the monitor
sends the RRQ TFTP_TRIES times and says that the server did not answer.
The script takes the client's port from its RRQ and builds the frames of
the next runs with it, each line waiting for the frames sent before it
(nice_cpu's SYSTEM.md §7), from the server 10.0.0.2 with the TID 3456:
- ok: PROG, 40 lines of .bin text in two blocks, with a CR LF line, an
  empty line, a line that is skipped, and a last line with no LF. After
  the RRQ, a datagram of another host, and DATA 1; after ACK 1, a DATA 2
  of another TID, which is passed over, and DATA 1 again, which is
  answered with ACK 1 again; then DATA 2.
- lost: no answer to the first RRQ, which is sent again; DATA 1; no
  answer to ACK 1, which is sent again; DATA 2.
- error: an ERROR 1, File not found, to the RRQ.
- exact: a file of 512 bytes, 25 lines ended by CR LF and 37 empty
  lines, whose DATA 2 is empty.
- empty: an empty file, one empty DATA 1.
The run args has the input ARGS, with no frames: tftp's arguments that
are not, tftp with no IP address, and tftp to a server that does not
answer ARP.
Each run's console output, up to the halt, and the frames sent, 16 bytes
a row with the client's port as pp pp, are written to OUT and compared
with EXPECTED. The script also checks each frame's IPv4 checksum, and
that each TFTP packet comes from the port of the first RRQ, the RRQs to
port 69 and the ACKs to the TID. Exits with status 1 when a check fails.
Only the Python standard library is used.
"""

import os
import struct
import subprocess
import sys
import tempfile
from typing import List, Optional, Tuple

MAC = bytes.fromhex("024E49434500")      # the station's after reset
SERVER_MAC = bytes.fromhex("0A0000000002")
RUN = b"i 10.0.0.9\rtftp 10.0.0.2 prog.bin\rd 9000 4\rh\r"
ARGS = (b"tftp\rtftp x\rtftp 10.0.0.2\rtftp 10.0.0.2 a b\rtftp 10.0.0.256 a\r"
        b"tftp 10.0.0.2x a\rtftpx\rtftp 10.0.0.2 a.bin\ri 10.0.0.9\r"
        b"tftp 10.0.0.3 a.bin\rh\r")
STEPS = 40_000_000
TID = 3456
PORT_AT = 34                             # the client's port in a frame sent


def ip(text: str) -> bytes:
    return bytes(int(n) for n in text.split("."))


def checksum(header: bytes) -> int:
    total: int = sum(struct.unpack(f">{len(header) // 2}H", header))
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return ~total & 0xFFFF


def datagram(port: int, data: bytes, src: str = "10.0.0.2", sport: int = TID) -> str:
    """A datagram to the client's port, as a line of --eth-in."""
    udp = struct.pack(">HHHH", sport, port, 8 + len(data), 0) + data
    hdr = struct.pack(">BBHHHBBH4s4s", 0x45, 0, 20 + len(udp), 0, 0, 64, 17,
                      0, ip(src), ip("10.0.0.9"))
    hdr = hdr[:10] + struct.pack(">H", checksum(hdr)) + hdr[12:]
    return (MAC + SERVER_MAC + b"\x08\x00" + hdr + udp).hex()


def data(port: int, block: int, payload: bytes, sport: int = TID) -> str:
    return datagram(port, struct.pack(">HH", 3, block) + payload, sport=sport)


def arp_reply() -> str:
    return (MAC + SERVER_MAC + b"\x08\x06" + bytes.fromhex("0001080006040002")
            + SERVER_MAC + ip("10.0.0.2") + MAC + ip("10.0.0.9")).hex()


def prog() -> bytes:
    """40 lines in 692 bytes that write 9000 to 9025, with the edits of
    the header."""
    lines = [f"{0x9000 + i:08X} {i * 0x01010101:08X}\n".encode() for i in range(37)]
    lines[3] = lines[3].replace(b"\n", b"\r\n")
    lines.insert(10, b"\n")
    lines.insert(20, b"90XX 1\n")
    lines.append(b"00009025 FFFFFFFF")
    text = b"".join(lines)
    assert 512 < len(text) < 1024, len(text)
    return text


def run(emu: str, monitor: str, inp: bytes, eth_in: Optional[str], tmp: str,
        name: str) -> Tuple[List[str], List[bytes]]:
    """The console output of a run, and its frames sent."""
    path = os.path.join(tmp, name + ".input")
    with open(path, "wb") as f:
        f.write(inp)
    out = os.path.join(tmp, name + ".out")
    args = [emu, "-n", str(STEPS), "--step-time", "-i", path, "--eth-out", out]
    if eth_in is not None:
        path = os.path.join(tmp, name + ".in")
        with open(path, "w") as f:
            f.write(eth_in)
        args += ["--eth-in", path]
    res = subprocess.run(args + [monitor], capture_output=True)
    text = res.stdout.decode("latin-1").replace("\r", "").split("\n")
    lines: List[str] = []
    for line in text:
        if line.startswith("Halted (HALT)"):
            break
        lines.append(line)
    lines.append(f"exit {res.returncode}")
    with open(out) as f:
        frames = [bytes.fromhex(line) for line in f if line.strip()]
    return lines, frames


def show(frames: List[bytes]) -> List[str]:
    rows = []
    for n, frame in enumerate(frames):
        rows.append(f"frame {n + 1}, {len(frame)} bytes")
        text = ["pp" if PORT_AT <= i < PORT_AT + 2 and frame[12:14] == b"\x08\x00"
                else f"{b:02x}" for i, b in enumerate(frame)]
        for at in range(0, len(text), 16):
            rows.append(f"{at:03x}  " + " ".join(text[at:at + 16]))
    return rows


def main() -> None:
    if len(sys.argv) != 5:
        sys.exit(str(__doc__).split("\n\n")[1])
    emu, monitor, expected, out = sys.argv[1:]
    fails = 0

    def check(name: str, ok: bool) -> None:
        nonlocal fails
        print(f"[{'PASS' if ok else 'FAIL'}] {name}")
        fails += not ok

    report: List[str] = []
    with tempfile.TemporaryDirectory() as tmp:
        lines, frames = run(emu, monitor, RUN, "1:" + arp_reply() + "\n", tmp, "none")
        udp = [f for f in frames if f[12:14] == b"\x08\x00"]
        check("tftp none: an RRQ sent", len(udp) > 0)
        if not udp:
            sys.exit(1)
        port: int = struct.unpack(">H", udp[0][PORT_AT:PORT_AT + 2])[0]
        runs = [("none", lines, frames)]
        text = prog()
        first, second = text[:512], text[512:]
        ok_in = "\n".join([
            "1:" + arp_reply(),
            "# after the RRQ: another host's datagram, and DATA 1",
            "2:" + datagram(port, struct.pack(">HH", 3, 1) + first, src="10.0.0.3"),
            "2:" + data(port, 1, first),
            "# after ACK 1: DATA 2 of another TID, and DATA 1 again",
            "3:" + data(port, 2, b"00009000 DEADBEEF\n", sport=TID + 1),
            "3:" + data(port, 1, first),
            "# after ACK 1 again: DATA 2",
            "4:" + data(port, 2, second),
            ""])
        runs.append(("ok", *run(emu, monitor, RUN, ok_in, tmp, "ok")))
        lost_in = "\n".join([
            "1:" + arp_reply(),
            "3:" + data(port, 1, first),
            "5:" + data(port, 2, second),
            ""])
        runs.append(("lost", *run(emu, monitor, RUN, lost_in, tmp, "lost")))
        err_in = "\n".join([
            "1:" + arp_reply(),
            "2:" + datagram(port, struct.pack(">HH", 5, 1) + b"File not found\x00"),
            ""])
        runs.append(("error", *run(emu, monitor, RUN, err_in, tmp, "error")))
        exact = b"".join(f"{0x9000 + i:08X} {i:08X}\r\n".encode() for i in range(25)) + b"\n" * 37
        assert len(exact) == 512
        exact_in = "\n".join([
            "1:" + arp_reply(),
            "2:" + data(port, 1, exact),
            "3:" + data(port, 2, b""),
            ""])
        runs.append(("exact", *run(emu, monitor, RUN, exact_in, tmp, "exact")))
        empty_in = "\n".join(["1:" + arp_reply(), "2:" + data(port, 1, b""), ""])
        runs.append(("empty", *run(emu, monitor, RUN, empty_in, tmp, "empty")))
        runs.append(("args", *run(emu, monitor, ARGS, None, tmp, "args")))

    for name, lines, frames in runs:
        report.append(f"== {name}")
        report += lines
        report += show(frames)
        udp = [f for f in frames if f[12:14] == b"\x08\x00"]
        sums = [checksum(f[14:34]) == 0 for f in udp]
        check(f"tftp {name}: the IPv4 checksums", all(sums))
        ports = {struct.unpack(">H", f[PORT_AT:PORT_AT + 2])[0] for f in udp}
        check(f"tftp {name}: one client port, the first run's",
              name == "args" or ports == {port})
        dst = [struct.unpack(">HH", f[36:38] + f[42:44]) for f in udp]
        check(f"tftp {name}: RRQs to port 69, ACKs to the TID",
              all((d, op) in ((69, 1), (TID, 4)) for d, op in dst))
    with open(out, "w") as f:
        f.write("\n".join(report) + "\n")
    try:
        with open(expected) as f:
            same = f.read() == "\n".join(report) + "\n"
    except FileNotFoundError:
        same = False
    check(f"tftp: the output as {os.path.basename(expected)}", same)
    if not same:
        subprocess.run(["diff", expected, out])
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
