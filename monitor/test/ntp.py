#!/usr/bin/env python3
"""Run the monitor's time ntp in niceemu, against frames of --eth-in.

Usage: test/ntp.py NICEEMU MONITOR.bin EXPECTED OUT

The monitor runs the commands of INPUT with --step-time, so that a run
takes the same steps each time. The transaction of i dhcp, and the port
and the transmit timestamp of each query, come from the clock, so the
script learns them from a run, and builds the frames of the next, as
test/dns.py does: it runs the monitor, finds the first frame sent that
it has not seen and that wants an answer, and adds the answer after that
frame (nice_cpu's SYSTEM.md §7), until no such frame is left. A run stops
after FIRST steps, which double whenever it brings no new frame, until
the monitor halts.

- i dhcp gets 10.0.0.9, with the mask, the gateway 10.0.0.1, the DNS
  server 10.0.0.53, and the NTP server 10.0.0.123 of option 42.
- Each ARP request for 10.0.0.x gets the answer of 0A:00:00:00:00:x.
- The DNS server answers kod.example.com with 10.0.0.125, and
  nx.example.com with RCODE 3.
- The time servers answer as SERVERS says, to the sends it gives: with
  the time of an answer, a kiss-o'-death, a leap indicator of 3, a
  stratum of 16, a time before 1970, and datagrams that are passed over,
  from another address and port, of mode 3, with another originate
  timestamp, and too short, four at a time, as many as the queue holds.
  10.0.0.128 never answers, and 10.0.0.131 only the second send.

The last run's console output, up to the halt, and the frames sent, 16
bytes a row with the IPv4 identification and checksum as ii ii and cc
cc, the transaction as xx, a query's port as pp, its transmit timestamp
as tt, and the ID of a DNS query as qq, which change with the steps of the code, are written to OUT
and compared with EXPECTED. The script also checks each frame's IPv4
checksum, that the identification counts up by one, that DF is clear,
that the queries of a command have one port and one timestamp, from
49152 to 65535, and that each query is version 4, mode 3, of 48 bytes.
Exits with status 1 when a check fails. Only the Python standard library
is used.
"""

import datetime
import os
import struct
import subprocess
import sys
import tempfile
from typing import Callable, Dict, List, Set, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dhcp  # noqa: E402
import dns  # noqa: E402

MAC = dhcp.MAC
INPUT = (b"time ntp\r"                       # no IP address
         b"i dhcp\r"
         b"time ntp\r"                       # DHCP's server, 10.0.0.123
         b"time ntp 10.0.0.124 +01:00\r"     # passed over, then era 1
         b"time\r"
         b"time ntp kod.example.com\r"
         b"time ntp 10.0.0.126\r"            # leap indicator 3
         b"time ntp 10.0.0.127\r"            # stratum 16
         b"time ntp 10.0.0.128\r"            # no answer
         b"time ntp nx.example.com\r"
         b"time ntp 10.0.0.130 -12:00\r"     # before 1970
         b"time ntp 10.0.0.131 -00:30\r"     # the second send, and the clock ahead
         b"time ntp 10.0.0.9 +14:01\r"       # an offset too large
         b"h\r")
STEPS = 256_000_000                      # the steps of a run at most
FIRST = 2_000_000                        # and of the first, doubled while no new frame comes
ID_AT = 18                               # the IPv4 identification
SUM_AT = 24                              # and the IPv4 header's checksum
PORT_AT = 34                             # a query's UDP source port
TS_AT = 82                               # and its transmit timestamp
NTP_EPOCH = datetime.datetime(1900, 1, 1)


def ntp_time(text: str) -> Tuple[int, int]:
    """The seconds of NTP, mod 2^32, and the fraction, of a UTC time with
    microseconds, such as 2026-11-14 12:00:00.500000."""
    t = datetime.datetime.fromisoformat(text) - NTP_EPOCH
    sec = t.days * 86400 + t.seconds
    return sec & 0xFFFFFFFF, t.microseconds * 2**32 // 1_000_000


def answer(query: bytes, when: str, li: int = 0, stratum: int = 2, mode: int = 4,
           refid: bytes = b"\x0a\x00\x00\x01", origin: bytes = b"") -> bytes:
    """The 48 bytes of a server's answer to query, the 48 bytes of data
    of a query, with the transmit timestamp of when."""
    sec, frac = ntp_time(when)
    return (bytes([li << 6 | 4 << 3 | mode, stratum, 6, 0xEC]) + bytes(8) + refid
            + struct.pack(">II", sec - 10, 0) + (origin or query[40:48])
            + struct.pack(">IIII", sec, frac, sec, frac))


Answer = Callable[[bytes, str, int], List[str]]


