#!/usr/bin/env python3
"""Run the monitor's DHCP exchange in the background in niceemu, against
frames of --eth-in (issue #126).

Usage: test/bgdhcp.py NICEEMU MONITOR.bin

The monitor runs with --step-time, so that a microsecond is a step and a
run counts the same each time, and with no input, or a line of it, after
which the console reads nothing and getline waits for a key, and carries
the exchange on, until the run's steps are done. The first run has no
frames, and gives the transaction, which the replies of the next runs
take. The cases:
- quiet: 1,900,000 steps, before the first DISCOVER: no frame.
- first: 2,200,000 steps: the first DISCOVER.
- backoff: 40,000,000 steps: four DISCOVERs, 4, 8, and 16 seconds apart
  and up to a second more, so the fourth about 30 seconds in.
- typed: i 10.0.0.9 typed first, which ends the exchange: no frame.
- ok: an OFFER after the DISCOVER, and the ACK after the REQUEST, with a
  lease of 200 seconds and T1 5: the line of the address over the
  prompt, the prompt again, the address in NET_IP, the port enabled, as
  the lease is kept, and the lease's REQUEST to the server by unicast at
  T1, 5 seconds after the ACK.
- nak: an OFFER, a NAK of the REQUEST, which sends the next DISCOVER at
  once, and an OFFER and an ACK of another address.
Each DISCOVER and REQUEST is checked: broadcast, from 0.0.0.0, with the
broadcast flag, and of the first run's transaction. Exits with status 1
when a check fails. Only the Python standard library is used.
"""

import os
import struct
import subprocess
import sys
import tempfile
from typing import List, Optional, Tuple

from dhcp import BCAST, MAC, XID_AT, ip, reply

SERVER_MAC = bytes.fromhex("0A0000000001")  # the source of dhcp.py's replies
DUMPS = ["-d", "0xFFFFFFB0:1", "-d", "0xFFFFFFC0:1"]
PROMPT = "> "


def run(emu: str, monitor: str, steps: int, keys: bytes,
        eth_in: Optional[str], tmp: str, name: str
        ) -> Tuple[str, List[int], List[bytes]]:
    """The console output of a run, its two dumped words, NET_IP and
    ETH_CSR, and its frames sent."""
    inp = os.path.join(tmp, name + ".keys")
    with open(inp, "wb") as f:
        f.write(keys)
    out = os.path.join(tmp, name + ".out")
    args = [emu, "-n", str(steps), "--step-time", "-i", inp,
            "--eth-out", out] + DUMPS
    if eth_in is not None:
        path = os.path.join(tmp, name + ".in")
        with open(path, "w") as f:
            f.write(eth_in)
        args += ["--eth-in", path]
    res = subprocess.run(args + [monitor], capture_output=True)
    text = res.stdout.decode("latin-1")
    words = []
    for line in text.split("\n"):
        parts = line.split()
        if len(parts) == 2 and parts[0] in ("ffffffb0:", "ffffffc0:"):
            words.append(int(parts[1], 16))
    with open(out) as f:
        frames = [bytes.fromhex(line) for line in f if line.strip()]
    return text, words, frames


