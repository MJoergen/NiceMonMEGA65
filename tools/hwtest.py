#!/usr/bin/env python3
"""Test the system on the MEGA65 or Nexys4DDR board through its debug UART.

First it finds the JTAG cable on the same USB device as the serial port,
reads the FPGA's IDCODE through it, and stops unless the FPGA is the part
the bitstream was built for. It then programs the FPGA through that cable
alone, so with several boards attached it programs the board whose UART it
tests. openFPGALoader does both, for the MEGA65 and the Nexys4DDR alike.
It checks the banner, and the ROM when the bitstream has one, then drives
the command line with the ROM hidden: it
loads and runs sim/echo.nasm, holds and restarts the core, clears
the memory, reads back what sim/emu.nasm leaves after its halt, checks that
the cycle counter and the timer stop there, writes and reads the screen's
registers, and runs the C example
examples/build/primes.bin. Last, it runs programs with tools/run.py and
with niceemu, and compares their output and exit status, with sim/eof.nasm
also the end of the input and an input file of 1536 bytes, with
sim/halttext.nasm a program that prints the halt message itself, and with
nice_cpu's benchmark, examples/build/bench.bin, all but its cycles. The programs
run with the ROM hidden, so the RAM is at 0; a bitstream with a ROM must
have halted its core, as a ROM with sim/rom.nasm does, for the command
line to answer.
Build the bitstream and the examples first, and niceemu
(make -C nice_cpu/emulator build), or that comparison is skipped.

Usage: tools/hwtest.py [--port /dev/ttyUSB1] [--baud 115200]
                       [--bit synth/r6/build/top.bit]
                       [--no-program]

--no-program skips programming and the banner check, for a board that is
already programmed and whose core is held or has halted. Only the Python
standard library is used, and openFPGALoader when the FPGA is programmed.
Programming needs Linux, as the JTAG cable is found through /sys; with
--no-program the script runs wherever load.py does.

A check that leaves a program running stops the run, as every later check
would fail. Whatever happens, the script ends by halting a program that is
still running and holding the core with the ROM hidden, so a following
--no-program run starts from the state it expects, and it prints the
summary.
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile
import termios
import time

from load import (HALT_MESSAGE, drain, load_words, open_port, read_bin,
                  read_until, start)

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONTROL = "FFFFFFF0"
NICEEMU = f"{REPO}/nice_cpu/emulator/zig-out/bin/niceemu"

results: list[bool] = []


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
    """Halts a program that may still be running and holds the core with the
    ROM hidden, as --no-program expects. The echo program halts on '.', and
    primes.bin on 0 after a prompt. Nothing here may fail the script."""
    try:
        fd = open_port(port, baud)
        try:
            os.write(fd, b"\r.\r0\r")
            drain(fd, 0.5)
            cmd(fd, f"W {CONTROL} 00000009")
        finally:
            os.close(fd)
    except (OSError, termios.error, SystemExit):
        print("  could not hold the core; press the reset button before a "
              "run with --no-program", flush=True)


def cmd(fd: int, line: str, quiet: float = 0.5) -> str:
    """Sends one command line and returns all that it answers."""
    os.write(fd, line.encode("ascii") + b"\r")
    return drain(fd, quiet).decode(errors="replace").strip()


def load(fd: int, path: str) -> int:
    """Clears the memory, writes the words of a .bin file, and starts the
    core."""
    words = read_bin(path)
    load_words(fd, words)
    start(fd)
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


def test_banner(fd: int, bit: str, cable: list[str]) -> None:
    r = subprocess.run(["openFPGALoader"] + cable + [bit],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"hwtest.py: openFPGALoader failed:\n{r.stdout}{r.stderr}")
    time.sleep(1.0)
    out = drain(fd, 1.0)
    check("banner after configuration", b"NICE" in out, repr(out))
    ctl = cmd(fd, f"R {CONTROL}")
    # Without a ROM the core is held and the ROM bit reads 1; with one the
    # core has booted from it and must have halted.
    check("core held at power-up, or halted after booting from the ROM",
          ctl in ("00000009", "00000002"),
          f"{ctl}: {'held, no ROM' if ctl == '00000009' else 'halted, ROM shown' if ctl == '00000002' else 'unexpected'}")
    if ctl == "00000002":
        # The ROM is shown: its first word is the program's, and a write to
        # it is dropped.
        first = cmd(fd, "R 00000000")
        check("ROM at address 0", first not in ("", "00000000"), first)
        check("write to the ROM dropped", cmd(fd, "W 00000000 12345678") == "OK"
              and cmd(fd, "R 00000000") == first)


def test_command_line(fd: int) -> None:
    require("hide the ROM", cmd(fd, f"W {CONTROL} 00000009") == "OK")
    check("R reads 8 hex digits", len(cmd(fd, "R 00000000")) == 8)
    check("W then R", cmd(fd, "W 00000100 DEADBEEF") == "OK"
          and cmd(fd, "R 00000100") == "DEADBEEF")


def test_echo(fd: int, echo: str) -> None:
    load(fd, echo)
    os.write(fd, b"Hello, MEGA65!")
    got = drain(fd)
    check("echo while running", got == b"Hello, MEGA65!", repr(got))
    # Bytes with bit 7 set. The core echoes far faster than they arrive, so
    # its input FIFO does not fill up.
    high = bytes(range(0x80, 0x100))
    os.write(fd, high)
    got = drain(fd)
    bad = [f"{s:02X}->{g:02X}" for s, g in zip(high, got) if s != g]
    check("echo of bytes 0x80 to 0xFF", got == high,
          f"{len(got)} of {len(high)} bytes back, {len(bad)} wrong: "
          f"{' '.join(bad[:8])}" if got != high else "")
    # While the core runs, a command is echoed and not answered.
    os.write(fd, b"R 00000000\r")
    got = drain(fd)
    check("UART belongs to the running core", got == b"R 00000000\r", repr(got))
    os.write(fd, b".")
    got = drain(fd)
    require("echo halts on '.', with the halt message",
            got == b"." + HALT_MESSAGE, repr(got))
    ctl = cmd(fd, f"R {CONTROL}")
    check("halted flag", ctl == "0000000A", ctl)
    check("command line back after halt", cmd(fd, "W 00000100 12345678") == "OK"
          and cmd(fd, "R 00000100") == "12345678")


def test_reset(fd: int, echo: str) -> None:
    check("hold the core", cmd(fd, f"W {CONTROL} 00000009") == "OK")
    ctl = cmd(fd, f"R {CONTROL}")
    check("held, halted flag cleared", ctl == "00000009", ctl)
    load(fd, echo)
    os.write(fd, b"again.")
    got = drain(fd)
    require("core runs again after reset", got == b"again." + HALT_MESSAGE,
            repr(got))


def test_clear(fd: int) -> None:
    check("W before the clear", cmd(fd, "W 00000100 DEADBEEF") == "OK")
    check("clear the memory", cmd(fd, f"W {CONTROL} 0000000D") == "OK")
    ctl = cmd(fd, f"R {CONTROL}")
    check("held after the clear", ctl == "00000009", ctl)
    got = cmd(fd, "R 00000100")
    check("memory cleared", got == "00000000", got)


def steps(path: str) -> str:
    """The steps niceemu counts for the program, as the R command prints."""
    r = subprocess.run([NICEEMU, path], stdin=subprocess.DEVNULL,
                       capture_output=True, check=True)
    m = re.search(rb" after (\d+) steps", r.stdout)
    if not m:
        raise SystemExit(f"hwtest: no step count in niceemu's output for {path}")
    return f"{int(m.group(1)):08X}"


def test_readback(fd: int, emu: str) -> None:
    load(fd, emu)
    halt = read_until(fd, HALT_MESSAGE)
    require("halt message", halt == HALT_MESSAGE, repr(halt))
    ctl = cmd(fd, f"R {CONTROL}")
    check("emu.nasm halted", ctl == "0000000A", ctl)
    expected = {
        "FFFFFFF1": "00000001",  # halted by HALT
        "FFFFFF42": steps(emu),  # as niceemu says
        "FFFF0000": "00000041",  # the screen, column 0 of row 0
        "FFFF07CF": "00000042",  # the screen, column 79 of row 24
        "FFFFFF02": "00001234",  # memory in the I/O range
        "00000110": "00001234",
        "00000111": "00000002",  # the read counter
        "FFFFFF01": "00000003",
        "FFFFFFE5": "0000CAFE",  # R5
    }
    for addr, want in expected.items():
        got = cmd(fd, f"R {addr}")
        check(f"readback {addr}", got == want, f"got {got}, want {want}")
    regs = [cmd(fd, f"R FFFFFFE{i:X}") for i in range(16)]
    print("  R0-R15:", " ".join(regs))


def test_counters_stop(fd: int) -> None:
    """After a halt the cycle counter and the timer's COUNT do not change."""
    first = cmd(fd, "R FFFFFF40")
    time.sleep(0.5)
    check("cycle counter stops at a halt", cmd(fd, "R FFFFFF40") == first,
          first)
    check("W TIMER_PERIOD", cmd(fd, "W FFFFFF10 00FFFFFF") == "OK")
    count = cmd(fd, "R FFFFFF11")
    time.sleep(0.5)
    check("timer COUNT stops at a halt",
          count != "00000000" and cmd(fd, "R FFFFFF11") == count, count)


