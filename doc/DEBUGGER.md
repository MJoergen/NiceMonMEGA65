# The on-board debugger

A debugger in the FPGA, with the MEGA65's own keyboard and screen and no
host: what `tools/mon.py` does over the debug link, in a strip of text
under the program's screen, and a page over it. **Stages 1 to 9 are
written, and the rest is planned**
([#52](https://github.com/MJoergen/NiceMonMEGA65/issues/52) and
[#53](https://github.com/MJoergen/NiceMonMEGA65/issues/53)): the toggle
key enters Focus, where the strip shows the core's state, its registers,
live while it runs, and the word at the PC at a stop, and F1 to F9 run
the core; F12 keeps the strip up when Focus is left, and a stop in Strip
comes back to Focus; and F11 shows the page, a window on the memory,
where a word is written and a breakpoint set at the cursor. The debugger
is a client of the debug link inside the system, beside a host on the
UART or over TCP, which keeps its line. The README's
[On its own](../README.md#the-on-board-debugger) says how to use it,
with a picture. This note
records the design and the decisions, as
[monitor/README.md](../monitor/README.md) does for the ROM of
[#24](https://github.com/MJoergen/NiceMonMEGA65/issues/24), a hardware
abstraction layer for programs, which the debugger does not need and
does not touch. It cannot load a program, so a host, the ROM, or a later
SD card still does that.

The engine is the debug link of nice_cpu's
[DEBUG.md](https://github.com/MJoergen/nice_cpu/blob/main/doc/DEBUG.md),
which has everything the debugger needs: pause, step, go on, hold, start,
the four breakpoints, R0–R15 at a stop, and the memory while the core is
stopped. What the link cannot do, the debugger cannot either: write a
register ([#22](https://github.com/MJoergen/NiceMonMEGA65/issues/22)),
load a program without a host, or know a label.

## The states

The debugger has three states, and the core's state is a different
thing: the debugger can be up while the program runs.

| State | Overlay | The link's side port | The keyboard |
|---|---|---|---|
| Off | None | Not used | The program's |
| Strip | The strip, live | Read, 60 times a second | The program's |
| Focus | The strip, and the page on demand | Read, and written by the keys | The debugger's |

The line, the UART's or the TCP connection's, is the host's in every
state.

- Reset leaves it Off. Nothing changes for anyone who never presses the
  key combination.
- MEGA+HELP toggles Focus, Scroll Lock on the Nexys4DDR. Leaving Focus
  goes to Strip or Off, as a sticky setting says; F12 in Focus toggles
  the setting, and it is Off after reset.
- On the Nexys4DDR, Focus takes the board's buttons and its seven-segment
  display too (see [The Nexys4DDR](#the-nexys4ddr)).
- In Strip, a halt, or a pause the debugger did not ask for, such as a
  breakpoint, takes the debugger to Focus: it catches what stops the
  core. It sees the stop as a rising edge of the core's pause or halt,
  `nicemon`'s `paused_o` and `halted_o`, as the link's side port brings
  no notices. A step or a pause of its own keys is not caught, also when
  Focus was left before the stop came. Off is not caught from: a host's
  tools stop the core on purpose, and a catch would take the keyboard
  from the program and show the debugger to those who never press the
  combination.
- In every state the line is the host's, the UART's or the TCP
  connection's: the debugger is a second client of the link, through its
  side port ([below](#how-it-drives-the-link)), and the host keeps its
  answers, its notices, and the console. The host gets the notices of a
  stop that the debugger caused, `p`, `x`, or `h`, as it does for a
  breakpoint, and may read a state it did not set (DEBUG.md §3).
- The program's keyboard input is unaffected in Off and Strip: the
  keyboard's bytes go into the console FIFO as now, not through the link.
  The console is the host's in every state, both ways; a console page
  here waits for a tap on the core's output.

## The display

The text display (`src/video/text.vhd`) shows 25 rows of 80 characters
of 16x32 pixels, 1280x800 pixels in the 1280x1024 frame that both boards
use, centered: 112 black lines above and below. The debugger adds 4 rows
under the text, and the 29 rows are centered instead: 48 black lines, the
program's 25 rows, the strip's 4, and 48 black lines. So the program's
picture moves up 64 lines, in every state, and nothing jumps when the
strip appears. `C_Y0` becomes `(v_visible - 29 * 32) / 2`, and the
assert that the text fits counts 29 rows.

The strip, rows 25 to 28, is black in Off. In Strip and Focus it is white
on dark blue, `0x004` and `0xFFF`:

```
 R0-7   00000000 00000001 0000FFFF 00000010 00000000 00000000 00000000 00000000
 R8-15  00000000 00000000 00000000 00000000 00000000 FFFFFEF0 00000003 00001234
 PAUSED   00001234  xxxxxxxx  X C . . . . I   ADD[CM] R1, @0x40, R1
 F1 step  F3 go  F5 pause  F7 hold  F9 restart  F11 page  F12 keep strip: off
```

- Rows 25 and 26: R0–R15 in hex, as the link returns them (DEBUG.md
  §6): live while the core runs, as `niceemu --link` returns them
  ([nice_cpu#85](https://github.com/MJoergen/nice_cpu/issues/85)), and
  the stop's values while it is paused or has halted. While it is held
  they are dimmed: the link keeps the values of the last stop then,
  which may be another program's.
- Row 27: the core's state, `RUNNING`, `PAUSED`, `BRK n` at breakpoint
  n, `HALTED n` with the reason of DEBUG.md §6, `HELD`, or `NO LINK`
  until the link has answered after reset; the PC; the
  instruction word at the PC; the flags of SR, X, C, Z, N, V, E, and I,
  each shown or a dot; and the instruction decoded, from column 46: the
  condition, the mnemonic with `[C]`, `[M]`, or `[CM]`, and the
  operands, in the assembler's syntax as `nicedis.py` writes it, with
  the constant words folded in, in hex, such as `?!Z MOVE R15, 0x2`. A
  text longer than the 34 columns ends in `>`, and a reserved control
  word is `reserved`. The debugger reads the constant words that the
  instruction word says it takes, and none past them, which could be a
  device's register. While the core runs the
  memory is out of reach (DEBUG.md §3), so the row shows the state and
  the PC, dashes for the word, and no decode; while the core is held,
  dashes for the PC too.
- Row 28: the keys, and the sticky setting, `keep strip: off` or `on`.
  In Strip, where the keys are the program's, it says so, and names the
  toggle key: `The keys are the program's.  MEGA+HELP for the debugger`.
  The row in Focus has no room for the toggle key's name with F11 in it.

The page replaces the program's 25 rows while it is up, in Focus only:
row 0 has the window's address, the cursor's, and the addresses of
breakpoints 0 to 3, in that order, dashes for one that is not enabled;
rows 1 to 22 the memory from the window's address, a row's address and
its 8 words, the cursor's word in swapped colors, and a word at an
enabled breakpoint white on dark red, or dark red on white under the
cursor; row 23 the input
field, its label, `Word:` or `Address:`, and the last message,
`written`, the link's error such as `e02`, `no answer`, or `none free`
when `b` finds every breakpoint in use; and row 24
the keys. The program's cursor is hidden under the page. The page stays
on when Focus is left, and shows again when Focus comes back.

```
 Window 00000000  Cursor 00000009  Breaks 00000002 -------- -------- --------
00000000 00005800 00000000 006040B0 00000001 022080B0 00000800 B003D800 00000002
00000008 0C000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000
...
 Word:    1234____  written
 CRSR PgUp PgDn Home move  0-f type  RETURN write  a address  b break  ESC back
```

The words are read, all 176 in one request, when the page is shown and
the core is stopped: paused, halted, or held. They are read again after
a stop, a write, and a move of the window, and while the core runs they
are dimmed. A move of the window shows
dashes until the new words are read, and a read that a move overtook is
dropped. A code page, the decode of a range of instructions, comes with the
disassembler.

The overlay is a memory of its own, like the copy of the screen
(`src/video/scr_ram.vhd`): 2^12 words of 32 bits, 4 block RAMs, each
word a character and its colors as a screen word is, written by the
debugger in the system clock and read in the VGA clock. Rows 0 to 24 are
the page and 25 to 28 the strip, addressed row * 80 + column as the
screen is, without the display offset. Stage 2 of the pipeline reads it
beside the screen's copy, and stage 3 takes the overlay's word in the
strip's rows while the strip is on, and in the text's rows while the
page is on. Two mode bits, strip and page, cross to the VGA clock
through synchronizers: they change rarely, and a frame half changed does
no harm. The debugger draws its own cursor by swapping the colors of the
word it writes, so the display has no second cursor.

## The keys

In Focus, the keyboard's bytes (`src/kbd_m65_ascii.vhd`: ASCII, and
xterm's sequences for the cursor and function keys) go to the debugger
instead of the console FIFO. One key is one action, and the letters are
mon.py's:

| Key | Action |
|---|---|
| F1, `s` | Step: one step of a paused core; the strip shows the new state |
| F3, `g` | Go on |
| F5, `p` | Pause |
| F7, `h` | Hold: bit 0 of the control register |
| F9, `r` | Restart: hold, then start at 0, with bit 3, the ROM, as it is |
| F11, `m` | The page, on or off |
| F12 | The sticky setting: Strip or Off when Focus is left |
| MEGA+HELP, Scroll Lock | Leave Focus, for Off or Strip |

On the page:

| Key | Action |
|---|---|
| Cursor keys | Move the cursor; past the top or bottom row the window scrolls a row |
| Page Up, Page Down | Move the window 22 rows, a page |
| Home | Move the cursor to the window's first word |
| `0`–`9`, `a`–`f`, `A`–`F` | Shift a hex digit into the input field; the last 8 count |
| DEL | Remove the last digit; on an empty field, leave the address |
| RETURN | Write the field to the word under the cursor |
| `a` on an empty field, then digits, RETURN | Move the window to the address in the field, the cursor to its first word |
| `b` on an empty field | A breakpoint at the cursor's address: clear the one that is there, or set the lowest free one |
| ESC | Clear the field, or leave the page when it is empty |

The ESC key is a lone ESC: one with no byte after it for 1 ms, as the
keys' sequences come without a gap. A word that starts with `a` is typed
with a 0 before it, `0a…`, as only 8 digits count.

`b` writes the debug registers of DEBUG.md §4, which take a write while
the core runs too: the address of the breakpoint, then its enable bit.
A key that needs the core stopped, pressed while it runs, shows the
link's answer in the message row (`e02`) and does nothing else, as
mon.py prints its errors. F1 to F9 read the control register before they
write it: step and go on act only on a paused core, and pause only on a
running one, as go on and pause would otherwise start a held core.

Page Up, Page Down, and Home are bytes of both keyboards (written),
xterm's `ESC [ 5 ~`, `ESC [ 6 ~`, and `ESC [ H`. On the Nexys4DDR they
are the keys of those names. On the MEGA65, which has no such keys,
CLR/HOME is Home, and MEGA with CRSR↑ and CRSR↓ are Page Up and Page
Down, which makes MEGA a modifier in `kbd_m65_ascii.vhd`. Programs get them too, and the key tables of
[SYSTEM.md](SYSTEM.md#the-keyboard) move with them.

## The Nexys4DDR

The debugger is the same on the Nexys4DDR: the board uses the 1280x1024
mode too, so the 29 rows and the overlay are as above, and its keyboard
sends the same bytes. The board differs in its toggle key, its inputs
and outputs, and its room.

- **The toggle is Scroll Lock.** The board has a USB keyboard, which its
  PIC24 turns into PS/2 (`src/kbd_ps2.vhd`), and no key matrix, so the
  detector, `src/kbd_ps2_toggle.vhd`, parses the scan codes. Scroll
  Lock is `7E`, one byte with a plain release, gives nothing today, and
  should come through the converter as any key does; Pause, the key
  meant for this, has an eight-byte code without a release, and the
  converter may not pass it. The parser pulses on a `7E` that did not
  follow `F0`, the release prefix, and arms again only after `F0 7E`, so
  the keyboard's repeats of a held key toggle once. It ignores a `7E`
  after `E0`, which is part of Ctrl+Break. The first test on
  the board is the toggle itself: the demo's key-code page cannot show a
  key that gives nothing.
- **In Focus, the buttons and the seven-segment display are the
  debugger's**, as the keyboard is; in Off and Strip they are the
  program's registers ([SYSTEM.md](SYSTEM.md#the-nexys4ddrs-devices)),
  so a program keeps them while the strip is up, and the debugger needs
  none of them, since Scroll Lock enters Focus. BTNL steps, BTNR goes
  on, BTNU and BTND move the cursor, and BTNC leaves Focus (written).
  The program reads the buttons as 0 meanwhile: `system.vhd` gives
  `nicemon` the buttons masked by `focus_o`, and the debugger, which
  debounces them itself, the raw ones: it samples them every 5 ms, and
  a press is a sample at 1 after one at 0. The display shows the PC,
  eight hex digits on its eight digits, live while the core runs and the
  stop's at a stop, and dashes while the core is held or before the link
  has answered, through a hex-to-segments table in the
  debugger; `system.vhd` gives the board
  the debugger's segments in Focus and the program's otherwise. The
  LEDs stay the program's.
- **Row 28 names the board's toggle key**, from a generic of the
  debugger.
- **Room.** With stage 1, 92 of the 135 block RAMs are used without a
  ROM and 124 with one, so 11 are left at the least: the overlay took 4,
  and Vivado put the PS/2 table into one more
  ([synth/README.md](../synth/README.md#block-ram)); stage 3 adds half
  a block RAM, the table of the strip's cells, 92.5 without a ROM. The
  system clock is 90 MHz on a -1 part, built with retiming; the build of
  stage 1 has 0.289 ns of setup and 0.029 ns of hold slack, that of
  stage 3 0.339 ns and 0.031 ns, that of stage 4 0.532 ns and 0.029 ns,
  that of stage 5 0.111 ns and 0.017 ns, on a path in the core, that
  of stage 6 0.139 ns and 0.022 ns, also in the core, that of stage 7
  0.159 ns and 0.034 ns, that of stage 8 0.187 ns and 0.019 ns, that of
  stage 9 0.166 ns and 0.025 ns, and the
  slacks move with
  placement more than with logic ([synth/README.md](../synth/README.md#timing)): every
  stage rebuilds `make nexys4ddr` and reads its timing, and a miss there
  is a placement re-roll before it is a design error.
- The screen is 8K words, so the RAM behind it starts at `0xFFFF2000`.
  The overlay is a memory of its own and does not care; only a page
  that labels the regions needs `G_SCR_ADDR_BITS`. The VGA has 4 bits
  per color, as the screen words have, so the dimmed registers show
  alike. The PS/2 keyboard cannot wait (SYSTEM.md); in Focus the
  debugger takes a byte the cycle it comes.

## How it drives the link

The debugger is a client of the debug link inside the system (DEBUG.md
§3), through the link's side port
([nice_cpu#86](https://github.com/MJoergen/nice_cpu/issues/86),
`debug_link.vhd`, contract g) into `p_acc`, the process that holds the
debug registers and runs the Wishbone master: a word at a time, with
valid held until done, an error for a word that is not a debug register
while the core runs, and the word read. `src/nicemon.vhd` passes the
port through as `dbg_*`, beside the mux of the UART and the TCP server,
which keeps the line: the host's answers, its notices, and the console
go on as before, and the host gets the notices of a stop the debugger
caused, `p`, `x`, or `h`, as it does for a breakpoint. The link serves
the host's words first, and a word of the debugger's waits for a clear,
as a host's does. The side port brings no notices, so the debugger sees
a stop as a rising edge of the core's pause or halt, `nicemon`'s
`paused_o` and `halted_o`, and the end of one as a falling edge, which
drops the word at the PC and the window it read at the stop, also when
a host went on.

`src/dbg/dbg_host.vhd` is the adapter between the debugger's requests,
a read of a run of words or a write of one, as a host's `R` and `W`,
and the port's single words: it walks the addresses, gives the words
read out one at a time, and ends the request the cycle after the last,
or at once with the code `02` when the link refuses a word. There is
no timeout: the link answers every word (contract g), after the host's
accesses, a clear, and the memory, as a host's word would wait. The
strip is refreshed about 60 times a second from a timer in the system
clock; a refresh is 28 words, microseconds on the port.

Stages 2 to 8 had a host in hardware instead: `dbg_host.vhd` spoke
DEBUG.md's packets into a third input of the link's mux, so that
`debug_link.vhd` stayed unchanged until nice_cpu V1.2, and the debugger
owned the line while it was up, with the host cut off. Serializing hex
inside the FPGA cost nothing at the keyboard's pace, but the side port
removed both the hex and the cut-off host.

## The modules

- `src/dbg/dbg.vhd`: the debugger: the states, the refresh, the keys,
  and the drawing into the overlay. Ports: the toggle pulse; the
  keyboard's bytes, with valid and ready; the link's side port, `lnk_*`,
  and the core's `paused_i` and `halted_i`; the overlay's write
  port, `ovl_we_o`, `ovl_addr_o`, and `ovl_data_o`, with `strip_o` and
  `page_o`; `focus_o`, for the keyboard mux; and, with `G_BOARD_IO`, the
  five buttons in and the display's 64 segment bits out. A generic names
  the toggle key for row 28.
- `src/dbg/dbg_host.vhd`: the adapter to the side port (written). A
  request in, with valid and ready: a read of a count of words from an
  address, or a write of one word, as the debugger writes one register
  or one word at a time. The words read out, one a cycle at the most,
  and the end of the request, with the link's code `02` when it refused
  a word; and the side port out, `side_*`.
- `src/dbg/dbg_decode.vhd` (written): the instruction word and its
  constant words in, the text of row 27 out, a character a cycle.
- `src/video/text.vhd`: the 29 rows, the overlay memory, and its ports:
  `ovl_we_i`, `ovl_addr_i`, `ovl_data_i`, `strip_i`, and `page_i`.
- `src/nicemon.vhd`: the link's side port as `dbg_*`, and the core's
  `paused_o` and `halted_o` (written).
- `src/system.vhd`: instantiates the debugger beside `eth` and `text`;
  `dbg_toggle_i`, the pulse; the side port and the core's state between
  `nicemon` and the debugger; the keyboard mux, which gives the bytes to
  the debugger while `focus_o` is '1' and to `nicemon` otherwise; and,
  with `G_BOARD_IO`, the buttons masked by `focus_o` to `nicemon` and
  raw to the debugger, and the debugger's segments to the board in Focus
  (see [The Nexys4DDR](#the-nexys4ddr)).
- `src/kbd_m65_toggle.vhd`, in `synth/mega65/mega65.vhd`: the MEGA+HELP
  detector on `kbd_m65`'s matrix, keys 61 and 67, both pressed in two
  samples 5 ms apart as `kbd_m65_ascii.vhd` debounces, a pulse on the
  press and none while held. Neither key gives a byte, so the
  combination sends nothing to the program.
- `src/kbd_ps2_toggle.vhd`, in `synth/nexys4ddr/top.vhd`: the Scroll Lock
  detector on the scan codes (see [The Nexys4DDR](#the-nexys4ddr)).
- `src/kbd_m65_ascii.vhd` and `src/kbd_ps2_ascii.vhd`: the bytes of
  Page Up, Page Down, and Home, and MEGA as a modifier.

Nothing new touches the core's paths, whose setup slack is about 0.1 ns
([synth/README.md](../synth/README.md#timing)): the side port is a
client of the link's own `p_acc`, and the core's pause and halt are
existing signals. The overlay takes 4 of the 230 free block RAMs of
the MEGA65, and the logic a few hundred to a thousand LUTs of the 88 %
free.

## Tests

- `tb_text` with `G_PPM_FILE` writes a frame as a picture; a case with
  the strip and one with the page show the layout.
- `tb_dbg_host` (written): the adapter against `debug_link` itself, in
  GHDL, on `nicemon`'s side port, with `sim/host.nasm` and a host on the
  UART: read the version, load a program and read it back, start it,
  read the control register while it runs and get `e02` for the memory,
  pause, read R0–R15, and step; the UART gets `b05` and the `p` of each
  stop, and the console bytes in order; a packet on the UART is answered
  while the adapter reads, and a go on from the UART ends a long read of
  the adapter's with `e02` after the words it got while the core was
  paused; and a read of no words ends at once.
- `tb_dbg_decode` (written): the decode against `nicedis.py`, on about
  3000 instruction words of every class, condition, modifier, and mode,
  with their constant words, from `sim/gen_decode.py`, and a start in
  the middle of a decode.
- `tb_dbg` (written for stage 9): the debugger with `nicemon`, driven
  by keyboard bytes and toggle pulses, checking the overlay's words and
  its requests on the side port. The program under it is `sim/dbg.nasm`,
  in the ROM: the registers live, R1 counting, and the PC on the display
  while the core runs; F5, s, F3, the halt, r, F7, with the registers
  dimmed, and g and p on a held core, with the
  decode of row 27 at each stop; F12 and Strip,
  a step of its own that is not caught, the catch of a halt in Strip,
  and no catch from Off; and the page: the ROM's words, the cursor keys,
  Home, Page Up and Down, a move during a read, `a`, a write read back,
  DEL, ESC, and a write that gets `e02` while the core runs; and the
  breakpoints: `b` sets one, which the header lists and the page colors,
  the core stops there with `BRK 0`, `b` clears one, `g` goes on to `BRK
  1`, `b` takes the lowest free one, and says `none free` when there is
  none, and after a digit `b` is a digit; and, with `G_BOARD_IO`, the
  display's dashes and PC, BTND and BTNU, a bouncing BTNL that steps
  once, BTNR, BTNC, and the buttons doing nothing in Off. The mask of
  the core's buttons in `system.vhd` has no test of its own.
- `tb_kbd` and `tb_ps2`: the two toggle detectors, with a held key's
  repeats and its release, and one key of MEGA+HELP alone; and Page Up,
  Page Down, and Home from both keyboards.
- `tb_nicemon` (written): R15 read over the UART while the program
  waits for a byte, in its loop and moving between reads, the live
  registers of nice_cpu V1.2.
- Formal (written): `dbg_host` holds a word on the side port, with its
  fields, until the link is done with it (contract g), asks for the
  request's addresses in order, ends after its count of words or at a
  refusal, and once (`formal/dbg_host.sby`).
- On the board (done on the R6 on 2026-10-31): `make hwtest` with the
  Ethernet station passes on the bitstream of stage 9; a host over TCP
  that reads the control register and R0–R15 twice a second keeps its
  line while MEGA+HELP brings the debugger up, and gets the `p` of the
  debugger's F5; and the strip shows R1 counting and the PC moving while
  the program runs, white, and the stop's values at the pause.
- `make hwtest`, a stretch goal: a register of `board_io.vhd` at
  `0xFFFFFF9E` that enters Focus when written, so that the test enters
  the debugger over the UART with no one at the keyboard, and so that
  `make cosimtest` reaches it too. A program can then drop into the
  debugger on purpose, a software breakpoint, which the ISA has none of.
  The side port makes it possible: the test keeps its link while the
  debugger is up.

The testbenches join `make -j test` and the CONTRIBUTING.md list as they
come.

## Stages

Each a commit that builds and passes the tests:

1. **The overlay** (done). `text.vhd` gets the 29 rows, the overlay
   memory, and its ports; `dbg.vhd` writes a fixed strip after reset,
   which the toggle pulse shows and hides; `mega65.vhd` gets the
   MEGA+HELP detector and `nexys4ddr/top.vhd` the Scroll Lock detector,
   entities of their own; `system.vhd` the keyboard mux. No link
   involved. Tests: `tb_text`'s picture, the first case of `tb_dbg`, and
   the detectors in `tb_kbd` and `tb_ps2`.
2. **The host in hardware** (done, and replaced at stage 9).
   `dbg_host.vhd`, the third input of the mux in `nicemon.vhd`, and the
   formal check. Test: `tb_dbg_host`.
3. **The live strip and the core keys** (done). The refresh of the
   control register, the halt reason, and the stop register; F1 to F9
   and their letters; R0–R15 and the word at the PC read at a stop,
   which a `p`, `x`, or `h` makes the debugger look for at once. The
   first useful debugger.
4. **The catch, and the sticky setting** (done). Strip, F12, and the
   catch of a stop in Strip from the link's notices, which stage 9 moved
   to the core's pause and halt.
5. **The page** (done). The window, the cursor, the input field, the
   word edit, `a`, and Page Up, Page Down, and Home from both keyboards.
6. **The breakpoints** (done). `b`, the header's list, the colored
   words, and `BRK n`.
7. **The Nexys4DDR's buttons and display** in Focus (done).
8. **The decode** of row 27, `dbg_decode.vhd` (done).
9. **nice_cpu V1.2**
   ([#53](https://github.com/MJoergen/NiceMonMEGA65/issues/53), done,
   and tested on the R6). The registers are live while the core runs (nice_cpu#85), and the
   strip dims them only while the core is held; and the debugger moved
   to the side port (nice_cpu#86): `dbg_host.vhd` is an adapter, the
   line is the UART's and TCP's again, and the catch watches the core's
   pause and halt. Tests: `tb_dbg`, `tb_dbg_host`, the formal check, and
   `tb_nicemon`.
10. Later, in no order: a console page, with a tap on the core's
    console output beside the line; the code page with a disassembler; the `board_io` register for `hwtest`; loading and
    saving on the SD card.

## Decisions

Made on 2026-10-30, with the reasons:

- **A host in hardware first, the side port later** (done at stage 9).
  The link was unchanged and formally checked, the protocol is written
  down, and the debugger was tested against the real link; the side port
  was a change in nice_cpu, nice_cpu#86, and came with V1.2, to get rid
  of the hex and of the cut-off host below.
- **The host is cut off while the debugger is up.** Accepted until the
  side port, which ended it at stage 9. MEGA+HELP won over a connected
  TCP host: the person at the keyboard is at the board.
- **The UART and Ethernet are not served at once**
  ([#44](https://github.com/MJoergen/NiceMonMEGA65/issues/44), closed).
  The side port frees the line from the debugger, and the merge of two
  hosts' packets, the routing of the answers, and the UART's FIFO cost
  more than the few setups with both cables would gain. The console
  page shows a program's output on the board, whichever host drives it.
- **Four rows, not seven.** Seven rows with the breakpoints, a console
  tail, and a status row were crowded. The breakpoints are on the page,
  the state is in row 27, and the console tail waits for a page of its
  own.
- **The text moves up 64 lines, permanently.** So nothing jumps when the
  strip appears, and program plus strip stay centered.
- **Three states and a sticky setting**, not a cycle: a cycle is annoying
  for a quick toggle, and the default Off changes nothing for those who
  never press the combination.
- **`a` moves the window only on an empty field** (decided at stage 5).
  `a` is a hex digit too, and the design gave it both meanings; on an
  empty field no digit is lost, and `0a…` types a word that starts with
  it. `b`, at stage 6, follows the same rule.
- **The header lists the breakpoints by place** (decided at stage 6).
  Row 0 has room for the four addresses but not for their numbers too,
  so `Breaks` is followed by breakpoints 0 to 3 in order, as `BRK n`
  counts them. The page shows four, the number every board has; a link
  with more has the rest unused by the debugger.
- **The catch is from Strip only** (changed on 2026-10-30, at stage 4,
  from a catch in every state on `nicemon`'s paused and halted
  outputs). A catch from Off takes the link from a host at the stop: a
  program that `run.py` runs halts, and the `h` it waits for is cut off,
  and so are mon.py's pause and step and `make hwtest`'s. It also showed
  the debugger to those who never press the combination. With the side
  port the link is no longer taken, but a catch from Off would still
  take the keyboard from the program and show the debugger unasked, so
  Off stays uncaught.
- **Live registers through the link**, nice_cpu#85, not a tap on the
  core's register file here (done at stage 9): the link is the one
  engine, and `niceemu --link` returns them live already, so the board
  comes to match the emulator.
- **Stops from the core's signals, not the link's notices** (decided at
  stage 9). The side client gets no notices (DEBUG.md §3), and `nicemon`
  has the core's pause and halt: a rising edge is a stop, and a falling
  edge its end, which also sees a host's step or go on and drops the
  word at the PC and the window read at the stop.
- **No timeout in the adapter** (decided at stage 9). The side port
  answers every word (contract g), and a word is held until it does; a
  timeout would drop a word the link still holds. `NO LINK` is only the
  state before the first answer after reset.
- **Dimmed while held** (decided at stage 9). The link keeps the last
  stop's registers through a hold, which may be another program's after
  a load; gray says so, as it said "not of this stop" before.
- **Key per action**, not a command line: a command line needs an editor
  and a parser, and a debugger at a keyboard is used with single keys.
  The letters are mon.py's, for the fingers that know them.
- **A structured decode first**, a disassembler later: the mnemonic, the
  condition, and the operands in the assembler's syntax are a small
  table and eight operand patterns; the full listing, with `nicedis.py`
  as the model, is a page of its own.
- **Row 27 writes what `nicedis.py` writes** (decided at stage 8), not
  the sketch's `ADD ?1 M C`: the assembler takes it back, mon.py shows
  the same, and `tb_dbg_decode` compares the two. Where `nicedis.py`
  writes `.DAT` for an unused field that is not R0, the row shows the
  instruction without the field, as the raw word is beside it.
- **A generic toggle pulse** per board, since the Nexys4DDR has no MEGA
  key: MEGA+HELP there, Scroll Lock on the Nexys4DDR, a key that gives
  no byte, has a plain scan code, and should pass the board's USB-to-PS/2
  converter, where Pause has neither of the last two.
- **The Nexys4DDR's buttons and display are the debugger's in Focus
  only**, as the keyboard is, so a program keeps them while the strip is
  up, and the debugger does not depend on them.
- **The detectors are entities in `src/`**, not processes in the top
  levels, which use unisim and which GHDL cannot test: `tb_kbd` and
  `tb_ps2` test them.
- **The strip is white on dark blue**, so that it stands apart from a
  program's usual white on black.
- **Page Up, Page Down, and Home on both keyboards**, as new bytes for
  programs too: a key that gives nothing is a key wasted. On the MEGA65
  they are CLR/HOME and MEGA with the cursor keys.
