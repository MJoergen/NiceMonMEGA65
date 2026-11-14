#!/usr/bin/env python3
"""Check the monitor's TCP, its clients and its servers, without a board
(issue #111).

It runs the monitor of the tests with monitor/build/tcp.bin, the program
of monitor/test/tcp.nasm, in niceemu with --eth-udp and --eth-peer,
whose frames go to tools/tcppeer.py, the host 10.0.0.2, and checks the
results that the program stores, and what the peer saw. Each case of the
program connects to a port of its own, whose Script here decides what
the peer does. In the cases where the program listens, a datagram from
it names the case, and Listening here connects to it.

It prints a line for each check, and last how many passed, and exits with
status 1 when one fails. niceemu must be built, with make -C
nice_cpu/emulator build, and so must the program, with make -C monitor
build/tcp.bin. Only the Python standard library is used.
"""

import os
import re
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from typing import Callable, Dict, List, Mapping, Optional, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tcppeer import (ACK, BOARD_IP, FIN, PEER_IP, PEER_MAC, PSH, RST, SYN, Conn,  # noqa: E402
                     Peer, Script, Segment, arp_reply, ip_frame, is_arp_for_peer,
                     mss_option, tcp_payload)

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NICEEMU = os.path.join(REPO, "nice_cpu", "emulator", "zig-out", "bin", "niceemu")
MONITOR = os.path.join(REPO, "monitor", "build", "monitor_test.bin")
PROGRAM = os.path.join(REPO, "monitor", "build", "tcp.bin")
TIMERS = os.path.join(REPO, "monitor", "build", "tcpt.bin")
PROGRAM_C = os.path.join(REPO, "monitor", "build", "tcp_c.bin")
PROGRAM_HW = os.path.join(REPO, "monitor", "build", "tcphw.bin")
RESULTS = 0x9100
E_NOIP, E_TCLOSED = -40, -56

passed = 0
failed = 0


def check(name: str, ok: bool, detail: str = "") -> None:
    global passed, failed
    print(f"[{'PASS' if ok else 'FAIL'}] {name}" + ("" if ok or not detail else f": {detail}"))
    if ok:
        passed += 1
    else:
        failed += 1


def pattern(n: int, start: int, step: int) -> bytes:
    return bytes((start + i * step) & 0xFF for i in range(n))


def hash31(data: bytes) -> int:
    h = 0
    for b in data:
        h = (h * 31 + b) & 0xFFFFFFFF
    return signed(h)


def signed(w: int) -> int:
    return w - (1 << 32) if w & 0x80000000 else w


# The scripts of the peer, by port, and the data each sends
DATA = {
    2001: pattern(3000, 0, 7),          # the program's, echoed
    2002: pattern(700, 3, 5),
    2004: pattern(50, 1, 1),
    2005: pattern(100, 4, 9),
    2007: pattern(500, 6, 1),
    2012: pattern(1000, 8, 3),
    2013: pattern(3000, 10, 17),
    2014: pattern(4096, 2, 3),
}
SENT = {                                # what the program sends
    2002: pattern(100, 5, 3)[:3] + pattern(100, 5, 3),
    2005: pattern(2000, 9, 11),
    2009: pattern(2000, 1, 13),
    2010: pattern(2000, 1, 13),
    2011: pattern(2000, 1, 13),
}


class Echo(Script):
    """Sends back what it takes; its FIN half a second after the board's,
    so that the program sees TCP_CLOSING."""

    fin_at = 0.0

    def on_data(self, c: Conn, data: bytes) -> None:
        c.send(data)

    def on_fin(self, c: Conn) -> None:
        self.fin_at = time.monotonic()

    def on_tick(self, c: Conn, now: float) -> None:
        if self.fin_at and now - self.fin_at > 0.5 and not c.fin_queued:
            c.close()


class PeerCloses(Script):
    """After 3 bytes, 700 and its FIN."""

    def on_data(self, c: Conn, data: bytes) -> None:
        if len(c.received) == 3:
            c.send(DATA[2002])
            c.close()


class Refuse(Script):
    """A RST to the SYN."""

    def on_syn(self, c: Conn, s: Segment) -> bool:
        c.segment(RST | ACK, 0, ack=s.seq + 1)
        c.state = "CLOSED"
        return False


class ResetMid(Script):
    """After 10 bytes, 50 and a RST."""

    def on_data(self, c: Conn, data: bytes) -> None:
        if len(c.received) >= 10 and c.state != "CLOSED":
            c.send(DATA[2004])
            c.rst()


class FinMid(Script):
    """100 bytes and the FIN at the open."""

    def on_open(self, c: Conn) -> None:
        c.send(DATA[2005])
        c.close()

    def on_fin(self, c: Conn) -> None:
        pass


class Connecting(Script):
    """The first SYN gets a RST without an ACK, a SYN without one, and an
    ACK of an old connection; the next SYN, the SYN-ACK."""

    syns = 0

    def on_syn(self, c: Conn, s: Segment) -> bool:
        self.syns += 1
        if self.syns > 1:
            return True
        c.segment(RST, 0)
        c.segment(SYN, 777)
        c.segment(ACK, 778, ack=s.seq + 5000)
        return False

    def on_segment(self, c: Conn, s: Segment) -> bool:
        return not s.flags & RST        # the board's answer to the old ACK