def test_screen_registers(fd: int) -> None:
    """Writes the screen's registers and reads them back. On the display the
    cursor shows at the bottom right, and the screen is scrolled one row."""
    for addr, value in [("FFFFFF80", "00000460"), ("FFFFFF81", "0000004F"),
                        ("FFFFFF82", "00000018"), ("FFFFFF85", "00000050")]:
        check(f"W {addr}", cmd(fd, f"W {addr} {value}") == "OK")
        got = cmd(fd, f"R {addr}")
        check(f"readback {addr}", got == value, f"got {got}, want {value}")
    got = cmd(fd, "R FFFFFF83")
    check("FFFFFF83 is not a register", got == "00000000", got)
    check("the display offset off again", cmd(fd, "W FFFFFF85 00000000") == "OK")


def test_fetch_statistics(fd: int) -> None:
    """Checks the control word of the fetch statistics at FFFFFF50 and that
    FFFFFF5D, a word they leave at 0, reads 0."""
    check("FS_CTRL runs", cmd(fd, "R FFFFFF50") == "00000001")
    check("FS_CTRL stops", cmd(fd, "W FFFFFF50 00000000") == "OK" and
          cmd(fd, "R FFFFFF50") == "00000000")
    check("FS_CTRL clears and runs", cmd(fd, "W FFFFFF50 00000003") == "OK" and
          cmd(fd, "R FFFFFF50") == "00000001")
    check("FFFFFF5D reads 0", cmd(fd, "R FFFFFF5D") == "00000000")


