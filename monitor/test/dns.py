#!/usr/bin/env python3
"""Run dns_lookup, entry 25, in niceemu, against frames of --eth-in.

Usage: test/dns.py NICEEMU MONITOR.bin DNS.bin EXPECTED OUT

DNS.bin, test/dns.nasm, runs under the monitor with the input r and h,
and --step-time, so that a run takes the same steps each time. The ID and
the port of a query come from the clock, so the script learns them from a
run, and builds the frames of the next: it runs the program, finds the
first frame sent that it has not seen and that wants an answer, an ARP
request for 10.0.0.53 or the gateway 10.0.0.1, or a query of a name in
ANSWERS, and adds the answer, after that frame (nice_cpu's SYSTEM.md §7),
until no such frame is left. As the frames of a run are the first of
every longer run with the same answers, a run stops after FIRST steps,
which double whenever it brings no new frame, until the program returns. A query is answered once, at the send that
ANSWERS gives, so late.example.com is answered only after its second
send, and its first send gets the query itself back, with QR clear, which
is passed over. Names not in ANSWERS, and the ARP requests for 10.0.0.54, get no
answer.

The last run's console output, up to the halt, the program's results,
and the frames sent, 16 bytes a row with the IPv4 identification and
checksum as ii ii and cc cc, and a query's port and ID as pp pp and qq qq,
which change with the steps of the code, are written to OUT and compared
with EXPECTED. The script also checks each frame's IPv4 checksum, that
the identification counts up by one from packet to packet, that DF is
clear, that the queries of one name have one port and one ID, and that
the port is 49152 to 65535 and not the endpoint's, 5000. Exits with
status 1 when a check fails. Only the Python standard library is used.
"""

import os
import struct
import subprocess
import sys
import tempfile
from typing import Callable, Dict, List, Set, Tuple

MAC = bytes.fromhex("024E49434500")      # the station's after reset
INPUT = b"r\rh\r"
STEPS = 64_000_000                       # the steps of a run at most
FIRST = 1_000_000                        # and of the first, doubled while no new frame comes
DUMPS = ["-d", "0x9100:53"]
ID_AT = 18                               # the IPv4 identification
SUM_AT = 24                              # and the IPv4 header's checksum
PORT_AT = 34                             # a query's UDP source port
QID_AT = 42                              # and its ID
MACS = {"10.0.0.53": "0A0000000053", "10.0.0.1": "0A0000000001"}


def ip(text: str) -> bytes:
    return bytes(int(n) for n in text.split("."))


def checksum(header: bytes) -> int:
    total: int = sum(struct.unpack(f">{len(header) // 2}H", header))
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return ~total & 0xFFFF


def name(text: str) -> bytes:
    """A name as DNS has it on the wire, with no compression."""
    out = b""
    for label in text.rstrip(".").split("."):
        out += bytes([len(label)]) + label.encode()
    return out + b"\0"


def record(owner: bytes, rtype: int, rclass: int, data: bytes) -> bytes:
    return owner + struct.pack(">HHIH", rtype, rclass, 300, len(data)) + data


def datagram(src: str, mac: str, sport: int, dport: int, payload: bytes) -> str:
    """A datagram from src at mac to the station, 10.0.0.9, as a line of
    --eth-in, less the N: in front."""
    udp = struct.pack(">HHHH", sport, dport, 8 + len(payload), 0) + payload
    hdr = struct.pack(">BBHHHBBH4s4s", 0x45, 0, 20 + len(udp), 0, 0, 64, 17,
                      0, ip(src), ip("10.0.0.9"))
    hdr = hdr[:10] + struct.pack(">H", checksum(hdr)) + hdr[12:]
    return (MAC + bytes.fromhex(mac) + b"\x08\x00" + hdr + udp).hex()


def message(qid: int, qname: str, flags: int, answers: List[bytes]) -> bytes:
    """An answer to the query qid of qname, with its question at byte 12,
    to which a pointer is 0xC00C."""
    return (struct.pack(">HHHHHH", qid, flags, 1, len(answers), 0, 0)
            + name(qname) + struct.pack(">HH", 1, 1) + b"".join(answers))


PTR = b"\xc0\x0c"                        # the question's name
OK = 0x8180                              # QR, RD, RA, and RCODE 0
A, CNAME, AAAA, IN, CH = 1, 5, 28, 1, 3


def plain(addr: str) -> Callable[[int, str], bytes]:
    return lambda qid, q: message(qid, q, OK, [record(PTR, A, IN, ip(addr))])


