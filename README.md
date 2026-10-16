# NiceMonMEGA65
The NICE CPU with a monitor, on the MEGA65

This project runs the [NICE CPU](https://github.com/MJoergen/nice_cpu) on the
MEGA65 board (R3 and R6), with a command line interpreter on the UART like
the one in [cmod-s7](https://github.com/MJoergen/cmod-s7). A monitor like
the one in [QNICE-FPGA](https://github.com/sy2002/QNICE-FPGA) is planned and
not written yet (see [monitor/](monitor/README.md)). The hardware for it is
there: a ROM at address 0, which the core boots from, and a screen with a
cursor and scrolling, laid out as QNICE-FPGA's. Until the monitor is
written, programs are loaded through the command line.

## Contents

| Path | What it is |
|---|---|
| [nice_cpu/](https://github.com/MJoergen/nice_cpu) | The NICE CPU, its assembler, and its emulator, as a git submodule. |
| [src/](src/) | The synthesisable VHDL, shared by both boards. `nicemon.vhd` is the system: the NICE core, the memory (`ram.vhd` and `rom.vhd`), the UART, the core's input FIFO (`rx_fifo.vhd`), and the command line interpreter. `uart_serdes.vhd` (with fixes to its receiver, and break detection), `line_buffer.vhd` and `cmd.vhd` are copied from cmod-s7; `cmd.vhd` prints `NICE` instead of `WBUS` at reset, and `HALT` when the core halts. `kbd_m65.vhd` drives the MEGA65 keyboard, and `kbd_ascii.vhd` turns its keys into ASCII. |
| [src/video/](src/video/) | The text display: `text.vhd` shows the screen at `0xFFFF0000` as 80×25 characters on a video output, with a cursor and a display offset for scrolling. `pix.vhd` and `video_pkg.vhd` are from [MandelbrotMEGA65](https://github.com/MJoergen/MandelbrotMEGA65), and `font_pkg.vhd` is the [Spleen](https://github.com/fcambus/spleen) 16×32 font, made by `font/gen_font_pkg.py`. |
| [font/](font/) | The script that makes `src/video/font_pkg.vhd` from Spleen, and Spleen's license (BSD 2-Clause). |
| [sim/](sim/) | The GHDL testbenches. |
| [formal/](formal/) | The formal checks, for SymbiYosys. |
| [synth/](synth/README.md) | The Vivado builds for the R3 and R6 boards. |
| [monitor/](monitor/README.md) | The monitor, in NICE assembly: planned, not written yet. Its README has the decisions it will follow, QNICE-FPGA's. |
| [examples/](examples/) | Example C programs, and the Makefile that builds them for the MEGA65. |
| [tools/](tools/) | `load.py`, which loads a program into the MEGA65 through the UART, `run.py`, which runs a program on the MEGA65 as `niceemu` runs it, and `hwtest.py`, which tests the system on the board. |

## Compared with the emulator

The goal is a MEGA65 that runs NICE programs as `niceemu`, the emulator in
`nice_cpu/emulator`, runs them. **It is close, but not there yet.** The
core, the address map, and the devices behave as in the emulator, and the
command line reads back what the emulator prints after a halt.
`tools/run.py` runs a program on the board and prints what `niceemu` prints
for it, so the two can be compared (see
[Comparing with the emulator](#comparing-with-the-emulator)). The main
difference is the memory: 64K words, not 2³².

| Feature | Emulator | MEGA65 | Same? |
|---|---|---|---|
| Instruction set | ISA.md | nice_cpu's `multicycle.vhd`, which nice_cpu's tests compare with the emulator | Yes |
| Console output, `0xFFFFFF00` | stdout | UART | Yes |
| Console input, `0xFFFFFF00` | stdin, with bit 8 set; `0x200` at the end. A read waits for the next byte | UART and the MEGA65 keyboard, with bit 8 set, through a 2048-byte FIFO; `0x200` after a UART break. A read returns 0 while no byte has arrived | Yes, but UART bytes beyond 2048 unread ones are lost, and a program that waits for input in a loop runs more steps |
| Math unit, `0xFFFFFF20`–`3F` | Computed on read | nice_cpu's `mpu.vhd`, which stalls the read until the result is ready | Yes |
| Performance counters, `0xFFFFFF10`–`1F` | One cycle per step, from the start | nice_cpu's `perf.vhd`, counting clock cycles at 50 MHz, from the start of the core | Instructions yes; cycles count real clocks |
| Timer, `0xFFFFFF40`–`4F` | Raises IRQ every P steps | nice_cpu's `timer.vhd`, raising IRQ every P clock cycles at 50 MHz | Yes, but the period counts real clocks, so the interrupts come at other steps |
| Instruction fetches from `0xFFFFFF00`–`FF` | Read 0 | Read 0 | Yes |
| Memory | All 2³² words, 0 at the start | 64K words, repeated through the address space; the stack at `0xFFFFFF00` lands in the top. `load.py` and `run.py` hide the ROM, if the bitstream has one, and clear the RAM to 0 before they load | No: a program, its data, and its stack must fit in 64K words |
| Screen, `0xFFFF0000`–`07CF` | 80×25 words of memory, printed by `--screen` | 32768 words of memory of their own, read with `R`; the first 2000 are shown on VGA and HDMI, unless the display offset is set | Yes |
| Read counter, `0xFFFFFF01` | Counts the data reads since the last write | The same; a read by the command line does not count, as `--dump` does not | Yes |
| The rest of `0xFFFFFF02`–`FF` | Ordinary memory for data | Memory, in the top 256 words of the RAM, except `0xFFFFFF50`–`5F`, the screen's registers | Yes, but for the screen's registers |
| Interrupts | From the timer, `--irq`, and `--nmi` | From the timer, on IRQ | Yes, for the timer's |
| After a halt | Prints why, the steps, and the registers, and exits with a status | The command line gets the UART back and prints `HALT`; `R FFFFFFF1` reads why, the instruction counter the steps, `R FFFFFFE0` to `R FFFFFFEF` R0–R15, and `R` memory. `run.py` prints them as the emulator does, with its exit status | Yes |
| `--dump`, `--screen`, `--input` | Options | The same options of `run.py` | Yes |
| `--trace`, `--max-steps`, `--irq`, `--nmi` | Options | Not available | No |

So a program that fits in 64K words, and does not fall more than 2048
bytes behind its input, prints the same. The C example `examples/primes.c`
is one, except for the cycles that it prints.

## Getting started

Clone with the submodule:

    git clone --recurse-submodules https://github.com/MJoergen/NiceMonMEGA65.git

or, in an existing clone:

    git submodule update --init

`make` in the top directory lists the targets: `make test` runs the
simulation tests, `make formal` runs the formal checks (see
[The formal checks](#the-formal-checks)), `make lint` checks the VHDL style, `make examples` builds
the C examples, `make r3` and `make r6` build the bitstreams, with
`ROM=file.bin` one whose core boots from the file (see
[The ROM](#the-rom)),
`make load FILE=prog.bin` loads a program into the MEGA65 and starts it,
`make run FILE=prog.bin` runs one as `niceemu` runs it (see
[Comparing with the emulator](#comparing-with-the-emulator)), and
`make hwtest` tests the board (see [Testing the board](#testing-the-board)).

## Using it

Connect a terminal to the MEGA65's debug UART at 115200 baud, 8-N-1. After
reset the command line interpreter prints `NICE` and takes two commands, with
8 hex digits for each number. Commands and hex digits may be upper or lower
case. End each line with CR alone.

| Command | What it does |
|---|---|
| `R <ADDR>` | Reads a word, and prints it. |
| `W <ADDR> <DATA>` | Writes a word, and prints `OK`. |

The core is held in reset at power-up. To run a program, write its words to
memory, then start the core:

    W FFFFFFF0 00000000

While the core runs, the UART belongs to it. When it halts, the UART goes
back to the command line. `W FFFFFFF0 00000001` holds the core in reset
again, and `R FFFFFFF0` reads bit 0 (held) and bit 1 (halted).
`W FFFFFFF0 00000005` clears the memory to 0 and holds the core; it answers
`OK` when the memory is clear. When a program halts, the command line
prints `HALT` on a line of its own, and `R FFFFFFF1` reads why it halted.
Bit 3 of the control register hides the ROM, so that the RAM is at address
0 (see [The ROM](#the-rom)); in a bitstream without a ROM it reads 1, and
`load.py` sets it, so the commands above work on both.

### The keyboard

The MEGA65's own keyboard types into the same input as the UART: what you
type goes to the command line, or to the program while it runs, and its
answers come out on the UART. The keys give ASCII, as a terminal sends it:

| Key | Byte |
|---|---|
| Letters, digits, symbols | Their ASCII; SHIFT or CAPS LOCK for capitals |
| RETURN | CR |
| INST/DEL | DEL (`0x7F`), also with SHIFT |
| RUN/STOP | CTRL-C (`0x03`) |
| ESC, TAB | ESC, TAB |
| Cursor keys | `ESC [ A` to `ESC [ D`, as ANSI terminals send them |
| CTRL with a letter | Its control code |
| £, ↑, ← | `\`, `^`, `_` (`\|`, `~`, `` ` `` with SHIFT) |
| SHIFT with `0`, `=`, `:`, `;` | `{`, `}`, `[`, `]` |

A held key repeats after half a second, 20 times a second. The function
keys, HELP, CLR/HOME, and the modifiers give nothing. The keyboard's drive
LED is green while the core runs, like the user LED.

### Running a program

A program is assembled with the assembler of the nice_cpu submodule, and
loaded with `tools/load.py`, which hides the ROM if there is one, clears the
memory, writes each word with a `W` command, and then starts the core. For
example, with `sim/echo.nasm`, which echoes what you type until a `.`:

    python3 nice_cpu/assembler/niceasm.py -o echo.bin sim/echo.nasm
    tools/load.py echo.bin
    picocom -b 115200 /dev/ttyUSB1

`load.py` uses the serial device `/dev/ttyUSB1`, the MEGA65's debug UART.
If yours is another, give it with `--port`, and to picocom.
`load.py` needs only Python 3, on Linux or macOS, and the port must not be
open in a terminal while it runs. Type in the terminal and the program echoes
it. When you type `.`, it halts, the command line takes the UART again,
and it prints `HALT`.

The `.bin` file has one line per word, the address and the word in hex, so
`load.py` turns `00000001 ffffff00` into `W 00000001 FFFFFF00`. You can also
type these commands by hand. `load.py --no-run` loads the program and leaves
the core held, so you can check memory with `R` before you start it.

`load.py` talks to the command line, so it works only while the core is held
or has halted. While a program runs, the UART belongs to it: wait for it to
halt, or press the reset button.

### Running a C program

C goes through WebAssembly, with the tools of the nice_cpu submodule: clang
compiles the program to a wasm module and links it with nice_cpu's C
library, `nicewasm` translates the module to NICE assembly, and `niceasm`
assembles it together with the start-up code and the runtime library.
`examples/Makefile` does all of it. For the prime counting example,
`examples/primes.c`:

    make -C examples

That builds `examples/build/primes.bin`. Load it and open a terminal:

    tools/load.py examples/build/primes.bin
    picocom -b 115200 /dev/ttyUSB1

The program asks for a limit, reads it with `scanf`, and counts the primes
up to it. It asks again until you enter 0, and then halts. The program does
not echo what you type, so the number shows only after you press Enter:

    Count the primes up to (0 to stop): 1000
    Primes up to 1000: 168
    51413 instructions in 619097 cycles

These numbers are from the simulation. The second line comes from the
performance counters, and it should be the same on the board, where the
619097 cycles at 50 MHz take about 12 ms.

You need clang with the wasm32 target, `wasm-ld` and `llvm-ar` (on Debian
and Ubuntu, the `clang`, `lld` and `llvm` packages). The steps that the
Makefile runs are those of `nice_cpu/runtime/README.md`:

    make -C nice_cpu/runtime/libc libc.a
    clang --target=wasm32 -mbulk-memory -O2 -ffreestanding -nostdlibinc \
        -isystem nice_cpu/runtime/libc/include -nostdlib -Wl,--no-entry -Wl,--export=main \
        -Wl,--stack-first -Wl,-z,stack-size=4096 -Wl,--initial-memory=65536 \
        -o primes.wasm examples/primes.c nice_cpu/runtime/libc/libc.a
    nice_cpu/translator/nicewasm.py -o primes.nasm primes.wasm
    cat nice_cpu/runtime/start_wasm.nasm primes.nasm nice_cpu/runtime/lib.nasm \
        nice_cpu/runtime/muldiv_mpu.nasm > primes_full.nasm
    nice_cpu/assembler/niceasm.py -o primes.bin primes_full.nasm

The C library has `printf`, `scanf`, `puts`, `putchar`, `getchar`, the
string functions, `malloc`, and more. `putchar` and `getchar` use the UART
at `0xFFFFFF00`. `getchar` waits for a byte, and returns `EOF` once a
break on the UART has ended the input. `nice.h` declares the device routines of
ISA.md §9.3: `nice_putc`, `nice_getc`, `nice_pollc`, and `nice_print` for
the UART, and `nice_cycles` and `nice_instructions` for the performance
counters, as `examples/primes.c` uses them. It also declares `nice_peek`
and `nice_poke`, which read and write any NICE address, such as the math
unit's. `nice_screen_put` and `nice_screen_clear` write the screen at
`0xFFFF0000`, which the VGA and HDMI outputs show.

The translated code and the runtime routines multiply and divide with the
math unit, so the program is joined with `muldiv_mpu.nasm`. A system
without the math unit would translate with `nicewasm --no-mpu` and use
`muldiv_soft.nasm` instead.

The linear memory is one page, 16384 words, and the program and its memory
must fit below the stack in the 64K words of memory. With `printf` and `scanf`, the
prime example ends at word `0x6C90`. The translator's README,
`nice_cpu/translator/README.md`, has the same steps for Zig and Rust.

### The screen

The screen at `0xFFFF0000` is shown on the VGA connector and on the HDMI
connector, at 1280×1024 and 60 Hz, as 80 columns and 25 rows of
characters of 16×32 pixels, in the middle of the picture. Word `80 * row +
column` is one character: its code, ISO 8859-1, in bits 7..0, and its
colour above. The colour is two 8-bit colours, RGB with 3, 3, and 2 bits:
the background in bits 31..24 and the foreground in bits 23..16. Bits 15..8
are not used. A word with 0 in bits 31..16 is white on black, so plain
characters are readable. The screen is 0 at power-up, which shows as black,
and `nice_screen_clear` fills it with blanks.

The screen's memory is 32768 words, `0xFFFF0000`–`0xFFFF7FFF`, of which the
display shows 2000 from the display offset, so a program scrolls by adding
80 to the offset and writing the next row after the rows shown, and scrolls
back by taking 80 away, as the QNICE monitor does. The offset wraps at the
end of the memory. The display also has a cursor, which swaps the colours
of its character. The registers are numbered as the VGA registers of
QNICE-FPGA, at `0xFF30` there:

| Address | Register |
|---|---|
| `0xFFFFFF50` | State. Bit 6 shows the cursor, bit 5 makes it blink, about twice a second, bit 4 makes it small, the bottom 4 lines of the character, and bit 10 enables the display offset. Bits 11..4 are kept and read back; the rest read 0. |
| `0xFFFFFF51` | The cursor's column, 0 to 79. |
| `0xFFFFFF52` | The cursor's row, 0 to 24. |
| `0xFFFFFF55` | The display offset, in words, 0 to 32767. It takes effect when bit 10 of the state is set. |

The words `0xFFFFFF53`, `54`, and `56`–`5F` read 0 and take no write. In
the emulator these addresses are memory, so a program that writes them
runs there too, without scrolling. After reset the offset is 0 and the
cursor is off.

The colour format is a guess. nice_cpu says only that the colour is above
bit 7, and its one example, the 2004 program
`nice_cpu/assembler/test/print.nasm`, writes `0xC80FF000` and calls it "blue
on orange", which this format shows: `0xC8` is orange and `0x0F` is blue.

From the command line, `W FFFF0000 00000041` puts an `A` in the top left
corner, white on black, and `W FFFF0001 E0FF0042` a white `B` on red next to
it.

The video output comes from MandelbrotMEGA65, which uses the same mode on
the MEGA65. The HDMI output is DVI, without sound.

### The ROM

A bitstream built with `make r6 ROM=file.bin` (or `make r3 ...`) has a ROM
of 32K words at `0x0000`–`0x7FFF`, in front of the RAM, with the words of the
`.bin` file, and its core boots from it at reset instead of waiting for the
command line. That is the layout of QNICE-FPGA, whose monitor is in ROM at
`0x0000`–`0x7FFF` and whose programs load at `0x8000`, and it is where the
monitor will go. The file is read by Vivado, so the ROM changes only with a
new bitstream, and a word beyond the ROM fails the build. A write to the
ROM is dropped, and the clear command does not touch it. So a program in
the ROM must keep its stack and its variables in the RAM, at `0x8000` or
above: `sim/rom.nasm`, the greeting that the tests use as the ROM, has its
stack at the top of the memory, as the runtime has. With a stack in the
ROM, as `hello.nasm` of nice_cpu has at `0x1000`, a pushed return address
is lost and reads back as 0, and the program starts over, forever.

While the core runs from the ROM, the UART belongs to it, so the command
line answers only after the core halts. Then bit 3 of the control register
hides the ROM: `W FFFFFFF0 00000009` holds the core with the ROM hidden, and
the RAM is at address 0, as in the emulator, so a program loads and runs as
without a ROM, with `W FFFFFFF0 00000008` to start it. `load.py` does this.
`W FFFFFFF0 00000001` and then `W FFFFFFF0 00000000` show the ROM again and
boot from it, as the reset button does. The RAM under the ROM keeps its
words meanwhile.

### Address map

The command line and the core's data accesses see the same addresses.

| Address | What it is |
|---|---|
| `0x00000000`–`0xFFFFFFFF` | Memory, where no register below is: 64K words of block RAM, repeated through the address space. So the runtime's stack below `0xFFFFFF00` lands in the top of it, and so do the words of `0xFFFFFF00`–`FF` that are not registers. |
| `0x00000000`–`0x00007FFF` | The ROM, in a bitstream built with one, in front of the RAM and repeating with it (see [The ROM](#the-rom)). Bit 3 of the control register hides it. |
| `0xFFFF0000`–`0xFFFF7FFF` | The screen: 32768 words of memory of their own, the emulator's 80×25 screen and room for scrolling. The 2000 words from the display offset are shown on VGA and HDMI (see [The screen](#the-screen)), and `R` reads them all. |
| `0xFFFFFF00` | The console of ISA.md §8.3. A write sends bits 7..0 to the UART. A read takes the oldest byte received from the UART or the keyboard, and returns it in bits 7..0 with bit 8 set, or 0 when no byte has arrived. A break on the UART ends the input: once the bytes before it are read, a read returns `0x200` (bit 9), as at the end of the emulator's input, until the core is started again. |
| `0xFFFFFF01` | The emulator's read counter. A read by the core returns the number of its reads since the last write, and a write sets that number. A read with `R` does not count. It is 0 when the core starts. |
| `0xFFFFFF10`–`0xFFFFFF1F` | The performance counters of ISA.md §8.5: cycles and instructions, 64 bits each. `R` reads them as the core does: `R FFFFFF12` takes the snapshot that `R FFFFFF13` returns, where `--dump` takes none. |
| `0xFFFFFF20`–`0xFFFFFF3F` | The math unit of ISA.md §8.4: 32-bit multiply and divide, and 64-bit divide. |
| `0xFFFFFF40`–`0xFFFFFF4F` | The timer of ISA.md §8.6: it raises IRQ every P clock cycles, through the vector it is given. |
| `0xFFFFFF50`–`0xFFFFFF5F` | The screen's registers: the cursor and the display offset (see [The screen](#the-screen)). |
| `0xFFFFFFE0`–`0xFFFFFFEF` | For the command line only: R0–R15 of the core, read only. After a halt they hold what the emulator prints. |
| `0xFFFFFFF0` | Control, for the command line only. Bit 0 holds the core in reset. Bit 1 reads the core's halted flag. A write with bit 2 set first clears the RAM and the screen to 0, with the core held, and answers `OK` when it is done; then bits 0 and 3 take effect. Bit 3 hides the ROM, so that the RAM is at 0; reset clears it in a bitstream with a ROM, and in one without it reads 1. |
| `0xFFFFFFF1` | For the command line only, read only: why the core halted. 0 while it has not, 1 for `HALT`, 2 for a reserved control word, 3 for `INT` inside an interrupt routine, and 4 for `RTI` outside one. |

Instruction fetches from `0xFFFFFF00`–`0xFFFFFFFF` read 0, as ISA.md §8.3
requires. The input waits for the core in a FIFO of 2048 bytes, in block
RAM. A UART byte that arrives when it is full is lost, as is a byte after a
break; a keyboard byte waits until there is room. A break while the command
line has the UART is ignored. To end a program's input from a terminal,
send a break: in picocom, `Ctrl-A Ctrl-\`.
The performance counters, the math unit, and the timer are nice_cpu's own,
`nice_cpu/hdl/src/perf.vhd`, `mpu.vhd`, and `timer.vhd`, the same as in the
emulator. They are reset with the system, and each time the core starts, as
the emulator's are when it starts. So after a halt the instruction counter
holds the steps that the emulator prints, unless the program starts the
timer. The timer counts clock cycles, at 50 MHz, where the emulator counts
steps, so its interrupts come at other steps, and the step counts differ.
Its request goes straight to the core's IRQ, for it is the only device that
raises one. They are not reset while the command line holds the core, so
`R` reads them after a halt.

## Comparing with the emulator

`tools/run.py` loads a program into cleared memory, starts it, sends it its
input, and copies its output to stdout. When the program halts, it prints
what `niceemu` prints: why and after how many steps the program halted,
and the registers, and it exits with the same status, 0 after `HALT` and 2
after any other halt. It takes niceemu's `-i`, `-d`, and `-s` options, so
the output of the two can be compared:

    nice_cpu/emulator/zig-out/bin/niceemu -d 0x110:2 -s prog.bin > emu.txt
    tools/run.py -d 0x110:2 -s prog.bin > board.txt
    diff emu.txt board.txt

Its input is stdin, or the file of `-i`. Each byte goes to the UART when it
is read, and a byte that arrives when the core's 2048-byte FIFO is full is
lost, so a program must not fall more than 2048 bytes behind its input. At
the end of the input, `run.py` sends a break, so that a read returns
`0x200`, as in the emulator. On a terminal, Ctrl-D ends the input.
`--timeout SEC` gives up after SEC seconds, with exit status 3, as
`niceemu -n` does at its step limit, but leaves the core running.

The step count is the core's instruction counter. A read of the console
in the emulator waits for the next byte, but on the board it returns 0
while no byte has arrived. So a program that waits for input in a loop runs
more steps on the board, and its step count differs. The memory is 64K
words, repeated through the address space, so `-d` beyond them shows the
same words again.

## Running the tests

You need GHDL (tested with 4.1.0) and Python 3.

    make -C sim test

- `sim/tb_hello.vhd` runs a "Hello" program on the NICE core from the
  submodule, and checks its console output.
- `sim/tb_nicemon.vhd` drives the whole system through its UART, with
  `sim/rom.nasm`, a greeting, as the ROM: the core boots from it at reset,
  the ROM is read only with the RAM above it, and bit 3 of the control
  register hides it and shows it again. With the ROM hidden, it loads the
  "Hello" program
  with the command line and runs it, and checks the
  halt message, the halt reason, and the step count, which must equal
  niceemu's. Then it loads and runs `sim/echo.nasm`, which echoes what it
  receives, and `sim/fifo.nasm`, which checks the input FIFO; the FIFO has
  16 bytes there, so that the test of a full FIFO is short. It uses the
  math unit from the command line, and runs `sim/devices.nasm`, which uses
  the math unit, the performance counters, and the timer's interrupts, and
  `sim/emu.nasm`, which checks the screen, the read counter, memory in the
  I/O range, and the registers after a halt, and writes and reads the
  screen's registers. It clears the memory, and runs
  `reserved.nasm` of the emulator's tests, which halts on a reserved
  control word, and `sim/eof.nasm`, which echoes its input until a break
  ends it. Last it types a command and input for `sim/fifo.nasm` on the
  keyboard input.
- `sim/tb_kbd.vhd` tests the keyboard driver and its ASCII, with a model of
  the keyboard.
- `sim/tb_text.vhd` fills the screen of the text display and checks every
  pixel of one 1280×1024 frame, and the sync pulses; then it scrolls the
  display one row, shows the cursor, and checks the first four rows of the
  next frame. It takes about two minutes.
- `make test` also checks that GHDL can synthesise the system, with
  `sim/rom.nasm` as its ROM and without a ROM, the keyboard, and the text
  display.
- `make lint` checks the VHDL against [CODING_STYLE.md](CODING_STYLE.md)
  with vsg.

For the boards, see [synth/](synth/README.md).

## The formal checks

`make formal` runs the SymbiYosys jobs in `formal/`, and CI runs it too.
It needs the tools of nice_cpu's formal checks: Yosys with the GHDL plugin,
SymbiYosys, and the Yices 2 solver. It is tested with the packages `yosys`,
`yosys-plugin-ghdl`, and `ghdl-gcc` of Ubuntu 24.04 (Yosys 0.33 and GHDL
4.1.0), SymbiYosys at its tag `yosys-0.33`, and Yices 2.6.4, as CI installs
them. Every input of each job is free, so the solver tries every input at
every time, not only the ones a testbench sends.

- `cli.sby` checks the command line interpreter, `line_buffer.vhd` and
  `cmd.vhd` together (`formal_cli.vhd`). It proves, for every cycle, that
  each of their valid/ready ports holds its data until it is taken, that a
  line and a message are never empty, that the bus request is one STB
  pulse after a line is taken, with CYC held until the ACK, and that each
  line gets one answer before the next line is taken.
- `rx_fifo.sby` proves the core's input FIFO, `src/rx_fifo.vhd`, with 4
  bytes: the bytes come out in the order they went in, a byte is lost only
  when the FIFO is full or the input has ended, no byte is written to the
  word being read, and the end of the input stays until reset.
- `nicemon.sby` checks the whole system, with 16 words of RAM whose
  contents are free, so that the solver runs every program. It is too
  large to prove, so it checks every cycle up to a depth: 30 cycles with
  the core running from reset, and 40 with the command line first, which
  is enough to type a command. It checks that the core's two buses get an
  ACK only for a request that waits, which is what nice_cpu's proof of the
  core assumes of them, that the command line's latched request is not
  overwritten and gets one ACK, that the devices answer only the latched
  request, and what a read of the console returns. Its tasks take 5 to 11
  minutes each; `make -j4 formal` runs all the tasks side by side, as CI
  does.

The checks in `cmd.vhd`, `line_buffer.vhd`, `rx_fifo.vhd`, and
`nicemon.vhd` are in `G_FORMAL` blocks, which are off in simulation and
synthesis.

## Testing the board

`tools/hwtest.py` tests the system on the board itself. It programs the
FPGA with `m65 -q` from mega65-tools and checks the `NICE` banner, and the
ROM when the bitstream has one. Then it hides the ROM and
uses the command line: it runs `sim/echo.nasm`, holds and restarts the core,
clears the memory, reads back what `sim/emu.nasm` leaves after its halt,
writes and reads the screen's registers, and runs
`examples/build/primes.bin`. Last, it runs programs with `run.py`
and with `niceemu`, whose output and exit status must be the same: among
them `sim/eof.nasm`, with no input and with 1536 bytes of input, which
checks the larger FIFO and the end of the input.
That needs niceemu, built with `make -C nice_cpu/emulator build`; without it
the comparison is skipped. Build the bitstream first, then:

    make hwtest

For the R3, give `BIT=synth/r3/build/top.bit`. A board that is already
programmed can be tested with `tools/hwtest.py --no-program`, which skips
the banner. The reset button is not tested: press it with a terminal open,
and `NICE` is printed again. A bitstream with a ROM can be tested when the
program in the ROM halts, as `sim/rom.nasm` does (`make r6
ROM=sim/build/rom.bin`, after `make test` has assembled it): the test hides
the ROM, as `load.py` does, and runs the programs from the RAM.

## License

MIT, see [LICENSE](LICENSE), like the files copied from cmod-s7 and
MandelbrotMEGA65. The exceptions are the third-party files named in
[synth/README.md](synth/README.md): `synth/r3/max10.vhd` is GPL v3, and the
HDMI output in `synth/common/hdmi/` is LGPL v3. The Spleen font in
`src/video/font_pkg.vhd` is BSD 2-Clause, see `font/LICENSE.spleen`.
