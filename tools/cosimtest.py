#!/usr/bin/env python3
"""Compare tools/run.py on the simulated system with niceemu, without a
board.

It starts "make -C sim cosim", the RTL in GHDL with its debug UART on a
free port of 127.0.0.1. On it, it runs hwtest.py's checks of bad
packets, except the one of a gap between two bytes, as a gap in real
time is far shorter in simulated time, and its checks of the pause, the
step, the breakpoints, and the writes of the registers, against niceemu
--link. Then it runs the programs of hwtest.py's comparison with run.py
--cosim on that port and with niceemu alone, and the monitor's test
program, with run.py --monitor and with the monitor's l. Each must print
the same and exit with the same status. The monitor's cold start must set
the clock of the time of day from the model of the real-time clock on
the I2C bus of the simulated system (#105). Last, load.py must refuse a word
beyond the simulated system's 64K words of RAM. So it checks the RTL,
boardlink.py, run.py, and load.py as hwtest.py does on the board. The
simulation runs far slower than real time, so the waits are longer, and
nice_cpu's benchmark and the demo's self-test are left out. NICE=multi
in the environment picks the multi-cycle core, as for make test. It
prints one line for each check, and last how many passed, and exits with
status 1 when one fails. niceemu must be built first, with make -C
nice_cpu/emulator build. Only the Python standard library is used.
"""

import argparse
import calendar
import os
import re
import signal
import subprocess
import sys
import tempfile

import hwtest
from hwtest import (NICEEMU, REPO, assemble, assemble_labels, comparisons,
                    results, test_fit, test_framing, test_monitor, test_pause,
                    test_run, test_step, test_break, test_watch,
                    test_write_regs)
from boardlink import HOLD, RAM, open_link

# The time of the model of the RV-3032-C7 in sim/cosim/tb_cosim.vhd, as
# the clock counts local time: seconds since 1970 as if it were UTC
RTC_TIME = calendar.timegm((2026, 11, 11, 12, 34, 56)) + 0.5


def test_rtc(port: str, tmp: str) -> None:
    """The clock from the real-time clock: the I2C master is present, and
    with "set" cleared, the monitor's cold start in test_monitor sets the
    clock to the model's time, which the simulation has run on from for
    no more than a minute."""
    args = argparse.Namespace(cosim=int(port), tcp=None)
    link = open_link(args)
    try:
        link.control(HOLD | RAM)
        status = hwtest.rd(link, hwtest.I2C_STATUS)
        hwtest.check("I2C master present, idle", status == 1, f"{status:08X}")
        hwtest.check("W CLOCK_STATUS clears set",
                     hwtest.wr(link, hwtest.CLOCK_STATUS, 0) and
                     hwtest.rd(link, hwtest.CLOCK_STATUS) == 0)
    finally:
        link.close()
    test_monitor(["--cosim", port], tmp)
    link = open_link(args)
    try:
        link.control(HOLD | RAM)
        ok = hwtest.rd(link, hwtest.CLOCK_STATUS) == 1
        clock = hwtest.read_clock(link)
        hwtest.check("clock set from the real-time clock at the cold start",
                     ok and 0 <= clock - RTC_TIME < 60,
                     f"{clock - RTC_TIME:+.3f} s from the model's time")
    finally:
        link.close()


def main() -> None:
    argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    ).parse_args()
    if not os.path.exists(NICEEMU):
        sys.exit(f"cosimtest.py: {NICEEMU} is missing; run "
                 "'make -C nice_cpu/emulator build'")
    hwtest.QUIET = 5.0
    hwtest.RUN_TIMEOUT = 600.0
    with tempfile.TemporaryDirectory() as tmp:
        log_path = os.path.join(tmp, "cosim.log")
        with open(log_path, "wb") as log:
            # A session of its own, so that make, GHDL, and the simulation
            # stop together.
            sim = subprocess.Popen(["make", "-s", "-C", f"{REPO}/sim",
                                    "cosim", "COSIM_PORT=0"], stdout=subprocess.PIPE,
                                   stderr=log, start_new_session=True)
        try:
            assert sim.stdout is not None
            port = None
            for raw in sim.stdout:
                line = raw.decode(errors="replace")
                m = re.match(r"cosim: port (\d+)", line)
                if m:
                    port = m.group(1)
                    break
            if port is None:
                with open(log_path, errors="replace") as f:
                    sys.exit(f"cosimtest.py: make -C sim cosim printed no "
                             f"port:\n{f.read()}")
            # Its stdout is read away, so that the pipe never fills.
            drain = subprocess.Popen(["cat"], stdin=sim.stdout,
                                     stdout=subprocess.DEVNULL)
            link = open_link(argparse.Namespace(cosim=int(port), tcp=None))
            try:
                link.control(HOLD | RAM)
                test_framing(link, gap=False)
                test_pause(link, assemble(f"{REPO}/sim/pause.nasm", tmp))
                test_step(link, assemble(f"{REPO}/sim/step.nasm", tmp))
                brk = assemble_labels(f"{REPO}/sim/break.nasm", tmp)
                test_break(link, *brk)
                test_watch(link, *brk)
                test_write_regs(link, *assemble_labels(
                    f"{REPO}/sim/step.nasm", tmp))
            finally:
                link.close()
            test_run(["--cosim", port], comparisons(tmp))
            test_rtc(port, tmp)
            # The simulated system has nicemon's default RAM, 64K words
            test_fit(["--cosim", port], tmp, 0x10000)
        finally:
            os.killpg(sim.pid, signal.SIGTERM)
            sim.wait()
        drain.wait()
    passed = sum(results)
    print(f"\n{passed}/{len(results)} passed")
    if hwtest.skipped:
        print(f"SKIPPED: {', '.join(hwtest.skipped)}")
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    main()
