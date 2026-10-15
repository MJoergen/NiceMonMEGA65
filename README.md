# NiceMonMEGA65
The NICE CPU with a monitor, on the MEGA65

This project runs the [NICE CPU](https://github.com/MJoergen/nice_cpu) on the
MEGA65 board (R3 and R6), with a monitor like the one in
[QNICE-FPGA](https://github.com/sy2002/QNICE-FPGA) and a command line
interpreter on the UART like the one in
[cmod-s7](https://github.com/MJoergen/cmod-s7).

## Contents

| Path | What it is |
|---|---|
| [nice_cpu/](https://github.com/MJoergen/nice_cpu) | The NICE CPU, its assembler, and its emulator, as a git submodule. |
| [src/](src/) | The synthesisable VHDL, shared by both boards. `nicemon.vhd` is the system: the NICE core, the memory, the UART, and the command line interpreter. `uart_serdes.vhd`, `line_buffer.vhd` and `cmd.vhd` are copied from cmod-s7; `cmd.vhd` prints `NICE` instead of `WBUS` at reset. |
| [sim/](sim/) | The GHDL testbenches. |
| [synth/](synth/README.md) | The Vivado builds for the R3 and R6 boards. |
| [monitor/](monitor/README.md) | The monitor, in NICE assembly. |
| [examples/](examples/) | Example C programs, and the Makefile that builds them for the MEGA65. |
| [tools/](tools/) | `load.py`, which loads a program into the MEGA65 through the UART. |

## Compared with the emulator

The goal is a MEGA65 that runs NICE programs as `niceemu`, the emulator in
`nice_cpu/emulator`, runs them. **It is close, but not there yet.** The
core, the address map, and the devices behave as in the emulator, and the
command line reads back what the emulator prints after a halt. The main
difference is the memory: 64K words, not 2³².

| Feature | Emulator | MEGA65 | Same? |
|---|---|---|---|
| Instruction set | ISA.md | nice_cpu's `multicycle.vhd`, which nice_cpu's tests compare with the emulator | Yes |
| Console output, `0xFFFFFF00` | stdout | UART | Yes |
| Console input, `0xFFFFFF00` | stdin, with bit 8 set; `0x200` at the end | UART, with bit 8 set, through a 16-byte FIFO; never ends | Yes, but bytes beyond 16 unread ones are lost, and `0x200` never comes |
| Math unit, `0xFFFFFF20`–`3F` | Computed on read | nice_cpu's `mpu.vhd`, which stalls the read until the result is ready | Yes |
| Performance counters, `0xFFFFFF10`–`1F` | One cycle per step | nice_cpu's `perf.vhd`, counting clock cycles at 50 MHz | Instructions yes; cycles count real clocks |
| Instruction fetches from `0xFFFFFF00`–`FF` | Read 0 | Read 0 | Yes |
| Memory | All 2³² words | 64K words, repeated through the address space; the stack at `0xFFFFFF00` lands in the top | No: a program, its data, and its stack must fit in 64K words |
| Screen, `0xFFFF0000`–`07CF` | 80×25 words of memory, printed by `--screen` | 2048 words of memory of their own, read with `R`; nothing displays them | Yes, but not displayed |
| Read counter, `0xFFFFFF01` | Counts the data reads since the last write | The same; a read by the command line does not count, as `--dump` does not | Yes |
| The rest of `0xFFFFFF02`–`FF` | Ordinary memory for data | Memory, in the top 256 words of the RAM | Yes |
| Interrupts | Only from `--irq` and `--nmi` | None raised | Yes: no device raises them in either |
| After `HALT` | Prints the registers and exits with a status | The command line gets the UART back; `R FFFFFFE0` to `R FFFFFFEF` read R0–R15, and `R` reads memory | Yes, by hand; there is no exit status |
| `--dump` | Option | `R` | Yes, by hand |
| `--trace`, `--max-steps`, `--irq`, `--nmi` | Options | Not available | No |

So a program that fits in 64K words runs the same. The C example
`examples/primes.c` is one.

## Getting started

Clone with the submodule:

    git clone --recurse-submodules https://github.com/MJoergen/NiceMonMEGA65.git

or, in an existing clone:

    git submodule update --init

## Using it

Connect a terminal to the MEGA65's debug UART at 115200 baud, 8-N-1. After
reset the command line interpreter prints `NICE` and takes two commands, with
8 hex digits for each number. End each line with CR alone.

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

### Running a program

A program is assembled with the assembler of the nice_cpu submodule, and
loaded with `tools/load.py`, which writes each word with a `W` command and
then starts the core. For example, with `sim/echo.nasm`, which echoes what you
type until a `.`:

    python3 nice_cpu/assembler/niceasm.py -o echo.bin sim/echo.nasm
    tools/load.py echo.bin
    picocom -b 115200 /dev/ttyUSB1

`load.py` uses the serial device `/dev/ttyUSB1`, the MEGA65's debug UART.
If yours is another, give it with `--port`, and to picocom.
`load.py` needs only Python 3, on Linux or macOS, and the port must not be
open in a terminal while it runs. Type in the terminal and the program echoes
it. When you type `.`, it halts, and the command line takes the UART again.

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
at `0xFFFFFF00`. `getchar` waits for a byte, and never returns `EOF`, as
the UART's input does not end. `nice.h` declares the device routines of
ISA.md §9.3: `nice_putc`, `nice_getc`, `nice_pollc`, and `nice_print` for
the UART, and `nice_cycles` and `nice_instructions` for the performance
counters, as `examples/primes.c` uses them. It also declares `nice_peek`
and `nice_poke`, which read and write any NICE address, such as the math
unit's. `nice_screen_put` and `nice_screen_clear` write the screen at
`0xFFFF0000`, which nothing displays here, but `R` reads it.

The translated code and the runtime routines multiply and divide with the
math unit, so the program is joined with `muldiv_mpu.nasm`. A system
without the math unit would translate with `nicewasm --no-mpu` and use
`muldiv_soft.nasm` instead.

The linear memory is one page, 16384 words, and the program and its memory
must fit below the stack in the 64K words of memory. With `printf` and `scanf`, the
prime example ends at word `0x6C90`. The translator's README,
`nice_cpu/translator/README.md`, has the same steps for Zig and Rust.

### Address map

The command line and the core's data accesses see the same addresses.

| Address | What it is |
|---|---|
| `0x00000000`–`0xFFFFFFFF` | Memory, where no register below is: 64K words of block RAM, repeated through the address space. So the runtime's stack below `0xFFFFFF00` lands in the top of it, and so do the words of `0xFFFFFF00`–`FF` that are not registers. |
| `0xFFFF0000`–`0xFFFF07FF` | The screen: 2048 words of memory of their own, the emulator's 80×25 screen and a little more. Nothing displays it, but `R` reads it. |
| `0xFFFFFF00` | The UART, as the console of ISA.md §8.3. A write sends bits 7..0. A read takes the oldest received byte and returns it in bits 7..0 with bit 8 set, or 0 when no byte has arrived. Bit 9, the end of the input, is never set. |
| `0xFFFFFF01` | The emulator's read counter. A read by the core returns the number of its reads since the last write, and a write sets that number. A read with `R` does not count. It is 0 when the core starts. |
| `0xFFFFFF10`–`0xFFFFFF1F` | The performance counters of ISA.md §8.5: cycles and instructions, 64 bits each. |
| `0xFFFFFF20`–`0xFFFFFF3F` | The math unit of ISA.md §8.4: 32-bit multiply and divide, and 64-bit divide. |
| `0xFFFFFFE0`–`0xFFFFFFEF` | For the command line only: R0–R15 of the core, read only. After a halt they hold what the emulator prints. |
| `0xFFFFFFF0` | Control, for the command line only. Bit 0 holds the core in reset. Bit 1 reads the core's halted flag. |

Instruction fetches from `0xFFFFFF00`–`0xFFFFFFFF` read 0, as ISA.md §8.3
requires. The input waits for the core in a FIFO of 16 bytes, and a byte
that arrives when it is full is lost.
The performance counters and the math unit are nice_cpu's own,
`nice_cpu/hdl/src/perf.vhd` and `mpu.vhd`, the same as in the emulator.
They are reset with the system, not when the command line holds the core,
so the counters keep counting from power-up: a program measures an interval
as the difference of two readings.

## Running the tests

You need GHDL (tested with 4.1.0) and Python 3.

    make -C sim test

- `sim/tb_hello.vhd` runs a "Hello" program on the NICE core from the
  submodule, and checks its console output.
- `sim/tb_nicemon.vhd` drives the whole system through its UART. It loads
  the "Hello" program with the command line, runs it, and then loads and
  runs `sim/echo.nasm`, which echoes what it receives. Last it uses the
  math unit from the command line, and runs `sim/devices.nasm`, which uses
  the math unit and the performance counters. `sim/fifo.nasm` checks the
  input FIFO, and `sim/emu.nasm` the screen, the read counter, memory in
  the I/O range, and the registers after a halt.
- `make test` also checks that GHDL can synthesise the system.

For the boards, see [synth/](synth/README.md).
