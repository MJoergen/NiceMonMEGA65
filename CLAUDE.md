# CLAUDE.md

NiceMonMEGA65 runs the NICE CPU (the `nice_cpu` submodule) on the MEGA65 R3
and R6 boards, the main target; the Digilent Nexys4DDR also builds, with
UART, VGA, a PS/2 keyboard, and its LEDs, seven-segment display, buttons,
and switches as registers. It has a command line interpreter (CLI) on the debug
UART, a text display on VGA and HDMI, a ROM at address 0 for a QMON-like
monitor that is planned but not written (`monitor/README.md`), and host
tools that load and run programs. The goal is that a program runs on the
board exactly as `niceemu`, the emulator in `nice_cpu/emulator`, runs it.
`README.md` is the user documentation, with "Address map" for the registers;
`EMULATOR.md` lists the known differences from the emulator.
`src/nicemon.vhd` is the whole system and the file to read first; its
header is the authoritative address map.

## Commands

    make                  # lists the targets
    make -j test          # GHDL: synth checks, tb_hello, tb_nicemon, tb_kbd, tb_ps2, tb_text, tb_board_io, check-steps (NICE=multi for the multi-cycle core)
    make -j formal        # SymbiYosys jobs in formal/, each task in a work directory of its own
    make lint             # vsg against CODING_STYLE.md; line-length warnings are tolerated
    make examples         # C examples -> examples/build/*.bin (clang wasm32, lld, llvm)
    make r6 [ROM=f.bin]   # Vivado bitstream, synth/r6/build/top.bit; make r3 and make nexys4ddr likewise
    make load FILE=p.bin  # load and start a program on the board (debug UART, PORT=/dev/ttyUSB1)
    make run FILE=p.bin   # run it and print what niceemu prints, for diffing
    make hwtest           # check the FPGA, program it with openFPGALoader, and test the board

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
`make -C sim -j4 test` on both cores, `make examples`, `make -j4 formal`,
and `make lint`.

## Layout

- `src/`: the system (`nicemon.vhd`), its memory (`ram.vhd`, `rom.vhd`),
  the CLI (`cmd.vhd`, `line_buffer.vhd`, `uart_serdes.vhd`, from cmod-s7),
  the core's input FIFO (`rx_fifo.vhd`), the keyboards (`kbd_m65.vhd` and
  `kbd_ascii.vhd` for the MEGA65, `kbd_ps2.vhd` and `kbd_ps2_ascii.vhd` for
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
- `sim/`: the GHDL testbenches and their `.nasm` programs. `formal/`: the
  SymbiYosys wrappers; the checks themselves are `G_FORMAL` blocks in the
  sources. `tools/`: `load.py`, `run.py`, `hwtest.py`. `examples/`: C
  programs built through nice_cpu's wasm translator.

## Rules and pitfalls

- Behavior starts in nice_cpu: `doc/ISA.md` for the CPU, `doc/SYSTEM.md`
  for the devices, the emulator for the rest. This repository follows them,
  never the reverse. The submodule has its own `CLAUDE.md` and tests.
- After a submodule bump: `make -C nice_cpu/emulator build` (the tools and
  `hwtest` use `nice_cpu/emulator/zig-out/bin/niceemu`, and a stale binary
  checks old behavior), `make -j test`, a look at the "Compared with the
  emulator" table, and a new bitstream, as the core's timing margin at
  100 MHz is small.
- A bitstream with a ROM boots from it. The tools hide it with bit 3 of the
  control register (`W FFFFFFF0 0000000D` to hold, clear, and hide, then
  `00000008` to run), so a program loads at 0 as in the emulator.
- American spelling everywhere, in comments, documentation, and identifiers
  (color, analyze, synchronize, behavior). The third-party files that are
  copied unchanged keep theirs, and so do the names they define, such as
  the entity `serialiser_10to1_selectio`.
- Every README is kept in step with the code it describes, in plain short
  sentences with the Oxford comma. Commit subjects are a short sentence;
  the body says what was wrong and what changed.
- VHDL follows `CODING_STYLE.md` (3-space indent, `_i`/`_o` ports, `C_`/`G_`
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
