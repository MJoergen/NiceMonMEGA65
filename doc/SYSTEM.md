# The system

This is the system that a program and the debug link see on the MEGA65 R3
and R6, and on the Nexys4DDR: the debug link on the UART, the address map,
the screen, the keyboard, the ROM, the Nexys4DDR's devices, and the
Ethernet station, which every board has. It follows nice_cpu's
[doc/SYSTEM.md](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md) for the devices and
[doc/DEBUG.md](https://github.com/MJoergen/nice_cpu/blob/main/doc/DEBUG.md) for the link.
[EMULATOR.md](EMULATOR.md) lists where it differs from `niceemu`.
`src/nicemon.vhd` is the system, and its header is the authoritative
address map. DEBUG.md, ISA.md, and MICROARCH.md are nice_cpu's, in
`nice_cpu/doc/`, and so is the SYSTEM.md with a section number, which is
not this file.

## The debug link

These words are used here and in the other documents and sources:

| Word | Meaning |
|---|---|
| The link | nice_cpu's debug link: packets between the console bytes on the UART, with which a host reads and writes memory and the debug registers. |
| Hold | Bit 0 of the control register at `0xFFFFFFF0` is 1: the core is in reset, and the link reaches all of memory. Without a ROM, the core is held at power-up. |
| Start | Bit 0 goes from 1 to 0: the devices are reset, and the core runs from address 0. |
| Hide | Bit 3 of the control register is 1: the ROM is out of the way, so the RAM is at 0, as in the emulator. |
| Clear | A write with bit 2 set fills the RAM and the screen with 0. |
| Pause | Bit 4 of the control register is 1: the core stops between two instructions, and the link reaches all of memory and the core's registers. Writing 0 to bit 4 makes the program go on. |
| Step | Bits 4 and 5 written to a paused core: it runs one instruction, or enters an interrupt, and pauses again. |
| Notice | A packet that the board sends on its own: `b05` at reset (the link's version, 5), `h` when the core halts, `p` when it pauses, `x` when it stops at a breakpoint, and `o` when an input byte is lost. |

The MEGA65's debug UART runs at 2 Mbaud (2000000), 8-N-1, and carries the
debug link of nice_cpu's [doc/DEBUG.md](https://github.com/MJoergen/nice_cpu/blob/main/doc/DEBUG.md). It passes
the program's console bytes both ways, and between them it carries
packets, which start with the byte `0xFF`. A console byte `0xFF` is sent
as two. With the packets, a host reads and writes memory and the debug
registers at `0xFFFFFFE0`–`FF` (see [Address map](#address-map)). The
board sends a notice at reset (`b05`), when the core halts (`h` and the
reason), and when an input byte is lost (`o`). The tools in `tools/` are
such a host, and `niceemu --link` serves the same link, so the tools
drive the emulator as they drive the board. The tools use 2 Mbaud too.

The Ethernet port carries the same line over TCP (see [The debug link
over TCP](#the-debug-link-over-tcp)). While a host is connected there,
its connection takes the UART's place in what this document says of the
UART: the console bytes, the packets, the notices, and the break.
While the on-board debugger is up ([DEBUGGER.md](DEBUGGER.md)), in
Focus or in Strip, it drives the link itself, and the bytes of both the
UART and TCP are dropped, and none is sent to them; so are a break, a
host's half-close, and the renewal of a new connection.

Without a ROM, the core is held in reset at power-up; with one, it runs
the ROM (see [The ROM](#the-rom)). A host loads a program with two
writes to the control register at `0xFFFFFFF0` around the writes of its
words. `0x0000000D` holds the core, clears the memory, and hides the ROM,
and `0x00000008` starts the core with the ROM still hidden (see
[The ROM](#the-rom)). A start without bit 3 shows the ROM again, which
boots instead of the program. `tools/load.py` does all of this.

While the core runs, the link reaches only its debug registers, and a
request for any other word gets the error answer `e` with code 02. A
write to the control register that holds the core works at any time, so
a host can always stop a program. While the core is held in reset or has
halted, the link reaches the whole address map.

A host can also pause a program, with link version 2. A write of
`0x00000018` asks for a pause: the core stops at the next step boundary,
and the link sends `p`, which may come before the `k` of the write. While
the core is paused, the link reaches the whole address map, R0–R15 at
`0xFFFFFFE0`–`EF` hold the core's registers, and the counters and the timer
stop. A write of `0x00000008` makes the program go on. A hold of a paused
core keeps R0–R15 until the next start or clear.

With link version 3, a host can step a paused program. A write of
`0x00000038` runs one step, an instruction or an interrupt entry, and the
core pauses again: the link sends `p`, or `h` if the step halted. Bit 5
reads 0, and does nothing unless the core is paused. During the step the
link reaches only its debug registers, and the counters and the timer run.
A write of `0x00000018` to a held core starts it paused at address 0, so a
host can step a program from its first instruction.

With link version 4, the board has four breakpoints. A host writes an
address to `0xFFFFFFF8`–`FB` and sets its bit in `0xFFFFFFF4`. The core
then pauses before the instruction at that address, and the link sends `x`
with the breakpoint's number, such as `x00#D8`, instead of `p`. After `x`
the core is paused as after `p`, and `0xFFFFFFF6` tells which breakpoint it
stopped at. When the program goes on, it runs that instruction, and does
not stop at it again. A step or a pause that ends at a breakpoint sends `x`
too. The breakpoints take a write at any time, and a reset clears them.
`tools/load.py` and `tools/run.py` disable them before they load a program.

With link version 5, a clear ends the halt and the stop of the program
it wipes. When the clear starts, bit 1 of the control register, the halt
reason, and the stop register become 0. So after `0x0000000D` the
control register reads `0x00000009`, also after a halt. A hold alone
keeps them, as before.

A terminal on the line, a plain TCP client such as `nc` on the Ethernet
port or a terminal program on the UART, shows what the program prints,
and what you type goes to the program while it runs. Bytes typed while it is paused wait
for it, and bytes typed while the core is held in reset or has halted
are dropped. The notices show up in the terminal too, as a few letters
after a stray character, such as `h01#C9` after a `HALT`.

## Address map

The link and the core's data accesses see the same addresses, but for the
debug registers at `0xFFFFFFE0`–`FF`, which only the link sees, and the
console and the read counter, which the link reads as 0 without a side
effect and does not write (DEBUG.md §3).

| Address | What it is |
|---|---|
| `0x00000000`–`0xFFFFFFFF` | Memory, where no register below is: 64K words of block RAM, repeated through the address space. So the runtime's stack below `0xFFFFFF00` lands in the top of it, and so do the words of `0xFFFFFF00`–`FF` that are not registers. |
| `0x00000000`–`0x00007FFF` | The ROM, in a bitstream built with one, in front of the RAM and repeating with it (see [The ROM](#the-rom)). Bit 3 of the control register hides it. |
| `0xFFFF0000`–`0xFFFF7FFF` | The screen: 32768 words of memory of their own, the emulator's 80×25 screen and room for scrolling. The 2000 words from the display offset are shown on VGA and HDMI, or VGA only on the Nexys4DDR (see [The screen](#the-screen)), and the link reads them all. |
| `0xFFFF8000`–`0xFFFFFEFF` | RAM, between the screen and the I/O page: the RAM words `0x8000`–`0xFEFF`, as the 64K words repeat. On the Nexys4DDR, whose screen is 8192 words, it starts lower: `0xFFFF2000`–`0xFFFFFEFF` are the words `0x2000`–`0xFEFF`. The runtime's stack starts at `0xFFFFFF00` and grows down into it, and so does the stack of a program in the ROM, such as the demo. In the emulator it is ordinary memory. |
| `0xFFFFFF00` | The console of nice_cpu's SYSTEM.md §1. A write sends bits 7..0 to the UART. A read takes the oldest byte received from the UART or the keyboard, and returns it in bits 7..0 with bit 8 set, or 0 when no byte has arrived. A break on the UART, or a host's half-close over Ethernet, ends the line's input until the core is started again or a host connects over Ethernet (see [The debug link over TCP](#the-debug-link-over-tcp)): the host's bytes after it are dropped, and once the bytes before it are read, a read returns `0x200` (bit 9), as at the end of the emulator's input. The keyboard's bytes still come, and a read returns them (nice_cpu's SYSTEM.md §5). |
| `0xFFFFFF01` | The emulator's read counter. A read by the core returns the number of its reads since the last write, and a write sets that number. It is 0 after reset, and a start keeps it, as in the emulator. |
| `0xFFFFFF10`–`0xFFFFFF1F` | The timer of nice_cpu's SYSTEM.md §4: it raises IRQ every P clock cycles, through the vector it is given. |
| `0xFFFFFF20`–`0xFFFFFF3F` | The math unit of nice_cpu's SYSTEM.md §2: 32-bit multiply and divide, and 64-bit divide. |
| `0xFFFFFF40`–`0xFFFFFF4F` | The performance counters of nice_cpu's SYSTEM.md §3: cycles, instructions, and microseconds, 64 bits each. The microseconds come from the clock, 100 MHz on the MEGA65 and 90 MHz on the Nexys4DDR, so they are real time, where the emulator counts one per step. They stop while the core is paused. The link reads them as the core does: a read of a low word takes the snapshot that the high word returns, where `niceemu --link` takes none. DEBUG.md §3 allows both while the core is held, halted, or paused. The words `0xFFFFFF46`–`4F` read 0 and take no write. |
| `0xFFFFFF50`–`0xFFFFFF7F` | The fetch statistics of MICROARCH.md §8.1, the rest of the performance counters: counters of what FETCH and DECODE do, for judging the size of FETCH's buffer. A start of the core clears them, and they then count each clock while the core runs, until a write of 0 to `FS_CTRL` stops them. They stop while the core is held and after it halts. With the multi-cycle core (`NICE=multi`), only `FS_CYCLES` and `FS_HIST[0]` count, `FS_CTRL` reads its run bit, and the other words read 0. |
| `0xFFFFFF80`–`0xFFFFFF8F` | The screen's registers: the cursor and the display offset (see [The screen](#the-screen)). |
| `0xFFFFFF90`–`0xFFFFFF9F` | The Nexys4DDR's LEDs, seven-segment display, buttons, and switches (see [The Nexys4DDR's devices](#the-nexys4ddrs-devices)). On the MEGA65 they read 0 and take no write. On every board, `0xFFFFFF98`–`9D` are the Ethernet station (see [The Ethernet station](#the-ethernet-station)). |
| `0xFFFFFFE0`–`0xFFFFFFEF` | The debug registers of DEBUG.md §6, for the link only, here and below: R0–R15 of the core, read only. After a halt they hold what the emulator prints. While the core is paused they hold its registers, with R15 the address of the next instruction, and a hold of the paused core keeps them. A hold of a running core leaves them undefined. |
| `0xFFFFFFF0` | Control: hold, clear, hide, pause, and step (see [The control register](#the-control-register)). |
| `0xFFFFFFF1` | Read only: why the core halted. 0 while it has not, and after a clear, 1 for `HALT`, 2 for a reserved control word, 3 for `INT` inside an interrupt routine, and 4 for `RTI` outside one. Reason 5, the step limit of `niceemu --link`, is the emulator's only. |
| `0xFFFFFFF2` | Read only: the version of the link, 5. |
| `0xFFFFFFF3` | Read only: the bytes of free space in the core's input FIFO. |
| `0xFFFFFFF4` | The enable bits of the breakpoints: bit i enables breakpoint i. Bits 4 to 31 read 0. |
| `0xFFFFFFF5` | Read only: the number of breakpoints, 4. |
| `0xFFFFFFF6` | Read only: the stop. From an `x` until the program goes on, steps, starts, or is cleared, bit 8 is 1 and bits 7–0 are the breakpoint's number. Otherwise 0. |
| `0xFFFFFFF7` | Reserved: reads 0. |
| `0xFFFFFFF8`–`0xFFFFFFFB` | The addresses of breakpoints 0 to 3. `0xFFFFFFFC`–`FF` read 0. A reset clears the breakpoints, and a hold, a start, and a clear keep them. |

### The control register

| Bit | Name | Meaning |
|---|---|---|
| 0 | Hold | 1 holds the core in reset. A write of 0 starts it. |
| 1 | Halted | Read only. 1 after a halt, and stays 1 while the core is held in reset, until the next start or clear. |
| 2 | Clear | A write with bit 2 set first clears the RAM and the screen to 0, with the core held, and is answered when the memory is clear, after 0.66 ms at 100 MHz. Bit 3 takes effect when the clear starts, and bit 0 when it ends. |
| 3 | Hide | 1 hides the ROM, so that the RAM is at 0. Reset clears it in a bitstream with a ROM; in one without a ROM it reads 1. |
| 4 | Pause | A write of 1 pauses the core at the next step boundary, and the link sends `p`. It reads 1 while the core is paused, and a write of 0 makes the program go on. A start with bit 4 set pauses before the first instruction. |
| 5 | Step | A write with bits 4 and 5 set to a paused core runs one step, and the link sends `p` again, or `h`. It reads 0. |

The tools write these values:

| Value | Bits | Effect |
|---|---|---|
| `0x0000000D` | Hold, clear, and hide | Stops the core and prepares the memory for a load. |
| `0x00000008` | Hide | Starts or continues the program, with the ROM still hidden. |
| `0x00000018` | Hide and pause | Pauses a running core, or starts a held one paused at address 0. |
| `0x00000038` | Hide, pause, and step | Runs one step of a paused core. |

Instruction fetches from `0xFFFFFF00`–`0xFFFFFFFF` read 0, as ISA.md §8.3
requires.

The input waits for the core in a FIFO of 2048 bytes, in block RAM. A
UART byte that arrives when it is full is lost, and the link sends its
`o` notice; a UART byte after a break is lost too, until a start, or a
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

The words `0xFFFFFF83`, `84`, and `86`–`8F` read 0 and take no write. In
the emulator these addresses are memory, so a program that writes them runs
there too, without scrolling. Reset, and the clear of the memory (bit 2 of
the control register, which `load.py` and `run.py` set), set the offset to
0 and turn the cursor off, as at the start of the emulator. From
nice_cpu V1.2 on, `niceemu --window` draws the same cursor from these
words, as nice_cpu's SYSTEM.md §1 says, but has no display offset.
A column or row out of range shows no cursor there, where here only
bits 6..0 of the column and 4..0 of the row are kept.

A write of `0x000FFF41` to `0xFFFF0000` puts an `A` in the top left
corner, white on black, and one of `0xF00FFF42` to `0xFFFF0001` a white `B`
on red next to it.

The video output comes from MandelbrotMEGA65, which uses the same mode on
the MEGA65. The HDMI output is DVI, without sound.

## The keyboard

The MEGA65's own keyboard types into the same input as the UART: what
you type goes to the program while it runs or is paused, and is dropped
while the core is held in reset or has halted. The keys give ASCII, as a
terminal sends it. nice_cpu's SYSTEM.md §1 defines the bytes of the keys
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
| MEGA with CRSR↑ or CRSR↓ | Page Up or Page Down, `ESC [ 5 ~` or `ESC [ 6 ~`, as xterm sends them; SHIFT with CRSR↓ is CRSR↑ here too |
| CTRL with a letter | Its control code |
| £, ↑, ← | `\`, `^`, `_` (`\|`, `~`, `` ` `` with SHIFT) |
| SHIFT with `0`, `=`, `:`, `;` | `{`, `}`, `[`, `]` |

A held key repeats after half a second, 20 times a second. F13, HELP,
and the modifiers give nothing, and MEGA changes no key but the cursor
keys up and down. MEGA and HELP together toggle the
on-board debugger ([DEBUGGER.md](DEBUGGER.md)), and while it is up the
keys go to it, not to the core, and it has the debug link. The keyboard's drive
LED is green while the core runs, like the user LED.

The bytes of a key wait until the core's input has room for them, and
the keyboard is not scanned meanwhile, so a key that is pressed and
released while they wait is lost. A key held down until then is not.

## The ROM

A bitstream built with `make r6 ROM=file.bin` (or `make r3 ...`) has a ROM
of 32K words at `0x0000`–`0x7FFF`, in front of the RAM, with the words of the
`.bin` file, and its core boots from it at reset instead of waiting held for
a host. That is the layout of QNICE-FPGA, whose monitor is in ROM at
`0x0000`–`0x7FFF` and whose programs load at `0x8000`, and the
[monitor](../monitor/README.md) is built for it, though the release's
ROM still holds the demo. The file is read by Vivado, so the ROM changes only with a
new bitstream, and a word beyond the ROM fails the build. A write to the
ROM is dropped, and a clear (bit 2 of the control register) does not
touch it. So a program in the ROM must keep its stack and its variables
in the RAM, at `0x8000` or above: `sim/rom.nasm`, the greeting that the
tests use as the ROM, has its stack at the top of the memory, as the
runtime has, and so has the demo that a release has in the ROM
([demo/](../demo/README.md)). With a stack in the ROM, as `hello.nasm` of
nice_cpu has at `0x1000`, a pushed return address is lost and reads back
as 0, and the program starts over, forever.

A C program cannot run from the ROM either: it keeps its data in its own
image, which would be in the ROM, so its writes would be lost.

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
where the emulator has memory there. `0xFFFFFF98`–`9D`, the Ethernet
station, are on every board (see [The Ethernet
station](#the-ethernet-station)). Reset clears the registers
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
A, C, D, F, and G, which shows a 5 on digit 0. The display is scanned at about
1 kHz per digit, so the digits look steady. The RGB LEDs are very bright at
full level; 1 to 3 is a comfortable range. The buttons and the switches are
synchronized to the clock but not debounced. While the on-board debugger
has the focus ([DEBUGGER.md](DEBUGGER.md#the-nexys4ddr)), the buttons
are its keys and read 0 here, and the display shows its segments; the
registers keep their values and show again when the focus is left. The CPU RESET button is not a
register: it resets the system. The words `0xFFFFFF97`, `9E`, and `9F`
read 0 and take no write; the keyboard's LEDs may come to `0xFFFFFF97`
(see [#25](https://github.com/MJoergen/NiceMonMEGA65/issues/25)).

## The Ethernet station

`0xFFFFFF98`–`9D` are on every board, the MEGA65 too. They are the
Ethernet station, which carries the debug link over TCP
([#30](https://github.com/MJoergen/NiceMonMEGA65/issues/30)). It
answers ARP requests for its IP address and pings to it, and serves the
link on TCP port 4510.

| Address | Access | What it is |
|---|---|---|
| `0xFFFFFF98` | Read only | The good frames received, to any address. |
| `0xFFFFFF99` | Read only | The bad frames received, and the good ones that were dropped. |
| `0xFFFFFF9A` | Read, write | The IP address, the first byte in bits 31..24: `0xC0A80141` is 192.168.1.65. 0 after reset, which answers nothing. |
| `0xFFFFFF9B` | Read, write | The first two bytes of the MAC address, in bits 15..0. Bits 31..16 read 0 and are dropped. |
| `0xFFFFFF9C` | Read, write | The last four bytes of the MAC address. The address is 02:4E:49:43:45:00 after reset. |
| `0xFFFFFF9D` | Read only | The frames sent: the ARP and ping replies, and the TCP segments. |

The counts start at 0 at reset and wrap at 2^32. A good frame has at
least 64 bytes and a right frame check sequence, and has come through the
FIFO of received frames to the system clock. A bad frame has a wrong
sequence, is shorter, did not end on a byte, or had a receive error, a
symbol that the PHY could not decode. A good frame is dropped
when it finds that FIFO full. The PHY negotiates the link on its own, so
a cable to a switch gives a good count that rises with the broadcasts on
the network, and a bad count that stays at 0. The station works only at
100 Mbit/s; with a link at 10 Mbit/s, every frame counts as bad. A write
to `0xFFFFFF9A`–`9C` while a host is connected, or while a reply goes
out, breaks that connection or reply.

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
    mon> w FFFFFF9A C0A80141

Then `ping 192.168.1.65` from a PC on the network gets its answers, and
`0xFFFFFF9D` counts the replies, the ARP reply and one for each ping.
With the demo in the ROM, its F11 shows the addresses and the counts,
and sets the addresses from the keyboard
([demo/README.md](../demo/README.md)).

### The debug link over TCP

The station serves the debug link on TCP port 4510 of its IP address,
to one host at a time. While a host is connected, the link's bytes come
from it and go to it, and not to the UART, whose bytes are dropped. A
host is connected from its ACK of the board's SYN-ACK on, so a SYN alone,
as of a port scan, leaves the link on the UART. The
connection is the line, as the UART is: connecting sends no `b` notice
and resets nothing, unlike `niceemu --link` (DEBUG.md §7), and a host's
half-close is a break, which ends the line's input. The tools take
`--eth HOST`, or `--eth HOST:PORT`, for it:

    python3 tools/run.py --eth 192.168.1.65 prog.bin
    make mon ARGS="--eth 192.168.1.65"

A new connection from the same host replaces the old one. The old one
gets the output that came before the new connection, and then the board
closes it, and only then takes the new one: when the host has
acknowledged the board's FIN, or reset the old connection, or after the
tries below. The tools half-close the old one first, at the end of a
program's input. If that FIN was lost, the old connection still takes
the host's data and FIN until it ends, and if the FIN has not come by
then, the end is a break. A connection from another host gets a reset
while one is open, so that its `connect` fails at once with "connection
refused".

A host's FIN is the end of the line's input, and the board keeps the
connection after it, so a host that is done ends it with a reset. A new
connection starts the line's input anew, as one to `niceemu --link` does
(DEBUG.md §7): once the program has read the old connection's bytes, the
console no longer reads `0x200`, and the new host's bytes reach the
program, so a host can type to a monitor that another host has left. The
tools set
`SO_LINGER` to 0 for that, so that each close of theirs, also at an exit
or a kill, sends one. A connection that a host closed with only a FIN
stays until that host connects again, or the board resets. The board
resends what the host does not acknowledge, after 300 ms, and drops the
connection after 17 tries. While the host's window is 0, it sends one
byte beyond it every 300 ms, and keeps the connection while the host
answers. It answers a host's keepalive probe with an ACK, and sends no
probe itself. A segment to the port that fits no connection, as one of
a connection that the board dropped, gets a reset, as RFC 9293 has it,
but for a reset, which gets nothing. Once a connection is open, a
segment without ACK is dropped, and one that acknowledges what the board
has not sent gets an ACK and is dropped. Segments to other ports get nothing,
and neither does anything while the IP address is 0, also after the
board resets, until it has an address again. Its SYN-ACK has no TCP options, so the host sends
segments of at most 536 bytes, and the board sends no more either. When a connection ends, the link
stays with it until it has taken the input that came before, and the
output in that time is dropped.

The link reads and writes all memory with no password, so anyone who
can reach the port can do the same. The IP address is 0 after reset,
which serves nothing, so a board is reachable only after a program or
the UART's link gives it an address. Give it one only on a network you
trust.
