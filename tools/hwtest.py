#!/usr/bin/env python3
"""Test the system on the MEGA65 board through its debug UART.

Programs the FPGA with m65 and checks the banner, then drives the command
line: it loads and runs sim/echo.nasm, holds and restarts the core, reads
back what sim/emu.nasm leaves after its halt, and runs the C example
examples/build/primes.bin. Build the bitstream and the example first.

Usage: tools/hwtest.py [--port /dev/ttyUSB1] [--bit synth/r6/build/top.bit]
                       [--no-program]

--no-program skips m65 and the banner check, for a board that is already
programmed and whose core is held or has halted. Only the Python standard
library is used, and m65 from mega65-tools when the FPGA is programmed.
"""

import argparse
import os
import subprocess
import sys
import tempfile
import time

from load import open_port

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONTROL = "FFFFFFF0"

results: list[bool] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    results.append(ok)
    print(f"[{'PASS' if ok else 'FAIL'}] {name} {detail}", flush=True)


def drain(fd: int, quiet: float = 0.5) -> bytes:
    """Reads until nothing has arrived for quiet seconds."""
    buf = b""
    end = time.monotonic() + quiet
    while time.monotonic() < end:
        data = os.read(fd, 4096)
        if data:
            buf += data
            end = time.monotonic() + quiet
    return buf


def read_until(fd: int, tail: bytes, timeout: float = 2.0) -> bytes:
    buf = b""
    end = time.monotonic() + timeout
    while not buf.endswith(tail) and time.monotonic() < end:
        buf += os.read(fd, 1)
    return buf


def cmd(fd: int, line: str, quiet: float = 0.5) -> str:
    """Sends one command line and returns all that it answers."""
    os.write(fd, line.encode("ascii") + b"\r")
    return drain(fd, quiet).decode(errors="replace").strip()


def load(fd: int, path: str) -> int:
    """Holds the core, writes the words of a .bin file, and starts the core.
    The writes go in chunks without waiting for each OK, for speed."""
    words = [line.split() for line in open(path) if line.strip()]
    if cmd(fd, f"W {CONTROL} 00000001") != "OK":
        sys.exit("hwtest.py: the command line does not answer")
    chunk = 64
    for i in range(0, len(words), chunk):
        part = words[i:i + chunk]
        os.write(fd, b"".join(f"W {a.upper()} {d.upper()}\r".encode()
                              for a, d in part))
        got = b""
        end = time.monotonic() + 5
        while got.count(b"OK") < len(part) and time.monotonic() < end:
            got += os.read(fd, 4096)
        if got.count(b"OK") != len(part):
            sys.exit(f"hwtest.py: loading {path} failed at word {i}: "
                     f"{got[-200:]!r}")
    # The program may print as soon as it starts, so read only up to the OK.
    os.write(fd, f"W {CONTROL} 00000000\r".encode())
    if not read_until(fd, b"OK\r\n").endswith(b"OK\r\n"):
        sys.exit("hwtest.py: the core did not start")
    return len(words)


def assemble(src: str, out_dir: str) -> str:
    out = os.path.join(out_dir, os.path.basename(src).replace(".nasm", ".bin"))
    subprocess.run([sys.executable, f"{REPO}/nice_cpu/assembler/niceasm.py",
                    "-o", out, src], check=True)
    return out


def test_banner(fd: int, bit: str) -> None:
    r = subprocess.run(["m65", "-q", bit], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"hwtest.py: m65 failed:\n{r.stdout}{r.stderr}")
    time.sleep(1.0)
    out = drain(fd, 1.0)
    check("banner after configuration", b"NICE" in out, repr(out))
    ctl = cmd(fd, f"R {CONTROL}")
    check("core held at power-up", ctl == "00000001", ctl)


def test_command_line(fd: int) -> None:
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
    check("echo halts on '.'", got == b".", repr(got))
    ctl = cmd(fd, f"R {CONTROL}")
    check("halted flag", ctl == "00000002", ctl)
    check("command line back after halt", cmd(fd, "W 00000100 12345678") == "OK"
          and cmd(fd, "R 00000100") == "12345678")


def test_reset(fd: int, echo: str) -> None:
    check("hold the core", cmd(fd, f"W {CONTROL} 00000001") == "OK")
    ctl = cmd(fd, f"R {CONTROL}")
    check("held, halted flag cleared", ctl == "00000001", ctl)
    load(fd, echo)
    os.write(fd, b"again.")
    got = drain(fd)
    check("core runs again after reset", got == b"again.", repr(got))


def test_readback(fd: int, emu: str) -> None:
    load(fd, emu)
    time.sleep(0.2)
    ctl = cmd(fd, f"R {CONTROL}")
    check("emu.nasm halted", ctl == "00000002", ctl)
    expected = {
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
    drain(fd, 1.0)
    ctl = cmd(fd, f"R {CONTROL}")
    check("primes halts on 0", ctl == "00000002", ctl)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", default="/dev/ttyUSB1")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--bit", default=f"{REPO}/synth/r6/build/top.bit")
    parser.add_argument("--no-program", action="store_true",
                        help="do not program the FPGA, and skip the banner")
    args = parser.parse_args()

    primes = f"{REPO}/examples/build/primes.bin"
    if not os.path.exists(primes):
        sys.exit(f"hwtest.py: {primes} is missing; run 'make examples'")
    if not args.no_program and not os.path.exists(args.bit):
        sys.exit(f"hwtest.py: {args.bit} is missing; build it, or give --bit")

    with tempfile.TemporaryDirectory() as tmp:
        echo = assemble(f"{REPO}/sim/echo.nasm", tmp)
        emu = assemble(f"{REPO}/sim/emu.nasm", tmp)

        fd = open_port(args.port, args.baud)
        if not args.no_program:
            test_banner(fd, args.bit)
        test_command_line(fd)
        test_echo(fd, echo)
        test_reset(fd, echo)
        test_readback(fd, emu)
        test_primes(fd, primes)
        os.close(fd)

    passed = sum(results)
    print(f"\n{passed}/{len(results)} passed")
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    main()