class DropAfterClose(Script):
    """500 bytes at the open; 0.3 seconds after the board's FIN, 300 and
    the FIN."""

    def on_open(self, c: Conn) -> None:
        c.send(DATA[2007])

    fin_at = 0.0

    def on_fin(self, c: Conn) -> None:
        self.fin_at = time.monotonic()

    def on_tick(self, c: Conn, now: float) -> None:
        if self.fin_at and now - self.fin_at > 0.3 and not c.fin_queued:
            c.send(pattern(300, 7, 2))
            c.close()


class NoFinAck(Script):
    """The board's FIN never taken."""

    def on_segment(self, c: Conn, s: Segment) -> bool:
        return not s.flags & FIN


class NoMss(Script):
    mss = None


class SmallWindow(Script):
    """An MSS of 100 and a window of 300, which the board must not
    overrun."""

    mss = 100
    window = 300
    overruns = 0

    def on_segment(self, c: Conn, s: Segment) -> bool:
        if s.data and (s.seq + len(s.data) - c.rcv_nxt) & 0xFFFFFFFF > self.window:
            self.overruns += 1
        return True


class ZeroWindow(Script):
    """After 500 bytes, a window of 0 for 2.5 seconds, with the board's
    probes answered and not taken."""

    window = 4096
    zero_at = 0.0
    probes = 0

    def on_data(self, c: Conn, data: bytes) -> None:
        if len(c.received) >= 500 and not self.zero_at:
            self.zero_at = time.monotonic()
            c.window = 0
            c.ack_now()

    def on_segment(self, c: Conn, s: Segment) -> bool:
        if c.window == 0 and s.data:
            if len(s.data) == 1 and s.seq == c.rcv_nxt:
                self.probes += 1
            c.ack_now()
            return False
        return True

    def on_tick(self, c: Conn, now: float) -> None:
        if self.zero_at and c.window == 0 and now - self.zero_at > 2.5:
            c.window = 4096
            c.ack_now()


class FullRing(Script):
    """1000 bytes into the board's ring of 256. At its zero window, a
    probe and a keepalive, each answered with an ACK, and a pure ACK,
    with no answer, 0.3 seconds apart; then the window opens when the
    program reads."""

    step = 0
    at = 0.0
    mark = 0
    probe_ok = keepalive_ok = pure_ok = False
    zero_seen = update_seen = False

    def on_open(self, c: Conn) -> None:
        c.send(DATA[2012])

    def on_segment(self, c: Conn, s: Segment) -> bool:
        if self.step >= 4 and s.flags & ACK and s.win > 0 and not s.data:
            self.update_seen = True
        return True

    def answered(self, c: Conn, ack: int) -> bool:
        return any(s.flags & ACK and s.ack == ack and s.win == 0 and not s.data
                   for s in c.log[self.mark:])

    def on_tick(self, c: Conn, now: float) -> None:
        if self.step == 0:
            if c.board_win == 0 and c.snd_una == c.snd_nxt and c.out:
                self.zero_seen = True
                self.step, self.at, self.mark = 1, now, len(c.log)
                c.segment(ACK, c.snd_nxt, c.out[:1])      # a probe
        elif now - self.at < 0.3:
            return
        elif self.step == 1:
            self.probe_ok = self.answered(c, c.snd_una)
            self.step, self.at, self.mark = 2, now, len(c.log)
            c.segment(ACK, c.snd_una - 1)                # a keepalive
        elif self.step == 2:
            self.keepalive_ok = self.answered(c, c.snd_una)
            self.step, self.at, self.mark = 3, now, len(c.log)
            c.segment(ACK, c.snd_una)                    # a pure ACK
        elif self.step == 3:
            self.pure_ok = len(c.log) == self.mark
            self.step = 4


class Disorder(Script):
    """3000 bytes in segments of 100: the third left out, to be sent
    again, the fifth twice, the sixth first with a bad checksum, ARP and
    UDP broadcasts among them, and the 11th to the 30th in one burst."""

    def on_open(self, c: Conn) -> None:
        data = DATA[2013]
        c.out = data
        base = c.snd_una

        def seg(i: int, bad: bool = False) -> None:
            c.segment(ACK | PSH, base + 100 * i, data[100 * i:100 * i + 100], bad=bad)

        for i in (0, 1, 3, 4, 4):
            seg(i)
        seg(5, bad=True)
        seg(5)
        c.peer.to_emu(b"\xff" * 6 + PEER_MAC + b"\x08\x06" + bytes.fromhex("0001080006040001")
                      + PEER_MAC + PEER_IP + bytes(6) + bytes([10, 0, 0, 99]))
        udp = struct.pack(">HHHH", 9999, 9999, 12, 0) + b"noise"
        c.peer.send_ip(b"\xff" * 6, b"\xff" * 4, 17, udp)
        for i in range(6, 30):
            seg(i)
        c.snd_nxt = (base + 3000) & 0xFFFFFFFF
        c.last_send = time.monotonic()


class Budget(Script):
    """N: after the program's byte, 4096, the window it had alone."""

    def on_data(self, c: Conn, data: bytes) -> None:
        if len(c.received) == 1:
            c.send(DATA[2014])


# The listening cases: the data that the peer's connections send
LDATA = {
    "T": pattern(1000, 11, 5),
    "V1": pattern(10, 1, 2),
    "V2": pattern(20, 2, 3),
    "V3": pattern(30, 3, 4),
    "W": pattern(40, 4, 5),
}
SIG_PORT = 7000                         # the program's datagrams, which name the case


class OneSyn(Script):
    """A SYN, once, to a port where nothing listens."""

    syn_retry = 1e9


class DataInAck(Script):
    """T: 1000 bytes and the FIN, the first segment the ACK of the
    SYN-ACK."""

    data_in_ack = True

    def on_open(self, c: Conn) -> None:
        c.send(LDATA["T"])
        c.close()


