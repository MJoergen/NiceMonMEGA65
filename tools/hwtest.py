#!/usr/bin/env python3
"""Test the system on the MEGA65 or Nexys4DDR board through its debug UART.

First it finds the JTAG cable on the same USB device as the serial port,
reads the FPGA's IDCODE through it, and stops unless the FPGA is the part
the bitstream was built for. It then programs the FPGA through that cable
alone, so with several boards attached it programs the board whose UART it
tests. openFPGALoader does both, for the MEGA65 and the Nexys4DDR alike.
It checks the link's b notice, and the ROM when the bitstream has one, then
drives the debug link (nice_cpu/doc/DEBUG.md) with the ROM hidden: it
checks that bad packets are dropped and that nicelink sends a dropped
request again, loads and runs sim/echo.nasm, checks that the link reaches only its debug
registers while it runs, holds and restarts the core, clears
the memory, reads back what sim/emu.nasm leaves after its halt, checks that
the cycle counter and the timer stop there, writes and reads the screen's
registers, writes and reads the board's devices (on the Nexys4DDR the LEDs,
RGB LEDs, and seven-segment display, and the buttons and switches, which
only a read can check; on the MEGA65 the block reads 0), and runs the C example
examples/build/primes.bin, after whose halt the microsecond counter must hold
the cycle counter's count over the clock in MHz. Last, it runs programs with tools/run.py and
with niceemu, and compares their output and exit status, with sim/eof.nasm
also the end of the input and an input file of 1536 bytes, with a program
that halts at once although 100 lines of input wait for it, with the
emulator's trapsym.nasm and its label file for --symbols, and with
nice_cpu's benchmark, examples/build/bench.bin, all but its cycles. The programs
run with the ROM hidden, so the RAM is at 0.
Build the bitstream and the examples first, and niceemu
(make -C nice_cpu/emulator build), or the checks that need it are skipped,
and the summary names them after a SKIPPED. The cleanup at the end holds the
core, and says so if the link did not answer.

Usage: tools/hwtest.py [--port /dev/ttyUSB1] [--baud 2000000]
                       [--bit synth/r6/build/top.bit]
                       [--board mega65|nexys4ddr] [--no-program]

--board says which board it is, for the check of the board's devices. By
default the name of the --bit file tells: a path with nexys4ddr in it is the
Nexys4DDR, any other is a MEGA65.

--no-program skips programming and the check of the b notice, for a board
that is already programmed. Only the Python
standard library is used, and openFPGALoader when the FPGA is programmed.
Programming needs Linux, as the JTAG cable is found through /sys; with
--no-program the script runs wherever load.py does.

A check that leaves the board in a state in which every later check would
fail stops the run. Whatever happens, the script ends by holding the core
with the ROM hidden, and it prints the summary.
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile
import time
from typing import Callable, TypeVar

from load import load_words, read_bin, start
from nicelink import (CONTROL, FREE, HOLD, RAM, VERSION, Link, LinkError,
                      Serial, packet)

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NICEEMU = f"{REPO}/nice_cpu/emulator/zig-out/bin/niceemu"
# The clock of each board, which sets the rate of the microsecond counter
CLOCK_HZ = {"mega65": 100_000_000, "nexys4ddr": 90_000_000}

T = TypeVar("T")

# How long console() and answers() wait for the next byte, and run.py's
# --timeout in test_run. tools/cosimtest.py makes them longer for the
# simulation, which runs far slower than real time.
QUIET = 0.5
RUN_TIMEOUT = 10.0

results: list[bool] = []
# The checks that could not run, which the summary names
skipped: list[str] = []


def check(name: str, ok: bool, detail: str = "") -> bool:
    results.append(ok)
    print(f"[{'PASS' if ok else 'FAIL'}] {name} {detail}", flush=True)
    return ok


def require(name: str, ok: bool, detail: str = "") -> None:
    """Like check, but stops the run when it fails: the board is then in a
    state in which every later check would fail too."""
    if not check(name, ok, detail):
        sys.exit(f"hwtest.py: stopped, as '{name}' failed")


def cleanup(port: str, baud: int) -> None:
    """Holds the core with the ROM hidden, which the link does whether a
    program runs or not. Nothing here may fail the script."""
    try:
        link = Link(Serial(port, baud))
        try:
            link.control(HOLD | RAM)
            held = True
        finally:
            link.close()
    except (OSError, LinkError, SystemExit):
        held = False
    if not held:
        print("  could not hold the core; press the reset button before a "
              "run with --no-program", flush=True)


def rd(link: Link, addr: int) -> int:
    return link.read_word(addr)


def wr(link: Link, addr: int, value: int) -> bool:
    """Writes a word; False when the link refuses it."""
    try:
        link.write(addr, [value])
    except LinkError as e:
        print(f"  {e}")
        return False
    return True


def ctl(link: Link) -> str:
    return f"{rd(link, CONTROL):08X}"


def console(link: Link, quiet: float | None = None) -> bytes:
    """The console bytes that arrive until none has for quiet seconds,
    QUIET by default."""
    if quiet is None:
        quiet = QUIET
    end = time.monotonic() + quiet
    while time.monotonic() < end:
        if link.poll(end - time.monotonic()):
            end = time.monotonic() + quiet
    return link.take_console()


def wait_halt(link: Link, timeout: float = 2.0) -> int | None:
    """The reason of the next halt notice, or None."""
    end = time.monotonic() + timeout
    while not link.halts and time.monotonic() < end:
        link.poll(end - time.monotonic())
    return link.halts.pop(0) if link.halts else None


def load(link: Link, path: str) -> int:
    """Clears the memory, writes the words of a .bin file, and starts the
    core."""
    words = read_bin(path)
    link.halts.clear()
    load_words(link, words)
    start(link)
    return len(words)


def assemble(src: str, out_dir: str) -> str:
    out = os.path.join(out_dir, os.path.basename(src).replace(".nasm", ".bin"))
    subprocess.run([sys.executable, f"{REPO}/nice_cpu/assembler/niceasm.py",
                    "-o", out, src], check=True)
    return out


# The openFPGALoader cables to try: ft2232 for the MEGA65's JTAG adapter,
# digilent for the Nexys4DDR. Each answers on its own board only.
CABLES = ["ft2232", "digilent"]


def bit_part(bit: str) -> str:
    """Returns the part a bitstream was built for, as its header names it
    (7a200tfbg484, say): fields of a letter, a 16-bit length, and the text,
    after a fixed preamble of 13 bytes."""
    with open(bit, "rb") as f:
        head = f.read(256)
    i = 13
    while i + 3 <= len(head):
        key = head[i]
        n = int.from_bytes(head[i + 1:i + 3], "big")
        if key == ord("b"):
            return head[i + 3:i + 3 + n].rstrip(b"\0").decode()
        if key not in b"acd":
            break
        i += 3 + n
    sys.exit(f"hwtest.py: {bit} has no part in its header")


def usb_serial(port: str) -> str:
    """Returns the serial number of the USB device that a serial port is an
    interface of: the board's FTDI chip, whose other interface is JTAG. It
    reads /sys, so this works on Linux only."""
    tty = os.path.basename(os.path.realpath(port))
    path = os.path.realpath(f"/sys/class/tty/{tty}/device")
    while path != "/":
        if os.path.exists(f"{path}/serial"):
            with open(f"{path}/serial") as f:
                return f.read().strip()
        path = os.path.dirname(path)
    sys.exit(f"hwtest.py: no USB serial number found for {port}")


def fpga_model(serial: str) -> tuple[str, str]:
    """Reads the IDCODE through the JTAG cable with that serial number and
    returns the cable that answered and the model openFPGALoader names for
    the FPGA (xc7a200, say)."""
    for cable in CABLES:
        r = subprocess.run(["openFPGALoader", "-c", cable, "--ftdi-serial",
                            serial, "--detect"], capture_output=True,
                           text=True, timeout=30)
        m = re.search(r"model\s+(\S+)", r.stdout + r.stderr)
        if m:
            return cable, m.group(1)
    sys.exit(f"hwtest.py: no FPGA answers on the JTAG cable {serial}")


def check_board(port: str, bit: str) -> list[str]:
    """Stops unless the FPGA on the board of the serial port is the part of
    the bitstream, and returns the openFPGALoader options that select its
    JTAG cable."""
    part = bit_part(bit)
    serial = usb_serial(port)
    cable, model = fpga_model(serial)
    ok = f"xc{part}".startswith(model)
    print(f"[{'PASS' if ok else 'FAIL'}] FPGA {model} on {port} (JTAG "
          f"{serial}), bitstream for {part}", flush=True)
    if not ok:
        sys.exit(f"hwtest.py: {bit} is for {part}, but the FPGA on {port} is "
                 f"{model}; give the --port of the board it is for")
    return ["-c", cable, "--ftdi-serial", serial]


def test_boot(link: Link, bit: str, cable: list[str]) -> None:
    r = subprocess.run(["openFPGALoader"] + cable + [bit],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"hwtest.py: openFPGALoader failed:\n{r.stdout}{r.stderr}")
    time.sleep(1.0)
    out = console(link, 1.0)
    check("b notice after configuration", link.boots >= 1,
          f"{link.boots} b notices, console {out!r}")
    c = ctl(link)
    # Without a ROM the core is held and the ROM bit reads 1; with one the
    # core has booted from it, and has halted or still runs.
    check("core held at power-up, or booted from the ROM",
          c in ("00000009", "00000002", "00000000"),
          f"{c}: {'held, no ROM' if c == '00000009' else 'ROM shown' if c in ('00000002', '00000000') else 'unexpected'}")
    if c in ("00000002", "00000000"):
        link.control(HOLD)
        # The ROM is shown: its first word is the program's, and a write to
        # it is dropped.
        first = rd(link, 0)
        check("ROM at address 0", first != 0, f"{first:08X}")
        check("write to the ROM dropped",
              wr(link, 0, 0x12345678) and rd(link, 0) == first)


def test_link(link: Link) -> None:
    link.control(HOLD | RAM)
    require("hide the ROM", ctl(link) in ("00000009", "0000000B"), ctl(link))
    check("version 1", rd(link, VERSION) == 1)
    check("W then R", wr(link, 0x100, 0xDEADBEEF) and
          rd(link, 0x100) == 0xDEADBEEF)
    words = list(range(0x1000, 0x1000 + 600))
    link.write(0x200, words)
    check("W and R of 600 words", link.read(0x200, 600) == words)


def answers(link: Link, quiet: float | None = None) -> list[tuple[str, str]]:
    """The answers that arrive until no byte has for quiet seconds."""
    console(link, quiet)
    return link.take_answers()


def bad_checksum(data: bytes) -> bytes:
    """The packet with another last digit of its checksum."""
    return data[:-1] + (b"0" if data[-1:] != b"0" else b"1")


def corrupt_first(link: Link, call: Callable[[], T]) -> tuple[T, int]:
    """Runs call with the checksum of the first packet that it sends made
    bad, so the system drops it and nicelink must send it again. Returns
    what call returns and the number of writes to the transport."""
    write = link.transport.write
    sent: list[bytes] = []

    def corrupt(data: bytes) -> None:
        sent.append(data)
        write(bad_checksum(data) if len(sent) == 1 else data)

    link.transport.write = corrupt  # type: ignore[method-assign]
    try:
        return call(), len(sent)
    finally:
        del link.transport.write


def test_framing(link: Link, gap: bool = True) -> None:
    """Bad packets (DEBUG.md §5), with the core held: one with a bad
    checksum, one cut short by an ESC, and one with a gap of more than
    100 ms between two bytes are dropped with no answer, and nicelink's
    retry of a request whose first copy was dropped gets its answer. A good
    packet with an unknown tag gets e01, and one with a bad payload e03.
    The same checks run on niceemu --link, in tools/linktest.py, and on the
    simulation, in tools/cosimtest.py, without the gap (gap false): a gap
    in real time is far shorter in simulated time."""
    require("W of the word for the framing checks",
            wr(link, 0x100, 0x0BADC0DE))
    an = f"{0x100:08X}0001"
    good = packet("R", an)
    answer = ("r", f"{an}0BADC0DE")
    link.take_answers()
    link.transport.write(bad_checksum(good))
    got = answers(link)
    check("R with a bad checksum gets no answer", got == [], repr(got))
    # The ESC of the whole request cuts the first copy short.
    link.transport.write(good[:8] + good)
    got = answers(link)
    check("R cut short by an ESC is dropped, and the next one answered",
          got == [answer], repr(got))
    if gap:
        link.transport.write(good[:8])
        time.sleep(0.3)
        link.transport.write(good[8:])
        got = answers(link)
        check("R with a gap of 300 ms gets no answer", got == [], repr(got))
    link.transport.write(packet("Q", an))
    got = answers(link)
    check("unknown tag gets e01", got == [("e", f"{ord('Q'):02X}01")],
          repr(got))
    link.transport.write(packet("R", "0100"))
    got = answers(link)
    check("bad payload gets e03", got == [("e", f"{ord('R'):02X}03")],
          repr(got))
    word, writes = corrupt_first(link, lambda: rd(link, 0x100))
    check("R sent again after a bad checksum", word == 0x0BADC0DE and
          writes == 2, f"{word:08X} after {writes} copies")
    words = [0x13579BDF, 0x2468ACE0]
    _, writes = corrupt_first(link, lambda: link.write(0x100, words))
    got_words = link.read(0x100, 2)
    check("W sent again after a bad checksum", got_words == words and
          writes == 2, f"{' '.join(f'{w:08X}' for w in got_words)} after "
          f"{writes} copies")
    check("a good R after the bad packets",
          rd(link, 0x101) == 0x2468ACE0)


def test_echo(link: Link, echo: str) -> None:
    load(link, echo)
    link.send_console(b"Hello, MEGA65!")
    got = console(link)
    check("echo while running", got == b"Hello, MEGA65!", repr(got))
    # Bytes with bit 7 set, 0xFF as ESC ESC both ways. The core echoes far
    # faster than they arrive, so its input FIFO does not fill up.
    high = bytes(range(0x80, 0x100))
    link.send_console(high)
    got = console(link)
    bad = [f"{s:02X}->{g:02X}" for s, g in zip(high, got) if s != g]
    check("echo of bytes 0x80 to 0xFF", got == high,
          f"{len(got)} of {len(high)} bytes back, {len(bad)} wrong: "
          f"{' '.join(bad[:8])}" if got != high else "")
    # While the core runs, the link reaches its debug registers only.
    check("control register while running", ctl(link) == "00000008",
          ctl(link))
    check("free space while running", rd(link, FREE) == 2048,
          f"{rd(link, FREE)}")
    try:
        link.read(0x100)
        refused = False
    except LinkError as e:
        refused = "error 02" in str(e)
    check("e02 for memory while running", refused)
    link.send_console(b".")
    got = console(link)
    check("echo halts on '.'", got == b".", repr(got))
    require("halt notice", wait_halt(link) == 1)
    c = ctl(link)
    check("halted flag", c == "0000000A", c)
    check("link reaches the memory after the halt",
          wr(link, 0x100, 0x12345678) and rd(link, 0x100) == 0x12345678)


def test_reset(link: Link, echo: str) -> None:
    link.control(HOLD | RAM)
    c = ctl(link)
    check("held, halted flag kept until a start", c == "0000000B", c)
    load(link, echo)
    link.send_console(b"again.")
    got = console(link)
    check("core runs again after a restart", got == b"again.", repr(got))
    require("halt notice after the restart", wait_halt(link) == 1)
    # A hold stops a running program at once.
    load(link, echo)
    link.control(HOLD | RAM)
    c = ctl(link)
    check("hold of a running program", c == "00000009", c)


def test_clear(link: Link) -> None:
    check("W before the clear", wr(link, 0x100, 0xDEADBEEF))
    link.control(HOLD | 4 | RAM)
    c = ctl(link)
    check("held after the clear", c == "00000009", c)
    got = rd(link, 0x100)
    check("memory cleared", got == 0, f"{got:08X}")


def steps(path: str) -> int:
    """The steps niceemu counts for the program."""
    r = subprocess.run([NICEEMU, path], stdin=subprocess.DEVNULL,
                       capture_output=True, check=True)
    m = re.search(rb" after (\d+) steps", r.stdout)
    if not m:
        raise SystemExit(f"hwtest: no step count in niceemu's output for {path}")
    return int(m.group(1))


def test_readback(link: Link, emu: str) -> None:
    load(link, emu)
    require("halt notice", wait_halt(link) == 1)
    c = ctl(link)
    check("emu.nasm halted", c == "0000000A", c)
    expected = {
        0xFFFFFFF1: 0x00000001,  # halted by HALT
        0xFFFF0000: 0x00000041,  # the screen, column 0 of row 0
        0xFFFF07CF: 0x00000042,  # the screen, column 79 of row 24
        0xFFFFFF02: 0x00001234,  # memory in the I/O range
        0x00000110: 0x00001234,
        0x00000111: 0x00000002,  # the read counter, as the program read it
        0xFFFFFF01: 0x00000000,  # which the link reads as 0 (DEBUG.md §3)
        0xFFFFFFE5: 0x0000CAFE,  # R5
    }
    if os.path.exists(NICEEMU):
        expected[0xFFFFFF42] = steps(emu)  # as niceemu says
    else:
        skipped.append("readback FFFFFF42")
    for addr, want in expected.items():
        got = rd(link, addr)
        check(f"readback {addr:08X}", got == want,
              f"got {got:08X}, want {want:08X}")
    regs = link.read(0xFFFFFFE0, 16)
    print("  R0-R15:", " ".join(f"{r:08X}" for r in regs))


def test_counters_stop(link: Link) -> None:
    """After a halt the cycle counter and the timer's COUNT do not change."""
    first = rd(link, 0xFFFFFF40)
    time.sleep(0.5)
    check("cycle counter stops at a halt", rd(link, 0xFFFFFF40) == first,
          f"{first:08X}")
    check("W TIMER_PERIOD", wr(link, 0xFFFFFF10, 0x00FFFFFF))
    count = rd(link, 0xFFFFFF11)
    time.sleep(0.5)
    check("timer COUNT stops at a halt",
          count != 0 and rd(link, 0xFFFFFF11) == count, f"{count:08X}")


