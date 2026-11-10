# Writing programs

A program is NICE assembly, or C, built on a PC into a `.bin` file,
which has one line per word, the address and the word in hex. The tools
are in the nice_cpu submodule: the assembler, `niceasm`, the C
toolchain, and the emulator, `niceemu`, in which a program can run
before it goes to the board.

Three documents say what a program sees:

- nice_cpu's [doc/ISA.md](https://github.com/MJoergen/nice_cpu/blob/main/doc/ISA.md) is the
  instruction set.
- nice_cpu's [doc/SYSTEM.md](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md)
  specifies the devices: the console, the math unit, the performance
  counters, the timer, and the others. It is cited here as "nice_cpu's
  SYSTEM.md".
- [SYSTEM.md](SYSTEM.md) here has the address map of the board, with
  its screen, its keyboard, and its memory, which is 128K words on the
  MEGA65 and 64K on the Nexys4DDR, not 2³² as in the emulator.

There are two kinds of program:

- A program **on its own** is built at address 0, and has only the
  hardware. A PC loads it with `tools/load.py`, which hides the ROM, and
  it runs the same in `niceemu`.
- A program **under the monitor** is built at `0x8000`, and may call
  the monitor's routines in the ROM, for the screen, the files, and the
  network. The monitor loads it, from the SD card, the network, or a
  paste, and it returns to the monitor (see
  [Programs under the monitor](#programs-under-the-monitor)).

## A first program

This program runs on its own. It writes a greeting to the console,
which goes to the PC, and to the screen:

    ; hello.nasm: a greeting on the console and on the screen
    CONSOLE         .EQU    0xFFFFFF00
    SCREEN          .EQU    0xFFFF0000
    WHITE           .EQU    0x000FFF00      ; white on black

                    MOVE    R1, TEXT        ; the address of the next character
                    MOVE    R3, SCREEN      ; the address of the next screen word
    LOOP            MOVE[M] R2, @R1++       ; the character, and Z if it is 0
            ?Z      HALT                    ; the end of the text
                    MOVE    @CONSOLE, R2    ; to the console
                    OR      R2, R2, WHITE   ; with its colors
                    MOVE    @R3++, R2       ; to the screen
                    JMP     LOOP

    TEXT            .ASCII_L 'Hello, world!'

Assemble it, and run it in the emulator, which is built with
`make -C nice_cpu/emulator build`. The emulator prints the console's
output, why the program stopped, and the registers, and with `--screen`
the screen:

    python3 nice_cpu/assembler/niceasm.py -o hello.bin hello.nasm
    nice_cpu/emulator/zig-out/bin/niceemu --screen hello.bin

Then run it on the board, from a PC on its network (the
[README](../README.md#over-ethernet) says how the board gets its
address):

    tools/run.py --eth 192.168.1.65 hello.bin

`run.py` loads the program, starts it, and prints what `niceemu`
prints, so the two can be compared. The greeting is at the top of the
board's screen, and the reset button brings the monitor back.
`tools/load.py` loads and starts a program without waiting for it, and
`tools/mon.py` is a debugger ([tools/README.md](../tools/README.md)).

## Three levels

A program uses what the system gives on three levels, and each is
there in different cases:

| Level | What it is | Where it is | In `niceemu` |
|---|---|---|---|
| 1. The hardware | The CPU and the I/O registers | Always | The same, but for the differences of [EMULATOR.md](EMULATOR.md) |
| 2. The ROM | The monitor's routines, called through the dispatch table at `0x0000`: a terminal on the screen, the files of the SD card, and UDP | While the ROM is visible: for a program at `0x8000` under the monitor | Only with the monitor joined at 0 |
| 3. The libraries | `monlib.nasm`, nice_cpu's runtime, and its C library | In the program's own image, joined when it is built | The same |

**The hardware.** Every program has the console at `0xFFFFFF00`, the
math unit, the counters, the timer, the screen, the fonts, the
keyboard, the network station, the port for Ethernet frames, and the SD
card controller, as registers. nice_cpu's SYSTEM.md specifies its
devices, and [SYSTEM.md](SYSTEM.md) here the address map and the
board's own registers. `niceemu` has all of them, with the differences
that [EMULATOR.md](EMULATOR.md) lists. Its SD cards are image files,
`--sd0 FILE` and `--sd1 FILE`, and its frames come from a file,
`--eth-in`, or from UDP, `--eth-udp`. A program on its own uses only
this level.

**The ROM.** The monitor gives a program at `0x8000` twenty routines.
The program calls them through the dispatch table, a row of jumps at
fixed addresses at the start of the ROM
([monitor/README.md](../monitor/README.md#the-dispatch-table)):

- A terminal on the screen, with the cursor, the scrolling, and a copy
  to the PC: `mon_putc`, `mon_out`, `scr_cls`, `scr_moveto`,
  `scr_getxy`, and `scr_color`.
- The files of the SD card, `fs_mount` to `fs_delete`: they read,
  write, list, and delete the files of the card's folder `NICE`.
- A UDP endpoint, `udp_open` to `udp_close`, which sends and receives
  datagrams.
- The return to the monitor, and its version.

They are there whenever the ROM is visible, as it is for a program that
the monitor runs. They are not there for a program at 0, as `load.py`
without `--monitor` hides the ROM. The ROM has other routines, such as
the SD card's sectors and the ARP cache, which have no entries, and
which a program does not call
([monitor/INTERNALS.md](../monitor/INTERNALS.md)).

**The libraries.** These are assembly files and C libraries that a
program joins when it is built. They are in its image, and only in a
program that joins them: there is no linker, so a program that joins a
file has all of it. `monitor/monlib.nasm` has the routines that the
monitor's commands use too, `_io_puts`, `_io_puthex`, `_io_gets`, and
others ([monitor/README.md](../monitor/README.md#the-shared-routines));
they print through `mon_putc`, so they need the ROM. nice_cpu's runtime
(`lib.nasm`, `muldiv_mpu.nasm`) and its C library need no ROM, and run
the same on the board and in `niceemu`.

## Programs under the monitor

The monitor in the ROM runs a program at `0x8000` as a subroutine, and
the program returns to it. The program has 92K words of RAM on the
MEGA65 and 28K on the Nexys4DDR (see [The memory](#the-memory)).

**Building.** Assemble the program at `0x8000`, with nice_cpu's
`start_mon.nasm` in front, in place of its usual start-up file, and the
files it uses joined after it, as `monitor/Makefile` builds
`test/hello.nasm`:

    cat nice_cpu/runtime/start_mon.nasm prog.nasm monitor/monlib.nasm \
        monitor/mon.nasm nice_cpu/runtime/lib.nasm \
        nice_cpu/runtime/muldiv_mpu.nasm > prog_all.nasm
    python3 nice_cpu/assembler/niceasm.py -o prog.bin prog_all.nasm

The program starts at its label `_main`, and calls an entry through its
stub in `monitor/mon.nasm`, such as `CALL _mon_putc`. A C program
declares the entries with `monitor/mon.h`, and is built with:

    nice_cpu/translator/nicebuild.py --monitor --asm monitor/mon.nasm \
        -I monitor -o prog.bin prog.c

[monitor/README.md](../monitor/README.md#programs) has the details.

**Loading.** On the board, the monitor's `load` reads the `.bin` file
from the SD card, `tftp` from the network, and `l` from a paste, and
`r` runs it. From a PC, `tools/load.py --monitor` loads and runs it
([tools/README.md](../tools/README.md#running-a-program-under-the-monitor)).

**In the emulator.** `niceemu` has no ROM. There the monitor is a
program at 0 like any other, and a program under it is joined after it,
as a `.bin` file is address and word pairs:

    make monitor
    cat monitor/build/monitor.bin prog.bin > joined.bin
    printf 'r\rh\r' > rh.txt
    niceemu -i rh.txt --sd0 card.img joined.bin

The input types `r`, which runs the program at `0x8000`, and `h`,
which halts the core when the program returns, and `--sd0` gives it a
card. A program built for the monitor that runs alone in `niceemu`
jumps into an empty dispatch table.

## C

C goes through WebAssembly, with the tools of the nice_cpu submodule: clang
compiles the program to a wasm module and links it with nice_cpu's C
library, `nicewasm` translates the module to NICE assembly, and `niceasm`
assembles it together with the start-up code and the runtime library.
`nicebuild.py` does all of it in one command:

    nice_cpu/translator/nicebuild.py -o prog.bin prog.c

You need clang with the wasm32 target, `wasm-ld`, and `llvm-ar` (on
Debian and Ubuntu, the `clang`, `lld`, and `llvm` packages). The steps
it runs are those of
[nice_cpu/runtime/README.md](https://github.com/MJoergen/nice_cpu/blob/main/runtime/README.md), and the
translator's README,
[nice_cpu/translator/README.md](https://github.com/MJoergen/nice_cpu/blob/main/translator/README.md), has them
for Zig and Rust too.

A wasm trap, such as an access outside the program's memory, prints a
line such as `trap 2: memory access out of bounds at 00003dc9` before
the core halts.

**The C library** has `printf`, `scanf`, `puts`, `putchar`, `getchar`,
the `FILE` functions on `stdin`, `stdout`, and `stderr`, which are all
the console, the string functions, `malloc`, `rand`, `exit`, `assert`,
and more.

- `putchar` and `getchar` use the console at `0xFFFFFF00`. It writes to
  the PC, over a TCP connection to the Ethernet port or the serial
  port, and reads from the PC and the keyboard. `getchar` waits for a
  byte, and returns `EOF` once the PC has ended the input.
- `nice.h` declares the device routines of nice_cpu's runtime/ABI.md:
  `nice_putc`, `nice_getc`, `nice_pollc`, and `nice_print` for the
  console, `nice_cycles`, `nice_instructions`, and `nice_micros` for the
  performance counters, and `nice_isqrt64`, the math unit's square
  root. `examples/primes.c` uses the cycles and the instructions.
- `nice_peek` and `nice_poke` read and write any NICE address, such as
  the math unit's.
- `nice_screen_put` and `nice_screen_clear` write the screen at
  `0xFFFF0000`, which the VGA and HDMI outputs show (VGA only on the
  Nexys4DDR).
- `time.h` has `clock()`, which counts microseconds. On the board they
  are real time; in the emulator they are the host's time, or a step
  each with `niceemu --step-time`.
- `time()` reads the clock of the time of day
  ([nice_cpu's SYSTEM.md §10](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#10-clock)).
  On the board the clock holds no time after a reset, and `time()`
  returns -1 until a program sets it with `nice_clock_set`. In the
  emulator it is the host's time.

**Multiplying and dividing.** The translated code and the runtime
routines multiply and divide with the math unit, so the program is
joined with `muldiv_mpu.nasm`. A system without the math unit would
translate with `nicewasm --no-mpu` and use `muldiv_soft.nasm` instead.

**Bytes.** The memory is addressed in words of 32 bits, and C reads and
writes single bytes. The board has the byte windows of [nice_cpu's
SYSTEM.md §9](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#9-byte-windows)
for that (see [SYSTEM.md](SYSTEM.md#the-byte-windows)), so
`nicebuild.py --byte-windows` makes each byte or halfword load and
store of the program one `MOVE`, where it is a few instructions without
them. nice_cpu's benchmark, `bench/bench.c`, built so with
`--trust-alignment` too, as `make examples` builds its programs, runs
15% fewer instructions and 10% fewer cycles on the board
(CONTRIBUTING.md, "The examples"). Such a program runs on the board and
in the emulator, but not on a system without the windows. Its start-up
code halts with wasm trap 8, `memory beyond the byte windows`, when the
linear memory lies above the words that the windows reach, which cannot
happen in the board's RAM.

**Size.** The program's wasm linear memory, which holds its data, its C
stack, and its heap, is one page, 16384 words, and the program and its
memory must fit below the stack in the RAM. With `printf` and `scanf`,
the prime example takes about 36K words in all.

## The memory

A program learns the size of the RAM from `0xFFFFFF9E`, which reads its
words, `0x20000` on the MEGA65 and `0x10000` on the Nexys4DDR. In the
emulator that word is plain memory, which reads 0, and 0 means no limit.
So one binary can take what each target has: build it with a cap of
several pages, `nicebuild.py --memory-pages 4`, and at the start read
the word with `nice_peek`, work out what fits below the stack, and grow
the linear memory with `__builtin_wasm_memory_grow` to that, or to the
cap when the word is 0.

Under the monitor, the monitor's variables at `0xFFFFF000` are the top
4K words of the RAM, and the stack grows down from them, so a program
at `0x8000` has 92K words on the MEGA65 and 28K on the Nexys4DDR
([monitor/README.md](../monitor/README.md#programs)).
[SYSTEM.md](SYSTEM.md#stack-heap-and-variables) has the layout, and
how deep the stack may grow.

## The keyboard

The MEGA65's own keyboard types into the console's input, beside the
PC, so a program reads it with `getchar`, and the keys give ASCII, as a
terminal sends it. [SYSTEM.md](SYSTEM.md#the-keyboard) has the table of
keys. The ROM's [demo](../demo/README.md) uses letters, digits, and
symbols, RETURN, INST/DEL, TAB, the cursor keys, and CTRL-L in its
typewriter, the function keys to switch demos, F12 to return to the
monitor, and I, M, and CTRL-C (RUN/STOP) in its F11, and ignores the
rest.

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
scrolls.

A program can draw its own characters, such as the pieces of a game. The
font RAM at `0xFFFE0000` has a glyph of 32 words for each code, one word a
row, the top row first, with the leftmost of its 16 pixels in bit 15.
The character ROM at `0xFFFE2000` holds the font Spleen in the same
layout. A program copies the ROM into the RAM, writes the glyphs it
wants, and writes `0xFFFE0000` to the font base at `0xFFFFFF86` to show
them. The codes `0x00`–`0x1F` and `0x7F`–`0x9F` are blank in Spleen, so
new glyphs there change no text. A glyph wider than a character is drawn
across several codes side by side. The monitor shows Spleen again when
the program returns to it. [SYSTEM.md](SYSTEM.md#the-font) has the
details and a loop that copies the ROM, and `niceemu --window` draws the
same font.

## The SD card and the network

Under the monitor, a program reads and writes files with the `fs_*`
entries, and sends and receives UDP datagrams with the `udp_*` entries
([monitor/README.md](../monitor/README.md#files)).

A program on its own has no monitor to call. It drives the hardware
itself, and a program under the monitor may do so too:

- The SD card controller at `0xFFFFFFA0` reads and writes a sector at a
  time ([nice_cpu's SYSTEM.md §5](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#5-sd-card), and [SYSTEM.md](SYSTEM.md#the-sd-card-slots)).
  A program under the monitor that drives it calls `fs_mount` before it
  uses the files again.
- The port for Ethernet frames at `0xFFFFFFC0` receives the frames that
  the board does not answer itself, and sends the program's
  ([nice_cpu's SYSTEM.md §7](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#7-ethernet-frames), and [SYSTEM.md](SYSTEM.md#ethernet-frames)).
  `sim/udp.nasm` answers a UDP datagram through it.

## The monitor's error codes

The entries of the files and the network return a negative number for an
error. The monitor's file commands print the number with its text, as
`File error 29, no folder NICE on the card`, or as
`SD error 1 in slot 0, no card` for an error of the SD controller. The
SD controller's errors are those of `SD_ERROR` ([nice_cpu's SYSTEM.md §5](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#5-sd-card)), negated:

| Error | Meaning |
|---|---|
| -1 | No card is in the selected slot |
| -2 | The card is not ready: Read or Write before a successful Init |
| -3 | Timeout: the card did not answer |
| -4 | CRC: the data from the card was corrupted |
| -5 | The card reported an error |
| -6 | Write-protected: Write to a card whose switch is set |
| -7 | Out of range: Read or Write of a sector after `SD_LAST` |
| -8 | Init failed |

The file entries, `fs_mount` to `fs_delete`, add those of FAT32
([monitor/README.md](../monitor/README.md#files)):

| Error | Meaning |
|---|---|
| -16 | No FAT32 file system |
| -17 | FAT12, which is not supported |
| -18 | FAT16, which is not supported |
| -19 | exFAT, which is not supported |
| -20 | Not an 8.3 name |
| -21 | No such file |
| -22 | A directory, opened as a file |
| -23 | Too many open files: two are |
| -24 | Not an open file, or not one of the right kind |
| -25 | No such mode |
| -26 | The FAT is damaged: a cluster outside the volume, or a chain shorter than the file |
| -27 | No such slot |
| -28 | The card has changed, and the mount was dropped |
| -29 | No folder `NICE` on the card, or the folder of the build |
| -30 | The card is full, or the folder has 65536 entries |
| -31 | The file is open: to write, or at all for a write or a deletion |
| -32 | The file is read-only |

The UDP entries, `udp_open` to `udp_close`, have their own
([monitor/README.md](../monitor/README.md#the-network)):

| Error | Meaning |
|---|---|
| -40 | No IP address: `NET_IP` is 0 |
| -41 | No such port: 0 to send to, or past 65535 |
| -42 | The endpoint is not open |
| -43 | More than 1472 bytes |
| -44 | No answer to ARP from the host, or from the gateway, or none for a host in another network |

## Programs in the ROM

A program can also be the ROM of a core file (see "Building your own ROM"
in the [README](../README.md#building-your-own-rom)). It must do three
things:

- **Fit in the ROM**, which is 32K words, at `0x0000`–`0x7FFF`.
- **Keep its stack and its variables in the RAM**, at `0x8000` or above
  ([SYSTEM.md](SYSTEM.md#stack-heap-and-variables)), as a write to the
  ROM is dropped. With a stack in the ROM, as `hello.nasm` of nice_cpu
  has at `0x1000`, a pushed return address is lost and reads back as 0,
  and the program starts over, forever.
- **In C, be built with `nicebuild.py --ram ADDR`.** A C program keeps
  its data in its image, which would be in the ROM too, and `--ram`
  puts the words it writes in the RAM from `ADDR`, as the monitor's C
  code is built
  ([monitor/INTERNALS.md](../monitor/INTERNALS.md#c-in-the-rom)).

The layout is that of QNICE-FPGA, whose monitor is in the ROM at
`0x0000`–`0x7FFF` and whose programs load at `0x8000`.
[`sim/rom.nasm`](../sim/rom.nasm) is a small example, a greeting, and
the monitor, [monitor/](../monitor/README.md), is a larger one.
