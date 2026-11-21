# The host tools

The tools run on the host, and control the board remotely over its
Ethernet port or its debug UART, with the debug link of
[DEBUG.md](https://github.com/MJoergen/nice_cpu/blob/main/doc/DEBUG.md).
They use only the Python standard library, and run on Linux and macOS, but
`nicemon.py flash` needs Linux, and pyftdi for the MEGA65.

`tools/nicemon.py` is the command that users run, with a subcommand for
each tool, which has a section of its own below, in this order:

    tools/nicemon.py load  --eth 192.168.1.65 [--monitor] prog.bin
    tools/nicemon.py run   --eth 192.168.1.65 prog.bin
    tools/nicemon.py mon   --eth 192.168.1.65 [prog.bin]
    tools/nicemon.py sd    --eth 192.168.1.65 ls
    tools/nicemon.py nbd   --eth 192.168.1.65
    tools/nicemon.py flash --port /dev/ttyUSB1 (--bit f.bit | --cor f.cor --flash-slot N)
    tools/nicemon.py tftpd [--dir DIR]

- [nicemon.py load](#nicemonpy-load) loads a program into the board and
  starts it, or an image of BASIC into the ROM.
- [nicemon.py run](#nicemonpy-run) runs a program on the board and
  prints what `niceemu` prints, for diffing.
- [nicemon.py mon](#nicemonpy-mon) is an interactive shell on the link.
- [nicemon.py sd](#nicemonpy-sd) lists, copies, writes, and deletes
  the files of the board's SD card.
- [nicemon.py nbd](#nicemonpy-nbd) serves the board's SD card as a disk
  of a Linux PC.
- [nicemon.py flash](#nicemonpy-flash) writes the flash that a board
  starts from.
- [nicemon.py tftpd](#nicemonpy-tftpd) serves files to BASIC's `LOAD`
  and `DIR`.

[hwtest.py](#hwtestpy) tests the board, and [the other
tools](#the-other-tools) test the tools and build releases.

| Tool | What it does |
|---|---|
| `nicemon.py` | The front end, with the subcommands below. |
| `cli.py` | The messages and exit codes that the subcommands share. |
| `boardlink.py` | The debug link, which the other tools use: nice_cpu's `debugger/nicelink.py`, over TCP to `niceemu --link` and on the UART, with the board's own links over TCP to its Ethernet port and to `make cosim`. |
| `load.py` | `nicemon.py load`: loads a `.bin` file into cleared memory and starts it, or with `--hold` leaves the core held in reset. With `--monitor`, it runs a program at `0x8000` under the monitor in the ROM. |
| `run.py` | `nicemon.py run`: runs a program on the board and prints what `niceemu` prints, for diffing, also one under the monitor with `--monitor`. |
| `mon.py` | `nicemon.py mon`: an interactive shell on the link: memory, registers, pause, step, breakpoints, and the console. It is nice_cpu's `debugger/nicedbg.py` with the board's links. |
| `sdcard.py` | `nicemon.py sd`: lists, copies, writes, and deletes the files of the folder `NICE` on the board's SD card, with no PC slot, and makes the folder. |
| `sdnbd.py` | `nicemon.py nbd`: serves the board's SD card as a block device over NBD, so that Linux mounts it as a folder, all of the card, for the file manager. |
| `flash.py` | `nicemon.py flash`: writes a bitstream into the Nexys4DDR's flash, or a core file into a slot of the MEGA65's, from which the board starts. |
| `tftpd.py` | `nicemon.py tftpd`: a TFTP server for BASIC's `LOAD` and `DIR`, which also lists the files of its folder for a name with `*` or `?`, and with `--write` for its `SAVE` and `BSAVE`. |
| `hwtest.py` | Programs the FPGA with openFPGALoader and tests the system on the board. |
| `jtag.py` | The JTAG cable of the board's UART, and the check that the board is the one a bitstream or core file was built for, which `hwtest.py` and `flash.py` use. |
| `spiflash.py` | The MEGA65's flash through openFPGALoader's bridge, which `flash.py` uses to clear the protection of its sectors. |
| `linktest.py` | Checks `nicemon.py run` and `mon`, the old names, and the link on `niceemu --link` against plain `niceemu`, without a board. |
| `sdtest.py` | Checks `nicemon.py sd` and `nbd` on `niceemu --link` with images of a card, without a board. |
| `tftptest.py` | Checks `nicemon.py tftpd`, and BASIC's TFTP in `niceemu` against it, without a board. |
| `tcptest.py` | Checks the monitor's TCP in `niceemu` against `tcppeer.py`, and its timers with `--step-time`, without a board. |
| `tcppeer.py` | A TCP peer of its own on `niceemu`'s frames, with a script for each port, and for each connection it opens to a port where the board listens, for `tcptest.py`. |
| `weathertest.py` | Checks the weather display, `examples/weather.c`, in `niceemu` against `tcppeer.py`, without a board. |
| `cosimtest.py` | Checks `nicemon.py run` and the RTL on `make cosim` against plain `niceemu`, without a board. |
| `romsize.py` | Measures the words of the ROM and of the demo, and writes or checks their tables in `monitor/INTERNALS.md` and `demo/README.md`. |
| `screenshot.py` | Runs a program in `niceemu` and draws its screen as a PNG picture, as the text display shows it, and with `--debugger` the on-board debugger's strip under it. |
| `bump.py` | Moves nice_cpu to a tag, builds the R6 and Nexys4DDR bitstreams, and writes the badge files and `verified.json`. |
| `release.py` | Builds, tests, and publishes a release (see [RELEASE.md](../doc/RELEASE.md)). |

## nicemon.py

`nicemon.py --help` lists the subcommands, and `nicemon.py SUBCOMMAND
--help`, or `nicemon.py help SUBCOMMAND`, gives a subcommand's usage, a
short description, and its options. Each subcommand is a module of
`tools/`, which the others import as a library, and which `nicemon.py`
imports only when its subcommand runs, so that only `flash` needs
pyftdi, and whose header says more. The name is that of the project and
of `src/nicemon.vhd` too, and matches nice_cpu's `nicedbg`, `nicelink`,
and `nicebin`.

The subcommands look like one command:

- Errors, warnings, and progress go to stderr, each line after
  `nicemon.py SUBCOMMAND: `. stdout carries only the console and the
  data that a subcommand prints: `run`'s output, `sd ls`, and
  `sd get NAME -`, so it can be piped.
- The exit status is 0 for success, 1 for an error of the board, the
  link, or a file, 2 for an error of the command line, 130 after
  Ctrl-C, and 141 when stdout closes early, as with
  `nicemon.py sd ls | head`. `run` exits with the program's status
  instead, and with 1 for an error of the command line, as `niceemu`
  does (see [Exit status](#exit-status)).
- The help of each subcommand gives each option's text in lower case,
  with its default in parentheses. The link's options are a group of
  their own, "the link", with the same text in every subcommand.
- `nicemon.py --version` prints the tags of this repository and of
  nice_cpu, from `git describe`, such as
  `nicemon.py V2.4.1, nice_cpu V2.4`.

`tools/cli.py` has the messages, the exit codes, and the `--listen`
option that `nbd` and `tftpd` share.

The old names, `tools/load.py`, `run.py`, `mon.py`, `sdcard.py`,
`sdnbd.py`, `flash.py`, and `tftpd.py`, still run the matching
subcommand until V3.1 removes them
([#156](https://github.com/MJoergen/NiceMonMEGA65/issues/156)). They
take the options that V2.4.1 renamed by their old names too, with a
warning that names the new one.

## The line

The board's line carries the program's console both ways, and the
packets of the debug link between its bytes (see
[DEBUG_LINK.md](../doc/DEBUG_LINK.md)). The line is a TCP
connection to the board's Ethernet port, or its debug UART, which needs
a JTAG cable. The tools use the link, and `niceemu --link` serves the
same link, so the tools drive the emulator as they drive the board.
When they connect, the tools read the link's version, and stop on a
major other than 0, which they do not know ([DEBUG.md §9](https://github.com/MJoergen/nice_cpu/blob/main/doc/DEBUG.md#9-versions)).

`load`, `run`, `mon`, `sd`, and `nbd` take the line as an option, shown
as `(link)` in their usage, one of:

- `--eth HOST[:PORT]` for the board's Ethernet port (see
  [Over Ethernet](#over-ethernet)), such as `--eth 192.168.1.65`.
- `--port DEVICE [--baud N]` for its serial port (see
  [The serial port](#the-serial-port)), such as `--port /dev/ttyUSB1`.
- `--tcp [HOST:]PORT` for `niceemu --link` (see
  [Without a board](#without-a-board)).
- `--cosim PORT` for the simulated system of `make cosim`, at about 250
  UART bytes a second.

`flash` and `hwtest.py` take `--port` alone, and `hwtest.py`'s `--eth`
tests the Ethernet port beside it.

`make` has a target for each subcommand, which runs `nicemon.py`:
`make load`, `make run`, `make mon`, `make sdcard`, `make sdnbd`,
`make flash`, and `make tftpd`. Those of the line take
`ETH=192.168.1.65` for the Ethernet port, or `PORT=/dev/ttyUSB1` for
the serial port, and one of the two. They pass `ARGS=` on to the
subcommand, and `ARGS="--tcp 4000"` drives `niceemu --link 4000`
instead of the board. Each section below names its target.

### Over Ethernet

The board serves remote control on TCP port 4510 of its Ethernet
station, once it has an IP address
([DEBUG_LINK.md](../doc/DEBUG_LINK.md#the-debug-link-over-tcp)). After reset it
has none, and the monitor gets one from the network's DHCP server on
its own, and shows it after BASIC's `READY.`
([README](../README.md#giving-the-board-an-address)). BASIC's `IP`
sets another, `IP "192.168.1.65"`, and the demo's F11 does
too: I types a new IP address. Then use `--eth` with any tool:

    tools/nicemon.py run --eth 192.168.1.65 prog.bin

`--eth HOST:PORT` names another port. A plain TCP client, such as
`nc -N 192.168.1.65 4510`, shows the program's console. It sends each
line you type, and Ctrl-D sends a break, which ends the line's input
(`-N` makes the end of stdin a half-close, which the board takes as a
break). The board keeps the connection after that, so Ctrl-C then ends
`nc`.

The board serves one host at a time. While a host is connected over
Ethernet, the UART carries no link: its bytes are dropped. A new
connection from the same host replaces the old one. The tools end their
connection with a reset, so that the UART has the link again at once;
after `nc`, the UART has it again when a tool connects from the same
host, or after a reset of the board. The link has no password, and the
monitor gets an IP address from DHCP on its own, so plug the cable
only into a network you trust.

### The serial port

The MEGA65's debug UART runs at 230400 baud, 8-N-1, after reset, the
tools' `--baud` by default, or at the rate written to `0xFFFFFF9F`
([doc/DEBUG_LINK.md](../doc/DEBUG_LINK.md#the-baud-rate)), which `--baud` must
match. It needs the JTAG cable, whose USB port carries it. It is usually the serial device
`/dev/ttyUSB1`. Give it to the tools with `--port`, or to `make` with
`PORT=`, and open it in your terminal program. On
macOS, use the `/dev/cu.*` device, as a `/dev/tty.*` device blocks on
open. The port must not be open in a terminal while a tool runs.

A terminal program, such as `picocom`, shows the program's console:
`picocom -b 230400 /dev/ttyUSB1`. In picocom,
`Ctrl-A Ctrl-\` sends a break, which ends the line's input; the
keyboard's goes on.

The debug link on the serial port gives the board an IP address too,
with no key typed. The core is paused for the write, as the link
reaches only its own registers while the core runs:

    tools/nicemon.py mon --port /dev/ttyUSB1
    dbg> pause
    dbg> w FFFFFFB0 C0A80141
    dbg> go
    dbg> q

### Without a board

`--tcp PORT` drives `niceemu --link PORT` instead of the board, which
checks the tools and the link against the plain emulator:

    nice_cpu/emulator/zig-out/bin/niceemu --link 4000 &
    tools/nicemon.py run --tcp 4000 prog.bin

`--tcp HOST:PORT` reaches a `niceemu` on another computer, which serves
the link on an address other than 127.0.0.1. An IPv6 HOST goes in
brackets, as for `niceemu --link`:

    niceemu --link 0.0.0.0:4510 prog.bin       # on emuhost
    tools/nicemon.py mon --tcp emuhost:4510    # on your own computer

The link has no authentication: anyone who reaches the port can read
and write the emulator's memory. Serve it beyond 127.0.0.1 only on a
trusted network. Elsewhere, forward the port over SSH instead:

    ssh -L 4510:127.0.0.1:4510 emuhost 'niceemu --link 4510 prog.bin'
    tools/nicemon.py mon --tcp 4510

With `--tcp`, the end of the input half-closes the connection, and `--dump`
cannot reach `0xFFFFFFD0`–`FF`, which are the emulator's memory.

## nicemon.py load

`nicemon.py load` loads a program into the board and starts it. It holds
the core, hides the ROM if there is one, clears the memory, writes the
words with `W` packets, and then starts the core. It holds the core
first, so it also works while a program runs.

    tools/nicemon.py load (link) [--hold] [--monitor [--rom FILE] | --basic] FILE

- `FILE` is a `.bin` file, one line per word, the address and the word
  in hex.
- `--hold` loads the program and leaves the core held in reset.
- `--monitor` runs a program at `0x8000` under the monitor in the ROM,
  and `--rom FILE` loads FILE at 0 in place of the ROM (see
  [Running a program under the monitor](#running-a-program-under-the-monitor)).
- `--basic` loads an image of BASIC into the ROM (see
  [Loading BASIC into the ROM](#loading-basic-into-the-rom)).

`make load FILE=prog.bin (ETH=IP | PORT=DEVICE)` runs it, with
`ARGS=--hold`, `ARGS=--monitor`, or `ARGS=--basic`. Ctrl-C during a load
leaves the core held.

### Running a program

A program is assembled with the assembler of the nice_cpu submodule. For
example, with `sim/echo.nasm`, which echoes what you type until a `.`:

    python3 nice_cpu/assembler/niceasm.py -o echo.bin sim/echo.nasm
    tools/nicemon.py load --eth 192.168.1.65 echo.bin
    nc -N 192.168.1.65 4510

Type a line, and the program echoes it. When you type `.`, it halts,
and the board sends its halt notice, which shows in the terminal as a
few letters after a stray character, such as `h01#C9`. What you type
goes to the program while it runs, and is dropped while the core is
held in reset or has halted. To end the line's input, send a break:
Ctrl-D in `nc -N`, or `Ctrl-A Ctrl-\` in picocom on the serial port,
after `tools/nicemon.py load --port /dev/ttyUSB1 echo.bin`.

### The .bin file

`nicemon.py load` takes the lines that `niceemu` takes:

- Each line has two fields of 1 to 8 hex digits, with no `0x`, sign, or
  underscore.
- No address is repeated, and there is at least one word.
- As in `niceemu`, only LF ends a line, only blanks and tabs part the
  fields, and a CR at the end of a line is ignored.
- A word where the board has no memory of its own is rejected. The RAM is
  the words `0` to `0x1FFFF` on the MEGA65 and `0` to `0xFFFF` on the
  Nexys4DDR, and the screen is the words `0xFFFF0000` to `0xFFFF1FFF`,
  the 8192 that both boards have. The file is checked against the
  MEGA65's RAM before the link opens, and against the board's, which
  `0xFFFFFF9E` reads, after the core is held; `niceemu` reads 0 there,
  and takes any address of the MEGA65's.

Any other address would land on a RAM word, or on a register of the I/O
page, where the emulator has a word of its own, so the program would run
differently. A program can still write the rest of the MEGA65's screen
when it runs.

### Running a program under the monitor

A program for the monitor of the ROM is assembled at `0x8000`, with
nice_cpu's `start_mon.nasm`, or built with `nicebuild.py --monitor`
([monitor/](../monitor/README.md#programs)). `--monitor` loads it so:

    tools/nicemon.py load --eth 192.168.1.65 --monitor prog.bin
    make load FILE=prog.bin ETH=192.168.1.65 ARGS=--monitor

`nicemon.py load` holds the core and clears the memory with the ROM visible,
writes the program, and starts the core. The monitor boots cold, which
leaves the RAM from `0x8000` alone, and `nicemon.py load` types `SYS 0x8000`
and CR, BASIC's statement that runs the program. The program then prints through the
monitor's `mon_putc`, on the screen and the line, and returns to the
monitor, which prints its status. A program with a word below `0x8000`
is refused, and so is one with a word at the variables or above,
BASIC's and the monitor's, `0x1E800` on the MEGA65 and `0xE800` on the
Nexys4DDR, and a
bitstream without a ROM. `--rom FILE` loads
FILE at 0 in place of the ROM, with the ROM hidden, such as
`build/rom.bin`, the monitor and BASIC: for `niceemu --link`, `make
cosim`, a bitstream without a ROM, or another build of the ROM.

`nicemon.py run --monitor` does the same, with `SYS 0x8000` and CR before the
input, and `--rom FILE` too, and prints what `niceemu` prints for the
monitor and the program joined. The monitor reads on at the end of the
input, so the input ends with BASIC's `HALT`, which halts the core, as
in the monitor's tests:

    printf 'HALT\r' > h.txt
    tools/nicemon.py run --tcp PORT --monitor --rom build/rom_test.bin \
        --input h.txt monitor/build/hello.bin
    printf 'SYS 0x8000\rHALT\r' > rh.txt
    cat build/rom_test.bin monitor/build/hello.bin > joined.bin
    niceemu -i rh.txt joined.bin

`make hwtest`, `make linktest`, and `make cosimtest` compare the two so
with `monitor/test/hello.nasm`, and `make hwtest` also runs it under the
monitor in the board's ROM, over the UART and Ethernet.

The end of a program's RAM is below the monitor's variables, 4K words,
and BASIC's RAM below them, as many words as the header of its image
says: that of the BASIC of `--rom FILE`, or else of the ROM's. A ROM
image that `nicemon.py load` or `nicemon.py run` loads at 0, such as `build/rom.bin`,
gets BASIC's flag "keep", so that its monitor runs that BASIC and does
not load a card's `BASIC*.ROM` in its place
([doc/BASIC_ROM.md](../doc/BASIC_ROM.md)).

A MEGA65 loads a card's `BASIC*.ROM` when it is switched on, which
takes a few seconds. A program that `--monitor` loads before that has
ended stays, and the core's own BASIC runs it. The card's BASIC is
then not loaded until the board is switched off and on again.

### Loading BASIC into the ROM

BASIC's part of the ROM, `0x3000`–`0x7FFF`, takes the link's writes.
`--basic` puts an image of BASIC there, such as `basic/build/basic.rom`
or a release's `BASIC-V2.4.ROM`, and starts the monitor with it:

    tools/nicemon.py load --eth 192.168.1.65 --basic BASIC-V2.4.ROM
    make load FILE=basic/build/basic.rom ETH=192.168.1.65 ARGS=--basic

`nicemon.py load` checks the image as `tools/basic_rom.py check` does, holds the
core, clears the memory, writes the image with "keep" set and zeros
after it up to `0x7FFF`, reads the part back, and starts the core with
the ROM shown. The ROM keeps that BASIC until the FPGA is configured
again, as when the board is switched off. A bitstream without a ROM, or
one older than V2.4, whose ROM takes no writes below `0x4000`, is
refused, and so is the Nexys4DDR's ROM, which takes no writes, as its
block RAMs are too few.

## nicemon.py run

`nicemon.py run` loads a program into cleared memory, as `load` does,
starts it, sends it its input, and copies its output to stdout. When the
program halts, it prints what `niceemu` prints: why and after how many
steps the program halted, and the registers.

    tools/nicemon.py run (link) [--input FILE] [--dump ADDR:N]... [--screen]
                         [--ide2004] [--symbols FILE] [--timeout SEC]
                         [--monitor [--rom FILE]] FILE

- `--input FILE` is the program's input, stdin by default (see
  [Input](#input)).
- `--dump ADDR:N`, `--screen`, `--ide2004`, and `--symbols FILE` print
  memory, the screen, and where the program halted, after the halt (see
  [Dumps and symbols](#dumps-and-symbols)).
- `--timeout SEC` gives up after SEC seconds, 60 by default (see
  [The time limit](#the-time-limit)).
- `--monitor` and `--rom FILE` run a program under the monitor, as for
  `load` (see
  [Running a program under the monitor](#running-a-program-under-the-monitor)).
- `--no-cycle-counter` is accepted and ignored, as the cycle counter
  always runs.

`make run FILE=prog.bin (ETH=IP | PORT=DEVICE)` runs it, with
`ARGS="--input in.txt --dump 0x100:16 --screen --timeout 5"`, for
example.

### Comparing with the emulator

`nicemon.py run` takes niceemu's `--input`, `--dump`, `--screen`, and
`--symbols` options by their long names, and niceemu's `-2004` as
`--ide2004`, so the output of the two can be compared:

    nice_cpu/emulator/zig-out/bin/niceemu --dump 0x110:2 --screen prog.bin > emu.txt
    tools/nicemon.py run --eth 192.168.1.65 --dump 0x110:2 --screen prog.bin > board.txt
    diff emu.txt board.txt

[EMULATOR.md](../doc/EMULATOR.md) has the table of the known differences
from the emulator.

### Exit status

The exit status is that of `niceemu`:

- 0 after `HALT`.
- 1 for a usage error or an unreadable file, before the core is touched.
- 2 after any other halt.
- 3 at the time limit (below).
- 130 after Ctrl-C, which holds the core.
- 141 when stdout closes early, as with `nicemon.py run ... | head`.

### Input

Its input is stdin, or the file of `--input`. On a terminal, Ctrl-D ends the
input. Before each part of at most 256 bytes, `nicemon.py run` reads the free
space of the core's input FIFO, and sends no more than that, so no byte
is lost, however far the program falls behind. At the end of the input,
`nicemon.py run` sends a break, so that a read returns `0x200`, as in the
emulator. It reads the output on while it waits for the input to go out
and holds the break, as the board sends with no flow control and the
kernel's buffer of the serial port fills in about 20 ms. Input that the program has not read when it halts is dropped,
as by the emulator. The link's halt notice comes after the program's last
byte, so the output ends there.

### Dumps and symbols

- `--dump ADDR:N` takes numbers as `niceemu` does, up to 32 bits, with no sign
  or underscore, but N is at most 131072 words.
- The words at `0xFFFFFFD0` to `0xFFFFFFFF` are read through their RAM
  alias, `0x0001FFD0` to `0x0001FFFF` on the MEGA65 and `0x0000FFD0` to
  `0x0000FFFF` on the Nexys4DDR, for the link has its debug registers
  there. The link reads the console and the read counter,
  `0xFFFFFF00` and `01`, as 0.
- The memory is 128K words on the MEGA65 and 64K on the Nexys4DDR,
  repeated through the address space, so `--dump` beyond them shows the same
  words again.
- `--symbols FILE` reads the labels that `niceasm.py --symbols` writes.
  After a halt other than `HALT`, it prints where the program was, `At
  label+0x1f`, if the file has any labels. After a halt at
  `___wasm_trap`, the default wasm trap handler, it prints the trap's
  code and location from R1 and R2, as `niceemu` does.
- `--ide2004` prints the screen from `0x400`, as `niceemu -2004` does. That
  is plain RAM on the board, not the screen that the display shows.

### The time limit

`niceemu` has no step limit unless `-n` gives one, and `nicemon.py run` gives up
after 60 seconds. `--timeout SEC` sets that (0 for no limit). At the
limit, `nicemon.py run` holds the core, prints "Stopped at the time limit after
SEC s" and the `--dump` and `--screen` output, and exits with status 3,
as `niceemu -n` does at its step limit. It prints no registers, no step
count, and no location for `--symbols`, as a hold leaves the registers
undefined ([DEBUG.md §6](https://github.com/MJoergen/nice_cpu/blob/main/doc/DEBUG.md#6-the-debug-registers)).

### Step counts

The step count is the core's instruction counter. The emulator's steps
include interrupt entries, and the instruction counter does not, so a
program with interrupts has more steps in the emulator. A read of the
console in the emulator waits for the next byte, but on the board it
returns 0 while no byte has arrived. So a program that waits for input in
a loop runs more steps on the board, and its step count differs.

## nicemon.py mon

`nicemon.py mon` is an interactive shell for remote control. It loads a program,
starts, holds, pauses, and steps the core, sets breakpoints, reads
and writes the registers and the memory, and disassembles, with one
short command each. It also passes text to and from the program. The
README has [a worked example](../README.md#using-the-interactive-shell).
It is nice_cpu's debugger, `nicedbg.py`, with the board's links and a
check of the board's memory. nice_cpu's
[debugger/README.md](https://github.com/MJoergen/nice_cpu/blob/main/debugger/README.md#the-commands)
describes the commands, the notices, and the labels.

    tools/nicemon.py mon (link) [--symbols FILE] [FILE]

- `--symbols FILE` reads the labels of a `.sym` file, which
  `niceasm.py --symbols` and `nicebuild.py --symbols` write, as the
  `symbols` command does.
- `FILE`, a `.bin` file, is optional. It is checked before the link
  opens, and loaded at the start, as the `load` command does, and the
  core is left held in reset. Without it, `nicemon.py mon` starts with
  `status`, and leaves the core as it is.

`make mon (ETH=IP | PORT=DEVICE)` runs it, and takes `FILE=` and
`ARGS=`, for example `make mon ARGS="--tcp 4000"`. On the serial port,
no other program may have the port open while it runs.

### On the board

The prompt is `dbg>`, nicedbg's. `help` lists the commands, and `help
CMD` describes one. Its messages say "the processor", which is the core
here. Leaving changes nothing on the board: a running program goes on.

- `load FILE`, and a `FILE` at the start, refuse a word that the
  board has no memory at, as `nicemon.py load` does: one beyond the MEGA65's
  RAM and the screen, or beyond the RAM that `0xFFFFFF9E` reads.
- The MEGA65 and the Nexys4DDR have 4 breakpoints.
- While the core runs, the link reaches only its debug registers at
  `FFFFFFD0`–`FF`. Pause or hold the core to read the rest. `regs`
  shows R0 to R15 live while it runs.
- Bytes sent while the core is held in reset or has halted are dropped,
  and bytes sent while it is paused wait for it.

### Running a C program

Build the C examples (see [PROGRAMMING.md](../doc/PROGRAMMING.md) for what
that needs):

    make examples

That builds `examples/build/primes.bin` from `examples/primes.c`, which
counts primes. Load it with `nicemon.py mon`, start it, and pass the terminal to
it with `console`, so that its first prompt is not lost:

    tools/nicemon.py mon --eth 192.168.1.65 examples/build/primes.bin
    dbg> go
    dbg> c

The program asks for a limit, reads it with `scanf`, and counts the primes
up to it. It asks again until you enter 0, and then halts. The program does
not echo what you type, so the number shows only after you press Enter:

    Count the primes up to (0 to stop): 1000
    Primes up to 1000: 168
    34333 instructions in 55761 cycles

The third line comes from the performance counters, and the numbers are
from the board with the pipelined core, where the 55761 cycles at 100 MHz
take about 0.56 ms.

## nicemon.py sd

`nicemon.py sd` reads and writes the board's SD card over the link, so a
file goes to the card and comes off it with no PC slot. It reads and
writes the card's FAT32 itself, as the monitor does, and only the
monitor's folder `NICE` (see
[SYSTEM.md](../doc/SYSTEM.md#the-sd-card-slots)), which it can make.

    tools/nicemon.py sd (link) [--slot N] [--hold] [--folder NAME] COMMAND

- `ls` lists the folder as BASIC's `DIR` does, with the long names
  after the rows.
- `get NAME [DEST]` copies a file to `DEST`, by default its name in the
  current directory, or with `-` to stdout. The name it writes is the
  long name when that is a plain file name, or else the 8.3 name, so a
  card's long name with a path in it writes nowhere else.
- `put SRC [NAME]` writes the host's file `SRC`, or stdin for `-`, as the
  file `NAME`, by default `SRC`'s own name. It makes the file, or
  truncates it when it is there, as BASIC's `SAVE` does.
- `del NAME` deletes a file, with its long name, if it has one.
- `mkdir` makes the folder in the root of a card that has FAT32 but not
  the folder, which the monitor never makes, or says that it is there
  already.
- `format [--label L] [--force] [--system] [--yes]` erases the whole
  card in the slot of `--slot` and writes a new FAT32 with the folder
  (see [Formatting a card](#formatting-a-card)).
- `--slot N` is the card's slot, `--hold` holds the core for `ls` and
  `get` (see [The core](#the-core)), and `--folder NAME` names another
  folder of the root than `NICE`.

`make sdcard CMD=COMMAND (ETH=IP | PORT=DEVICE)` runs it:

```
tools/nicemon.py sd --eth 192.168.1.65 ls
tools/nicemon.py sd --eth 192.168.1.65 get HELLO.BIN
tools/nicemon.py sd --eth 192.168.1.65 put prog.bas
make sdcard ETH=192.168.1.65 CMD="del PROG.BAS"
make sdcard ETH=192.168.1.65 CMD=mkdir
make sdcard ETH=192.168.1.65 CMD="--slot 0 format"
```

`ls` and `get NAME -` print to stdout, and the others report on stderr.

### The files

`get` and `del` take the 8.3 name or the long name, in either case.
`put` writes only 8.3 names, as the monitor does: a host file such as
`my program.bas` needs a `NAME`, such as `PROG.BAS`. The folder of
`mkdir` must be an 8.3 name with no extension, as `NICE` is.

A card with no FAT32 file system, or with FAT16 or exFAT, must be
formatted as FAT32 first, with `format` or on a PC; the tool says so. A
card with FAT32 but no folder gets the hint of `mkdir`.

The writes keep to the order of the monitor's FAT32 code, so that a
reset at any point leaves the card no worse than with lost clusters,
which `fsck.fat` frees. `mkdir` writes the folder's cluster before the
root's entry of it. A new entry has the host's date and time. When
the card fills up, the file keeps what fitted, and `put` says error 30.

### Formatting a card

`format` needs `--slot`, so that no card is erased by chance. It shows
the card's size, its partitions, and their labels, and asks you to type
the slot's number; `--yes` skips that. It refuses:

- a write-protected card;
- a card that is not blank, unless `--force` is given. A blank card has
  only zeros, or only ones, in its first sector;
- a card with the MEGA65's system partition, of type `0x41`, unless
  `--system` is given too. That is the card in slot 1 of a MEGA65, which
  the MEGA65's own SD card utility formats with its system files;
- a card too small for FAT32, under about 37 MB.

It writes the card as cards are sold: one partition of type `0x0C`
from sector 8192 to the end, two FATs, Microsoft's cluster size for the
card's size, the folder `NICE`, and the label `NICE`, or that of
`--label`. A card of most sizes needs about 30000 sectors written,
which takes minutes over Ethernet and much longer over the serial port.
A format that breaks off leaves a card with no FAT32, as the old MBR is
cleared first and the new one written last.

### The core

The core can be in any state. `put`, `del`, `mkdir`, and `format` hold a running
or paused core, and start it again from reset after the write, as the
monitor keeps a sector of the FAT and its mount between commands, which
the write makes stale. So a program at `0x8000` under the monitor is gone
afterwards, and the monitor shows `READY.` again. A held core stays
held. For `ls` and `get`, a running core is paused for the reads,
and goes on after them. While it is paused, the tool uses the program's
card as it is: its slot, which BASIC's `DIR` or `LOAD` must have
started up, and it puts back `SD_LBA`, `SD_CHUNK`, and the buffer at the
end. `--slot` of another slot is refused then. While the core is held or
has halted, the tool takes the slot of `--slot`, or slot 0, or slot 1
when slot 0 has no card, as the monitor does, and starts the card up.

`--hold` makes `ls` and `get` hold a running or paused core too, and
start it again from reset afterwards, as `put` and `del` do, so that
they read any slot, whatever the program had. Without it, they need the
program's own card: after a write, the monitor starts again with slot 0
selected, so with the card in slot 1 an `ls` while it runs needs a
`DIR 1` on the board first, or `--hold`:

```
tools/nicemon.py sd --eth 192.168.1.65 --slot 1 put prog.bas
tools/nicemon.py sd --eth 192.168.1.65 --slot 1 --hold get PROG.BAS
```

### The speed

A sector takes 16 writes and 16 reads on the link, each a request that
waits for its answer. On an R6, a file comes at about 115 KB a second
over Ethernet, and goes at about 80 KB a second, and on the serial port
at about 0.9 KB and 0.65 KB a second, 0.58 s a sector to read, as each
request waits for the 16 ms latency timer of the FTDI chip. Linux sets the timer in
`/sys/bus/usb-serial/devices/ttyUSB1/latency_timer`, for the board's
port; the timer, not the baud rate, sets the speed there.
`make sdtest` checks the tool on `niceemu --link`, without a board.

## nicemon.py nbd

`nicemon.py nbd` makes the board's SD card a disk of a Linux PC, so that the
card is a folder there, and files go to it and come off it with the
file manager. It is a server of NBD, Linux's network block device, on
port 10809 of `127.0.0.1`. Its disk is the card: each read and write is
a read or write of the card's sectors over the link. `nbd-client`
connects `/dev/nbd0` to it, and the kernel mounts the card's FAT32 as
any other, all of it, not only `NICE`, with every folder, long names,
and renames. It needs the `nbd` module and `nbd-client` (package
`nbd-client` on Debian and Ubuntu), and root for them and the mount.

    tools/nicemon.py nbd (link) [--slot N] [--read-only] [--hold] [--listen [HOST:]PORT]

- `--slot N` picks the slot, as for `nicemon.py sd`.
- `--read-only` refuses writes, and pauses the core instead of holding
  it, and `--hold` holds it all the same (see [The core and the kernel](#the-core-and-the-kernel)).
- `--listen [HOST:]PORT` moves the server, `127.0.0.1:10809` by
  default; port 0 picks a free one.

`make sdnbd (ETH=IP | PORT=DEVICE)` runs it:

```
tools/nicemon.py nbd --eth 192.168.1.65 &
sudo modprobe nbd
sudo nbd-client -N sd localhost /dev/nbd0
sudo mount -o uid=$(id -u),gid=$(id -g) /dev/nbd0p1 /mnt
cp prog.bas /mnt/NICE/
sudo umount /mnt
sudo nbd-client -d /dev/nbd0
kill %1
```

`/dev/nbd0p1` is the first partition of a card with an MBR, as the
MEGA65's cards have; a card that is FAT32 from sector 0 mounts as
`/dev/nbd0`. A desktop usually mounts the partition itself once
`nbd-client` has connected it.

### The core and the kernel

The core is held from the start until the server ends, with Ctrl-C,
which exits with status 130, or SIGTERM, which exits with 0, and
then starts again from reset, as after `nicemon.py sd put`. The kernel
keeps the card's FAT and folders in its cache, so a program on the board
that used the card at the same time would see it stale, and the board
would see the kernel's. A held core stays held.

Unmount before the server stops: `umount` writes what the kernel kept.
The kernel writes in its own order, not in the careful order of
`nicemon.py sd` and the monitor, so a link that breaks during a write can
leave the FAT damaged, which `fsck.fat` repairs.

With `--read-only`, the server refuses writes, and the core is paused
instead of held, and goes on at the end, as for `nicemon.py sd ls`. The
card is then the paused program's, in its slot, which it must have
started up; `--hold` holds the core all the same, to reach any slot.
Mount it with `-o ro`.

### The speed of a mount

The speed is that of `nicemon.py sd`: about 115 KB a second reading and
80 KB a second writing over Ethernet on an R6, and a hundred times less
on the serial port. `make sdtest` checks the server with a client of
its own on `niceemu --link`.

On the serial port, a mount can take many minutes. The kernel reads
ahead 128 KB, 256 sectors, for a small read, and the desktop's udev
reads the card when `nbd-client` connects it. Two settings make it
faster, and both must come before the mount, as reads that are already
waiting keep their size and their speed. Here the board's port is
`ttyUSB1`:

```
echo 1 | sudo tee /sys/bus/usb-serial/devices/ttyUSB1/latency_timer
tools/nicemon.py nbd --port /dev/ttyUSB1 &
sudo modprobe nbd
sudo nbd-client -N sd localhost /dev/nbd0
echo 4 | sudo tee /sys/block/nbd0/queue/read_ahead_kb
sudo mount -o uid=$(id -u),gid=$(id -g) /dev/nbd0p1 /mnt
```

The first line sets the FTDI chip's latency timer to 1 ms, as for
`nicemon.py sd`, and goes before the server. The fifth makes the
read-ahead 4 KB, on the disk that `nbd-client` connected.

## nicemon.py flash

`nicemon.py flash` writes the flash that a board starts from, over the
JTAG cable on the USB device of `--port`, with openFPGALoader, and
checks the FPGA first, as `hwtest.py` does. It runs on Linux only, and
the MEGA65 needs pyftdi.

    tools/nicemon.py flash --port DEVICE [--baud N] [--bit FILE | --erase]
    tools/nicemon.py flash --port DEVICE [--baud N] --cor FILE --flash-slot N
                           [--no-board-check]

- `--port DEVICE` is the board's serial port, whose USB device has the
  JTAG cable too, and `--baud N` the UART's rate, 230400 by default.
- On the Nexys4DDR, `--bit FILE` is the bitstream to write,
  `synth/nexys4ddr/build/top.bit` by default, and `--erase` erases the
  flash instead. It refuses a MEGA65's bitstream, verifies the flash,
  and waits for the board to start from it.
- On the MEGA65, `--cor FILE --flash-slot N` writes a core file into slot N of
  the flash, 1 to 7, or 1 to 3 in an R3's flash of 32 MiB, with no
  MEGAFLASH: it checks that the flash chip and slot 0's core are
  those of the file's board revision (`--no-board-check` skips the
  chip), shows what the slot held, clears the
  protection of the slot's sectors, writes, verifies, and loads the slot
  into the FPGA.

`make flash PORT=/dev/ttyUSB1 [BIT=FILE]` is the Nexys4DDR's form, with
`ARGS=--erase` to erase, and `make flash PORT=/dev/ttyUSB1 COR=FILE
SLOT=N` the MEGA65's ([synth/README.md](../synth/README.md#building)).

`jtag.py` has what both share: it finds the JTAG cable of `--port`,
checks the FPGA's part, and on a MEGA65 the flash chip.

## nicemon.py tftpd

`nicemon.py tftpd` serves the files of a folder to BASIC's `LOAD` and
`DIR` over TFTP, with a listing for a name with `*` or `?`, and with
`--write` takes the files of its `SAVE` and `BSAVE`. It uses no link,
and so takes none of its options.

    tools/nicemon.py tftpd [--dir DIR] [--listen [ADDR:]PORT] [--retry-wait SEC] [--tries N] [--write]

- `--dir DIR` is the folder served, the current one by default.
- `--listen [ADDR:]PORT` is where it listens, `0.0.0.0:69` by default,
  all of the host's addresses. Port 69 needs root on Linux, or the
  capability that the header of `tftpd.py` names; another port, such as
  `--listen 6969`, needs none, and BASIC reaches it with
  `LOAD "NAME.BIN", "IP:6969"`. Port 0 picks a free one, printed on
  stderr.
- `--retry-wait SEC` is the wait for an ACK before a block is sent
  again, 1 by default, and `--tries N` the sends of a block in all, 5
  by default. A write waits as long for each DATA, and sends its ACK
  again meanwhile.
- `--write` takes write requests, which it refuses with ERROR 2
  without it. A file goes into the folder under the name of the
  request, or under that of the one file that has the name in another
  case, and replaces a file that is there, as `SAVE` to the card does.
  A name with `*` or `?`, or that of a directory or a symbolic link, is
  refused. The blocks go to a temporary file, whose name starts with a
  dot, which is renamed at the end, so that a transfer that fails, such
  as one that BASIC's CTRL-C stops, leaves no half file. TFTP has no
  login: anyone who reaches the port may write to the folder.

`make tftpd [TFTP_DIR=DIR] [TFTP_PORT=PORT] [ARGS=--write]` serves `examples/build`
([monitor/README.md](../monitor/README.md#the-network)). It reports each
transfer on stderr, and Ctrl-C stops it.

## hwtest.py

`tools/hwtest.py` programs the FPGA and tests the system on the board,
which [CONTRIBUTING.md](../CONTRIBUTING.md#testing-the-board) describes
check by check. It is a program of its own, not a subcommand. It needs
the board's debug UART, `--port`, and finds the JTAG cable on the same
USB device:

    tools/hwtest.py --port /dev/ttyUSB1 [--baud 230400] [--bit FILE]
                    [--board mega65|nexys4ddr] [--no-program]
                    [--no-board-check] [--eth HOST[:PORT]]

- `--bit FILE` is the bitstream to program, `synth/r6/build/top.bit` by
  default. The FPGA's IDCODE must be the part the bitstream was built
  for, and tells which board is tested. `--board` names the board
  instead; without either, a path with `nexys4ddr` in it means the
  Nexys4DDR.
- On a MEGA65, the flash chip must be that of the bitstream's board, an
  S25FL256S on the R3 and an S25FL512S on the R6, as the R3 and R6 have
  the same FPGA. The bitstream names its board by its UserID, or else by
  its path. `--no-board-check` skips that check.
- `--no-program` skips the programming and the boot test, for a board
  that is already programmed. Programming needs Linux; with
  `--no-program` the script runs wherever `nicemon.py load` does.
- `--eth HOST` tests the Ethernet station too, after every other check:
  it gives the board the IP address HOST through BASIC's `IP`,
  pings it, and runs the programs over TCP. Without `--eth`, or when no
  frame reaches the station, the summary names the station after NOT
  COVERED, and the run still passes.
- It prints a line for each check, `[PASS]` or `[FAIL]`, and last how
  many passed, with SKIPPED for the checks that need niceemu when it is
  missing.

`make hwtest PORT=/dev/ttyUSB1 [BIT=FILE] [ETH=IP]` builds the examples
and niceemu first, and runs it.

## The other tools

- `tools/bump.py TAG [--push]` moves nice_cpu to the tag, builds the R6
  and the Nexys4DDR, and commits `badge-mega65.json`,
  `badge-nexys4ddr.json`, and `verified.json`, pushed with `--push`.
  `--reports DIR [--nexys-reports DIR]` builds and commits nothing, and
  prints what the timing reports in DIR would give. `make bump TAG=V1.0
  [ARGS=--push]` runs it
  ([CONTRIBUTING.md](../CONTRIBUTING.md#the-timing-badges)).
- `tools/release.py TAG --port DEVICE [--eth IP]` builds, tests, and
  stages a release, and `tools/release.py TAG --publish` tags and
  publishes it. `make release TAG=V1.0 PORT=DEVICE` passes the port, and
  `ARGS="--eth IP"` or `ARGS=--publish` the rest
  ([RELEASE.md](../doc/RELEASE.md)).
- `tools/linktest.py`, `tools/sdtest.py`, `tools/tftptest.py`,
  `tools/tcptest.py`, `tools/weathertest.py`, and `tools/cosimtest.py`
  take no options. They need niceemu, and `make linktest`,
  `make sdtest`, `make tftptest`, `make tcptest`, `make weathertest`,
  and `make cosimtest`, which runs on `make cosim`, build it first
  ([CONTRIBUTING.md](../CONTRIBUTING.md#the-tools-and-niceemu)).
- `tools/romsize.py` is run by `make romsize`, which writes the tables
  of the ROM's words anew, and by the tests of the monitor and the
  demo, which check them
  ([monitor/INTERNALS.md](../monitor/INTERNALS.md#the-roms-words)).
- `tools/screenshot.py [-i FILE] [-n N] [--debugger] [-o FILE] prog.bin`
  runs the program in niceemu, with the console input of `-i` and at
  most `-n` steps, as niceemu's options, and draws the screen as the
  display shows it into `-o`, `screen.png` by default, with the on-board
  debugger's strip under it with `--debugger`. The README's pictures are
  drawn with it, as its docstring says.