def test_primes(fd: int, primes: str) -> None:
    start = time.monotonic()
    n = load(fd, primes)
    print(f"  loaded {n} words in {time.monotonic() - start:.1f} s")
    prompt = drain(fd, 1.0)
    check("primes prompt", b"Count the primes up to" in prompt, repr(prompt))
    for limit, count in [(1000, 168), (10000, 1229), (20000, 2262)]:
        os.write(fd, f"{limit}\r".encode())
        out = drain(fd, 3.0).decode(errors="replace")
        check(f"primes up to {limit}",
              f"Primes up to {limit}: {count}" in out, repr(out))
    os.write(fd, b"0\r")
    end = drain(fd, 1.0)
    require("primes halt message", end.endswith(HALT_MESSAGE), repr(end))
    ctl = cmd(fd, f"R {CONTROL}")
    check("primes halts on 0", ctl == "0000000A", ctl)


def test_run(port: str, baud: int,
             programs: list[tuple[str, list[str], bool]]) -> None:
    """Runs each program with run.py and with niceemu, which must print the
    same and exit with the same status. A program is (path, options,
    polls): when polls is true, the program waits for input in a loop, which
    takes more steps on the board, where a read returns 0 until a byte
    arrives, so the step counts are not compared. The port must be closed
    meanwhile."""
    if not os.path.exists(NICEEMU):
        print(f"  {NICEEMU} is missing; the comparison with the emulator "
              "is skipped")
        return
    for path, options, polls in programs:
        name = " ".join([os.path.basename(path)] +
                        [os.path.basename(o) for o in options])
        emu = subprocess.run([NICEEMU] + options + [path],
                             stdin=subprocess.DEVNULL, capture_output=True)
        board = subprocess.run([sys.executable, f"{REPO}/tools/run.py",
                                "--port", port, "--baud", str(baud),
                                "--timeout", "10"] + options + [path],
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


def test_bench(port: str, baud: int, bench: str) -> None:
    """Runs nice_cpu's benchmark with run.py and with niceemu, which must
    print the same and exit with the same status, but for the cycles, which
    the board counts in clock cycles. So the steps differ too, since
    printing other numbers takes other steps. The board's table is printed.
    The port must be closed meanwhile."""
    if not os.path.exists(NICEEMU):
        print(f"  {NICEEMU} is missing; the benchmark is skipped")
        return
    emu = subprocess.run([NICEEMU, bench], stdin=subprocess.DEVNULL,
                         capture_output=True)
    board = subprocess.run([sys.executable, f"{REPO}/tools/run.py",
                            "--port", port, "--baud", str(baud),
                            "--timeout", "10", bench],
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
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--bit", default=f"{REPO}/synth/r6/build/top.bit")
    parser.add_argument("--no-program", action="store_true",
                        help="do not program the FPGA, and skip the banner")
    args = parser.parse_args()

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
        hello = assemble(f"{REPO}/nice_cpu/doc/intro/examples/hello.nasm", tmp)
        reserved = assemble(f"{REPO}/nice_cpu/emulator/test/reserved.nasm",
                            tmp)
        eof = assemble(f"{REPO}/sim/eof.nasm", tmp)
        halttext = assemble(f"{REPO}/sim/halttext.nasm", tmp)
        # Every byte value, six times over: 1536 bytes, far more than the
        # 16-byte FIFO of the testbench holds
        text = os.path.join(tmp, "input.bin")
        with open(text, "wb") as f:
            f.write(bytes(range(256)) * 6)

        opened = False
        try:
            # Before the port is opened, as openFPGALoader takes the FTDI chip
            cable = []
            if not args.no_program:
                if not sys.platform.startswith("linux"):
                    sys.exit("hwtest.py: programming needs Linux; program "
                             "the FPGA yourself and give --no-program")
                cable = check_board(args.port, args.bit)
            fd = open_port(args.port, args.baud)
            opened = True
            try:
                if not args.no_program:
                    test_banner(fd, args.bit, cable)
                test_command_line(fd)
                test_echo(fd, echo)
                test_reset(fd, echo)
                test_clear(fd)
                test_readback(fd, emu)
                test_counters_stop(fd)
                test_screen_registers(fd)
                test_fetch_statistics(fd)
                test_primes(fd, primes)
            finally:
                os.close(fd)
            test_run(args.port, args.baud, [
                (hello, [], False),
                (emu, ["-d", "0x110:2", "-d", "0xFFFFFF00:4", "-s"], False),
                (reserved, [], False),
                (eof, [], True),               # no input: it ends at once
                (eof, ["-i", text], True),
                (halttext, [], False),         # prints the halt message itself
            ])
            test_bench(args.port, args.baud, bench)
        except SystemExit as e:
            # load.fail() and require() exit with a message; keep going to
            # the cleanup and the summary
            if e.code not in (0, None):
                print(e.code, file=sys.stderr, flush=True)
                if all(results):  # else a failed check is already counted
                    results.append(False)
        finally:
            if opened:
                cleanup(args.port, args.baud)

    passed = sum(results)
    print(f"\n{passed}/{len(results)} passed")
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    main()
