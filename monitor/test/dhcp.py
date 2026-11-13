#!/usr/bin/env python3
"""Run the monitor's i dhcp in niceemu, against frames of --eth-in.

Usage: test/dhcp.py NICEEMU MONITOR.bin NETDHCP.bin EXPECTED OUT

The monitor runs with the input i 10.0.0.9, i dhcp, i, and h, and
--step-time, so that a run takes the same steps each time, and the
microseconds that start the transaction, V_XID, are the same in each run.
The first run has no frames: the monitor sends DHCP_TRIES DISCOVERs, says
that no server answered, and keeps 10.0.0.9. The script takes the
transaction from its first frame, and builds the frames of the next runs
with it, each line waiting for the frames sent before it (nice_cpu's
SYSTEM.md §7). As the address 10.0.0.9 is set, each DISCOVER asks for it
with option 50.
- ok: after the DISCOVER, an ARP request of another station, an OFFER of
  another transaction, an OFFER of ours without an address, which is
  passed over, and the OFFER of 192.168.1.1, with its options out of
  word order, a pad, and two gateways; after the REQUEST, the
  OFFER of a second server, which must change nothing, and the ACK.
- nak: an OFFER, a NAK of the REQUEST, which starts again from a
  DISCOVER, a second OFFER of another address, and its ACK.
The runs entry-none and entry run NETDHCP.bin, test/netdhcp.nasm, under
the monitor, with the input r and h: a program that calls net_dhcp,
entry 23, with the address 192.168.1.50 set and the UDP endpoint open.
entry-none has no frames, and net_dhcp returns E_NODHCP; entry has, after
the DISCOVER, an ARP reply of 192.168.1.1, which is learned while
net_dhcp waits, and the OFFER of 192.168.1.50, and after the REQUEST its
ACK; net_dhcp returns 0, and the endpoint keeps the port enabled.
Each run's console output, up to the halt, the words of NET_IP and
ETH_CSR, or the program's results, and the frames sent, 16 bytes a row
with the transaction as xx, and the IPv4 identification and checksum as
ii ii and cc cc, which change with the steps of the code, are written
to OUT and compared with EXPECTED. The script also checks that each
frame's IPv4 checksum is right, that the identification counts up by one
from frame to frame, that DF is clear, and that each frame has the
transaction of its run's first. Exits with status 1 when a check fails.
Only the Python standard library is used.
"""

import os
import struct
import subprocess
import sys
import tempfile
from typing import List, Optional, Tuple

MAC = bytes.fromhex("024E49434500")      # the station's after reset
BCAST = b"\xff" * 6
INPUT = b"i 10.0.0.9\ri dhcp\ri\rh\r"
INPUT_PROG = b"r\rh\r"
STEPS = 30_000_000
DUMPS = ["-d", "0xFFFFFFB0:1", "-d", "0xFFFFFFC0:1"]
DUMPS_PROG = ["-d", "0x9100:14"]
XID_AT = 46                              # the transaction's bytes in a frame
ID_AT = 18                               # the IPv4 identification
SUM_AT = 24                              # and the IPv4 header's checksum


def ip(text: str) -> bytes:
    return bytes(int(n) for n in text.split("."))


def checksum(header: bytes) -> int:
    total: int = sum(struct.unpack(f">{len(header) // 2}H", header))
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return ~total & 0xFFFF


def reply(xid: int, kind: int, yiaddr: str, server: str, dst: bytes = BCAST,
          extra: bytes = b"") -> str:
    """A DHCP reply of the message type kind from server, as a line of
    --eth-in."""
    srv = ip(server)
    opts = bytes([53, 1, kind]) + extra + bytes([54, 4]) + srv + b"\xff"
    bootp = (struct.pack(">BBBBIHH", 2, 1, 6, 0, xid, 0, 0x8000)
             + bytes(4) + ip(yiaddr) + srv + bytes(4)
             + MAC + bytes(10) + bytes(64) + bytes(128)
             + bytes.fromhex("63825363") + opts)
    udp = struct.pack(">HHHH", 67, 68, 8 + len(bootp), 0) + bootp
    hdr = struct.pack(">BBHHHBBH4s4s", 0x45, 0, 20 + len(udp), 0, 0, 64, 17,
                      0, srv, ip("255.255.255.255"))
    hdr = hdr[:10] + struct.pack(">H", checksum(hdr)) + hdr[12:]
    frame = dst + bytes.fromhex("0A0000000001") + b"\x08\x00" + hdr + udp
    return frame.hex()


