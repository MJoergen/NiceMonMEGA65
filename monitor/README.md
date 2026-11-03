# monitor

The ROM at `0x0000`, which the core boots from, holds the monitor: a
hardware abstraction layer, the HAL, of nine routines that reach the
hardware or the state the monitor keeps, called through a dispatch table
at the start of the ROM, and a main loop with a few commands. It is not a
library: what a program can do for itself stays in the program. It is in
NICE assembly. `monitor.nasm` is the ROM; `monlib.nasm` has the routines
that programs join and the monitor's commands use too; `mon.nasm` has the
stubs through which a program calls the entries, and `mon.h` their
declarations for C. `make -C monitor` builds `build/monitor.bin`, and
`make -C monitor test` runs it in `niceemu` (Building and testing below).
It was written for
[#24](https://github.com/MJoergen/NiceMonMEGA65/issues/24), and what is
finished in
[#64](https://github.com/MJoergen/NiceMonMEGA65/issues/64). Loading
from storage is the SD card's,
[#62](https://github.com/MJoergen/NiceMonMEGA65/issues/62). The QNICE
monitor (QMON) of [QNICE-FPGA](https://github.com/sy2002/QNICE-FPGA) is
the inspiration, not the model: the decisions below were made for a port
of it, and #24 revisited them. Debugging is the on-board debugger's
([#52](https://github.com/MJoergen/NiceMonMEGA65/issues/52),
[doc/DEBUGGER.md](../doc/DEBUGGER.md)), which needs no ROM.

## Where it lives

- The monitor is in the ROM at `0x0000`–`0x7FFF`, as QMON is, and the core
  boots from it at reset. The RAM is above it, from `0x8000`, and the
  monitor's variables are at `0xFFFFF000` and up, below the I/O page, as
  QMON's are below `0xFF00`. The stack grows down from `0xFFFFF000`.
  Nothing of the monitor's is written below `0x8000`: a write to the ROM
  is dropped, so a stack there loses its return addresses (`sim/rom.nasm`
  says what happens then).
- `make r6` (or `r3`, or `nexys4ddr`) puts the monitor in the ROM, with
  the demo behind it, `demo/build/rom.bin`, as the release does (The
  demo below); `make r6 ROM=monitor/build/monitor.bin` puts the monitor
  alone (see [synth/](../synth/README.md) and
  [SYSTEM.md](../doc/SYSTEM.md#the-rom)). The ROM changes only with a new
  bitstream, so the monitor is developed in the emulator, `niceemu`, which
  runs it like any program, with its keystrokes in an input file; the
  board is for checking.
- The debug link stays. While the monitor runs, the link reaches only its
  debug registers, and a host holds the core to reach the rest, as
  `load.py` and `run.py` do. They hide the ROM too, so that a program at
  address 0 runs as in the emulator, and the reset button boots the monitor
  again. With `--monitor` they keep the ROM, and run a program at
  `0x8000` under the monitor (Loading from a host below).

## The commands

At the cold start the monitor clears the screen, prints its banner,
`NiceMon` and the version, and prints a prompt, `> `, on the screen and
on the line. It reads a line from the console: the keyboard and the line,
which the hardware merges. A command is a letter, in either case, and
after `d` and `u` a hex address and a hex count, each of them optional. DEL and
backspace delete the character before the cursor, CTRL-C empties the
line, and the cursor and function keys, the other control codes, and the
bytes `0x80` to `0x9F` do nothing. RETURN runs the line.

Before the first key of a line, Page Up and Page Down scroll back
through the rows that left the top of the screen, 24 rows at a time.
On the MEGA65 they are MEGA with CRSR↑ and CRSR↓. Any other key shows
the screen again, and goes on to the line. The history has 384 rows on
the MEGA65 and 77 on the Nexys4DDR (Input and output below).

| Command | What it does |
|---|---|
| `r [ADDR]` | Runs the program at `ADDR` in hex, or at `0x8000` without it (Programs below), and prints its status when it returns: `Returned 0000002A`. A word of 0 at `ADDR` is no program, and `r` says so: `No program at 00008000`. `r 0` runs entry 0 of the dispatch table, the cold start, so it restarts the monitor and leaves the RAM from `0x8000` alone. |
| `d [ADDR] [N]` | Shows `N` words from `ADDR`, 4 to a row with the row's address first, all in hex. Without `ADDR`, the words after the last shown; without `N`, 32 words. |
| `u [ADDR] [N]` | Disassembles `N` instructions from `ADDR`, a row each: the address, the instruction's 1 to 4 words, and its text, all in hex (The disassembler below). Without `ADDR`, the instructions after the last shown; without `N`, 20. |
| `c` | Clears the screen. |
| `v` | The version of the monitor, and of the dispatch table: `NiceMon V1.2, table 1.0`. |
| `i [A.B.C.D]` | Shows the Ethernet station's IP address, `IP address 192.168.1.65`, or writes it first: four decimal numbers of 0 to 255 with dots between them, such as `i 192.168.1.65`. Anything else is no address, and `i` says so and writes nothing. It writes `0xFFFFFF9A` ([SYSTEM.md](../doc/SYSTEM.md#the-ethernet-station)), so a host connected over TCP loses its connection. In `niceemu` the register is plain memory. |
| `l` | Loads words into the RAM from lines of `ADDR WORD` in hex, as a `.bin` file has them (Loading without a host below), up to an empty line, and prints the words written and the lines skipped: `Words loaded: 600, 00008000 to 00008257`. |
| `x` | Runs the demo of the ROM, for the time being (The demo below). Without a demo in the ROM, `x` says so. |
| `h` | Halts the core, which the reset button, or a host over the link, starts again. The tests end with it. |
| `?` | Lists the commands, and the keys of the history. |

Anything else prints `Unknown command; ? lists them`. The debugger has
pause, step, and inspect, so the monitor adds only `l`, which loads a
program with no host's tools and no storage, and `u`, which reads code
with no host
([#72](https://github.com/MJoergen/NiceMonMEGA65/issues/72)); the SD
card's commands come
with [#62](https://github.com/MJoergen/NiceMonMEGA65/issues/62).

## The disassembler

`u` shows each instruction as nice_cpu's `assembler/nicedis.py` and
`mon.py` do, so the three disassemblers agree:

    > u 8000 3
    00008000 0077580f 00000002 0003d800 00008123  CALL 0x8123
    00008004 0003f680                             RET
    00008005 3c400007                             ?Z INT 7

- The text has the condition, the mnemonic with `[C]` and `[M]`, the
  SHIFT aliases, such as `SHL` and `ROR`, and the operands in the syntax
  of nice_cpu's ISA.md §10.2. Constants are in lower-case hex without
  leading zeros, and INT's vector is in decimal.
- A reserved control word, and an instruction with a field that its
  mnemonic does not use and that is not R0, are a `.DAT` of their words,
  with what they would do as a comment, as nicedis.py writes them:
  `.DAT 0x00000001 ; MOVE R0, R0 (s1: R1)`.
- `ADD @--R13, n, R15` followed by `MOVE R15, target`, where `n` is the
  number of words of the `MOVE`, is one row, `CALL target`, and
  `MOVE R15, @R13++` is `RET`: the pseudo-instructions of ISA.md §10.1,
  which `niceasm` assembles back to the same words. A condition applies
  to both instructions of a `CALL`, so the two must have the same one,
  as in `?Z CALL 0x8123`. A pair with two conditions, an `ADD` with a
  modifier, an `n` that is not the length of the `MOVE`, or a `MOVE`
  with a modifier, is two rows. nicedis.py does not show the two
  pseudo-instructions.
- An instruction of 4 words, with constants in all three fields, has a
  text longer than the 34 columns left, and goes on in the next row of
  the screen.

## Programs

- Programs for the monitor are assembled at `0x8000`, as QNICE programs
  are, with nice_cpu's `start_mon.nasm`, `start_wasm_mon.nasm`, or
  `start_wasm_trap_mon.nasm` in place of its start-up files at 0
  (`nice_cpu/runtime/ABI.md`, "Programs under a monitor"), and
  `nicebuild.py --monitor` builds a C, Zig, or Rust program so. They
  return to the monitor instead of halting: when `main` returns, through
  `exit`, or with `RET` on the SP of the entry. `test/hello.nasm` and
  `test/hello.c` are two such programs, and the Makefile shows how they
  are built.
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
  and up, as the demo's are, and its stack grows down from there. The
  RAM repeats through the address space, so those words are the top 4K
  of the RAM, and programs have `0x8000` up to them for their image and
  their stack: `0x8000`–`0x1EFFF`, 92K words, on the MEGA65, with 128K
  words of RAM, and `0x8000`–`0xEFFF`, 28K words, on the Nexys4DDR, with
  64K. A program learns the size of the RAM from `0xFFFFFF9E`
  ([SYSTEM.md](../doc/SYSTEM.md#address-map)), which reads 0 in
  `niceemu`, where it is plain memory and the memory has no limit. The
  monitor's routines use at most 32 words of the stack when a program
  calls them. The stack is in use before the program runs: `r` pushes
  its return address at the top word of the program's RAM, `0x1EFFF` or
  `0xEFFF`, and `l`'s own summary reaches 13 words below it. `l` and
  `load.py --monitor` take a word there, which is then overwritten, as
  any word in the room the stack needs is.
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
routine, `ADD @--SP, 2, PC` then `MOVE PC, 2n`, through the names that
`mon.nasm` gives: an `.EQU` for each entry, such as `MON_PUTC`, and a
stub for each, such as `_mon_putc  MOVE R15, MON_PUTC`. Entries are only
ever added at the end, never moved or removed, so a program built for one
monitor runs on every later one.

An entry is added only when a program cannot do without it: it reaches
hardware that the monitor owns or that differs between boards, or state
that the monitor keeps, such as the cursor and the outputs. The SD card's
routines are the kind that will come later. Strings, memory, number
formatting, line editing, and random numbers are not the HAL's: assembly
programs join `monlib.nasm` (The shared routines below), which the
monitor's own commands use too, and C programs have nice_cpu's `libc`.
The ROM's routines could not serve C anyway, for a C string is bytes
packed four to a word in wasm's linear memory
(`nice_cpu/translator/WASM.md`), and libc must run in `niceemu`, which
has no ROM.

The routines follow the C ABI of `nice_cpu/runtime/ABI.md`, not QMON's
registers from R8 up: arguments in R1–R4, the result in R1, R1–R6
changed, and R7–R13 kept. A C program for the monitor declares them with
`mon.h`, and is joined with the stubs of `mon.nasm`
(`nicebuild.py --monitor --asm mon.nasm`), as the translator makes a call
to the `env` import `mon_putc` a call to `_mon_putc`. For C, `mon.nasm`
also has `_scr_getx` and `_scr_gety`, as `scr_getxy` returns two values.
Such a program runs only with the ROM visible, as every program built at
`0x8000` for the monitor does.

VBASE is 0 at reset and stays 0. The monitor has no interrupts of its
own, as the debugger is hardware and the board has no NMI source, and it
keeps E at 0, so the vector table that would overlap the dispatch table
is never read. A program that wants interrupts sets VBASE to a page of
its own image, and the monitor clears E, stops the timer, and sets VBASE
back to 0 at every return.

| # | Addr | Name | Arguments → result | QMON |
|---|---|---|---|---|
| 0 | `00` | `mon_reset` | Cold start: E, the timer, and VBASE cleared, the stack, the variables, the screen, the banner, the main loop. The RAM from `0x8000` is left alone. | `reset!` |
| 1 | `02` | `mon_exit` | R1 a status. Back to the main loop with a fresh stack, with E, the timer, and VBASE cleared, and the status printed; for a program that has not kept the SP of its entry. A program with the runtime's start-up code returns or calls `exit` instead, which lands here too. | `exit!` |
| 2 | `04` | `mon_version` | → R1 the version of the table, major in bits 31..16, minor in 15..0: `0x00010000`. | — |
| 3 | `06` | `mon_putc` | R1 a character, to the outputs `mon_out` selects. On the screen it goes at the cursor, which moves on, to the next row after the last column; CR moves the cursor to column 0, LF to column 0 of the next row, BS one back, and TAB to the next multiple of 8; the other control codes and `0x7F` to `0x9F` do nothing; past the last row the rows move up by one. On the line every byte goes as it is. | `putc!` |
| 4 | `08` | `mon_out` | R1 the outputs: bit 0 the line, bit 1 the screen; both at reset. → R1 the old ones. | — |
| 5 | `0A` | `scr_cls` | Clears the screen in the current color, cursor home, shown and blinking, display offset 0. | `vga_cls!` |
| 6 | `0C` | `scr_moveto` | R1 the column, R2 the row; a column past 79 is 79, and a row past 24 is 24. | `vga_moveto!` |
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
  are in `monlib.nasm`.
- `memset!`, `memcpy!`, `strlen!`, `strcmp!`, `strcpy!`, `strchr!`,
  `strstr!`, `chr2upper!`, `chr2lower!`, `str2upper!`, `chomp!`, and
  `split!`: they go in `monlib.nasm` when a program needs them.
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

## The shared routines

`monlib.nasm` is joined after a program, with `mon.nasm`, whose stubs its
routines call, and the monitor joins it too. The routines follow the C
ABI, and their names start with `_io_`, so that they clash with nothing
in nice_cpu's runtime or C library:

| Routine | What it does |
|---|---|
| `_io_puts` | The string at R1, one character per word up to a 0 word, through `mon_putc`. |
| `_io_crlf` | CR LF, which ends a line on the screen and on the line. |
| `_io_puthex` | R1 in hex, 8 digits. |
| `_io_putdec` | R1 in decimal, unsigned, with the math unit. |
| `_io_gethex` | A hex number in the string at R1, after any blanks. → R1 the value, R2 the number of digits, 0 for none, R3 the address after them. |
| `_io_gets` | A line into the buffer at R1, up to R2 characters and a 0 word, edited as The commands says and echoed through `mon_putc`. → R1 the number of characters. `_io_gets.first` is the same, with R3 a first byte already read, for the monitor's own line. |
| `_io_getc` | → R1 the next byte of the console, which it waits for. The end of the line's input, `0x200`, is no byte, as the keyboard's bytes still come. |

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
  ends with the host's input. A new connection over Ethernet starts the
  line anew, as one to `niceemu --link` does (nice_cpu's DEBUG.md §7,
  through its link's `rx_resume_i` of MJoergen/nice_cpu#90), so the
  next host can type to a monitor that one host has left.
- The screen is memory at `0xFFFF0000`, one word per character with its
  color, so `mon_putc` writes the words directly where QMON writes a
  register. The hardware has a cursor, in registers numbered as
  QNICE-FPGA's VGA registers (`0xFFFFFF80` for `0xFF30`, and so on; see
  [SYSTEM.md](../doc/SYSTEM.md#the-screen)), which `mon_putc` keeps at
  the next character, and a display offset. Past the last row
  `mon_putc` moves the rows up by one, by copying, so the rows shown are
  always the 2000 words at `0xFFFF0000`, as in `niceemu`, and a program
  can write them directly. The screen is cleared by a loop over its
  words.
- The scrollback uses the rest of the screen's memory, past the 2000
  words: before the rows move up, row 0 is copied into a ring of rows,
  the history, which runs down from the top of the memory. The cold
  start finds the size of the memory from the display offset, which a
  board keeps only in the bits that address the memory: 32768 words on
  the MEGA65 and 8192 on the Nexys4DDR, so one `monitor.bin` serves
  every board. Page Up shows `k` rows back with the offset `size - 80k`,
  which wraps to row 0 of the screen, and the cursor off; the first
  Page Up turns the ring so that its newest row is the last of the
  memory. `niceemu` has no display offset, and keeps it as memory, so
  there the history is kept, 384 rows, and can be read with `d` or
  `--dump`, but is not shown. `c` and `scr_cls` leave it, as `clear`
  in a terminal does, and the cold start empties it.

## Loading from a host

A host loads a program at `0x8000` over the debug link, on the board's
Ethernet port or its UART, with `--monitor`:

    tools/load.py --eth 192.168.1.65 --monitor prog.bin
    tools/run.py --eth 192.168.1.65 --monitor -i in.txt prog.bin
    make load FILE=prog.bin ETH=192.168.1.65 ARGS=--monitor

Each holds the core with the ROM visible, clears the memory, which
leaves the ROM alone, writes the program, and starts the core. The
monitor boots cold, which leaves the RAM from `0x8000` alone, and the
tool types `r` and CR, which run the program. A program with a word
below `0x8000` is refused, as it would be in the ROM, and so is a
bitstream without a ROM. `--rom FILE` loads FILE at 0, with the ROM
hidden, in the ROM's place: for `niceemu --link`, `make cosim`, a
bitstream without a ROM, or another build of the monitor, such as
`build/monitor_test.bin`.

`run.py --monitor` prints what `niceemu` prints for the monitor and the
program joined, with `r` and CR before the input. The monitor reads on
at the end of the input, so the input ends with `h`, which halts the
core, as in the tests here:

    printf 'h\r' > h.txt
    tools/run.py --tcp PORT --monitor --rom build/monitor_test.bin \
        -i h.txt build/hello.bin
    printf 'r\rh\r' > rh.txt
    cat build/monitor_test.bin build/hello.bin > joined.bin
    niceemu -i rh.txt joined.bin

`make hwtest`, `make linktest`, and `make cosimtest` compare the two so
with `test/hello.nasm`, and `make hwtest` also runs it under the monitor
in the board's ROM, over the UART and Ethernet.

## Loading without a host

`l` loads a program that is typed on the keyboard, or pasted into a
terminal on the line, with no tools on the host and no storage. It reads
lines of `ADDR WORD`, two hex numbers of 1 to 8 digits with blanks or
tabs between them, which is what a `.bin` file has (nice_cpu's ISA.md
§10.4), and writes each word. CR, LF, and CR LF end a line, the `l`
line itself too. An empty line ends the load, and so does CTRL-C, which
drops the line it is in; a line of blanks only is passed over, as
`niceemu` passes it. DEL and backspace delete, and the cursor and
function keys do nothing. A line with anything else, one longer than 76
characters, or one with an address outside a program's RAM, `0x8000` to
`0x1EFFF` on the MEGA65 and to `0xEFFF` on the Nexys4DDR (Programs
above), is skipped: the RAM repeats through the address space, so a
larger address could reach the ROM or the monitor's variables and
stack. The top of that range is the stack itself, which `r` uses, so a
program's words stay below it. A second line for an address writes its
word over the first's, where `niceemu` rejects the file. In `niceemu`,
where `0xFFFFFF9E` reads 0, the program's RAM goes up to the screen,
`0xFFFEFFFF`. At the end `l` prints the number of words written, with
the lowest and the highest address, and the number of lines skipped,
with the first of them and the last address that a line may have:

    Words loaded: 601, 00008000 to 00009000
    Lines skipped: 4, first line 2; ADDR WORD in hex, ADDR 00008000 to 0001EFFF

The lines are shown in one row of the screen, which each line clears,
and not on the line, so the screen does not scroll, and a paste over the
UART at 2 Mbaud keeps up: a line takes about 1400 instructions, and
arrives in about 90 µs. On the R6, 20600 lines pasted at full speed, in
LF lines and in CR LF lines, were all written, with no byte lost.

Over Ethernet, a paste into a plain client, such as
`nc 192.168.1.65 4510`, keeps up too. The station takes the host's
bytes at 100 Mbit/s, faster than `l` reads them, but a byte that finds
the core's input FIFO of 2048 bytes full waits up to 50 ms for room,
and TCP holds the host back meanwhile. A byte is lost, with the link's
`o`, only when the program reads nothing for 50 ms. On the R6, 20600
lines pasted at full speed over TCP, in LF lines and in CR LF lines,
and through `nc`, were all written, with no byte lost, in about 0.7 s.
`load.py --eth 192.168.1.65 --monitor prog.bin` (Loading from a host
above) is faster, as it writes the words into the memory.

## Building and testing

`make -C monitor` assembles `monitor.nasm`, `monlib.nasm`, `mon.nasm`,
and `build/version.nasm`, the `cat` of them, with `niceasm` into
`build/monitor.bin`, as the assembler has no include. `version.nasm`
defines `VERSION`, the string of the banner, `git describe` of the tree
unless `VERSION=` is given, and is written only when it changes.

`make -C monitor test` checks the layout of the sources with nice_cpu's
`nicefmt`, checks that the monitor ends below `DEMO`, where the demo
goes in the ROM, assembles the monitor with the version `V9.9`, and runs
it in `niceemu` seven times, with its keystrokes in an input file and
`h` as the last command, so that the run ends: alone, with every command
and the edits of a line; alone, with 448 rows of `d`, which go round the
ring of the history, and Page Up and Page Down; alone, with `l` and
`build/hello.bin` pasted, lines that are skipped, tabs, a line of
blanks, a line too long, a second line for an address, and CTRL-C, then
`r`, with 128K words of RAM, as on the MEGA65, which a word of the
input file gives `0xFFFFFF9E`; alone, with `l` at the bounds of 64K
words, as on the Nexys4DDR; alone, with `l` where `0xFFFFFF9E` reads 0,
as in `niceemu`; with `test/hello.nasm` at `0x8000`, an assembly
program under nice_cpu's `start_mon.nasm`; and with `test/hello.c`,
built with `nicebuild.py --monitor --asm mon.nasm`, which is skipped
without clang. The console output, which is the copy on the line, a few
memory words, and the screen are compared with `test/NAME.expected`. The
expected files were checked by hand; after a change that moves them,
check the new output the same way before copying it from `build/`.
`test/ring.py` checks the ring of the history first, at the sizes of the
screen's memory of `niceemu` and the MEGA65, 32768 words, of the
Nexys4DDR, 8192, and of 2048, which has no room for it, with the monitor
built to take each size: it reads the rows a board would show from the
dump of the memory, at the display offset the monitor set, and compares
them with the console output, with the history filled in part and gone
round, after Page Ups, Page Downs, and a key that shows the screen
again. `test/dis.py` runs `u` over `test/dis.nasm` at `0x8000`, which
has every opcode, operand mode, condition, and modifier, the control
instructions, the reserved control words, unused fields that are not R0,
and the pairs that are `CALL` and `RET` and those that are not. It
compares each row with nicedis.py's text, or, for a `CALL` or a `RET`,
assembles it with `niceasm` and compares the words, and checks that `u`
without `ADDR` goes on after the last row.

On a board, `make r6` builds a bitstream that boots the monitor, with the
demo behind it in the ROM. `make hwtest` loads the same, with the
versions of the tests, into the RAM, and types `x` for the demo
([demo/](../demo/README.md)).

## The demo

The demo leaves this repository for nice_cpu
([nice_cpu#91](https://github.com/MJoergen/nice_cpu/issues/91)), and the
BASIC interpreter of
[#54](https://github.com/MJoergen/NiceMonMEGA65/issues/54) takes its place
in the ROM. Until then
([#65](https://github.com/MJoergen/NiceMonMEGA65/issues/65)), the ROM of
the boards and of the release has the demo behind the monitor, and `x`
runs it. The demo is a program assembled at `0x8000`
([demo/](../demo/README.md)), and `demo/join.py` puts it in the ROM at
`DEMO`, `0x1000`: the number of its words first, then the words. `x`
copies them to `0x8000` and runs them as `r` runs a program, and the
demo's F12 returns. A number of 0, as in the ROM of the monitor alone
and in `niceemu` without the demo, is no demo, and so is one that would
not fit below `0x8000`. Neither the copy nor the demo has an entry in
the dispatch table, and both go when the demo goes; `release.py` and
`demo_hw.py` follow.

## What QMON has that this port will not

- The SD card, FAT32, and `qtransfer` code, about half of QMON, has no
  hardware here.
- QMON's disassembler is for QNICE; `u` was written anew for the NICE
  instruction set, with nice_cpu's `assembler/nicedis.py` as the model
  (The disassembler above).