def www(qid: int, q: str) -> bytes:
    """A CNAME of the question's name to web.example.com, the label web
    and a pointer to example.com, and the A record of that name by a
    pointer to the CNAME's data."""
    at = 12 + len(name(q)) + 4                     # the CNAME record
    cname = record(PTR, CNAME, IN, b"\x03web" + struct.pack(">H", 0xC000 | (12 + 4)))
    a = record(struct.pack(">H", 0xC000 | (at + 12)), A, IN, ip("93.184.216.35"))
    return message(qid, q, OK, [cname, a])


def aaaa(qid: int, q: str) -> bytes:
    return message(qid, q, OK, [record(PTR, AAAA, IN, bytes(16)),
                                record(PTR, A, CH, ip("10.9.9.9")),
                                record(PTR, A, IN, ip("10.1.2.3"))])


def loop(qid: int, q: str) -> bytes:
    at = 12 + len(name(q)) + 4                     # the record, whose name points to itself
    return message(qid, q, OK, [record(struct.pack(">H", 0xC000 | at), A, IN, ip("10.4.4.4"))])


def short(qid: int, q: str) -> bytes:
    return plain("10.7.7.7")(qid, q)[:-2]


def rcode(flags: int) -> Callable[[int, str], bytes]:
    return lambda qid, q: message(qid, q, flags, [])


def cname_only(qid: int, q: str) -> bytes:
    return message(qid, q, OK, [record(PTR, CNAME, IN, b"\x01x" + PTR)])


def exdot(qid: int, q: str, port: int) -> List[str]:
    """The datagrams that are passed over, and the answer, 4, which the
    queue holds."""
    msg = plain("93.184.216.34")(qid, q)
    srv, mac = "10.0.0.53", MACS["10.0.0.53"]
    other = bytearray(msg)
    other[1] ^= 1                                  # another ID
    return [datagram("10.0.0.54", mac, 53, port, msg),
            datagram(srv, mac, 54, port, msg),
            datagram(srv, mac, 53, port, bytes(other)),
            datagram(srv, mac, 53, port, msg)]


def echo(qid: int, q: str, port: int) -> List[str]:
    """The query itself, with QR clear, which is passed over."""
    msg = bytearray(plain("10.5.5.5")(qid, q))
    msg[2] &= 0x7F
    return [datagram("10.0.0.53", MACS["10.0.0.53"], 53, port, bytes(msg))]


L253 = ".".join(["x" * 63] * 3 + ["x" * 61])
# The names answered: the send to answer, and the message
ANSWERS: Dict[str, Tuple[int, Callable[[int, str], bytes]]] = {
    "www.example.com": (1, www),
    "aaaa.example.com": (1, aaaa),
    "nx.example.com": (1, rcode(0x8183)),
    "fail.example.com": (1, rcode(0x8182)),
    "tc.example.com": (1, rcode(0x8380)),
    "cname.example.com": (1, cname_only),
    "loop.example.com": (1, loop),
    "short.example.com": (1, short),
    "late.example.com": (2, plain("10.5.5.5")),
    L253: (1, rcode(0x8183)),
    "gw.example.com": (1, plain("10.6.6.6")),
}


def query(frame: bytes) -> Tuple[str, int, int]:
    """The name, the port, and the ID of a query, or an empty name."""
    if len(frame) < 55 or frame[12:14] != b"\x08\x00" or frame[23] != 17 \
            or frame[36:38] != b"\x00\x35":
        return "", 0, 0
    labels, at = [], 54
    while frame[at]:
        labels.append(frame[at + 1:at + 1 + frame[at]].decode("latin-1"))
        at += 1 + frame[at]
    port, qid = struct.unpack(">H", frame[PORT_AT:PORT_AT + 2])[0], \
        struct.unpack(">H", frame[QID_AT:QID_AT + 2])[0]
    return ".".join(labels), port, qid


