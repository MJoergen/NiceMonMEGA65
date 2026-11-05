#!/usr/bin/env python3
"""Test the system on the MEGA65 or Nexys4DDR board through its debug UART.

Usage:
    tools/hwtest.py --port DEVICE [--baud 2000000]
                    [--bit synth/r6/build/top.bit]
                    [--board mega65|nexys4ddr] [--no-program]
                    [--eth HOST[:PORT]]

    Build the bitstream and the examples first, and niceemu
    (make -C nice_cpu/emulator build), or the checks that need it are
    skipped, and the summary names them after a SKIPPED.

    --board says which board it is, for the checks of the RAM's size and
    the board's devices. By default the FPGA tells, when it is programmed:
    an xc7a100t is the Nexys4DDR, and an xc7a200t a MEGA65. With
    --no-program the name of the --bit file tells: a path with nexys4ddr
    in it is the Nexys4DDR, any other is a MEGA65.

    --no-program skips programming and the boot test, the b notice and the
    checks of the ROM, for a board that is already programmed.

    --eth HOST tests the Ethernet station too, with the board's Ethernet
    port on this computer's network: HOST is the IP address the board
    gets, which no other device may have, and PORT the link's TCP port,
    4510 by default.

Programming:
    It finds the JTAG cable on the same USB device as the serial port,
    reads the FPGA's IDCODE through it, and stops unless the FPGA is the
    part the bitstream was built for. It then programs the FPGA through
    that cable alone, so with several boards attached it programs the
    board whose UART it tests. openFPGALoader does both, for the MEGA65 and
    the Nexys4DDR alike. Programming needs Linux, as the JTAG cable is
    found through /sys; with --no-program the script runs wherever load.py
    does.

Checks, in this order:
    - the link's b notice, and the ROM when the bitstream has one
    Then, with the ROM hidden, the debug link (nice_cpu/doc/DEBUG.md):
    - bad packets are dropped, and nicelink sends a dropped request again
    - sim/echo.nasm loads and runs, and the link reaches only its debug
      registers while it runs
    - a hold and a restart of the core
    - sim/pause.nasm pauses, and the registers, the memory, the counters,
      and the input are checked while paused, after going on, after a
      hold, and after a start paused
    - sim/step.nasm steps to its halt, and the registers after each step
      are compared with niceemu --trace
    - sim/break.nasm stops at breakpoints
    - sim/step.nasm, paused, takes writes of R0-R15, and goes on from
      them, compared with the same on niceemu --link; a write while
      halted or held is refused
    - the memory is cleared
    - 0xFFFFFF9E reads the RAM's words, and the top word of the RAM holds
      a word, apart from the word of a RAM half the size
    - what sim/emu.nasm leaves after its halt is read back, and the cycle
      counter and the timer stop there
    - the screen's registers are written and read
    - the fonts (doc/SYSTEM.md, The font): the character ROM holds
      Spleen's A and drops a write, the font RAM keeps bits 15..0 of the
      words of a glyph and leaves the RAM it aliases, the font base is
      kept, and a clear makes the font RAM and the base 0
    - the board's devices are written and read: on the Nexys4DDR the LEDs,
      RGB LEDs, and seven-segment display, and the buttons and switches,
      which only a read can check; on the MEGA65 the block reads 0
    - the SD card controller (doc/SYSTEM.md, The SD card slots): its slots,
      the reserved word, SD_CHUNK, and every word of the buffer, written
      and read; a slot the board does not have shows no card. Then for each
      slot with a card: Init, its type and last sector, a Read of sector 0,
      twice, and of the last sector, and the sector after the last one out
      of range. Sector 0 ends in 55 AA, and is a FAT boot sector, or an
      MBR whose first partition starts with one. A write-protected card
      refuses a Write with error 6, which writes nothing. Nothing is ever
      written to a card. A slot without a card, a card without 55 AA in
      sector 0, and a card with another file system, exFAT or NTFS, or a
      GPT, are named after NOT COVERED.
    - the C example examples/build/primes.bin runs, and after its halt the
      microsecond counter holds the cycle counter's count over the clock
      in MHz
    Last, programs run with tools/run.py and with niceemu, and their
    output and exit status are compared:
    - sim/eof.nasm, also for the end of the input, and an input file of
      1536 bytes
    - a program that halts at once although 100 lines of input wait for it
    - the emulator's trapsym.nasm and its label file, for --symbols
    - the ROM of the release, the monitor and the demo behind it,
      demo/build/rom_test.bin, with x for the demo, and its screen
    - nice_cpu's benchmark, examples/build/bench.bin, all but its cycles
    - the monitor's test program, monitor/test/hello.nasm, with run.py
      --monitor and the monitor of the tests from --rom, against niceemu
      on the two joined, also with 448 rows of d that are still coming
      when the input ends, and under the monitor in the board's ROM, if it
      has one, which must return its status; and the monitor's l, with the
      600 lines of hello.bin pasted at the UART's full rate, then r
    - load.py refuses a word beyond the RAM that 0xFFFFFF9E gives, under
      the monitor and without it
    And the demo's self-test, F11, runs with tools/run.py, and its four
    tests must pass, as their timer and instruction counts depend on the
    core.
    The programs run with the ROM hidden, so the RAM is at 0, but for
    the one under the monitor in the board's ROM.
    With --eth, last of all, the Ethernet station, which no failure above
    or here keeps the other checks from:
    - the ROM, loaded at 0, gets the monitor's i, the IP address, and CR
      as console bytes over the UART, as from a terminal, and gives the
      station that address, which a pause reads back
    - ping gets its answers, and the station counts the requests and its
      replies; when no frame at all has come, the board has no Ethernet
      connection, and the summary names the rest after NOT COVERED
      instead of failing
    - the link over TCP to that address pauses the monitor and reads the
      address, while the monitor still has it
    - programs run with tools/run.py --eth and with niceemu, and their
      output and exit status are compared, as above, and so is the
      monitor's test program, with --monitor
    Without --eth, the summary names the Ethernet station after NOT
    COVERED.

Exit status:
    0 if every check passed, else 1.

Notes:
    A check that leaves the board in a state in which every later check
    would fail stops the run. Whatever happens, the script ends by holding
    the core with the ROM hidden (the cleanup says so if the link did not
    answer), and it prints the summary. Only the Python standard library
    is used, and openFPGALoader when the FPGA is programmed.
"""

import argparse
import os
import re
import socket
import struct
import subprocess
import sys
import tempfile
import time
from typing import Callable, TypeVar

from jtag import check_board
from load import (MAX_RAM_WORDS, MONITOR_WORDS, PROGRAM, RAM_SIZE, load_words,
                  read_bin, start)