def test_screen_registers(link: Link) -> None:
    """Writes the screen's registers and reads them back. On the display the
    cursor shows at the bottom right, and the screen is scrolled one row."""
    for addr, value in [(0xFFFFFF80, 0x460), (0xFFFFFF81, 0x4F),
                        (0xFFFFFF82, 0x18), (0xFFFFFF85, 0x50)]:
        check(f"W {addr:08X}", wr(link, addr, value))
        got = rd(link, addr)
        check(f"readback {addr:08X}", got == value,
              f"got {got:08X}, want {value:08X}")
    got = rd(link, 0xFFFFFF83)
    check("FFFFFF83 is not a register", got == 0, f"{got:08X}")
    check("the display offset off again", wr(link, 0xFFFFFF85, 0))


def test_board_devices(link: Link, board: str) -> None:
    """On the Nexys4DDR, writes the LEDs, the RGB LEDs, and the display's
    segments at FFFFFF90-94 and reads them back. The LEDs, the RGB LEDs, and
    the display show the patterns until the check clears them. The buttons and switches at FFFFFF95-96 take no write and read
    nothing above their bits, whatever their state. On the MEGA65 the block
    reads 0 and takes no write."""
    if board == "mega65":
        for addr in (0xFFFFFF90, 0xFFFFFF93, 0xFFFFFF95, 0xFFFFFF96):
            check(f"W {addr:08X} is dropped",
                  wr(link, addr, 0xFFFFFFFF) and rd(link, addr) == 0)
        return
    for addr, value in [(0xFFFFFF90, 0x0000A5C3), (0xFFFFFF91, 0x00000121),
                        (0xFFFFFF92, 0x00000102), (0xFFFFFF93, 0x4F5B063F),
                        (0xFFFFFF94, 0x077D6D66)]:
        check(f"W {addr:08X}", wr(link, addr, value))
        got = rd(link, addr)
        check(f"readback {addr:08X}", got == value,
              f"got {got:08X}, want {value:08X}")
    check("W FFFFFF91 drops the bits above the levels",
          wr(link, 0xFFFFFF91, 0xFFFFF121) and rd(link, 0xFFFFFF91) == 0x121)
    buttons = rd(link, 0xFFFFFF95)
    switches = rd(link, 0xFFFFFF96)
    check("buttons read in bits 4..0", buttons < 0x20, f"{buttons:08X}")
    check("switches read in bits 15..0", switches < 0x10000, f"{switches:08X}")
    check("W FFFFFF95 and FFFFFF96 are dropped",
          wr(link, 0xFFFFFF95, 0xFFFFFFFF) and
          wr(link, 0xFFFFFF96, 0xFFFFFFFF) and
          rd(link, 0xFFFFFF95) == buttons and
          rd(link, 0xFFFFFF96) == switches)
    check("FFFFFF97 is not a register",
          wr(link, 0xFFFFFF97, 0xFFFFFFFF) and rd(link, 0xFFFFFF97) == 0)
    # Leave the devices dark
    for addr in range(0xFFFFFF90, 0xFFFFFF95):
        check(f"W {addr:08X} clears", wr(link, addr, 0) and rd(link, addr) == 0)


