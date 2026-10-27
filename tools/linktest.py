#!/usr/bin/env python3
"""Compare tools/run.py on niceemu --link with niceemu, without a board.

It starts "niceemu --link 0", which picks a free port, and runs
hwtest.py's checks of bad packets, the pause, the step, and the
breakpoints on it. Then it runs the programs of hwtest.py's comparison,
and nice_cpu's benchmark when examples/build/bench.bin is built, with
run.py --tcp on that port and with niceemu alone. Each must print the
same and exit with the same status. So it checks run.py, nicelink.py,
and the link of the emulator, as CI does. It prints one line for each
check, and last how many passed, and exits with status 1 when one fails.
niceemu must be built first, with make -C nice_cpu/emulator build. Only
the Python standard library is used.
"""

import os
import re
import subprocess
import sys
import argparse
import tempfile

import hwtest
from hwtest import (NICEEMU, REPO, assemble, assemble_labels, comparisons,
                    results, test_bench, test_framing, test_pause, test_run,
                    test_step, test_break)
from nicelink import HOLD, RAM, open_link


def main() -> None:
    argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    ).parse_args()
    if not os.path.exists(NICEEMU):
        sys.exit(f"linktest.py: {NICEEMU} is missing; run "
                 "'make -C nice_cpu/emulator build'")
    emu = subprocess.Popen([NICEEMU, "--link", "0"], stdout=subprocess.DEVNULL,
                           stderr=subprocess.PIPE)
    try:
        assert emu.stderr is not None
        first = emu.stderr.readline().decode(errors="replace")
        m = re.search(r"link: port (\d+)", first)
        if not m:
            sys.exit(f"linktest.py: niceemu --link printed {first!r}, not "
                     "its port")
        tcp = ["--tcp", m.group(1)]
        # niceemu prints its report of each run on stderr: read it away, so
        # that the pipe never fills.
        drain = subprocess.Popen(["cat"], stdin=emu.stderr,
                                 stdout=subprocess.DEVNULL)
        # niceemu takes one host at a time, so the link is closed before
        # run.py connects.
        link = open_link(argparse.Namespace(tcp=int(m.group(1))))
        with tempfile.TemporaryDirectory() as tmp:
            try:
                link.control(HOLD | RAM)
                test_framing(link)
                test_pause(link, assemble(f"{REPO}/sim/pause.nasm", tmp))
                test_step(link, assemble(f"{REPO}/sim/step.nasm", tmp))
                test_break(link, *assemble_labels(f"{REPO}/sim/break.nasm",
                                                  tmp))
            finally:
                link.close()
            test_run(tcp, comparisons(tmp))
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
    passed = sum(results)
    print(f"\n{passed}/{len(results)} passed")
    if hwtest.skipped:
        print(f"SKIPPED: {', '.join(hwtest.skipped)}")
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    main()