from nicelink import (BRK_COUNT, BRK_EN, CONTROL, ETH_PORT, FREE, HOLD,
                      PAUSE, RAM, REGS, STEP, STOP, VERSION, Eth, Link,
                      LinkError, Serial, Tcp, packet)

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NICEEMU = f"{REPO}/nice_cpu/emulator/zig-out/bin/niceemu"
# The debug link of the pinned nice_cpu, which the bitstream is built from
DEBUG_LINK = f"{REPO}/nice_cpu/hdl/src/debug_link.vhd"
# The clock of each board, which sets the rate of the microsecond counter
CLOCK_HZ = {"mega65": 100_000_000, "nexys4ddr": 90_000_000}
# The words of the RAM, which 0xFFFFFF9E reads
RAM_WORDS = {"mega65": 0x20000, "nexys4ddr": 0x10000}
# The SD card controller's registers (nice_cpu's SYSTEM.md §5); A7 is
# reserved
SD_CSR, SD_LBA, SD_CHUNK, SD_ERROR, SD_SELECT, SD_LAST, SD_SLOTS = \
    range(0xFFFFFFA0, 0xFFFFFFA7)
SD_RESERVED = 0xFFFFFFA7
SD_BUF = 0xFFFFFFA8
# The slots of each board (doc/SYSTEM.md)
SD_SLOT_COUNT = {"mega65": 2, "nexys4ddr": 1}

T = TypeVar("T")

# How long console() and answers() wait for the next byte, and run.py's
# --timeout in test_run. tools/cosimtest.py makes them longer for the
# simulation, which runs far slower than real time.
QUIET = 0.5
RUN_TIMEOUT = 10.0

results: list[bool] = []
# The checks that could not run, which the summary names
skipped: list[str] = []
# What the run did not test, and why, which the summary names too
uncovered: list[str] = []


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


def assemble_labels(src: str, out_dir: str) -> tuple[str, dict[str, int]]:
    """Like assemble, and the addresses of the program's labels, from
    niceasm.py --symbols."""
    base = os.path.join(out_dir, os.path.basename(src).replace(".nasm", ""))
    subprocess.run([sys.executable, f"{REPO}/nice_cpu/assembler/niceasm.py",
                    "-o", base + ".bin", "--symbols", base + ".sym", src],
                   check=True)
    with open(base + ".sym") as f:
        return base + ".bin", {
            name: int(addr, 16)
            for addr, name in (line.split() for line in f if line.strip())}


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


def link_version() -> int:
    """The version of the link, C_VERSION of the pinned nice_cpu's
    debug_link.vhd."""
    with open(DEBUG_LINK) as f:
        m = re.search(r'constant C_VERSION *: *t_word *:= *'
                      r'X"([0-9A-Fa-f]{8})"', f.read())
    if not m:
        sys.exit(f"hwtest.py: no C_VERSION in {DEBUG_LINK}")
    return int(m.group(1), 16)


def test_link(link: Link) -> None:
    link.control(HOLD | RAM)
    require("hide the ROM", ctl(link) in ("00000009", "0000000B"), ctl(link))
    want = link_version()
    got = rd(link, VERSION)
    check(f"version {want >> 4}.{want & 0xF}, as nice_cpu's debug_link.vhd",
          got == want, f"{got:02X}")
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


def test_ram_size(link: Link, board: str) -> None:
    """The words of the RAM at FFFFFF9E, 128K on the MEGA65 and 64K on the
    Nexys4DDR, which takes no write. The top word of the RAM holds what is
    written to it, and so does the word of a RAM half the size, which is
    another word: the RAM has all the words it says. The address of the
    top word plus the RAM's size reads the top word again, as the RAM
    repeats. The core is held."""
    want = RAM_WORDS[board]
    ram = rd(link, RAM_SIZE)
    check("FFFFFF9E reads the RAM's words", ram == want,
          f"got {ram:08X}, want {want:08X}")
    check("FFFFFF9E takes no write",
          wr(link, RAM_SIZE, 0) and rd(link, RAM_SIZE) == ram)
    top, half = want - 1, want // 2 - 1
    check(f"W {top:08X} and {half:08X}",
          wr(link, top, 0x7A5A0001) and wr(link, half, 0x7A5A0002))
    for addr, value in [(top, 0x7A5A0001), (half, 0x7A5A0002),
                        (top + want, 0x7A5A0001)]:
        got = rd(link, addr)
        check(f"readback {addr:08X}", got == value,
              f"got {got:08X}, want {value:08X}")
    check("the words cleared again", wr(link, top, 0) and wr(link, half, 0))


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


def wait_pause(link: Link, before: int) -> bool:
    """Whether a p notice has come after the first before of them."""
    end = time.monotonic() + 4 * QUIET
    while link.pauses == before and time.monotonic() < end:
        link.poll(end - time.monotonic())
    return link.pauses > before


def test_pause(link: Link, prog: str) -> None:
    """The pause of DEBUG.md §6 on sim/pause.nasm, which counts in R1 and
    stores each count at 0x100: the p notice, bit 4, R0-R15 and the memory
    while paused, the cycle counter stopped, a console byte kept in the
    input buffer, going on, a write of R1 while paused that the count
    goes on from, one while running refused, a hold that keeps the
    registers, and a start paused before the first instruction."""
    load(link, prog)
    n = link.pauses
    link.control(PAUSE | RAM)
    require("pause sends p", wait_pause(link, n))
    check("pause sets bit 4", ctl(link) == "00000018", ctl(link))
    r1, r15 = rd(link, REGS + 1), rd(link, REGS + 15)
    stored = rd(link, 0x100)
    check("R1 and memory agree while paused", r1 - stored in (0, 1),
          f"R1 {r1:08X}, 0x100 {stored:08X}")
    check("R15 at an instruction while paused", r15 in (2, 4, 6),
          f"{r15:08X}")
    cycles = rd(link, 0xFFFFFF40)
    time.sleep(0.2)
    check("paused core does not run",
          rd(link, REGS + 1) == r1 and rd(link, 0x100) == stored)
    check("cycle counter stops while paused", rd(link, 0xFFFFFF40) == cycles,
          f"{cycles:08X}")
    free = link.free()
    link.send_console(b"x", paced=False)
    time.sleep(0.1)
    check("console byte kept while paused", link.free() == free - 1,
          f"{free} before, {link.free()} after")
    link.control(RAM)
    check("go on clears bit 4", ctl(link) == "00000008", ctl(link))
    n = link.pauses
    link.control(PAUSE | RAM)
    require("pause again sends p", wait_pause(link, n))
    later = rd(link, REGS + 1)
    check("count goes on after the pause", later > r1,
          f"{r1:08X}, then {later:08X}")
    # Link version 6: R1-R15 take a write while paused, and the core goes
    # on from it; a write while it runs is refused with e04.
    check("write R1 while paused", wr(link, REGS + 1, 0x40000000) and
          rd(link, REGS + 1) == 0x40000000, f"{rd(link, REGS + 1):08X}")
    link.control(RAM)
    print("  a write of R1 while running, which the link refuses:")
    check("write R1 while running refused", not wr(link, REGS + 1, 0))
    n = link.pauses
    link.control(PAUSE | RAM)
    require("pause after the write sends p", wait_pause(link, n))
    later = rd(link, REGS + 1)
    check("count goes on from the written R1",
          0x40000000 < later < 0x50000000, f"{later:08X}")
    link.control(HOLD | RAM)
    check("hold ends the pause", ctl(link) == "00000009", ctl(link))
    check("hold keeps R1 of the pause", rd(link, REGS + 1) == later)
    n = link.pauses
    link.control(HOLD | PAUSE | RAM)
    link.control(PAUSE | RAM)
    require("start paused sends p", wait_pause(link, n))
    check("start paused stops at address 0", rd(link, REGS + 15) == 0,
          f"{rd(link, REGS + 15):08X}")
    link.control(HOLD | RAM)


