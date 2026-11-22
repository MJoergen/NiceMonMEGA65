#!/usr/bin/env python3
"""Compare nicemon.py run on niceemu --link with niceemu, without a board.

It starts "niceemu --link 0", which picks a free port, and runs
hwtest.py's checks of bad packets, the pause, the step, the breakpoints,
the writes of the registers, and the FPU on it, and mon.py's checks of
the board's memory, which it adds to nice_cpu's debugger, its help, and
its console in a pseudo-terminal, where the Enter key must run the
monitor's line. Then it runs
the programs of hwtest.py's comparison, a BASIC program's text with
run.py --bas and load.py --bas, and nice_cpu's benchmark when
examples/build/bench.bin and bench_win.bin are built, with run.py --tcp
on that port and with niceemu alone. Each must print the same and exit
with the same status. The demo's self-test, F11, must pass. Last,
run.py --tcp HOST:PORT runs hello on "niceemu --link
127.0.0.2:0", an address other than 127.0.0.1, as for a niceemu on
another computer. And with a card in niceemu's slot 0 that has
NICE/BASIC-T.ROM, BASIC's image of build/rom.bin, which niceemu alone
loads at the cold start, run.py --tcp loads build/rom.bin with "keep"
set, so that its monitor loads none; and load.py --basic refuses
niceemu, which has no ROM (issue #153). So it checks run.py, mon.py, boardlink.py, and the
link of the emulator, as CI does. It prints one line for each check, and last how many passed,
and exits with status 1 when one fails. niceemu must be built first,
with make -C nice_cpu/emulator build. Only the Python standard library
is used.
"""

import os
import pty
import re
import select
import subprocess
import sys
import argparse
import tempfile
import time

import hwtest
from hwtest import (NICEEMU, NICEMON, REPO, assemble, assemble_labels,
                    comparisons, results, test_bench, test_framing,
                    test_pause, test_run, test_monitor, test_bas,
                    test_selftest,
                    test_step, test_break, test_watch, test_write_regs,
                    test_fpu, check, start_emu)
from lib.boardlink import HOLD, RAM, open_link
# After boardlink, which puts nice_cpu's debugger/ on the path
import nicedbg


def mon(port: str, args: list[str],
        script: str) -> subprocess.CompletedProcess[str]:
    """mon.py --tcp PORT with args, and the commands of script on its
    stdin. niceemu refuses a new host, closing it, until it has seen the
    last one close, so a run that got no connection is tried again for a
    while."""
    end = time.monotonic() + 2
    while True:
        r = subprocess.run([*NICEMON, "mon", "--tcp", port] + args,
                           input=script, capture_output=True,
                           text=True, timeout=30)
        if (r.returncode == 0 or "no b notice" not in r.stderr and
                "closed the connection" not in r.stderr or
                time.monotonic() > end):
            return r
        time.sleep(0.05)


def test_mon(port: str, prog: str, tmp: str) -> None:
    """mon.py, nice_cpu's nicedbg.py with the board's hooks: a load, and
    the board's check of the memory, which refuses a word beyond the
    MEGA65's RAM, at load and before the link opens, and its help, with
    a line for each command. nice_cpu's make -C debugger test checks the
    debugger's commands."""
    high = os.path.join(tmp, "high.bin")
    with open(high, "w") as f:
        f.write("0 0\n30000 1\n")
    refused = f"{high}:2: address 00030000 is not in the RAM"
    r = mon(port, [], f"load {prog}\nload {high}\nq\n")
    check("mon: load", "loaded " in r.stdout and
          "the processor is held in reset" in r.stdout, repr(r.stdout))
    check("mon: load beyond the board's RAM", refused in r.stdout,
          repr(r.stdout))
    # help: a line for each command, which starts with the command, the
    # first one after the prompt
    r = mon(port, [], "help\nq\n")
    lines = [line.removeprefix("dbg> ") for line in r.stdout.splitlines()]
    # nicedbg's commands, in its order, without EOF, the Ctrl-D that quits
    names = [name[3:] for name in vars(nicedbg.Debugger)
             if name.startswith("do_") and name != "do_EOF"]
    missing = [name for name in names
               if not any(re.match(rf"{re.escape(name)}[ (]", line)
                          for line in lines)]
    check("mon: help has a line for each command",
          not missing and "Documented commands" not in r.stdout,
          f"missing {missing}: {r.stdout!r}")
    r = mon(port, [], "help s\nq\n")
    check("mon: help CMD describes one, also by its short name",
          "step (s) [N]: runs N steps" in r.stdout, repr(r.stdout))
    r = mon(port, [high], "q\n")
    check("mon: a file beyond the RAM, before the link opens",
          r.returncode == 1 and refused in r.stderr and not r.stdout,
          repr(r.stderr))


