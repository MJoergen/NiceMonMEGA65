# NiceMonMEGA65

[![CI](https://github.com/MJoergen/NiceMonMEGA65/actions/workflows/ci.yml/badge.svg)](https://github.com/MJoergen/NiceMonMEGA65/actions/workflows/ci.yml)

The NICE CPU with a monitor, on the MEGA65

This project runs the [NICE CPU](https://github.com/MJoergen/nice_cpu) on the
MEGA65 board (R3 and R6), with a debug link on the UART: the protocol of
nice_cpu's [doc/DEBUG.md](nice_cpu/doc/DEBUG.md), which `niceemu --link`
speaks too. A monitor like
the one in [QNICE-FPGA](https://github.com/sy2002/QNICE-FPGA) is planned and
not written yet (see [monitor/](monitor/README.md)). The hardware for it is
there: a ROM at address 0, which the core boots from, and a screen with a
cursor and scrolling, laid out as QNICE-FPGA's. Until the monitor is
written, programs are loaded through the link, with the tools in `tools/`.

The MEGA65 is the main board. The system also builds for the Digilent
Nexys4DDR, with the UART and a USB keyboard for input, the UART for output,
and VGA for the screen, and with its LEDs, seven-segment display, buttons,
and switches as registers (see [synth/](synth/README.md#the-nexys4ddr) and
[The Nexys4DDR's devices](#the-nexys4ddrs-devices)).

## Contents

| Path | What it is |
|---|---|
| [nice_cpu/](https://github.com/MJoergen/nice_cpu) | The NICE CPU, its assembler, its emulator, and `nicewasm`, a [translator](https://github.com/MJoergen/nice_cpu/tree/main/translator) from WebAssembly to NICE assembly, as a git submodule. |
| [src/](src/) | The synthesizable VHDL, shared by both boards. `nicemon.vhd` is the system: the NICE core, the memory (`ram.vhd` and `rom.vhd`), the UART, the core's input FIFO (`rx_fifo.vhd`), and the debug link, nice_cpu's `hdl/src/debug_link.vhd`. `uart_serdes.vhd` is copied from [cmod-s7](https://github.com/MJoergen/cmod-s7), with fixes to its receiver, and break detection. `kbd_m65.vhd` drives the MEGA65 keyboard, and `kbd_ascii.vhd` turns its keys into ASCII. `kbd_ps2.vhd` receives the PS/2 keyboard of the Nexys4DDR, and `kbd_ps2_ascii.vhd` turns its scan codes into ASCII. `seg7.vhd` scans the Nexys4DDR's seven-segment display, and `rgb_pwm.vhd` dims its RGB LEDs. `system.vhd` is what every board has: the system, the text display of its screen, and the UART's pins. |
| [src/core/](src/core/) | `nice_core_pipeline.vhd` and `nice_core_multi.vhd`, the two architectures of `nice_core`. `src/nice_core.vhd` is the entity that wraps whichever of nice_cpu's cores `core.mk` selects with `NICE=pipeline` (the default) or `NICE=multi`. |
| [src/video/](src/video/) | The text display: `text.vhd` shows the screen at `0xFFFF0000` as 80×25 characters on a video output, with a cursor and a display offset for scrolling. `pix.vhd` and `video_pkg.vhd` are from [MandelbrotMEGA65](https://github.com/MJoergen/MandelbrotMEGA65). `scr_ram.vhd` is the screen's dual-clock memory. `font_pkg.vhd` is the [Spleen](https://github.com/fcambus/spleen) 16×32 font, made by `font/gen_font_pkg.py`. |
| [font/](font/) | The script that makes `src/video/font_pkg.vhd` from Spleen, and Spleen's license (BSD 2-Clause). |
| [sim/](sim/) | The GHDL testbenches. `text_synth.vhd` is the wrapper with which GHDL checks that the display synthesizes. |
| [formal/](formal/) | The formal checks, for SymbiYosys. |
| [synth/](synth/README.md) | The Vivado builds for the MEGA65 R3 and R6 boards, and the Nexys4DDR. |
| [monitor/](monitor/README.md) | The monitor, in NICE assembly: planned, not written yet. Its README has the decisions it will follow, QNICE-FPGA's. |
| [examples/](examples/) | Example C programs, and the Makefile that builds them for the MEGA65. |
| [tools/](tools/) | `nicelink.py`, the debug link over the board's UART, over TCP to `niceemu --link`, or over TCP to the simulated system of `make cosim`, and the tools that use it: `load.py`, which loads a program into the MEGA65 or Nexys4DDR, `run.py`, which runs a program on the board as `niceemu` runs it, `hwtest.py`, which tests the system on the board, `linktest.py`, which checks `run.py` on `niceemu --link`, and `cosimtest.py`, which checks `run.py` on the simulated system. |
| [EMULATOR.md](EMULATOR.md) | The table of the known differences from the emulator. |
| [TODO.md](TODO.md) | Work that is planned but not started. |
| [core.mk](core.mk) | Picks the source files of the core, from `NICE`, for the Makefiles of `sim/` and `synth/`. |
| [.claude/rules/synth.md](.claude/rules/synth.md) | Notes for Claude Code on the Vivado builds: where Vivado is, how to build, and what to check after a build. |
| [vsg.yml](vsg.yml) | The configuration of `make lint`, which checks the VHDL against [CODING_STYLE.md](CODING_STYLE.md). |
| [CLAUDE.md](CLAUDE.md) | Instructions for Claude Code: the commands, the layout, and the pitfalls. |
| [.github/workflows/ci.yml](.github/workflows/ci.yml) | The CI: `make test` and `make cosimtest` on both cores, with niceemu built for its step counts, `make examples`, `make linktest`, `make formal`, and `make lint`. It cannot run `make hwtest` or build a bitstream. |

## Compared with the emulator

The goal is a MEGA65 that runs NICE programs as `niceemu`, the emulator in
`nice_cpu/emulator`, runs them. It is close, but not there yet. The main
difference is the memory: 64K words, not 2³². [EMULATOR.md](EMULATOR.md)
has the table of the known differences. `tools/run.py` runs a program on
the board and prints what `niceemu` prints for it (see
[Comparing with the emulator](#comparing-with-the-emulator)).

## Getting started

Clone with the submodule:

    git clone --recurse-submodules https://github.com/MJoergen/NiceMonMEGA65.git

or, in an existing clone:

    git submodule update --init

`make` in the top directory lists the targets:

- `make test` runs the simulation tests.
- `make formal` runs the formal checks (see
  [The formal checks](#the-formal-checks)).
- `make lint` checks the VHDL style.
- `make examples` builds the C examples.
- `make r3`, `make r6`, and `make nexys4ddr` build the bitstreams. With
  `ROM=file.bin`, the core boots from the file (see [The ROM](#the-rom)).
- `make load FILE=prog.bin` loads a program into the board and starts it.
- `make run FILE=prog.bin` runs one as `niceemu` runs it (see
  [Comparing with the emulator](#comparing-with-the-emulator)).
- `make hwtest` tests the board (see [Testing the board](#testing-the-board)).
- `make linktest` checks the tools on `niceemu --link`, without a board
  (see [Comparing with the emulator](#comparing-with-the-emulator)).
- `make cosim` runs the system in GHDL for the tools, and `make cosimtest`
  checks the tools and the RTL on it, without a board (see
  [The simulated board](#the-simulated-board)).

`make load` and `make run` use the serial device `PORT=/dev/ttyUSB1` by
default, and pass `ARGS=` on to the tool, for example `ARGS=--no-run` or
`ARGS="-i in.txt -d 0:10 -s --timeout 5"`. `ARGS="--tcp 4000"` drives
`niceemu --link 4000` instead of the board, and `ARGS="--cosim 4000"` the
simulated system of `make cosim COSIM_PORT=4000`. The bitstream targets take
`FLOW=default` or `FLOW=timing`, the directives of Vivado's steps (see
[synth/](synth/README.md)). `make hwtest` rebuilds `niceemu` first, if its
sources have changed.

`make test` and the boards' targets use nice_cpu's pipelined core. Add
`NICE=multi` to use its multi-cycle core instead (`NICE=pipeline` is the
default). The simulation of each core is built in `sim/build/pipeline` or
`sim/build/multi`, and both cores run the same tests. The bitstream goes to
`top.bit` in either case, so build one core at a time. The system clock is
set for the pipelined core, so the multi-cycle core has room to spare.

## Using it

The MEGA65's debug UART runs at 2 Mbaud (2000000), 8-N-1, and carries the debug
link of nice_cpu's [doc/DEBUG.md](nice_cpu/doc/DEBUG.md). It passes the
program's console bytes both ways, and between them it carries packets,
which start with the byte `0xFF`. A console byte `0xFF` is sent as two. With
the packets, a host reads and writes memory and the debug registers at
`0xFFFFFFE0`–`FF` (see [Address map](#address-map)). The board sends a
notice at reset (`b01`), when the core halts (`h` and the reason), and when
an input byte is lost (`o`). The tools in `tools/` are such a host, and
`niceemu --link` serves the same link, so the tools drive the emulator as
they drive the board.
The tools use 2 Mbaud too. A bitstream built before the rate went up runs
at 115200 baud, and the tools need `--baud 115200` for it.

The core is held in reset at power-up. A host loads a program with two
writes to the control register at `0xFFFFFFF0` around the writes of its
words. `0x0000000D` holds the core, clears the memory, and hides the ROM,
and `0x00000008` starts the core with the ROM still hidden (see
[The ROM](#the-rom)). A start without bit 3 shows the ROM again, which
boots instead of the program. `tools/load.py` does all of this.

While the core runs, the link reaches only its debug registers, and a
request for any other word gets the error answer `e` with code 02. A write
to the control register that holds the core works at any time, so a host
can always stop a program. While the core is held or has halted, the link
reaches the whole address map.

A terminal on the UART shows what the program prints, and what you type
goes to the program while it runs. Bytes typed while the core is held or
has halted are dropped. The notices show up in the terminal too, as a few
letters after a stray character, such as `h01#C9` after a `HALT`.

### The keyboard

The MEGA65's own keyboard types into the same input as the UART: what you
type goes to the program while it runs, and is dropped while the core is
held or has halted. The program's output comes out on the UART. The keys
give ASCII, as a terminal sends it:

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

On the Nexys4DDR, a USB keyboard in the board's USB HID port types into the
same input (the board's PIC24 turns it into PS/2). Its keys give the same
bytes, for a US layout: Enter is CR, Backspace and Delete are DEL, the
cursor keys are `ESC [ A` to `ESC [ D`, and CTRL with a letter is its
control code. The keypad gives its digits and symbols, whatever Num Lock
is. A held key repeats as the keyboard repeats it. The keyboard's LEDs are
not set, so the CAPS LOCK LED does not show whether CAPS LOCK is on. A PS/2
keyboard can't wait, so keys typed while the core's input is full are
lost: the bytes of one key wait until there is room, and the keys typed
meanwhile give nothing. The MEGA65's keyboard loses no key.

### Running a program

A program is assembled with the assembler of the nice_cpu submodule, and
loaded with `tools/load.py`, which holds the core, hides the ROM if there is
one, clears the memory, writes the words with `W` packets, and then starts
the core. For
example, with `sim/echo.nasm`, which echoes what you type until a `.`:

    python3 nice_cpu/assembler/niceasm.py -o echo.bin sim/echo.nasm
    tools/load.py echo.bin
    picocom -b 2000000 /dev/ttyUSB1

`load.py` uses the serial device `/dev/ttyUSB1`, the MEGA65's debug UART.
If yours is another, give it with `--port`, and to picocom. On macOS, use
the `/dev/cu.*` device, as a `/dev/tty.*` device blocks on open.
`load.py` needs only Python 3, on Linux or macOS, and the port must not be
open in a terminal while it runs. Type in the terminal and the program echoes
it. When you type `.`, it halts, and the board sends its halt notice.

The `.bin` file has one line per word, the address and the word in hex.
`load.py --no-run` loads the program and leaves the core held.
`load.py --tcp PORT` loads it into `niceemu --link PORT` instead of the
board, and `load.py --cosim PORT` into the simulated system of `make cosim`.

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

C goes through WebAssembly, with the tools of the nice_cpu submodule: clang
compiles the program to a wasm module and links it with nice_cpu's C
library, `nicewasm` translates the module to NICE assembly, and `niceasm`
assembles it together with the start-up code and the runtime library.
`examples/Makefile` does all of it. For the prime counting example,
`examples/primes.c`:

    make -C examples

That builds `examples/build/primes.bin`. Load it and open a terminal:

    tools/load.py examples/build/primes.bin
    picocom -b 2000000 /dev/ttyUSB1

The program asks for a limit, reads it with `scanf`, and counts the primes
up to it. It asks again until you enter 0, and then halts. The program does
not echo what you type, so the number shows only after you press Enter:

    Count the primes up to (0 to stop): 1000
    Primes up to 1000: 168
    36731 instructions in 58159 cycles

The second line comes from the performance counters, and the numbers are
from the board with the pipelined core, where the 58159 cycles at 100 MHz
take about 0.58 ms.

`make -C examples` also builds `examples/build/bench.bin` from nice_cpu's
benchmark, `nice_cpu/bench/bench.c`. It runs six phases, each a known
kernel, and prints the instructions and cycles of each, its result, and
whether that is the expected one. It reads no input, so `tools/run.py`
runs it:

    tools/run.py examples/build/bench.bin

The instructions are the same as on the emulator. The cycles are from the
board with the pipelined core, beside those of nice_cpu's own testbench
for the core (`bench/README.md`, with the core at nice_cpu 1a41b0c):

| Phase | Instructions | Cycles on the board | In nice_cpu's testbench |
|---|---|---|---|
| `rng64` | 52768 | 83082 | 83082 |
| `crc32` | 65816 | 83067 | 83067 |
| `bst` | 310469 | 415028 | 416052 |
| `heapsort` | 307416 | 387338 | 387338 |
| `vm` | 840049 | 1248168 | 1248168 |
| `strings` | 104562 | 166928 | 166928 |
| total | 1681080 | 2383611 | 2384635 |

The board takes the same cycles, or 1024 fewer in `bst`, and at 100 MHz
the benchmark runs for about 24 ms.

You need clang with the wasm32 target, `wasm-ld`, and `llvm-ar` (on Debian
and Ubuntu, the `clang`, `lld`, and `llvm` packages). The steps that the
Makefile runs are those of `nice_cpu/runtime/README.md`:

    make -C nice_cpu/runtime/libc libc.a
    clang --target=wasm32 -mbulk-memory -O2 -ffreestanding -nostdlibinc \
        -isystem nice_cpu/runtime/libc/include -nostdlib \
        -Wl,--no-entry -Wl,--export=main -Wl,--stack-first \
        -Wl,-z,stack-size=4096 -Wl,--initial-memory=65536 \
        -o primes.wasm examples/primes.c nice_cpu/runtime/libc/libc.a
    nice_cpu/translator/nicewasm.py -o primes.nasm primes.wasm
    cat nice_cpu/runtime/start_wasm.nasm primes.nasm nice_cpu/runtime/lib.nasm \
        nice_cpu/runtime/muldiv_mpu.nasm > primes_full.nasm
    nice_cpu/assembler/niceasm.py -o primes.bin primes_full.nasm

With plain `start_wasm.nasm`, a wasm trap, such as an access outside the
linear memory, halts the core without a word, and only `run.py --symbols`
shows the trap. `nice_cpu/translator/nicebuild.py -o primes.bin
examples/primes.c` does all of these steps in one command, and by default
it joins the trap report instead: `start_wasm_trap.nasm` at the start and
`trapmsg.nasm` at the end. Then a trap prints a line such as `trap 2: out
of bounds memory access at 00003dc9` before the core halts. The Makefile
keeps the plain start, so that `bench.bin` is laid out as in nice_cpu's
testbench, and its cycles compare with those above.

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
`scanf`, the prime example ends at word `0x634F`. The translator's README,
`nice_cpu/translator/README.md`, has the same steps for Zig and Rust.

### The screen

The screen at `0xFFFF0000` is shown on the VGA connector and on the HDMI
connector, at 1280×1024 and 60 Hz, as 80 columns and 25 rows of
characters of 16×32 pixels, in the middle of the picture. Word `80 * row +
column` is one character: its code, ISO 8859-1, in bits 7..0, and its
color above. The color is two 12-bit colors, red, green, and blue with 4
bits each, as in nice_cpu's `doc/SYSTEM.md` §1: the background in bits
31..20 and the foreground in bits 19..8. A component `n` gives the byte
`n × 0x11`, so `0xF` is full intensity and `0x0` is none. The foreground is
not inverted, as it is in the 2004 IDE. So a word with only a character,
such as `0x41`, is black on black, and `0x000FFF41` is a white `A` on
black. The screen is 0 at power-up, which shows as black, and
`nice_screen_clear` fills it with blanks.

The screen's memory is 32768 words, `0xFFFF0000`–`0xFFFF7FFF` (8192 words,
`0xFFFF0000`–`0xFFFF1FFF`, on the Nexys4DDR), of which the
display shows 2000 from the display offset, so a program scrolls by adding
80 to the offset and writing the next row after the rows shown, and scrolls
back by taking 80 away, as the QNICE monitor does. The offset wraps at the
end of the memory. The display also has a cursor, which swaps the colors
of its character. The registers are numbered as the VGA registers of
QNICE-FPGA, at `0xFF30` there:

| Address | Register |
|---|---|
| `0xFFFFFF80` | State. Bit 6 shows the cursor, bit 5 makes it blink, about twice a second, bit 4 makes it small, the bottom 4 lines of the character, and bit 10 enables the display offset. Bits 11..4 are kept and read back; the rest read 0. |
| `0xFFFFFF81` | The cursor's column, 0 to 79. |
| `0xFFFFFF82` | The cursor's row, 0 to 24. |
| `0xFFFFFF85` | The display offset, in words, 0 to 32767 (8191 on the Nexys4DDR). It takes effect when bit 10 of the state is set. |

The words `0xFFFFFF83`, `84`, and `86`–`8F` read 0 and take no write. In
the emulator these addresses are memory, so a program that writes them
runs there too, without scrolling. Reset, and the clear of the memory
(bit 2 of the control register, which `load.py` and `run.py` set),
set the offset to 0 and turn the cursor off, as at the start of the emulator.

A write of `0x000FFF41` to `0xFFFF0000` puts an `A` in the top left
corner, white on black, and one of `0xF00FFF42` to `0xFFFF0001` a white `B`
on red next to it.

The video output comes from MandelbrotMEGA65, which uses the same mode on
the MEGA65. The HDMI output is DVI, without sound.

### The ROM

A bitstream built with `make r6 ROM=file.bin` (or `make r3 ...`) has a ROM
of 32K words at `0x0000`–`0x7FFF`, in front of the RAM, with the words of the
`.bin` file, and its core boots from it at reset instead of waiting held for
a host. That is the layout of QNICE-FPGA, whose monitor is in ROM at
`0x0000`–`0x7FFF` and whose programs load at `0x8000`, and it is where the
monitor will go. The file is read by Vivado, so the ROM changes only with a
new bitstream, and a word beyond the ROM fails the build. A write to the
ROM is dropped, and a clear (bit 2 of the control register) does not
touch it. So a program in the ROM must keep its stack and its variables
in the RAM, at `0x8000` or above: `sim/rom.nasm`, the greeting that the
tests use as the ROM, has its stack at the top of the memory, as the
runtime has. With a stack in the ROM, as `hello.nasm` of nice_cpu has at `0x1000`, a pushed return address
is lost and reads back as 0, and the program starts over, forever.

While the core runs from the ROM, the link reaches only its debug
registers. Bit 3 of the control register hides the ROM: a write of
`0x00000009` holds the core with the ROM hidden, and the RAM is at address
0, as in the emulator, so a program loads and runs as without a ROM, with
`0x00000008` to start it. `load.py` does this. `0x00000001` and then
`0x00000000` show the ROM again and boot from it, as the reset button does. The RAM under the ROM keeps its
words meanwhile.

### The Nexys4DDR's devices

The Nexys4DDR's LEDs, seven-segment display, buttons, and switches are
registers in `0xFFFFFF90`–`96`, for the core and the link alike.
Only the Nexys4DDR has them: on the MEGA65 the whole block reads 0 and
takes no write, where the emulator has memory there. Reset clears the registers
that can be written, and a start of the core does not, so a program's
display stays after it halts.

| Address | Access | What it is |
|---|---|---|
| `0xFFFFFF90` | Read, write | The 16 LEDs, bit n for LED n. LED0 is also on while the core runs. |
| `0xFFFFFF91` | Read, write | RGB LED 0: bits 11..8 red, 7..4 green, 3..0 blue, each a level from 0 (dark) to 15. Bits 31..12 read 0 and are dropped. |
| `0xFFFFFF92` | Read, write | RGB LED 1, in the same way. |
| `0xFFFFFF93` | Read, write | The segments of digits 3..0, a byte each, digit 0 (the rightmost) in bits 7..0. |
| `0xFFFFFF94` | Read, write | The segments of digits 7..4, in the same way, digit 4 in bits 7..0. |
| `0xFFFFFF95` | Read only | The five buttons: bit 0 the center one, then up, left, right, and down (bits 1 to 4). 1 when pressed. |
| `0xFFFFFF96` | Read only | The 16 switches, bit n for switch n. 1 when the switch is up. |

The seven-segment display takes the segments as raw bits, so a program
brings its own font. In each byte, bit 0 is segment A, bit 1 B, and so on
up to bit 6 for G, and bit 7 is the decimal point; a 1 lights it, and a
byte of 0 leaves the digit dark. `0x0000006D` in `0xFFFFFF93` lights segments
A, C, D, and F, which shows a 5 on digit 0. The display is scanned at about
1 kHz per digit, so the digits look steady. The RGB LEDs are very bright at
full level; 1 to 3 is a comfortable range. The buttons and the switches are
synchronized to the clock but not debounced. The CPU RESET button is not a
register: it resets the system. The words `0xFFFFFF97`–`9F` read 0 and take
no write; the keyboard's LEDs may come to `0xFFFFFF97` (see
[TODO.md](TODO.md)).

### Address map

The link and the core's data accesses see the same addresses, but for the
debug registers at `0xFFFFFFE0`–`FF`, which only the link sees, and the
console and the read counter, which the link reads as 0 without a side
effect and does not write (DEBUG.md §3).

| Address | What it is |
|---|---|
| `0x00000000`–`0xFFFFFFFF` | Memory, where no register below is: 64K words of block RAM, repeated through the address space. So the runtime's stack below `0xFFFFFF00` lands in the top of it, and so do the words of `0xFFFFFF00`–`FF` that are not registers. |
| `0x00000000`–`0x00007FFF` | The ROM, in a bitstream built with one, in front of the RAM and repeating with it (see [The ROM](#the-rom)). Bit 3 of the control register hides it. |
| `0xFFFF0000`–`0xFFFF7FFF` | The screen: 32768 words of memory of their own, the emulator's 80×25 screen and room for scrolling. The 2000 words from the display offset are shown on VGA and HDMI, or VGA only on the Nexys4DDR (see [The screen](#the-screen)), and the link reads them all. |
| `0xFFFFFF00` | The console of SYSTEM.md §1. A write sends bits 7..0 to the UART. A read takes the oldest byte received from the UART or the keyboard, and returns it in bits 7..0 with bit 8 set, or 0 when no byte has arrived. A break on the UART ends the input: once the bytes before it are read, a read returns `0x200` (bit 9), as at the end of the emulator's input, until the core is started again. |
| `0xFFFFFF01` | The emulator's read counter. A read by the core returns the number of its reads since the last write, and a write sets that number. It is 0 after reset, and a start keeps it, as in the emulator. |
| `0xFFFFFF10`–`0xFFFFFF1F` | The timer of SYSTEM.md §4: it raises IRQ every P clock cycles, through the vector it is given. |
| `0xFFFFFF20`–`0xFFFFFF3F` | The math unit of SYSTEM.md §2: 32-bit multiply and divide, and 64-bit divide. |
| `0xFFFFFF40`–`0xFFFFFF4F` | The performance counters of SYSTEM.md §3: cycles, instructions, and microseconds, 64 bits each. The microseconds come from the clock, 100 MHz on the MEGA65 and 90 MHz on the Nexys4DDR, so they are real time, where the emulator counts one per step. The link reads them as the core does: a read of a low word takes the snapshot that the high word returns, where `niceemu --link` takes none. DEBUG.md §3 allows both. The words `0xFFFFFF46`–`4F` read 0 and take no write. |
| `0xFFFFFF50`–`0xFFFFFF7F` | The fetch statistics of MICROARCH.md §8.1, the rest of the performance counters: counters of what FETCH and DECODE do, for judging the size of FETCH's buffer. A start of the core clears them, and they then count each clock while the core runs, until a write of 0 to `FS_CTRL` stops them. They stop while the core is held and after it halts. |
| `0xFFFFFF80`–`0xFFFFFF8F` | The screen's registers: the cursor and the display offset (see [The screen](#the-screen)). |
| `0xFFFFFF90`–`0xFFFFFF9F` | The Nexys4DDR's LEDs, seven-segment display, buttons, and switches (see [The Nexys4DDR's devices](#the-nexys4ddrs-devices)). On the MEGA65 they read 0 and take no write. |
| `0xFFFFFFE0`–`0xFFFFFFEF` | The debug registers of DEBUG.md §6, for the link only, here and below: R0–R15 of the core, read only. After a halt they hold what the emulator prints. A hold leaves them undefined. |
| `0xFFFFFFF0` | Control. Bit 0 holds the core in reset. Bit 1, read only, is 1 after a halt, and stays 1 while the core is held, until the next start. A write with bit 2 set first clears the RAM and the screen to 0, with the core held, and is answered when the memory is clear, after 0.66 ms at 100 MHz. Bit 3 takes effect when the clear starts, and bit 0 when it ends. Bit 3 hides the ROM, so that the RAM is at 0; reset clears it in a bitstream with a ROM, and in one without it reads 1. |
| `0xFFFFFFF1` | Read only: why the core halted. 0 while it has not, 1 for `HALT`, 2 for a reserved control word, 3 for `INT` inside an interrupt routine, and 4 for `RTI` outside one. |
| `0xFFFFFFF2` | Read only: the version of the link, 1. |
| `0xFFFFFFF3` | Read only: the bytes of free space in the core's input FIFO. |

Instruction fetches from `0xFFFFFF00`–`0xFFFFFFFF` read 0, as ISA.md §8.3
requires. The input waits for the core in a FIFO of 2048 bytes, in block
RAM. A UART byte that arrives when it is full is lost, and the link sends
its `o` notice; a byte after a break is lost too, until a start clears the
end of the input. A keyboard byte waits until the FIFO has room for two, so
that a UART byte still finds room; on the Nexys4DDR, keys typed meanwhile
are lost (see "The keyboard"). While the core is held or has halted,
the bytes of the UART and the keyboard are dropped. To end a program's
input from a terminal, send a break: in picocom, `Ctrl-A Ctrl-\`.
The performance counters, the math unit, and the timer are nice_cpu's own,
`nice_cpu/hdl/src/perf.vhd`, `mpu.vhd`, and `timer.vhd`, and behave as the
emulator's. The fetch statistics are nice_cpu's `fetch_stats.vhd`, which
the emulator does not have. They are reset with the system, and each time the core starts, as
the emulator's are when it starts. So after a halt the instruction counter
holds the steps that the emulator prints, unless the program starts the
timer. The timer counts clock cycles, at 100 MHz (90 MHz on the Nexys4DDR),
where the emulator counts steps, so its interrupts come at other steps, and
the step counts differ. The cycle counter and the timer's counter run only
while the core runs, so they stop at a halt, as the emulator's do.
The timer's request goes straight to the core's IRQ, for it is the only device that
raises one. They are not reset while the link holds the core, so the link
reads them after a halt.

## Comparing with the emulator

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
`make linktest` does this for the programs that `make hwtest` compares, and
nice_cpu's benchmark, with `tools/linktest.py`, and CI runs it. It runs
hwtest's checks of bad packets on `niceemu --link` first.
`--cosim PORT` runs the program on the simulated system of `make cosim`
(see [The simulated board](#the-simulated-board)).
`-2004` prints the screen from `0x400`, as `niceemu -2004` does. That is
plain RAM on the board, not the screen that the display shows.
`run.py` accepts `--no-cycle-counter` and ignores it, as the cycle counter
always runs.
`--symbols FILE` reads the labels that `niceasm.py --symbols` writes, and
after a halt other than `HALT` prints where the program was, `At
label+0x1f`, if the file has any labels, and after a halt at `___wasm_trap`, the default wasm trap
handler, the trap's code and location from R1 and R2, as `niceemu` does. At
the time limit it prints no location, as there are no registers.
A missing or unreadable input file, `.bin` file, or serial device stops
`run.py` with a message before it touches the core, and so does an input
file that is a directory. A usage error, such as an unknown option, exits
with status 1, as in `niceemu`. Each option must stand alone, with its value
as the next argument, so `--sym`, `--dump=1:2`, `-d1:2`, and `-sd` are
errors in both. When stdout closes early, as with `run.py ... | head`,
`run.py` exits quietly with status 141, as `niceemu` does.

The step count is the core's instruction counter. The emulator's steps
include interrupt entries, and the instruction counter does not, so a
program with interrupts has more steps in the emulator. A read of the console
in the emulator waits for the next byte, but on the board it returns 0
while no byte has arrived. So a program that waits for input in a loop runs
more steps on the board, and its step count differs. The memory is 64K
words, repeated through the address space, so `-d` beyond them shows the
same words again.

## Running the tests

You need GHDL (tested with 4.1.0) and Python 3, and gcc for `make cosim`.

    make -C sim test

- `sim/tb_hello.vhd` runs a "Hello" program on the NICE core from the
  submodule, and checks its console output.
- `sim/tb_nicemon.vhd` drives the whole system through its UART, as a host
  of the debug link, with `sim/rom.nasm`, a greeting, as the ROM: the core
  boots from it at reset, the ROM is read only with the RAM above it, and
  bit 3 of the control register hides it and shows it again. It checks its
  checksums against the examples of DEBUG.md, and the board's `b` notice.
  With the ROM hidden, it loads the "Hello" program over the link and runs
  it. It checks the halt notice, the halt reason, and the step count, which
  must equal
  niceemu's, and that the microsecond counter matches the cycle counter at
  its clock of 90 MHz. Then it loads and runs these programs:
  - `sim/echo.nasm` echoes what it receives.
  - `sim/fifo.nasm` checks the input FIFO, which has 16 bytes there, so
    that the test of a full FIFO is short.
  - `sim/devices.nasm` uses the math unit, the performance counters, and
    the timer's interrupts. The testbench also uses the math unit over the
    link.
  - `sim/emu.nasm` checks the screen, the read counter, memory in the I/O
    range, and the registers after a halt, and writes and reads the
    screen's registers.
  - `reserved.nasm` of the emulator's tests halts on a reserved control
    word, after the testbench has cleared the memory.
  - `sim/counters.nasm` reads the fetch statistics, the microsecond
    counter, and the board's registers through the core's data bus. A start
    clears the fetch statistics, and with the multi-cycle core every cycle
    counts as one with no word in the buffer.
  - `sim/eof.nasm` echoes its input until a break ends it.
  - `sim/count.nasm` reads the read counter, which a start keeps.

  It also checks the error answers while the core runs, the `o` notice when
  the FIFO overflows, and that the link reads the console and the read
  counter as 0 and does not write them. Between the programs, the
  testbench writes and reads the board's registers, and checks that a clear
  of the memory and a start keep them. Then it types on the keyboard input,
  which is dropped while the core is held, and input for `sim/fifo.nasm`
  while it runs. Last it resets the system while a program runs, and checks that
  the core boots from the ROM again and that the screen's and the board's
  registers are cleared.
- `sim/tb_kbd.vhd` tests the keyboard driver and its ASCII, with a model of
  the keyboard.
- `sim/tb_ps2.vhd` tests the PS/2 receiver and its ASCII, with a model of a
  PS/2 keyboard, and checks that bad and broken frames are dropped.
- `sim/tb_ps2_nicemon.vhd` types on that model into the system, wired as
  the Nexys4DDR wires it. Keys typed while the core is held are dropped,
  `sim/fifo.nasm` echoes the keys typed, and `sim/switch.nasm`, which reads
  no input until switch 0 is on, lets the UART fill the core's input. Then
  one key waits, the keys typed after it are lost, and the keyboard works
  again once the program reads.
- `sim/tb_text.vhd` fills the screen of the text display and checks every
  pixel of one 1280×1024 frame, and the sync pulses; then it scrolls the
  display one row, shows the cursor, and checks the first four rows of the
  next frame. It takes under a minute, the longest of the tests.
- `sim/tb_board_io.vhd` tests the Nexys4DDR's drivers of its seven-segment
  display and RGB LEDs: every digit of the display lit in turn with its own
  segments, and the duty of an RGB output at its level.
- `make test` also checks that GHDL can synthesize the system, with
  `sim/rom.nasm` as its ROM and without a ROM, the keyboards, the text
  display, and `src/system.vhd` with the screen and the devices of the
  Nexys4DDR, and the drivers of its display and RGB LEDs.
- `make -C sim check-steps`, part of `make test`, compares the step counts
  that `tb_nicemon` checks with those of niceemu. It is skipped when niceemu
  is not built.
- `make -j test` runs all these side by side, in the time of `tb_text`.
  Each is also a target of `sim/Makefile`, so `make -C sim tb_kbd` runs one.
- `make lint` checks the VHDL against [CODING_STYLE.md](CODING_STYLE.md)
  with vsg.

For the boards, see [synth/](synth/README.md).

### The simulated board

`make cosim` runs the system in GHDL, with its debug UART on a TCP port of
127.0.0.1, until you stop it with Ctrl-C. The tools reach it with
`--cosim PORT` as they reach the board, so they drive the RTL without a
board:

    make cosim COSIM_PORT=4000 &
    tools/run.py --cosim 4000 prog.bin

It prints `cosim: port N`, and without `COSIM_PORT` it takes any free
port. `ROM=file.bin` gives it a ROM, and `NICE=multi` the multi-cycle core.
It has the board's memory, screen, and input buffer, a clock of 10 MHz,
and its UART runs at 1 Mbaud. `sim/cosim/cosim.c` serves the port, and
`sim/cosim/tb_cosim.vhd` drives the UART.

The connection is the UART line, as a USB serial adapter is. It sends no
`b` notice, and a new connection resets nothing. A half-close or a close
of the connection is a break, which ends the program's input. One host is
served at a time. Another host waits until the first has half-closed or
closed.

The simulation is far slower than real time, about 250 bytes a second on
the UART. A short request takes a fraction of a second, a clear of the
memory about 4 s, and a load of 1000 words about 40 s. So `nicelink.py`
waits longer for an answer there: 20 s, and 20 ms more for each byte of
the request. Only small programs are practical.

`make cosimtest` starts `make cosim` on a free port. It runs hwtest's
checks of bad packets on it, but for the gap of 300 ms, which is far
shorter in simulated time. Then it runs the programs that `make hwtest`
compares, with `run.py --cosim` and with `niceemu`, whose output and exit
status must be the same. It leaves out nice_cpu's benchmark, which would
take too long. It takes about 4 minutes, and CI runs it on both cores.

## The formal checks

`make formal` runs the SymbiYosys jobs in `formal/`, and CI runs it too.
It needs the tools of nice_cpu's formal checks: Yosys with the GHDL plugin,
SymbiYosys, and the Yices 2 solver. It is tested with the packages `yosys`,
`yosys-plugin-ghdl`, and `ghdl-gcc` of Ubuntu 24.04 (Yosys 0.33 and GHDL
4.1.0), SymbiYosys at its tag `yosys-0.33`, and Yices 2.6.4, as CI installs
them. Every input of each job is free, so the solver tries every input at
every time, not only the ones a testbench sends.

- `rx_fifo.sby` proves the core's input FIFO, `src/rx_fifo.vhd`, with 4
  bytes: the bytes come out in the order they went in, a byte is lost only
  when the FIFO is full or the input has ended, no byte is written to the
  word being read, and the end of the input stays until reset.
- `nicemon.sby` checks the whole system, with 16 words of RAM and
  a free core, `formal/nice_core_formal.vhd`. The free core does anything
  that either of nice_cpu's cores may do on its ports, as nice_cpu's own
  formal checks state it, so the system is checked against both cores,
  and the solver spends no time on a real core. The debug link is free
  too, `formal/debug_link_formal.vhd`: it does anything that nice_cpu's
  `debug_link.vhd` may do on its ports, as the header of that file
  promises and nice_cpu's `hdl/formal/debug_link.sby` proves, and makes a
  request in any cycle. The job is too large to
  prove, so it checks every cycle up to a depth: 30 cycles with the core
  running from reset, and 40 with the core held for the link first. These
  have no ROM and no board registers. The `rom` and `rom_cover` tasks are
  `run` and `cover` with both: a ROM of 4 words, `formal/rom.bin`, and the Nexys4DDR's
  registers at `0xFFFFFF90`–`9F`. It checks these properties:
  - The core's two buses get an ACK only for a request that waits, which
    is what nice_cpu's proofs of the cores assume of them, also when the
    link holds a running core.
  - The link's requests are taken only while the core is held or has
    halted, and each gets one ACK.
  - A link access to the console or the read counter returns 0 and changes
    nothing.
  - A clear of the memory is answered once.
  - The devices answer only the link's request or one of the core, which
    gets one ACK at a time.
  - What a read of the console returns.
  - A read of the ROM returns its word, and only the clear writes the RAM
    under the ROM while the ROM is shown.
  - The board's registers change only on a write to their own word, and a
    read of `0xFFFFFF90`–`9F` returns the register, or 0 for a word that
    is not one.

  The `link` and `rom` tasks take about 14 minutes each, and the others a
  few each;
  `make -j formal`
  runs all the tasks side by side. CI runs `make -j4 formal` on its four
  processors.

The checks in `rx_fifo.vhd` and `nicemon.vhd` are in `G_FORMAL` blocks, which are off in simulation and
synthesis.

## Testing the board

`tools/hwtest.py` tests the system on the board itself. First it finds the
board from its UART: the JTAG cable on the same USB device as the port. It
reads the FPGA's IDCODE through that cable with
[openFPGALoader](https://github.com/trabucayre/openFPGALoader), and stops
unless the FPGA is the part the bitstream was built for. So with a MEGA65 and
a Nexys4DDR both attached, it never programs the wrong one. It programs the
FPGA through that cable alone, with openFPGALoader too, on every board, and
checks the link's `b` notice, and the ROM when the bitstream has one. Then
it hides the ROM and uses the link: it writes and reads memory, checks
that the link drops a packet with a bad checksum, one cut short by an ESC,
and one with a gap of 300 ms, that `nicelink.py` sends a dropped `R` or `W`
again, and that an unknown tag gets `e01` and a bad payload `e03`, runs
`sim/echo.nasm`, checks that the link reaches only its debug registers
while the core runs, holds and restarts the core, clears the memory, reads back what `sim/emu.nasm` leaves
after its halt, writes and reads the screen's registers, and runs
`examples/build/primes.bin`. Last, it runs programs with `run.py` and with
`niceemu`, whose output and exit status must be the same: among them
`sim/eof.nasm`, with no input and with 1536 bytes of input, which checks the
larger FIFO and the end of the input, the intro's `hello.nasm` with 100
lines of input that it halts without reading, the emulator's `trapsym.nasm` with
`--symbols`, and `examples/build/bench.bin`, but for its cycles, whose table
it prints. That needs niceemu, built with `make -C
nice_cpu/emulator build`. Without it, the checks that need it are skipped,
and the last line names them after a `SKIPPED`. Build the bitstream first,
then:

    make hwtest

It prints one line for each check, and last how many passed. A check that
leaves the board in a state in which every later check would fail stops
the run. Even then the script holds the core with the ROM hidden, and
prints how many passed. If the link does not answer then, it says so:
press the reset button. Programming the FPGA needs Linux, as the JTAG
cable is found through `/sys`; with `--no-program` the script runs wherever
`load.py` does. With the pipelined core, all 78 pass on the R6, and all 94
on the Nexys4DDR, which has more checks, for its LEDs, display, buttons,
and switches.

For the R3, give `BIT=synth/r3/build/top.bit`. For the Nexys4DDR, give
`BIT=synth/nexys4ddr/build/top.bit`. Its UART is usually `/dev/ttyUSB1` too.
With both boards attached, the `ttyUSB` numbers depend on the order they were
plugged in, so name the port by the cable's serial number, as in
`PORT=/dev/serial/by-id/usb-Digilent_Digilent_USB_Device_<serial>-if01-port0`.
A board that is already programmed can be tested with `tools/hwtest.py
--no-program`, which skips the `b` notice. The reset button is not tested:
press it with a terminal open, and the `b01` notice comes again. A
bitstream with a ROM can be tested, such as one with `sim/rom.nasm`
(`make r6 ROM=sim/build/pipeline/rom.bin`, after `make test` has assembled
it): the test holds the core and hides the ROM, as `load.py` does, and runs
the programs from the RAM.

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