def arp_request(sender: str, target: str) -> str:
    frame = (BCAST + bytes.fromhex("0A0000000002") + b"\x08\x06"
             + bytes.fromhex("000108000604" "0001") + bytes.fromhex("0A0000000002")
             + ip(sender) + bytes(6) + ip(target))
    return frame.hex()


def arp_reply(sender: str, target: str) -> str:
    frame = (MAC + bytes.fromhex("0A0000000001") + b"\x08\x06"
             + bytes.fromhex("000108000604" "0002") + bytes.fromhex("0A0000000001")
             + ip(sender) + MAC + ip(target))
    return frame.hex()


def run(emu: str, monitor: str, eth_in: Optional[str], tmp: str,
        name: str, prog: bool = False) -> Tuple[List[str], List[bytes]]:
    """The console output and dumps of a run, and its frames sent; with
    prog, of the program after the monitor, MONITOR the two joined."""
    inp = os.path.join(tmp, "input")
    with open(inp, "wb") as f:
        f.write(INPUT_PROG if prog else INPUT)
    out = os.path.join(tmp, name + ".out")
    args = [emu, "-n", str(STEPS), "--step-time", "-i", inp, "--eth-out", out]
    args += DUMPS_PROG if prog else DUMPS
    if eth_in is not None:
        path = os.path.join(tmp, name + ".in")
        with open(path, "w") as f:
            f.write(eth_in)
        args += ["--eth-in", path]
    res = subprocess.run(args + [monitor], capture_output=True)
    text = res.stdout.decode("latin-1").replace("\r", "").split("\n")
    lines: List[str] = []
    skip = False
    for line in text:
        if line.startswith("Halted"):
            skip = True
        elif skip and line.startswith("R12 "):
            skip = False
            continue
        if not skip:
            lines.append(line)
    lines.append(f"exit {res.returncode}")
    with open(out) as f:
        frames = [bytes.fromhex(line) for line in f if line.strip()]
    return lines, frames


def show(frames: List[bytes]) -> List[str]:
    rows = []
    for n, frame in enumerate(frames):
        rows.append(f"frame {n + 1}, {len(frame)} bytes")
        text = ["xx" if XID_AT <= i < XID_AT + 4
                else "ii" if ID_AT <= i < ID_AT + 2
                else "cc" if SUM_AT <= i < SUM_AT + 2
                else f"{b:02x}" for i, b in enumerate(frame)]
        for at in range(0, len(text), 16):
            rows.append(f"{at:03x}  " + " ".join(text[at:at + 16]))
    return rows


