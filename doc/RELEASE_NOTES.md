# Release notes

The releases of NiceMonMEGA65, newest first: the versions from `V1.0` on,
and the release candidates `RC02` to `RC06` before them. Each section lists
the changes since the one before that a user of the bitstreams, the boards,
or the tools can see. The git log has the full story, and
[nice_cpu's release notes](https://github.com/MJoergen/nice_cpu/blob/main/RELEASE_NOTES.md) have the changes to
the cores, the emulator, and the tools that come with the submodule.

From `V1.0` on, a release here has the name of the nice_cpu tag it pins,
and a release that leaves the submodule alone adds a third number:
`V1.0.1` and `V1.0.2` pin `V1.0` ([RELEASE.md](RELEASE.md#version-names)).
The release candidates pinned these:

| NiceMonMEGA65 | nice_cpu |
|---|---|
| `RC06` | `RC06` |
| `RC05` | `RC05` |
| `RC04` | `RC04` |
| `RC02` | `4cd869e`, a commit before nice_cpu's `RC02` |

nice_cpu's `RC01` and `RC03` have no tag here.

## V1.2 (2026-10-31)

**Upgrade notes.**

- nice_cpu moves to `V1.2`. The debug link stays at version 5, and
  R0–R15 at `0xFFFFFFE0`–`EF` now read the core's registers live while
  it runs, where they were undefined before. A hold of a running core
  still leaves them undefined. `mon.py`'s `regs` shows them live.
- nice_cpu V1.2's runtime moves `_exit` from `lib.nasm` into the
  start-up files, and its C library's `nice_putc` is an import, so a C
  program of your own needs a rebuild, and a program that joins
  `lib.nasm` without a start-up file of the runtime's must define
  `_exit` itself
  ([nice_cpu's release notes](https://github.com/MJoergen/nice_cpu/blob/main/RELEASE_NOTES.md)).
  `make examples` rebuilds the examples. A program that runs with the
  runtime's start-up files needs no change.
- The program's 25 rows sit 64 lines higher on HDMI and VGA: the
  picture has 29 rows centered, the program's and the 4 rows of the
  on-board debugger's strip under them, which are black until MEGA+HELP
  shows the strip.
- A break on the UART, or a host's half-close over Ethernet, ends the
  line's input and no longer the keyboard's, as nice_cpu's SYSTEM.md §5
  says from V1.2 on: once the bytes before it are read, the console
  reads `0x200`, while the keyboard's bytes still come. Before, every
  byte after a break was lost until the core was started again. A new
  connection over Ethernet starts the line anew, as a connection to
  `niceemu --link` does: the next host's bytes reach the program, so a
  host can type to a monitor that another host has left. The demo
  still ends at a break, as it does in `niceemu`.
- Keys that gave nothing have meanings now. On the MEGA65, CLR/HOME is
  Home, MEGA with CRSR↑ or CRSR↓ is Page Up or Page Down, and MEGA+HELP
  is the on-board debugger's; on the Nexys4DDR, Home, Page Up, and Page
  Down are the keys of those names, and Scroll Lock is the debugger's.
  A program gets `ESC [ H`, `ESC [ 5 ~`, and `ESC [ 6 ~` for Home, Page
  Up, and Page Down, as xterm sends them, and nothing for the
  debugger's key.
- The Ethernet station answers a segment that fits no connection with a
  reset, so a second host's `connect` fails at once while one host is
  connected, where it waited for its retries (see Ethernet).

**The on-board debugger**

- MEGA+HELP brings up a debugger in the FPGA, with no cable and no PC
  ([DEBUGGER.md](DEBUGGER.md),
  [#52](https://github.com/MJoergen/NiceMonMEGA65/issues/52) and
  [#53](https://github.com/MJoergen/NiceMonMEGA65/issues/53)): a strip
  of four rows under the program's screen, white on dark blue, and the
  keyboard is the debugger's until MEGA+HELP again. On the Nexys4DDR
  the key is Scroll Lock. Nothing changes for those who never press it.
  The README's [On its own](../README.md#the-on-board-debugger) says
  how to use it, with a picture.
- The strip shows R0–R15, live while the program runs, and dimmed
  while the core is held; the state, `RUNNING`, `PAUSED`, `BRK n` at
  breakpoint n, `HALTED n` with the reason, `HELD`, or `NO LINK` until
  the link has answered after reset; the PC, the instruction word
  there, and the flags of the status register; and the instruction
  decoded, as `nicedis.py` writes it, with the constant words folded
  in.
- F1 steps, F3 goes on, F5 pauses, F7 holds, and F9 restarts the
  program at 0, with the ROM as it is. The letters `s`, `g`, `p`, `h`,
  and `r` do the same, as in `mon.py`. A key that needs a stopped core
  shows the link's answer, `e02`, and does nothing else.
- F11 shows the page, a window on the memory over the program's rows:
  the window's and the cursor's addresses and the four breakpoints in
  its header, 22 rows of 8 words, the cursor's word in swapped colors,
  and a word at a breakpoint white on dark red. The cursor keys, Page
  Up and Page Down, and Home move; hex digits, DEL, and RETURN write a
  word at the cursor; `a` on an empty field, an address, and RETURN
  move the window there; `b` on an empty field sets a breakpoint at the
  cursor, the lowest free of the four, or clears the one that is there,
  and says `none free`; and ESC clears the field, or leaves the page.
  The words are read while the core is stopped, and dimmed while it
  runs.
- F12 toggles a sticky setting, off after reset: whether MEGA+HELP
  leaves the strip up, live, with the keys the program's. With the
  strip up, a halt, a breakpoint, or a pause the debugger did not ask
  for brings the debugger back, with the keyboard. From off, nothing
  does.
- The debugger is a client of the debug link inside the system, through
  the side port of nice_cpu V1.2's link
  ([nice_cpu#86](https://github.com/MJoergen/nice_cpu/issues/86)): a
  host on the UART or over TCP keeps its line while the debugger is up,
  and gets the `p`, `x`, or `h` of a stop that the debugger caused, as
  it does for a breakpoint. The debugger cannot load a program, write
  a register, or know a label; a host does that.
- On the Nexys4DDR, while the debugger has the keyboard, BTNL steps,
  BTNR goes on, BTNU and BTND move the page's cursor, BTNC leaves, and
  the seven-segment display shows the PC, live, or dashes while the
  core is held. The program reads the buttons as 0 meanwhile, and its
  display shows again after.

**Boards**

- The MEGA65's keyboard sends `ESC [ H` for CLR/HOME, and `ESC [ 5 ~`
  and `ESC [ 6 ~` for MEGA with CRSR↑ and CRSR↓, so MEGA is a modifier
  of those two keys. The Nexys4DDR's keyboard sends the same for Home,
  Page Up, and Page Down, apart from the keypad's keys with the same
  scan codes. nice_cpu's SYSTEM.md §1 now defines the bytes of the keys
  that every keyboard has, which the MEGA65's keyboard follows and
  `niceemu --window` sends too.
- The R6 meets 100 MHz with 0.33 ns of setup slack, and the Nexys4DDR
  90 MHz with 0.17 ns, with the debugger. The TCP server's paths were
  registered, so the worst paths are the core's again, and the
  station's have about 2.3 ns to spare on the R6
  ([#49](https://github.com/MJoergen/NiceMonMEGA65/issues/49)). The
  debugger's overlay takes 4 block RAMs on each board.
- The R3 build has the debugger and the station, and has not been
  tested on hardware yet.

**Ethernet**

- The station answers a segment that fits no connection with a reset,
  as RFC 9293 has it, where it answered nothing: a `connect` from a
  second host while one is connected fails at once with "connection
  refused", where it waited about two minutes, and a host on a
  connection the board has dropped learns of it at once, where it
  retried for a quarter of an hour. `nicelink.py` says that another
  host has a connection to the board when it is refused
  ([#46](https://github.com/MJoergen/NiceMonMEGA65/issues/46)).
  Segments to other ports, and every segment while the IP address is
  0, get nothing, as before.
- Once a connection is open, a segment without ACK is dropped, and one
  that acknowledges what the board has not sent gets an ACK and is
  dropped, as RFC 9293 has it
  ([#50](https://github.com/MJoergen/NiceMonMEGA65/issues/50)).
- A new connection starts the line's input anew (see the upgrade
  notes), as one to `niceemu --link` does, through `rx_resume_i` of
  nice_cpu V1.2's link
  ([nice_cpu#90](https://github.com/MJoergen/nice_cpu/issues/90)).
- Fixed: after a reset from the host, or the last of the 17 tries, with
  data out, the retransmission timer stayed armed and ran out every
  300 ms until the next connection
  ([#45](https://github.com/MJoergen/NiceMonMEGA65/issues/45)); an ACK
  that covered the data and the board's FIN at once was not booked; an
  ACK that came while a segment was sent again freed its first bytes,
  which the link's next output could overwrite while the sender still
  read them, so the host got wrong bytes with a wrong checksum; and a
  segment of an old connection could, with odds of 1 in 2³², be taken
  for a new connection from the same port.
- The server is split into its parser of segments, its choice of the
  segments to send and their sender, its buffers, and its
  retransmission timer, and the arbiter of the frames to send is an
  entity of its own
  ([#39](https://github.com/MJoergen/NiceMonMEGA65/issues/39)), each
  with a formal proof (see Tests). A segment is answered a cycle or two
  later than before, which no timeout sees.

**Monitor**

- The monitor for the ROM is written and tested in `niceemu`, not on a
  board yet ([monitor/](../monitor/README.md),
  [#24](https://github.com/MJoergen/NiceMonMEGA65/issues/24)): a
  dispatch table at 0 with nine entries, a hardware abstraction layer
  for programs at `0x8000` in the C ABI, with the reset, the exit, the
  version, the console, and the screen, and a main loop with the
  commands `r`, `d`, `c`, `v`, `h`, and `?`. `make monitor` builds it,
  `make -C monitor test` runs it in `niceemu` with programs built by
  nice_cpu's `nicebuild.py --monitor`, and `make cor
  ROM=monitor/build/monitor.bin` puts it in a core of your own. It
  cannot load a program on its own, so the release's ROM still holds
  the demo.

**Demo**

- The demo runs in `niceemu --window` too, from nice_cpu V1.2 on, with
  the keys typed into the window, and the comet keeps its pace, as the
  window runs one step per microsecond ([demo/](../demo/README.md)).

**Tools**

- `make flash COR=f.cor SLOT=N` writes a core file into slot N, 1 to 7,
  of the MEGA65's flash over the JTAG cable, with no SD card and no key
  held at power on. It stops unless slot 0's core is for the core
  file's revision, shows what the slot held, verifies the flash, and
  starts the slot, through the serial monitor of slot 0's core if that
  core does not start it. It is written against the MEGA65's
  documentation and openFPGALoader, and has not been run on a board yet
  ([#41](https://github.com/MJoergen/NiceMonMEGA65/issues/41)).
- `tools/screenshot.py --debugger` draws the on-board debugger's strip
  under the screen, as the board shows it at the stop. The README's
  picture of the debugger is made with it.
- `make monitor` builds the monitor, and `make diagrams` draws the
  block diagrams of `src/` (needs pdflatex and pdftoppm).

**Documentation**

- `doc/DEBUGGER.md` is the design note of the on-board debugger: the
  states, the display, the keys, the Nexys4DDR, the side port, the
  modules, the tests, the stages, and the decisions with their reasons.
- `src/README.md` and `src/eth/README.md` have block diagrams of the
  system and of the Ethernet station, drawn by `make diagrams` from the
  `.tex` files beside them.
- `doc/EMULATOR.md`'s table has `niceemu --window`, and a row for the
  keyboard. `doc/SYSTEM.md` has the keys, the 29 rows, the line's
  input, the debugger, and the station's resets.
- `doc/BASIC_SURVEY.md` surveys the BASIC dialects behind the
  interpreter planned for the ROM
  ([#54](https://github.com/MJoergen/NiceMonMEGA65/issues/54),
  milestone V2.0).
- `monitor/README.md` has the monitor's table, the entry ABI, its
  decisions, and what is not decided yet.

**Tests**

- `make test` runs `tb_dbg`, the debugger on the system, driven by
  keys, toggles, and the Nexys4DDR's buttons; `tb_dbg_host`, its
  adapter against the link's side port, with a host on the UART beside
  it; `tb_dbg_decode`, the decode of row 27 against `nicedis.py` on
  about 3000 words from `sim/gen_decode.py`; and the monitor's test in
  `niceemu`. `tb_text` checks the strip and the page, `tb_kbd` and
  `tb_ps2` the toggle keys and the new keys, and `tb_nicemon` the live
  registers, the keyboard after a break, and the station's ports.
- `tb_eth_tcp` has steps for the edges of RFC 9293, and
  `tb_eth_tcp_random` runs 2500 random actions of the host and the link
  on one connection whose sequence numbers cross 2³², which found the
  retransmission bug above.
- `make formal` proves the check of the frame check sequence, the
  arbiter, the two FIFOs of frames across their clocks, the TCP
  server's timer, buffers, choice, parser, and sender, the connection
  itself with free models of its parser and choice, and the debugger's
  adapter to the side port
  ([#37](https://github.com/MJoergen/NiceMonMEGA65/issues/37)).
- `make lint` checks `src/dbg/`, and every Vivado build writes the
  worst paths of the TCP server to `build/tcp_paths.rpt`.

## V1.1 (2026-10-29)

**Upgrade notes.**

- `0xFFFFFF98`–`9D` are the Ethernet station on every board. They read
  0 and took no write before, on the MEGA65 and on the Nexys4DDR.
- The debug link over Ethernet reads and writes all memory with no
  password. The station is silent until it gets an IP address, so give
  it one only on a network you trust.
- nice_cpu moves to `V1.1`, and the debug link to version 5. A clear of
  the memory now ends the halt and the stop of the program it wipes:
  bit 1 of the control register, the halt reason, and the stop register
  read 0 after it. So after `load` in `mon.py`, `status` shows `held`,
  not `held, after a halt`, and the control register reads `00000009`.
  A hold alone keeps them, as before
  ([#32](https://github.com/MJoergen/NiceMonMEGA65/issues/32)).
- `load.py`, `run.py`, and `mon.py` have no default line: they need
  `--eth`, `--port`, `--tcp`, or `--cosim`, and stop with an error
  without one. `/dev/ttyUSB1` was the default before. `hwtest.py`,
  `flash.py`, `release.py`, and `demo_hw.py` need `--port`. Likewise,
  `make load`, `make run`, and `make mon` need `ETH=` or `PORT=`, and
  `make hwtest`, `make flash`, and `make release` without
  `ARGS=--publish` need `PORT=`.

**Ethernet**

- Every board has an Ethernet station on its Ethernet port, at
  100 Mbit/s ([SYSTEM.md](SYSTEM.md#the-ethernet-station)). A write of
  its IP address to `0xFFFFFF9A`, by a program or over the link on the
  UART, turns it on. It is 0 after reset, which answers nothing.
  There is no DHCP client yet, so a board needs its USB cable, a
  program that sets the address, or the demo's F11, before `--eth` can
  reach it ([#34](https://github.com/MJoergen/NiceMonMEGA65/issues/34)).
- The R3 build has the station but has not been tested on hardware yet.
- The station answers ARP requests and pings to its IP address. Its MAC
  address is 02:4E:49:43:45:00 after reset, and `0xFFFFFF9B`–`9C` change
  it, which two boards on one network need.
- It serves the debug link on TCP port 4510, to one host at a time. The
  connection is the line, as the UART is: it sends no `b` notice, and a
  half-close is a break. While a host is connected, the UART's link
  bytes are dropped. A new connection from the same host replaces the
  old one.
- The board resends what the host does not acknowledge after 300 ms, and
  drops the connection after 17 tries.
- `0xFFFFFF98`, `99`, and `9D` count the good frames received, the bad
  and dropped ones, and the frames sent.

**Boards**

- F1 to F12 give xterm's escape sequences, on the Nexys4DDR's keyboard
  and on the MEGA65's, which has F1, F3, and so on to F11, and the even
  keys with SHIFT. They gave nothing before.

**Demo**

- The welcome says to give the board an IP address with F11, then to
  load and debug programs over Ethernet with `tools/mon.py --eth`. It
  pointed to the debug UART before.
- The function keys switch between the demos in the ROM, which a menu in
  the second row lists. The typewriter is F1, and runs at power-up. The
  other five are the ideas of
  [#28](https://github.com/MJoergen/NiceMonMEGA65/issues/28), each on a
  key of its own.
- An ESC that no byte follows within 10 ms is a key of its own, as the
  MEGA65's ESC key sends it. The typewriter dropped it before, and took
  the key after it as it was, and it held up the other demos until the
  next key.
- F3 shows the bytes of each key, in hex and as characters.
- F5 shows the 256 characters of the font and ramps of seven colors, as
  backgrounds and as foregrounds, to check the video output.
- F7 shows the performance counters since reset, as a clock and in
  decimal, with the clock's frequency, and those of a prime sieve that
  runs again and again, with its cycles per instruction.
- F9 is a game: the cursor keys steer a comet to the stars, and its tail
  grows with each one.
- F11 is the board. It tests the RAM, the math unit, the timer's
  interrupts, and the performance counters, with PASS or FAIL for each.
  Below the tests it shows the Ethernet station's IP and MAC addresses
  and its three counts, and the I and M keys type a new IP or MAC
  address and write it to the station
  ([#40](https://github.com/MJoergen/NiceMonMEGA65/issues/40)). ESC,
  CTRL-C, or RUN/STOP cancels the typing. A byte of a MAC address has
  one or two hex digits, and a number of an IP address any number of
  digits, such as `001`, as long as it is 255 at most. A
  board with the demo in its ROM can thus get its IP address from its
  own keyboard, with no USB cable.

**Tools**

- `load.py`, `run.py`, and `mon.py` take `--eth HOST[:PORT]` for the
  link over the board's Ethernet port. They close each connection with a
  reset, by `SO_LINGER` 0.
- `make flash` (`tools/flash.py`) writes a bitstream into the
  Nexys4DDR's flash, verifies it, and waits for the board to start from
  it. With jumper JP1 on QSPI, the board then starts the system at power
  on, and with the release's bitstream it shows the demo, as a MEGA65
  does with a core file in its flash.
- `mon.py` disassembles with `d ADDR N`, and shows the instruction at the
  PC after a pause, a step, and a breakpoint. The disassembler is
  nice_cpu's `assembler/nicedis.py`, new in nice_cpu's `V1.1`.
- `mon.py --symbols FILE` and its `symbols FILE` command read the labels
  of `niceasm.py --symbols` and `nicebuild.py --symbols`. An address may
  then be a label, `label+N`, or `label-N`, and the output shows the
  labels.
- `mon.py` ends without a traceback on `quit`, also over `--tcp` and
  `--cosim` ([#29](https://github.com/MJoergen/NiceMonMEGA65/issues/29)).
- `tools/screenshot.py` runs a program in `niceemu` and draws its screen
  as a PNG picture, as the text display shows it. The README's pictures
  of the demo are made with it.
- `make linktest` checks `mon.py`'s commands on `niceemu --link` too.
- The tools read the link's version when they connect, and stop with a
  message on a major other than 0 (nice_cpu's DEBUG.md §9). `mon.py`'s
  `status` shows the version as major.minor, and `hwtest.py` checks the
  version of the pinned nice_cpu's `debug_link.vhd`, not a fixed 4.

**Documentation**

- `SYSTEM.md`, `EMULATOR.md`, `CODING_STYLE.md`, `RELEASE.md`, and
  `RELEASE_NOTES.md` move into `doc/`. `README.md` and `CONTRIBUTING.md`
  stay at the root.
- The README is for users of the core files, on their own and with the
  serial port, with a worked example. The guide to `load.py`, `run.py`,
  and `mon.py` moves to `tools/README.md`. The new `doc/PROGRAMMING.md`
  says how to write and build programs, and the new `doc/README.md`
  lists the documents.

**Tests**

- `make test` runs the Ethernet station's testbenches: `tb_rmii_rx`,
  `tb_rx_fcs`, `tb_eth_rx_fifo`, `tb_eth_tx_fifo`, `tb_rmii_tx`,
  `tb_eth`, which drives the station at its pins, and `tb_eth_tcp`,
  which checks the TCP server against a host modeled in VHDL.
- `make hwtest` and `make linktest` run the demo's self-test, F11, and
  check that its four tests pass. The tests of the timer and of the
  counters depend on the core's timing, so a nice_cpu bump that changes
  it fails them
  ([#43](https://github.com/MJoergen/NiceMonMEGA65/issues/43)).
- `make -C demo test` also checks how a failed self-test shows, the
  colors of the menu and of PASS and FAIL, and the keys that no test had.

**Release**

- `make release` builds the Nexys4DDR only with `FLOW=timing`, as its
  Makefile does, and no longer tries the default flow first, which never
  meets timing there.
- `make release` builds the R6 with the flow of `verified.json` first,
  and then with the other one, for the ROM can cost the margin of the
  bump's build. The notes say when the other flow was needed.
- `make hwtest ETH=IP` tests the Ethernet station too, after all the
  other checks: the demo's F11 gets the address as keys over the UART,
  and gives it to the station, which is pinged, reached by the link over
  TCP, and runs the programs of the comparison over `run.py --eth`. A
  board that receives no frame has no Ethernet connection, and the
  summary names the rest of the test after NOT COVERED, which fails
  nothing; without `ETH`, it names the station there.
  `make release ARGS="--eth IP"` passes it on.

## V1.0 (2026-10-28)

**Upgrade notes.**

- nice_cpu `V1.0` builds `niceemu` with Zig 0.17.0, and no longer with
  0.15. The tools, `make hwtest`, and `make -C sim check-steps` need the rebuilt
  binary: `make -C nice_cpu/emulator build`.
- This is the first release with files: the three bitstreams, the two
  MEGA65 core files, and the C examples are on the GitHub Release.

**Boards**

- `make cor` builds core files for the R3 and the R6, which MEGAFLASH
  writes to a slot of the MEGA65's flash. The board then starts NiceMon
  without a JTAG cable.
- Every build writes the core's worst paths in and out of the core,
  `build/core_in.rpt` and `build/core_out.rpt`, from which nice_cpu sets
  its budget for the core's ports.

**Tools**

- `tools/mon.py` is an interactive shell on the debug link, and `make mon
  [FILE=p.bin]` runs it. It reads and writes memory, loads a `.bin` file,
  starts, holds, pauses, steps, and goes on, sets the breakpoints, and
  shows the registers and the state. It shows the program's output and
  the link's notices as they arrive, and sends console input or passes
  the terminal through to the program. It takes `--port`, `--tcp`, and
  `--cosim`, as `load.py` does.

**Documentation**

- `README.md` is now for users of the core files: the MEGA65 on its own,
  and with the serial port. The address map, the link, the screen, the
  ROM, and the Nexys4DDR's devices are in `SYSTEM.md`. The tests, the
  formal checks, `make hwtest`, and the badge are in `CONTRIBUTING.md`.

**System**

- `nicemon.vhd` is split into `mem.vhd`, `devices.vhd`, `scr_regs.vhd`,
  and `board_io.vhd`, with no change in behavior or address map.
  `kbd_ascii.vhd` is now `kbd_m65_ascii.vhd`.
- `formal/mem.sby` proves the memory by k-induction, and that a read
  returns what was written, 0 after a clear, or the ROM's word.

**Tests**

- The `.nasm` files of `sim/` are laid out in nice_cpu's columns, and
  `make test` checks the layout with nice_cpu's `nicefmt.py`.

**Demo**

- The bitstreams and the core files of the release have a demo in the
  ROM (`demo/`), so a MEGA65 with no computer on its debug UART no longer
  starts with a black screen. It shows a welcome with the version, and
  then a typewriter: what is typed on the keyboard appears on the screen,
  with RETURN, DEL, TAB, the cursor keys, CTRL-L to clear, and scrolling.
  The tools hide the ROM, and load programs as before.
- `make demo` builds it, and `make test` and CI run it in `niceemu`.

**Release**

- `make bump TAG=V1.0` moves nice_cpu to a tag, builds the R6 bitstream,
  and records the timing in `badge-mega65.json`, the badge that nice_cpu's
  README shows, and in `verified.json`.
- `make release` builds, tests, and publishes a release
  ([RELEASE.md](RELEASE.md)).
- The tags follow nice_cpu's version names, and CI takes its Zig version
  from nice_cpu's CI.

## RC06 (2026-10-27)

**Upgrade notes.**

- The debug link is version 4. `load.py` and `run.py` disable the
  breakpoints before a load, as the board keeps them until a reset, where
  `niceemu` clears them at each connection.

**Debug link and tools**

- Four breakpoints on every board, at `FFFFFFF4`–`FF`. The core pauses
  before an enabled one, and the link sends `x` with its number.
- `nicelink.py` has `set_breaks()`, and takes `x` as a pause.

**Tests**

- `tb_nicemon` stops `sim/break.nasm` at a read of memory and in an
  interrupt routine, and checks that a reset clears the breakpoints.
- `hwtest.py` has `test_break`, which runs on the board, in `make
  linktest`, and in `make cosimtest`.

**Timing**

- The R6 meets 100 MHz by 0.595 ns, and the Nexys4DDR 90 MHz by
  0.111 ns.

## RC05 (2026-10-26)

**Upgrade notes.**

- The debug UART runs at 2 Mbaud, not 115200 baud. The tools default to
  it. A bitstream from before needs `--baud 115200`.
- The debug link is version 3.

**Debug link and tools**

- Bit 4 of the control register pauses the core at a step boundary, and
  the link sends `p` (version 2). The link reaches all of the memory and
  the registers while the core is paused. The counters, the timer, and the
  fetch statistics stop. Console and keyboard bytes wait in the input
  FIFO.
- Bits 4 and 5 run one step of a paused core, and the link sends `p`
  again, or `h` if the step halted (version 3).
- Loading `primes.bin` takes 0.7 s instead of 6.9 s.
- `nicelink.py` has `PAUSE` and `step()`.

**Simulation**

- `make cosim` runs the system in GHDL with its debug UART on a TCP port,
  and the tools reach it with `--cosim PORT`.
- `make cosimtest` runs `hwtest`'s checks and programs on it against
  `niceemu`, without a board. CI runs it on both cores.

**Tests**

- `hwtest.py` has `test_pause` and `test_step`. `test_step` compares
  R0–R15 after each step with `niceemu --trace`.

**Timing**

- The R6 meets 100 MHz by 0.628 ns, and the Nexys4DDR 90 MHz by
  0.187 ns.

## RC04 (2026-10-24)

**Upgrade notes.**

- The command line on the debug UART is gone. The board speaks nice_cpu's
  debug link instead, as `niceemu --link` does, and the tools of `RC02` do
  not work with it.
- `run.py` ends at the link's halt notice, not at the halt message in the
  output. On `--timeout` it holds the core, prints the dumps, and exits
  with status 3.

**Debug link and tools**

- `tools/nicelink.py` speaks the link over the debug UART, or over TCP to
  `niceemu --link` with `--tcp PORT`. It retries a bad packet, and paces
  the input by the free space of the input FIFO.
- `run.py` takes `niceemu`'s options, including `--symbols`, and names
  where a program stopped after a halt other than `HALT`.
- `make linktest` checks the tools on `niceemu --link`, without a board.

**System**

- The microsecond counter, `TIME_LO` and `TIME_HI` at `FFFFFF44` and
  `FFFFFF45`, is exact on every board.
- The fetch statistics stop while the core is held or halted.

**Boards**

- The Nexys4DDR's 16 LEDs, two RGB LEDs, seven-segment display, five
  buttons, and 16 switches are registers at `FFFFFF90`–`96`. On the
  MEGA65, the block reads 0, as in the emulator.
- DEL with CTRL held stays DEL on the PS/2 keyboard, as on the MEGA65.
- A failed Vivado build fails `make`.

**Tests**

- `tb_board_io` checks the Nexys4DDR's drivers, and `tb_ps2_nicemon` the
  PS/2 keyboard into the core's input. Keys typed while the input is full
  are lost on the Nexys4DDR, as a PS/2 keyboard cannot wait.
- CI runs on Ubuntu 24.04, with both cores and the examples.

## RC02 (2026-10-23)

The first release candidate here. It holds:

- **The system**, `src/nicemon.vhd`: nice_cpu's pipelined core, or its
  multi-cycle core with `NICE=multi`, with RAM, a ROM at address 0,
  nice_cpu's devices, and an input FIFO fed by the debug UART and the
  keyboard.
- **Three boards**: the MEGA65 R3 and R6 at 100 MHz, and the Digilent
  Nexys4DDR at 90 MHz with a PS/2 keyboard.
- **A text display** on VGA and HDMI, with QNICE's screen registers at
  `FFFFFF80`, a cursor, and 12-bit RGB colors.
- **A command line** on the debug UART at 115200 baud, and the host tools
  `load.py`, `run.py`, and `hwtest.py`. `run.py` runs a program as
  `niceemu` does, for diffing, and `make hwtest` tests a board, with
  nice_cpu's benchmark.
- **Tests**: GHDL testbenches of the system, the keyboard, and the
  display, formal checks of the command line, the input FIFO, and the
  buses, and `vsg` lint, all in CI.
- **[EMULATOR.md](EMULATOR.md)**, the known differences from the emulator.
