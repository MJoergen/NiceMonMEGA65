"""The host side of the debug link of PROTOCOL.md.

Link opens the MEGA65's debug UART and speaks the protocol: read() and
write() reach the board's address space, and the methods after them control
the core through the debug registers. The program's console output arrives
between the answers; Link keeps it, in order, for console(), and the stop
notices for wait_stop(). tools/nicemon.py, load.py, run.py, and hwtest.py
use it. Only the Python standard library is used.
"""

import os
import select
import sys
import termios
import time
from typing import NoReturn, Optional

ESC = 0xFF
BAUD = 2_000_000
PORT = "/dev/ttyUSB1"

CONSOLE = 0xFFFFFF00
INSTR_LO = 0xFFFFFF12
INSTR_HI = 0xFFFFFF13
SCREEN = 0xFFFF0000
REGS = 0xFFFFFFE0
CONTROL = 0xFFFFFFF0
HALT_WHY = 0xFFFFFFF1
RUN = 0xFFFFFFF2
STEP = 0xFFFFFFF3
TRACE = 0xFFFFFFF4
TRACE_DATA = 0xFFFFFFF5
INFO = 0xFFFFFFF6
BP_ADDR = 0xFFFFFFF8
BP_KIND = 0xFFFFFFFC

# Control bits: hold the core in reset, clear the memory first, hide the
# ROM so that the RAM is at 0, and, read only, halted and paused
HOLD = 1
HALTED = 2
CLEAR = 4
RAM = 8
PAUSED = 16

# The kinds of a breakpoint
EXEC = 1
READ = 2
WRITE = 4

# The most words in one request
CHUNK = 4096

# The halt reasons of 0xFFFFFFF1, as the emulator describes them
HALT_REASONS = {
    1: "HALT",
    2: "reserved control instruction",
    3: "INT inside an interrupt routine",
    4: "RTI outside an interrupt routine",
}


def fail(message: str) -> NoReturn:
    """Exits with the message, after the name of the running script."""
    sys.exit(f"{os.path.basename(sys.argv[0])}: {message}")


def stop_text(reason: int) -> str:
    """What a stop reason of PROTOCOL.md means."""
    if reason == 0x01:
        return "paused"
    if reason == 0x02:
        return "stepped"
    kind, k = reason >> 4, reason & 0xF
    if kind == 1:
        return f"breakpoint {k}"
    if kind == 2:
        return f"watchpoint {k}, read"
    if kind == 3:
        return f"watchpoint {k}, written"
    if reason & 0x80:
        return "halted (" + HALT_REASONS.get(reason & 0x7F, "?") + ")"
    return f"stopped (0x{reason:02x})"


def open_port(name: str, baud: int) -> int:
    """Opens the serial device raw, 8-N-1, without flow control."""
    fd = os.open(name, os.O_RDWR | os.O_NOCTTY)
    attr = termios.tcgetattr(fd)
    attr[0] = 0                                                # iflag
    attr[1] = 0                                                # oflag
    attr[2] = termios.CS8 | termios.CREAD | termios.CLOCAL     # cflag
    attr[3] = 0                                                # lflag
    attr[6][termios.VMIN] = 0
    attr[6][termios.VTIME] = 0
    speed = getattr(termios, f"B{baud}", None)
    if speed is not None:
        attr[4] = attr[5] = speed
        termios.tcsetattr(fd, termios.TCSANOW, attr)
    else:
        # macOS has no B2000000: set the speed with IOSSIOSPEED instead.
        import fcntl
        import struct
        termios.tcsetattr(fd, termios.TCSANOW, attr)
        fcntl.ioctl(fd, 0x80045402, struct.pack("I", baud))
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


class LinkError(Exception):
    pass