def good(when: str) -> Answer:
    return lambda q, srv, port: [udp(srv, 123, port, answer(q, when))]


def kod(q: bytes, srv: str, port: int) -> List[str]:
    return [udp(srv, 123, port, answer(q, "2026-11-14 12:00:00", li=3, stratum=0,
                                       refid=b"RATE"))]


def leap(q: bytes, srv: str, port: int) -> List[str]:
    return [udp(srv, 123, port, answer(q, "2026-11-14 12:00:00", li=3))]


def stratum16(q: bytes, srv: str, port: int) -> List[str]:
    return [udp(srv, 123, port, answer(q, "2026-11-14 12:00:00", stratum=16))]


def passed(q: bytes, srv: str, port: int) -> List[str]:
    """Four datagrams that are passed over, as many as the queue holds:
    from another address, from another port, with another originate
    timestamp, and too short."""
    ok = answer(q, "2040-01-01 00:00:00")
    return [udp("10.0.0.99", 123, port, ok),
            udp(srv, 124, port, ok),
            udp(srv, 123, port, answer(q, "2040-01-01 00:00:00", origin=bytes(8))),
            udp(srv, 123, port, ok[:47])]


def era1(q: bytes, srv: str, port: int) -> List[str]:
    """A datagram of mode 3, which is passed over, and the answer of a
    time of era 1, 2040, which the clock shows an hour later."""
    return [udp(srv, 123, port, answer(q, "2040-01-01 00:00:00", mode=3)),
            udp(srv, 123, port, answer(q, "2040-01-01 00:00:00"))]


# The time servers: what each answers to which send
SERVERS: Dict[str, Dict[int, Answer]] = {
    "10.0.0.123": {1: good("2026-11-14 12:00:00.500000")},
    "10.0.0.124": {1: passed, 2: era1},
    "10.0.0.125": {1: kod},
    "10.0.0.126": {1: leap},
    "10.0.0.127": {1: stratum16},
    "10.0.0.130": {1: good("1970-01-01 06:00:00")},
    "10.0.0.131": {2: good("2026-11-14 12:00:00")},
}
NAMES = {"kod.example.com": "10.0.0.125"}


def udp(src: str, sport: int, dport: int, payload: bytes) -> str:
    return dns.datagram(src, "0A00000000" + f"{dns.ip(src)[3]:02X}", sport, dport, payload)


def is_ntp(frame: bytes) -> bool:
    return len(frame) >= 42 and frame[12:14] == b"\x08\x00" and frame[23] == 17 \
        and frame[36:38] == b"\x00\x7b"


def answers(frame: bytes, sends: Dict[str, int]) -> List[str]:
    """The frames that answer frame, less the N: in front, or none."""
    if frame[12:14] == b"\x08\x06" and frame[20:22] == b"\x00\x01":
        target = frame[38:42]
        if target[:3] != b"\x0a\x00\x00" or target[3] == 9:
            return []
        src = b"\x0a\x00\x00\x00\x00" + target[3:4]
        return [(MAC + src + b"\x08\x06" + bytes.fromhex("000108000604" "0002")
                 + src + target + MAC + dns.ip("10.0.0.9")).hex()]
    if frame[12:14] == b"\x08\x00" and frame[23] == 17 and frame[36:38] == b"\x00\x43":
        xid = struct.unpack(">I", frame[46:50])[0]
        kind = frame[42 + 240 + 2]                  # option 53, the first
        opts = (bytes([1, 4]) + dns.ip("255.255.255.0") + bytes([3, 4]) + dns.ip("10.0.0.1")
                + bytes([6, 4]) + dns.ip("10.0.0.53") + bytes([42, 8]) + dns.ip("10.0.0.123")
                + dns.ip("10.0.0.122"))
        return [dhcp.reply(xid, 2 if kind == 1 else 5, "10.0.0.9", "10.0.0.1", extra=opts)]
    q, port, qid = dns.query(frame)
    if q:
        msg = (dns.plain(NAMES[q])(qid, q) if q in NAMES else dns.rcode(0x8183)(qid, q))
        return [dns.datagram("10.0.0.53", "0A0000000035", 53, port, msg)]
    if is_ntp(frame):
        srv = ".".join(str(b) for b in frame[30:34])
        sends[srv] = sends.get(srv, 0) + 1
        reply = SERVERS.get(srv, {}).get(sends[srv])
        if reply:
            return reply(frame[42:90], srv, struct.unpack(">H", frame[34:36])[0])
    return []


