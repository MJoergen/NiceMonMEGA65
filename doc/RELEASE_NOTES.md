# Release notes

The releases of NiceMonMEGA65, newest first: the versions from `V1.0` on,
and the release candidates `RC02` to `RC06` before them. Each section lists
the changes since the one before that a user of the bitstreams, the boards,
or the tools can see. The git log has the full story, and
[nice_cpu's release notes](https://github.com/MJoergen/nice_cpu/blob/main/RELEASE_NOTES.md) have the changes to
the cores, the emulator, and the tools that come with the submodule.

From `V1.0` on, a release here has the name of the nice_cpu tag it pins,
and a release that leaves the submodule alone adds a third number:
`V1.0.1` and `V1.0.2` pin `V1.0` ([RELEASE.md](RELEASE.md#version-names)).
The release candidates pinned these:

| NiceMonMEGA65 | nice_cpu |
|---|---|
| `RC06` | `RC06` |
| `RC05` | `RC05` |
| `RC04` | `RC04` |
| `RC02` | `4cd869e`, a commit before nice_cpu's `RC02` |

nice_cpu's `RC01` and `RC03` have no tag here.

## V1.1 (not yet released)

**Boards**

- F1 to F12 give xterm's escape sequences, on the Nexys4DDR's keyboard
  and on the MEGA65's, which has F1, F3, and so on to F11, and the even
  keys with SHIFT. They gave nothing before.

**Demo**

- The function keys switch between the demos in the ROM, which a menu in
  the second row lists. The typewriter is F1, and runs at power-up. The
  ideas of issue #28 come next, each on a key of its own.

**Tools**

- `make flash` (`tools/flash.py`) writes a bitstream into the
  Nexys4DDR's flash, verifies it, and waits for the board to start from
  it. With jumper JP1 on QSPI, the board then starts the system at power
  on, and with the release's bitstream it shows the demo, as a MEGA65
  does with a core file in its flash.
- `mon.py` disassembles with `d ADDR N`, and shows the instruction at the
  PC after a pause, a step, and a breakpoint. The disassembler is
  nice_cpu's `assembler/nicedis.py`, which comes after nice_cpu's `V1.0`.
  With the submodule at `V1.0`, `d` says that it is missing.
- `mon.py --symbols FILE` and its `symbols FILE` command read the labels
  of `niceasm.py --symbols` and `nicebuild.py --symbols`. An address may
  then be a label, `label+N`, or `label-N`, and the output shows the
  labels.
- `make linktest` checks `mon.py`'s commands on `niceemu --link` too.
- The tools read the link's version when they connect, and stop with a
  message on a major other than 0 (nice_cpu's DEBUG.md §9). `mon.py`'s
  `status` shows the version as major.minor, and `hwtest.py` checks the
  version of the pinned nice_cpu's `debug_link.vhd`, not a fixed 4.

**Documentation**

- `SYSTEM.md`, `EMULATOR.md`, `CODING_STYLE.md`, `RELEASE.md`, and
  `RELEASE_NOTES.md` move into `doc/`. `README.md` and `CONTRIBUTING.md`
  stay at the root.

**Release**

- `make release` builds the Nexys4DDR only with `FLOW=timing`, as its
  Makefile does, and no longer tries the default flow first, which never
  meets timing there.

## V1.0 (2026-10-28)

**Upgrade notes.**

- nice_cpu `V1.0` builds `niceemu` with Zig 0.17.0, and no longer with
  0.15. The tools, `make hwtest`, and `make -C sim check-steps` need the rebuilt
  binary: `make -C nice_cpu/emulator build`.
- This is the first release with files: the three bitstreams, the two
  MEGA65 core files, and the C examples are on the GitHub Release.

**Boards**

- `make cor` builds core files for the R3 and the R6, which MEGAFLASH
  writes to a slot of the MEGA65's flash. The board then starts NiceMon
  without a JTAG cable.
- Every build writes the core's worst paths in and out of the core,
  `build/core_in.rpt` and `build/core_out.rpt`, from which nice_cpu sets
  its budget for the core's ports.

**Tools**

- `tools/mon.py` is an interactive shell on the debug link, and `make mon
  [FILE=p.bin]` runs it. It reads and writes memory, loads a `.bin` file,
  starts, holds, pauses, steps, and goes on, sets the breakpoints, and
  shows the registers and the state. It shows the program's output and
  the link's notices as they arrive, and sends console input or passes
  the terminal through to the program. It takes `--port`, `--tcp`, and
  `--cosim`, as `load.py` does.

**Documentation**

- `README.md` is now for users of the core files: the MEGA65 on its own,
  and with the serial port. The address map, the link, the screen, the
  ROM, and the Nexys4DDR's devices are in `SYSTEM.md`. The tests, the
  formal checks, `make hwtest`, and the badge are in `CONTRIBUTING.md`.

**System**

- `nicemon.vhd` is split into `mem.vhd`, `devices.vhd`, `scr_regs.vhd`,
  and `board_io.vhd`, with no change in behavior or address map.
  `kbd_ascii.vhd` is now `kbd_m65_ascii.vhd`.
- `formal/mem.sby` proves the memory by k-induction, and that a read
  returns what was written, 0 after a clear, or the ROM's word.

**Tests**

- The `.nasm` files of `sim/` are laid out in nice_cpu's columns, and
  `make test` checks the layout with nice_cpu's `nicefmt.py`.

**Demo**

- The bitstreams and the core files of the release have a demo in the
  ROM (`demo/`), so a MEGA65 with no computer on its debug UART no longer
  starts with a black screen. It shows a welcome with the version, and
  then a typewriter: what is typed on the keyboard appears on the screen,
  with RETURN, DEL, TAB, the cursor keys, CTRL-L to clear, and scrolling.
  The tools hide the ROM, and load programs as before.
- `make demo` builds it, and `make test` and CI run it in `niceemu`.

**Release**

- `make bump TAG=V1.0` moves nice_cpu to a tag, builds the R6 bitstream,
  and records the timing in `badge-mega65.json`, the badge that nice_cpu's
  README shows, and in `verified.json`.
- `make release` builds, tests, and publishes a release
  ([RELEASE.md](RELEASE.md)).
- The tags follow nice_cpu's version names, and CI takes its Zig version
  from nice_cpu's CI.

## RC06 (2026-10-27)

**Upgrade notes.**

- The debug link is version 4. `load.py` and `run.py` disable the
  breakpoints before a load, as the board keeps them until a reset, where
  `niceemu` clears them at each connection.

**Debug link and tools**

- Four breakpoints on every board, at `FFFFFFF4`–`FF`. The core pauses
  before an enabled one, and the link sends `x` with its number.
- `nicelink.py` has `set_breaks()`, and takes `x` as a pause.

**Tests**

- `tb_nicemon` stops `sim/break.nasm` at a read of memory and in an
  interrupt routine, and checks that a reset clears the breakpoints.
- `hwtest.py` has `test_break`, which runs on the board, in `make
  linktest`, and in `make cosimtest`.

**Timing**

- The R6 meets 100 MHz by 0.595 ns, and the Nexys4DDR 90 MHz by
  0.111 ns.

## RC05 (2026-10-26)

**Upgrade notes.**

- The debug UART runs at 2 Mbaud, not 115200 baud. The tools default to
  it. A bitstream from before needs `--baud 115200`.
- The debug link is version 3.

**Debug link and tools**

- Bit 4 of the control register pauses the core at a step boundary, and
  the link sends `p` (version 2). The link reaches all of the memory and
  the registers while the core is paused. The counters, the timer, and the
  fetch statistics stop. Console and keyboard bytes wait in the input
  FIFO.
- Bits 4 and 5 run one step of a paused core, and the link sends `p`
  again, or `h` if the step halted (version 3).
- Loading `primes.bin` takes 0.7 s instead of 6.9 s.
- `nicelink.py` has `PAUSE` and `step()`.

**Simulation**

- `make cosim` runs the system in GHDL with its debug UART on a TCP port,
  and the tools reach it with `--cosim PORT`.
- `make cosimtest` runs `hwtest`'s checks and programs on it against
  `niceemu`, without a board. CI runs it on both cores.

**Tests**

- `hwtest.py` has `test_pause` and `test_step`. `test_step` compares
  R0–R15 after each step with `niceemu --trace`.

**Timing**

- The R6 meets 100 MHz by 0.628 ns, and the Nexys4DDR 90 MHz by
  0.187 ns.

## RC04 (2026-10-24)

**Upgrade notes.**

- The command line on the debug UART is gone. The board speaks nice_cpu's
  debug link instead, as `niceemu --link` does, and the tools of `RC02` do
  not work with it.
- `run.py` ends at the link's halt notice, not at the halt message in the
  output. On `--timeout` it holds the core, prints the dumps, and exits
  with status 3.

**Debug link and tools**

- `tools/nicelink.py` speaks the link over the debug UART, or over TCP to
  `niceemu --link` with `--tcp PORT`. It retries a bad packet, and paces
  the input by the free space of the input FIFO.
- `run.py` takes `niceemu`'s options, including `--symbols`, and names
  where a program stopped after a halt other than `HALT`.
- `make linktest` checks the tools on `niceemu --link`, without a board.

**System**

- The microsecond counter, `TIME_LO` and `TIME_HI` at `FFFFFF44` and
  `FFFFFF45`, is exact on every board.
- The fetch statistics stop while the core is held or halted.

**Boards**

- The Nexys4DDR's 16 LEDs, two RGB LEDs, seven-segment display, five
  buttons, and 16 switches are registers at `FFFFFF90`–`96`. On the
  MEGA65, the block reads 0, as in the emulator.
- DEL with CTRL held stays DEL on the PS/2 keyboard, as on the MEGA65.
- A failed Vivado build fails `make`.

**Tests**

- `tb_board_io` checks the Nexys4DDR's drivers, and `tb_ps2_nicemon` the
  PS/2 keyboard into the core's input. Keys typed while the input is full
  are lost on the Nexys4DDR, as a PS/2 keyboard cannot wait.
- CI runs on Ubuntu 24.04, with both cores and the examples.

## RC02 (2026-10-23)

The first release candidate here. It holds:

- **The system**, `src/nicemon.vhd`: nice_cpu's pipelined core, or its
  multi-cycle core with `NICE=multi`, with RAM, a ROM at address 0,
  nice_cpu's devices, and an input FIFO fed by the debug UART and the
  keyboard.
- **Three boards**: the MEGA65 R3 and R6 at 100 MHz, and the Digilent
  Nexys4DDR at 90 MHz with a PS/2 keyboard.
- **A text display** on VGA and HDMI, with QNICE's screen registers at
  `FFFFFF80`, a cursor, and 12-bit RGB colors.
- **A command line** on the debug UART at 115200 baud, and the host tools
  `load.py`, `run.py`, and `hwtest.py`. `run.py` runs a program as
  `niceemu` does, for diffing, and `make hwtest` tests a board, with
  nice_cpu's benchmark.
- **Tests**: GHDL testbenches of the system, the keyboard, and the
  display, formal checks of the command line, the input FIFO, and the
  buses, and `vsg` lint, all in CI.
- **[EMULATOR.md](EMULATOR.md)**, the known differences from the emulator.