class RepeatFin(Script):
    """U: the peer's FIN after the board's, and 0.2 seconds after the
    board acknowledged it, the FIN again, as if that ACK were lost."""

    acked_at = 0.0
    again = False

    def on_tick(self, c: Conn, now: float) -> None:
        if self.again or not c.fin_sent or c.snd_una != c.snd_nxt:
            return
        if not self.acked_at:
            self.acked_at = now
        elif now - self.acked_at > 0.2:
            self.again = True
            c.segment(ACK | FIN, c.snd_nxt - 1)


class Busy(Script):
    """V: three peers to a port where two handles listen. The first opens
    the second, the second the third, whose SYN goes every second; the
    first sends its bytes and FIN 1.5 seconds after the third's first
    SYN, and the second when the third opens."""

    shared: Dict[str, Conn] = {}
    third_at = 0.0

    def __init__(self, n: int) -> None:
        self.n = n
        self.syn_retry = 1.0 if n == 3 else 0.3
        self.sent = False

    def on_open(self, c: Conn) -> None:
        if self.n < 3:
            nxt = c.peer.connect(3003, Busy(self.n + 1))
            Busy.shared[f"V{self.n + 1}"] = nxt
            if self.n == 2:
                Busy.third_at = time.monotonic()
        else:
            c.send(LDATA["V3"])
            c.close()
            two = Busy.shared["V2"]
            two.send(LDATA["V2"])
            two.close()

    def on_tick(self, c: Conn, now: float) -> None:
        if self.n == 1 and not self.sent and Busy.third_at and now - Busy.third_at > 1.5:
            self.sent = True
            c.send(LDATA["V1"])
            c.close()


class SynRcvd(Script):
    """W: the board's SYN-ACK answered with the SYN again; the second
    with an ACK of the wrong number; its RST with a RST in the window;
    then 0.3 seconds later another peer connects, and sends 40 bytes."""

    def __init__(self) -> None:
        self.syn_retry = 1e9
        self.synacks: List[Segment] = []
        self.rst_at = 0.0
        self.second: Optional[Conn] = None

    def on_synack(self, c: Conn, s: Segment) -> bool:
        self.synacks.append(s)
        if len(self.synacks) == 1:
            c.segment(SYN, c.iss, options=mss_option(1460))
        elif len(self.synacks) == 2:
            c.segment(ACK, c.iss + 1, ack=s.seq + 1000)
        return False

    def on_tick(self, c: Conn, now: float) -> None:
        if c.rsts and not self.rst_at:
            self.rst_at = now
            c.segment(RST, c.iss + 1)
        elif self.rst_at and self.second is None and now - self.rst_at > 0.3:
            self.second = c.peer.connect(3004, Sender(LDATA["W"]))


class Sender(Script):
    """Its bytes and the FIN at the open."""

    def __init__(self, data: bytes) -> None:
        self.data = data

    def on_open(self, c: Conn) -> None:
        c.send(self.data)
        c.close()


class Ask(Script):
    """Its bytes at the open, and its FIN once as many came back."""

    def __init__(self, data: bytes) -> None:
        self.data = data

    def on_open(self, c: Conn) -> None:
        c.send(self.data)

    def on_data(self, c: Conn, data: bytes) -> None:
        if len(c.received) >= len(self.data):
            c.close()


def connect_at_start(port: int, script: Script) -> Callable[[Peer], None]:
    """A setup of run: the peer connects to the port from the start, its
    SYN again every 0.3 seconds until the board listens there."""
    def setup(peer: Peer) -> None:
        with peer.lock:
            peer.connect(port, script)
    return setup


class Listening:
    """The peer's side of the listening cases of tcp.nasm, started by the
    program's datagrams to SIG_PORT, each the number of a case."""

    def __init__(self, peer: Peer) -> None:
        self.peer = peer
        self.conns: Dict[str, Conn] = {}
        peer.on_udp = self.signal
        Busy.shared = self.conns
        Busy.third_at = 0.0

    def signal(self, port: int, data: bytes) -> None:
        if port != SIG_PORT or len(data) != 1:
            return
        case = data[0]
        p = self.peer
        if case == 1:
            p.send_ip(b"\xff" * 6, BOARD_IP, 6,
                      tcp_payload(BOARD_IP, 41000, 3001, 123, 5555, ACK, 8192))
            self.conns["T0"] = p.connect(3099, OneSyn())
            self.conns["T"] = p.connect(3001, DataInAck())
        elif case == 2:
            self.conns["U"] = p.connect(3002, RepeatFin())
        elif case == 3:
            self.conns["V1"] = p.connect(3003, Busy(1))
        elif case == 4:
            self.conns["W"] = p.connect(3004, SynRcvd())


SCRIPTS = {
    2001: Echo,
    2002: PeerCloses,
    2003: Refuse,
    2004: ResetMid,
    2005: FinMid,
    2006: Connecting,
    2007: DropAfterClose,
    2008: NoFinAck,
    2009: NoMss,
    2010: SmallWindow,
    2011: ZeroWindow,
    2012: FullRing,
    2013: Disorder,
    2014: Budget,
    2015: Script,
    2016: Script,
    2017: Script,
}


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.bind(("127.0.0.1", 0))
        port: int = s.getsockname()[1]
        return port


