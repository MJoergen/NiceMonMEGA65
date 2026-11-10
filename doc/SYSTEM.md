# The system

This is the system that a program and the debug link see on the MEGA65 R3
and R6, and on the Nexys4DDR: the address map, the screen and the font,
the keyboard, the ROM, the Nexys4DDR's devices, the Ethernet station,
which every board has, with the port for frames, and the SD card slots.
[DEBUG_LINK.md](DEBUG_LINK.md) has the debug link: its words, the
control register, the UART's baud rate, and the link over TCP. It
follows nice_cpu's
[doc/SYSTEM.md](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md) for the devices and
[doc/DEBUG.md](https://github.com/MJoergen/nice_cpu/blob/main/doc/DEBUG.md) for the link.
[EMULATOR.md](EMULATOR.md) lists where it differs from `niceemu`.
`src/nicemon.vhd` is the system, and its header is the authoritative
address map. DEBUG.md, ISA.md, and MICROARCH.md are nice_cpu's, in
`nice_cpu/doc/`, and so is the SYSTEM.md with a section number, which is
not this file.

## Address map

The link and the core's data accesses see the same addresses, but for the
debug registers at `0xFFFFFFD0`–`FF`, which only the link sees, and the
console and the read counter, which the link reads as 0 without a side
effect and does not write ([DEBUG.md §3](https://github.com/MJoergen/nice_cpu/blob/main/doc/DEBUG.md#3-requests-and-answers)).

| Address | What it is |
|---|---|
| `0x00000000`–`0xFFFFFFFF` | Memory, where no register below is: block RAM, 128K words on the MEGA65 and 64K on the Nexys4DDR, repeated through the address space. `0xFFFFFF9E` reads the number of words. So the runtime's stack below `0xFFFFFF00` lands in the top of it, and so do the words of `0xFFFFFF00`–`FF` that are not registers. |
| `0x00000000`–`0x00007FFF` | The ROM, in a bitstream built with one, in front of the RAM and repeating with it (see [The ROM](#the-rom)). Bit 3 of the control register hides it. |
| `0x10000000`–`0x5FFFFFFF` | The byte windows of [nice_cpu's SYSTEM.md §9](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#9-byte-windows): a word, a byte, or a halfword of the RAM, or of the ROM while it is shown, at a byte address, for the core's data accesses and the link (see [The byte windows](#the-byte-windows)). |
| `0xFFFE0000`–`0xFFFE1FFF` | The font RAM of [nice_cpu's SYSTEM.md §1.8](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#18-font): 256 glyphs of 32 rows, one word a row, read and written, with bits 31..16 reading 0. It is 0 at power-up and after a clear, and a start keeps it (see [The font](#the-font)). |
| `0xFFFE2000`–`0xFFFE3FFF` | The character ROM: Spleen, in the layout of the font RAM. A write is dropped. |
| `0xFFFF0000`–`0xFFFF7FFF` | The screen: 32768 words of memory of their own, the emulator's 80×25 screen and room for scrolling. The 2000 words from the display offset are shown on VGA and HDMI, or VGA only on the Nexys4DDR (see [The screen](#the-screen)), and the link reads them all. |
| `0xFFFF8000`–`0xFFFFFEFF` | RAM: the top words of the RAM, as it repeats, from `0xFFFF2000` on the Nexys4DDR. The stacks and the monitor's variables are here (see [Stack, heap, and variables](#stack-heap-and-variables)). |
| `0xFFFFFF00`–`0xFFFFFFFF` | The I/O page: nice_cpu's devices, the board's registers, and the link's debug registers (see [I/O registers](#io-registers)). |

### The byte windows

The memory is word-addressed: each address is a word of 32 bits. C and
WebAssembly hold byte addresses, and read and write single bytes and
halfwords. The byte windows let a data access take a byte address, so
that such a load or store is one `MOVE`, with no shifts and masks.

A window address A has the window in its top four bits, and the byte
address in the rest. It reaches the word W = (A >> 2) AND `0x03FFFFFF`,
and byte A mod 4 of it, or halfword bit 1 of A. Byte 0 is bits 7..0 of
the word, and halfword 0 bits 15..0, as in WebAssembly.

| Window | Addresses | A read returns | A write changes |
|---|---|---|---|
| Word | `0x10000000`–`0x1FFFFFFF` | Word W. | Word W. |
| Byte | `0x20000000`–`0x2FFFFFFF` | The byte, zero-extended. | The byte, to bits 7..0 of the value. |
| Signed byte | `0x30000000`–`0x3FFFFFFF` | The byte, sign-extended. | As the byte window. |
| Halfword | `0x40000000`–`0x4FFFFFFF` | The halfword, zero-extended. | The halfword, to bits 15..0 of the value. |
| Signed halfword | `0x50000000`–`0x5FFFFFFF` | The halfword, sign-extended. | As the halfword window. |

So the byte address of word W is 4 × W, and a window adds its base to
it. For example, the word at `0x8000`, where a program under the monitor
starts, has the byte address `0x20000`. If it holds `0x12A4C6E8`:

| Address | Window | A read returns |
|---|---|---|
| `0x10020000` | Word | `0x12A4C6E8` |
| `0x20020000` | Byte 0 | `0x000000E8` |
| `0x20020001` | Byte 1 | `0x000000C6` |
| `0x20020003` | Byte 3 | `0x00000012` |
| `0x30020001` | Signed byte 1 | `0xFFFFFFC6` |
| `0x40020000` | Halfword 0 | `0x0000C6E8` |
| `0x50020000` | Signed halfword 0 | `0xFFFFC6E8` |
| `0x50020002` | Signed halfword 1 | `0x000012A4` |

A write of `0x000003FF` to `0x20020001` changes byte 1 only, and the
word then holds `0x12A4FFE8`: the bits of the value above bit 7 are
dropped. The word window ignores bits 1..0 of A, and the halfword
windows bit 0, so an access through a window never straddles two words.
With the byte address in R2, a program reads the byte with
`MOVE R1, @0x20000000[R2]`, and writes R1 to it with
`MOVE @0x20000000[R2], R1`.

On the board:

- **One access.** A write through a window changes its byte or halfword
  in one access to the RAM, with byte enables, so no interrupt routine
  can change the word between a read and a write of it. A read of a
  byte or a halfword takes a cycle more than a read of a word, for the
  timing at 100 MHz.
- **The RAM repeats.** W reaches the first 64M words, `0x00000000`–
  `0x03FFFFFF`, and the RAM repeats through them as through the whole
  address space, so W reaches the word that its plain address does: RAM
  word W mod 128K on the MEGA65, or W mod 64K on the Nexys4DDR, with
  the ROM in front of the first `0x8000` words of each repeat while it
  is shown. A window never reaches the screen, the font, or the I/O
  registers.
- **No code.** An instruction fetch from a window reads the RAM or the
  ROM that the address aliases, where the emulator reads 0, so no code
  runs through a window.
- **The link** reads and writes through the windows as the core does.

A C or wasm program built with nicewasm's `--byte-windows`, or
`nicebuild.py --byte-windows`, uses them ([PROGRAMMING.md](PROGRAMMING.md)).

### Stack, heap, and variables

The board decodes only the low 17 bits of a RAM address on the MEGA65,
and the low 16 on the Nexys4DDR, so the RAM repeats through the address
space ([nice_cpu's SYSTEM.md §8](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#8-systems-built-on-the-fpga-core), Aliasing). Each word of the RAM has many
addresses, and a program picks the one that suits it. The top of the
address space is the top of the RAM: on the MEGA65, `0xFFFFF000` is RAM
word `0x1F000`, as are `0x0001F000` and `0x0003F000`. Where a device or
the screen is, its address reaches the device instead, and the RAM word
behind it is reached by another address. So on the MEGA65,
`0xFFFF0000`–`7FFF` is the screen, and the RAM words `0x10000`–`0x17FFF`
are reached at `0x00010000`–`0x00017FFF`.

A program that the tools load at 0, with the ROM hidden, has its code
and its data from 0 up, and the runtime's start-up code sets SP to
`0xFFFFFF00`, so its stack grows down from the top of the RAM:

| RAM words, MEGA65 | Nexys4DDR | What |
|---|---|---|
| `0x00000` and up | `0x0000` and up | The program: its code, its static data, and, for C, its wasm linear memory. |
| below `0x1FF00` | below `0xFF00` | The stack, from SP = `0xFFFFFF00` down. |
| `0x1FF00`–`0x1FFFF` | `0xFF00`–`0xFFFF` | The words behind the I/O page, `0xFFFFFF00`–`FF`, that are no register. |

A program under the monitor starts at `0x8000`, as the ROM is at
`0x0000`–`0x7FFF`, and shares the monitor's stack, which grows down
from `0xFFFFF000`. The monitor keeps the top 4K words for itself
([monitor/README.md](../monitor/README.md)):

| RAM words, MEGA65 | Nexys4DDR | Address | What |
|---|---|---|---|
| `0x08000` and up | `0x8000` and up | `0x00008000` and up | The program and the stack: 92K words on the MEGA65, and 28K on the Nexys4DDR. |
| below `0x1F000` | below `0xF000` | below `0xFFFFF000` | The stack of the monitor and the program, from SP = `0xFFFFF000` down. |
| `0x1F000`–`0x1F3FF` | `0xF000`–`0xF3FF` | `0xFFFFF000`–`F3FF` | The monitor's variables. |
| `0x1F400`–`0x1FEFF` | `0xF400`–`0xFEFF` | `0xFFFFF400`–`FEFF` | The words of the monitor's C code, its FAT32, with its own stack ([monitor/INTERNALS.md](../monitor/INTERNALS.md)). |

The heap of a C program is in its wasm linear memory, after its static
data and its C stack, which are there too: `malloc` takes more of the
linear memory with `memory.grow`, up to the cap that the program was
built with. The NICE stack, which holds the return addresses and the
registers that a call saves, is the one that SP points at. So the
program, its linear memory, and the NICE stack must all fit in the RAM,
and nothing checks that the stack does not grow into the program. A
program learns the size of the RAM from `0xFFFFFF9E`
([PROGRAMMING.md](PROGRAMMING.md#the-memory)).

In the emulator the memory has 2^32 words and does not repeat, so the
same addresses work there, but each is a word of its own.

### I/O registers

The words `0xFFFFFF00`–`FF` are the I/O page. Most of its devices are
nice_cpu's, and the rows below say what differs on the board. The
words where no register is reach the RAM behind them.

| Address | What it is |
|---|---|
| `0xFFFFFF00` | The console of [nice_cpu's SYSTEM.md §1.2](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#12-console). Its output goes to the line, the UART or a host over TCP, and its input comes from the line and the keyboard, through the input FIFO (below). A break on the UART, or a host's half-close over TCP, ends the line's input, and a read returns `0x200` once the bytes before it are read, until a start or the next connection ([DEBUG_LINK.md](DEBUG_LINK.md#the-debug-link-over-tcp)). The keyboard's bytes still come ([nice_cpu's SYSTEM.md §8](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#8-systems-built-on-the-fpga-core)). |
| `0xFFFFFF01` | The read counter of [nice_cpu's SYSTEM.md §1.7](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#17-read-counter), as in the emulator. A start keeps it. |
| `0xFFFFFF10`–`0xFFFFFF1F` | The timer of [nice_cpu's SYSTEM.md §4](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#4-timer). It counts clock cycles, at 100 MHz on the MEGA65 and 90 MHz on the Nexys4DDR, where the emulator counts steps. |
| `0xFFFFFF20`–`0xFFFFFF3F` | The math unit of [nice_cpu's SYSTEM.md §2](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#2-math-unit), as in the emulator. |
| `0xFFFFFF40`–`0xFFFFFF5F` | The performance counters of [nice_cpu's SYSTEM.md §3](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#3-performance-counters). The cycles are those of the board's clock, at 100 MHz on the MEGA65 and 90 MHz on the Nexys4DDR, and the microseconds come from it, so they are real time. The instructions and the event counters count as the emulator's do. A read of a low word by the link takes the snapshot, as the core's does, where `niceemu --link` takes none. |
| `0xFFFFFF46`–`0xFFFFFF49` | The clock of the time of day of [nice_cpu's SYSTEM.md §10](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#10-clock), within the performance counters, counted from the board's clock. After a reset it is not set until a program sets it: the board does not read the MEGA65's real-time clock yet. A read of `0xFFFFFF46` by the link takes the snapshot too. |
| `0xFFFFFF60`–`0xFFFFFF7F` | The fetch statistics of [MICROARCH.md §8.1](https://github.com/MJoergen/nice_cpu/blob/main/doc/MICROARCH.md#81-fetch-statistics), which the emulator does not have. With the multi-cycle core (`NICE=multi`), only two of them count. |
| `0xFFFFFF80`–`0xFFFFFF8F` | The screen's registers: the cursor and the display offset (see [The screen](#the-screen)). |
| `0xFFFFFF90`–`0xFFFFFF9F` | The Nexys4DDR's LEDs, seven-segment display, buttons, and switches (see [The Nexys4DDR's devices](#the-nexys4ddrs-devices)). On the MEGA65 they read 0 and take no write. On every board, `0xFFFFFF9E` reads the words of the RAM, `0x20000` on the MEGA65 and `0x10000` on the Nexys4DDR, and takes no write, and `0xFFFFFF9F` is the UART's baud rate (see [The baud rate](DEBUG_LINK.md#the-baud-rate)). The emulator has memory there, which reads 0 after a clear, so a program takes 0 to mean no limit. |
| `0xFFFFFFA0`–`0xFFFFFFAF` | The SD card controller of [nice_cpu's SYSTEM.md §5](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#5-sd-card), with 2 slots on the MEGA65 and 1 on the Nexys4DDR (see [The SD card slots](#the-sd-card-slots)). |
| `0xFFFFFFB0`–`0xFFFFFFBF` | The network station of [nice_cpu's SYSTEM.md §6](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#6-network-station), on every board: the Ethernet station's addresses, its counts of frames, and the state of the debug link over TCP (see [The Ethernet station](#the-ethernet-station)). |
| `0xFFFFFFC0`–`0xFFFFFFCF` | The port for Ethernet frames of [nice_cpu's SYSTEM.md §7](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#7-ethernet-frames), on every board: a queue of 4 frames received and a send buffer, through which a program sends and receives frames of its own (see [Ethernet frames](#ethernet-frames)). |
| `0xFFFFFFD0`–`0xFFFFFFDF` | The debug registers of [DEBUG.md §6](https://github.com/MJoergen/nice_cpu/blob/main/doc/DEBUG.md#6-the-debug-registers), for the link only, here and below: `saved_pc`, `saved_sr`, and 4 watchpoints. While a watchpoint is enabled, the pipelined core runs more slowly. A data access of the core here, and below, goes to the RAM. |
| `0xFFFFFFE0`–`0xFFFFFFEF` | R0–R15 of the core, read live while it runs. The multi-cycle core adds 1 to R15 for each word it fetches, so its live R15 may be the address of a constant word, or of the word after the instruction it carries out. |
| `0xFFFFFFF0`–`0xFFFFFFFF` | The control register ([DEBUG_LINK.md](DEBUG_LINK.md#the-control-register)), the halt reason, never 5 here, the link's version, 7, the free space of the 2048-byte input FIFO, the stop, and 4 breakpoints at `0xFFFFFFF8`–`FB`. |

Instruction fetches from `0xFFFFFF00`–`0xFFFFFFFF` read 0, as [ISA.md §8.3](https://github.com/MJoergen/nice_cpu/blob/main/doc/ISA.md#83-input-and-output)
requires.

The input waits for the core in a FIFO of 2048 bytes, in block RAM. A
UART byte that arrives when it is full is lost, and the link sends its
`o` notice. Over Ethernet, a byte that finds it full waits up to 50 ms
for room, and holds back the bytes behind it, before it is lost with
`o`, as TCP can wait; a UART byte after a break is lost too, until a start, or a
host's connection over Ethernet, clears the end of the line's input. A
keyboard byte goes in after a break as
before it, so that a program that reads on, as a monitor does, gets the
keys. A keyboard byte waits until the FIFO has room for two,
so that a UART byte still finds room, and keys typed meanwhile may be
lost (see [The keyboard](#the-keyboard) and [The Nexys4DDR's
devices](#the-nexys4ddrs-devices)). While the core is held in reset or
has halted, the bytes of the UART and the keyboard are dropped. While it
is paused, they go into the FIFO. To end a program's input from a
terminal, send a break ([tools/README.md](../tools/README.md) says how).

The performance counters, the math unit, and the timer are nice_cpu's
own, `nice_cpu/hdl/src/perf.vhd`, `mpu.vhd`, and `timer.vhd`, and behave
as the emulator's. The fetch statistics are nice_cpu's `fetch_stats.vhd`,
which the emulator does not have. `src/devices.vhd` connects the four.
They are reset with the system, and each time the core starts, as the
emulator's are when it starts, but not while the link holds the core, so
the link reads them after a halt. So after a halt the instruction counter
holds the steps that the emulator prints, unless the program starts the
timer. The timer counts clock cycles, at 100 MHz (90 MHz on the
Nexys4DDR), where the emulator counts steps, so its interrupts come at
other steps, and the step counts differ. The cycle counter and the
timer's counter run only while the core runs, so they stop at a halt, as
the emulator's do. The timer's request goes straight to the core's IRQ,
for it is the only device that raises one.

## The screen

The screen at `0xFFFF0000` is shown on the VGA connector and on the HDMI
connector, at 1280×1024 and 60 Hz, as 80 columns and 25 rows of characters
of 16×32 pixels. Under them are the 4 rows of the on-board debugger's
strip ([DEBUGGER.md](DEBUGGER.md)), black unless it is shown, and the 29
rows are in the middle of the picture, 48 black lines from its top. Word `80 * row + column` is
one character: its code, ISO 8859-1, in bits 7..0, and its color above. The
color is two 12-bit colors, red, green, and blue with 4 bits each, as in
nice_cpu's `doc/SYSTEM.md` §1: the background in bits 31..20 and the
foreground in bits 19..8. A component `n` gives the byte `n × 0x11`, so
`0xF` is full intensity and `0x0` is none. Unlike in NICE's original IDE of
2004, the foreground is not inverted. So a word with only a character, such
as `0x41`, is black on black, and `0x000FFF41` is a white `A` on black. The
screen is 0 at power-up, which shows as black, and `nice_screen_clear`
fills it with blanks.

The screen's memory is 32768 words, `0xFFFF0000`–`0xFFFF7FFF` (8192
words, `0xFFFF0000`–`0xFFFF1FFF`, on the Nexys4DDR), of which the display
shows 2000 from the display offset, so a program scrolls by adding
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
| `0xFFFFFF86` | The font base of [nice_cpu's SYSTEM.md §1.8](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#18-font), all 32 bits kept and read back: `0xFFFE0000` shows the font RAM, and 0 shows the character ROM, as do the other values, which are reserved (see [The font](#the-font)). |

The words `0xFFFFFF83`, `84`, and `87`–`8F` read 0 and take no write. In
the emulator these addresses are memory, so a program that writes them runs
there too, without scrolling. Reset, and the clear of the memory (bit 2 of
the control register, which `load.py` and `run.py` set), set the offset and
the font base to 0 and turn the cursor off, as at the start of the
emulator. From
nice_cpu V1.2 on, `niceemu --window` draws the same cursor from these
words, as [nice_cpu's SYSTEM.md §1](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#1-console-screen-and-read-counter) says, but has no display offset.
A column or row out of range shows no cursor there, where here only
bits 6..0 of the column and 4..0 of the row are kept.

A write of `0x000FFF41` to `0xFFFF0000` puts an `A` in the top left
corner, white on black, and one of `0xF00FFF42` to `0xFFFF0001` a white `B`
on red next to it.

### The font

The characters are drawn from one of two fonts of 256 glyphs, as in
[nice_cpu's SYSTEM.md §1.8](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#18-font) and `niceemu --window`. The character ROM at
`0xFFFE2000` holds [Spleen](https://github.com/fcambus/spleen) 16×32 with
the codes of ISO 8859-1, where `0x00`–`0x1F` and `0x7F`–`0x9F` are blank.
The font RAM at `0xFFFE0000` holds what a program writes. In both, the
word at the font's address + `32 * c + r` is row `r` of the glyph of code
`c`, row 0 at the top, and its bits 15..0 are the 16 pixels, the leftmost
in bit 15. A set bit is drawn in the foreground color, and a clear bit in
the background color.

The font base at `0xFFFFFF86` selects the font shown: 0, after reset and
a clear, shows Spleen, and `0xFFFE0000` the font RAM. A write to a glyph
shows in the next frame in every cell with its code while the RAM is
selected, and a write to the base changes the whole screen at once. The
debugger's strip and page are always drawn in Spleen.

A program that wants Spleen's letters and a few symbols of its own copies
the ROM into the RAM, 8192 words, changes the glyphs it wants, and writes
`0xFFFE0000` to the base:

                    MOVE    R1, 0xFFFE2000  ; the character ROM
                    MOVE    R2, 0xFFFE0000  ; the font RAM
                    MOVE    R3, 8192
    COPY            MOVE    @R2++, @R1++
                    SUB[M]  R3, R3, 1
            ?!Z     JMP     COPY
                    MOVE    @0xFFFFFF86, 0xFFFE0000  ; show the font RAM

The monitor writes 0 to the base at its start and when a program returns
to it, so its text is in Spleen whatever the program did, and the
program's font stays in the RAM. The font RAM is 0 at power-up and after
a clear, and a start keeps it, as it keeps the screen. An instruction
fetch in `0xFFFE0000`–`0xFFFE3FFF` reads the RAM there, which these
words alias, and not the fonts, so a program does not run from its font
([nice_cpu's SYSTEM.md §8](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#8-systems-built-on-the-fpga-core), and [EMULATOR.md](EMULATOR.md)).

The video output comes from MandelbrotMEGA65, which uses the same mode on
the MEGA65. The HDMI output is DVI, without sound.

## The keyboard

The MEGA65's own keyboard types into the same input as the UART: what
you type goes to the program while it runs or is paused, and is dropped
while the core is held in reset or has halted. The keys give ASCII, as a
terminal sends it. [nice_cpu's SYSTEM.md §1](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#1-console-screen-and-read-counter) defines the bytes of the keys
that every keyboard has, which `niceemu --window` sends too, from
nice_cpu V1.2 on, and the MEGA65's keyboard follows it. The table has
the MEGA65's keys:

| Key | Byte |
|---|---|
| Letters, digits, symbols | Their ASCII; SHIFT or CAPS LOCK for capitals |
| RETURN | CR |
| INST/DEL | DEL (`0x7F`), also with SHIFT or CTRL |
| RUN/STOP | CTRL-C (`0x03`) |
| ESC, TAB | ESC, TAB |
| Cursor keys | `ESC [ A` to `ESC [ D`, as ANSI terminals send them |
| SHIFT with CRSR→ or CRSR↓ | The other direction, `ESC [ D` or `ESC [ A`, as on the C64 |
| F1, F3, F5, F7, F9, F11 | As xterm sends them: `ESC O P` and `ESC O R` for F1 and F3, and `ESC [ 15 ~`, `ESC [ 18 ~`, `ESC [ 20 ~`, and `ESC [ 23 ~` for the others |
| SHIFT with F1 to F11 | The even keys F2 to F12, as xterm sends them: `ESC O Q`, `ESC O S`, `ESC [ 17 ~`, `ESC [ 19 ~`, `ESC [ 21 ~`, and `ESC [ 24 ~` |
| CLR/HOME | Home, `ESC [ H`, as xterm sends it, also with SHIFT |
| CTRL and MEGA with CRSR↑ or CRSR↓ | Page Up or Page Down, `ESC [ 5 ~` or `ESC [ 6 ~`, as xterm sends them; SHIFT with CRSR↓ is CRSR↑ here too |
| CTRL with a letter | Its control code |
| £, ↑, ← | `\`, `^`, `_` (`\|`, `~`, `` ` `` with SHIFT) |
| SHIFT with `0`, `=`, `:`, `;` | `{`, `}`, `[`, `]` |

A held key repeats after half a second, 20 times a second. F13, HELP,
and the modifiers give nothing, and MEGA changes no key on its own: with
CTRL it makes the cursor keys up and down Page Up and Page Down, and
without CTRL they stay the cursor keys. MEGA and HELP together toggle the
on-board debugger ([DEBUGGER.md](DEBUGGER.md)), and while it has the
focus the keys go to it, not to the core. The keyboard's drive
LED is green while the core runs, like the user LED.

The bytes of a key wait until the core's input has room for them, and
the keyboard is not scanned meanwhile, so a key that is pressed and
released while they wait is lost. A key held down until then is not.

## The ROM

A bitstream built with `make r6 ROM=file.bin` (or `make r3 ...`), or with
`demo/build/rom.bin`, the monitor and the demo, by default, has a ROM of 32K words at `0x0000`–`0x7FFF`, in
front of the RAM, with the words of the `.bin` file, and its core boots
from it at reset instead of waiting held for a host. That is the layout of QNICE-FPGA, whose monitor is in ROM at
`0x0000`–`0x7FFF` and whose programs load at `0x8000`, and the
[monitor](../monitor/README.md) is built for it. The release's ROM holds
the monitor, and behind it the demo, which the monitor's `x` copies to
`0x8000` and runs there ([demo/](../demo/README.md)). The file is read by Vivado, so the ROM changes only with a
new bitstream, and a word beyond the ROM fails the build. A write to the
ROM is dropped, and a clear (bit 2 of the control register) does not
touch it. So a program in the ROM must keep its stack and its variables
in the RAM, at `0x8000` or above: `sim/rom.nasm`, the greeting that the
tests use as the ROM, has its stack at the top of the memory, as the
runtime has, and the monitor has its stack and variables below
`0xFFFFF000`. With a stack in the ROM, as `hello.nasm` of
nice_cpu has at `0x1000`, a pushed return address is lost and reads back
as 0, and the program starts over, forever.

A C program keeps its data in its own image, which would be in the ROM,
so its writes would be lost. It runs from the ROM when it is built with
`nicebuild.py --ram ADDR`, which puts the words it writes in the RAM from
`ADDR`, as the monitor's C code has them at `0xFFFFF400`
([monitor/INTERNALS.md](../monitor/INTERNALS.md#c-in-the-rom)).

While the core runs from the ROM, the link reaches only its debug
registers. Bit 3 of the control register hides the ROM: a write of
`0x00000009` holds the core with the ROM hidden, and the RAM is at address
0, as in the emulator, so a program loads and runs as without a ROM, with
`0x00000008` to start it. `load.py` does this. `0x00000001` and then
`0x00000000` show the ROM again and boot from it, as the reset button
does. The RAM under the ROM keeps its words meanwhile.

## The Nexys4DDR's devices

On the Nexys4DDR, a USB keyboard in the board's USB HID port types into the
same input (the board's PIC24 turns it into PS/2). Its keys give the same
bytes, for a US layout: Enter is CR, Backspace and Delete are DEL, the
cursor keys are `ESC [ A` to `ESC [ D`, F1 to F12 are as on the MEGA65,
also with SHIFT, Home, Page Up, and Page Down give `ESC [ H`, `ESC [ 5 ~`,
and `ESC [ 6 ~`, and CTRL with a letter is its control code. The keypad gives its digits and symbols, whatever Num Lock
is. Scroll Lock gives nothing, and toggles the on-board debugger, as MEGA
and HELP do on the MEGA65. A held key repeats as the keyboard repeats it. The keyboard's LEDs are
not set, so the CAPS LOCK LED does not show whether CAPS LOCK is on. A PS/2
keyboard can't wait, so keys typed while the core's input is full are
lost: the bytes of one key wait until there is room, and the keys typed
meanwhile give nothing. The MEGA65's keyboard loses only the keys pressed
and released in that time (see [The keyboard](#the-keyboard)).

The Nexys4DDR's LEDs, seven-segment display, buttons, and switches are
registers in `0xFFFFFF90`–`96`, for the core and the link alike. Only the
Nexys4DDR has them: on the MEGA65 these words read 0 and take no write,
where the emulator has memory there. `0xFFFFFF9E`, the size of
the RAM, is on every board (see [I/O registers](#io-registers)), and `0xFFFFFF9F`, the UART's
baud rate (see [The baud rate](DEBUG_LINK.md#the-baud-rate)), and so is the Ethernet
station at `0xFFFFFFB0` (see [The Ethernet
station](#the-ethernet-station)). Reset clears the
registers that can be written, and a start of the core does not, so a
program's display stays after it halts.

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
A, C, D, F, and G, which shows a 5 on digit 0. The display is scanned at about
1 kHz per digit, so the digits look steady. The RGB LEDs are very bright at
full level; 1 to 3 is a comfortable range. The buttons and the switches are
synchronized to the clock but not debounced. While the on-board debugger
has the focus ([DEBUGGER.md](DEBUGGER.md#the-nexys4ddr)), the buttons
are its keys and read 0 here, and the display shows its segments; the
registers keep their values and show again when the focus is left. The CPU RESET button is not a
register: it resets the system. The words `0xFFFFFF97` to `9D`
read 0 and take no write; the keyboard's LEDs may come to
`0xFFFFFF97`.

## The Ethernet station

`0xFFFFFFB0`–`BF` are on every board, the MEGA65 too. They are the
network station of [nice_cpu's SYSTEM.md §6](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#6-network-station), here the Ethernet station,
which carries the debug link over TCP
([DEBUG_LINK.md](DEBUG_LINK.md#the-debug-link-over-tcp)). It answers ARP requests for its
IP address and pings to it, and serves the link on TCP port 4510. Until
V1.7 it was at `0xFFFFFF98`–`9D`, in another order and without
`NET_STATUS`.

| Address | Name | Access | What it is |
|---|---|---|---|
| `0xFFFFFFB0` | `NET_IP` | Read, write | The IP address, the first byte in bits 31..24: `0xC0A80141` is 192.168.1.65. 0 after reset, which answers nothing. |
| `0xFFFFFFB1` | `NET_MAC_HI` | Read, write | The first two bytes of the MAC address, in bits 15..0. Bits 31..16 read 0 and are dropped. |
| `0xFFFFFFB2` | `NET_MAC_LO` | Read, write | The last four bytes of the MAC address. The address is 02:4E:49:43:45:00 after reset. |
| `0xFFFFFFB3` | `NET_RX_GOOD` | Read only | The good frames received, to any address. |
| `0xFFFFFFB4` | `NET_RX_BAD` | Read only | The bad frames received, and the good ones that were dropped. |
| `0xFFFFFFB5` | `NET_TX` | Read only | The frames sent: the ARP and ping replies, the TCP segments, and a program's frames. |
| `0xFFFFFFB6` | `NET_STATUS` | Read only | Bit 31 while a host is connected to the link over TCP, and the TCP port of the link, 4510, in bits 15..0. |
| `0xFFFFFFB7`–`BF` | | Read only | 0. |

Only a reset of the system sets the addresses and the counts, not a
start of the core nor the link's clear, so a host keeps its connection
through a start, and a program finds the addresses that an earlier one
set. The counts start at 0 at reset and wrap at 2^32. A good frame has at
least 64 bytes and a right frame check sequence, and has come through the
FIFO of received frames to the system clock. A bad frame has a wrong
sequence, is shorter, did not end on a byte, or had a receive error, a
symbol that the PHY could not decode. A good frame is dropped
when it finds that FIFO full. The PHY negotiates the link on its own, so
a cable to a switch gives a good count that rises with the broadcasts on
the network, and a bad count that stays at 0. The station works only at
100 Mbit/s; with a link at 10 Mbit/s, every frame counts as bad. A write
to `0xFFFFFFB0`–`B2` while a host is connected, or while a reply goes
out, breaks that connection or reply. The frames that the station does
not serve go to the port for Ethernet frames (see [Ethernet
frames](#ethernet-frames)).

The station keeps the frames to its MAC address and to everyone, and
drops the others. It answers each ARP request for its IP address with
an ARP reply, and each ICMP echo request, a ping, to its MAC and IP
addresses with an echo reply of the same data, up to the 1472 bytes that
fit in a frame. It answers only whole IPv4 packets without options, and
no ping to everyone. With the IP address at 0, as after reset, it answers
nothing, so a board on a network stays silent until a program or the
link gives it an address. The MAC address is a locally administered one;
two boards on one network need different ones. On the link, for example:

    make mon PORT=/dev/ttyUSB3
    dbg> w FFFFFFB0 C0A80141

Then `ping 192.168.1.65` from a PC on the network gets its answers, and
`0xFFFFFFB5` counts the replies, the ARP reply and one for each ping.
The monitor's `i` shows and sets the IP address from the keyboard or
the line, and its `m` the MAC address
([monitor/README.md](../monitor/README.md)). With the demo in
the ROM, its F11, after the monitor's `x`, shows the addresses and the counts,
and sets the addresses from the keyboard
([demo/README.md](../demo/README.md)).

### Ethernet frames

`0xFFFFFFC0`–`CF` are the port for Ethernet frames of [nice_cpu's
SYSTEM.md §7](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#7-ethernet-frames), on every board. A program sends and receives frames of its
own through it, for DHCP, DNS, or TFTP, and builds and parses them
itself. §7 has the registers, the queue of 4 frames received, the send
buffer, and the window of `ETH_BUF0`–`7` on them. Before V1.7.2 these
words were memory.

The station keeps the frames it serves, as niceemu's does: an ARP
request for its IP address, an ICMP echo request to it, and TCP to port
4510 of it, while the IP address is not 0. Every other frame to its MAC
address, or to everyone, goes to the port, so while the IP address is 0
they all do. The station decides as niceemu does, from the headers, so
a program sees the frames that it sees in niceemu. A ping that the
station keeps may still get no answer, as its responder answers only the
pings above. The port takes a frame only while it is enabled, and counts
it in `ETH_DROPPED` when its queue is full. A frame that the station
keeps never counts there.

A frame that a program sends goes out with the station's own frames,
one at a time; the replies and the TCP segments of the link come first
when they are ready at the same time. The station pads a frame shorter
than 60 bytes, adds the check sequence, and counts it in `NET_TX`. Busy,
bit 2 of `ETH_CSR`, reads 1 while the frame is copied into the station's
FIFO of frames to send, about 6 cycles a word: 0.3 µs for a frame of 20
bytes and 23 µs for one of 1514 at 100 MHz, and longer while the station
sends a frame of its own first. The frame may still be on its way to the
wire when busy is 0, but the send buffer is free, as the FIFO has the
whole frame. The emulator sends a frame in the write of `ETH_TX_LEN`.

A start of the core resets the port: it is disabled, its queue is
empty, and `ETH_DROPPED` and `ETH_CHUNK` are 0. A frame that is being
sent goes on. The send buffer keeps its words, and is 0 after a reset
of the system. The link reads and writes the port as the core does,
while the core is paused, held, or halted.

The monitor in the ROM uses the port in its `i dhcp`, which gets the
station's IP address from a DHCP server, in its `tftp`, which loads a
file from a TFTP server, and in its UDP entries for programs.
It disables the port at its start, at the end of `i dhcp` and `tftp`,
and when a program returns, so a program that does not enable it sees
no frame. Its frame routines and ARP cache are its own, with no entries
for programs ([monitor/](../monitor/README.md#the-network)).

## The SD card slots

The SD card controller of [nice_cpu's SYSTEM.md §5](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#5-sd-card) is at
`0xFFFFFFA0`–`AF`, with the boards' slots.
`SD_SLOTS` is 2 on the MEGA65 and 1 on the Nexys4DDR.

| Board | Slot 0, the default | Slot 1 |
|---|---|---|
| MEGA65 R3 and R6 | The microSD slot at the back | The full-size slot underneath, with the MEGA65's system files |
| Nexys4DDR | The microSD slot | none |

- The controller runs the cards in SPI mode: CLK is the clock, CMD the
  data to the card, DAT3 the chip select, and DAT0 the data from the
  card. DAT1 and DAT2 are not driven. One engine serves both slots, and
  the slot that it does not serve rests, with its clock low and the
  other lines high.
- Init starts the card at 400 kHz, and the commands after it run at
  25 MHz on the MEGA65 and 22.5 MHz on the Nexys4DDR, the clock divided
  by 4. It reads the card's version, its type, SDSC or SDHC and SDXC,
  and its size from the CSD, and it turns the card's CRC checks on, so
  that a corrupted command or block fails with error 4. Every step has a
  timeout: about a second for the start-up, 100 ms for a block to read,
  and 500 ms for a block to be written.
- A command takes time: busy reads 1 until it ends, as on any board of
  [nice_cpu's SYSTEM.md §5](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#5-sd-card), where the emulator ends it at once. A Read
  takes up to about a millisecond, and an Init tens of milliseconds.
- Every slot has card detect, and the MEGA65's slot 1 also has write
  protect. A card that is put in or taken out counts after 10 ms, but
  after a reset the slot shows at once what the pin says, so a card
  that is in is there for the first command.
- The MEGA65's cards are always powered. The Nexys4DDR switches its
  card's power with `SD_RESET`: off after reset, off for 20 ms and on
  again at each Init, so that the card starts from power-up, and on
  after it.
- A start of the core resets the controller's registers: a Write that
  runs finishes first, so that no sector is torn, and any other command
  is abandoned. The controller runs while the core is held, paused, or
  halted, so the link reaches the card then. After a reset that
  abandoned a command, the next Init first clocks 1024 bytes, so that a
  card in the middle of a block finishes it.
- On the R3, slot 0's DAT1, DAT2, CMD, and DAT0 also reach the JTAG pins
  of the MAX10, so the slot runs in SPI mode or 1-bit SD mode only. Plug
  no JTAG cable into the MAX10's header J17 while a card is in it.
- On the R3, slot 1 has no card detect and no write protect, as the
  common pin of the socket's switches is not connected to GND. The R3
  build ignores them, so a missing card shows as a failed start-up,
  error 3 or 8. The R3A fixed it, but one core serves both.
