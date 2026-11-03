#!/usr/bin/env python3
"""Compare tools/run.py on niceemu --link with niceemu, without a board.

It starts "niceemu --link 0", which picks a free port, and runs
hwtest.py's checks of bad packets, the pause, the step, the breakpoints,
and the writes of the registers on it, and mon.py's commands, as they
are typed at its prompt. Then it runs the programs of hwtest.py's
comparison, and nice_cpu's benchmark when examples/build/bench.bin is
built, with run.py --tcp on that port and with niceemu alone. Each must
print the same and exit with the same status. The demo's self-test, F11,
must pass. Last, run.py --tcp HOST:PORT runs hello on "niceemu --link
127.0.0.2:0", an address other than 127.0.0.1, as for a niceemu on
another computer, and the parsing of --tcp [HOST:]PORT is checked first.
So it checks run.py, mon.py, nicelink.py, and the link of the emulator,
as CI does. It prints one line for each check, and last how many passed,
and exits with status 1 when one fails. niceemu must be built first,
with make -C nice_cpu/emulator build. Only the Python standard library
is used.
"""

import contextlib
import io
import os
import re
import subprocess
import sys
import argparse
import tempfile
import time
from typing import Callable

import hwtest
from hwtest import (NICEEMU, REPO, assemble, assemble_labels, comparisons,
                    results, test_bench, test_framing, test_pause, test_run,
                    test_monitor, test_selftest, test_step, test_break,
                    test_write_regs, check, start_emu, QUIET)
import mon
from mon import Monitor
from nicelink import HOLD, RAM, Link, LinkError, open_link, parse_tcp
from run import Symbols


def command(monitor: Monitor, line: str) -> str:
    """What mon.py prints for a line typed at its prompt, with print() or,
    as help does, on its stdout."""
    raw = io.BytesIO()
    out = io.TextIOWrapper(raw, write_through=True)
    stdout, monitor.stdout = monitor.stdout, out
    try:
        with contextlib.redirect_stdout(out):
            monitor.onecmd(monitor.precmd(line))
    finally:
        monitor.stdout = stdout
    return raw.getvalue().decode()


def go(monitor: Monitor, link: Link, count: Callable[[Link], int]) -> str:
    """What mon.py prints for a go, and shows between commands after it,
    until count(link) grows, which counts the notices of one kind. The
    notice may come while the go waits for its answer."""
    before = count(link)
    text = command(monitor, "go")
    end = time.monotonic() + 4 * QUIET
    while count(link) == before and time.monotonic() < end:
        link.poll(end - time.monotonic())
    raw = io.BytesIO()
    out = io.TextIOWrapper(raw, write_through=True)
    with contextlib.redirect_stdout(out):
        monitor.show(monitor.pending())
    return text + raw.getvalue().decode()


def test_mon_d(monitor: Monitor, at: dict[str, int]) -> None:
    """mon.py's d on sim/break.nasm, after its halt: the labels before
    their instructions, constants under 16 as numbers, and an instruction
    whose constant word would be at a label, which is a .DAT, with the
    next instruction at the label."""
    def line(addr: int, words: str, text: str) -> str:
        return f"{addr:08x}  {words:<35}  {text}\n"

    loop, done = at["LOOP"], at["DONE"]
    out = command(monitor, "d LOOP 2")
    check("mon: the disassembly at a label", out == "LOOP:\n" +
          line(loop, "02210230 00000001", "SUB[M] R4, R4, 0x1") +
          line(loop + 2, "b003d800 00000006", "?!Z MOVE R15, 0x6"),
          repr(out))
    # MOVE R5, with its constant word at DONE
    command(monitor, "w DONE-1 00015800")
    out = command(monitor, "d DONE-1 2")
    check("mon: no instruction spans a label", out ==
          line(done - 1, "00015800",
               ".DAT 0x00015800 ; MOVE R5, ? (cut off)") +
          "DONE:\n" + line(done, "0c000000", "HALT"), repr(out))


def test_mon(port: int, prog: str, at: dict[str, int]) -> None:
    """mon.py on sim/break.nasm, with its labels: a load, a breakpoint at
    a label and its notice, the registers, a step, set and pc, help on a
    short name, a read at label+N, a bad address, a set while halted, the
    disassembly, and the halt."""
    # niceemu refuses the new host, closing it, until it has seen the
    # last one close, so the connection is tried again for a while.
    end = time.monotonic() + 2
    while True:
        try:
            link = open_link(argparse.Namespace(tcp=port))
            break
        except LinkError:
            if time.monotonic() > end:
                raise
            time.sleep(0.05)
    monitor = Monitor(link, Symbols(prog.replace(".bin", ".sym")))
    try:
        out = command(monitor, f"load {prog}")
        check("mon: load", out.startswith("loaded "), repr(out))
        out = command(monitor, "b LOOP")
        check("mon: a breakpoint at a label",
              out == f"0: {at['LOOP']:08x} LOOP\n", repr(out))
        out = go(monitor, link, lambda l: len(l.breaks))
        check("mon: the breakpoint's notice", out.startswith(
            f"[breakpoint 0, PC={at['LOOP']:08x} LOOP"), repr(out))
        out = command(monitor, "regs")
        check("mon: the registers", "R4  00000003" in out, repr(out))
        command(monitor, "bd all")
        out = command(monitor, "s")
        check("mon: a step", re.match(r"PC=[0-9a-f]{8} LOOP\+0x", out)
              is not None, repr(out))
        out = command(monitor, "set R4 2")
        check("mon: set a register", out == "R4 00000002\n", repr(out))
        out = command(monitor, "set r0 1")
        check("mon: set R0, which takes none", out == "R0 00000000\n",
              repr(out))
        out = command(monitor, "set R16 1")
        check("mon: set a register that is not one", out ==
              "error: 'R16' is not R0 to R15, SP, SR, or PC\n", repr(out))
        out = command(monitor, "pc LOOP")
        check("mon: pc at a label", out == f"PC={at['LOOP']:08x} LOOP  "
              "SUB[M] R4, R4, 0x1\n", repr(out))
        command(monitor, "s")
        out = command(monitor, "regs")
        check("mon: a step from the PC set", "R4  00000001" in out,
              repr(out))
        out = command(monitor, "help s")
        check("mon: help on a short name", out.startswith("step (s)"),
              repr(out))
        out = command(monitor, "r TWO+1 1")
        check("mon: a read at label+N",
              out == f"{at['TWO'] + 1:08x}: 12345678\n", repr(out))
        out = command(monitor, "r NOPE")
        check("mon: a bad address", out ==
              "error: 'NOPE' is not a label or a hex number\n", repr(out))
        out = go(monitor, link, lambda l: len(l.halts))
        check("mon: the halt's notice", out.startswith("[halted: HALT, PC="),
              repr(out))
        out = command(monitor, "set R1 0")
        check("mon: set while halted", out ==
              "error: the core is not paused; 'pause' first\n", repr(out))
        test_mon_d(monitor, at)
    finally:
        monitor.stop()
        link.close()


