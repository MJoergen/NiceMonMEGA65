# Writing programs

A program is NICE assembly, assembled with `niceasm` of the nice_cpu
submodule into a `.bin` file, which has one line per word, the address and
the word in hex. nice_cpu's [doc/ISA.md](https://github.com/MJoergen/nice_cpu/blob/main/doc/ISA.md) is the
instruction set, and its [doc/SYSTEM.md](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md) the
devices: the console, the math unit, the performance counters, and the
timer. [SYSTEM.md](SYSTEM.md) here has the address map of the board,
with its screen and its ROM. The memory is 128K words on the MEGA65 and
64K on the Nexys4DDR, not 2³² as in the emulator.

## Three levels

A program uses what the system gives on three levels, and each is
there in different cases:

| Level | What it is | Where it is | In `niceemu` |
|---|---|---|---|
| 1. The hardware | The CPU and the I/O registers, in the RTL | Always | The same, but for the differences of [EMULATOR.md](EMULATOR.md) |
| 2. The ROM | The monitor's dispatch table at `0x0000`: the screen's cursor and outputs, the files of the SD card, and UDP | While the ROM is visible: for a program at `0x8000` under the monitor | Only with the monitor joined at 0 |
| 3. The libraries | `monlib.nasm`, nice_cpu's runtime, and its C library | In the program's own image, joined when it is built | The same |

**The hardware.** Every program has the console at `0xFFFFFF00`, the
math unit, the counters, the timer, the screen, the fonts, the
keyboard, the network station, the port for Ethernet frames, and the SD
card controller, as registers. nice_cpu's SYSTEM.md specifies its
devices, and [SYSTEM.md](SYSTEM.md) here the address map and the
board's own registers. `niceemu` has all of them, with the differences
that [EMULATOR.md](EMULATOR.md) lists: the size of the memory, the
Nexys4DDR's devices, and the RAM's size and the baud rate at
`0xFFFFFF9E` and `9F`, which are memory there. Its SD cards are image
files, `--sd0 FILE` and `--sd1 FILE`, and its frames come from a file,
`--eth-in`, or from UDP, `--eth-udp`. A program that uses only this
level is built at 0, and runs alone on the board, loaded with
`tools/load.py` (which hides the ROM), and in `niceemu`.