def run(emu: str, monitor: str, eth_in: List[str], tmp: str,
        steps: int) -> Tuple[List[str], List[bytes]]:
    """The console output of a run, and its frames sent."""
    inp = os.path.join(tmp, "input")
    with open(inp, "wb") as f:
        f.write(INPUT)
    out = os.path.join(tmp, "ntp.out")
    path = os.path.join(tmp, "ntp.in")
    with open(path, "w") as f:
        f.write("\n".join(eth_in) + "\n")
    args = [emu, "-n", str(steps), "--step-time", "-i", inp, "--eth-out", out,
            "--eth-in", path, monitor]
    res = subprocess.run(args, capture_output=True)
    text = res.stdout.decode("latin-1").replace("\r", "").split("\n")
    lines: List[str] = []
    for line in text:
        if line.startswith("Halted"):
            lines.append(line)
            break
        lines.append(line)
    with open(out) as f:
        frames = [bytes.fromhex(line) for line in f if line.strip()]
    return lines, frames


def show(frames: List[bytes]) -> List[str]:
    rows = []
    for n, frame in enumerate(frames):
        rows.append(f"frame {n + 1}, {len(frame)} bytes")
        ipv4 = frame[12:14] == b"\x08\x00"
        ntp = is_ntp(frame)
        boot = ipv4 and frame[36:38] == b"\x00\x43"
        query = bool(dns.query(frame)[0])
        text = ["ii" if ipv4 and ID_AT <= i < ID_AT + 2
                else "cc" if ipv4 and SUM_AT <= i < SUM_AT + 2
                else "pp" if (ntp or query) and PORT_AT <= i < PORT_AT + 2
                else "qq" if query and dns.QID_AT <= i < dns.QID_AT + 2
                else "tt" if ntp and TS_AT <= i < TS_AT + 8
                else "xx" if boot and dhcp.XID_AT <= i < dhcp.XID_AT + 4
                else f"{b:02x}" for i, b in enumerate(frame)]
        for at in range(0, len(text), 16):
            rows.append(f"{at:03x}  " + " ".join(text[at:at + 16]))
    return rows


def main() -> None:
    if len(sys.argv) != 5:
        sys.exit(str(__doc__).split("\n\n")[1])
    emu, monitor, expected, out = sys.argv[1:]
    fails = 0

    def check(what: str, ok: bool) -> None:
        nonlocal fails
        print(f"[{'PASS' if ok else 'FAIL'}] {what}")
        fails += not ok

    eth_in = ["# The answers to the frames sent, built from the runs before"]
    done: Set[int] = set()
    with tempfile.TemporaryDirectory() as tmp:
        steps = FIRST
        while True:
            lines, frames = run(emu, monitor, eth_in, tmp, steps)
            sends: Dict[str, int] = {}
            for n, frame in enumerate(frames):
                more = answers(frame, sends)
                if n not in done:
                    done.add(n)
                    if more:
                        eth_in += [f"{n + 1}:{line}" for line in more]
                        break
            else:
                if any(line.startswith("Halted") for line in lines) or steps >= STEPS:
                    break
                steps *= 2

    report = lines + show(frames)
    ipv4 = [f for f in frames if f[12:14] == b"\x08\x00"]
    check("ntp: the IPv4 checksums", all(dns.checksum(f[14:34]) == 0 for f in ipv4))
    ids = [struct.unpack(">H", f[ID_AT:ID_AT + 2])[0] for f in ipv4]
    check("ntp: the identification counts up by one",
          all((b - a) & 0xFFFF == 1 for a, b in zip(ids, ids[1:])))
    check("ntp: DF clear", all(f[20:22] == b"\0\0" for f in ipv4))
    queries = [f for f in frames if is_ntp(f)]
    check("ntp: the queries, version 4, mode 3, 48 bytes",
          bool(queries) and all(len(f) == 90 and f[42] == 0x23 and f[43:82] == bytes(39)
                                for f in queries))
    by_server: Dict[bytes, Set[bytes]] = {}
    for q in queries:
        by_server.setdefault(q[30:34], set()).add(q[PORT_AT:PORT_AT + 2] + q[TS_AT:TS_AT + 8])
    check("ntp: one port and one timestamp for the sends of a command",
          all(len(v) == 1 for v in by_server.values()))
    ports = [struct.unpack(">H", f[PORT_AT:PORT_AT + 2])[0] for f in queries]
    check("ntp: the ports 49152 to 65535", all(49152 <= p <= 65535 for p in ports))
    with open(out, "w") as f:
        f.write("\n".join(report) + "\n")
    try:
        with open(expected) as f:
            same = f.read() == "\n".join(report) + "\n"
    except FileNotFoundError:
        same = False
    check(f"ntp: the output as {os.path.basename(expected)}", same)
    if not same:
        subprocess.run(["diff", expected, out])
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