def trace_regs(path: str) -> list[list[int]]:
    """R0-R15 after each step of the program, from niceemu --trace, which
    prints the registers that each step changes (nice_cpu/emulator/README.md,
    Trace format). R15 is the address of the next step's instruction unless
    the line gives it, and after the halt the PC of the Halted line."""
    r = subprocess.run([NICEEMU, "--max-steps", "1000", "--trace", path],
                       stdin=subprocess.DEVNULL, capture_output=True,
                       check=True, text=True)
    regs = [0] * 16
    regs[14] = 0x01000000  # ISA.md §8.1
    after: list[list[int]] = []
    explicit: list[bool] = []
    for line in r.stdout.splitlines():
        m = re.match(r"([0-9a-f]{8}) [0-9a-f]{8}|(IRQ|NMI) [0-9a-f]{2}", line)
        if m:
            if m.group(1) and explicit and not explicit[-1]:
                after[-1][15] = int(m.group(1), 16)
            for n, v in re.findall(r"\bR(\d+)=([0-9a-f]{8})", line):
                regs[int(n)] = int(v, 16)
            after.append(list(regs))
            explicit.append(" R15=" in line)
        m = re.match(r"Halted \(.*\) after \d+ steps, PC=([0-9a-f]{8})", line)
        if m and after:
            after[-1][15] = int(m.group(1), 16)
    return after


def test_step(link: Link, prog: str) -> None:
    """The single step of DEBUG.md §6 on sim/step.nasm: a start paused,
    then a step at a time to its HALT, with R0-R15 after each step compared
    with niceemu --trace, the INT and its routine included. Bit 5 reads 0,
    the instruction counter counts the steps, and a step of a halted core
    does nothing."""
    if not os.path.exists(NICEEMU):
        skipped.append("step")
        return
    want = trace_regs(prog)
    link.halts.clear()
    load_words(link, read_bin(prog))
    n = link.pauses
    link.control(PAUSE | RAM)
    require("step: start paused sends p", wait_pause(link, n))
    first = link.read(REGS, 16)
    check("step: registers at the start", first[:14] == [0] * 14 and
          first[14:] == [0x01000000, 0], " ".join(f"{r:08X}" for r in first))
    wrong = []
    reason = None
    for i, regs in enumerate(want):
        reason = link.step(timeout=4 * QUIET)
        if reason is not None:
            break
        if i == 0:
            check("step: bit 5 reads 0", ctl(link) == "00000018", ctl(link))
        if i == 7:
            count = rd(link, 0xFFFFFF42)
            check("step: instructions counted", count == 8, f"{count:08X}")
        got = link.read(REGS, 16)
        if got != regs:
            wrong.append(f"step {i + 1}: " + " ".join(
                f"R{r}={got[r]:08X}/{regs[r]:08X}" for r in range(16)
                if got[r] != regs[r]))
    check("step: the registers of each step as niceemu --trace",
          not wrong and i == len(want) - 1, "; ".join(wrong) +
          f" ({i + 1} of {len(want)} steps)")
    check("step: the last step halts", reason == 1, str(reason))
    got = link.read(REGS, 16)
    check("step: the registers after the halt", got == want[-1],
          " ".join(f"{r:08X}" for r in got))
    n = link.pauses
    link.control(STEP | PAUSE | RAM)
    check("step of a halted core does nothing",
          not wait_pause(link, n) and ctl(link) == "0000000A", ctl(link))
    # A hold keeps bit 1 until the next start, so start paused and hold, to
    # leave the core held as test_pause does.
    n = link.pauses
    link.control(HOLD | PAUSE | RAM)
    link.control(PAUSE | RAM)
    wait_pause(link, n)
    link.control(HOLD | RAM)


def wait_break(link: Link, before: int) -> int | None:
    """The number of the x notice after the first before of them, or
    None when none has come."""
    end = time.monotonic() + 4 * QUIET
    while len(link.breaks) == before and time.monotonic() < end:
        link.poll(end - time.monotonic())
    return link.breaks[before] if len(link.breaks) > before else None


def test_break(link: Link, prog: str, at: dict[str, int]) -> None:
    """The breakpoints of DEBUG.md §6 on sim/break.nasm, at its labels
    (at): a start paused at a breakpoint, a loop that stops on each pass,
    two breakpoints at one address, which send the lower number, one
    disabled, a skipped instruction, a step that ends at a breakpoint, an
    instruction with a read from memory, the second word of a two-word
    instruction, which does not match, the first instruction of an
    interrupt routine and the one after its RTI, and a HALT at a
    breakpoint, which halts after a go on. Each stop sends x, never p, with
    R15 at the breakpoint and its number in the stop register, which reads
    0 again after the halt. A system without breakpoints passes this."""
    count = rd(link, BRK_COUNT)
    if count == 0:
        check("break: the system has no breakpoints", True)
        return
    require("break: 4 breakpoints or more", count >= 4, str(count))
    link.halts.clear()
    load_words(link, read_bin(prog))
    pauses, first = link.pauses, len(link.breaks)
    breaks = first

    def stop(name: str, label: str, number: int) -> None:
        nonlocal breaks
        got = wait_break(link, breaks)
        breaks = len(link.breaks)
        r15 = rd(link, REGS + 15)
        stop_reg = rd(link, STOP)
        check(f"break: {name}", got == number and r15 == at[label] and
              stop_reg == 0x100 + number,
              f"x {got}, R15 {r15:08X}, stop {stop_reg:08X}")

    link.set_breaks([at["LOOP"], at["LOOP"], at["TWO"] + 1, at["START"]])
    link.control(HOLD | PAUSE | RAM)
    link.control(PAUSE | RAM)
    stop("start paused at a breakpoint", "START", 3)
    check("break: bit 4 reads 1", ctl(link) == "00000018", ctl(link))
    link.control(RAM)
    stop("the loop's first pass, the lower of two", "LOOP", 0)
    link.control(RAM)
    stop("the loop's second pass", "LOOP", 0)
    link.write(BRK_EN, [0b1110])
    link.control(RAM)
    stop("the loop's third pass, breakpoint 0 disabled", "LOOP", 1)
    link.set_breaks([at["SKIP"], at["READ"], at["TWO"] + 1, at["V3"]])
    link.control(RAM)
    stop("a skipped instruction", "SKIP", 0)
    reason = link.step()
    check("break: a step sends no h", reason is None, str(reason))
    stop("a step that ends at one", "READ", 1)
    link.control(RAM)
    stop("an interrupt routine, past a read and a second word", "V3", 3)
    link.set_breaks([at["AFTER"], at["DONE"]])
    link.control(RAM)
    stop("the instruction after RTI", "AFTER", 0)
    link.control(RAM)
    stop("a HALT", "DONE", 1)
    link.control(RAM)
    reason = wait_halt(link)
    check("break: go on from a HALT halts", reason == 1, str(reason))
    check("break: the stop register reads 0 after the halt",
          rd(link, STOP) == 0, f"{rd(link, STOP):08X}")
    check("break: no p notice",
          link.pauses - pauses == len(link.breaks) - first,
          f"{link.pauses - pauses} stops, {len(link.breaks) - first} x")
    link.write(BRK_EN, [0])
    # A hold keeps bit 1 until the next start, so start paused and hold, to
    # leave the core held as test_pause does.
    n = link.pauses
    link.control(HOLD | PAUSE | RAM)
    link.control(PAUSE | RAM)
    wait_pause(link, n)
    link.control(HOLD | RAM)