def run(tmp: str, program: str, scripts: Mapping[int, Callable[[], Script]], keys: str = "r\rh\r",
        extra: str = "", setup: Optional[Callable[[Peer], None]] = None) -> Tuple[List[int], int]:
    """A program run against a peer with scripts, which becomes PEER, with
    the monitor's input keys, the lines of a .bin file extra, and setup
    called with the peer before it runs: the words it stores from
    RESULTS on, and the value it returns."""
    peer = Peer()
    for port, script in scripts.items():
        peer.listen(port, script)
    peer.emu_port = free_port()
    if setup is not None:
        setup(peer)
    thread = threading.Thread(target=peer.run, daemon=True)
    thread.start()
    image = os.path.join(tmp, "tcp.full.bin")
    with open(image, "w") as f:
        f.write(open(MONITOR).read() + open(program).read() + extra)
    inp = os.path.join(tmp, "input")
    with open(inp, "w") as f:
        f.write(keys)
    name = os.path.basename(program)
    out = ""
    try:
        res = subprocess.run(
            [NICEEMU, "-i", inp, "-d", f"{RESULTS:#x}:256", "--eth-udp",
             f"127.0.0.1:{peer.emu_port}", "--eth-peer", f"127.0.0.1:{peer.port}", image],
            capture_output=True, timeout=300)
        out = res.stdout.decode("latin-1").replace("\r", "")
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode("latin-1").replace("\r", "")
        check(f"{name}: niceemu halts", False, "timeout")
    peer.stop = True
    thread.join()
    global PEER
    PEER = peer
    words: Dict[int, int] = {}
    for m in re.finditer(r"^([0-9A-Fa-f]{8}):((?: [0-9A-Fa-f]{8})+)", out, re.M):
        a = int(m[1], 16)
        for k, w in enumerate(m[2].split()):
            words[a + k] = int(w, 16)
    n = re.search(r"Returned ([0-9A-F]{8})", out)
    check(f"{name}: the program returns", n is not None, out[-800:])
    value = signed(int(n[1], 16)) if n else -1
    return [signed(words.get(RESULTS + k, 0)) for k in range(max(value, 0))], value


PEER: Peer


class Results:
    """The program's results, read in the order it stores them."""

    def __init__(self, words: List[int]) -> None:
        self.words = words
        self.i = 0

    def take(self) -> int:
        w = self.words[self.i] if self.i < len(self.words) else -9999
        self.i += 1
        return w

    def expect(self, name: str, *want: int) -> List[int]:
        got = [self.take() for _ in want]
        check(name, got == list(want), f"got {got}, expected {list(want)}")
        return got


def conn(port: int, n: int = 0) -> Conn:
    cs = PEER.conns_on(port)
    if n >= len(cs):
        sys.exit(f"tcptest.py: no connection {n} to port {port}; the program stopped early")
    return cs[n]


def board_data(c: Conn) -> List[Segment]:
    return [s for s in c.log if s.data]