def test_fetch_statistics(link: Link) -> None:
    """Checks the control word of the fetch statistics at FFFFFF50 and that
    FFFFFF5D, a word they leave at 0, reads 0."""
    check("FS_CTRL runs", rd(link, 0xFFFFFF50) == 1)
    check("FS_CTRL stops", wr(link, 0xFFFFFF50, 0) and rd(link, 0xFFFFFF50) == 0)
    check("FS_CTRL clears and runs", wr(link, 0xFFFFFF50, 3) and
          rd(link, 0xFFFFFF50) == 1)
    check("FFFFFF5D reads 0", rd(link, 0xFFFFFF5D) == 0)


def counter(link: Link, lo: int) -> int:
    """A 64-bit performance counter: the read of its low word takes the
    snapshot that its high word returns."""
    low = rd(link, lo)
    high = rd(link, lo + 1)
    return high << 32 | low


def test_primes(link: Link, primes: str, board: str) -> None:
    t0 = time.monotonic()
    n = load(link, primes)
    print(f"  loaded {n} words in {time.monotonic() - t0:.1f} s")
    prompt = console(link, 1.0)
    check("primes prompt", b"Count the primes up to" in prompt, repr(prompt))
    for limit, count in [(1000, 168), (10000, 1229), (20000, 2262)]:
        link.send_console(f"{limit}\r".encode())
        out = console(link, 3.0).decode(errors="replace")
        check(f"primes up to {limit}",
              f"Primes up to {limit}: {count}" in out, repr(out))
    link.send_console(b"0\r")
    console(link, 1.0)
    require("primes halt notice", wait_halt(link) == 1)
    c = ctl(link)
    check("primes halts on 0", c == "0000000A", c)
    # The core ran for seconds, so the counters are far from 0. Both stopped
    # at the halt, so the microseconds are the cycles over the clock in MHz.
    cycles = counter(link, 0xFFFFFF40)
    micros = counter(link, 0xFFFFFF44)
    mhz = CLOCK_HZ[board] // 1_000_000
    check(f"microsecond counter is the cycles over {mhz}",
          micros == cycles // mhz, f"{micros} of {cycles} cycles")


def comparisons(tmp: str) -> list[tuple[str, list[str], bool]]:
    """The programs that test_run compares, assembled into tmp, with their
    options and input files."""
    emu = assemble(f"{REPO}/sim/emu.nasm", tmp)
    hello = assemble(f"{REPO}/nice_cpu/doc/intro/examples/hello.nasm", tmp)
    reserved = assemble(f"{REPO}/nice_cpu/emulator/test/reserved.nasm", tmp)
    eof = assemble(f"{REPO}/sim/eof.nasm", tmp)
    trapsym = assemble(f"{REPO}/nice_cpu/emulator/test/trapsym.nasm", tmp)
    # Every byte value, six times over: 1536 bytes, far more than the
    # 16-byte FIFO of the testbench holds
    text = os.path.join(tmp, "input.bin")
    with open(text, "wb") as f:
        f.write(bytes(range(256)) * 6)
    # 100 lines for hello.nasm, which halts without reading them
    lines = os.path.join(tmp, "lines.txt")
    with open(lines, "w") as f:
        f.writelines(f"line {i}\n" for i in range(100))
    return [
        (hello, [], False),
        (hello, ["-i", lines], False),  # halts with unread input
        # Not 0xFFFFFF00-01, which the link reads as 0 (DEBUG.md §3)
        (emu, ["-d", "0x110:2", "-d", "0xFFFFFF02:2", "-s"], False),
        (reserved, [], False),
        (eof, [], True),               # no input: it ends at once
        (eof, ["-i", text], True),
        (trapsym, ["--symbols",        # names the halt and the trap
                   f"{REPO}/nice_cpu/emulator/test/trapsym.sym"], False),
    ]


def test_run(link_args: list[str],
             programs: list[tuple[str, list[str], bool]]) -> None:
    """Runs each program with run.py and with niceemu, which must print the
    same and exit with the same status. link_args are run.py's options for
    the link. A program is (path, options, polls): when polls is true, the
    program waits for input in a loop, which takes more steps on the board,
    where a read returns 0 until a byte arrives, so the step counts are not
    compared. The port must be closed meanwhile."""
    if not os.path.exists(NICEEMU):
        print(f"  {NICEEMU} is missing; the comparison with the emulator "
              "is skipped")
        skipped.append("run.py as niceemu")
        return
    for path, options, polls in programs:
        name = " ".join([os.path.basename(path)] +
                        [os.path.basename(o) for o in options])
        emu = subprocess.run([NICEEMU] + options + [path],
                             stdin=subprocess.DEVNULL, capture_output=True)
        board = subprocess.run([sys.executable, f"{REPO}/tools/run.py"] +
                               link_args + ["--timeout", f"{RUN_TIMEOUT:g}"] +
                               options + [path],
                               stdin=subprocess.DEVNULL, capture_output=True)
        if polls:
            for r in (emu, board):
                r.stdout = re.sub(rb"after \d+ steps", b"after N steps",
                                  r.stdout)
        same = (emu.stdout == board.stdout and
                emu.returncode == board.returncode)
        check(f"run.py {name} as niceemu", same,
              "" if same else f"\n  niceemu (exit {emu.returncode}): "
              f"{emu.stdout!r}\n  run.py (exit {board.returncode}): "
              f"{board.stdout!r} {board.stderr!r}")


def test_bench(link_args: list[str], bench: str) -> None:
    """Runs nice_cpu's benchmark with run.py and with niceemu, which must
    print the same and exit with the same status, but for the cycles, which
    the board counts in clock cycles. So the steps differ too, since
    printing other numbers takes other steps. The board's table is printed.
    link_args are run.py's options for the link. The port must be closed
    meanwhile."""
    if not os.path.exists(NICEEMU):
        print(f"  {NICEEMU} is missing; the benchmark is skipped")
        skipped.append("bench.bin as niceemu")
        return
    emu = subprocess.run([NICEEMU, bench], stdin=subprocess.DEVNULL,
                         capture_output=True)
    board = subprocess.run([sys.executable, f"{REPO}/tools/run.py"] +
                           link_args + ["--timeout", "10", bench],
                           stdin=subprocess.DEVNULL, capture_output=True)
    for line in board.stdout.decode(errors="replace").splitlines():
        if line.startswith("Halted"):
            break
        print(f"  {line}")
    # A line of a phase, or the total: its name, instructions, and cycles
    phase = re.compile(rb"^(\S+ +\d+) +\d+", re.MULTILINE)
    for r in (emu, board):
        r.stdout = phase.sub(rb"\1 N", r.stdout)
        r.stdout = re.sub(rb"after \d+ steps", b"after N steps", r.stdout)
    same = emu.stdout == board.stdout and emu.returncode == board.returncode
    check("bench.bin as niceemu, but for the cycles", same,
          "" if same else f"\n  niceemu (exit {emu.returncode}): "
          f"{emu.stdout!r}\n  run.py (exit {board.returncode}): "
          f"{board.stdout!r} {board.stderr!r}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", default="/dev/ttyUSB1")
    parser.add_argument("--baud", type=int, default=2000000)
    parser.add_argument("--bit", default=f"{REPO}/synth/r6/build/top.bit")
    parser.add_argument("--board", choices=["mega65", "nexys4ddr"],
                        help="default: nexys4ddr if --bit has it in its path")
    parser.add_argument("--no-program", action="store_true",
                        help="do not program the FPGA, and skip the b notice")
    args = parser.parse_args()

    board = args.board or ("nexys4ddr" if "nexys4ddr" in args.bit
                           else "mega65")
    primes = f"{REPO}/examples/build/primes.bin"
    bench = f"{REPO}/examples/build/bench.bin"
    for path in (primes, bench):
        if not os.path.exists(path):
            sys.exit(f"hwtest.py: {path} is missing; run 'make examples'")
    if not args.no_program and not os.path.exists(args.bit):
        sys.exit(f"hwtest.py: {args.bit} is missing; build it, or give --bit")

    with tempfile.TemporaryDirectory() as tmp:
        echo = assemble(f"{REPO}/sim/echo.nasm", tmp)
        emu = assemble(f"{REPO}/sim/emu.nasm", tmp)

        opened = False
        try:
            # Before the port is opened, as openFPGALoader takes the FTDI chip
            cable = []
            if not args.no_program:
                if not sys.platform.startswith("linux"):
                    sys.exit("hwtest.py: programming needs Linux; program "
                             "the FPGA yourself and give --no-program")
                cable = check_board(args.port, args.bit)
            link = Link(Serial(args.port, args.baud))
            opened = True
            try:
                if not args.no_program:
                    test_boot(link, args.bit, cable)
                test_link(link)
                test_framing(link)
                test_echo(link, echo)
                test_reset(link, echo)
                test_clear(link)
                test_readback(link, emu)
                test_counters_stop(link)
                test_screen_registers(link)
                test_board_devices(link, board)
                test_fetch_statistics(link)
                test_primes(link, primes, board)
            finally:
                link.close()
            serial = ["--port", args.port, "--baud", str(args.baud)]
            test_run(serial, comparisons(tmp))
            test_bench(serial, bench)
        except LinkError as e:
            print(f"hwtest.py: {e}", file=sys.stderr, flush=True)
            results.append(False)
        except SystemExit as e:
            # fail() and require() exit with a message; keep going to the
            # cleanup and the summary
            if e.code not in (0, None):
                print(e.code, file=sys.stderr, flush=True)
                if all(results):  # else a failed check is already counted
                    results.append(False)
        finally:
            if opened:
                cleanup(args.port, args.baud)

    passed = sum(results)
    print(f"\n{passed}/{len(results)} passed")
    if skipped:
        print(f"SKIPPED, as {NICEEMU} is missing: {', '.join(skipped)}")
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    main()
