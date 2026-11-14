#!/usr/bin/env python3
"""A TCP peer of its own on Ethernet frames, for the tests of the
monitor's TCP (issue #111), in niceemu with --eth-udp and --eth-peer.

It is the host 10.0.0.2 on the board's network: it answers ARP for that
address, and takes the TCP segments to it. Each port it listens on has a
Script, which decides what the peer sends: a SYN-ACK with an MSS option
or none, data, a FIN, a RST, a zero window, segments out of order, and
the other cases that a real stack cannot be made to do. A connection
keeps a log of every segment that came from the board, with the time it
came, so that the checks can read what the board did.

The peer is a small stack, not a full one: it takes data in order only,
acknowledges every segment with data at once, sends again from SND.UNA
after RTO seconds with no ACK, and keeps no TIME-WAIT. tools/tcptest.py
runs it. Only the Python standard library is used.
"""

import selectors
import socket
import struct
import threading
import time
from typing import Callable, Dict, List, Optional, Tuple

PEER_IP = bytes([10, 0, 0, 2])
PEER_MAC = bytes.fromhex("0A0000000002")
RTO = 0.3                               # the peer's own timeout, in seconds

FIN, SYN, RST, PSH, ACK = 1, 2, 4, 8, 16


def csum(data: bytes) -> int:
    """The ones' complement of the ones' complement sum of 16-bit words."""
    if len(data) % 2:
        data += b"\0"
    total: int = sum(struct.unpack(f">{len(data) // 2}H", data))
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return ~total & 0xFFFF


def ip_frame(mac: bytes, ip: bytes, proto: int, payload: bytes, ident: int = 0) -> bytes:
    """An IPv4 frame from the peer to the host at mac and ip."""
    hdr = struct.pack(">BBHHHBBH4s4s", 0x45, 0, 20 + len(payload), ident, 0, 64, proto, 0,
                      PEER_IP, ip)
    hdr = hdr[:10] + struct.pack(">H", csum(hdr)) + hdr[12:]
    return mac + PEER_MAC + b"\x08\x00" + hdr + payload


