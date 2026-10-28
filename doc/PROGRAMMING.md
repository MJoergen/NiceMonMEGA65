# Writing programs

A program is NICE assembly, assembled with `niceasm` of the nice_cpu
submodule into a `.bin` file, which has one line per word, the address and
the word in hex. nice_cpu's [doc/ISA.md](https://github.com/MJoergen/nice_cpu/blob/main/doc/ISA.md) is the
instruction set, and its [doc/SYSTEM.md](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md) the
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
linear memory, prints a line such as `trap 2: memory access out of bounds
at 00003dc9` before the core halts. You need clang with the wasm32 target,
`wasm-ld`, and `llvm-ar` (on Debian and Ubuntu, the `clang`, `lld`, and
`llvm` packages). The steps it runs are those of
[nice_cpu/runtime/README.md](https://github.com/MJoergen/nice_cpu/blob/main/runtime/README.md), and the
translator's README,
[nice_cpu/translator/README.md](https://github.com/MJoergen/nice_cpu/blob/main/translator/README.md), has them
for Zig and Rust too.

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
`scanf`, the prime example ends at word `0x631F`.

## The keyboard

The MEGA65's own keyboard types into the same input as the UART, so a
program reads it with `getchar`, and the keys give ASCII, as a terminal
sends it. [SYSTEM.md](SYSTEM.md#the-keyboard) has the table of keys.
The ROM's [demo](../demo/README.md) uses letters, digits, and symbols,
RETURN, INST/DEL, TAB, the cursor keys, and CTRL-L, and ignores the rest.

## The screen

The screen at `0xFFFF0000` is shown on the VGA and HDMI connectors, as 80
columns and 25 rows of characters. Word `80 * row + column` is one
character: its code, ISO 8859-1, in bits 7..0, and its color above, the
background in bits 31..20 and the foreground in bits 19..8, each 4 bits of
red, green, and blue. So `0x000FFF41` is a white `A` on black, and `0x41`
alone is black on black. `nice_screen_clear` fills the screen with blanks.
The cursor, the scrolling, and the exact colors are in
[SYSTEM.md](SYSTEM.md#the-screen).

## Programs in the ROM

A program can also be the ROM of a core file (see "Building your own ROM"
in the [README](../README.md)). The program must fit in the 32K words of
the ROM. A C program cannot be a ROM, as its data would be in the ROM too.
A program in the ROM also has some limits on its writes, which
[SYSTEM.md](SYSTEM.md#the-rom) describes: the main one is that the stack
and the variables must be in the RAM, at `0x8000` or above.
[`sim/rom.nasm`](../sim/rom.nasm) is a small example, a greeting, and
[demo/](../demo/README.md) is a larger one.
