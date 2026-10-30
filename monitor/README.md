# monitor

The ROM at `0x0000`, which the core boots from, will hold a hardware
abstraction layer, the HAL: the few routines that reach the hardware or
the state the monitor keeps, called through a dispatch table, and, when
there is storage, a loader. It is not a library: what a program can do
for itself stays in the program. It is in NICE assembly, and planned and
not written yet
([#24](https://github.com/MJoergen/NiceMonMEGA65/issues/24)). The QNICE
monitor (QMON) of [QNICE-FPGA](https://github.com/sy2002/QNICE-FPGA) is
the inspiration, not the model: the decisions below were made for a port
of it, and #24's first task, the list of the routines, revisits them.
Debugging is the on-board debugger's
([#52](https://github.com/MJoergen/NiceMonMEGA65/issues/52),
[doc/DEBUGGER.md](../doc/DEBUGGER.md)), which needs no ROM. This
directory holds only this note.

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
  [SYSTEM.md](../doc/SYSTEM.md#the-rom)). The ROM changes only with a new
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
  of the ROM, as QMON's `getc!` and `putc!` are, so that programs need
  not be reassembled when the monitor changes. The draft of the table is
  below.

## The dispatch table (draft)

Each entry is one `MOVE PC, routine`, two words, so entry n is at address
2n, and entry 0 is the reset. A program calls entry n as it calls any
routine, `ADD @--SP, 2, PC` then `MOVE PC, 2n`, through names that a
`monitor.nasm` of `.EQU` lines gives. Entries are only ever added at the
end, never moved or removed, so a program built for one monitor runs on
every later one.

An entry is added only when a program cannot do without it: it reaches
hardware that the monitor owns or that differs between boards, or state
that the monitor keeps, such as the cursor and the vector table. The SD
card's routines are the kind that will come later. Strings, memory,
number formatting, line editing, and random numbers are not the HAL's:
assembly programs join a file of such routines in NICE assembly, which
the monitor's own commands use too, and C programs have nice_cpu's
`libc`. The ROM's routines could not serve C anyway, for a C string is
bytes packed four to a word in wasm's linear memory
(`nice_cpu/translator/WASM.md`), and libc must run in `niceemu`, which
has no ROM.

The routines follow the C ABI of `nice_cpu/runtime/ABI.md`, not QMON's
registers from R8 up: arguments in R1–R4, the result in R1, and R7–R13
kept. A C program for the monitor declares them in a `mon.h`, and is
joined with one stub per entry, such as `_mon_putc  MOVE PC, 0x0A`, as
the translator makes a call to the `env` import `mon_putc` a call to
`_mon_putc`. Such a program runs only with the ROM visible, as every
program built at `0x8000` for the monitor does.

At reset VBASE is 0, so the vector table would be the dispatch table in
the ROM, which no program can write. The cold start moves VBASE to a page
of RAM below the monitor's variables, and `mon_setvec` fills it.

| # | Addr | Name | Arguments → result | QMON |
|---|---|---|---|---|
| 0 | `00` | `mon_reset` | Cold start: VBASE, stack, variables, screen, banner, main loop. | `reset!` |
| 1 | `02` | `mon_exit` | Back to the main loop, with a fresh stack; a program may also `RET`. | `exit!` |
| 2 | `04` | `mon_version` | → R1 the version of the table, major in bits 31..16, minor in 15..0. | — |
| 3 | `06` | `mon_getc` | Waits for a byte from the line or the keyboard. → R1 the byte, or −1 at the end of the input (bit 9). | `getc!` |
| 4 | `08` | `mon_getc_nb` | As `mon_getc`, but → R1 −2 when no byte waits. | — |
| 5 | `0A` | `mon_putc` | R1 a character, to the outputs `mon_out` selects. CR, LF, and BS move the cursor; the screen scrolls. | `putc!` |
| 6 | `0C` | `mon_out` | R1 the outputs: bit 0 the line, bit 1 the screen. → R1 the old ones. | — |
| 7 | `0E` | `scr_cls` | Clears the screen in the current color, cursor home, display offset 0. | `vga_cls!` |
| 8 | `10` | `scr_moveto` | R1 the column, R2 the row. | `vga_moveto!` |
| 9 | `12` | `scr_getxy` | → R1 the column, R2 the row. | `vga_getxy!` |
| 10 | `14` | `scr_color` | R1 the color for later characters, bits 31..8 of a screen word. → R1 the old one. | — |
| 11 | `16` | `mon_setvec` | R1 a vector, R2 a routine, or 0 for the monitor's. → R1 the old one. | — |

What QMON's table has that this one leaves out:

- `puts!`, `crlf!`, `gets!`, `gets_s!`, `gets_slf!`, `puthex!`,
  `gethex!`, and `h2dstr!`: they are built on `getc!` and `putc!`, and
  go in the file of routines that programs join.
- `memset!`, `memcpy!`, `strlen!`, `strcmp!`, `strcpy!`, `strchr!`,
  `strstr!`, `chr2upper!`, `chr2lower!`, `str2upper!`, `chomp!`, and
  `split!`: likewise.
- `wait!`, `srand!`, and `rand!`: a program reads the microsecond
  counter at `0xFFFFFF44` itself, the same on every board and in the
  emulator, and libc has `clock`, `rand`, and `srand`.
- `muls!`, `mulu!`, `divu!`, `divs!`, `mulu32!`, `divu32!`,
  `in_range_u!`, and `in_range_s!`: the math unit at `0xFFFFFF20` does
  them, and a word has 32 bits.
- `shl32!` and `shr32!`: a word has 32 bits.
- `til!`: there are LEDs and a seven-segment display only on the
  Nexys4DDR, as registers.
- `enter!` and `leave!`: NICE has no register banks.
- `vga_init!`, `vga_copyfont!`, and `vga_copypal!`: the font is fixed,
  and the colors are in each screen word.
- The `sd_*!` and `f32_*!` entries: there is no SD card yet. When one
  comes, the entries it strictly needs go at the end.

Open questions:

- Whether `mon_out` is enough, or the screen and the line need
  `scr_putc` and `ser_putc` of their own, as QMON's `VGA$PUTCHAR` and
  `UART$PUTCHAR` are, outside its table.
- Whether `mon_getc` belongs in the HAL at all, as the hardware already
  merges the line and the keyboard into the console at `0xFFFFFF00`. It
  is there so that a program never reads the console itself, should the
  input change.

## Input and output

- Output goes to the line (Ethernet or the UART) and to the screen; input
  comes from the line and the keyboard, which the hardware already merges into the console at
  `0xFFFFFF00`. A read returns 0 while no byte has arrived, so the monitor
  polls, which works in the emulator too, where a read waits.
- The screen is memory at `0xFFFF0000`, one word per character with its
  color, so the VGA library writes the words directly where QMON writes a
  register. The hardware has what QMON's VGA library needs for the rest: a
  cursor, and a display offset over 32768 words for scrolling back, in
  registers numbered as QNICE-FPGA's VGA registers (`0xFFFFFF80` for
  `0xFF30`, and so on; see
  [SYSTEM.md](../doc/SYSTEM.md#the-screen)). The screen is cleared by a loop
  over its words.

## What QMON has that this port will not

- The SD card, FAT32, and `qtransfer` code, about half of QMON, has no
  hardware here.
- The disassembler needs writing anew for the NICE instruction set, in
  NICE assembly; nice_cpu's `assembler/nicedis.py`, which `mon.py` uses,
  is the model.
- The monitor's build is the `cat` of its files and one run of
  `nice_cpu/assembler/niceasm.py`, for the assembler has no `#include` or
  `#ifdef`; the sysdef constants become a `.nasm` file of `.EQU` lines.
