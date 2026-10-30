# The on-board debugger

A debugger in the FPGA, with the MEGA65's own keyboard and screen and no
host: what `tools/mon.py` does over the debug link, in a strip of text
under the program's screen, and a page over it. **Stages 1 to 6 are
written, and the rest is planned**
([#52](https://github.com/MJoergen/NiceMonMEGA65/issues/52)): the toggle
key enters Focus, where the strip shows the core's state, its registers
at a stop, and the word at the PC, and F1 to F9 run the core; F12 keeps
the strip up when Focus is left, and a stop in Strip comes back to
Focus; and F11 shows the page, a window on the memory, where a word is
written and a breakpoint set at the cursor. This note
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

| State | Overlay | The link | The keyboard |
|---|---|---|---|
| Off | None | The host's: the UART, or TCP | The program's |
| Strip | The strip, live | The debugger's | The program's |
| Focus | The strip, and the page on demand | The debugger's | The debugger's |

- Reset leaves it Off. Nothing changes for anyone who never presses the
  key combination.
- MEGA+HELP toggles Focus, Scroll Lock on the Nexys4DDR. Leaving Focus
  goes to Strip or Off, as a sticky setting says; F12 in Focus toggles
  the setting, and it is Off after reset.
- On the Nexys4DDR, Focus takes the board's buttons and its seven-segment
  display too (see [The Nexys4DDR](#the-nexys4ddr)).
- In Strip, a halt, or a pause the debugger did not ask for, such as a
  breakpoint, takes the debugger to Focus: it catches what stops the
  core. It sees the stop on the link, as the notice `h`, `p`, or `x`. A
  step or a pause of its own keys is not caught, also when Focus was
  left before its notice came. Off is not caught from: the link is a
  host's then, and a host's tools wait for the notices of their own
  halts and pauses, which a catch would cut off.
- In Strip and Focus the debugger owns the link. The UART's and the TCP
  host's bytes are dropped meanwhile, and nothing is sent to them, as the
  UART's are while a TCP host is connected today (`src/nicemon.vhd`). A
  host that is connected when the debugger comes up loses the link until
  the debugger goes Off. The side port [below](#how-it-drives-the-link)
  removes the problem.
- The program's keyboard input is unaffected in Off and Strip: the
  keyboard's bytes go into the console FIFO as now, not through the link.
  The console bytes that a host sends do not arrive while the debugger
  owns the link, and the program's console output goes to the debugger,
  which takes it and drops it until it has a console page.

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
 PAUSED   00001234  xxxxxxxx  X C . . . . I   ADD ?1 M C  R1, @0040[R0], R1
 F1 step  F3 go  F5 pause  F7 hold  F9 restart  F11 page  F12 keep strip: off
```

- Rows 25 and 26: R0–R15 in hex. At a stop they are the link's values.
  While the core runs they are what the link returns then: until
  nice_cpu V1.2 the values of the last stop, shown dimmed, and from V1.2
  the live register file
  ([nice_cpu#85](https://github.com/MJoergen/nice_cpu/issues/85)), as
  `niceemu --link` returns it.
- Row 27: the core's state, `RUNNING`, `PAUSED`, `BRK n` at breakpoint
  n, `HALTED n` with the reason of DEBUG.md §6, `HELD`, or `NO LINK`
  when the link does not answer; the PC; the
  instruction word at the PC; the flags of SR, X, C, Z, N, V, E, and I,
  each shown or a dot; and the instruction decoded: the mnemonic, the
  condition, M and C, and the operands dest, s0, and s1 in the assembler's
  syntax, with the constant words folded in. While the core runs the
  memory is out of reach (DEBUG.md §3), so the row shows the state, and
  the PC once it is live.
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
a stop notice, a write, and a move of the window, and while the core
runs they are dimmed, as the registers are. A move of the window shows
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
  on, BTNU and BTND move the cursor, and BTNC leaves Focus. The program
  reads the buttons as 0 meanwhile: `system.vhd` gives `nicemon` the
  buttons masked by `focus_o`, and the debugger, which debounces them
  itself, the raw ones. The display shows the PC, eight hex digits on
  its eight digits, live once the registers are, through a
  hex-to-segments table in the debugger; `system.vhd` gives the board
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
  of stage 6 0.139 ns and 0.022 ns, also in the core, and the
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

The debugger is a third host of the link. `src/nicemon.vhd` muxes two
today, the UART, and the TCP server while `net_on_i` is '1', through the
register stage `p_lnk_rx`. It gets a third pair of byte streams,
`dbg_on_i`, `dbg_rx_*`, and `dbg_tx_*`, with the debugger first, then
TCP, then the UART. The debugger speaks DEBUG.md's packets: a `W` to the
control register to pause, step, go on, hold, or start, `R` for the
registers and the memory, and `W` for a word or a breakpoint. It parses
the answers `k`, `r`, and `e`, the notices `p`, `x`, `h`, and `o`, and
the program's console bytes, which the owner of the line receives. It
always takes a console byte: a console write of the core waits for the
byte before it (`nicemon.vhd`), so a host that does not take them slows
the program.

So `debug_link.vhd` is unchanged, its formal checks stand, the protocol
is specified, and the host in hardware is tested against the very link
the board has. Serializing hex inside an FPGA is odd, but at the
keyboard's pace it costs nothing: a read of the 16 registers is about
170 bytes, microseconds on the link. The strip is refreshed about 60
times a second from a timer in the system clock.

Then, with nice_cpu V1.2, the debugger gets a word-level side port into
the link's `p_acc`, the process that holds the debug registers and runs
the Wishbone master
([nice_cpu#86](https://github.com/MJoergen/nice_cpu/issues/86)). The
line stays the host's, the debugger is a client beside it, and the
hardware host here becomes an adapter: the hex goes, and so does the
cut-off host.

## The modules

- `src/dbg/dbg.vhd`: the debugger: the states, the refresh, the keys,
  and the drawing into the overlay. Ports: the toggle pulse; the
  keyboard's bytes, with valid and ready; the link's byte streams and
  `on_o`; the overlay's write
  port, `ovl_we_o`, `ovl_addr_o`, and `ovl_data_o`, with `strip_o` and
  `page_o`; `focus_o`, for the keyboard mux; and, with `G_BOARD_IO`, the
  five buttons in and the display's 64 segment bits out. A generic names
  the toggle key for row 28.
- `src/dbg/dbg_host.vhd`: the host in hardware (written). A request in,
  with valid and ready: an `R` of a count of words from an address, or
  a `W` of one word, as the debugger writes one register or one word at
  a time. The words of the `r` out, as they arrive, and the end of the
  request, with `e`'s code or a code of its own, `FF`, when no answer
  came in time; the link's byte streams, which it always takes; the
  notices out, with the version, the breakpoint's number, or the halt
  reason; and the console bytes out.
- `src/dbg/dbg_decode.vhd`, later: the instruction word and its constant
  words in, the text of row 27 out.
- `src/video/text.vhd`: the 29 rows, the overlay memory, and its ports:
  `ovl_we_i`, `ovl_addr_i`, `ovl_data_i`, `strip_i`, and `page_i`.
- `src/nicemon.vhd`: the third input of the link's mux, `dbg_on_i`,
  `dbg_rx_*`, and `dbg_tx_*`, like `net_*` (written).
- `src/system.vhd`: instantiates the debugger beside `eth` and `text`;
  `dbg_toggle_i`, the pulse; the keyboard mux, which gives the bytes to
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
([synth/README.md](../synth/README.md#timing)): the mux's third input
goes through the register stage that exists, and the two new outputs
are existing signals. The overlay takes 4 of the 230 free block RAMs of
the MEGA65, and the logic a few hundred to a thousand LUTs of the 88 %
free.

## Tests

- `tb_text` with `G_PPM_FILE` writes a frame as a picture; a case with
  the strip and one with the page show the layout.
- `tb_dbg_host` (written): the host in hardware against `debug_link`
  itself, in GHDL, on `nicemon`'s third input, with `sim/host.nasm`:
  write the control register, read it back, load a program and read it
  back, pause, read R0–R15, step, and catch `p`; a read while the core
  runs gets `e02`; console bytes arrive in order between packets; the
  UART's bytes are dropped; and a request that the link never gets
  times out.
- `tb_dbg` (written for stage 6): the debugger with `nicemon`, driven
  by keyboard bytes and toggle pulses, checking the overlay's words and
  the link's state. The program under it is `sim/dbg.nasm`, in the ROM:
  F5, s, F3, the halt, r, F7, and g and p on a held core; F12 and Strip,
  a step of its own that is not caught, the catch of a halt in Strip,
  and no catch from Off; and the page: the ROM's words, the cursor keys,
  Home, Page Up and Down, a move during a read, `a`, a write read back,
  DEL, ESC, and a write that gets `e02` while the core runs; and the
  breakpoints: `b` sets one, which the header lists and the page colors,
  the core stops there with `BRK 0`, `b` clears one, `g` goes on to `BRK
  1`, `b` takes the lowest free one, and says `none free` when there is
  none, and after a digit `b` is a digit.
- `tb_kbd` and `tb_ps2`: the two toggle detectors, with a held key's
  repeats and its release, and one key of MEGA+HELP alone; and Page Up,
  Page Down, and Home from both keyboards.
- Formal (written): the packets of `dbg_host` are well formed, with the
  parser of `debug_link.vhd`'s FORMAL block as the model, and carry the
  request's fields (`formal/dbg_host.sby`).
- `make hwtest`, a stretch goal: a register of `board_io.vhd` at
  `0xFFFFFF9E` that enters Focus when written, so that the test enters
  the debugger over the UART with no one at the keyboard, and so that
  `make cosimtest` reaches it too. A program can then drop into the
  debugger on purpose, a software breakpoint, which the ISA has none of.
  This waits for the side port: with the host in hardware, the test
  would lose its own link the moment the debugger came up.

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
2. **The host in hardware** (done). `dbg_host.vhd`, the third input of
   the mux in `nicemon.vhd`, and the formal check. Test: `tb_dbg_host`.
3. **The live strip and the core keys** (done). The refresh of the
   control register, the halt reason, and the stop register; F1 to F9
   and their letters; R0–R15 and the word at the PC read at a stop,
   which a `p`, `x`, or `h` makes the debugger look for at once. The
   first useful debugger.
4. **The catch, and the sticky setting** (done). Strip, F12, and the
   catch of a stop in Strip from the link's notices.
5. **The page** (done). The window, the cursor, the input field, the
   word edit, `a`, and Page Up, Page Down, and Home from both keyboards.
6. **The breakpoints** (done). `b`, the header's list, the colored
   words, and `BRK n`.
7. **The Nexys4DDR's buttons and display** in Focus.
8. **The decode** of row 27, `dbg_decode.vhd`.
9. **nice_cpu V1.2**
   ([#53](https://github.com/MJoergen/NiceMonMEGA65/issues/53)). At
   the bump, the registers are live while the core runs (nice_cpu#85),
   and the strip stops dimming them; and the debugger moves to the side
   port (nice_cpu#86): `dbg_host.vhd` becomes an adapter, and the line
   returns to the UART and TCP.
10. Later, in no order: a console page, with a tap on the core's
    console output beside the line; the code page with a disassembler; the `board_io` register for `hwtest`; loading and
    saving on the SD card.

## Decisions

Made on 2026-10-30, with the reasons:

- **A host in hardware first, the side port later.** The link is
  unchanged and formally checked, the protocol is written down, and the
  debugger is tested against the real link; the side port is a change in
  nice_cpu, nice_cpu#86, and comes with V1.2, to get rid of the hex and
  of the cut-off host below.
- **The host is cut off while the debugger is up.** Accepted until the
  side port. MEGA+HELP wins over a connected TCP host: the person at
  the keyboard is at the board.
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
  the debugger to those who never press the combination. In Strip the
  debugger has the link already, so its notices are enough, and
  `nicemon` needs no outputs for it.
- **Live registers through the link**, nice_cpu#85, not a tap on the
  core's register file here: the link is the one engine, and `niceemu
  --link` returns them live already, so the board comes to match the
  emulator.
- **Key per action**, not a command line: a command line needs an editor
  and a parser, and a debugger at a keyboard is used with single keys.
  The letters are mon.py's, for the fingers that know them.
- **A structured decode first**, a disassembler later: the mnemonic, the
  condition, and the operands in the assembler's syntax are a small
  table and eight operand patterns; the full listing, with `nicedis.py`
  as the model, is a page of its own.
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
