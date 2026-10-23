# Release checklist

The steps to take before a release, in order. Each step is cheaper than the
ones after it, so a problem is found as early as possible. Do not go on to
the next step while one fails.

A release needs a clean working tree on `main`, and the bitstreams and the
hardware test come last because they take the longest and need the boards.

## 1. Prepare

1. `git status` is clean, and the branch is `main`, up to date with `origin`.
2. The submodule is at the nice_cpu commit you mean to release:
   `git submodule status`. If you bumped it, take the steps of the
   "After a submodule bump" pitfall in [CLAUDE.md](../CLAUDE.md): build the
   emulator, re-read the table in
   [EMULATOR.md](../EMULATOR.md), and plan on new bitstreams (step 5).
3. Build the emulator, as the tools and `hwtest` use it and a stale binary
   checks old behavior:

       make -C nice_cpu/emulator build

4. Run nice_cpu's own tests, as this repository relies on them:

       make -C nice_cpu test

## 2. Documentation

1. Every README agrees with the code: `README.md` (the address map), `EMULATOR.md`
   (the table of differences), `synth/README.md`,
   `monitor/README.md`, and the headers of `src/nicemon.vhd`. The header of
   `nicemon.vhd` is the authoritative address map.
2. The test counts and timing figures quoted in the READMEs (for example
   "all 63 pass" and "all 79 pass" in "Testing the board", and the slack in the clock
   section) are those you will measure in steps 3 to 6. Update them after
   those steps, and run `make lint` again.
3. `TODO.md` lists only what is still to do.
4. American spelling, plain short sentences, the Oxford comma.

## 3. Software checks (no hardware)

Run these on a machine with GHDL, vsg, Yosys with its GHDL plugin,
SymbiYosys, Yices, and clang. They are what CI runs, so a green CI run on
the release commit is the same evidence, but run them locally too.

1. Lint, against [CODING_STYLE.md](../CODING_STYLE.md). Line-length warnings
   are tolerated:

       make lint

2. The simulation tests, with the default pipelined core. This runs the
   synthesis checks, `tb_hello`, `tb_nicemon`, `tb_kbd`, `tb_ps2`, and
   `tb_text`, and the check of the step counts against `niceemu`. It takes
   about as long as `tb_text`, under a minute or two:

       make -j test

   Every line must say `PASS`.

3. The same with the multi-cycle core, as the board can be built with it:

       make -j NICE=multi test

4. The formal checks. Run them alone, not alongside other work, as the
   `nicemon` tasks take up to 3 minutes each:

       make -j4 formal

   If a recent SymbiYosys reports "database disk image is malformed" for a
   proof that passed, it is the known problem of `make -j formal` (see
   [CLAUDE.md](../CLAUDE.md)); run it without `-j` (`make formal`), or run the failing
   task alone as a `formal-<job>_<task>` target, and check that it passes.

5. The C examples build, as `hwtest` runs them:

       make examples

   `examples/build/primes.bin` and `examples/build/bench.bin` must exist.

6. Run a program in the emulator, to see that the tools work:

       nice_cpu/emulator/zig-out/bin/niceemu examples/build/primes.bin

## 4. CI

Push the release candidate and wait for the three CI jobs (`sim`, `lint`,
and `formal`) to pass on that exact commit. CI's pinned SymbiYosys does
not have the database problem above.

## 5. Bitstreams

Build every board that the release supports, with the default flow, from
the commit you are releasing, with the same `NICE` core as the tests used.
Each takes several minutes in Vivado.

    make r6
    make r3
    make nexys4ddr

For each board, check in `synth/<board>/build/`:

1. `timing.rpt`: all user-specified timing constraints are met (WNS and
   WHS not negative). The margin at 100 MHz is small, so note the WNS, and
   compare it with the figures in the README. If a board misses, try
   `FLOW=timing`, and say in the README which flow the figure is from.
2. `vivado.log`: `grep 'Synth 8-6849' vivado.log` finds nothing, which means
   no dual-clock memory became LUTRAM.
3. `utilization.rpt` is within the part, with no surprise against the last
   release.
4. The XDC still has `IOB TRUE` on every registered pin, and the report
   shows the registers in the IOBs.

If you will ship a ROM, build with it (`make r6 ROM=...`) and test that
bitstream too, in step 6.

## 6. Hardware test

Needs a MEGA65 (R3 and R6 if you can) and the Nexys4DDR, openFPGALoader,
Linux, and `niceemu` from step 1. Run it for each board, with the bitstream
from step 5 and its UART. With several boards attached, name the port by the
cable's serial number, as the README says, so the right board is
programmed:

    make hwtest BIT=synth/r6/build/top.bit PORT=/dev/ttyUSB1
    make hwtest BIT=synth/r3/build/top.bit PORT=/dev/ttyUSB1
    make hwtest BIT=synth/nexys4ddr/build/top.bit PORT=/dev/ttyUSB1

Every check must pass (63 on the R6, 79 on the Nexys4DDR, with the
pipelined core). `hwtest` programs the FPGA, checks the banner, runs the command line
checks, and compares `run.py` against `niceemu` for several programs, so it
fails if the board differs from the emulator. If a check leaves a program
running, the script stops there, halts the core, and prints the count; fix
the cause, then rerun.

Then check by hand what `hwtest` cannot:

1. Press the reset button with a terminal open on the UART: `NICE` is
   printed again.
2. On the MEGA65, type on the keyboard and see the text on the VGA and HDMI
   screens. On the Nexys4DDR, check the VGA screen and the PS/2 or USB
   keyboard.
3. Load and run a program from the host, and compare it with the emulator:

       make run FILE=examples/build/primes.bin

4. If the bitstream has a ROM, power-cycle the board and check that it boots
   from the ROM, then that `make load` still works (it hides the ROM).

## 7. Compare with the emulator

For the programs you care about, and at least `sim/*.nasm` and the
examples, run each on the board with `make run`, and with `niceemu`, and
diff the output. Any difference not listed in `EMULATOR.md`
is either a bug, or a line to add to that table before the release.

## 8. Release

1. Update the figures in the READMEs (step 2.2), and commit them. If this
   changes any VHDL, go back to step 3, as the bitstreams must be built from
   the released commit.
2. `git status` is clean, and CI is green on the commit to tag.
3. Tag it, and push the tag. Commit subjects are a short sentence, and the
   tag message says what changed since the last release, in particular the
   nice_cpu commit, the Vivado version, the timing slack for each board, and
   the differences from the emulator:

       git tag -a vX.Y -m "..."
       git push origin vX.Y

4. Attach the bitstreams (`top.bit` of each board), with the nice_cpu commit
   and the `NICE` and `FLOW` options they were built with, to the release.