def start_emu(addr: str = "127.0.0.1") -> tuple[subprocess.Popen[bytes], str]:
    """niceemu --link on a free port of addr, and that port. Its stderr,
    where it prints the report of each run, is left for the caller to read
    away."""
    emu = subprocess.Popen([NICEEMU, "--link", f"{addr}:0"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    assert emu.stderr is not None
    first = emu.stderr.readline().decode(errors="replace")
    m = re.search(r"link: port (\d+)", first)
    if not m:
        emu.terminate()
        emu.wait()
        sys.exit(f"hwtest.py: niceemu --link printed {first!r}, not its "
                 "port")
    return emu, m.group(1)


# The words that write_regs() writes to R0-R15 of sim/step.nasm, paused
# after its first four steps: R0 takes none, R4 is the loop's count, R13
# points where the store goes, R14 has VBASE 1 and bit 24 clear, and R15
# is LOOP, which write_regs() puts in.
REG_WORDS = [0xDEADBEEF] + [0x11111111 * n for n in range(1, 13)]
REG_WORDS[4] = 3
REG_WORDS[13:] = [0x300, 0x00000001]


def write_regs(link: Link, prog: str, at: dict[str, int]) -> list[object]:
    """The writes of R0-R15 of DEBUG.md §6, link version 6, on
    sim/step.nasm, and what follows them, as a list to compare with
    niceemu --link's: a start paused, four steps, a write of all sixteen
    with R15 at LOOP, R0 alone, and R14 alone with bit 24 clear, each
    read back; then breakpoint 0 at LOOP and a go on, which runs LOOP's
    instruction first and stops there on the next pass; then steps to the
    halt, with R0-R15 after each, and the word stored over 0xFFFFFFFF.
    Last, a write
    refused with e04 while halted, and while held, after a write of R0
    alone while paused, which takes."""
    out: list[object] = []
    link.halts.clear()
    load_words(link, read_bin(prog))
    n = link.pauses
    link.control(HOLD | PAUSE | RAM)
    link.control(PAUSE | RAM)
    require("write: start paused sends p", wait_pause(link, n))
    for _ in range(4):
        out.append(link.step(timeout=4 * QUIET))
    words = REG_WORDS[:15] + [at["LOOP"]]
    out.append(wr_words(link, REGS, words))
    out.append(link.read(REGS, 16))
    out.append(wr(link, REGS, 0x12345678))
    out.append(rd(link, REGS))
    out.append(wr(link, REGS + 14, 0x00000001))
    out.append(rd(link, REGS + 14))
    out.append(wr(link, 0x300, 0xFFFFFFFF))
    link.set_breaks([at["LOOP"]])
    breaks = len(link.breaks)
    link.control(RAM)
    out.append(wait_break(link, breaks))
    link.write(BRK_EN, [0])
    out.append(link.read(REGS, 16))
    for _ in range(8):
        why = link.step(timeout=4 * QUIET)
        out.append(why)
        out.append(link.read(REGS, 16))
        if why is not None:
            break
    out.append(rd(link, 0x300))
    print("  writes of R1, halted, then held, which the link refuses:")
    out.append(wr(link, REGS + 1, 0))
    out.append(rd(link, REGS + 1))
    n = link.pauses
    link.control(HOLD | PAUSE | RAM)
    link.control(PAUSE | RAM)
    wait_pause(link, n)
    out.append(wr(link, REGS, 0))
    link.control(HOLD | RAM)
    out.append(wr(link, REGS + 1, 0))
    return out


def wr_words(link: Link, addr: int, words: list[int]) -> bool:
    """Writes the words with one W; False when the link refuses it."""
    try:
        link.write(addr, words)
    except LinkError as e:
        print(f"  {e}")
        return False
    return True


def test_write_regs(link: Link, prog: str, at: dict[str, int]) -> None:
    """write_regs() on the link, with its own checks, and compared with the
    same on niceemu --link: R0 takes no write, R14 keeps bit 24, a write
    of R15 is where the core goes on, a PC set onto a breakpoint runs its
    instruction, and a write while halted or held gets e04."""
    if not os.path.exists(NICEEMU):
        skipped.append("write registers")
        return
    if rd(link, BRK_COUNT) == 0:
        check("write: the system has no breakpoints", True)
        return
    got = write_regs(link, prog, at)
    regs = got[5]
    want = REG_WORDS[:15] + [at["LOOP"]]
    want[0] = 0
    want[14] |= 0x01000000
    check("write: R0-R15 in one W", got[4] is True and regs == want,
          " ".join(f"{r:08X}" for r in regs) if isinstance(regs, list)
          else str(regs))
    check("write: R0 alone takes none", got[6] is True and got[7] == 0,
          f"{got[7]:08X}" if isinstance(got[7], int) else str(got[7]))
    check("write: R14 keeps bit 24", got[8] is True and got[9] == 0x01000001,
          f"{got[9]:08X}" if isinstance(got[9], int) else str(got[9]))
    after = got[12]
    check("write: the PC set onto a breakpoint runs it, and stops there "
          "next", got[11] == 0 and isinstance(after, list) and
          after[4] == 2 and after[15] == at["LOOP"],
          f"x {got[11]}, " + (f"R4 {after[4]:08X}, R15 {after[15]:08X}"
                              if isinstance(after, list) else str(after)))
    check("write: the steps to the halt from the written registers",
          got[-7] == 1 and got[-5] == 0,
          f"halt {got[-7]}, stored {got[-5]!r}")
    check("write: refused while halted, and R1 kept",
          got[-4] is False and got[-3] == want[1])
    check("write: R0 alone while paused at the start", got[-2] is True)
    check("write: refused while held", got[-1] is False)
    emu, port = start_emu()
    try:
        drain = subprocess.Popen(["cat"], stdin=emu.stderr,
                                 stdout=subprocess.DEVNULL)
        ref = Link(Tcp(int(port)))
        try:
            print("  the same on niceemu --link:")
            ref.control(HOLD | RAM)
            exp = write_regs(ref, prog, at)
        finally:
            ref.close()
    finally:
        emu.terminate()
        emu.wait()
    drain.wait()
    diff = [f"{i}: {g!r} / {e!r}" for i, (g, e) in enumerate(zip(got, exp))
            if g != e]
    check("write: all of it as on niceemu --link",
          not diff and len(got) == len(exp), "; ".join(diff) +
          f" ({len(got)} and {len(exp)} results)")


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


# The fonts of nice_cpu's SYSTEM.md section 1.8
FONT_RAM  = 0xFFFE0000
FONT_ROM  = 0xFFFE2000
FONT_BASE = 0xFFFFFF86


def spleen(code: int) -> list[int]:
    """The 32 rows of the glyph of code in src/video/font_pkg.vhd, which
    lists the rows that are not 0."""
    rows = {int(m.group(1)): int(m.group(2), 2) for m in re.finditer(
        r'(\d+) => "([01]{16})"', open(f"{REPO}/src/video/font_pkg.vhd").read())}
    return [rows.get(32 * code + r, 0) for r in range(32)]


def test_fonts(link: Link) -> None:
    """The character ROM, the font RAM, and the font base. The display
    shows the glyph of 0x80 in the font RAM until the clear at the end."""
    a = spleen(0x41)
    rows = link.read(FONT_ROM + 32 * 0x41, 32)
    check("the character ROM holds Spleen's A", rows == a,
          " ".join(f"{w:04X}" for w in rows))
    row9 = FONT_ROM + 32 * 0x41 + 9
    check("W to the character ROM", wr(link, row9, 0))
    got = rd(link, row9)
    check("the character ROM drops a write", got == a[9], f"{got:08X}")
    # 0xFFFE1000, the glyph of 0x80, aliases the RAM word 0x1000 on both
    # boards
    alias = 0x5AA5C33C
    check("W of the RAM that the font RAM aliases", wr(link, 0x1000, alias))
    glyph = [0xA5000000 | r * 0x0421 for r in range(32)]
    check("W of a glyph to the font RAM", wr_words(link, FONT_RAM + 32 * 0x80, glyph))
    rows = link.read(FONT_RAM + 32 * 0x80, 32)
    check("the font RAM keeps bits 15..0", rows == [w & 0xFFFF for w in glyph],
          " ".join(f"{w:08X}" for w in rows))
    got = rd(link, 0x1000)
    check("the font RAM leaves the RAM it aliases", got == alias,
          f"{got:08X}")
    check("W of the font base", wr(link, FONT_BASE, FONT_RAM))
    got = rd(link, FONT_BASE)
    check("the font base is kept", got == FONT_RAM, f"{got:08X}")
    link.control(HOLD | 4 | RAM)
    rows = link.read(FONT_RAM + 32 * 0x80, 32)
    check("the clear zeros the font RAM", rows == [0] * 32,
          " ".join(f"{w:04X}" for w in rows))
    got = rd(link, FONT_BASE)
    check("the clear zeros the font base", got == 0, f"{got:08X}")
    got = rd(link, row9)
    check("the clear keeps the character ROM", got == a[9], f"{got:08X}")


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


def sd_said(got: tuple[int, int] | None) -> str:
    """What sd_run returned, for a check's detail."""
    return "busy too long" if got is None else \
        f"status {got[0]:08X}, error {got[1]}"


def sd_run(link: Link, cmd: int, timeout: float) -> tuple[int, int] | None:
    """Starts an SD card command, and waits for busy to fall: the status
    and the error after it, or None after the timeout."""
    link.write(SD_CSR, [cmd])
    end = time.monotonic() + timeout
    while True:
        csr = rd(link, SD_CSR)
        if csr & 1 == 0:
            return csr, rd(link, SD_ERROR)
        if time.monotonic() > end:
            return None


def sd_sector(link: Link) -> bytes:
    """The 512 bytes of the buffer, read a chunk at a time."""
    data = bytearray()
    for c in range(16):
        link.write(SD_CHUNK, [c])
        for w in link.read(SD_BUF, 8):
            data += w.to_bytes(4, "little")
    return bytes(data)


def sd_read(link: Link, name: str, lba: int) -> bytes | None:
    """Reads a sector into the buffer, and its bytes, or None when the
    Read fails."""
    link.write(SD_LBA, [lba])
    got = sd_run(link, 1, 1.0)
    if not check(f"{name}: Read of sector {lba:#x}",
                 got is not None and got[1] == 0,
                 sd_said(got)):
        return None
    return sd_sector(link)


def fs_kind(sector: bytes) -> str | None:
    """The file system whose boot sector a sector is, or None: FAT, for
    FAT12, FAT16, or FAT32, with a jump, 512 bytes in a sector, the
    type's name where the boot sector of its kind has it, and 55 AA; or
    exFAT or NTFS, by the name after the jump."""
    if sector[510:] != b"\x55\xaa" or sector[0] not in (0xEB, 0xE9):
        return None
    if (sector[11:13] == b"\x00\x02"
            and (sector[54:59] == b"FAT12" or sector[54:59] == b"FAT16"
                 or sector[82:87] == b"FAT32")):
        return "FAT"
    if sector[3:11] == b"EXFAT   ":
        return "exFAT"
    if sector[3:11] == b"NTFS    ":
        return "NTFS"
    return None


def test_sd_fat(link: Link, name: str, first: bytes) -> None:
    """Checks the file system of a card from its sector 0, first, which
    is either a FAT boot sector itself or an MBR whose first partition
    starts with one. A sector 0 without 55 AA is a card that is not
    formatted, and exFAT, NTFS, and a GPT are a file system or a
    partition table the check does not know, as an SDXC card comes with
    exFAT: all are not covered, not failures."""
    if first[510:] != b"\x55\xaa":
        uncovered.append(f"{name}'s file system, as sector 0 has no 55 AA")
        return
    kind = fs_kind(first)
    if kind == "FAT":
        check(f"{name}: sector 0 is a FAT boot sector", True)
        return
    if kind is not None:
        uncovered.append(f"{name}'s file system, as it is {kind}")
        return
    ptype = first[450]
    start = int.from_bytes(first[454:458], "little")
    if ptype == 0xEE:
        uncovered.append(f"{name}'s file system, as its partitions are a GPT")
        return
    if not check(f"{name}: sector 0 is an MBR, partition 1 at {start:#x}",
                 ptype != 0 and start > 0, f"type {ptype:#04x}"):
        return
    boot = sd_read(link, name, start)
    if boot is None:
        return
    kind = fs_kind(boot)
    if kind not in (None, "FAT"):
        uncovered.append(f"{name}'s file system, as partition 1 is {kind}")
        return
    check(f"{name}: sector {start:#x} is a FAT boot sector", kind == "FAT",
          repr(boot[3:11]))


def test_sd(link: Link, board: str) -> None:
    """The SD card controller at FFFFFFA0-AF, with the core held, as the
    header says. It only reads the cards."""
    slots = SD_SLOT_COUNT[board]
    n = rd(link, SD_SLOTS)
    check("SD_SLOTS", n == slots, f"got {n}, want {slots}")
    check("FFFFFFA7 reads 0 and takes no write",
          wr(link, SD_RESERVED, 0xFFFFFFFF) and rd(link, SD_RESERVED) == 0)
    check("SD_CHUNK takes bits 3..0",
          wr(link, SD_CHUNK, 0x12) and rd(link, SD_CHUNK) == 2)
    # Every word of the buffer, eight at a time
    for c in range(16):
        link.write(SD_CHUNK, [c])
        link.write(SD_BUF, [0x5D000000 + (c << 8) + k for k in range(8)])
    bad = []
    for c in range(16):
        link.write(SD_CHUNK, [c])
        bad += [8 * c + k for k, w in enumerate(link.read(SD_BUF, 8))
                if w != 0x5D000000 + (c << 8) + k]
    check("the SD buffer's 128 words", not bad,
          f"wrong: {bad}" if bad else "")
    # A slot the board does not have
    link.write(SD_SELECT, [5])
    csr = rd(link, SD_CSR)
    got = sd_run(link, 0, 1.0)
    check("SD slot 5: no card, and Init fails with error 1",
          csr & 4 == 0 and got is not None and got[1] == 1,
          f"present {csr >> 2 & 1}, {sd_said(got)}")
    for slot in range(slots):
        name = f"SD slot {slot}"
        link.write(SD_SELECT, [slot])
        csr = rd(link, SD_CSR)
        if csr & 4 == 0:
            got = sd_run(link, 0, 1.0)
            check(f"{name}: no card, Init fails with error 1",
                  got is not None and got[1] == 1, sd_said(got))
            uncovered.append(f"{name}, as it has no card")
            continue
        t0 = time.monotonic()
        got = sd_run(link, 0, 3.0)
        ms = (time.monotonic() - t0) * 1000
        if not check(f"{name}: Init", got is not None and got[1] == 0,
                     f"{sd_said(got)}, {ms:.0f} ms") \
                or got is None:
            continue
        csr = got[0]
        kind = (csr >> 8) & 3
        last = rd(link, SD_LAST)
        check(f"{name}: ready, type {kind}, last sector {last:#x} "
              f"({(last + 1) / 2048 / 1024:.2f} GiB)",
              csr & 0x18 == 0x08 and kind in (1, 2) and last > 0,
              f"status {csr:08X}")
        first = sd_read(link, name, 0)
        if first is not None:
            check(f"{name}: sector 0 reads the same again",
                  sd_read(link, name, 0) == first)
            test_sd_fat(link, name, first)
        sd_read(link, name, last)
        link.write(SD_LBA, [last + 1])
        got = sd_run(link, 1, 1.0)
        check(f"{name}: Read of sector {last + 1:#x} is out of range",
              got is not None and got[1] == 7, sd_said(got))
        if csr & 0x20:
            # The controller refuses it before anything reaches the card.
            link.write(SD_LBA, [last])
            got = sd_run(link, 2, 1.0)
            check(f"{name}: write-protected, Write fails with error 6",
                  got is not None and got[1] == 6, sd_said(got))
    link.write(SD_SELECT, [0])


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


# The monitor's command that runs the demo behind it in the ROM (demo/)
DEMO_KEY = b"x\r"


def rom_test() -> str:
    """The ROM with the monitor and the demo, as the release has it, with
    the version of their tests, built if need be; its path."""
    subprocess.run(["make", "-s", "-C", f"{REPO}/demo", "build/rom_test.bin"],
                   check=True)
    return f"{REPO}/demo/build/rom_test.bin"


def comparisons(tmp: str) -> list[tuple[str, list[str], bool]]:
    """The programs that test_run compares, assembled into tmp, with their
    options and input files."""
    emu = assemble(f"{REPO}/sim/emu.nasm", tmp)
    hello = assemble(f"{REPO}/nice_cpu/doc/intro/examples/hello.nasm", tmp)
    reserved = assemble(f"{REPO}/nice_cpu/emulator/test/reserved.nasm", tmp)
    eof = assemble(f"{REPO}/sim/eof.nasm", tmp)
    trapsym = assemble(f"{REPO}/nice_cpu/emulator/test/trapsym.nasm", tmp)
    # The ROM, the monitor and the demo, with the version of their tests,
    # loaded at 0 as any program, and the monitor's x and a few keys for
    # the demo
    demo = rom_test()
    keys = os.path.join(tmp, "keys.txt")
    with open(keys, "wb") as f:
        f.write(DEMO_KEY + b"Hello\tNICE\r\nabc\x7fd\x1b[Ae\n")
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
        (demo, ["-i", keys, "-s"], True),
    ]


def test_run(link_args: list[str],
             programs: list[tuple[str, list[str], bool]],
             via: str = "") -> None:
    """Runs each program with run.py and with niceemu, which must print the
    same and exit with the same status. link_args are run.py's options for
    the link. A program is (path, options, polls): when polls is true, the
    program waits for input in a loop, which takes more steps on the board,
    where a read returns 0 until a byte arrives, so the step counts are not
    compared. via, such as " over Ethernet", names the link in the checks.
    The port must be closed meanwhile."""
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
        check(f"run.py {name} as niceemu{via}", same,
              "" if same else f"\n  niceemu (exit {emu.returncode}): "
              f"{emu.stdout!r}\n  run.py (exit {board.returncode}): "
              f"{board.stdout!r} {board.stderr!r}")


def test_monitor(link_args: list[str], tmp: str, in_rom: bool = False,
                 via: str = "", long: bool = False) -> None:
    """Runs the monitor's test program, monitor/test/hello.nasm at 0x8000,
    with run.py --monitor --rom and the monitor of the tests, and with
    niceemu, on the two joined, with r and h, the commands that run it and
    halt the core, in the input. The two must print the same and exit with
    the same status, but for the steps, as the monitor waits for input in
    a loop. Then the monitor's l gets the lines of a .bin file pasted,
    with a word of 0 at 0x8000 loaded before, so that the r run.py types
    finds no program, and r runs what l wrote: a program that returns
    0x2A, assembled here, or with long hello.bin itself, 600 lines at the
    full rate of the line. With in_rom, it also runs under the monitor in
    the board's ROM, whose version differs, and checks the program's
    status, unless the bitstream has no ROM. With long, it also runs d
    8000 700 before the h, 448 rows, about 20 KB, which the board sends
    while run.py ends the input with a break: the host has to read on
    meanwhile (issue #67). The simulation of make cosim is too slow for
    it. link_args are run.py's options for the link, and via names it in
    the checks, as for test_run. The port must be closed meanwhile."""
    subprocess.run(["make", "-s", "-C", f"{REPO}/monitor",
                    "build/monitor_test.bin", "build/hello.bin"], check=True)
    monitor = f"{REPO}/monitor/build/monitor_test.bin"
    hello = f"{REPO}/monitor/build/hello.bin"
    joined = os.path.join(tmp, "monitor_hello.bin")
    with open(joined, "w") as f:
        for path in (monitor, hello):
            with open(path) as g:
                f.write(g.read())
    halt = os.path.join(tmp, "h.txt")
    with open(halt, "wb") as f:
        f.write(b"h\r")
    run_py = [sys.executable, f"{REPO}/tools/run.py"] + link_args + [
        "--timeout", f"{RUN_TIMEOUT:g}", "--monitor"]
    # The keys, the program run.py loads, and what niceemu runs
    inputs = [("", b"h\r", hello, joined)]
    if long:
        inputs.append((" with d 8000 700", b"d 8000 700\rh\r", hello,
                       joined))
    # l: the lines of a .bin file, each ended by LF, and an empty line, CR,
    # which ends the load. run.py loads a word of 0 at 0x8000, no program,
    # as niceemu has there with the monitor alone.
    none = os.path.join(tmp, "none.bin")
    with open(none, "w") as f:
        f.write(f"{PROGRAM:08x} 00000000\n")
    if long:
        paste = hello
    else:
        ret = os.path.join(tmp, "ret.nasm")
        with open(ret, "w") as f:
            f.write("; Returns the status 0x2A to the monitor\n"
                    "                .ORG    0x8000\n"
                    "                MOVE    R1, 0x2A\n"
                    "                RET\n")
        paste = assemble(ret, tmp)
    with open(paste, "rb") as f:
        lines = f.read()
    inputs.append((f" with l, {os.path.basename(paste)} pasted, and r",
                   b"l\r" + lines + b"\rr\rh\r", none, monitor))
    if os.path.exists(NICEEMU):
        for name, keys, prog, emu_prog in inputs:
            board_in = os.path.join(tmp, "monitor_in.txt")
            with open(board_in, "wb") as f:
                f.write(keys)
            emu_in = os.path.join(tmp, "monitor_rin.txt")
            with open(emu_in, "wb") as f:
                f.write(b"r\r" + keys)
            emu = subprocess.run([NICEEMU, "-i", emu_in, "-s", emu_prog],
                                 stdin=subprocess.DEVNULL, capture_output=True)
            board = subprocess.run(run_py + ["--rom", monitor, "-i", board_in,
                                             "-s", prog],
                                   stdin=subprocess.DEVNULL,
                                   capture_output=True)
            for r in (emu, board):
                r.stdout = re.sub(rb"after \d+ steps", b"after N steps",
                                  r.stdout)
            same = (emu.stdout == board.stdout and
                    emu.returncode == board.returncode)
            check(f"run.py --monitor --rom monitor_test.bin "
                  f"{os.path.basename(prog)}{name} as niceemu{via}", same,
                  "" if same else
                  f"\n  niceemu (exit {emu.returncode}): "
                  f"{emu.stdout[-400:]!r}\n  run.py (exit {board.returncode}): "
                  f"{board.stdout[-400:]!r} {board.stderr!r}")
    else:
        skipped.append("run.py --monitor as niceemu")
    if not in_rom:
        return
    board = subprocess.run(run_py + ["-i", halt, hello],
                           stdin=subprocess.DEVNULL, capture_output=True)
    if b"no ROM" in board.stderr:
        uncovered.append("run.py --monitor under the ROM's monitor, as the "
                         "bitstream has no ROM")
        return
    ok = board.returncode == 0 and b"Returned 0000002A" in board.stdout
    check(f"run.py --monitor hello.bin under the ROM's monitor{via}", ok,
          "" if ok else f"exit {board.returncode}: {board.stdout!r} "
          f"{board.stderr!r}")


def test_fit(link_args: list[str], tmp: str, ram: int) -> None:
    """load.py refuses a word beyond the RAM of ram words, which it reads
    at 0xFFFFFF9E with the core held (load.py, check_fit): under the
    monitor, with --rom and the monitor of the tests, a word at the
    monitor's variables, the first past a program's RAM, and without the
    monitor a word at the RAM's size, on a board whose RAM is smaller
    than the MEGA65's, as read_bin() refuses one beyond that for every
    board. A refused load leaves the core held and the memory cleared,
    as the next load does."""
    subprocess.run(["make", "-s", "-C", f"{REPO}/monitor",
                    "build/monitor_test.bin"], check=True)
    monitor = f"{REPO}/monitor/build/monitor_test.bin"
    cases = [(ram - MONITOR_WORDS, ["--monitor", "--rom", monitor],
              " under the monitor")]
    if ram < MAX_RAM_WORDS:
        cases.append((ram, [], ""))
    for addr, options, where in cases:
        beyond = os.path.join(tmp, "beyond.bin")
        with open(beyond, "w") as f:
            f.write(f"{addr:08x} 00000001\n")
        r = subprocess.run([sys.executable, f"{REPO}/tools/load.py"] +
                           link_args + ["--no-run"] + options + [beyond],
                           stdin=subprocess.DEVNULL, capture_output=True,
                           text=True)
        ok = r.returncode != 0 and "beyond" in r.stderr
        check(f"load.py refuses {addr:08X}{where}", ok,
              "" if ok else f"exit {r.returncode}: {r.stdout!r} {r.stderr!r}")


def test_selftest(link_args: list[str], tmp: str) -> None:
    """Runs the self-test of the demo's F11 with run.py, and checks that
    its four tests pass. Two of them depend on the core's pipeline, not on
    the ISA: the timer's 10 interrupts must come in 9500 to 10499 cycles,
    and the instruction counter must count 9 between two reads of it. So a
    core that times them otherwise fails here. Below the tests, the screen
    shows the Ethernet station's addresses and counts, which differ from
    board to board, so it is not compared with niceemu. link_args are
    run.py's options for the link. The port must be closed meanwhile."""
    rom = rom_test()
    keys = os.path.join(tmp, "f11.txt")
    with open(keys, "wb") as f:
        f.write(DEMO_KEY + b"\x1b[23~")
    board = subprocess.run([sys.executable, f"{REPO}/tools/run.py"] +
                           link_args + ["--timeout", f"{RUN_TIMEOUT:g}", "-s",
                                        "-i", keys, rom],
                           stdin=subprocess.DEVNULL, capture_output=True)
    rows = [line[1:] for line in
            board.stdout.decode(errors="replace").splitlines()
            if line.startswith("|")]
    for name in ("RAM", "Math unit", "Timer", "Performance counters"):
        row = next((r for r in rows if r.startswith(f"    {name}")), "")
        ok = row[50:54] == "PASS"
        check(f"demo self-test: {name}", ok,
              "" if ok else row.strip() if row else
              f"no row\n  {board.stdout!r} {board.stderr!r}")
    check("demo self-test: all passed", "  All tests passed." in rows)


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


def paused(link: Link, addrs: list[int]) -> list[int] | None:
    """The words at addrs, read in a pause of the running core, which then
    goes on; None if the pause did not come."""
    n = link.pauses
    link.control(PAUSE | RAM)
    if not wait_pause(link, n):
        return None
    words = [rd(link, a) for a in addrs]
    link.control(RAM)
    return words


def test_eth_ip(link: Link, rom: str, ip: str) -> list[int] | None:
    """Loads the ROM of the monitor and the demo, and types the monitor's
    i, the IP address, and CR, as console bytes, which i writes to the
    station. Returns the station's counts of the good frames received and
    the frames sent, or None if the address did not come."""
    want = struct.unpack(">I", socket.inet_aton(ip))[0]
    load(link, rom)
    time.sleep(QUIET)                  # the monitor's banner
    room = link.free()
    link.send_console(b"i " + ip.encode() + b"\r")
    # Until the monitor has taken every key, then the time for the CR
    end = time.monotonic() + 10 * QUIET
    while link.free() < room and time.monotonic() < end:
        link.poll(0.05)
    link.poll(QUIET)
    got = paused(link, [0xFFFFFF9A, 0xFFFFFF98, 0xFFFFFF9D])
    if not check(f"eth: the monitor's i typed over the UART gives the IP "
                 f"address {ip}",
                 got is not None and got[0] == want,
                 "no pause" if got is None else f"{got[0]:08X}"):
        return None
    assert got is not None
    return got[1:]


def test_eth(port: str, baud: int, eth: str,
             programs: list[tuple[str, list[str], bool]], rom: str,
             tmp: str) -> None:
    """The Ethernet station, last of all: the monitor's i gives it the IP
    address of eth's HOST from keys over the UART, ping gets the answers,
    the link over TCP reaches the monitor, and the programs run over it as
    over the UART. A board that receives no frame at all is not connected,
    which is not a failure but a gap in the coverage. A failure here is
    counted, and ends this test alone."""
    host, _, tcp = eth.partition(":")
    try:
        ip = socket.gethostbyname(host)
        want = struct.unpack(">I", socket.inet_aton(ip))[0]
        link = Link(Serial(port, baud))
        try:
            counts = test_eth_ip(link, rom, ip)
            if counts is None:
                return
            ping = subprocess.run(["ping", "-c", "3", "-W", "2", ip],
                                  capture_output=True, text=True)
            after = paused(link, [0xFFFFFF98, 0xFFFFFF9D])
            if after is None:
                check("eth: pause after the ping", False)
                return
            frames = (after[0] - counts[0]) & 0xFFFFFFFF
            replies = (after[1] - counts[1]) & 0xFFFFFFFF
            if ping.returncode != 0 and frames == 0:
                print(f"  no frame came to the station during the ping of "
                      f"{ip}: no Ethernet connection, or {ip} is not on "
                      "this computer's network, so the rest of the "
                      "Ethernet test is not run", flush=True)
                uncovered.append(f"the Ethernet station past its address, "
                                 f"as no frame came from {ip}'s network")
                return
            check("eth: ping answered", ping.returncode == 0,
                  "" if ping.returncode == 0 else
                  repr(ping.stdout + ping.stderr))
            # Three echo replies, and an ARP reply unless the host knew the
            # MAC
            check("eth: the replies counted", replies >= 3, str(replies))
            check("eth: the requests counted", frames >= 3, str(frames))
        finally:
            link.close()
        # The UART's link bytes are dropped while this connection is open
        tcp_link = Link(Eth(int(tcp) if tcp else ETH_PORT, ip))
        try:
            got = paused(tcp_link, [0xFFFFFF9A])
            check("eth: the link over TCP pauses the monitor and reads the "
                  "IP address", got is not None and got[0] == want,
                  "no pause" if got is None else f"{got[0]:08X}")
        finally:
            tcp_link.close()
        test_run(["--eth", eth], programs, " over Ethernet")
        test_monitor(["--eth", eth], tmp, True, " over Ethernet", long=True)
    except (LinkError, OSError) as e:
        check(f"eth: {e}", False)
    except SystemExit as e:
        # fail() and require() exit with a message
        if e.code not in (0, None):
            check(f"eth: {e.code}", False)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", required=True, metavar="DEVICE",
                        help="the serial device of the board's debug UART, "
                        "such as /dev/ttyUSB1")
    parser.add_argument("--baud", type=int, default=2000000,
                        help="the UART's baud rate (default %(default)s)")
    parser.add_argument("--bit", default=f"{REPO}/synth/r6/build/top.bit",
                        help="the bitstream to program (default "
                        "%(default)s)")
    parser.add_argument("--board", choices=["mega65", "nexys4ddr"],
                        help="default: nexys4ddr if --bit has it in its path")
    parser.add_argument("--no-program", action="store_true",
                        help="do not program the FPGA, and skip the boot "
                        "test")
    parser.add_argument("--eth", metavar="HOST[:PORT]",
                        help="test the Ethernet station too, giving it the "
                        "IP address HOST")
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
        pause = assemble(f"{REPO}/sim/pause.nasm", tmp)
        step = assemble(f"{REPO}/sim/step.nasm", tmp)
        brk, brk_at = assemble_labels(f"{REPO}/sim/break.nasm", tmp)
        step_at = assemble_labels(f"{REPO}/sim/step.nasm", tmp)
        emu = assemble(f"{REPO}/sim/emu.nasm", tmp)

        opened = False
        try:
            # Before the port is opened, as openFPGALoader takes the FTDI chip
            cable: list[str] = []
            if not args.no_program:
                if not sys.platform.startswith("linux"):
                    sys.exit("hwtest.py: programming needs Linux; program "
                             "the FPGA yourself and give --no-program")
                cable, args.port, model = check_board(args.port, args.bit)
                if not args.board:
                    board = "nexys4ddr" if model.startswith("xc7a100") \
                        else "mega65"
            link = Link(Serial(args.port, args.baud))
            opened = True
            try:
                if not args.no_program:
                    test_boot(link, args.bit, cable)
                test_link(link)
                test_framing(link)
                test_echo(link, echo)
                test_reset(link, echo)
                test_pause(link, pause)
                test_step(link, step)
                test_break(link, brk, brk_at)
                test_write_regs(link, *step_at)
                test_clear(link)
                test_ram_size(link, board)
                test_readback(link, emu)
                test_counters_stop(link)
                test_screen_registers(link)
                test_fonts(link)
                test_board_devices(link, board)
                test_sd(link, board)
                test_fetch_statistics(link)
                test_primes(link, primes, board)
            finally:
                link.close()
            serial = ["--port", args.port, "--baud", str(args.baud)]
            test_run(serial, comparisons(tmp))
            test_monitor(serial, tmp, in_rom=True, long=True)
            test_fit(serial, tmp, RAM_WORDS[board])
            test_bench(serial, bench)
            test_selftest(serial, tmp)
            if not args.eth:
                uncovered.append("the Ethernet station, without --eth")
            else:
                test_eth(args.port, args.baud, args.eth, comparisons(tmp),
                         rom_test(), tmp)
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
    for gap in uncovered:
        print(f"NOT COVERED: {gap}")
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    main()
