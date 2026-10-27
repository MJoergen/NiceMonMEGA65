# NiceMonMEGA65

[![CI](https://github.com/MJoergen/NiceMonMEGA65/actions/workflows/ci.yml/badge.svg)](https://github.com/MJoergen/NiceMonMEGA65/actions/workflows/ci.yml)

The NICE CPU on the MEGA65, with a debug link and a demo in its ROM

This project runs the [NICE CPU](https://github.com/MJoergen/nice_cpu) on
the [MEGA65](https://mega65.org/) (R3 and R6), a modern FPGA computer in
the form of a Commodore 65. NICE is a 32-bit CPU with its own instruction
set, assembler, C toolchain, and emulator, `niceemu`. Here it shows a
screen of 80×25 characters on HDMI and VGA, and reads the MEGA65's
keyboard. The debug UART carries the program's console and the debug
link, which a PC uses to load, run, pause, step, and inspect programs. A
program runs on the board as it runs in `niceemu`.

There are two ways to use it:

- [On its own](#on-its-own), as a box with a keyboard and a screen, with
  no JTAG cable and no serial cable. The program is in the core's ROM.
- [With the serial port](#with-the-serial-port), where a PC loads programs
  over the debug link, talks to them, and debugs them.

A monitor like QMON, the one in
[QNICE-FPGA](https://github.com/sy2002/QNICE-FPGA), is planned but not
written yet (see [monitor/](monitor/README.md)). It will be in the ROM,
and will let a MEGA65 on its own load and run programs too.

This README is for those who use the core and write programs for it.
[SYSTEM.md](SYSTEM.md) has the address map, the devices, and the words
used for the link, such as hold, pause, and step.
[EMULATOR.md](EMULATOR.md) has the differences from the emulator, and
[CONTRIBUTING.md](CONTRIBUTING.md) is for those who change this repository.
The system also builds for the Digilent Nexys4DDR (see
[synth/](synth/README.md#the-nexys4ddr) and
[SYSTEM.md](SYSTEM.md#the-nexys4ddrs-devices)).

## Quick start

1. Download the core file for your board from the latest
   [release](https://github.com/MJoergen/NiceMonMEGA65/releases):
   `nicemon-V1.0-r6.cor` for the R6, or `nicemon-V1.0-r3.cor` for the R3
   and R3A. A core file holds its board revision, so use the one for
   yours.
2. Copy it to the SD card, and hold No Scroll while you switch the MEGA65
   on. MEGAFLASH, the MEGA65's core menu, then writes the core file into
   a slot of the flash.
3. The board then starts the system from that slot. The screen shows a
   welcome, and what you type appears on it (see
   [On its own](#on-its-own)).

No JTAG cable is needed. [RELEASE_NOTES.md](RELEASE_NOTES.md) has what
changed in each release.

## Setting up the tools

The tools that load and debug programs are in this repository. Clone it
with the submodule, which has the assembler, the emulator, and the C
library:

    git clone --recurse-submodules https://github.com/MJoergen/NiceMonMEGA65.git

or, in an existing clone:

    git submodule update --init

The tools need only Python 3, on Linux or macOS. The emulator, `niceemu`,
is built with `make -C nice_cpu/emulator build`, which needs Zig (see
[nice_cpu/emulator/](nice_cpu/emulator/README.md)). A terminal program
that runs at 2 Mbaud, such as `picocom`, shows the program's console.

## On its own

With no serial cable, the MEGA65 runs the program in its ROM, from reset.
The program reads the keyboard and writes the screen. Until the monitor is
written, the ROM of a release holds a demo, [demo/](demo/README.md). It
shows the version and how to go further, and below that it is a
typewriter: what you type appears on the screen. RETURN starts a new
line, INST/DEL deletes, the cursor keys move the cursor, and CTRL-L
clears what you typed. The reset button starts the demo again.

The ROM can also hold a program of your own, built into a core file of
your own:

    make cor ROM=prog.bin

That builds the bitstreams of the R3 and the R6 with Vivado, with a ROM of
32K words at address 0 that holds the words of `prog.bin`. It then makes
`synth/r6/build/NiceMonMEGA65-r6.cor` and
`synth/r3/build/NiceMonMEGA65-r3.cor`, which need `coretool` (see
[synth/](synth/README.md)). `make r6 ROM=prog.bin` builds only the R6's
bitstream, for a JTAG cable.

A write to the ROM is dropped, so a program in the ROM keeps its stack and
its variables in the RAM, at `0x8000` or above. `sim/rom.nasm`, a
greeting, and `demo/demo.nasm` are such programs. A C program keeps its data in its own image,
so it does not run from the ROM. [SYSTEM.md](SYSTEM.md#the-rom) has the
details. Try the program first in `niceemu`, or on the board with the
serial port, as the ROM changes only with a new bitstream.

### The keyboard

The MEGA65's own keyboard types into the same input as the UART: what you
type goes to the program while it runs or is paused, and is dropped while
the core is held or has halted. The keys give ASCII, as a terminal sends
it:

| Key | Byte |
|---|---|
| Letters, digits, symbols | Their ASCII; SHIFT or CAPS LOCK for capitals |
| RETURN | CR |
| INST/DEL | DEL (`0x7F`), also with SHIFT or CTRL |
| RUN/STOP | CTRL-C (`0x03`) |
| ESC, TAB | ESC, TAB |
| Cursor keys | `ESC [ A` to `ESC [ D`, as ANSI terminals send them |
| CTRL with a letter | Its control code |
| £, ↑, ← | `\`, `^`, `_` (`\|`, `~`, `` ` `` with SHIFT) |
| SHIFT with `0`, `=`, `:`, `;` | `{`, `}`, `[`, `]` |

A held key repeats after half a second, 20 times a second. The function
keys, HELP, CLR/HOME, and the modifiers give nothing. The keyboard's drive
LED is green while the core runs, like the user LED.

### The screen

The screen at `0xFFFF0000` is shown on the VGA connector and on the HDMI
connector, at 1280×1024 and 60 Hz, as 80 columns and 25 rows of characters
of 16×32 pixels, in the middle of the picture. Word `80 * row + column` is
one character: its code, ISO 8859-1, in bits 7..0, and its color above. The
color is two 12-bit colors, red, green, and blue with 4 bits each, as in
nice_cpu's `doc/SYSTEM.md` §1: the background in bits 31..20 and the
foreground in bits 19..8. A component `n` gives the byte `n × 0x11`, so
`0xF` is full intensity and `0x0` is none. Unlike in NICE's original IDE of
2004, the foreground is not inverted. So a word with only a character, such
as `0x41`, is black on black, and `0x000FFF41` is a white `A` on black. The
screen is 0 at power-up, which shows as black, and `nice_screen_clear`
fills it with blanks.

The screen's memory has room for scrolling, and the display has a cursor,
with registers as QNICE-FPGA's (see [SYSTEM.md](SYSTEM.md#the-screen)).

## With the serial port

The MEGA65's debug UART runs at 2 Mbaud (2000000), 8-N-1. It carries the
program's console both ways, and between its bytes the packets of the
debug link of nice_cpu's [doc/DEBUG.md](nice_cpu/doc/DEBUG.md). The tools
in `tools/` use the link, and `niceemu --link` serves the same link, so the
tools drive the emulator as they drive the board.

The tools use the serial device `/dev/ttyUSB1`, the MEGA65's debug UART. If
yours is another, give it to the tools with `--port`, and open it in your
terminal program. On macOS, use the `/dev/cu.*` device, as a `/dev/tty.*`
device blocks on open. The port must not be open in a terminal while a tool
runs. A bitstream built before the rate went up runs at 115200 baud, and
the tools need `--baud 115200` for it.

`make` has a target for each tool:

- `make load FILE=prog.bin` loads a program into the board and starts it.
- `make run FILE=prog.bin` runs one as `niceemu` runs it (see
  [Comparing with the emulator](#comparing-with-the-emulator)).
- `make mon` opens an interactive shell on the link (see
  [Debugging a program](#debugging-a-program)).

They use `PORT=/dev/ttyUSB1` by default, and pass `ARGS=` on to the tool,
for example `ARGS=--no-run` or `ARGS="-i in.txt -d 0:10 -s --timeout 5"`.
`ARGS="--tcp 4000"` drives `niceemu --link 4000` instead of the board.

### Running a program

A program is assembled with the assembler of the nice_cpu submodule, and
loaded with `tools/load.py`, which holds the core, hides the ROM if there is
one, clears the memory, writes the words with `W` packets, and then starts
the core. For
example, with `sim/echo.nasm`, which echoes what you type until a `.`:

    python3 nice_cpu/assembler/niceasm.py -o echo.bin sim/echo.nasm
    tools/load.py echo.bin
    picocom -b 2000000 /dev/ttyUSB1

Type in the terminal and the program echoes it. When you type `.`, it
halts, and the board sends its halt notice, which shows in the terminal as
a few letters after a stray character, such as `h01#C9`. What you type
goes to the program while it runs, and is dropped while the core is held
or has halted. To end a program's input, send a break: in picocom,
`Ctrl-A Ctrl-\`.

The `.bin` file has one line per word, the address and the word in hex.
`load.py --no-run` loads the program and leaves the core held.
`load.py --tcp PORT` loads it into `niceemu --link PORT` instead of the
board.

`load.py` takes the lines that `niceemu` takes: two fields of 1 to 8 hex
digits, with no `0x`, sign, or underscore, no repeated address, and at least
one word. As in `niceemu`, only LF ends a line, only blanks and tabs part the
fields, and a CR at the end of a line is ignored. It also rejects a word where the board has no memory of its own:
the RAM is the words `0` to `0xFFFF`, and the screen is the words
`0xFFFF0000` to `0xFFFF1FFF`, the 8192 that both boards have. Any other
address would land on a RAM word, or on a register of the I/O page, where
the emulator has a word of its own, so the program would run differently.
A program can still write the rest of the MEGA65's screen when it runs.

`load.py` holds the core first, so it also works while a program runs.

### Running a C program

Build the C examples (see [Writing programs](#writing-programs) for what
that needs):

    make -C examples

That builds `examples/build/primes.bin` from `examples/primes.c`, which
counts primes. Load it and open a terminal:

    tools/load.py examples/build/primes.bin
    picocom -b 2000000 /dev/ttyUSB1

The program asks for a limit, reads it with `scanf`, and counts the primes
up to it. It asks again until you enter 0, and then halts. The program does
not echo what you type, so the number shows only after you press Enter:

    Count the primes up to (0 to stop): 1000
    Primes up to 1000: 168
    36731 instructions in 58159 cycles

The third line comes from the performance counters, and the numbers are
from the board with the pipelined core, where the 58159 cycles at 100 MHz
take about 0.58 ms.

### Debugging a program

`tools/mon.py` is an interactive shell on the link, so that you need not
type packets in a terminal. It takes `--port`, `--tcp`, and `--cosim` as
`load.py` does, and a `.bin` file to load, with the core held:

    tools/mon.py echo.bin

Its commands are short, and `help` lists them. Numbers are hex.

- `load FILE` loads a program as `load.py --no-run` does.
- `go` starts a held core, or goes on from a pause. `run` starts the
  program at 0 again, and `hold` holds the core.
- `pause` pauses the core, and `step N` runs N steps of a paused core.
  An empty line steps again.
- `b ADDR` sets a breakpoint, `b` lists them, and `bd N` or `bd all`
  disables them.
- `regs` shows R0 to R15, and `status` the state of the core.
- `r ADDR N` reads N words, and `w ADDR WORD...` writes them. `ctl VALUE`
  writes the control register.
- `send TEXT` sends text to the program, with escapes such as `\n`, and
  `eof` ends its input.
- `console` passes the terminal through to the program, until Ctrl-].

The program's output and the link's notices, such as `[paused, PC=...]`
and `[halted: HALT, PC=...]`, are shown as they arrive. `quit` leaves the
core as it is. In `niceemu`, a pause or a breakpoint takes effect only
after the next byte while the program waits for one.

#### A worked example

This session ran on the MEGA65 R6, with `sim/echo.nasm`. These are its
instructions and their addresses:

    0  LOOP  MOVE    R1, @CONSOLE      ; bit 8 set when a byte has arrived
    2        AND[M]  R2, R1, 0x100
    4    ?Z  MOVE    PC, LOOP          ; nothing yet
    6        AND     R1, R1, 0xFF
    8        MOVE    @CONSOLE, R1      ; echo the byte
    A        SUB[M]  R2, R1, 0x2E      ; a '.'?
    C   ?!Z  MOVE    PC, LOOP
    E        HALT

Assemble it, and start `mon.py` with it. The core is held, with the
program in memory:

    $ python3 nice_cpu/assembler/niceasm.py -o echo.bin sim/echo.nasm
    $ tools/mon.py echo.bin
    loaded 15 words; the core is held
    'help' lists the commands, and 'q' quits.
    mon> status
    held, ROM hidden, control 00000009, link version 4, input free 2048
    mon> r 0 f
    00000000: 00007800 ffffff00 03a080b0 00000100 3003d800 00000000 01a040b0 000000ff
    00000008: 001c0080 ffffff00 022080b0 0000002e b003d800 00000000 0c000000

Start the program, and pause it. It waits for input, so it is in its
loop. Z, bit 27 of R14, is set, as no byte has arrived:

    mon> go
    mon> pause
    [paused, PC=00000000]
    mon> regs
    R0  00000000 R1  00000000 R2  00000000 R3  00000000
    R4  00000000 R5  00000000 R6  00000000 R7  00000000
    R8  00000000 R9  00000000 R10 00000000 R11 00000000
    R12 00000000 R13 00000000 R14 09000000 R15 00000000
    mon> s 3
    PC=00000002
    PC=00000004
    PC=00000000

Set a breakpoint at 6, which the program reaches only when a byte has
arrived, and go on. Send it an `A`, and it stops. R1 holds the console's
read: bit 8 set, and `0x41`, the `A`:

    mon> b 6
    0: 00000006
    mon> g
    mon> send A
    [breakpoint 0, PC=00000006]
    mon> regs
    R0  00000000 R1  00000141 R2  00000100 R3  00000000
    R4  00000000 R5  00000000 R6  00000000 R7  00000000
    R8  00000000 R9  00000000 R10 00000000 R11 00000000
    R12 00000000 R13 00000000 R14 01000000 R15 00000006
    mon> s
    PC=00000008
    mon>
    A
    PC=0000000a
    mon>
    PC=0000000c

Each empty line runs one more step. The step at 8 echoes the `A`. Then
disable the breakpoint, go on, and type to the program in the console,
until Ctrl-]. A `.` ends it:

    mon> bd all
    mon> g
    mon> c
    console; Ctrl-] returns to the prompt
    Hello
    mon> send .
    .
    [halted: HALT, PC=0000000f]
    mon> status
    halted: HALT, ROM hidden, control 0000000a, link version 4, input free 2048
    PC=0000000f
    mon> q

### Comparing with the emulator

`tools/run.py` loads a program into cleared memory, starts it, sends it its
input, and copies its output to stdout. When the program halts, it prints
what `niceemu` prints: why and after how many steps the program halted,
and the registers, and it exits with the same status, 0 after `HALT` and 2
after any other halt. It takes niceemu's `-i`, `-d`, `-s`, and `--symbols`
options, so the output of the two can be compared:

    nice_cpu/emulator/zig-out/bin/niceemu -d 0x110:2 -s prog.bin > emu.txt
    tools/run.py -d 0x110:2 -s prog.bin > board.txt
    diff emu.txt board.txt

`-d ADDR:N` takes numbers as `niceemu` does, up to 32 bits, with no sign or
underscore, but N is at most 65536 words. On the board, the words at
`0xFFFFFFE0` to `0xFFFFFFFF` are read through their RAM alias `0x0000FFE0`
to `0x0000FFFF`, for the link has its debug registers there. The link reads
the console and the read counter, `0xFFFFFF00` and `01`, as 0.

Its input is stdin, or the file of `-i`. Before each part of at most 256
bytes, `run.py` reads the free space of the core's input FIFO, and sends
no more than that, so no byte is lost, however far the program falls
behind. At the end of the input, `run.py` sends a break, so that a read
returns `0x200`, as in the emulator. On a terminal, Ctrl-D ends the input.
The link's halt notice comes after the program's last byte, so the output
ends there. Input that the program has not read when it halts is dropped,
as by the emulator.
`--timeout SEC` gives up after SEC seconds (60 by default, 0 for no limit).
It holds the core, prints "Stopped at the time limit after SEC s" and the
`--dump` and `--screen` output, and exits with status 3, as `niceemu -n`
does at its step limit. It prints no registers and no step count, as a
hold leaves the registers undefined (DEBUG.md §6). `niceemu` has no step
limit unless `-n` gives one, and `run.py` gives up after 60 seconds.
Ctrl-C holds the core too.
`--tcp PORT` runs the program on `niceemu --link PORT` instead of the
board, which checks `run.py` and the link against the plain emulator:

    nice_cpu/emulator/zig-out/bin/niceemu --link 4000 &
    tools/run.py --tcp 4000 prog.bin

With `--tcp`, the end of the input half-closes the connection, and `-d`
cannot reach `0xFFFFFFE0`–`FF`, which are the emulator's memory.

`--symbols FILE` reads the labels that `niceasm.py --symbols` writes, and
after a halt other than `HALT` prints where the program was, `At
label+0x1f`, if the file has any labels, and after a halt at `___wasm_trap`, the default wasm trap
handler, the trap's code and location from R1 and R2, as `niceemu` does. At
the time limit it prints no location, as there are no registers.
`-2004` prints the screen from `0x400`, as `niceemu -2004` does. That is
plain RAM on the board, not the screen that the display shows.

The step count is the core's instruction counter. The emulator's steps
include interrupt entries, and the instruction counter does not, so a
program with interrupts has more steps in the emulator. A read of the console
in the emulator waits for the next byte, but on the board it returns 0
while no byte has arrived. So a program that waits for input in a loop runs
more steps on the board, and its step count differs. The memory is 64K
words, repeated through the address space, so `-d` beyond them shows the
same words again. [EMULATOR.md](EMULATOR.md) has the table of the known
differences from the emulator.

## Writing programs

A program is NICE assembly, assembled with `niceasm` of the nice_cpu
submodule into a `.bin` file, which has one line per word, the address and
the word in hex. nice_cpu's [doc/ISA.md](nice_cpu/doc/ISA.md) is the
instruction set, and its [doc/SYSTEM.md](nice_cpu/doc/SYSTEM.md) the
devices: the console, the math unit, the performance counters, and the
timer. [SYSTEM.md](SYSTEM.md) here has the address map of the board,
with its screen and its ROM. The memory is 64K words, not 2³² as in the
emulator.

C goes through WebAssembly, with the tools of the nice_cpu submodule: clang
compiles the program to a wasm module and links it with nice_cpu's C
library, `nicewasm` translates the module to NICE assembly, and `niceasm`
assembles it together with the start-up code and the runtime library.
`nicebuild.py` does all of it in one command:

    nice_cpu/translator/nicebuild.py -o prog.bin prog.c

It joins the trap report, so a wasm trap, such as an access outside the
linear memory, prints a line such as `trap 2: out of bounds memory access
at 00003dc9` before the core halts. You need clang with the wasm32 target,
`wasm-ld`, and `llvm-ar` (on Debian and Ubuntu, the `clang`, `lld`, and
`llvm` packages). The steps it runs are those of
[nice_cpu/runtime/README.md](nice_cpu/runtime/README.md), and the
translator's README, [nice_cpu/translator/README.md](nice_cpu/translator/README.md),
has them for Zig and Rust too.

The C library has `printf`, `scanf`, `puts`, `putchar`, `getchar`, the
`FILE` functions on `stdin`, `stdout`, and `stderr`, which are all the
console, the string functions, `malloc`, `rand`, `exit`, `assert`, and more.
`putchar` and `getchar` use the UART at `0xFFFFFF00`. `getchar` waits for a
byte, and returns `EOF` once a break on the UART has ended the input.
`nice.h` declares the device routines of nice_cpu's runtime/ABI.md:
`nice_putc`, `nice_getc`, `nice_pollc`, and `nice_print` for the UART, and
`nice_cycles`, `nice_instructions`, and `nice_micros` for the performance
counters. `examples/primes.c` uses the first two. It also declares `nice_peek`
and `nice_poke`, which read and write any NICE address, such as the math
unit's. `nice_screen_put` and `nice_screen_clear` write the screen at
`0xFFFF0000`, which the VGA and HDMI outputs show (VGA only on the
Nexys4DDR). `time.h` has `clock()`, which counts microseconds from the
counter at `0xFFFFFF44`. On the board they are real time, at the clock's
rate; in the emulator a microsecond is a step. There is no calendar, so
`time()` returns -1.

The translated code and the runtime routines multiply and divide with the
math unit, so the program is joined with `muldiv_mpu.nasm`. A system
without the math unit would translate with `nicewasm --no-mpu` and use
`muldiv_soft.nasm` instead.

The linear memory is one page, 16384 words, and the program and its memory
must fit below the stack in the 64K words of memory. With `printf` and
`scanf`, the prime example ends at word `0x634F`.

## License

MIT, see [LICENSE](LICENSE), like the files copied from cmod-s7 and
MandelbrotMEGA65. The exceptions are the third-party files named in
[synth/README.md](synth/README.md): `synth/r3/max10.vhd` is GPL v3, and the
HDMI output in `synth/mega65/hdmi/` is LGPL v3. The Spleen font in
`src/video/font_pkg.vhd` is BSD 2-Clause, see `font/LICENSE.spleen`.
`synth/r3/max10.vhd` has no license header of its own, so its GPL v3 rests on
its origin in the MEGA65 core. `src/kbd_m65.vhd` is written after the GPL v3
driver of MiSTer2MEGA65, with the same timing on the pins but none of its
code, and is MIT like the rest of `src/`.