def checks(r: Results) -> None:
    peer = PEER
    T = 2                               # TCP_OPEN
    r.expect("tcp_open and tcp_listen without an IP address give E_NOIP", E_NOIP, E_NOIP)
    r.expect("tcp_open gives E_PORT for the ports 0 and 65536", -41, -41)
    r.expect("tcp_open gives E_TSIZE for a ring of 63 bytes, received or sent", -52, -52)
    r.expect("tcp_open gives E_TSIZE for a block not aligned, or below 0x8000", -52, -52)
    r.expect("tcp_open gives E_NOROUTE for a host with no ARP, and the broadcast", -44, -44)
    check("ARP asked for 10.0.0.77, not for the broadcast",
          bytes([10, 0, 0, 77]) in peer.arps and b"\xff" * 4 not in peer.arps)
    r.expect("tcp_state gives E_THANDLE for 4 and -1, and 0 for a free handle", -50, -50, 0)
    r.expect("tcp_send, tcp_recv, and tcp_close give E_THANDLE on a free handle", -50, -50, -50)

    r.expect("N: opens with handle 0", 0, T)

    # A, the echo
    r.expect("A: opens at a word-window address, and echoes 3000 bytes", 1, 3000, 3000,
             hash31(DATA[2001]))
    r.expect("A: tcp_close gives 0, then TCP_CLOSING", 0, 4)
    r.expect("A: then tcp_recv and tcp_send give E_TCLOSED", E_TCLOSED, E_TCLOSED)
    r.expect("A: the handle frees itself", 0)
    a = conn(2001)
    check("A: the peer received the 3000 bytes", a.received == DATA[2001])
    check("A: the SYN has an MSS of 1024, its ring, and a window of 1024",
          a.log[0].mss() == 1024 and a.log[0].win == 1024 and a.log[0].flags == SYN,
          f"{a.log[0]} {a.log[0].options.hex()}")
    check("M: the SYN has an MSS of 1460, less than its ring of 4096",
          conn(2013).log[0].mss() == 1460)
    check("A: the board's FIN came, and it ACKed the peer's",
          a.got_fin and a.acks()[-1] == a.snd_nxt and not a.reset)
    check("A: no segment had more than the ring of 1024",
          all(len(s.data) <= 1024 for s in a.log))

    # B, the peer closes first
    r.expect("B: 3 bytes sent; the peer's 700 read, then E_TEOF", 1, T, 3, 700,
             hash31(DATA[2002]), -57)
    r.expect("B: TCP_PEER_CLOSED; 100 bytes sent after it; closed and freed", 3, 100, 0, 0)
    b = conn(2002)
    check("B: the peer received 103 bytes and the FIN", b.received == SENT[2002] and b.got_fin)

    # C, refused
    r.expect("C: a RST to the SYN gives E_TREFUSED; tcp_close frees", 1, -53, 0, 0)
    check("C: no segment after the SYN", len(conn(2003).log) == 1)

    # D, reset
    r.expect("D: the peer's RST gives E_TRESET to tcp_state, tcp_recv, and tcp_send",
             1, T, -54, -54, -54, 0, 0)
    d = conn(2004)
    check("D: the peer received the 10 bytes, and the board sent no RST",
          d.received == SENT[2002][3:13] and not any(s.flags & RST for s in d.log))

    # E, the peer's FIN mid-stream
    r.expect("E: 2000 sent while the peer's 100 and FIN came, then E_TEOF",
             1, T, 2000, 100, hash31(DATA[2005]), -57, 0, 0)
    e = conn(2005)
    check("E: the peer received the 2000 bytes, and the FIN", e.received == SENT[2005]
          and e.got_fin)

    # F, CONNECTING
    got = r.expect("F: opens after the passed-over RST and SYN", 1, T)
    tenths = r.take()
    check("F: opens with the second SYN, a second after the first", 8 <= tenths <= 20,
          f"{tenths} tenths")
    r.expect("F: an abort frees the handle at once", 0, 0)
    f = conn(2006)
    syn = f.log[0]
    rst = [s for s in f.log if s.flags & RST]
    check("F: the old ACK got a RST with its ACK number as the seq, and nothing else",
          len(rst) >= 1 and rst[0].seq == (syn.seq + 5000) & 0xFFFFFFFF and
          rst[0].flags == RST)
    check("F: the abort of an open connection sent a RST", rst[-1].flags & ACK != 0
          and len(rst) == 2, f"{rst}")
    del got

    # G, a close with bytes not read, and bytes after the FIN
    r.expect("G: tcp_close with 500 bytes not read; E_TCLOSED; freed",
             1, T, 0, E_TCLOSED, 0)
    g = conn(2007)
    check("G: the board ACKed the 300 bytes after its FIN, and the peer's FIN, with no RST",
          g.acks()[-1] == g.snd_nxt and not g.reset)

    # H, an abort while closing
    r.expect("H: TCP_CLOSING, then an abort frees the handle", 1, T, 4, 0, 0)
    h = conn(2008)
    check("H: the FIN was sent again, then the abort's RST",
          sum(1 for s in h.log if s.flags & FIN) >= 2 and h.log[-1].flags & RST != 0)

    # I, J, K
    for port, name in ((2009, "I: no MSS option"), (2010, "J: an MSS of 100 and a window of 300"),
                       (2011, "K: a zero window for 2.5 seconds")):
        r.expect(f"{name}: 2000 bytes sent; closed and freed", 1, T, 2000, 0, 0)
        c = conn(port)
        check(f"{name}: the peer received them", c.received == SENT[port] and c.got_fin)
    check("I: no segment over 536 bytes", max(len(s.data) for s in conn(2009).log) == 536)
    check("J: no segment over 100 bytes", max(len(s.data) for s in conn(2010).log) == 100)
    small = conn(2010).script
    assert isinstance(small, SmallWindow)
    check("J: the window of 300 was never overrun", small.overruns == 0)
    zero = conn(2011).script
    assert isinstance(zero, ZeroWindow)
    check("K: the board probed the zero window with a byte", zero.probes >= 1,
          f"{zero.probes} probes")

    # L, the full ring
    r.expect("L: the peer's 1000 bytes read through a ring of 256", 1, T, 0, 1000,
             hash31(DATA[2012]), 0, 0)
    full = conn(2012).script
    assert isinstance(full, FullRing)
    check("L: the board announced a zero window", full.zero_seen)
    check("L: the peer's probe got an ACK", full.probe_ok)
    check("L: the peer's keepalive got an ACK", full.keepalive_ok)
    check("L: the peer's pure ACK got no answer", full.pure_ok)
    check("L: a window update followed the reads", full.update_seen)

    # M, disorder
    r.expect("M: 3000 bytes read in order, after the disorder", 1, T, 0, 3000,
             hash31(DATA[2013]))
    dropped = r.take()
    check("M: ETH_DROPPED counted the burst", dropped > 0, f"{dropped}")
    r.expect("M: closed and freed", 0, 0)

    # O, four at once
    r.expect("O: three more connections, four with N", 1, T, 2, T, 3, T)
    r.expect("O: a fifth gives E_TFULL", -51)
    r.expect("O: the three closed and freed", 0, 0, 0, 0, 0, 0)
    ports = [conn(2014).bport] + [c.bport for c in PEER.conns_on(2015)]
    check("O: four distinct local ports", len(set(ports)) == 4, f"{ports}")

    # P, the budget, and the wrap of the clock
    r.expect("P: opens", 1, T)
    us = r.take() & 0xFFFFFFFF
    check("P: the clock is past its wrap, 4 seconds after the start",
          4_000_000 < us < 60_000_000, f"{us} us")
    r.expect("N: a byte; the peer's 4096 bytes read, across the wrap", 1, 4096,
             hash31(DATA[2014]))
    r.expect("P: closed and freed", 0, 0)
    p = conn(2016)
    check("P: its SYN announces half the budget, 2048", p.log[0].win == 2048,
          f"{p.log[0].win}")
    n = conn(2014)
    check("N: announced 2048 or less after P opened, until P closed",
          any(s.win == 2048 and s.when > p.opened for s in n.log))
    check("N: the peer received the byte", n.received == SENT[2009][:1])

    # N's end, and Q
    r.expect("N: closed and freed", 0, 0)
    r.expect("Q: a new IP address gives E_TRESET; closed and freed; a handle in LISTEN "
             "stays, and closes", 0, T, 1, -54, 0, 0, 5, 0)
    listening(r)
    r.expect("the port is off at the end", 0)
    check("every result read", r.i == len(r.words), f"{r.i} of {len(r.words)}")

    # Every frame
    segs = [Segment(f, t) for t, f in peer.frames if f[12:14] == b"\x08\x00" and f[23] == 6]
    check("every IP header's checksum is right", all(s.ip_ok for s in segs))
    check("every TCP checksum is right", all(s.tcp_ok for s in segs),
          f"{[s for s in segs if not s.tcp_ok][:3]}")
    check("every segment from 10.0.0.9, or 10.0.0.10 after the change",
          all(s.src_ip in (bytes([10, 0, 0, 9]), bytes([10, 0, 0, 10])) for s in segs))
    stray = [s for s in peer.no_conn if not s.flags & RST]
    check("no segment outside a connection, but RSTs", not stray, f"{stray[:3]}")


