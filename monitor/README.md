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
  are, with nice_cpu's `start_mon.nasm`, `start_wasm_mon.nasm`, or
  `start_wasm_trap_mon.nasm` in place of its start-up files at 0
  (`nice_cpu/runtime/ABI.md`, "Programs under a monitor"), and
  `nicebuild.py --monitor` builds a C, Zig, or Rust program so. They
  return to the monitor instead of halting: when `main` returns, through
  `exit`, or with `RET` on the SP of the entry.
- The monitor runs a program as a subroutine on its own stack: it pushes
  a return address and jumps to `0x8000` with E = 0, R1 = the address of
  `mon_putc`'s entry, and R2 = 0 and R3 = 0, `argc` and `argv` for a
  command line later. The start-up code stores R1 in `___putc_vector`, so
  `nice_putc`, `nice_print`, the C library's `printf`, and the trap report
  print through `mon_putc`. At the return the monitor relies on SP and
  R1, the status, and on nothing else. It clears E, stops the timer, and
  sets VBASE back to 0 itself, so a program may own the interrupts, with
  a vector table in its own image.
- A program may use the RAM from `0x8000` up to, but not including, the
  SP it was called with, and must leave room below that for the stack it
  shares with the monitor. The monitor's variables are at `0xFFFFF000`
  and up, as the demo's are, and its stack grows down from there, so
  programs have `0x8000`–`0xEFFF`, 28K words, for their image and their
  stack. The monitor's routines use at most 32 words of the stack when a
  program calls them.
- A program runs once per load: the load initializes its static data and
  its wasm linear memory. A wasm trap halts the core, as in nice_cpu,
  after the trap report's line on the monitor's output; the on-board
  debugger then has the state, and the reset button boots the monitor
  again.
- The monitor's routines are called through a dispatch table at the start
  of the ROM, as QMON's `getc!` and `putc!` are, so that programs need
  not be reassembled when the monitor changes. The table is below.
- In `niceemu`, which has no ROM, the monitor is a program at 0 like any
  other, and `cat monitor.bin prog.bin` runs it with a program at
  `0x8000`, for a `.bin` file is address and word pairs. Its keystrokes
  come from an input file. nice_cpu's own tests use a stand-in for the
  monitor, `nice_cpu/runtime/test/monitor.nasm`, which shows what the
  monitor does to run a program.

## The dispatch table

Each entry is one `MOVE PC, routine`, two words, so entry n is at address
2n, and entry 0 is the reset. A program calls entry n as it calls any
routine, `ADD @--SP, 2, PC` then `MOVE PC, 2n`, through names that
`mon.nasm` gives: an `.EQU` for each entry, and a stub for each, such as
`_mon_putc  MOVE PC, 0x06`. Entries are only ever added at the end, never
moved or removed, so a program built for one monitor runs on every later
one.

An entry is added only when a program cannot do without it: it reaches
hardware that the monitor owns or that differs between boards, or state
that the monitor keeps, such as the cursor and the outputs. The SD card's
routines are the kind that will come later. Strings, memory, number
formatting, line editing, and random numbers are not the HAL's: assembly
programs join a file of such routines in NICE assembly, which the
monitor's own commands use too, and C programs have nice_cpu's `libc`.
The ROM's routines could not serve C anyway, for a C string is bytes
packed four to a word in wasm's linear memory
(`nice_cpu/translator/WASM.md`), and libc must run in `niceemu`, which
has no ROM.

The routines follow the C ABI of `nice_cpu/runtime/ABI.md`, not QMON's
registers from R8 up: arguments in R1–R4, the result in R1, and R7–R13
kept. A C program for the monitor declares them in `mon.h`, and is joined
with the stubs of `mon.nasm` (`nicebuild.py --monitor --asm mon.nasm`),
as the translator makes a call to the `env` import `mon_putc` a call to
`_mon_putc`. Such a program runs only with the ROM visible, as every
program built at `0x8000` for the monitor does.

VBASE is 0 at reset and stays 0. The monitor has no interrupts of its
own, as the debugger is hardware and the board has no NMI source, and it
keeps E at 0, so the vector table that would overlap the dispatch table
is never read. A program that wants interrupts sets VBASE to a page of
its own image, and the monitor clears E, stops the timer, and sets VBASE
back to 0 at every return.

