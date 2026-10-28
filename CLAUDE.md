# CLAUDE.md

NiceMonMEGA65 runs the NICE CPU (the `nice_cpu` submodule) on the MEGA65 R3
and R6 boards, the main target; the Digilent Nexys4DDR also builds, with
UART, VGA, a PS/2 keyboard, and its LEDs, seven-segment display, buttons,
and switches as registers. It has nice_cpu's debug link
(`nice_cpu/doc/DEBUG.md`, `hdl/src/debug_link.vhd`) on the debug UART, a
text display on VGA and HDMI, a ROM at address 0 for a QMON-like
monitor that is planned but not written (`monitor/README.md`), and host
tools that load and run programs. The goal is that a program runs on the
board exactly as `niceemu`, the emulator in `nice_cpu/emulator`, runs it.
`README.md` is for users of the core files: on its own, and with the
serial port. `doc/SYSTEM.md` has the address map, the link, the screen,
the ROM, and the Nexys4DDR's devices; `CONTRIBUTING.md` the tests, the
formal checks, `make hwtest`, and the badge; `doc/EMULATOR.md` the known
differences from the emulator. `doc/` also has `CODING_STYLE.md`,
`RELEASE.md`, and `RELEASE_NOTES.md`; the root keeps only `README.md`,
`CONTRIBUTING.md`, and this file.
`src/nicemon.vhd` is the whole system and the file to read first; its
header is the authoritative address map.

## Commands

    make                  # lists the targets
    make -j test          # GHDL: synth checks, tb_hello, tb_nicemon, tb_kbd, tb_ps2, tb_ps2_nicemon, tb_text, tb_board_io, check-steps, check-fmt (NICE=multi for the multi-cycle core); then the demo in niceemu
    make -j formal        # SymbiYosys jobs in formal/, each task in a work directory of its own
    make lint             # vsg against doc/CODING_STYLE.md; line-length warnings are tolerated
    make examples         # C examples -> examples/build/*.bin (clang wasm32, lld, llvm)
    make demo             # the ROM's demo -> demo/build/demo.bin; make -C demo test runs it in niceemu
    make r6 [ROM=f.bin]   # Vivado bitstream, synth/r6/build/top.bit; make r3 and make nexys4ddr likewise
    make cor [ROM=f.bin]  # MEGA65 core files for MEGAFLASH, synth/r{3,6}/build/NiceMonMEGA65-r{3,6}.cor (coretool)
    make load FILE=p.bin  # load and start a program on the board (debug UART, PORT=/dev/ttyUSB1)
    make run FILE=p.bin   # run it and print what niceemu prints, for diffing
    make mon [FILE=p.bin] # interactive shell on the link: memory, pause, step, breakpoints
    make bump TAG=V1.0    # nice_cpu to the tag, R6 bitstream, badge-mega65.json and verified.json, committed (--push with ARGS)
    make release TAG=V1.0 # after the bump: gates, three bitstreams, two .cor, hwtest, staged; ARGS=--publish tags and releases (doc/RELEASE.md); TAG=V1.0.1 keeps nice_cpu at V1.0
    make hwtest           # check the FPGA, program it with openFPGALoader, and test the board
    make linktest         # run.py --tcp on niceemu --link against plain niceemu, no board
    make cosim            # the RTL in GHDL, its debug UART on TCP, for the tools' --cosim PORT
    make cosimtest        # run.py --cosim on make cosim against plain niceemu, no board (minutes)

One testbench: `make -C sim tb_kbd` (likewise `tb_hello`, `tb_nicemon`,
`tb_ps2`, `tb_text`, `tb_board_io`, `synth-nicemon`, ...). `make -C sim
check-steps` compares the step counts that `tb_nicemon` checks with
niceemu's. By hand: `make -C sim analyze` then, in
`sim/build/pipeline`, `ghdl --elab-run --std=08 --workdir=. tb_kbd`;
`tb_nicemon` and `tb_hello` take `-gG_*_FILE=` generics as `sim/Makefile`
shows, and `tb_text` with `-gG_PPM_FILE=frame.ppm` writes the frame as a
picture. Test programs are assembled with `python3
nice_cpu/assembler/niceasm.py -o x.bin x.nasm` and run with
`nice_cpu/emulator/zig-out/bin/niceemu x.bin`. CI
(`.github/workflows/ci.yml`, on Ubuntu 24.04) builds niceemu and runs
`make -C sim -j4 test` and `make cosimtest` on both cores, `make examples`,
`make -C demo test`, `make linktest`, `make -j4 formal`, and `make lint`.

## Layout

