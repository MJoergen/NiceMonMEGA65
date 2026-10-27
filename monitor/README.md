# monitor

The monitor will be a program in the ROM that loads, runs, and inspects
programs from the MEGA65's own keyboard and screen, without a PC. It is
in NICE assembly, a port of the QNICE monitor (QMON) from
[QNICE-FPGA](https://github.com/sy2002/QNICE-FPGA), and is planned and not
written yet ([#24](https://github.com/MJoergen/NiceMonMEGA65/issues/24)).
This directory holds only this note, which records the decisions the
monitor will follow. The rule is to stay as close to QNICE as the NICE
CPU allows.

## Where it lives

- The monitor is in the ROM at `0x0000`–`0x7FFF`, as QMON is, and the core
  boots from it at reset. The RAM is above it, from `0x8000`, and the
  monitor's variables are directly below the I/O page at `0xFFFFFF00`, as
  QMON's are below `0xFF00`. The stack starts below the variables. Nothing
  of the monitor's may be written below `0x8000`: a write to the ROM is
  dropped, so a stack there loses its return addresses (`sim/rom.nasm`
  says what happens then).
- The bitstream is built with `make r6 ROM=monitor/monitor.bin` (or `r3`),
  which puts the assembled monitor in the ROM (see
  [synth/](../synth/README.md) and
  [SYSTEM.md](../SYSTEM.md#the-rom)). The ROM changes only with a new
  bitstream, so the monitor is developed in the emulator, `niceemu`, which
  runs it like any program, with its keystrokes in an input file; the
  board is for checking.
- The debug link stays. While the monitor runs, the link reaches only its
  debug registers, and a host holds the core to reach the rest, as
  `load.py` and `run.py` do. They hide the ROM too, so that a program at
  address 0 runs as in the emulator, and the reset button boots the monitor
  again.

## Programs

- Programs for the monitor are assembled at `0x8000`, as QNICE programs
  are, and return to the monitor with `RET`, or through its `exit` entry,
  instead of `HALT`, which halts the core. `nice_cpu/runtime/start*.nasm`
  will get a variant for this: another origin, the monitor's stack, and a
  return instead of a halt. That is a change in the nice_cpu submodule, and
  its software conventions in ISA.md §9.
- The monitor's routines are called through a dispatch table at the start
  of the ROM, as QMON's `getc!`, `putc!`, `puts!`, and so on, so that
  programs need not be reassembled when the monitor changes.

## Input and output

- Output goes to the UART and to the screen; input comes from the UART and
  the keyboard, which the hardware already merges into the console at
  `0xFFFFFF00`. A read returns 0 while no byte has arrived, so the monitor
  polls, which works in the emulator too, where a read waits.
- The screen is memory at `0xFFFF0000`, one word per character with its
  color, so the VGA library writes the words directly where QMON writes a
  register. The hardware has what QMON's VGA library needs for the rest: a
  cursor, and a display offset over 32768 words for scrolling back, in
  registers numbered as QNICE-FPGA's VGA registers (`0xFFFFFF80` for
  `0xFF30`, and so on; see
  [SYSTEM.md](../SYSTEM.md#the-screen)). The screen is cleared by a loop
  over its words.

## What QMON has that this port will not

- The SD card, FAT32, and `qtransfer` code, about half of QMON, has no
  hardware here.
- The disassembler needs writing anew for the NICE instruction set.
- The monitor's build is the `cat` of its files and one run of
  `nice_cpu/assembler/niceasm.py`, for the assembler has no `#include` or
  `#ifdef`; the sysdef constants become a `.nasm` file of `.EQU` lines.