**The ROM.** The monitor in the ROM gives a program at `0x8000` twenty
routines, through a dispatch table at `0x0000`
([monitor/README.md](../monitor/README.md#the-dispatch-table)): a
terminal on the screen, with the cursor, the scrolling, and the copy to
the line (`mon_putc`, `mon_out`, `scr_cls`, `scr_moveto`, `scr_getxy`,
and `scr_color`), the files of the SD card's FAT32 (`fs_mount` to
`fs_delete`), and a UDP endpoint (`udp_open` to `udp_close`), with the
return to the monitor and its version. A program calls them through the
stubs of `monitor/mon.nasm`, and C declares them with `monitor/mon.h`.
They are there whenever the ROM is visible, as it is for a program that
the monitor runs: one loaded with `l`, `load`, or `tftp` on the board
and run with `r`, or loaded with `tools/load.py --monitor` from a host. They are not
there for a program at 0, as `load.py` without `--monitor` hides the
ROM. The ROM has other routines, such as the SD card's sectors and the
ARP cache, which have no entries, and which a program does not call
([monitor/INTERNALS.md](../monitor/INTERNALS.md)).

`niceemu` has no ROM. There the monitor is a program at 0 like any
other, and a program under it is joined after it, as a `.bin` file is
address and word pairs:

    cat monitor/build/monitor.bin prog.bin > joined.bin
    printf 'r\rh\r' > rh.txt
    niceemu -i rh.txt --sd0 card.img joined.bin

The input types `r`, which runs the program at `0x8000`, and `h`,
which halts the core when the program returns, and `--sd0` gives it a
card. A program built for the monitor that runs alone in `niceemu`
jumps into an empty dispatch table.

**The libraries.** These are assembly files and C libraries that a
program joins when it is built. They are in its image, and only in a
program that joins them: there is no linker, so a program that joins a
file has all of it. `monitor/monlib.nasm` has the routines that the
monitor's commands use too, `_io_puts`, `_io_puthex`, `_io_gets`, and
others ([monitor/README.md](../monitor/README.md#the-shared-routines));
they print through `mon_putc`, so they need the ROM. nice_cpu's runtime
(`lib.nasm`, `muldiv_mpu.nasm`) and its C library need no ROM, and run
the same on the board and in `niceemu`.

To build a program for the monitor, assemble it at `0x8000` with
nice_cpu's `start_mon.nasm` in front, and join the files it uses after
it, as `monitor/Makefile` builds `test/hello.nasm`:

    cat nice_cpu/runtime/start_mon.nasm prog.nasm monitor/monlib.nasm \
        monitor/mon.nasm nice_cpu/runtime/lib.nasm \
        nice_cpu/runtime/muldiv_mpu.nasm > prog_all.nasm
    python3 nice_cpu/assembler/niceasm.py -o prog.bin prog_all.nasm

A C program is built with `nicebuild.py --monitor --asm monitor/mon.nasm
-I monitor` ([monitor/README.md](../monitor/README.md#programs)).

## C

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
`putchar` and `getchar` use the console at `0xFFFFFF00`, which writes to
the line, a TCP connection to the Ethernet port or the UART, and reads
from the line and the keyboard. `getchar` waits for a byte, and returns
`EOF` once a break on the line has ended the input.
`nice.h` declares the device routines of nice_cpu's runtime/ABI.md:
`nice_putc`, `nice_getc`, `nice_pollc`, and `nice_print` for the console,
`nice_cycles`, `nice_instructions`, and `nice_micros` for the performance
counters, and `nice_isqrt64`, the math unit's square root.
`examples/primes.c` uses the two counters. It also declares `nice_peek`
and `nice_poke`, which read and write any NICE address, such as the math
unit's. `nice_screen_put` and `nice_screen_clear` write the screen at
`0xFFFF0000`, which the VGA and HDMI outputs show (VGA only on the
Nexys4DDR). `time.h` has `clock()`, which counts microseconds from the
counter at `0xFFFFFF44`. On the board they are real time, at the clock's
rate; in the emulator they are the host's time, or a step each with
`niceemu --step-time`. There is no calendar, so
`time()` returns -1.

The translated code and the runtime routines multiply and divide with the
math unit, so the program is joined with `muldiv_mpu.nasm`. A system
without the math unit would translate with `nicewasm --no-mpu` and use
`muldiv_soft.nasm` instead.

The linear memory is one page, 16384 words, and the program and its memory
must fit below the stack in the RAM. With `printf` and `scanf`, the prime
example ends at word `0x9C5A`.

## The memory

A program learns the size of the RAM from `0xFFFFFF9E`, which reads its
words, `0x20000` on the MEGA65 and `0x10000` on the Nexys4DDR. In the
emulator that word is plain memory, which reads 0, and 0 means no limit.
So one binary can take what each target has: build it with a cap of
several pages, `nicebuild.py --memory-pages 4`, and at the start read
the word with `nice_peek`, work out what fits below the stack, and grow
the linear memory with `__builtin_wasm_memory_grow` to that, or to the
cap when the word is 0. Under the monitor, the monitor's variables at
`0xFFFFF000` are the top 4K words of the RAM, and the stack grows down
from them, so a program at `0x8000` has 92K words on the MEGA65 and 28K
on the Nexys4DDR ([monitor/README.md](../monitor/README.md)).

## The keyboard

The MEGA65's own keyboard types into the same input as the line, so a
program reads it with `getchar`, and the keys give ASCII, as a terminal
sends it. [SYSTEM.md](SYSTEM.md#the-keyboard) has the table of keys.
The ROM's [demo](../demo/README.md) uses letters, digits, and symbols,
RETURN, INST/DEL, TAB, the cursor keys, and CTRL-L in its typewriter, the
function keys to switch demos, and I, M, and CTRL-C (RUN/STOP) in its
F11, and ignores the rest.

## The screen

The screen at `0xFFFF0000` is shown on the VGA and HDMI connectors, as 80
columns and 25 rows of characters. Word `80 * row + column` is one
character: its code, ISO 8859-1, in bits 7..0, and its color above, the
background in bits 31..20 and the foreground in bits 19..8, each 4 bits of
red, green, and blue. So `0x000FFF41` is a white `A` on black, and `0x41`
alone is black on black. `nice_screen_clear` fills the screen with blanks.
The cursor, the scrolling, and the exact colors are in
[SYSTEM.md](SYSTEM.md#the-screen). Under the monitor, `mon_putc` and the
`scr_*` entries are a terminal on the screen, which moves the cursor and
scrolls (Three levels above).

A program can draw its own characters, such as the pieces of a game. The
font RAM at `0xFFFE0000` has a glyph of 32 words for each code, one word a
row, the top row first, with the leftmost of its 16 pixels in bit 15.
The character ROM at `0xFFFE2000` holds Spleen in the same layout. A
program copies the ROM into the RAM, writes the glyphs it wants, and
writes `0xFFFE0000` to the font base at `0xFFFFFF86` to show them. The
codes `0x00`–`0x1F` and `0x80`–`0x9F` are blank in Spleen, so new glyphs
there change no text. A glyph wider than a character is drawn across
several codes side by side. The monitor shows Spleen again when the
program returns to it. [SYSTEM.md](SYSTEM.md#the-font) has the details and
a loop that copies the ROM, and `niceemu --window` draws the same font.

## Programs under the monitor

The monitor in the ROM runs a program at `0x8000` as a subroutine, and
the program returns to it. Such a program is assembled with nice_cpu's
`start_mon.nasm` in place of its start-up file, or built with
`nicebuild.py --monitor`, and the monitor's `l` or `load`, or
`tools/load.py --monitor`, loads it
([monitor/README.md](../monitor/README.md#programs)). It has 92K words of
RAM on the MEGA65 and 28K on the Nexys4DDR. The monitor's entries are its
hardware abstraction layer: the console and the screen, and the files of
the SD card, `fs_mount`, `fs_open`, `fs_read`, `fs_readdir`, and
`fs_close`, which read a file of the card's folder `NICE`. A C program
declares them with `monitor/mon.h` and joins the stubs of `mon.nasm`,
`nicebuild.py --monitor --asm monitor/mon.nasm`
([monitor/README.md](../monitor/README.md#the-dispatch-table)).

A program that runs on its own, at 0, has no monitor to call. It reaches
the SD card controller at `0xFFFFFFA0` itself, a sector at a time
(nice_cpu's SYSTEM.md §5, and [SYSTEM.md](SYSTEM.md#the-sd-card-slots)),
and the port for Ethernet frames at `0xFFFFFFC0`, which receives the
frames that the station does not serve and sends the program's
(nice_cpu's SYSTEM.md §7, and [SYSTEM.md](SYSTEM.md#ethernet-frames));
`sim/udp.nasm` answers a UDP datagram through it. A program under the
monitor may use both too, and one that drives the SD registers itself
mounts the card again afterwards.

## Programs in the ROM

A program can also be the ROM of a core file (see "Building your own ROM"
in the [README](../README.md)). The program must fit in the 32K words of
the ROM. A C program keeps its data in its image, which would be in the
ROM too, so it is built with `nicebuild.py --ram ADDR`, which puts the
words it writes in the RAM from `ADDR`, as the monitor's C code is
([monitor/INTERNALS.md](../monitor/INTERNALS.md#c-in-the-rom)).
A program in the ROM also has some limits on its writes, which
[SYSTEM.md](SYSTEM.md#the-rom) describes: the main one is that the stack
and the variables must be in the RAM, at `0x8000` or above.
[`sim/rom.nasm`](../sim/rom.nasm) is a small example, a greeting, and
the monitor, [monitor/](../monitor/README.md), is a larger one.
