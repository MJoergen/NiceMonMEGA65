#!/usr/bin/env python3
"""Test the system on the MEGA65 board through its debug UART.

Programs the FPGA with m65 and checks the reset notice of the debug link,
and the ROM when the bitstream has one, then drives the link with the ROM
hidden: it reads and writes memory, loads and runs sim/echo.nasm, which it
reads from while it runs, holds and restarts the core, clears the memory,
reads back what sim/emu.nasm leaves after its halt, writes and reads the
screen's registers, pauses, steps, and stops sim/debug.nasm at breakpoints
and watchpoints and reads its trace, and runs the C example
examples/build/primes.bin. Last, it runs programs with tools/run.py and
with niceemu, and compares their output and exit status, with sim/eof.nasm
also the end of the input and an input file of 1536 bytes, every byte value
six times. The programs run with the ROM hidden, so the RAM is at 0.
Build the bitstream and the example first, and niceemu
(make -C nice_cpu/emulator build), or that comparison is skipped.

Usage: tools/hwtest.py [--port /dev/ttyUSB1] [--baud 2000000]
                       [--bit synth/r6/build/top.bit] [--no-program]

--no-program skips m65 and the reset notice, for a board that is already
programmed. Only the Python standard library is used, and m65 from
mega65-tools when the FPGA is programmed.
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import nicelink as nl                                    # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NICEEMU = f"{REPO}/nice_cpu/emulator/zig-out/bin/niceemu"

results: list[bool] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    results.append(ok)
    print(f"[{'PASS' if ok else 'FAIL'}] {name} {detail}", flush=True)


def drain(link: nl.Link, quiet: float = 0.5) -> bytes:
    """The console output until nothing has arrived for quiet seconds."""
    while link.pump(quiet):
        pass
    return link.console()


def load(link: nl.Link, path: str) -> int:
    """Clears the memory, writes the words of a .bin file, and starts the
    core."""
    image = nl.read_bin(path)
    link.load(image)
    link.start()
    return len(image)


def stop_is(link: nl.Link, want: int, name: str, timeout: float = 2.0) -> None:
    why = link.wait_stop(timeout)
    check(name, why == want,
          "no stop notice" if why is None else f"stop reason 0x{why:02x}")


def assemble(src: str, out_dir: str) -> str:
    out = os.path.join(out_dir, os.path.basename(src).replace(".nasm", ".bin"))
    subprocess.run([sys.executable, f"{REPO}/nice_cpu/assembler/niceasm.py",
                    "-o", out, src], check=True)
    return out


def test_reset_notice(link: nl.Link, bit: str) -> None:
    r = subprocess.run(["m65", "-q", bit], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"hwtest.py: m65 failed:\n{r.stdout}{r.stderr}")
    time.sleep(1.0)
    out = drain(link, 1.0)
    check("reset notice after configuration", link.resets > 0, repr(out))
    ctl = link.control()
    # Without a ROM the core is held and the ROM bit reads 1; with one the
    # core has booted from it and must have halted.
    check("core held at power-up, or halted after booting from the ROM",
          ctl in (0x9, 0x2),
          f"{ctl:08X}: {'held, no ROM' if ctl == 0x9 else 'halted, ROM shown' if ctl == 0x2 else 'unexpected'}")
    if ctl == 0x2:
        # The ROM is shown: its first word is the program's, and a write to
        # it is dropped.
        first = link.read1(0)
        check("ROM at address 0", first != 0, f"{first:08X}")
        link.write1(0, 0x12345678)
        check("write to the ROM dropped", link.read1(0) == first)


def test_link(link: nl.Link) -> None:
    link.hold()
    check("hide the ROM", link.control() == 0x9)
    link.write1(0x100, 0xDEADBEEF)
    check("W then R", link.read1(0x100) == 0xDEADBEEF)
    words = [(i * 0x01010101) & 0xFFFFFFFF for i in range(1000)]
    link.write(0x1000, words)
    check("W then R of 1000 words", link.read(0x1000, 1000) == words)
    check("P reads one word again and again",
          link.read(0x1001, 3, same=True) == [words[1]] * 3)
    info = link.read1(nl.INFO)
    check("info: protocol 1, 4 breakpoints, 1024 steps, 64K words",
          info == 0x0010A401, f"{info:08X}")


def test_echo(link: nl.Link, echo: str) -> None:
    load(link, echo)
    link.send_console(b"Hello, MEGA65!")
    got = drain(link)
    check("echo while running", got == b"Hello, MEGA65!", repr(got))
    # Bytes with bit 7 set, 0xFF among them. The core echoes far faster
    # than they arrive, so its input FIFO does not fill up.
    high = bytes(range(0x80, 0x100))
    link.send_console(high)
    got = drain(link)
    bad = [f"{s:02X}->{g:02X}" for s, g in zip(high, got) if s != g]
    check("echo of bytes 0x80 to 0xFF", got == high,
          f"{len(got)} of {len(high)} bytes back, {len(bad)} wrong: "
          f"{' '.join(bad[:8])}" if got != high else "")
    # While the core runs, the link reads and writes.
    link.write1(0x100, 0x12345678)
    check("the link reads while the core runs", link.read1(0x100) == 0x12345678)
    link.send_console(b".")
    got = drain(link)
    check("echo halts on '.'", got == b".", repr(got))
    stop_is(link, 0x81, "stop notice for HALT")
    ctl = link.control()
    check("halted flag", ctl == 0xA, f"{ctl:08X}")


def test_reset(link: nl.Link, echo: str) -> None:
    link.hold()
    ctl = link.control()
    check("held, halted flag cleared", ctl == 0x9, f"{ctl:08X}")
    load(link, echo)
    link.send_console(b"again.")
    got = drain(link)
    check("core runs again after reset", got == b"again.", repr(got))
    stop_is(link, 0x81, "stop notice again")


def test_clear(link: nl.Link) -> None:
    link.write1(0x100, 0xDEADBEEF)
    link.hold(clear=True)
    ctl = link.control()
    check("held after the clear", ctl == 0x9, f"{ctl:08X}")
    got = link.read1(0x100)
    check("memory cleared", got == 0, f"{got:08X}")


def test_readback(link: nl.Link, emu: str) -> None:
    load(link, emu)
    stop_is(link, 0x81, "emu.nasm halts")
    ctl = link.control()
    check("emu.nasm halted", ctl == 0xA, f"{ctl:08X}")
    expected = {
        0xFFFFFFF1: 0x00000001,  # halted by HALT
        0xFFFFFF42: 0x0000000C,  # 12 steps, as niceemu says
        0xFFFF0000: 0x00000041,  # the screen, column 0 of row 0
        0xFFFF07CF: 0x00000042,  # the screen, column 79 of row 24
        0xFFFFFF02: 0x00001234,  # memory in the I/O range
        0x00000110: 0x00001234,
        0x00000111: 0x00000002,  # the read counter
        0xFFFFFF01: 0x00000003,
        0xFFFFFFE5: 0x0000CAFE,  # R5
    }
    for addr, want in expected.items():
        got = link.read1(addr)
        check(f"readback {addr:08X}", got == want, f"got {got:08X}, want {want:08X}")
    print("  R0-R15:", " ".join(f"{r:08X}" for r in link.regs()))


def test_screen_registers(link: nl.Link) -> None:
    """Writes the screen's registers and reads them back. On the display the
    cursor shows at the bottom right, and the screen is scrolled one row."""
    for addr, value in [(0xFFFFFF50, 0x460), (0xFFFFFF51, 0x4F),
                        (0xFFFFFF52, 0x18), (0xFFFFFF55, 0x50)]:
        link.write1(addr, value)
        got = link.read1(addr)
        check(f"readback {addr:08X}", got == value, f"got {got:08X}, want {value:08X}")
    got = link.read1(0xFFFFFF53)
    check("FFFFFF53 is not a register", got == 0, f"{got:08X}")
    link.write1(0xFFFFFF55, 0)


def test_run_control(link: nl.Link, debug: str) -> None:
    """sim/debug.nasm: a loop of the instructions at 2, 4, 6, and 8, which
    counts in R1, reads WATCH at 0x101, and writes COUNT at 0x100."""
    link.load(nl.read_bin(debug))
    link.start(paused=True)
    stop_is(link, 0x01, "paused before the first instruction")
    check("R15 is 0", link.read1(nl.REGS + 15) == 0)
    link.step(3)
    stop_is(link, 0x02, "three steps")
    check("R15 is 6 after them", link.read1(nl.REGS + 15) == 6)
    link.set_breakpoint(0, 2, nl.EXEC)
    link.go()
    stop_is(link, 0x10, "breakpoint 0")
    r1 = link.read1(nl.REGS + 1)
    link.go()
    stop_is(link, 0x10, "breakpoint 0, after one more round")
    check("one more round", link.read1(nl.REGS + 1) == r1 + 1)
    link.set_breakpoint(0, 0, 0)
    link.set_breakpoint(1, 0x100, nl.WRITE)
    link.go()
    stop_is(link, 0x31, "watchpoint 1 for a write")
    check("after the write", link.read1(nl.REGS + 15) == 8)
    link.set_breakpoint(1, 0, 0)
    steps = link.trace()
    check("the trace", [a for a, _, _ in steps] == [0, 2, 4, 6, 8, 2, 4, 6, 8, 2, 4, 6],
          " ".join(f"{a:x}" for a, _, _ in steps))
    link.go()
    time.sleep(0.2)
    check("runs again", not link.stopped())
    link.pause()
    stop_is(link, 0x01, "paused while running")
    link.hold()


def test_primes(link: nl.Link, primes: str) -> None:
    start = time.monotonic()
    n = load(link, primes)
    print(f"  loaded {n} words in {time.monotonic() - start:.1f} s")
    prompt = drain(link, 1.0)
    check("primes prompt", b"Count the primes up to" in prompt, repr(prompt))
    for limit, count in [(1000, 168), (10000, 1229), (20000, 2262)]:
        link.send_console(f"{limit}\r".encode())
        out = drain(link, 3.0).decode(errors="replace")
        check(f"primes up to {limit}",
              f"Primes up to {limit}: {count}" in out, repr(out))
    link.send_console(b"0\r")
    drain(link, 1.0)
    stop_is(link, 0x81, "primes halts on 0")
    ctl = link.control()
    check("primes halted", ctl == 0xA, f"{ctl:08X}")


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


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", default=nl.PORT)
    parser.add_argument("--baud", type=int, default=nl.BAUD)
    parser.add_argument("--bit", default=f"{REPO}/synth/r6/build/top.bit")
    parser.add_argument("--no-program", action="store_true",
                        help="do not program the FPGA, and skip the reset notice")
    args = parser.parse_args()

    primes = f"{REPO}/examples/build/primes.bin"
    if not os.path.exists(primes):
        sys.exit(f"hwtest.py: {primes} is missing; run 'make examples'")
    if not args.no_program and not os.path.exists(args.bit):
        sys.exit(f"hwtest.py: {args.bit} is missing; build it, or give --bit")

    with tempfile.TemporaryDirectory() as tmp:
        echo = assemble(f"{REPO}/sim/echo.nasm", tmp)
        emu = assemble(f"{REPO}/sim/emu.nasm", tmp)
        debug = assemble(f"{REPO}/sim/debug.nasm", tmp)
        hello = assemble(f"{REPO}/nice_cpu/doc/intro/examples/hello.nasm", tmp)
        reserved = assemble(f"{REPO}/nice_cpu/emulator/test/reserved.nasm",
                            tmp)
        eof = assemble(f"{REPO}/sim/eof.nasm", tmp)
        # Every byte value, six times over: 1536 bytes, far more than the
        # 16-byte FIFO of the testbench holds
        text = os.path.join(tmp, "input.bin")
        with open(text, "wb") as f:
            f.write(bytes(range(256)) * 6)

        link = nl.Link.open(args.port, args.baud)
        try:
            if not args.no_program:
                test_reset_notice(link, args.bit)
            else:
                link.sync()
            test_link(link)
            test_echo(link, echo)
            test_reset(link, echo)
            test_clear(link)
            test_readback(link, emu)
            test_screen_registers(link)
            test_run_control(link, debug)
            test_primes(link, primes)
        except nl.LinkError as e:
            check("the link answers", False, str(e))
        link.close()
        test_run(args.port, args.baud, [
            (hello, [], False),
            (emu, ["-d", "0x110:2", "-d", "0xFFFFFF00:4", "-s"], False),
            (reserved, [], False),
            (eof, [], True),               # no input: it ends at once
            (eof, ["-i", text], True),
        ])

    passed = sum(results)
    print(f"\n{passed}/{len(results)} passed")
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    main()