def tcp_payload(ip: bytes, sport: int, dport: int, seq: int, ack: int, flags: int, win: int,
                data: bytes = b"", options: bytes = b"", bad: bool = False) -> bytes:
    """A TCP segment from the peer to ip, its checksum spoiled with bad."""
    hlen = 20 + len(options)
    tcp = struct.pack(">HHIIBBHHH", sport, dport, seq & 0xFFFFFFFF,
                      ack & 0xFFFFFFFF if flags & ACK else 0, (hlen // 4) << 4, flags, win,
                      0, 0) + options + data
    c = csum(PEER_IP + ip + struct.pack(">BBH", 0, 6, len(tcp)) + tcp)
    if bad:
        c ^= 0x5555
    return tcp[:16] + struct.pack(">H", c) + tcp[18:]


def arp_reply(request: bytes) -> bytes:
    """The peer's answer to an ARP request for PEER_IP."""
    return (request[6:12] + PEER_MAC + b"\x08\x06" + bytes.fromhex("0001080006040002")
            + PEER_MAC + PEER_IP + request[22:28] + request[28:32])


def is_arp_for_peer(f: bytes) -> bool:
    return f[12:14] == b"\x08\x06" and f[20:22] == b"\x00\x01" and f[38:42] == PEER_IP


def mss_option(mss: int) -> bytes:
    return struct.pack(">BBH", 2, 4, mss)


def flag_names(flags: int) -> str:
    return "".join(n for b, n in ((SYN, "S"), (ACK, "A"), (FIN, "F"), (RST, "R"), (PSH, "P"))
                   if flags & b) or "-"


class Segment:
    """A TCP segment from the board, parsed from its frame."""

    def __init__(self, frame: bytes, when: float) -> None:
        self.frame = frame
        self.when = when
        ip = frame[14:]
        self.ihl = (ip[0] & 15) * 4
        self.ip_len = struct.unpack(">H", ip[2:4])[0]
        self.ident = struct.unpack(">H", ip[4:6])[0]
        self.frag = struct.unpack(">H", ip[6:8])[0]
        self.ttl = ip[8]
        self.ip_ok = csum(ip[:self.ihl]) == 0
        self.src_ip = ip[12:16]
        self.dst_ip = ip[16:20]
        self.src_mac = frame[6:12]
        tcp = ip[self.ihl:self.ip_len]
        self.sport, self.dport, self.seq, self.ack, off, self.flags, self.win, _, _ = \
            struct.unpack(">HHIIBBHHH", tcp[:20])
        self.hlen = (off >> 4) * 4
        self.options = tcp[20:self.hlen]
        self.data = tcp[self.hlen:]
        pseudo = self.src_ip + self.dst_ip + struct.pack(">BBH", 0, 6, len(tcp))
        self.tcp_ok = csum(pseudo + tcp) == 0

    def mss(self) -> Optional[int]:
        """The MSS option, if the segment has one."""
        o = self.options
        i = 0
        while i < len(o):
            if o[i] == 0:
                break
            if o[i] == 1:
                i += 1
                continue
            if i + 1 >= len(o) or o[i + 1] < 2:
                break
            if o[i] == 2 and o[i + 1] == 4:
                return int(struct.unpack(">H", o[i + 2:i + 4])[0])
            i += o[i + 1]
        return None

    def __repr__(self) -> str:
        return (f"<{self.sport}>{self.dport} {flag_names(self.flags)} seq {self.seq} "
                f"ack {self.ack} win {self.win} len {len(self.data)}>")


class Script:
    """What the peer does on a connection; the default is a plain server
    that takes data, and answers the board's FIN with its own. A Script
    overrides the hooks it needs."""

    mss: Optional[int] = 1460           # the SYN-ACK's option, or None for none
    window = 8192                       # the window that the peer announces

    def on_syn(self, c: "Conn", s: Segment) -> bool:
        """The board's first SYN: True to answer it with the SYN-ACK."""
        return True

    def on_open(self, c: "Conn") -> None:
        """The handshake is done."""

    def on_data(self, c: "Conn", data: bytes) -> None:
        """Bytes in order from the board, after they were acknowledged."""

    def on_fin(self, c: "Conn") -> None:
        """The board's FIN, after it was acknowledged: the peer's FIN."""
        c.close()

    def on_segment(self, c: "Conn", s: Segment) -> bool:
        """Every segment of the connection, before the peer takes it:
        False to pass it over."""
        return True

    def on_tick(self, c: "Conn", now: float) -> None:
        """Called about every 20 ms."""


class Conn:
    """A connection of the peer, from the board's SYN on."""

    def __init__(self, peer: "Peer", s: Segment, script: Script) -> None:
        self.peer = peer
        self.script = script
        self.bport = s.sport             # the board's port
        self.pport = s.dport             # the peer's
        self.board_mac = s.src_mac
        self.board_ip = s.src_ip
        self.log: List[Segment] = []
        self.irs = s.seq                 # the board's initial sequence number
        self.rcv_nxt = (s.seq + 1) & 0xFFFFFFFF
        self.iss = 1_000_000 + 100_000 * len(peer.conns)
        self.snd_una = self.iss
        self.snd_nxt = self.iss
        self.out = b""                   # the bytes to send, from SND.UNA
        self.fin_queued = False          # a FIN after self.out
        self.fin_sent = False
        self.board_win = s.win
        self.board_mss = s.mss() or 536
        self.window = script.window
        self.received = b""              # the bytes from the board, in order
        self.got_fin = False
        self.reset = False               # a RST came from the board
        self.state = "SYN-RCVD"
        self.last_send = 0.0
        self.opened = 0.0

    # Sending
    def segment(self, flags: int, seq: int, data: bytes = b"", ack: Optional[int] = None,
                win: Optional[int] = None, options: bytes = b"", bad: bool = False) -> None:
        """A segment to the board, as it is given."""
        tcp = tcp_payload(self.board_ip, self.pport, self.bport, seq,
                          self.rcv_nxt if ack is None else ack, flags,
                          self.window if win is None else win, data, options, bad)
        self.peer.send_ip(self.board_mac, self.board_ip, 6, tcp)

    def ack_now(self, win: Optional[int] = None) -> None:
        self.segment(ACK, self.snd_nxt, win=win)

    def send(self, data: bytes) -> None:
        """Bytes to the board, sent as far as its window lets them."""
        self.out += data
        self.push()

    def close(self) -> None:
        """The peer's FIN after its bytes."""
        self.fin_queued = True
        self.push()

    def rst(self) -> None:
        self.segment(RST | ACK, self.snd_nxt)
        self.state = "CLOSED"

    def push(self, again: bool = False) -> None:
        """What the board's window lets go, from SND.NXT, or with again
        from SND.UNA."""
        if self.state not in ("ESTABLISHED", "CLOSE-WAIT"):
            return
        if again:
            self.snd_nxt = self.snd_una
            self.fin_sent = False
        while True:
            off = (self.snd_nxt - self.snd_una) & 0xFFFFFFFF
            room = self.board_win - off
            if off < len(self.out):
                n = min(len(self.out) - off, max(room, 0), self.board_mss)
                if n <= 0:
                    break
                self.segment(ACK | PSH, self.snd_nxt, self.out[off:off + n])
                self.snd_nxt = (self.snd_nxt + n) & 0xFFFFFFFF
                self.last_send = time.monotonic()
                continue
            if self.fin_queued and not self.fin_sent and off == len(self.out):
                self.segment(ACK | FIN, self.snd_nxt)
                self.snd_nxt = (self.snd_nxt + 1) & 0xFFFFFFFF
                self.fin_sent = True
                self.last_send = time.monotonic()
            break

    # Receiving
    def take(self, s: Segment) -> None:
        self.log.append(s)
        if not self.script.on_segment(self, s):
            return
        if s.flags & RST:
            self.reset = True
            self.state = "CLOSED"
            return
        if self.state == "SYN-RCVD":
            if s.flags & SYN:            # the SYN again
                if self.script.on_syn(self, s):
                    self.syn_ack()
                return
            if s.flags & ACK and s.ack == (self.iss + 1) & 0xFFFFFFFF:
                self.state = "ESTABLISHED"
                self.snd_una = self.snd_nxt = s.ack
                self.board_win = s.win
                self.opened = time.monotonic()
                self.script.on_open(self)
            else:
                return
        if self.state == "CLOSED":
            return
        if s.flags & ACK:
            d = (s.ack - self.snd_una) & 0xFFFFFFFF
            if 0 < d <= (self.snd_nxt - self.snd_una) & 0xFFFFFFFF:
                n = min(d, len(self.out))
                self.out = self.out[n:]
                self.snd_una = s.ack
                self.last_send = time.monotonic()
            if d <= 0x7FFFFFFF:
                self.board_win = s.win
        if s.data or s.flags & FIN:
            if s.seq == self.rcv_nxt:
                if s.data:
                    self.received += s.data
                    self.rcv_nxt = (self.rcv_nxt + len(s.data)) & 0xFFFFFFFF
                if s.flags & FIN and not self.got_fin:
                    self.got_fin = True
                    self.rcv_nxt = (self.rcv_nxt + 1) & 0xFFFFFFFF
                self.ack_now()
                if s.data:
                    self.script.on_data(self, s.data)
                if s.flags & FIN and self.state == "ESTABLISHED":
                    self.state = "CLOSE-WAIT"
                    self.script.on_fin(self)
            else:
                self.ack_now()
        self.push()

    def syn_ack(self) -> None:
        opts = b"" if self.script.mss is None else mss_option(self.script.mss)
        self.segment(SYN | ACK, self.iss, options=opts)
        self.snd_nxt = (self.iss + 1) & 0xFFFFFFFF

    def tick(self, now: float) -> None:
        self.script.on_tick(self, now)
        if self.state in ("ESTABLISHED", "CLOSE-WAIT") and self.snd_nxt != self.snd_una \
                and now - self.last_send > RTO:
            self.last_send = now
            self.push(again=True)

    def acks(self) -> List[int]:
        """The ACK numbers of the board's segments, in order."""
        return [s.ack for s in self.log if s.flags & ACK]


class Peer:
    """The host PEER_IP on niceemu's frames, in a thread of its own."""

    def __init__(self) -> None:
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", 0))
        self.emu_port = 0               # niceemu's, set before run
        self.scripts: Dict[int, Callable[[], Script]] = {}
        self.conns: List[Conn] = []
        self.by_ports: Dict[Tuple[int, int], Conn] = {}
        self.frames: List[Tuple[float, bytes]] = []  # every frame from the board
        self.arps: List[bytes] = []     # the addresses that ARP asked for
        self.no_conn: List[Segment] = []  # segments that fit no connection
        self.ident = 0
        self.lock = threading.Lock()
        self.stop = False
        self.sent = 0

    @property
    def port(self) -> int:
        p: int = self.sock.getsockname()[1]
        return p

    def listen(self, port: int, script: Callable[[], Script]) -> None:
        self.scripts[port] = script

    def to_emu(self, frame: bytes) -> None:
        self.sock.sendto(frame, ("127.0.0.1", self.emu_port))
        self.sent += 1

    def send_ip(self, mac: bytes, ip: bytes, proto: int, payload: bytes) -> None:
        self.ident = (self.ident + 1) & 0xFFFF
        self.to_emu(ip_frame(mac, ip, proto, payload, self.ident))

    def run(self) -> None:
        sel = selectors.DefaultSelector()
        sel.register(self.sock, selectors.EVENT_READ)
        tick = time.monotonic()
        while not self.stop:
            for _ in sel.select(0.02):
                try:
                    frame = self.sock.recv(2048)
                except OSError:
                    continue
                with self.lock:
                    self.from_emu(frame)
            now = time.monotonic()
            if now - tick >= 0.02:
                tick = now
                with self.lock:
                    for c in self.conns:
                        c.tick(now)
        sel.close()

    def from_emu(self, f: bytes) -> None:
        now = time.monotonic()
        self.frames.append((now, f))
        kind = f[12:14]
        if kind == b"\x08\x06" and f[20:22] == b"\x00\x01":
            self.arps.append(f[38:42])
            if is_arp_for_peer(f):
                self.to_emu(arp_reply(f))
            return
        if kind != b"\x08\x00" or f[23] != 6 or f[30:34] != PEER_IP:
            return
        s = Segment(f, now)
        key = (s.sport, s.dport)
        c = self.by_ports.get(key)
        if c is not None and c.state == "CLOSED" and s.flags & SYN and not s.flags & ACK \
                and s.seq != c.irs:
            c = None                    # a new connection from the same port
        if c is None:
            if s.flags & SYN and not s.flags & ACK and s.dport in self.scripts:
                c = Conn(self, s, self.scripts[s.dport]())
                c.log.append(s)
                self.conns.append(c)
                self.by_ports[key] = c
                if c.script.on_syn(c, s):
                    c.syn_ack()
                return
            self.no_conn.append(s)
            if not s.flags & RST and s.dport not in self.scripts:
                self.refuse(s)
            return
        c.take(s)

    def refuse(self, s: Segment) -> None:
        """A RST to a segment that fits no connection."""
        if s.flags & ACK:
            flags, seq, ack = RST, s.ack, 0
        else:
            flags, seq = RST | ACK, 0
            ack = s.seq + len(s.data) + (1 if s.flags & SYN else 0) + (1 if s.flags & FIN else 0)
        self.send_ip(s.src_mac, s.src_ip, 6, tcp_payload(s.src_ip, s.dport, s.sport, seq, ack,
                                                         flags, 0))

    def conns_on(self, port: int) -> List[Conn]:
        return [c for c in self.conns if c.pport == port]
