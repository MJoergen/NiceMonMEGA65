#!/usr/bin/env python3
"""Run the renewal of the DHCP lease in niceemu, against frames of --eth-in.

Usage: test/lease.py NICEEMU MONITOR.bin LEASE.bin

LEASE.bin, test/lease.nasm, runs under the monitor with the input r and
h, and --step-time, so that a microsecond is a step and a run counts
the same each time. It takes a lease with net_dhcp, opens the UDP
endpoint, which keeps the network on, and polls for the case's time,
noting when it sent a frame. Each case is run again with the answers to
the frames that the last run sent, until it needs no new one, as
tools/tcptest.py runs TCP's timers. The cases, each with an OFFER and an
ACK of 192.168.1.50 from 192.168.1.1, with a lease of 200 seconds, T1 5,
and T2 100, unless they say otherwise:
- 1, renew: no answer to the renewal. A REQUEST to the server by unicast
  at T1, and again 60 ticks of arp_tick later; one broadcast at T2, and
  60 ticks later; then the lease's end, after which nothing is sent.
- 2, ack: the first REQUEST gets an ACK, which starts the lease again, so
  that the next REQUEST is at T1 again; its ACK is of 192.168.1.51 with
  a lease of 0xFFFFFFFF: the address is taken, and never renewed.
- 3, nak: the first REQUEST gets a NAK; the lease is forgotten, and the
  address stays.
- 4, long: a lease of 3000 seconds, with no T1 and T2: the first REQUEST
  at half of it, 1500 seconds, past the housekeeping deadline of 2^30
  microseconds.
- 5, forever: a lease of 0xFFFFFFFF, which is not kept.
The script checks the program's results, the times of the frames, and
each REQUEST of a renewal: by unicast to the server's MAC and IP
addresses, or broadcast; from 192.168.1.50, with it in ciaddr; with no
broadcast flag, and no options 50 and 54. Exits with status 1 when a
check fails. Only the Python standard library is used.
"""

import os
import re
import struct
import subprocess
import sys
import tempfile
from typing import Dict, List, Tuple

from dhcp import BCAST, MAC, XID_AT, ip, reply

SERVER_MAC = bytes.fromhex("0A0000000001")  # the source of dhcp.py's replies
RESULTS = 0x9100
S = 1_000_000
TICK = 1 << 20                           # arp_tick's, in microseconds
SLACK = 1_200_000                        # a tick, and a poll's period
FOREVER = 0xFFFFFFFF


def ticks(sec: int) -> int:
    """lease_ticks of the monitor: seconds in ticks of arp_tick."""
    return sec - (sec >> 4) + (sec >> 6)


def lease_opts(lease: int, t1: int = 0, t2: int = 0) -> bytes:
    opts = bytes([1, 4]) + ip("255.255.255.0") + bytes([3, 4]) + ip("192.168.1.1") \
        + bytes([51, 4]) + struct.pack(">I", lease)
    if t1:
        opts += bytes([58, 4]) + struct.pack(">I", t1)
    if t2:
        opts += bytes([59, 4]) + struct.pack(">I", t2)
    return opts


def options(frame: bytes) -> Dict[int, bytes]:
    """The DHCP options of a frame that the monitor sent."""
    out: Dict[int, bytes] = {}
    at = 14 + 20 + 8 + 240
    while at < len(frame) and frame[at] != 255:
        if frame[at] == 0:
            at += 1
            continue
        out[frame[at]] = frame[at + 2:at + 2 + frame[at + 1]]
        at += 2 + frame[at + 1]
    return out


def answers(case: int, frames: List[bytes]) -> List[str]:
    """The lines of --eth-in that answer the frames of a run of a case."""
    if not frames:
        return []
    xid = struct.unpack(">I", frames[0][XID_AT:XID_AT + 4])[0]
    first = {4: lease_opts(3000), 5: lease_opts(FOREVER)}.get(case, lease_opts(200, 5, 100))
    lines = ["1:" + reply(xid, 2, "192.168.1.50", "192.168.1.1", MAC, first)]
    if len(frames) >= 2:
        lines.append("2:" + reply(xid, 5, "192.168.1.50", "192.168.1.1", BCAST, first))
    if case == 2 and len(frames) >= 3:
        lines.append("3:" + reply(xid, 5, "192.168.1.50", "192.168.1.1", MAC,
                                  lease_opts(200, 5, 100)))
    if case == 2 and len(frames) >= 4:
        lines.append("4:" + reply(xid, 5, "192.168.1.51", "192.168.1.1", MAC,
                                  lease_opts(FOREVER)))
    if case == 3 and len(frames) >= 3:
        lines.append("3:" + reply(xid, 6, "0.0.0.0", "192.168.1.1", MAC))
    return lines