def main() -> None:
    if len(sys.argv) != 6:
        sys.exit(str(__doc__).split("\n\n")[1])
    emu, monitor, netdhcp, expected, out = sys.argv[1:]
    fails = 0

    def check(name: str, ok: bool) -> None:
        nonlocal fails
        print(f"[{'PASS' if ok else 'FAIL'}] {name}")
        fails += not ok

    report: List[str] = []
    with tempfile.TemporaryDirectory() as tmp:
        lines, frames = run(emu, monitor, None, tmp, "none")
        check("dhcp none: frames sent", len(frames) > 0)
        if not frames:
            sys.exit(1)
        xid = struct.unpack(">I", frames[0][XID_AT:XID_AT + 4])[0]
        runs = [("none", lines, frames)]
        offer = bytes([1, 4]) + ip("255.255.255.0") + bytes([0, 51, 4, 0, 0, 0x0E, 0x10]) \
            + bytes([3, 8]) + ip("192.168.1.1") + ip("192.168.1.254") \
            + bytes([6, 4]) + ip("192.168.1.3")
        ok_in = "\n".join([
            "# after the DISCOVER: an ARP request, an OFFER of another",
            "# transaction, an OFFER of ours without an address, and the",
            "# OFFER, to the station's MAC address",
            "1:" + arp_request("10.0.0.1", "10.0.0.77"),
            "1:" + reply(xid ^ 1, 2, "10.0.0.66", "10.0.0.2"),
            "1:" + reply(xid, 2, "0.0.0.0", "10.0.0.3"),
            "1:" + reply(xid, 2, "192.168.1.50", "192.168.1.1", MAC, offer),
            "# after the REQUEST: a second server's OFFER, and the ACK",
            "2:" + reply(xid, 2, "192.168.1.60", "192.168.1.2"),
            "2:" + reply(xid, 5, "192.168.1.50", "192.168.1.1", BCAST, offer),
            ""])
        runs.append(("ok", *run(emu, monitor, ok_in, tmp, "ok")))
        nak_in = "\n".join([
            "1:" + reply(xid, 2, "192.168.1.50", "192.168.1.1"),
            "2:" + reply(xid, 6, "0.0.0.0", "192.168.1.1"),
            "3:" + reply(xid, 2, "192.168.1.51", "192.168.1.1", BCAST, offer),
            "4:" + reply(xid, 5, "192.168.1.51", "192.168.1.1", BCAST, offer),
            ""])
        runs.append(("nak", *run(emu, monitor, nak_in, tmp, "nak")))
        joined = os.path.join(tmp, "netdhcp.bin")
        with open(joined, "w") as f:
            for part in (monitor, netdhcp):
                with open(part) as g:
                    f.write(g.read())
        lines, frames = run(emu, joined, None, tmp, "entry-none", True)
        runs.append(("entry-none", lines, frames))
        check("dhcp entry-none: frames sent", len(frames) > 0)
        if not frames:
            sys.exit(1)
        exid = struct.unpack(">I", frames[0][XID_AT:XID_AT + 4])[0]
        entry_in = "\n".join([
            "# after the DISCOVER: an ARP reply of 192.168.1.1, and the OFFER",
            "1:" + arp_reply("192.168.1.1", "192.168.1.50"),
            "1:" + reply(exid, 2, "192.168.1.50", "192.168.1.1", MAC, offer),
            "# after the REQUEST: the ACK",
            "2:" + reply(exid, 5, "192.168.1.50", "192.168.1.1", BCAST, offer),
            ""])
        runs.append(("entry", *run(emu, joined, entry_in, tmp, "entry", True)))

    for name, lines, frames in runs:
        report.append(f"== {name}")
        report += lines
        report += show(frames)
        sums = [checksum(f[14:34]) == 0 for f in frames if f[12:14] == b"\x08\x00"]
        check(f"dhcp {name}: the IPv4 checksums", all(sums) and len(sums) == len(frames))
        ids = [struct.unpack(">H", f[ID_AT:ID_AT + 2])[0] for f in frames]
        check(f"dhcp {name}: the identification counts up by one",
              all((b - a) & 0xFFFF == 1 for a, b in zip(ids, ids[1:])))
        check(f"dhcp {name}: DF clear", all(f[20:22] == b"\0\0" for f in frames))
        xids = {struct.unpack(">I", f[XID_AT:XID_AT + 4])[0] for f in frames}
        first = exid if name.startswith("entry") else xid
        check(f"dhcp {name}: one transaction, the first run's", xids == {first})
    with open(out, "w") as f:
        f.write("\n".join(report) + "\n")
    try:
        with open(expected) as f:
            same = f.read() == "\n".join(report) + "\n"
    except FileNotFoundError:
        same = False
    check(f"dhcp: the output as {os.path.basename(expected)}", same)
    if not same:
        subprocess.run(["diff", expected, out])
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