def listening(r: Results) -> None:
    """The checks of the listening cases, R to W."""
    peer = PEER
    L = LISTEN.conns
    T, LS, EOF = 2, 5, -57
    r.expect("the endpoint of the signals opens", SIG_PORT)
    r.expect("R: tcp_listen gives E_PORT for 0, 65536, and 4510, and E_TSIZE for a ring of "
             "63 bytes, and a block not aligned", -41, -41, -41, -52, -52)
    r.expect("S: listens in TCP_LISTEN, takes 5 bytes, has none to read, closes, and frees",
             0, LS, 5, 0, 0, 0)
    check("S: nothing sent from port 3000",
          not any(sg.sport == 3000 for _, f in peer.frames if f[12:14] == b"\x08\x00"
                  and f[23] == 6 for sg in [Segment(f, 0.0)]))
    r.expect("T: listens, and takes 5 bytes", 0, 5)
    opened(r, "T")
    r.expect("T: the peer's 1000 bytes read to E_TEOF; TCP_PEER_CLOSED; closed and freed",
             1000, hash31(LDATA["T"]), EOF, 3, 0, 0)
    t = L["T"]
    check("T: the SYN-ACK has an MSS of 1460, the least of it and the ring of 2048",
          t.log[0].flags == SYN | ACK and t.log[0].mss() == 1460, f"{t.log[:1]}")
    check("T: the 5 bytes taken while listening came after the handshake, then the FIN",
          t.received == b"ABCDE" and t.got_fin and not t.reset, f"{t.received!r}")
    rst = [sg for sg in peer.no_conn if sg.dport == 41000]
    check("T: an ACK to the listening port got a RST with its number",
          len(rst) == 1 and rst[0].flags == RST and rst[0].seq == 5555, f"{rst}")
    t0 = L["T0"]
    check("T: a SYN to port 3099, where nothing listens, got a RST",
          t0.rsts == 1 and t0.log[0].flags == RST | ACK and t0.log[0].ack == t0.iss + 1,
          f"{t0.log}")
    r.expect("U: 100 bytes sent; the board closes first; freed", 0, T, 100, 0, 0)
    u = L["U"]
    check("U: the peer received the 100 bytes and the board's FIN",
          u.received == pattern(100, 9, 1) and u.got_fin)
    script = u.script
    assert isinstance(script, RepeatFin)
    check("U: the peer's FIN again got a RST, at the board's FIN's number plus 1",
          script.again and u.reset and u.log[-1].flags & RST != 0
          and u.log[-1].seq == u.rcv_nxt, f"{u.log[-3:]}")
    r.expect("V: two handles listen on one port, and both open", 0, 1, T, T)
    r.expect("V: the first's 10 bytes read; closed and freed", 10, hash31(LDATA["V1"]), EOF,
             0, 0)
    r.expect("V: the handle listens again", 0)
    opened(r, "V")
    r.expect("V: the third's 30 bytes read; closed and freed", 30, hash31(LDATA["V3"]), EOF,
             0, 0)
    r.expect("V: the second's 20 bytes read; closed and freed", 20, hash31(LDATA["V2"]), EOF,
             0, 0)
    v3 = L["V3"]
    check("V: the third peer's first SYNs were passed over, with no RST, until a handle "
          "listened again", len(v3.syns) >= 2 and v3.rsts == 0 and v3.log[0].flags == SYN | ACK
          and v3.log[0].when > v3.syns[1] - 0.1, f"{len(v3.syns)} SYNs, {v3.rsts} RSTs")
    check("V: every peer got its FIN", all(L[k].got_fin for k in ("V1", "V2", "V3")))
    r.expect("W: listens", 0)
    opened(r, "W: back in LISTEN after a RST in SYN-RECEIVED, then")
    r.expect("W: the second peer's 40 bytes read; closed and freed", 40, hash31(LDATA["W"]),
             EOF, 0, 0)
    w = L["W"]
    sr = w.script
    assert isinstance(sr, SynRcvd)
    rsts = [sg for sg in w.log if sg.flags & RST]
    check("W: the SYN again got the same SYN-ACK again",
          len(sr.synacks) == 2 and sr.synacks[0].seq == sr.synacks[1].seq, f"{sr.synacks}")
    check("W: the wrong ACK got a RST with its number, and nothing came after the peer's RST",
          len(rsts) == 1 and rsts[0].flags == RST and rsts[0].seq == sr.synacks[0].seq + 1000
          and w.log[-1] is rsts[0], f"{w.log}")
    check("W: the second peer opened, and got the FIN", sr.second is not None
          and sr.second.got_fin)