def run_case(emu: str, monitor: str, prog: str, tmp: str,
             case: int) -> Tuple[List[int], List[bytes], str]:
    """A case, run until its answers are complete: its results, its
    frames, and its console output."""
    image = os.path.join(tmp, f"lease{case}.bin")
    with open(image, "w") as f:
        f.write(open(monitor).read() + open(prog).read() + f"00009000 {case:08X}\n")
    inp = os.path.join(tmp, "input")
    with open(inp, "w") as f:
        f.write("r\rh\r")
    eth_in = os.path.join(tmp, f"in{case}")
    eth_out = os.path.join(tmp, f"out{case}")
    lines: List[str] = []
    out = ""
    frames: List[bytes] = []
    for _ in range(10):
        with open(eth_in, "w") as f:
            f.write("".join(line + "\n" for line in lines))
        res = subprocess.run([emu, "--step-time", "-n", "20000000000", "-i", inp, "-d",
                              f"{RESULTS:#x}:16", "--eth-in", eth_in, "--eth-out", eth_out,
                              image], capture_output=True, timeout=600)
        out = res.stdout.decode("latin-1")
        frames = [bytes.fromhex(line) for line in open(eth_out).read().splitlines() if line]
        new = answers(case, frames)
        if new == lines:
            break
        lines = new
    words: Dict[int, int] = {}
    for m in re.finditer(r"^([0-9A-Fa-f]{8}):((?: [0-9A-Fa-f]{8})+)", out, re.M):
        for k, w in enumerate(m[2].split()):
            words[int(m[1], 16) + k] = int(w, 16)
    return [words.get(RESULTS + k, 0) for k in range(16)], frames, out


def main() -> None:
    if len(sys.argv) != 4:
        sys.exit(str(__doc__).split("\n\n")[1])
    emu, monitor, prog = sys.argv[1:]
    fails = 0

    def check(name: str, ok: bool, detail: str = "") -> None:
        nonlocal fails
        print(f"[{'PASS' if ok else 'FAIL'}] {name}" + ("" if ok or not detail else f": {detail}"))
        fails += not ok

    def near(got: int, want: float) -> bool:
        return want - SLACK <= got <= want + SLACK

    def renewal(f: bytes, unicast: bool, src: str = "192.168.1.50") -> bool:
        opts = options(f)
        dst_mac, dst_ip = (SERVER_MAC, ip("192.168.1.1")) if unicast else (BCAST, ip("255.255.255.255"))
        return (f[0:6] == dst_mac and f[26:30] == ip(src) and f[30:34] == dst_ip
                and f[34:38] == bytes.fromhex("00440043") and f[42 + 10:42 + 12] == b"\0\0"
                and f[42 + 12:42 + 16] == ip(src) and opts.get(53) == b"\x03"
                and 50 not in opts and 54 not in opts)

    with tempfile.TemporaryDirectory() as tmp:
        for case in range(1, 6):
            r, frames, out = run_case(emu, monitor, prog, tmp, case)
            name = f"lease {case}"
            check(f"{name}: the program returns 16", "Returned 00000010" in out, out[-300:])
            check(f"{name}: net_dhcp 0, udp_open 5000", r[0] == 0 and r[1] == 5000, str(r))
            check(f"{name}: the endpoint closed, the port off", r[14] == 0 and r[15] == 0, str(r))
            sends = r[11]
            times = r[3:3 + min(sends, 8)]
            renew = frames[2:]
            check(f"{name}: a frame for each time", len(renew) == sends,
                  f"{len(renew)} frames, {sends} sends")
            t1, t2 = ticks(5) * TICK, ticks(100) * TICK
            again = 60 * TICK
            if case == 1:
                check(f"{name}: a lease kept", r[2] == 1)
                check(f"{name}: 4 REQUESTs, at T1, 60 ticks later, T2, and 60 ticks later",
                      sends == 4 and near(times[0], t1) and near(times[1], t1 + again)
                      and near(times[2], t2) and near(times[3], t2 + again), str(times))
                check(f"{name}: 2 by unicast, then 2 broadcast",
                      len(renew) == 4 and all(renewal(f, k < 2) for k, f in enumerate(renew)))
                check(f"{name}: the lease forgotten at its end, the address kept",
                      r[12] == 0 and r[13] == 0xC0A80132)
            elif case == 2:
                check(f"{name}: 2 REQUESTs by unicast, at T1, and T1 after the ACK",
                      sends == 2 and near(times[0], t1) and near(times[1], times[0] + t1)
                      and all(renewal(f, True) for f in renew), str(times))
                check(f"{name}: the address of the second ACK, and a lease forever, not kept",
                      r[12] == 0 and r[13] == 0xC0A80133, str(r))
            elif case == 3:
                check(f"{name}: 1 REQUEST by unicast at T1",
                      sends == 1 and near(times[0], t1) and renewal(renew[0], True), str(times))
                check(f"{name}: the lease forgotten after the NAK, the address kept",
                      r[12] == 0 and r[13] == 0xC0A80132, str(r))
            elif case == 4:
                check(f"{name}: 1 REQUEST by unicast at half the lease, past 2^30 microseconds",
                      sends == 1 and near(times[0], ticks(1500) * TICK)
                      and renewal(renew[0], True), str(times))
                check(f"{name}: the lease kept", r[12] == 1)
            else:
                check(f"{name}: a lease forever not kept, nothing sent",
                      r[2] == 0 and sends == 0 and r[12] == 0 and r[13] == 0xC0A80132, str(r))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