def answers(n: int, frame: bytes, sends: Dict[str, int]) -> List[str]:
    """The frames that answer frame n, less the N: in front, or none."""
    if frame[12:14] == b"\x08\x06" and frame[20:22] == b"\x00\x01":
        target = ".".join(str(b) for b in frame[38:42])
        if target not in MACS:
            return []
        src = bytes.fromhex(MACS[target])
        return [(MAC + src + b"\x08\x06" + bytes.fromhex("000108000604" "0002")
                 + src + frame[38:42] + MAC + ip("10.0.0.9")).hex()]
    q, port, qid = query(frame)
    if not q:
        return []
    sends[q] = sends.get(q, 0) + 1
    if q == "example.com":
        return exdot(qid, q, port)
    if q == "late.example.com" and sends[q] == 1:
        return echo(qid, q, port)
    if q not in ANSWERS or ANSWERS[q][0] != sends[q]:
        return []
    srv = ".".join(str(b) for b in frame[30:34])
    mac = MACS["10.0.0.53"] if srv == "10.0.0.53" else MACS["10.0.0.1"]
    return [datagram(srv, mac, 53, port, ANSWERS[q][1](qid, q))]


def run(emu: str, prog: str, eth_in: List[str], tmp: str,
        steps: int) -> Tuple[List[str], List[bytes]]:
    """The console output and dumps of a run, and its frames sent."""
    inp = os.path.join(tmp, "input")
    with open(inp, "wb") as f:
        f.write(INPUT)
    out = os.path.join(tmp, "dns.out")
    path = os.path.join(tmp, "dns.in")
    with open(path, "w") as f:
        f.write("\n".join(eth_in) + "\n")
    args = [emu, "-n", str(steps), "--step-time", "-i", inp, "--eth-out", out,
            "--eth-in", path] + DUMPS
    res = subprocess.run(args + [prog], capture_output=True)
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
        ipv4 = frame[12:14] == b"\x08\x00"
        dns = bool(query(frame)[0])
        text = ["ii" if ipv4 and ID_AT <= i < ID_AT + 2
                else "cc" if ipv4 and SUM_AT <= i < SUM_AT + 2
                else "pp" if dns and PORT_AT <= i < PORT_AT + 2
                else "qq" if dns and QID_AT <= i < QID_AT + 2
                else f"{b:02x}" for i, b in enumerate(frame)]
        for at in range(0, len(text), 16):
            rows.append(f"{at:03x}  " + " ".join(text[at:at + 16]))
    return rows


def main() -> None:
    if len(sys.argv) != 6:
        sys.exit(str(__doc__).split("\n\n")[1])
    emu, monitor, dns, expected, out = sys.argv[1:]
    fails = 0

    def check(what: str, ok: bool) -> None:
        nonlocal fails
        print(f"[{'PASS' if ok else 'FAIL'}] {what}")
        fails += not ok

    eth_in = ["# The answers to the frames sent, built from the runs before"]
    done: Set[int] = set()
    with tempfile.TemporaryDirectory() as tmp:
        joined = os.path.join(tmp, "dns.bin")
        with open(joined, "w") as f:
            for part in (monitor, dns):
                with open(part) as g:
                    f.write(g.read())
        steps = FIRST
        while True:
            lines, frames = run(emu, joined, eth_in, tmp, steps)
            sends: Dict[str, int] = {}
            for n, frame in enumerate(frames):
                more = answers(n, frame, sends)
                if n not in done:
                    done.add(n)
                    if more:
                        eth_in += [f"{n + 1}:{line}" for line in more]
                        break
            else:
                if any(line.startswith("Returned") for line in lines) or steps >= STEPS:
                    break
                steps *= 2

    report = lines + show(frames)
    ipv4 = [f for f in frames if f[12:14] == b"\x08\x00"]
    check("dns: the IPv4 checksums", all(checksum(f[14:34]) == 0 for f in ipv4))
    ids = [struct.unpack(">H", f[ID_AT:ID_AT + 2])[0] for f in ipv4]
    check("dns: the identification counts up by one",
          all((b - a) & 0xFFFF == 1 for a, b in zip(ids, ids[1:])))
    check("dns: DF clear", all(f[20:22] == b"\0\0" for f in ipv4))
    queries: Dict[str, Set[Tuple[int, int]]] = {}
    for frame in frames:
        q, port, qid = query(frame)
        if q:
            queries.setdefault(q, set()).add((port, qid))
    check("dns: one port and one ID for each name",
          all(len(v) == 1 for v in queries.values()))
    ports = [p for v in queries.values() for p, _ in v]
    check("dns: the ports 49152 to 65535, not 5000",
          all(49152 <= p <= 65535 for p in ports) and bool(ports))
    with open(out, "w") as f:
        f.write("\n".join(report) + "\n")
    try:
        with open(expected) as f:
            same = f.read() == "\n".join(report) + "\n"
    except FileNotFoundError:
        same = False
    check(f"dns: the output as {os.path.basename(expected)}", same)
    if not same:
        subprocess.run(["diff", expected, out])
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