def opened(r: Results, name: str) -> None:
    """The state after the handshake: TCP_OPEN, or TCP_PEER_CLOSED when
    the peer's FIN came before the program looked."""
    state = r.take()
    check(f"{name}: opens", state in (2, 3), f"state {state}")


LISTEN: Listening


def listen_setup(peer: Peer) -> None:
    global LISTEN
    LISTEN = Listening(peer)


# The timers' part: one case a run, with --step-time, so that a
# microsecond is a step and a run counts the same each time
PEER_ISS = 5_000_000
PROBES_ANSWERED = 12                    # case 4: the probes that get an ACK


def answers(case: int, frames: List[bytes]) -> List[str]:
    """The lines of --eth-in that answer the frames of a run of a case,
    each after the frame it answers."""
    lines: List[str] = []
    probes = 0
    if case == 6:                       # a SYN to the port that listens, as it is enabled
        lines.append("0:" + ip_frame(b"\xff" * 6, BOARD_IP, 6, tcp_payload(
            BOARD_IP, 5555, 2106, PEER_ISS, 0, SYN, 8192, options=mss_option(1460))).hex())
    for i, f in enumerate(frames, 1):
        def reply(frame: bytes) -> None:
            lines.append(f"{i}:{frame.hex()}")
        if is_arp_for_peer(f):
            reply(arp_reply(f))
            continue
        if f[12:14] != b"\x08\x00" or f[23] != 6:
            continue
        s = Segment(f, 0.0)

        def seg(flags: int, ack: int, win: int = 8192, data: bytes = b"", opts: bytes = b"",
                seq: int = PEER_ISS + 1) -> None:
            reply(ip_frame(s.src_mac, s.src_ip, 6, tcp_payload(s.src_ip, s.dport, s.sport, seq,
                                                               ack, flags, win, data, opts)))
        if s.flags & SYN:
            if case not in (1, 6):
                seg(SYN | ACK, s.seq + 1, 0 if case == 4 else 8192, opts=mss_option(1460),
                    seq=PEER_ISS)
        elif case == 3 and s.flags & FIN:
            seg(ACK, s.seq + 1)
        elif case == 4 and s.data:
            probes += 1
            if probes <= PROBES_ANSWERED:
                seg(ACK, s.seq, 0)
        elif case == 5 and s.data:
            seg(ACK | PSH, s.seq + len(s.data), data=s.data)
    return lines


def timer_case(tmp: str, case: int) -> Tuple[List[int], List[bytes]]:
    """A case of the timers, run until its answers are complete: its
    results, and the frames it sent."""
    image = os.path.join(tmp, f"tcpt{case}.bin")
    with open(image, "w") as f:
        f.write(open(MONITOR).read() + open(TIMERS).read() + f"00009000 {case:08X}\n")
    inp = os.path.join(tmp, "input")
    with open(inp, "w") as f:
        f.write("r\rh\r")
    eth_in = os.path.join(tmp, f"in{case}")
    eth_out = os.path.join(tmp, f"out{case}")
    lines: List[str] = []
    prev_lines: List[str] = []
    prev: List[bytes] = []
    for _ in range(40):
        with open(eth_in, "w") as f:
            f.write("".join(line + "\n" for line in lines))
        res = subprocess.run([NICEEMU, "--step-time", "-n", "20000000000", "-i", inp, "-d",
                              f"{RESULTS:#x}:16", "--eth-in", eth_in, "--eth-out", eth_out,
                              image], capture_output=True, timeout=300)
        out = res.stdout.decode("latin-1")
        frames = [bytes.fromhex(line) for line in open(eth_out).read().splitlines() if line]
        # The frames before the first new answer are those of the last run.
        k = next((j for j, (a, b) in enumerate(zip(lines, prev_lines)) if a != b),
                 min(len(lines), len(prev_lines)))
        same = min([int(x[k].split(":")[0]) for x in (lines, prev_lines) if k < len(x)]
                   or [len(prev)])
        if frames[:same] != prev[:same]:
            d = next(j for j, (a, b) in enumerate(zip(frames, prev)) if a != b)
            check(f"timers {case}: a run sends what the last one sent", False,
                  f"frame {d + 1} of {same}: {frames[d].hex()} {prev[d].hex()}")
        prev, prev_lines = frames, lines
        new = answers(case, frames)
        if new == lines:
            break
        lines = new
    words = {}
    for m in re.finditer(r"^([0-9A-Fa-f]{8}):((?: [0-9A-Fa-f]{8})+)", out, re.M):
        for k, w in enumerate(m[2].split()):
            words[int(m[1], 16) + k] = int(w, 16)
    n = re.search(r"Returned ([0-9A-F]{8})", out)
    count = int(n[1], 16) if n else 0
    check(f"timers {case}: the program returns", n is not None, out[-400:])
    return [signed(words.get(RESULTS + k, 0)) for k in range(count)], frames