- `src/`: the system (`nicemon.vhd`), its memory (`mem.vhd`, with
  `ram.vhd` and `rom.vhd`), the UART (`uart_serdes.vhd`, from cmod-s7),
  which carries the link,
  the core's input FIFO (`rx_fifo.vhd`), nice_cpu's devices at
  `FFFFFF10`–`7F` (`devices.vhd`), the board's registers at
  `FFFFFF90`–`9F` (`board_io.vhd`) and the screen's at `FFFFFF80`–`8F`
  (`scr_regs.vhd`), the keyboards (`kbd_m65.vhd` and
  `kbd_m65_ascii.vhd` for the MEGA65, `kbd_ps2.vhd` and `kbd_ps2_ascii.vhd` for
  the Nexys4DDR's PS/2), the Nexys4DDR's display and RGB LED drivers
  (`seg7.vhd`, `rgb_pwm.vhd`), and `system.vhd`, which every board
  instantiates.
  `nice_core.vhd` with one architecture from `src/core/` wraps whichever
  nice_cpu core `core.mk` selects (`NICE=pipeline`, the default, or `multi`).
- `src/video/`: `text.vhd` shows the screen with a cursor and a display
  offset; `scr_ram.vhd` is its dual-clock copy; `font_pkg.vhd` is generated
  by `font/gen_font_pkg.py`.
- `synth/`: `Makefile.inc` is the Vivado build, `common/` the clocks,
  `mega65/` what the R3 and R6 share (keyboard, DAC, HDMI), `r3/`, `r6/`,
  and `nexys4ddr/` the boards. See `synth/README.md`, and
  `.claude/rules/synth.md` when working there.
- `sim/`: the GHDL testbenches and their `.nasm` programs; `sim/cosim/` is
  the system with its UART on TCP (`tb_cosim.vhd`, `cosim.c`). `formal/`: the
  SymbiYosys wrappers; the checks themselves are `G_FORMAL` blocks in the
  sources. `tools/`: `nicelink.py` (the link, on the UART, or over TCP to
  `niceemu --link` or `make cosim`), `load.py`, `run.py`, `mon.py`, `hwtest.py`,
  `bump.py`, `release.py`, `linktest.py`, `cosimtest.py`. `examples/`: C programs built through
  nice_cpu's wasm translator. `demo/`: the welcome screen and typewriter
  in NICE assembly that the release puts in the ROM (`release.py`), and
  `demo_hw.py`, which checks it in the ROM of a programmed board.

## Rules and pitfalls

- Behavior starts in nice_cpu: its `doc/ISA.md` for the CPU, its
  `doc/SYSTEM.md` (not this repository's) for the devices, the emulator for the rest. This repository follows them,
  never the reverse. The submodule has its own `CLAUDE.md` and tests.
- Tags follow nice_cpu's (doc/RELEASE.md): `V1.0` here pins nice_cpu's
  `V1.0`, and `V1.0.1`, `V1.0.2`, and so on are releases that keep the
  submodule. The submodule pins only nice_cpu tags. `RC02` and `RC04` to
  `RC06` came before. CI takes its Zig version from nice_cpu's own CI.
  A release's notes start with its dated section of `doc/RELEASE_NOTES.md`.
- After a submodule bump: `make -C nice_cpu/emulator build` (the tools and
  `hwtest` use `nice_cpu/emulator/zig-out/bin/niceemu`, and a stale binary
  checks old behavior), `make -j test`, a look at the "Compared with the
  emulator" table, and a new bitstream, as the core's timing margin at
  100 MHz is small.
- A bitstream with a ROM boots from it. The tools hide it with bit 3 of the
  control register (a link write of `0000000D` to `FFFFFFF0` to hold,
  clear, and hide, then `00000008` to run), so a program loads at 0 as in
  the emulator.
- While the core runs, the link reaches only its debug registers at
  `FFFFFFE0`–`FF`, and the link reads the console and the read counter as
  0. A hold of a running core leaves R0–R15 undefined. Bit 4 pauses the
  core (link version 2): the link sends `p`, and reaches everything while
  paused, with R0–R15 defined and the counters stopped. Bits 4 and 5 step
  a paused core (version 3): one step, then `p` again, or `h`. Version 4
  has `G_BREAKS` breakpoints, 4 on every board, at `FFFFFFF4`–`FF`: the
  core pauses on its own before one, and the link sends `x` instead of
  `p`.
- The tools take `--tcp PORT` for `niceemu --link PORT` (PORT 0 prints the
  port it picked on stderr). `make linktest` runs `run.py --tcp` against
  plain `niceemu`, which checks the tools without a board.
- The tools take `--cosim PORT` for `make cosim`, the RTL in GHDL at
  about 250 UART bytes a second. That connection is a UART line: no `b`
  notice, and a half-close is a break. hwtest.py's `QUIET` and
  `RUN_TIMEOUT` and nicelink's `COSIM_WAIT` are the waits it needs.
- American spelling everywhere, in comments, documentation, and identifiers
  (color, analyze, synchronize, behavior). The third-party files that are
  copied unchanged keep theirs, and so do the names they define, such as
  the entity `serialiser_10to1_selectio`.
- Every README, `doc/SYSTEM.md`, and `CONTRIBUTING.md` is kept in step with
  the code it describes, in plain short sentences with the Oxford comma.
  Commit messages follow the 50/72 style: the subject is a short sentence
  of at most 50 characters, and the body, after a blank line, has lines
  of at most 72 characters and says what was wrong and what changed.
- VHDL follows `doc/CODING_STYLE.md` (3-space indent, `_i`/`_o` ports, `C_`/`G_`
  names, `synthesis`/`simulation` architectures, long headers with THEORY OF
  OPERATION and RESET). `synth/r3/max10.vhd` and `synth/mega65/hdmi/` are
  third-party, unlinted, and copied unchanged.
- A dual-clock memory must be an entity of its own, or Vivado makes LUTRAM
  of it; grep the Vivado log for `Synth 8-6849` after changing one.
- Every registered board pin carries `IOB TRUE` in the board's XDC, with a
  plain register in front of the pin and no logic between them.
- `tb_nicemon` uses small sizes (RAM 4K, ROM 2K, screen 2K words, FIFO 16
  bytes) and a fast UART, so addresses and limits there differ from the board.
- `.bin` files are text, one `address word` hex pair per line (ISA.md §10.4).