def read_until(fd: int, token: bytes, seconds: float) -> bytes:
    """What the pseudo-terminal fd gives until token has come, or for
    seconds."""
    text = b""
    end = time.monotonic() + seconds
    while token not in text and time.monotonic() < end:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                text += os.read(fd, 4096)
            except OSError:     # the other end has closed
                break
    return text


def test_console(port: str) -> None:
    """mon.py's console in a pseudo-terminal, which treats the keys as a
    terminal does: it makes the Enter key's CR an LF, which BASIC's line
    passes over. mon.py must send the CR, the board's RETURN, so that the
    monitor of the tests, loaded and started here, runs its line, HELP,
    and lists its statements. Ctrl-] must give the prompt back.
    As in mon(), a run that got no connection is tried again."""
    subprocess.run(["make", "-s", "-C", REPO, "build/rom_test.bin"], check=True)
    end = time.monotonic() + 2
    while True:
        master, slave = pty.openpty()
        proc = subprocess.Popen(
            [*NICEMON, "mon", "--tcp", port,
             f"{REPO}/build/rom_test.bin"],
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        text = read_until(master, b"dbg> ", 10)
        if b"dbg> " in text or time.monotonic() > end:
            break
        proc.wait()
        os.close(master)
        time.sleep(0.05)
    try:
        os.write(master, b"go\r")
        read_until(master, b"dbg> ", 5)
        os.write(master, b"console\r")
        text += read_until(master, b"Ctrl-]", 5)
        os.write(master, b"HELP\r")
        help_text = read_until(master, b"call the program", 5)
        check("mon: the console's Enter key runs BASIC's line",
              b"call the program" in help_text, repr(text[-200:] + help_text))
        read_until(master, b"\0", 0.5)   # the rest of HELP's list
        os.write(master, b"\x1d")
        back = read_until(master, b"dbg> ", 5)
        check("mon: Ctrl-] returns from the console to the prompt",
              b"dbg> " in back, repr(back[-200:]))
        os.write(master, b"q\r")
        try:
            proc.wait(5)
        except subprocess.TimeoutExpired:
            pass
    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.wait()
        os.close(master)


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


def test_keep(tmp: str) -> None:
    """The tools' "keep" (doc/BASIC_ROM.md, "The tools"): niceemu alone,
    with build/rom.bin, whose BASIC has "keep" clear, and a card with a
    BASIC*.ROM, loads the card's BASIC at the cold start; run.py --tcp
    loads the same ROM image with "keep" set, so that its monitor loads
    none. load.py --basic refuses niceemu, which has no ROM. These two
    run by the old names, tools/run.py and tools/load.py, the wrappers
    of nicemon.py run and load, which are kept for one release (issue
    #156), so that the wrappers stay tested while they exist, and run.py
    takes run's old -i, with a warning, which nicemon.py run refuses."""
    subprocess.run(["make", "-s", "-C", REPO, "build/rom.bin"], check=True)
    rom = f"{REPO}/build/rom.bin"
    card = os.path.join(tmp, "basic_card.img")
    with open(card, "wb") as f:
        f.truncate(40 * 1024 * 1024)
    subprocess.run(["mkfs.fat", "-F", "32", "-s", "1", card], check=True,
                   stdout=subprocess.DEVNULL)
    subprocess.run(["mmd", "-i", card, "::NICE"], check=True)
    subprocess.run(["mcopy", "-i", card, f"{REPO}/basic/build/basic.rom",
                    "::NICE/BASIC-T.ROM"], check=True)
    keys = os.path.join(tmp, "halt.txt")
    with open(keys, "w") as f:
        f.write("HALT\r")
    alone = subprocess.run([NICEEMU, "-i", keys, "--sd0", card, rom],
                           stdin=subprocess.DEVNULL, capture_output=True)
    ok = b"BASIC-T.ROM from card 0" in alone.stdout
    check("niceemu alone loads the card's BASIC-T.ROM", ok,
          "" if ok else repr(alone.stdout[:200]))
    emu, port = start_emu("127.0.0.1", ["--sd0", card])
    try:
        drain = subprocess.Popen(["cat"], stdin=emu.stderr,
                                 stdout=subprocess.DEVNULL)
        run = subprocess.run([sys.executable, f"{REPO}/tools/run.py",
                              "--tcp", port, "-i", keys, rom],
                             stdin=subprocess.DEVNULL, capture_output=True)
        ok = b"NiceMon " in run.stdout and b" from card " not in run.stdout
        check("run.py loads build/rom.bin with \"keep\", and the monitor "
              "loads no card's BASIC", ok,
              "" if ok else repr(run.stdout[:200]) + repr(run.stderr[-200:]))
        ok = b"run.py: warning: -i is --input of nicemon.py run" in run.stderr
        check("run.py takes -i, with a warning that names --input", ok,
              "" if ok else repr(run.stderr[-200:]))
        new = subprocess.run([*NICEMON, "run", "--tcp", port, "-i", keys,
                              rom], stdin=subprocess.DEVNULL,
                             capture_output=True, text=True)
        ok = new.returncode == 1 and "unknown option '-i'" in new.stderr
        check("nicemon.py run refuses -i, which is --input", ok,
              "" if ok else f"exit {new.returncode}: {new.stderr!r}")
        load = subprocess.run([sys.executable, f"{REPO}/tools/load.py",
                               "--tcp", port, "--basic",
                               f"{REPO}/basic/build/basic.rom"],
                              stdin=subprocess.DEVNULL, capture_output=True,
                              text=True)
        ok = load.returncode != 0 and "no ROM" in load.stderr
        check("load.py --basic refuses niceemu, which has no ROM", ok,
              "" if ok else f"exit {load.returncode}: {load.stderr!r}")
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
                test_watch(link, *brk)
                test_write_regs(link, *assemble_labels(
                    f"{REPO}/sim/step.nasm", tmp))
                test_fpu(link, *assemble_labels(
                    f"{REPO}/sim/fpusum.nasm", tmp))
            finally:
                link.close()
            test_mon(port, brk[0], tmp)
            test_console(port)
            test_run(tcp, comparisons(tmp))
            test_monitor(tcp, tmp)
            test_bas(tcp, tmp)
            test_selftest(tcp, tmp)
        for name in ("bench.bin", "bench_win.bin"):
            bench = f"{REPO}/examples/build/{name}"
            if os.path.exists(bench):
                test_bench(tcp, bench)
            else:
                print(f"  {bench} is missing; the benchmark is skipped")
                hwtest.skipped.append(name)
    finally:
        emu.terminate()
        emu.wait()
    drain.wait()
    with tempfile.TemporaryDirectory() as tmp:
        test_host(tmp)
        test_keep(tmp)
    passed = sum(results)
    print(f"\n{passed}/{len(results)} passed")
    if hwtest.skipped:
        print(f"SKIPPED: {', '.join(hwtest.skipped)}")
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    main()