def timers(tmp: str) -> None:
    S = 1_000_000
    TO = -55                            # E_TTIMEOUT
    for case in range(1, 7):
        r, frames = timer_case(tmp, case)
        segs = [Segment(f, 0.0) for f in frames if f[12:14] == b"\x08\x00" and f[23] == 6]
        data = [x for x in segs if x.data]
        check(f"timers {case}: every TCP checksum is right", all(x.tcp_ok for x in segs))
        t = r[-3] if case != 3 else r[-2]
        if case == 1:
            check("timers 1: no SYN-ACK: E_TTIMEOUT after 15 seconds",
                  r[:2] == [0, TO] and 15 * S <= t < 15 * S + 50_000, f"{r}")
            check("timers 1: the SYN, and again after 1, 2, 4, and 8 seconds",
                  len(segs) == 4 and all(x.flags == SYN and x.seq == segs[0].seq for x in segs),
                  f"{segs}")
        elif case == 2:
            check("timers 2: no ACK of 100 bytes: E_TTIMEOUT 120 seconds after the "
                  "first timeout", r[:4] == [0, 2, 100, TO] and
                  120_200_000 <= t < 120_300_000, f"{r}")
            check("timers 2: the 100 bytes, and 9 times again at 0.2 seconds doubled",
                  len(data) == 10 and all(x.seq == data[0].seq for x in data), f"{data}")
        elif case == 3:
            check("timers 3: no FIN from the peer: freed 60 seconds after the ACK of ours",
                  r[:4] == [0, 2, 0, 0] and 60 * S <= t < 60 * S + 50_000, f"{r}")
            check("timers 3: the FIN once, then a RST",
                  sum(1 for x in segs if x.flags & FIN) == 1 and segs[-1].flags & RST != 0,
                  f"{segs}")
        elif case == 4:
            check("timers 4: probes of a zero window answered 12 times, then not: "
                  "E_TTIMEOUT 120 seconds after the first unanswered",
                  r[:4] == [0, 2, 100, TO] and 462_200_000 <= t < 462_600_000, f"{r}")
            check("timers 4: 14 probes of a byte, at SND.UNA, out to 60 seconds apart",
                  len(data) == PROBES_ANSWERED + 2 and
                  all(len(x.data) == 1 and x.seq == data[0].seq for x in data), f"{data}")
        elif case == 6:
            check("timers 6: a SYN-ACK with no ACK: TCP_LISTEN again after 15 seconds",
                  r[:3] == [0, 1, 5] and 14_950_000 <= t < 15_050_000, f"{r}")
            check("timers 6: the SYN-ACK, and again after 1, 2, 4, and 8 seconds, and "
                  "nothing at the close", len(segs) == 4 and
                  all(x.flags == SYN | ACK and x.seq == segs[0].seq and x.ack == PEER_ISS + 1
                      and x.mss() == 1024 for x in segs), f"{segs}")
        else:
            check("timers 5: open after 4300 seconds idle, past a wrap of the microseconds; "
                  "10 bytes echoed", r == [0, 2, 2, 10, 10, 2, 0, 0], f"{r}")
            check("timers 5: nothing sent while idle",
                  [x.flags for x in segs] == [SYN, ACK, ACK | PSH, ACK, ACK | RST],
                  f"{segs}")
        check(f"timers {case}: the port is off at the end", r[-1] == 0)


def main() -> None:
    for path, how in ((NICEEMU, "make -C nice_cpu/emulator build"),
                      (MONITOR, "make -C monitor build/monitor_test.bin"),
                      (PROGRAM, "make -C monitor build/tcp.bin"),
                      (TIMERS, "make -C monitor build/tcpt.bin"),
                      (PROGRAM_C, "make -C monitor build/tcp_c.bin"),
                      (PROGRAM_HW, "make -C monitor build/tcphw.bin")):
        if not os.path.exists(path):
            sys.exit(f"tcptest.py: no {path}; {how} builds it")
    with tempfile.TemporaryDirectory() as tmp:
        if "--timers" not in sys.argv[1:]:
            checks(Results(run(tmp, PROGRAM, SCRIPTS, setup=listen_setup)[0]))
            ask = pattern(200, 5, 9)
            _, value = run(tmp, PROGRAM_C, {2001: Echo}, setup=connect_at_start(3010, Ask(ask)))
            check("tcp_c.c: 1000 bytes echoed through the stubs of mon_c.nasm, from odd "
                  "addresses, then 200 on port 3010, where it listens", value == 0,
                  f"returned {value}")
            c = conn(2001)
            check("tcp_c.c: the peer received them", c.received == bytes(
                (i * 7 + 3) & 0xFF for i in range(1000)) and c.got_fin)
            c = next(x for x in PEER.conns if x.bport == 3010)
            check("tcp_c.c: the peer's 200 bytes came back on port 3010",
                  c.received == ask and c.got_fin, f"{len(c.received)} bytes, FIN {c.got_fin}")
            n = 20000
            _, value = run(tmp, PROGRAM_HW, {2001: Echo}, "i 10.0.0.9\rr\rh\r",
                           f"00009000 0A000002\n00009001 000007D1\n00009002 {n:08X}\n")
            check("tcphw.nasm, hwtest's program: 20000 bytes echoed after i 10.0.0.9",
                  value == 0, f"returned {value}")
            c = conn(2001)
            check("tcphw.nasm: the peer received them", c.received == bytes(
                (7 * i + (i >> 8)) & 0xFF for i in range(n)) and c.got_fin)
            _, value = run(tmp, PROGRAM_HW, {}, "i 10.0.0.9\rr\rh\r",
                           f"00009000 00000000\n00009001 00000BCC\n00009002 {n:08X}\n",
                           setup=connect_at_start(3020, Echo()))
            check("tcphw.nasm: 20000 bytes echoed by a peer that connects to port 3020, where "
                  "it listens", value == 0, f"returned {value}")
            c = PEER.conns[-1]
            check("tcphw.nasm: the peer received them, and the FIN", c.received == bytes(
                (7 * i + (i >> 8)) & 0xFF for i in range(n)) and c.got_fin)
        if "--clients" not in sys.argv[1:]:
            timers(tmp)
    print(f"{passed} of {passed + failed} checks passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