def test_parse_tcp() -> None:
    """parse_tcp() takes PORT, HOST:PORT, and [HOST]:PORT, with the colons
    of an IPv6 host in brackets, and refuses the rest with fail(), which
    exits."""
    good: list[tuple[str | int, tuple[str, int]]] = [
        ("5000", ("127.0.0.1", 5000)), (5000, ("127.0.0.1", 5000)),
        ("127.0.0.2:5000", ("127.0.0.2", 5000)),
        ("[::1]:5000", ("::1", 5000)),
        ("[fe80::1%eth0]:1", ("fe80::1%eth0", 1))]
    for text, want in good:
        got = parse_tcp(text)
        check(f"parse_tcp({text!r})", got == want, repr(got))
    for text in ["::1:5000", "x", "", ":5000", "5000:", "1.2.3.4:70000",
                 "[::1]", "[]:5000"]:
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                got = parse_tcp(text)
            check(f"parse_tcp({text!r}) fails", False, repr(got))
        except SystemExit:
            check(f"parse_tcp({text!r}) fails", True)


def test_host(tmp: str) -> None:
    """run.py --tcp HOST:PORT on niceemu --link 127.0.0.2:0, which serves
    the link on an address other than 127.0.0.1, as a niceemu on another
    computer does. All of 127.0.0.0/8 is loopback on Linux; elsewhere the
    check is skipped."""
    if not sys.platform.startswith("linux"):
        print("  127.0.0.2 is not loopback here; --tcp HOST:PORT is skipped")
        hwtest.skipped.append("--tcp HOST:PORT")
        return
    emu, port = start_emu("127.0.0.2")
    try:
        drain = subprocess.Popen(["cat"], stdin=emu.stderr,
                                 stdout=subprocess.DEVNULL)
        hello = assemble(f"{REPO}/nice_cpu/doc/intro/examples/hello.nasm",
                         tmp)
        test_run(["--tcp", f"127.0.0.2:{port}"], [(hello, [], False)],
                 " on 127.0.0.2")
    finally:
        emu.terminate()
        emu.wait()
    drain.wait()


def main() -> None:
    argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    ).parse_args()
    if not os.path.exists(NICEEMU):
        sys.exit(f"linktest.py: {NICEEMU} is missing; run "
                 "'make -C nice_cpu/emulator build'")
    test_parse_tcp()
    emu, port = start_emu("127.0.0.1")
    try:
        tcp = ["--tcp", port]
        # niceemu prints its report of each run on stderr: read it away, so
        # that the pipe never fills.
        drain = subprocess.Popen(["cat"], stdin=emu.stderr,
                                 stdout=subprocess.DEVNULL)
        # niceemu takes one host at a time, so the link is closed before
        # run.py connects.
        link = open_link(argparse.Namespace(tcp=port))
        with tempfile.TemporaryDirectory() as tmp:
            try:
                link.control(HOLD | RAM)
                test_framing(link)
                test_pause(link, assemble(f"{REPO}/sim/pause.nasm", tmp))
                test_step(link, assemble(f"{REPO}/sim/step.nasm", tmp))
                brk = assemble_labels(f"{REPO}/sim/break.nasm", tmp)
                test_break(link, *brk)
                test_write_regs(link, *assemble_labels(
                    f"{REPO}/sim/step.nasm", tmp))
            finally:
                link.close()
            test_mon(int(port), *brk)
            test_run(tcp, comparisons(tmp))
            test_monitor(tcp, tmp)
            test_selftest(tcp, tmp)
        bench = f"{REPO}/examples/build/bench.bin"
        if os.path.exists(bench):
            test_bench(tcp, bench)
        else:
            print(f"  {bench} is missing; the benchmark is skipped")
            hwtest.skipped.append("bench.bin")
    finally:
        emu.terminate()
        emu.wait()
    drain.wait()
    with tempfile.TemporaryDirectory() as tmp:
        test_host(tmp)
    passed = sum(results)
    print(f"\n{passed}/{len(results)} passed")
    if hwtest.skipped:
        print(f"SKIPPED: {', '.join(hwtest.skipped)}")
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    main()