class Link:
    """The debug link on an open serial device."""

    def __init__(self, fd: int, baud: int = BAUD, wait: float = 1.0):
        self.fd = fd
        self.baud = baud
        # How long a request may take, beyond the time for its bytes. The
        # simulation (sim/cosim) is far slower than the board.
        self.wait = wait
        self.rx = bytearray()      # received, not parsed yet
        self.out = bytearray()     # console output, not taken yet
        self.stops: list[int] = []
        self.resets = 0
        self.answers: list[bytes] = []
        # The lengths of the answers that are still to come, in order
        self.expected: list[tuple[int, int]] = []

    @classmethod
    def open(cls, port: str = PORT, baud: int = BAUD, wait: float = 1.0) -> "Link":
        return cls(open_port(port, baud), baud, wait)

    def close(self) -> None:
        os.close(self.fd)

    # -- Bytes ---------------------------------------------------------------

    def _parse(self) -> None:
        """Takes the console bytes and the packets that have arrived
        whole."""
        rx = self.rx
        i = 0
        while i < len(rx):
            b = rx[i]
            if b != ESC:
                j = rx.find(ESC, i)
                j = len(rx) if j < 0 else j
                self.out += rx[i:j]
                i = j
                continue
            if i + 1 >= len(rx):
                break
            tag = rx[i + 1]
            if tag == ESC:
                self.out.append(ESC)
                i += 2
            elif tag in b"bh":
                if i + 2 >= len(rx):
                    break
                if tag == ord("b"):
                    self.resets += 1
                    self.expected.clear()
                else:
                    self.stops.append(rx[i + 2])
                i += 3
            elif tag in b"rk":
                if not self.expected or self.expected[0][0] != tag:
                    raise LinkError(f"an answer '{chr(tag)}' that was not asked for")
                n = self.expected[0][1]
                if i + 2 + n > len(rx):
                    break
                self.answers.append(bytes(rx[i + 2:i + 2 + n]))
                self.expected.pop(0)
                i += 2 + n
            else:
                raise LinkError(f"an unknown packet 0x{tag:02x}")
        del rx[:i]

    def pump(self, timeout: float) -> bool:
        """Reads what arrives within timeout seconds. Returns whether
        anything did."""
        ready, _, _ = select.select([self.fd], [], [], max(timeout, 0))
        if not ready:
            return False
        data = os.read(self.fd, 65536)
        if not data:
            return False
        self.rx += data
        self._parse()
        return True

    def send_console(self, data: bytes) -> None:
        """Sends console bytes to the program, with 0xFF escaped."""
        os.write(self.fd, data.replace(b"\xff", b"\xff\xff"))

    def console(self) -> bytes:
        """The console output that has arrived, which is then taken."""
        data = bytes(self.out)
        self.out.clear()
        return data

    def _request(self, packet: bytes, tag: str, n: int, timeout: float) -> bytes:
        self.expected.append((ord(tag), n))
        os.write(self.fd, packet)
        end = time.monotonic() + timeout
        while not self.answers:
            if time.monotonic() > end:
                self.expected.clear()
                raise LinkError("no answer from the board")
            self.pump(end - time.monotonic())
        return self.answers.pop(0)

    @staticmethod
    def _header(op: str, addr: int, n: int) -> bytes:
        return (bytes([ESC, ord(op)]) + (addr & 0xFFFFFFFF).to_bytes(4, "little") +
                n.to_bytes(2, "little"))

    def _timeout(self, n: int) -> float:
        # 4 bytes a word at 10 bits a byte, with plenty to spare
        return self.wait * (1.0 + 4 * n * 40 / self.baud)

    # -- The address space ---------------------------------------------------

    def read(self, addr: int, n: int = 1, same: bool = False) -> list[int]:
        """Reads n words from addr upwards, or n times the word at addr."""
        words: list[int] = []
        while n > 0:
            k = min(n, CHUNK)
            data = self._request(self._header("P" if same else "R", addr, k),
                                 "r", 4 * k, self._timeout(k))
            words += [int.from_bytes(data[i:i + 4], "little")
                      for i in range(0, len(data), 4)]
            if not same:
                addr += k
            n -= k
        return words

    def read1(self, addr: int) -> int:
        return self.read(addr)[0]

    def write(self, addr: int, words: list[int]) -> None:
        """Writes the words from addr upwards."""
        for i in range(0, len(words), CHUNK):
            part = words[i:i + CHUNK]
            data = b"".join((w & 0xFFFFFFFF).to_bytes(4, "little") for w in part)
            self._request(self._header("W", addr + i, len(part)) + data,
                          "k", 0, self._timeout(len(part)))

    def write1(self, addr: int, word: int) -> None:
        self.write(addr, [word])

    def write_image(self, image: dict[int, int]) -> None:
        """Writes the words of an image, a run of consecutive words at a
        time."""
        addrs = sorted(image)
        i = 0
        while i < len(addrs):
            j = i
            while j + 1 < len(addrs) and addrs[j + 1] == addrs[j] + 1:
                j += 1
            self.write(addrs[i], [image[a] for a in addrs[i:j + 1]])
            i = j + 1

    # -- The core ------------------------------------------------------------

    def sync(self) -> None:
        """Drops the answers that a host that died may have left, and
        checks that the board answers."""
        time.sleep(0.02)   # longer than a request may wait (PROTOCOL.md)
        while self.pump(0.05):
            pass
        self.rx.clear()
        self.out.clear()
        self.stops.clear()
        self.answers.clear()
        self.expected.clear()
        info = self.read1(INFO)
        if info & 0xFF != 1:
            raise LinkError(f"the board speaks protocol {info & 0xFF}, not 1")

    def control(self) -> int:
        return self.read1(CONTROL)

    def hold(self, clear: bool = False) -> None:
        """Holds the core in reset, with the ROM hidden, and clears the
        memory if asked."""
        self.write1(CONTROL, HOLD | RAM | (CLEAR if clear else 0))
        self.stops.clear()

    def start(self, paused: bool = False) -> None:
        """Starts the held core, with the ROM hidden, or makes it pause
        before its first instruction."""
        self.write1(RUN, 1 if paused else 2)
        self.stops.clear()
        self.write1(CONTROL, RAM)

    def load(self, image: dict[int, int]) -> None:
        """Holds the core, clears the memory, and writes the image."""
        self.hold(clear=True)
        self.write_image(image)

    def pause(self) -> None:
        self.write1(RUN, 1)

    def go(self) -> None:
        self.stops.clear()
        self.write1(RUN, 2)

    def step(self, n: int = 1) -> None:
        self.stops.clear()
        self.write1(STEP, n)

    def regs(self) -> list[int]:
        return self.read(REGS, 16)

    def stopped(self) -> bool:
        return bool(self.control() & (HALTED | PAUSED))

    def wait_stop(self, timeout: Optional[float] = None) -> Optional[int]:
        """Waits for a stop notice, and returns its reason, or None after
        timeout seconds."""
        end = None if timeout is None else time.monotonic() + timeout
        while not self.stops:
            left = 1.0 if end is None else end - time.monotonic()
            if left <= 0:
                return None
            self.pump(left)
        return self.stops.pop(0)

    def set_breakpoint(self, k: int, addr: int, kind: int) -> None:
        self.write1(BP_ADDR + k, addr)
        self.write1(BP_KIND + k, kind)

    def breakpoints(self) -> list[tuple[int, int]]:
        addrs = self.read(BP_ADDR, 4)
        kinds = self.read(BP_KIND, 4)
        return list(zip(addrs, kinds))

    def trace(self, last: Optional[int] = None) -> list[tuple[int, int, int]]:
        """The steps of the trace, oldest first, or the last ones: each the
        address, the instruction word, and the flags (PROTOCOL.md)."""
        count = self.read1(TRACE)
        first = 0 if last is None else max(0, count - last)
        self.write1(TRACE, first)
        words = self.read(TRACE_DATA, 3 * (count - first), same=True)
        return [(words[i], words[i + 1], words[i + 2])
                for i in range(0, len(words), 3)]


def read_bin(path: str) -> dict[int, int]:
    """The words of a .bin file (ISA.md §10.4), by address."""
    words: dict[int, int] = {}
    with open(path) as f:
        for line in f:
            if line.strip():
                a, d = line.split()
                words[int(a, 16)] = int(d, 16)
    return words
