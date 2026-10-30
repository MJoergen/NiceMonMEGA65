# Working on NiceMonMEGA65

This is for those who change this repository: the VHDL, the tools, the
tests, and the releases. Those who flash a core file and write programs
for it need only the [README](README.md).

## Getting started

Clone with the submodule:

    git clone --recurse-submodules https://github.com/MJoergen/NiceMonMEGA65.git

or, in an existing clone:

    git submodule update --init

`make` in the top directory lists the targets:

- `make test` runs the simulation tests, and the demo's test in `niceemu`.
- `make formal` runs the formal checks (see [The formal
  checks](#the-formal-checks)).
- `make lint` checks the VHDL style.
- `make examples` builds the C examples.
- `make demo` builds the demo of the ROM, `demo/build/demo.bin`, which the
  release puts in the ROM of its bitstreams and core files.
- `make r3`, `make r6`, and `make nexys4ddr` build the bitstreams. With
  `ROM=file.bin`, the core boots from the file (see [The
  ROM](doc/SYSTEM.md#the-rom)).
- `make cor` builds the MEGA65 core files for MEGAFLASH (see
  [synth/README.md](synth/README.md)).
- `make load FILE=prog.bin` loads a program into the board and starts it.
- `make run FILE=prog.bin` runs one as `niceemu` runs it (see [Comparing
  with the emulator](tools/README.md#comparing-with-the-emulator)).
- `make mon` opens an interactive shell on the link (see [Using the
  interactive shell](README.md#using-the-interactive-shell)).
- `make hwtest` tests the board (see [Testing the
  board](#testing-the-board)).
- `make flash` writes a bitstream into the Nexys4DDR's flash, from which
  the board then starts (see [synth/README.md](synth/README.md)).
- `make bump TAG=V1.0` moves nice_cpu to a tag and records the MEGA65's
  timing (see [The timing badge](#the-timing-badge)).
- `make release TAG=V1.0` builds, tests, and publishes a release, and
  `TAG=V1.0.1` one that keeps nice_cpu at `V1.0` (see
  [RELEASE.md](doc/RELEASE.md)).
- `make linktest` checks the tools on `niceemu --link`, without a board
  (see [The tools and niceemu](#the-tools-and-niceemu)).
- `make cosim` runs the system in GHDL for the tools, and `make cosimtest`
  checks the tools and the RTL on it, without a board (see [The simulated
  board](#the-simulated-board)).

`make load`, `make run`, and `make mon` use the board's Ethernet port
with `ETH=192.168.1.65`, or the serial device with `PORT=/dev/ttyUSB1`,
and need one of the two, unless `ARGS=` picks the line, as below. They
pass `ARGS=` on to the tool, for example `ARGS=--no-run` or
`ARGS="-i in.txt -d 0:10 -s --timeout 5"`.
`ARGS="--tcp 4000"` drives `niceemu --link 4000` instead of the board, and
`ARGS="--cosim 4000"` the simulated system of `make cosim COSIM_PORT=4000`.
The bitstream targets take `FLOW=default` or `FLOW=timing`, the directives
of Vivado's steps (see [synth/](synth/README.md)). `make hwtest` rebuilds
`niceemu` first, if its sources have changed.

`make test` and the boards' targets use nice_cpu's pipelined core. Add
`NICE=multi` to use its multi-cycle core instead (`NICE=pipeline` is the
default). The simulation of each core is built in `sim/build/pipeline` or
`sim/build/multi`, and both cores run the same tests. The bitstream goes to
`top.bit` in either case, so build one core at a time. The system clock is
set for the pipelined core, so the multi-cycle core has room to spare.

The rules that every change follows are in [CLAUDE.md](CLAUDE.md), under
"Rules and pitfalls", and the VHDL style is in
[CODING_STYLE.md](doc/CODING_STYLE.md). For the boards' builds, see
[synth/](synth/README.md).

## Contents

| Path | What it is |
|---|---|
| [nice_cpu/](https://github.com/MJoergen/nice_cpu) | The NICE CPU, its assembler, its emulator, and `nicewasm`, a [translator](https://github.com/MJoergen/nice_cpu/tree/main/translator) from WebAssembly to NICE assembly, as a git submodule. |
| [src/](src/) | The synthesizable VHDL, shared by both boards (see [What is in src/](#what-is-in-src)). |
| [src/core/](src/core/) | `nice_core_pipeline.vhd` and `nice_core_multi.vhd`, the two architectures of `nice_core`. `src/nice_core.vhd` is the entity that wraps whichever of nice_cpu's cores `core.mk` selects with `NICE=pipeline` (the default) or `NICE=multi`. |
| [src/video/](src/video/) | The text display: `text.vhd` shows the screen at `0xFFFF0000` as 80×25 characters on a video output, with a cursor and a display offset for scrolling. `pix.vhd` and `video_pkg.vhd` are from [MandelbrotMEGA65](https://github.com/MJoergen/MandelbrotMEGA65). `scr_ram.vhd` is the screen's dual-clock memory. `font_pkg.vhd` is the [Spleen](https://github.com/fcambus/spleen) 16×32 font, made by `font/gen_font_pkg.py`. |
| [font/](font/) | The script that makes `src/video/font_pkg.vhd` from Spleen, and Spleen's license (BSD 2-Clause). |
| [sim/](sim/) | The GHDL testbenches. `text_synth.vhd` is the wrapper with which GHDL checks that the display synthesizes. |
| [formal/](formal/) | The formal checks, for SymbiYosys. |
| [synth/](synth/README.md) | The Vivado builds for the MEGA65 R3 and R6 boards, and the Nexys4DDR. |
| [monitor/](monitor/README.md) | The monitor, in NICE assembly: planned, not written yet ([#24](https://github.com/MJoergen/NiceMonMEGA65/issues/24)). Its README has the decisions it will follow, QNICE-FPGA's. |
| [demo/](demo/README.md) | The demos in the ROM of the release, in NICE assembly, which the function keys switch between: a welcome screen that turns into a typewriter, the key codes, the characters and colors, the counters, a game, and the board: a self-test and the Ethernet station's addresses. |
| [examples/](examples/) | Example C programs, and the Makefile that builds them for the MEGA65. |
| [tools/](tools/) | `nicelink.py`, the debug link over the board's Ethernet port or UART, over TCP to `niceemu --link`, or over TCP to the simulated system of `make cosim`, and the tools that use it: `load.py`, which loads a program into the MEGA65 or Nexys4DDR, `run.py`, which runs a program on the board as `niceemu` runs it, `mon.py`, an interactive shell on the link, `hwtest.py`, which tests the system on the board, `flash.py`, which writes the Nexys4DDR's flash or a slot of the MEGA65's, `bump.py`, which records the MEGA65's timing for a nice_cpu tag, `release.py`, which builds and publishes a release, `linktest.py`, which checks `run.py` and `mon.py` on `niceemu --link`, `cosimtest.py`, which checks `run.py` on the simulated system, and `screenshot.py`, which draws a program's screen in `niceemu` as a PNG picture. |
| [README.md](README.md) | For those who use the core files and write programs for them: on its own, over Ethernet, and over the serial port. |
| [SYSTEM.md](doc/SYSTEM.md) | The system that programs and the link see: the debug link, the address map, the screen, the ROM, and the Nexys4DDR's devices. |
| [EMULATOR.md](doc/EMULATOR.md) | The table of the known differences from the emulator. |
| [RELEASE_NOTES.md](doc/RELEASE_NOTES.md) | The releases, newest first, with what changed in each. [RELEASE.md](doc/RELEASE.md) is how to make one. |
| [core.mk](core.mk) | Picks the source files of the core, from `NICE`, for the Makefiles of `sim/` and `synth/`. |
| [.claude/rules/synth.md](.claude/rules/synth.md) | Notes for Claude Code on the Vivado builds: where Vivado is, how to build, and what to check after a build. |
| [vsg.yml](vsg.yml) | The configuration of `make lint`, which checks the VHDL against [CODING_STYLE.md](doc/CODING_STYLE.md). |
| [CLAUDE.md](CLAUDE.md) | Instructions for Claude Code: the commands, the layout, and the pitfalls. |
| [.github/workflows/ci.yml](.github/workflows/ci.yml) | The CI: `make test` and `make cosimtest` on both cores, with niceemu built for its step counts, `make examples`, the demo's test, `make linktest`, `make formal`, and `make lint`. It cannot run `make hwtest` or build a bitstream. |

### What is in src/

- `nicemon.vhd` is the system: the NICE core, the memory, the UART, the
  core's input FIFO, nice_cpu's devices, the screen's and the board's
  registers, and the debug link.
- `mem.vhd`, with `ram.vhd` and `rom.vhd`, is the memory.
- `rx_fifo.vhd` is the core's input FIFO.
- `devices.vhd` has nice_cpu's devices at `0xFFFFFF10`–`7F`.
- `scr_regs.vhd` has the screen's registers at `0xFFFFFF80`–`8F`.
- `board_io.vhd` has the board's registers at `0xFFFFFF90`–`9F`.
- `eth/eth.vhd` is the Ethernet station. `eth/rmii_rx.vhd` receives the
  PHY's frames, `eth/rx_fcs.vhd` checks their frame check sequence, and
  `eth/eth_rx_fifo.vhd` takes the good ones to the system clock.
  `eth/eth_arp.vhd` filters them by their MAC address and answers ARP
  requests, `eth/eth_icmp.vhd` answers pings, `eth/eth_tcp.vhd` serves
  the debug link on a TCP port, with `eth/eth_tcp_rx.vhd` parsing its
  segments, `eth/eth_tcp_pick.vhd` choosing the ones to send and
  `eth/eth_tcp_tx.vhd` sending them, `eth/eth_tcp_buf.vhd` keeping the
  bytes of the link, and `eth/eth_tcp_timer.vhd` timing the
  retransmissions, `eth/eth_arb.vhd` merges the frames to send a whole
  frame at a time, `eth/eth_tx_fifo.vhd` takes them back to the PHY's
  clock, and `eth/rmii_tx.vhd` sends them. The FIFOs and the TCP server keep their bytes in
  `eth/eth_ram.vhd`, and `eth/eth_pkg.vhd` has the CRC, the Gray code,
  and the checksum sum.
- The debug link is nice_cpu's `hdl/src/debug_link.vhd`.
- `uart_serdes.vhd` is copied from
  [cmod-s7](https://github.com/MJoergen/cmod-s7), with fixes to its
  receiver, and break detection.
- `kbd_m65.vhd` drives the MEGA65 keyboard, and `kbd_m65_ascii.vhd` turns
  its keys into ASCII.
- `kbd_ps2.vhd` receives the PS/2 keyboard of the Nexys4DDR, and
  `kbd_ps2_ascii.vhd` turns its scan codes into ASCII.
- `seg7.vhd` scans the Nexys4DDR's seven-segment display, and
  `rgb_pwm.vhd` dims its RGB LEDs.
- `dbg/dbg.vhd` is the on-board debugger (doc/DEBUGGER.md), and
  `dbg/dbg_host.vhd` its host of the debug link, which turns a request
  of a word or more into a packet, and the link's bytes back into the
  answer, the notices, and the console bytes. `kbd_m65_toggle.vhd` and
  `kbd_ps2_toggle.vhd` detect the boards' toggle keys.
- `system.vhd` is what every board has: the system, the text display of
  its screen, and the UART's pins.

## Running the tests

You need GHDL (tested with 4.1.0) and Python 3, and gcc for `make cosim`.

    make -j test

It prints a `PASS` line for each testbench, and a `FAIL` line with the log
for one that fails. If one fails, run it alone with `make -C sim <name>`,
such as `make -C sim tb_kbd`. `make -j test` runs all the tests side by
side, in the time of `tb_text`, and then runs the demo in `niceemu`. `make
-C sim test` runs them in turn. `make lint` checks the VHDL against
[CODING_STYLE.md](doc/CODING_STYLE.md) with vsg.

The testbenches are these:

- `sim/tb_hello.vhd` runs a "Hello" program on the NICE core from the
  submodule, and checks its console output.
- `sim/tb_nicemon.vhd` drives the whole system through its UART, as a host
  of the debug link, with `sim/rom.nasm`, a greeting, as the ROM (see
  below).
- `sim/tb_kbd.vhd` tests the keyboard driver and its ASCII, with a model of
  the keyboard, CLR/HOME and MEGA with the cursor keys among the keys,
  and the debugger's MEGA+HELP detector, which pulses once while the
  keys are held.
- `sim/tb_ps2.vhd` tests the PS/2 receiver and its ASCII, with a model of a
  PS/2 keyboard, and checks that bad and broken frames are dropped, and
  that Home, Page Up, and Page Down differ from the keypad's keys with
  the same codes. It also tests the debugger's Scroll Lock detector: one pulse for a held
  key, and none in Ctrl+Break.
- `sim/tb_ps2_nicemon.vhd` types on that model into the system, wired as
  the Nexys4DDR wires it. Keys typed while the core is held in reset are
  dropped, `sim/fifo.nasm` echoes the keys typed, and `sim/switch.nasm`,
  which reads no input until switch 0 is on, lets the UART fill the
  core's input. Then one key waits, the keys typed after it are lost,
  and the keyboard works again once the program reads.
- `sim/tb_text.vhd` fills the screen of the text display and the
  debugger's overlay, and checks every pixel of one 1280×1024 frame with
  the strip shown, and the sync pulses; then it hides the strip, scrolls
  the display one row, shows the cursor, and checks every pixel of the
  next frame; then it shows the page, and checks the first four rows of
  the third. It takes about a minute and a half, the longest of the
  tests.
- `sim/tb_dbg.vhd` tests the on-board debugger on the system, with
  `sim/dbg.nasm` in the ROM, a count to 0x800 and a halt. The strip
  after reset has no registers and NO LINK, and the debugger is Off,
  without the link. The toggle enters Focus, where it takes the
  keyboard's bytes and the link, and the core is RUNNING. F5 pauses,
  with R0–R15 in white, R15 as the PC, and the word at the PC as the ROM
  has it; s steps to the next instruction; F3 goes on, with the
  registers dimmed; and the halt shows HALTED 1, R1 at 0x800, and Z.
  r restarts, F7 holds, and g and p then leave the core held. F12 makes
  the toggle leave Focus for Strip, where the debugger keeps the link but
  not the keyboard, and a step of its own does not bring it back; a
  halt in Strip does, the catch. F12 again makes the toggle leave for
  Off, which gives the link back. A reset in Focus leaves the debugger
  Off with the strip drawn again, and the halt that follows leaves it
  Off: Off is not caught from. F11 then shows the page, the ROM's words
  with the cursor on the first; the cursor keys, Home, Page Down, and
  Page Up move the cursor and the window, also during a read of it; `a`
  moves the window to the screen's memory, where a word is written and
  read back; DEL and ESC edit the field, and ESC leaves the page; and
  while the core runs the words are dimmed and a write gets `e02`. Last,
  `b` sets breakpoint 0 at the cursor, which the header lists and the
  page colors, and a restart stops there with BRK 0; `b` sets breakpoint
  1 and clears breakpoint 0, and `g` goes on to BRK 1; `b` then takes
  the lowest free breakpoint, says `none free` when all four are in use,
  and after a digit is a digit.
- `sim/tb_dbg_host.vhd` tests the debugger's host against the debug link
  itself, on the system's third link input, with `sim/host.nasm`, which
  writes 0x00 to 0xFF to the console again and again. It reads the
  version, loads the program and reads it back in one request, and
  starts it; the console bytes come in order, 0xFF among them, while it
  reads the control register, and a read of the memory gets `e02`. A
  pause brings `p`, stops the console, and lets it read R0–R15 in one
  request, and a step brings `p` again and moves R15. A packet on the
  UART is dropped meanwhile, and nothing is sent there. With the host
  off the link, its request ends with the timeout.
- `sim/tb_board_io.vhd` tests the Nexys4DDR's drivers of its seven-segment
  display and RGB LEDs: every digit of the display lit in turn with its own
  segments, and the duty of an RGB output at its level.
- `sim/tb_rmii_rx.vhd` tests the RMII receiver with a model of the PHY:
  frames of 1 to 100 bytes, frames whose CRS_DV toggles at the end as the
  carrier goes, one that ends half a byte late, and a false carrier.
- `sim/tb_rx_fcs.vhd` tests the check of the frame check sequence: an ARP
  request whose sequence comes from Python's `zlib.crc32`, the same with
  a bit flipped in its data and in its sequence, and frames of 3 to 1518
  bytes, of which those under 64 are bad. It first checks its own CRC-32
  against that of `123456789`.
- `sim/tb_eth_rx_fifo.vhd` tests the FIFO of received frames between its
  two clocks, with good and bad frames, a reader that is not always
  ready, and a stall that makes frames find the FIFO full: every good
  frame comes, whole and without its check sequence, or is counted as
  dropped. A second FIFO of 64 bytes checks the capacity to the byte: a
  frame that fills it fits and one byte more is dropped, many drops give
  back all their space, and the room beside a waiting frame is used to
  its last byte.
- `sim/tb_eth_tx_fifo.vhd` tests the FIFO of frames to send between its
  two clocks, with a writer and a reader that are not always ready: the
  frames come in order and whole, none before it is written whole, and,
  with the reader always ready, a byte every two cycles. A second FIFO of
  64 bytes checks the capacity to the byte: it takes 64 bytes and no more,
  a frame that fills it goes in and out again and again, and the room
  beside a waiting frame is used to its last byte.
- `sim/tb_rmii_tx.vhd` tests the RMII transmitter with a model of the
  PHY: frames of 1 to 1514 bytes, with their preamble, padding, frame
  check sequence, which it checks with its own CRC, and gap of 12 bytes.
- `sim/tb_eth.vhd` tests the Ethernet station at its pins, against
  answers it makes itself, byte for byte. ARP requests to everyone and to
  the station get a reply, and so do pings of 0, 56, and 1472 bytes of
  data, and pings whose checksums carry, or not, when the type changes.
  No answer comes to ARP requests for another address, to another
  station, or to a mix of the two; to an ARP reply or an IPv4 frame; to
  pings to everyone or to another address, with a wrong header checksum,
  a fragment, IP options, another ICMP type or protocol, or a total
  length longer than the frame; to a frame with a wrong check sequence;
  or to anything while the IP address is 0. A host also opens a TCP
  connection to port 4510 through the pins, and twice the link side sends
  bytes, the host sends data, and the host sends ARP requests and pings,
  all at once, so that the replies and the TCP segments compete for the
  transmit FIFO. Every frame sent must be whole, with right checksums, the
  next sequence number, and the link's bytes, or the next reply expected;
  the link side must get the host's bytes; an RST ends the connection; and
  the counts of frames are checked too.
- `sim/tb_eth_tcp.vhd` tests the TCP server of the debug link at its
  ports, against a host modeled in VHDL that checks both checksums of
  every segment, and sends SYNs with the options of Linux, data with
  options, and gaps in its frames: the handshake, and the SYN-ACK sent
  again; data each way, data again, out of order, with a wrong checksum,
  and too much for the buffer, and a frame longer than the server reads;
  a keepalive probe; the host's window, a window of 0, an older window,
  data sent again after the timeout, and an ACK that comes while it is;
  the host's FIN as a break after its data; a new connection after it,
  which closes the old one first with a FIN that comes again until it is
  acknowledged, and one before it, as when the FIN was lost, or after a
  crash; data in the ACK of the SYN-ACK; an RST, after which the link
  still takes the input, and one while data is out; a break that waits
  for its input while a new connection's comes; an RST before the ACK of
  the SYN-ACK; a SYN-ACK that is never acknowledged; the parser's bad
  headers; a SYN with ACK, a FIN, or data; a partial ACK, an old one,
  and one of what was not sent; a segment with old bytes and new ones,
  one without ACK, and a FIN ahead of its data; an RST from another IP
  address; a SYN from the connection's own port; and both sides'
  sequence numbers across 2^32. In every cycle, the retransmission timer
  must run only while there is a connection, an ACK of the FIN must free
  the data before it, also when it covers both at once, and the server
  must keep the contracts that the formal jobs of its timer, buffers,
  and chooser assume, and the link's output must not overwrite a
  segment while it is sent.
- `make -C sim tb_eth_tcp_random`, part of `make test`, runs the same
  testbench with `G_RANDOM`: 2500 random actions on one connection
  whose sequence numbers cross 2^32. The host sends data at random
  offsets, old, overlapping, ahead, with options, and with a wrong
  checksum, and ACKs and windows that never move its right edge back,
  while the link side sends at random, stops taking input, and the host
  stops taking frames or waits for a timeout. Every segment is checked,
  and at the end everything sent each way must have come, in order,
  once. `SEED=n` picks another run.
- `make test` also checks that GHDL can synthesize the system, with
  `sim/rom.nasm` as its ROM and without a ROM, the keyboards, the
  debugger and its host, the text display, and `src/system.vhd` with the screen and the devices of the
  Nexys4DDR, and the drivers of its display and RGB LEDs.
- `make -C sim check-steps`, part of `make test`, compares the step counts
  that `tb_nicemon` checks with those of niceemu. It is skipped when niceemu
  is not built.
- `make -C sim check-fmt`, part of `make test`, checks that the `.nasm`
  files of `sim/` are laid out in nice_cpu's columns, with
  `nice_cpu/assembler/nicefmt.py`. Its `--write` fixes a file.

### tb_nicemon

`tb_nicemon` boots the core from the ROM, and checks that the ROM is read
only with the RAM above it, and that bit 3 of the control register hides
it and shows it again. It checks its checksums against the examples of
DEBUG.md, and the board's `b` notice. With the ROM hidden, it loads the
"Hello" program over the link and runs it. It checks the halt notice, the
halt reason, and the step count, which must equal niceemu's, and that the
microsecond counter matches the cycle counter at its clock of 90 MHz.
Then it loads and runs these programs:

| Program | What it checks |
|---|---|
| `sim/echo.nasm` | Echoes what it receives. The testbench pauses it: the `p` notice, the memory, R15, and the stopped cycle counter while paused, and a byte that waits until it goes on. |
| `sim/fifo.nasm` | The input FIFO, which has 16 bytes there, so that the test of a full FIFO is short. |
| `sim/devices.nasm` | The math unit, the performance counters, and the timer's interrupts. The testbench also uses the math unit over the link. |
| `sim/emu.nasm` | The screen, the read counter, memory in the I/O range, and the registers after a halt. The testbench writes and reads the screen's registers. |
| `reserved.nasm` of the emulator's tests | A halt on a reserved control word, after the testbench has cleared the memory. |
| `sim/counters.nasm` | The fetch statistics, the microsecond counter, and the board's registers through the core's data bus. A start clears the fetch statistics, and with the multi-cycle core every cycle counts as one with no word in the buffer. |
| `sim/break.nasm` | The breakpoints, and the `x` notice. |
| `sim/eof.nasm` | Echoes its input until a break ends it. |
| `sim/count.nasm` | The read counter, which a start keeps. |

It also checks the error answers while the core runs, the `o` notice
when the FIFO overflows, and that the link reads the console and the
read counter as 0 and does not write them. Between the programs, the
testbench writes and reads the board's registers, and checks that a
clear of the memory and a start keep them. Then it types on the keyboard
input, which is dropped while the core is held in reset, and input for
`sim/fifo.nasm` while it runs. Last it resets the system while a program
runs, and checks that the core boots from the ROM again and that the
screen's and the board's registers are cleared. The header of
`sim/tb_nicemon.vhd` lists the steps in order. `tb_nicemon` and
`tb_hello` take `-gG_*_FILE=` generics, as `sim/Makefile` shows.

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
shorter in simulated time, and its checks of the pause, the step, and
the breakpoints.
Then it runs the programs that `make hwtest` compares, with `run.py
--cosim` and with `niceemu`, whose output and exit status must be the same.
It leaves out nice_cpu's benchmark and the demo's self-test, which would
take too long. It takes about 4 minutes, and CI runs it on both cores.

## The formal checks

`make formal` runs the SymbiYosys jobs in `formal/`, and CI runs it too.
It needs the tools of nice_cpu's formal checks: Yosys with the GHDL plugin,
SymbiYosys, and the Yices 2 solver. CI installs them as nice_cpu's CI
does, from the OSS CAD Suite of 2026-09-30 (Yosys 0.69, GHDL 7.0.0-dev
with its plugin, and Yices 2.7.0): download
`oss-cad-suite-linux-x64-20260930.tgz` from the suite's releases, unpack
it, and put its `bin/` first on the PATH. Every input of each job is free, so the solver tries every input at
every time, not only the ones a testbench sends.

- `rx_fifo.sby` proves the core's input FIFO, `src/rx_fifo.vhd`, with 4
  bytes: the bytes come out in the order they went in, a byte is lost only
  when the FIFO is full or the input has ended, no byte is written to the
  word being read, and the end of the input stays until reset.
- `board_io.sby` proves the board's registers at `0xFFFFFF90`–`9F`,
  `src/board_io.vhd`, with them and without them: a write sets the
  register of its word, nothing else changes one but reset, each word
  reads its register, its input, or 0, and the buttons reach their
  register two cycles after their pins. The Ethernet station's words at
  `0xFFFFFF98`–`9D` are there on every board, and its IP and MAC
  addresses after reset are as the generics say. Without the other
  registers, every word but those reads 0.
- `scr_regs.sby` proves the screen's registers at `0xFFFFFF80`–`8F`,
  `src/scr_regs.vhd`: a write sets the register of its word, nothing else
  changes one but a clear or reset, each word reads its register, or 0,
  the display hears of each write, clear, and reset, and the display
  offset goes out only while bit 10 of the state enables it.
- `devices.sby` proves `src/devices.vhd`, with nice_cpu's real devices,
  for the requests that nicemon makes: each ACK answers a request, and
  goes to the master that made it, the core or the link, with the word of
  the device that takes it, and each request reaches its device, and no
  other, the link's from its latch until the device takes it. The devices
  are reset when the core starts.
- `mem.sby` proves the memory, `src/mem.vhd`, with 16 words of RAM, a ROM
  of 4 words, `formal/rom.bin`, and a screen of 8: a write reaches the
  memory of its address, and no other, and none while it is to the shown
  ROM, a clear writes 0 to every word of the RAM and the screen, a read
  returns the word of the memory of its address, a fetch in the I/O page
  returns 0, and each fetch gets one ACK. Its `model` task proves, with
  PDR, that a read of a word of the RAM or the screen returns the word last
  written there, or 0 after a clear, on both ports, and a read of the
  shown ROM returns its word, and a clear ends.
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
  `run` and `cover` with both: a ROM of 4 words, `formal/rom.bin`, and the
  Nexys4DDR's registers at `0xFFFFFF90`–`9F`. It checks these properties:
  - The core's two buses get an ACK only for a request that waits, which
    is what nice_cpu's proofs of the cores assume of them, also when the
    link holds a running core.
  - The link's requests are taken only while the core is held or has
    halted, and each gets one ACK. A request is served only for the
    master that owns port B.
  - A link access to the console or the read counter returns 0 and changes
    nothing.
  - A clear of the memory is answered once, and meets no request.
  - The core gets one ACK at a time, from nicemon or from a device.
  - What a read of the console returns.
  - A read of memory returns the word of `mem.vhd`, one of
    `0xFFFFFF90`–`9F` that of `board_io.vhd`, and one of
    `0xFFFFFF80`–`8F` that of `scr_regs.vhd`.

  The `link` and `rom` tasks take about 14 minutes each, and the others a
  few each; `make -j formal` runs all the tasks side by side. CI runs `make -j4
  formal` on its four processors.

- `eth_tcp_timer.sby` proves the TCP server's retransmission timer,
  `src/eth/eth_tcp_timer.vhd`, with a millisecond of 3 cycles, a timeout
  of 2, and 3 tries: the counts stay in their ranges, the register of
  the millisecond's last cycle is '1' in that cycle and no other, the
  timer runs out only at a tick while it is armed, never in the cycle after it was held
  or ran out, and not before its time, each timeout counts a try but the
  last, and what the connection tells it lands in the cycle after.

- `eth_tcp_buf.sby` proves the TCP server's buffers,
  `src/eth/eth_tcp_buf.vhd`, with 4 bytes each: the link's output is
  taken only into room below the first byte not acknowledged, and dropped
  without a connection; the data written and the data committed stay in
  order, within a buffer of what the link has taken, and a commit or a
  discard moves the one to the other; a byte read goes to the link in
  the cycle after, and stays until it is taken; the break waits, after
  the data committed, until the bytes before it are taken, and comes
  alone; and the link is on while a byte or the
  break is offered, and from the cycle after a connection opens. Its
  `model` task proves, with PDR, that the link takes the bytes of the
  receive buffer in the order of their pointers, each as it was last
  written, and that a byte the link writes into the send buffer is read
  back until the buffer wraps around to its word.

- `eth_tcp_pick.sby` proves the choice of the TCP server's segments,
  `src/eth/eth_tcp_pick.vhd`, with the sender under it, a buffer of 4
  bytes, and segments of 2: a segment is chosen only in the cycle meant
  for it, not while one is sent, and acknowledges, unless it is a reset;
  the SYN-ACK, data, the FIN, an ACK alone, and the reset are chosen only
  as its header says, and data never beyond the data there is or the
  host's window, but for the probe; and the sender is offered the connection's fields, the
  sequence number, and the length chosen, or the reset's host and
  numbers, which stay until it takes them, in the cycle after the choice.
- `eth_tcp_rx.sby` proves the parser of the TCP server's frames,
  `src/eth/eth_tcp_rx.vhd`, for every frame, with the longest frame read
  60 bytes: the stream is held from the cycle after a last byte until the
  segment, offered from the second, is taken; data is written only while
  the stream moves, from the end of the TCP header to the IP total
  length, of a segment that was the next of the connection at byte 47,
  with data that fitted; a good segment whose data was written has had
  all of it written, and no more; a longer frame is not good; and the
  verdict and the fields stand from the last byte until the segment is
  taken. Its `cover` reaches a good segment, checksums and all.
- `eth_tcp_tx.sby` proves the sender of the TCP server's segments,
  `src/eth/eth_tcp_tx.vhd`, with a buffer of 4 bytes and segments of 2:
  it takes a segment offered only while idle, keeps its fields, and is
  busy from the take until the last byte has gone; a byte offered
  stays until it is taken; the frame has 54 bytes and the data's, in
  order, with the last marked; its header is the one built, checksums and
  all; and its data is read from the segment's address on. The sums of
  the checksums are not proved, as the solver does not get through
  ones' complement sums of free words; `tb_eth_tcp` checks both
  checksums of every segment.
- `rx_fcs.sby` proves the check of the frame check sequence of a
  received frame, `src/eth/rx_fcs.vhd`, with every input free: each end
  of a frame gives exactly one of good and bad, in the cycle after, and
  nothing else gives either; good comes only for a frame of 64 bytes or
  more with the CRC's residue and no error, and always for one; and the
  CRC and the count start again after each frame and reset.
- `eth_arb.sby` proves the arbiter of the frames to send,
  `src/eth/eth_arb.vhd`, with the two responders never valid together:
  a source's byte is taken only when the output takes it, and it is that
  byte that goes out; each byte that goes out is one source's, which is
  taken; the bytes of a frame, from its first to its last, all come from
  the responders or all from the TCP server; and the responders come
  first when both start in the same cycle.
- `eth_rx_fifo.sby` and `eth_tx_fifo.sby` prove the two FIFOs of
  frames, `src/eth/eth_rx_fifo.vhd` and `src/eth/eth_tx_fifo.vhd`,
  across their two clocks, with SymbiYosys's `multiclock on`: each step
  of the solver is a moment in which either clock may rise. The system
  clock rises every other step, and the PHY's clock as the solver
  likes, but never faster than the system clock and, for the FIFO of
  frames to send, no more than three times slower. Both sides are reset
  together at the start, and the FIFOs have 8 and 4 bytes. The read
  pointer that the write side decodes from Gray code is a past value of
  the real one, which stays at or before the committed one, which stays
  at or before the write pointer, all within the FIFO's size of the
  read pointer that the write side sees, and the write side is full
  exactly when it sees the FIFO full; a write never lands on a byte not
  yet read; the read
  side takes the committed pointer only after it has stood still for two
  of its cycles, and then has it exactly; a byte offered stays until it
  is taken; and a byte that the solver picks stays in the memory until
  its turn, and is then the byte read, with its mark. In the FIFO of
  received frames, a bad frame, or one that found the FIFO full, gives
  back all of its space, and a good one commits all but its check
  sequence, with the mark on its last byte. In the FIFO of frames to
  send, a frame is committed only with its last byte, and commits are
  14 cycles apart, whatever the frames' lengths. The solver has no
  metastability, so a synchronizer of one register instead of two would
  pass.
- `eth_tcp.sby` proves the TCP server's connection, `src/eth/eth_tcp.vhd`,
  with the real buffers and timer, and a free parser and chooser,
  `formal/eth_tcp_rx_free.vhd` and `formal/eth_tcp_pick_free.vhd`, which
  do anything that the real ones may do, as their own jobs prove. GHDL
  binds the architecture analyzed last, so these replace the real ones.
  The buffers have 4 bytes, a segment 2, the timeout 6 cycles, and the
  tries 3, and the station's addresses stay as they are from reset. It
  proves: the pointers of the send buffer stay in order, within the
  buffer, and not past the FIN while closing; the connection opens, and
  the link goes to it, only by the ACK of its SYN-ACK; the next number
  expected from the host is the one past the data committed and its
  FIN, and data is committed only from the peer, at that number; every
  segment with data, a FIN, or another sequence number gets an ACK,
  which stays asked for until it is sent; the first byte not
  acknowledged has the right sequence number, and moves only to what an
  ACK covers; the host's window is taken only as RFC 9293 3.10.7.4 says;
  the connection ends only by a reset in the window, the last try, or
  the ACK of this side's FIN; the host's half-close comes once per
  connection; with the IP address 0, nothing opens and nothing is sent;
  and the server keeps the contracts that the jobs of the timer, the
  buffers, and the chooser assume. It assumes the parser's promise, that
  a good segment whose data was written has had all of it written, which
  `eth_tcp_rx.sby` proves. Its `cover` reaches each state, the end by the
  last try, by a reset, and by the ACK of the FIN, the probe, and a new
  connection replacing an open one.
- `dbg_host.sby` proves the debugger's host of the debug link,
  `src/dbg/dbg_host.vhd`, with every input free, the link's answers
  too: every packet it sends is whole, an `R` with 12 or a `W` with 20
  upper-case hex digits that are the request's fields, `#`, and its
  checksum, with no console byte; a byte offered stays until it is
  taken; it takes a request only while none is open; and a request ends
  once. Its `cover` reaches an `R` and a `W` sent whole.

The checks in `rx_fifo.vhd`, `board_io.vhd`, `scr_regs.vhd`,
`devices.vhd`, `mem.vhd`, `nicemon.vhd`, `eth/eth_tcp_timer.vhd`,
`eth/eth_tcp_buf.vhd`, `eth/eth_tcp_pick.vhd`, `eth/eth_tcp_rx.vhd`,
`eth/eth_tcp_tx.vhd`, `eth/rx_fcs.vhd`, `eth/eth_arb.vhd`,
`eth/eth_rx_fifo.vhd`, `eth/eth_tx_fifo.vhd`, `eth/eth_tcp.vhd`, and
`dbg/dbg_host.vhd` are in `G_FORMAL` blocks, which are off in
simulation and synthesis.

## Testing the board

`tools/hwtest.py` tests the system on the board itself.

### What you need

- A board, attached by its USB cable, with the bitstream built for it.
  Build that first (see [synth/](synth/README.md)).
- [openFPGALoader](https://github.com/trabucayre/openFPGALoader), which
  programs the FPGA through the same USB cable. Programming needs Linux,
  as the JTAG cable is found through `/sys`; with `--no-program` the
  script runs wherever `load.py` does.
- niceemu, built with `make -C nice_cpu/emulator build`, which `make
  hwtest` does first. Without it, `tools/hwtest.py` skips the checks that
  need it, and its last line names them after a `SKIPPED`.
- The C examples, `examples/build/primes.bin` and `bench.bin`, which
  `make hwtest` builds first with `make examples`. That needs clang, lld,
  and llvm (see [The examples](#the-examples)).

### Running it

    make hwtest PORT=/dev/ttyUSB1

First it finds the board from its UART: the JTAG cable on the same USB
device as the port. It reads the FPGA's IDCODE through that cable, and
stops unless the FPGA is the part the bitstream was built for. So with a
MEGA65 and a Nexys4DDR both attached, it never programs the wrong one.

For the R3, give `BIT=synth/r3/build/top.bit`. For the Nexys4DDR, give
`BIT=synth/nexys4ddr/build/top.bit`. Its UART is usually `/dev/ttyUSB1`
too. With both boards attached, the `ttyUSB` numbers depend on the order
they were plugged in, so name the port by the cable's serial number, as in
`PORT=/dev/serial/by-id/usb-Digilent_Digilent_USB_Device_<serial>-if01-port0`.

A board that is already programmed can be tested with `tools/hwtest.py
--no-program`, which skips the programming and the whole boot test, the
`b` notice and the checks of the ROM. A bitstream with a ROM can be
tested, such as one with the demo (`make demo`, then `make r6
ROM=demo/build/demo.bin`): the test holds the core and hides the ROM, as
`load.py` does, and runs the programs from the RAM.

### What it prints

It prints one line for each check, and last how many passed. With the
pipelined core, all checks pass on both boards, and the Nexys4DDR has
more of them, for its LEDs, display, buttons, and switches. A check that
leaves the board in a state in which every later check would fail stops
the run. Even then the script holds the core with the ROM hidden, and
prints how many passed. If the link does not answer then, it says so:
press the reset button.

### What it checks

It programs the FPGA through the cable alone, with openFPGALoader too, on
every board, and checks the link's `b` notice, and the ROM when the
bitstream has one. Then it hides the ROM and uses the link:

- It writes and reads memory.
- It checks that the link drops a packet with a bad checksum, one cut
  short by an ESC, and one with a gap of 300 ms, that `nicelink.py` sends
  a dropped `R` or `W` again, and that an unknown tag gets `e01` and a bad
  payload `e03`.
- It runs `sim/echo.nasm`, checks that the link reaches only its debug
  registers while the core runs, and holds and restarts the core.
- It pauses `sim/pause.nasm`: the `p` notice, the registers and the memory
  while paused, the stopped cycle counter, a console byte kept, going on,
  a hold, and a start paused.
- It steps `sim/step.nasm` to its halt and compares the registers after
  each step with `niceemu --trace`.
- It runs `sim/break.nasm` to its breakpoints: in a loop, two at one
  address, one disabled, a step that ends at one, the second word of a
  two-word instruction, an interrupt routine, and a `HALT`, each with the
  `x` notice, R15, and the stop register.
- It clears the memory, reads back what `sim/emu.nasm` leaves after its
  halt, and checks that the cycle counter and the timer stop at the halt.
- It writes and reads the screen's registers, and the board's registers:
  on the Nexys4DDR the LEDs, RGB LEDs, and display, and that the buttons
  and switches take no write, and on the MEGA65 that they read 0 and take
  no write.
- It checks `FS_CTRL` of the fetch statistics, and runs
  `examples/build/primes.bin`, and checks that the microsecond counter is
  the cycles over the clock's MHz.
- Last, it runs programs with `run.py` and with `niceemu`, whose output
  and exit status must be the same: among them `sim/eof.nasm`, with no
  input and with 1536 bytes of input, which checks the larger FIFO and the
  end of the input, the intro's `hello.nasm` with 100 lines of input that
  it halts without reading, the emulator's `reserved.nasm`, which halts
  on a reserved control word, its `trapsym.nasm` with `--symbols`, the demo of the ROM with a few keys and its screen, and
  `examples/build/bench.bin`, but for its cycles, whose table it prints.
- Then it runs the demo's self-test, F11, with `run.py`, and checks that
  its four tests pass. The timer's test and the counters' test check
  counts of the core's pipeline, not of the ISA, so a core whose timing
  changes fails them. The rest of that screen, the Ethernet station's
  addresses and counts, differs from board to board and is not compared.

With `ETH=IP`, as in `make hwtest PORT=/dev/ttyUSB1 ETH=192.168.1.65`, and the board's
Ethernet port on this computer's network, it tests the Ethernet station
after all the other checks, which its failures do not stop. It loads
the demo, and types F11, I, the IP address, and CR into it as console
bytes over the UART, as a terminal would, and reads the address back in
a pause. It pings the address and checks the station's counts. It
pauses the demo over the link on TCP and reads the address again, and
then runs the programs above with `run.py --eth`. The address must be
free on the network. If no frame at all reaches the station during the
ping, the board has no Ethernet connection, or the address is not on
this computer's network: the rest is not run, and the summary names it
after NOT COVERED, which does not fail the run. Without `ETH`, the
summary names the Ethernet station there.

The reset button is not tested: press it with a terminal open, and the
`b05` notice comes again.

## The tools and niceemu

`make linktest` runs `run.py --tcp` on `niceemu --link` against plain
`niceemu`, without a board, for the programs that `make hwtest` compares,
the demo's self-test, and nice_cpu's benchmark when `make examples` has
built `examples/build/bench.bin`, with `tools/linktest.py`. It runs hwtest's
checks of bad packets, of the pause, of the step, and of the breakpoints
on `niceemu --link` first, and then `mon.py`'s commands, its disassembly
among them, as typed at its prompt, with the labels of `sim/break.nasm`.
CI runs it.

`run.py` matches `niceemu` in the details too. It accepts
`--no-cycle-counter` and ignores it, as the cycle counter always runs. A
missing or unreadable input file, `.bin` file, or serial device stops
`run.py` with a message before it touches the core, and so does an input
file that is a directory. A usage error, such as an unknown option, exits
with status 1, as in `niceemu`. Each option must stand alone, with its value
as the next argument, so `--sym`, `--dump=1:2`, `-d1:2`, and `-sd` are
errors in both. When stdout closes early, as with `run.py ... | head`,
`run.py` exits quietly with status 141, as `niceemu` does.

## The examples

`examples/Makefile` builds the C examples with the steps of
`nice_cpu/runtime/README.md`, for `examples/primes.c`:

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
`trapmsg.nasm` at the end. Then a trap prints a line such as `trap 2:
memory access out of bounds at 00003dc9` before the core halts. The Makefile
keeps the plain start, so that `bench.bin` is laid out as in nice_cpu's
testbench, and its cycles compare with those below.

`make examples` also builds `examples/build/bench.bin` from nice_cpu's
benchmark, `nice_cpu/bench/bench.c`. It runs six phases, each a known
kernel, and prints the instructions and cycles of each, its result, and
whether that is the expected one. It reads no input, so `tools/run.py`
runs it:

    tools/run.py examples/build/bench.bin

The instructions are the same as on the emulator, and the same at nice_cpu
V1.0 and V1.1. The cycles were measured on the R6 with the pipelined core
at nice_cpu V1.0, and `make hwtest` prints them for the core it tests.
They are beside those of
nice_cpu's own testbench for the core that predicts backward jumps
(`bench/README.md`):

| Phase | Instructions | Cycles on the board | In nice_cpu's testbench |
|---|---|---|---|
| `rng64` | 51746 | 82571 | 82571 |
| `crc32` | 63514 | 80765 | 80765 |
| `bst` | 297825 | 402384 | 403408 |
| `heapsort` | 298396 | 378658 | 378658 |
| `vm` | 840049 | 1248168 | 1248168 |
| `strings` | 101281 | 163585 | 163585 |
| total | 1652811 | 2356131 | 2357155 |

The board takes the same cycles, or 1024 fewer in `bst`, and at 100 MHz
the benchmark runs for about 24 ms.

## The timing badge

The badge claims that nice_cpu's core meets timing at 100 MHz in a MEGA65
build, here: the R6 bitstream, built with Vivado. nice_cpu shows the
badge, and this repository is the proof. `make bump TAG=V1.0`, which runs
`tools/bump.py`, checks that the tree is clean and on `main`, moves the
`nice_cpu` submodule to the tag, builds `niceemu`, runs `make test`, and
builds the R6 bitstream with Vivado's default directives. If that misses
timing, it builds again with `FLOW=timing`, and the badge says so.

It writes two files at the top level and commits them, after a commit of
the submodule bump. `badge-mega65.json` is the badge in the shields.io
endpoint format: `V1.0 met` in green, `V1.0 met (timing flow)`, or `V1.0
failed (WNS -0.12 ns)` in red. `verified.json` is the full record: the
nice_cpu tag and commit, the Vivado version, WNS, TNS, and the hold and
pulse width slacks, the worst paths into and out of the core, the clock,
the board, the flow, and the date. The paths into and out of the core
come from `build/core_in.rpt` and `build/core_out.rpt`, which every build
writes, and nice_cpu sets its budget for the core's ports from them.

A timing miss is a result, and the red badge is committed. A failed build
or test is not: the submodule goes back to where it was, and nothing is
written. The script pushes only with `ARGS=--push`, for a push publishes
the badge. `tools/bump.py V1.0 --reports synth/r6/build` prints the two
files for the reports of an earlier build, and changes nothing. Vivado
does not run in CI, so neither does this.

## Releases

[RELEASE.md](doc/RELEASE.md) is how to make a release, with `make release`,
and [RELEASE_NOTES.md](doc/RELEASE_NOTES.md) has what changed in each.
