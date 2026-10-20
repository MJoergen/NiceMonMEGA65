# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

NiceMonMEGA65 runs the NICE CPU (the `nice_cpu` git submodule) on the MEGA65 R3 and R6 boards, with a debug link on the debug UART (a binary protocol, `PROTOCOL.md`), a text display on VGA and HDMI, and the monitor on the host, `tools/nicemon.py` (see `monitor/README.md` for why it is not in a ROM). The goal is that a program runs on the board exactly as `niceemu`, the emulator in `nice_cpu/emulator`, runs it; the README's table "Compared with the emulator" lists the known differences.

## Commands

    make                  # lists the targets
    make test             # (NICE=multi for the multi-cycle core) GHDL: synth checks, tb_hello,
                          # tb_nicemon, tb_kbd, tb_text (~3 min); and tools/test_nicedis.py
    make -j4 formal       # SymbiYosys jobs in formal/ (~4 min with -j4)
    make lint             # vsg against CODING_STYLE.md; line-length warnings are tolerated
    make examples         # C examples -> examples/build/*.bin (clang wasm32, lld, llvm)
    make r6 [ROM=f.bin]   # Vivado bitstream, synth/r6/build/top.bit; make r3 likewise
    make mon [FILE=p.bin] # the monitor, tools/nicemon.py, on the board (/dev/ttyUSB1, 2 Mbaud)
    make load FILE=p.bin  # load and start a program on the board
    make run FILE=p.bin   # run it and print what niceemu prints, for diffing
    make hwtest           # program the FPGA with m65 and test the board (needs the board)
    make cosim            # the system in GHDL on the pty sim/build/nicemon.pty, for the
                          # tools with --port sim/build/nicemon.pty --wait 1000

One testbench: `make -C sim analyse` then, in `sim/build/pipeline`,
`ghdl --elab-run --std=08 --workdir=. tb_kbd`; `tb_nicemon` and `tb_hello` take
`-gG_*_FILE=` generics as `sim/Makefile` shows. `tb_text` with
`-gG_PPM_FILE=frame.ppm` writes the frame as a picture. Test programs are
assembled with `python3 nice_cpu/assembler/niceasm.py -o x.bin x.nasm` and
run in the emulator with `nice_cpu/emulator/zig-out/bin/niceemu x.bin`
(build it with `make -C nice_cpu/emulator build`). The submodule has its own
CLAUDE.md, tests, and `doc/ISA.md`, which is authoritative for the CPU.

CI (`.github/workflows/ci.yml`) runs `make -C sim test`, `tools/test_nicedis.py`,
`make -j4 formal`, and `make lint`. The formal checks live in `G_FORMAL`
blocks of `link.vhd`, `rx_fifo.vhd`, and `nicemon.vhd`, with wrappers in
`formal/`; a change to those files, or to `run_ctl.vhd`, which the system's
job builds, should keep `make formal` passing. The system's job cannot reach
a link request in its depth, so the link has its own job, `link.sby`.

## Architecture

`src/nicemon.vhd` is the whole system and the file to read first; its header
holds the address map. The core (`nice_cpu/hdl/src/pipeline.vhd`, or `multicycle.vhd` with `NICE=multi`; `core.mk` picks the sources, and `src/nice_core.vhd` with one architecture from `src/core/` is the entity `nicemon.vhd` instantiates) has a
64-bit instruction bus on port A of the RAM, which reads an aligned pair of
words (the RAM, ROM, and screen keep even and odd words in two banks), and
a 32-bit data bus on port B, which it shares with the debug link (`link.vhd`,
a second Wishbone master). Everything at `0xFFFFFF00`–`FF` is the I/O page: the console, the read counter, nice_cpu's
math unit, performance counters and timer, the screen's registers, and the
link-only registers (`E0`–`EF` the core's registers, `F0` control, `F1` halt
reason, `F2`–`FF` run control, trace, and breakpoints of `run_ctl.vhd`). Words of that page that are not registers are memory, as in the
emulator.

Memory is layered as in QNICE-FPGA: 64K words of RAM repeat through the
address space; a ROM (`rom.vhd`, 32K words from a `.bin` given at synthesis
with `ROM=`) sits in front of the RAM at `0x0000`–`0x7FFF`, writes to it are
dropped, and the core boots from it at reset. Control bit 3 hides the ROM so
the RAM is at 0 as in the emulator; `tools/nicelink.py`, which the tools use,
and `sim/tb_nicemon.vhd` always set it (`0xD` to `0xFFFFFFF0` to hold, clear,
and hide; `0x8` to run). A program in the ROM must keep its stack above
`0x8000`; `sim/rom.nasm` is the test ROM, and `hello.nasm` with its stack at
`0x1000` loops forever on the board.

The UART carries the core's console and the link's packets at once: `0xFF`
starts a packet, and `0xFF 0xFF` is the console byte `0xFF`. When the core
halts or pauses, the link sends a stop notice after its last console byte,
and the tools wait for that. `run_ctl.vhd` pauses the core by stalling its
next instruction fetch (`freeze` on `ibus_stall_i`), and masks the IRQ
meanwhile. The keyboard (`kbd_m65.vhd`, `kbd_ascii.vhd`) feeds the same input
path as the UART. The math unit, counters, and timer are reset each time the
core starts, so step counts match the emulator's.

The screen is 32K words at `0xFFFF0000`, memory of its own in `nicemon.vhd`,
and every write is also sent to `src/video/text.vhd`, which keeps a copy in
`scr_ram.vhd` (a dual-clock block RAM) and shows 80x25 characters from the
display offset with a hardware cursor; the registers at `0xFFFFFF50`–`55` are
numbered as QNICE's VGA registers and cross to the pixel clock through a
handshake inside `text.vhd`. `synth/common/mega65.vhd` is the shared board
level (clocks, keyboard, video DAC, HDMI); `synth/r3/top.vhd` and
`synth/r6/top.vhd` only differ in pins and the reset path.

## Conventions and pitfalls

- VHDL follows `CODING_STYLE.md` (3-space indent, `_i`/`_o` ports, `C_`/`G_`
  names, `synthesis`/`simulation` architectures, long headers with THEORY OF
  OPERATION and RESET). `synth/r3/max10.vhd` and `synth/common/hdmi/` are
  third-party, unlinted, and copied unchanged.
- A dual-clock memory must be an entity of its own, or Vivado makes LUTRAM of
  it; grep the Vivado log for `Synth 8-6849` after changing one.
- `tb_nicemon` uses small sizes (RAM 4K, ROM 2K, screen 2K words, FIFO 16
  bytes, trace 16 steps) and a fast UART, so addresses and limits there
  differ from the board. Its `command("R ADDR", "WORD")` and
  `command("W ADDR DATA")` send the link's binary requests.
- The cosim (`sim/cosim/`) loads `libpty.so` through VHPIDIRECT and runs
  some 30,000 cycles a second, so the tools need `--wait 1000` there, and a
  memory clear takes seconds. It is the way to try tool changes without a
  board.
- The tools import each other from `tools/`; Python may keep a stale
  `tools/__pycache__` when a file changes twice in a second.
- `.bin` files are text, one `address word` hex pair per line (ISA.md §10.4).
- Behaviour that the emulator defines starts in nice_cpu's `doc/ISA.md`;
  this repository follows it, never the reverse.
- READMEs are written in plain short sentences with the Oxford comma, and
  every README is kept in step with the code it describes. Commit subjects
  are a short sentence; the body says what was wrong and what changed.
