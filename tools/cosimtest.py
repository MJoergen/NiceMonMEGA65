#!/usr/bin/env python3
"""Compare tools/run.py on the simulated system with niceemu, without a
board.

It starts "make -C sim cosim", the RTL in GHDL with its debug UART on a
free port of 127.0.0.1. On it, it runs hwtest.py's checks of bad packets,
except the one of a gap between two bytes, as a gap in real time is far
shorter in simulated time, and its checks of the pause, the step, and the breakpoints. Then it runs
the programs of hwtest.py's comparison with run.py --cosim on that port
and with niceemu alone. Each must print the
same and exit with the same status. So it checks the RTL, nicelink.py, and
run.py as hwtest.py does on the board. The simulation runs far slower than
real time, so the waits are longer, and nice_cpu's benchmark is left out.
NICE=multi in the environment picks the multi-cycle core, as for make
test. It prints one line for each check, and last how many passed, and
exits with status 1 when one fails. niceemu must be built first, with make
-C nice_cpu/emulator build. Only the Python standard library is used.
"""

import argparse
import os
import re
import signal
import subprocess
import sys
import tempfile

import hwtest
from hwtest import (NICEEMU, REPO, assemble, assemble_labels, comparisons,
                    results, test_framing, test_pause, test_run, test_step,
                    test_break)
from nicelink import HOLD, RAM, open_link


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
                test_break(link, *assemble_labels(f"{REPO}/sim/break.nasm",
                                                  tmp))
            finally:
                link.close()
            test_run(["--cosim", port], comparisons(tmp))
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
