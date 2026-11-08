#!/usr/bin/env python3
"""Compare tools/run.py on niceemu --link with niceemu, without a board.

It starts "niceemu --link 0", which picks a free port, and runs
hwtest.py's checks of bad packets, the pause, the step, the breakpoints,
and the writes of the registers on it, and mon.py's checks of the
board's memory, which it adds to nice_cpu's debugger. Then it runs the programs of hwtest.py's
comparison, and nice_cpu's benchmark when examples/build/bench.bin is
built, with run.py --tcp on that port and with niceemu alone. Each must
print the same and exit with the same status. The demo's self-test, F11,
must pass. Last, run.py --tcp HOST:PORT runs hello on "niceemu --link
127.0.0.2:0", an address other than 127.0.0.1, as for a niceemu on
another computer. So it checks run.py, mon.py, boardlink.py, and the
link of the emulator, as CI does. It prints one line for each check, and last how many passed,
and exits with status 1 when one fails. niceemu must be built first,
with make -C nice_cpu/emulator build. Only the Python standard library
is used.
"""

import os
import subprocess
import sys
import argparse
import tempfile
import time

import hwtest
from hwtest import (NICEEMU, REPO, assemble, assemble_labels, comparisons,
                    results, test_bench, test_framing, test_pause, test_run,
                    test_monitor, test_selftest, test_step, test_break,
                    test_write_regs, check, start_emu)
from boardlink import HOLD, RAM, open_link


def mon(port: str, args: list[str],
        script: str) -> subprocess.CompletedProcess[str]:
    """mon.py --tcp PORT with args, and the commands of script on its
    stdin. niceemu refuses a new host, closing it, until it has seen the
    last one close, so a run that got no connection is tried again for a
    while."""
    end = time.monotonic() + 2
    while True:
        r = subprocess.run([sys.executable, f"{REPO}/tools/mon.py", "--tcp",
                            port] + args, input=script, capture_output=True,
                           text=True, timeout=30)
        if (r.returncode == 0 or "no b notice" not in r.stderr and
                "closed the connection" not in r.stderr or
                time.monotonic() > end):
            return r
        time.sleep(0.05)


def test_mon(port: str, prog: str, tmp: str) -> None:
    """mon.py, nice_cpu's nicedbg.py with the board's hooks: a load, and
    the board's check of the memory, which refuses a word beyond the
    MEGA65's RAM, at load and before the link opens. nice_cpu's make -C
    debugger test checks the debugger's commands."""
    high = os.path.join(tmp, "high.bin")
    with open(high, "w") as f:
        f.write("0 0\n30000 1\n")
    refused = f"{high}:2: address 00030000 is not in the RAM"
    r = mon(port, [], f"load {prog}\nload {high}\nq\n")
    check("mon: load", "loaded " in r.stdout and
          "the processor is held in reset" in r.stdout, repr(r.stdout))
    check("mon: load beyond the board's RAM", refused in r.stdout,
          repr(r.stdout))
    r = mon(port, [high], "q\n")
    check("mon: a file beyond the RAM, before the link opens",
          r.returncode == 1 and refused in r.stderr and not r.stdout,
          repr(r.stderr))


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
            test_mon(port, brk[0], tmp)
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