def dhcp_type(frame: bytes) -> int:
    """The message type of option 53 of a DHCP frame that the monitor
    sent, which it puts first, or 0."""
    at = 14 + 20 + 8 + 240
    if len(frame) > at + 2 and frame[at] == 53:
        return frame[at + 2]
    return 0


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(str(__doc__).split("\n\n")[1])
    emu, monitor = sys.argv[1:]
    fails = 0

    def check(name: str, ok: bool, detail: str = "") -> None:
        nonlocal fails
        print(f"[{'PASS' if ok else 'FAIL'}] bgdhcp {name}"
              + (f": {detail}" if detail and not ok else ""))
        fails += not ok

    def broadcast(name: str, frames: List[bytes], xid: int) -> None:
        for n, f in enumerate(frames):
            if dhcp_type(f) not in (1, 3):
                continue
            ok = (f[:6] == BCAST and f[26:30] == bytes(4)
                  and f[30:34] == b"\xff" * 4
                  and f[XID_AT:XID_AT + 4] == struct.pack(">I", xid)
                  and f[XID_AT + 6] & 0x80 != 0)
            check(f"{name}: frame {n + 1} broadcast, from 0.0.0.0, with "
                  "the flag and the transaction", ok)

    with tempfile.TemporaryDirectory() as tmp:
        _, words, frames = run(emu, monitor, 1_900_000, b"", None, tmp,
                               "quiet")
        check("quiet: no frame before 2 seconds", frames == [],
              str(len(frames)))
        _, words, frames = run(emu, monitor, 2_200_000, b"", None, tmp,
                               "first")
        check("first: one DISCOVER after 2 seconds",
              [dhcp_type(f) for f in frames] == [1],
              str([dhcp_type(f) for f in frames]))
        if not frames:
            sys.exit(1)
        xid = struct.unpack(">I", frames[0][XID_AT:XID_AT + 4])[0]
        broadcast("first", frames, xid)
        check("first: no address, and the port enabled", words == [0, 1],
              str(words))

        # The fourth DISCOVER is due at 2 + 4 + 8 + 16 = 30 seconds, and
        # up to 3 more; the fifth at 62 at the earliest
        _, words, frames = run(emu, monitor, 34_000_000, b"", None, tmp,
                               "backoff")
        check("backoff: four DISCOVERs in 34 seconds",
              [dhcp_type(f) for f in frames] == [1] * 4,
              str([dhcp_type(f) for f in frames]))
        broadcast("backoff", frames, xid)
        _, words, frames = run(emu, monitor, 29_000_000, b"", None, tmp,
                               "backoff3")
        check("backoff: three DISCOVERs in 29 seconds", len(frames) == 3,
              str(len(frames)))

        text, words, frames = run(emu, monitor, 10_000_000, b"i 10.0.0.9\r",
                                  None, tmp, "typed")
        check("typed: i ends the exchange, no frame", frames == [],
              str(len(frames)))
        check("typed: the address typed, and the port disabled",
              words == [0x0A000009, 0], str(words))

        opts = bytes([1, 4]) + ip("255.255.255.0") + bytes([3, 4]) \
            + ip("192.168.1.1") + bytes([51, 4]) + struct.pack(">I", 200) \
            + bytes([58, 4]) + struct.pack(">I", 5)
        ok_in = "\n".join([
            "1:" + reply(xid, 2, "192.168.1.50", "192.168.1.1", MAC, opts),
            "2:" + reply(xid, 5, "192.168.1.50", "192.168.1.1", BCAST, opts),
            ""])
        text, words, frames = run(emu, monitor, 9_000_000, b"", ok_in, tmp,
                                  "ok")
        shown = PROMPT + "\rIP address 192.168.1.50 from DHCP\r\n" + PROMPT
        check("ok: the address shown over the prompt, and the prompt again",
              shown in text, repr(text[-120:]))
        check("ok: the address set, and the port enabled for the lease",
              words == [0xC0A80132, 1], str([f"{w:08X}" for w in words]))
        types = [dhcp_type(f) for f in frames]
        check("ok: DISCOVER, REQUEST, and the lease's REQUEST at T1",
              types == [1, 3, 3], str(types))
        broadcast("ok", frames[:2], xid)
        if len(frames) == 3:
            f = frames[2]
            check("ok: the lease's REQUEST by unicast to the server, from "
                  "192.168.1.50",
                  f[:6] == SERVER_MAC and f[26:30] == ip("192.168.1.50")
                  and f[30:34] == ip("192.168.1.1"))

        nak_in = "\n".join([
            "1:" + reply(xid, 2, "192.168.1.50", "192.168.1.1"),
            "2:" + reply(xid, 6, "0.0.0.0", "192.168.1.1"),
            "3:" + reply(xid, 2, "192.168.1.51", "192.168.1.1", BCAST, opts),
            "4:" + reply(xid, 5, "192.168.1.51", "192.168.1.1", BCAST, opts),
            ""])
        text, words, frames = run(emu, monitor, 3_000_000, b"", nak_in, tmp,
                                  "nak")
        types = [dhcp_type(f) for f in frames]
        check("nak: DISCOVER, REQUEST, DISCOVER at once, REQUEST",
              types == [1, 3, 1, 3], str(types))
        broadcast("nak", frames, xid)
        check("nak: the second address shown",
              "IP address 192.168.1.51 from DHCP" in text, repr(text[-120:]))
        check("nak: the second address set", words[:1] == [0xC0A80133],
              str([f"{w:08X}" for w in words]))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