| # | Addr | Name | Arguments → result | QMON |
|---|---|---|---|---|
| 0 | `00` | `mon_reset` | Cold start: stack, variables, screen, banner, main loop. | `reset!` |
| 1 | `02` | `mon_exit` | R1 a status. Back to the main loop with a fresh stack, for a program that has not kept the SP of its entry; a program with the runtime's start-up code returns or calls `exit` instead. | `exit!` |
| 2 | `04` | `mon_version` | → R1 the version of the table, major in bits 31..16, minor in 15..0. | — |
| 3 | `06` | `mon_putc` | R1 a character, to the outputs `mon_out` selects. On the screen it goes at the cursor, which moves on; CR moves the cursor to column 0, LF to column 0 of the next row, and BS one back; the last row scrolls the screen by the display offset. On the line every byte goes as it is. | `putc!` |
| 4 | `08` | `mon_out` | R1 the outputs: bit 0 the line, bit 1 the screen; both at reset. → R1 the old ones. | — |
| 5 | `0A` | `scr_cls` | Clears the screen in the current color, cursor home, display offset 0. | `vga_cls!` |
| 6 | `0C` | `scr_moveto` | R1 the column, R2 the row. | `vga_moveto!` |
| 7 | `0E` | `scr_getxy` | → R1 the column, R2 the row. | `vga_getxy!` |
| 8 | `10` | `scr_color` | R1 the color for later characters, bits 31..8 of a screen word. → R1 the old one. | — |

Three entries of the first draft went on 2026-10-30, by the table's own
rule ([#24](https://github.com/MJoergen/NiceMonMEGA65/issues/24), the
comments of that day): `mon_getc` and `mon_getc_nb`, as the console at
`0xFFFFFF00` is the same on every board and in the emulator, with the
line and the keyboard merged by the hardware, and nice_cpu's `nice_getc`
and `nice_pollc` read it; and `mon_setvec`, as the monitor keeps no
vector table. `mon_out` stayed, one routine and one piece of state in
place of a `scr_putc` and a `ser_putc`: the line is the console, which
any program can write, and the screen's memory is the same everywhere,
so what the HAL adds is the terminal, the cursor, the scrolling, and the
copy to the line.

What QMON's table has that this one leaves out:

- `getc!`: see above.
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

## Input and output

- Output goes to the line (Ethernet or the UART) and to the screen, as
  `mon_out` selects, both at reset; input comes from the line and the
  keyboard, which the hardware already merges into the console at
  `0xFFFFFF00`. A read returns 0 while no byte has arrived, so the monitor
  polls, which works in the emulator too, where a read waits.
- A break on the UART, or a host's half-close over Ethernet, ends the
  line's input and not the keyboard's (nice_cpu's SYSTEM.md §5): the
  host's bytes are dropped until the core is started again, a read
  returns `0x200` once the FIFO is empty, and the keyboard's bytes still
  come. So the monitor reads on, and a program that reads until `0x200`
  ends with the host's input. A new connection over Ethernet does not
  yet start the line anew, as `niceemu --link` does at a new connection
  (nice_cpu's DEBUG.md §7): the link in nice_cpu drops the host's bytes
  until the next start, and needs a port for it, an issue there. Until
  then, the next host cannot type to a monitor that one host has left.
- The screen is memory at `0xFFFF0000`, one word per character with its
  color, so `mon_putc` writes the words directly where QMON writes a
  register. The hardware has what QMON's VGA library needs for the rest: a
  cursor, and a display offset over 32768 words for scrolling back, in
  registers numbered as QNICE-FPGA's VGA registers (`0xFFFFFF80` for
  `0xFF30`, and so on; see
  [SYSTEM.md](../doc/SYSTEM.md#the-screen)). The screen is cleared by a loop
  over its words.

## Not decided yet

- The main loop's commands. At least one to run the program at `0x8000`,
  and one to give the board its IP address, which the demo's F11 does
  today. Debugging is the on-board debugger's.
- How a program reaches `0x8000` on a board with no storage: over the
  link, which holds the core, writes the image, and starts it, after
  which the monitor boots cold and a host types the run command on the
  console; or which pauses the running monitor, writes the image, goes
  on, and types the command. Either way the cold start must leave the
  RAM from `0x8000` alone, and `load.py` and `run.py` need an option that
  keeps the ROM visible, loads at `0x8000`, and sends the command, with
  the same command in the input file of `niceemu`.
- The scrollback on the Nexys4DDR, whose screen is 8192 words where the
  MEGA65's is 32768, with one `monitor.bin` for every board and no
  register that tells the size.
- The demo's place once the monitor is in the ROM of the release:
  `release.py` puts the demo there, and `demo_hw.py` checks it.

## What QMON has that this port will not

- The SD card, FAT32, and `qtransfer` code, about half of QMON, has no
  hardware here.
- The disassembler needs writing anew for the NICE instruction set, in
  NICE assembly; nice_cpu's `assembler/nicedis.py`, which `mon.py` uses,
  is the model.
- The monitor's build is the `cat` of its files and one run of
  `nice_cpu/assembler/niceasm.py`, for the assembler has no `#include` or
  `#ifdef`; the sysdef constants become a `.nasm` file of `.EQU` lines.
