# The host tools

The tools run on the host, and talk to the board over its Ethernet port
or its debug UART, with the debug link of
[DEBUG.md](https://github.com/MJoergen/nice_cpu/blob/main/doc/DEBUG.md).
They use only the Python standard library, and run on Linux and macOS, but
`flash.py` needs Linux, and pyftdi for the MEGA65. Each one
prints its options with `--help`, and its header says more.

| Tool | What it does |
|---|---|
| `boardlink.py` | The debug link, which the other tools use: nice_cpu's `debugger/nicelink.py`, over TCP to `niceemu --link` and on the UART, with the board's own links over TCP to its Ethernet port and to `make cosim`. |
| `load.py` | Loads a `.bin` file into cleared memory and starts it, or with `--no-run` leaves the core held in reset. With `--monitor`, it runs a program at `0x8000` under the monitor in the ROM. |
| `run.py` | Runs a program on the board and prints what `niceemu` prints, for diffing, also one under the monitor with `--monitor`. |
| `mon.py` | An interactive shell on the link: memory, registers, pause, step, breakpoints, and the console. It is nice_cpu's `debugger/nicedbg.py` with the board's links. |
| `sdcard.py` | Lists, copies, writes, and deletes the files of the folder `NICE` on the board's SD card, with no PC slot. |
| `hwtest.py` | Programs the FPGA with openFPGALoader and tests the system on the board. |
| `flash.py` | Writes a bitstream into the Nexys4DDR's flash, or a core file into a slot of the MEGA65's, from which the board starts. |
| `linktest.py` | Checks `run.py` and the link on `niceemu --link` against plain `niceemu`, without a board. |
| `tftpd.py` | A TFTP server for the monitor's `tftp`, which also lists the files of its folder for a name with `*` or `?`. |
| `sdtest.py` | Checks `sdcard.py` on `niceemu --link` with images of a card, without a board. |
| `tftptest.py` | Checks `tftpd.py`, and the monitor's `tftp` in `niceemu` against it, without a board. |
| `cosimtest.py` | Checks `run.py` and the RTL on `make cosim` against plain `niceemu`, without a board. |
| `screenshot.py` | Runs a program in `niceemu` and draws its screen as a PNG picture, as the text display shows it, and with `--debugger` the on-board debugger's strip under it. |
| `bump.py` | Moves nice_cpu to a tag, builds the R6 and Nexys4DDR bitstreams, and writes the badge files and `verified.json`. |
| `release.py` | Builds, tests, and publishes a release (see [RELEASE.md](../doc/RELEASE.md)). |

## The line

The board's line carries the program's console both ways, and the
packets of the debug link between its bytes (see
[SYSTEM.md](../doc/SYSTEM.md#the-debug-link)). The line is a TCP
connection to the board's Ethernet port, or its debug UART, which needs
a JTAG cable. The tools use the link, and `niceemu --link` serves the
same link, so the tools drive the emulator as they drive the board.
When they connect, the tools read the link's version, and stop on a
major other than 0, which they do not know (DEBUG.md §9).

`load.py`, `run.py`, and `mon.py` take the line as an option:
`--eth 192.168.1.65` for the Ethernet port (see
[Over Ethernet](#over-ethernet)), `--port` for the serial port (see
[The serial port](#the-serial-port)), such as `--port /dev/ttyUSB1`, or
`--tcp` and `--cosim` for `niceemu --link` and `make cosim`, with no
board (see [Without a board](#without-a-board) and [mon.py](#monpy)).
One of them must be given. `flash.py` and `hwtest.py` take `--port`
alone, and `hwtest.py`'s `--eth` tests the Ethernet port beside it.

`make` has a target for each tool:

- `make load FILE=prog.bin` loads a program into the board and starts it.
- `make run FILE=prog.bin` runs one as `niceemu` runs it (see
  [Comparing with the emulator](#comparing-with-the-emulator)).
- `make mon` opens an interactive shell on the link (see
  [mon.py](#monpy)).

They take `ETH=192.168.1.65` for the Ethernet port, or
`PORT=/dev/ttyUSB1` for the serial port, and one of the two. They pass
`ARGS=` on to the tool: `ARGS=--no-run` for `make load`, or
`ARGS="-i in.txt -d 0x100:16 -s --timeout 5"` for `make run`.
`ARGS="--tcp 4000"` drives `niceemu --link 4000` instead of the board.

The other tools have targets too: `make hwtest` and `make flash` (see
[hwtest.py](#hwtestpy) and [flash.py](#flashpy)), `make linktest`,
`make cosim` and `make cosimtest`, `make bump`, and `make release` (see
[The other tools](#the-other-tools)).

## Over Ethernet

The board serves the debug link on TCP port 4510 of its Ethernet
station, once it has an IP address
([SYSTEM.md](../doc/SYSTEM.md#the-debug-link-over-tcp)). After reset it
has none. The monitor's `i` gives it one, `i 192.168.1.65` at the
prompt, and the demo's F11 does too: I types a new IP address. Then
use `--eth` with any tool:

    tools/run.py --eth 192.168.1.65 prog.bin

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
host, or after a reset of the board. The link has no password, so give
the board an IP address only on a network you trust.

## The serial port

The MEGA65's debug UART runs at 230400 baud, 8-N-1, after reset, the
tools' `--baud` by default, or at the rate written to `0xFFFFFF9F`
([doc/SYSTEM.md](../doc/SYSTEM.md#the-baud-rate)), which `--baud` must
match. A core built before `V1.9` runs at 2 Mbaud after reset, and needs
`--baud 2000000`. It needs the JTAG cable, whose USB port carries it. It is usually the serial device
`/dev/ttyUSB1`. Give it to the tools with `--port`, or to `make` with
`PORT=`, and open it in your terminal program. On
macOS, use the `/dev/cu.*` device, as a `/dev/tty.*` device blocks on
open. The port must not be open in a terminal while a tool runs.

A terminal program, such as `picocom`, shows the program's console:
`picocom -b 230400 /dev/ttyUSB1`. In picocom,
`Ctrl-A Ctrl-\` sends a break, which ends the line's input; the
keyboard's goes on.

The debug link on the serial port gives it one too, with no key typed:

    tools/mon.py --port /dev/ttyUSB1
    dbg> w FFFFFFB0 C0A80141
    dbg> q

## Running a program

A program is assembled with the assembler of the nice_cpu submodule, and
loaded with `tools/load.py`, which holds the core, hides the ROM if there
is one, clears the memory, writes the words with `W` packets, and then
starts the core. For example, with `sim/echo.nasm`, which echoes what you
type until a `.`:

    python3 nice_cpu/assembler/niceasm.py -o echo.bin sim/echo.nasm
    tools/load.py --eth 192.168.1.65 echo.bin
    nc -N 192.168.1.65 4510

Type a line, and the program echoes it. When you type `.`, it halts,
and the board sends its halt notice, which shows in the terminal as a
few letters after a stray character, such as `h01#C9`. What you type
goes to the program while it runs, and is dropped while the core is
held in reset or has halted. To end the line's input, send a break:
Ctrl-D in `nc -N`, or `Ctrl-A Ctrl-\` in picocom on the serial port,
after `tools/load.py --port /dev/ttyUSB1 echo.bin`.

The `.bin` file has one line per word, the address and the word in hex.
`load.py --no-run` loads the program and leaves the core held in reset.
`load.py --tcp PORT` loads it into `niceemu --link PORT` instead of the
board.

`load.py` takes the lines that `niceemu` takes:

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

`load.py` holds the core first, so it also works while a program runs.

## Running a program under the monitor

A program for the monitor of the ROM is assembled at `0x8000`, with
nice_cpu's `start_mon.nasm`, or built with `nicebuild.py --monitor`
([monitor/](../monitor/README.md#programs)). `--monitor` loads it so:

    tools/load.py --eth 192.168.1.65 --monitor prog.bin

`load.py` holds the core and clears the memory with the ROM visible,
writes the program, and starts the core. The monitor boots cold, which
leaves the RAM from `0x8000` alone, and `load.py` types `r` and CR, its
command that runs the program. The program then prints through the
monitor's `mon_putc`, on the screen and the line, and returns to the
monitor, which prints its status. A program with a word below `0x8000`
is refused, and so is one with a word at the monitor's variables or
above, `0x1F000` on the MEGA65 and `0xF000` on the Nexys4DDR, and a
bitstream without a ROM. `--rom FILE` loads
FILE at 0 in place of the ROM, with the ROM hidden, such as
`monitor/build/monitor.bin`: for `niceemu --link`, `make cosim`, a
bitstream without a ROM, or another build of the monitor.

`run.py --monitor` does the same, with `r` and CR before the input, and
`--rom FILE` too, and prints what `niceemu` prints for the monitor and
the program joined.
The monitor reads on at the end of the input, so the input ends with
its `h`, which halts the core (monitor/README.md, "Loading from a
host").

## Running a C program

Build the C examples (see [PROGRAMMING.md](../doc/PROGRAMMING.md) for what
that needs):

    make examples

That builds `examples/build/primes.bin` from `examples/primes.c`, which
counts primes. Load it with `mon.py`, start it, and pass the terminal to
it with `console`, so that its first prompt is not lost:

    tools/mon.py --eth 192.168.1.65 examples/build/primes.bin
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

## Comparing with the emulator

`tools/run.py` loads a program into cleared memory, starts it, sends it
its input, and copies its output to stdout. When the program halts, it
prints what `niceemu` prints: why and after how many steps the program
halted, and the registers. It takes niceemu's `-i`, `-d`, `-s`, and
`--symbols` options, the long forms `--input`, `--dump`, and `--screen`
among them, so the output of the two can be compared:

    nice_cpu/emulator/zig-out/bin/niceemu -d 0x110:2 -s prog.bin > emu.txt
    tools/run.py --eth 192.168.1.65 -d 0x110:2 -s prog.bin > board.txt
    diff emu.txt board.txt

The exit status is that of `niceemu`:

- 0 after `HALT`.
- 1 for a usage error or an unreadable file, before the core is touched.
- 2 after any other halt.
- 3 at the time limit (below).
- 130 after Ctrl-C, which holds the core.
- 141 when stdout closes early, as with `run.py ... | head`.

### Input

Its input is stdin, or the file of `-i`. On a terminal, Ctrl-D ends the
input. Before each part of at most 256 bytes, `run.py` reads the free
space of the core's input FIFO, and sends no more than that, so no byte
is lost, however far the program falls behind. At the end of the input,
`run.py` sends a break, so that a read returns `0x200`, as in the
emulator. It reads the output on while it waits for the input to go out
and holds the break, as the board sends with no flow control and the
kernel's buffer of the serial port fills in about 20 ms. Input that the program has not read when it halts is dropped,
as by the emulator. The link's halt notice comes after the program's last
byte, so the output ends there.

### Dumps and symbols

- `-d ADDR:N` takes numbers as `niceemu` does, up to 32 bits, with no sign
  or underscore, but N is at most 131072 words.
- The words at `0xFFFFFFE0` to `0xFFFFFFFF` are read through their RAM
  alias, `0x0001FFE0` to `0x0001FFFF` on the MEGA65 and `0x0000FFE0` to
  `0x0000FFFF` on the Nexys4DDR, for the link has its debug registers
  there. The link reads the console and the read counter,
  `0xFFFFFF00` and `01`, as 0.
- The memory is 128K words on the MEGA65 and 64K on the Nexys4DDR,
  repeated through the address space, so `-d` beyond them shows the same
  words again.
- `--symbols FILE` reads the labels that `niceasm.py --symbols` writes.
  After a halt other than `HALT`, it prints where the program was, `At
  label+0x1f`, if the file has any labels. After a halt at
  `___wasm_trap`, the default wasm trap handler, it prints the trap's
  code and location from R1 and R2, as `niceemu` does.
- `-2004` prints the screen from `0x400`, as `niceemu -2004` does. That
  is plain RAM on the board, not the screen that the display shows.
- `--no-cycle-counter` is accepted and ignored, as the cycle counter
  always runs.

### The time limit

`niceemu` has no step limit unless `-n` gives one, and `run.py` gives up
after 60 seconds. `--timeout SEC` sets that (0 for no limit). At the
limit, `run.py` holds the core, prints "Stopped at the time limit after
SEC s" and the `--dump` and `--screen` output, and exits with status 3,
as `niceemu -n` does at its step limit. It prints no registers, no step
count, and no location for `--symbols`, as a hold leaves the registers
undefined (DEBUG.md §6).

### Without a board

`--tcp PORT` runs the program on `niceemu --link PORT` instead of the
board, which checks `run.py` and the link against the plain emulator:

    nice_cpu/emulator/zig-out/bin/niceemu --link 4000 &
    tools/run.py --tcp 4000 prog.bin

`--tcp HOST:PORT` reaches a `niceemu` on another computer, which serves
the link on an address other than 127.0.0.1. An IPv6 HOST goes in
brackets, as for `niceemu --link`:

    niceemu --link 0.0.0.0:4510 prog.bin       # on emuhost
    tools/mon.py --tcp emuhost:4510            # on your own computer

The link has no authentication: anyone who reaches the port can read
and write the emulator's memory. Serve it beyond 127.0.0.1 only on a
trusted network. Elsewhere, forward the port over SSH instead:

    ssh -L 4510:127.0.0.1:4510 emuhost 'niceemu --link 4510 prog.bin'
    tools/mon.py --tcp 4510

With `--tcp`, the end of the input half-closes the connection, and `-d`
cannot reach `0xFFFFFFE0`–`FF`, which are the emulator's memory.

### Step counts

The step count is the core's instruction counter. The emulator's steps
include interrupt entries, and the instruction counter does not, so a
program with interrupts has more steps in the emulator. A read of the
console in the emulator waits for the next byte, but on the board it
returns 0 while no byte has arrived. So a program that waits for input in
a loop runs more steps on the board, and its step count differs.
[EMULATOR.md](../doc/EMULATOR.md) has the table of the known differences from the
emulator.

## mon.py

`mon.py` is an interactive shell on the debug link. It loads a program,
starts, holds, pauses, and steps the core, sets breakpoints, reads
and writes the registers and the memory, and disassembles, with one
short command each. It also passes text to and from the program. The
README has [a worked example](../README.md#using-the-interactive-shell).

It is nice_cpu's debugger, `nicedbg.py`, with the board's links and a
check of the board's memory. nice_cpu's
[debugger/README.md](https://github.com/MJoergen/nice_cpu/blob/main/debugger/README.md#the-commands)
describes the commands, the notices, and the labels.

### Starting it

    tools/mon.py (--eth HOST[:PORT] | --port DEVICE [--baud 230400]
                 | --tcp [HOST:]PORT | --cosim PORT) [--symbols FILE] [FILE.bin]

- `--eth HOST` talks to the board over its Ethernet port, at its IP
  address HOST (see [Over Ethernet](#over-ethernet)).
- `--port DEVICE` names the serial device of the board's debug UART,
  such as `/dev/ttyUSB1`, and `--baud` its rate, 230400 by default.
- `--tcp PORT` talks to `niceemu --link PORT` instead of the board, and
  `--tcp HOST:PORT` to one on another computer (see [Without a
  board](#without-a-board)).
- `--cosim PORT` talks to the simulated system of `make cosim`, at
  about 250 UART bytes a second.
- `--symbols FILE` reads the labels of a `.sym` file, which
  `niceasm.py --symbols` and `nicebuild.py --symbols` write, as the
  `symbols` command does.
- `FILE.bin` is optional. It is checked before the link opens, and
  loaded at the start, as the `load` command does, and the core is left
  held in reset. Without it, `mon.py` starts with `status`, and leaves
  the core as it is.

`make mon ETH=192.168.1.65` runs it over the Ethernet port, and
`make mon PORT=/dev/ttyUSB1` on the serial port. One of the four
options above must be given. It takes `FILE=` and `ARGS=`, for
example `make mon ARGS="--tcp 4000"`. On the serial port, no other
program may have the port open while it runs.

### On the board

The prompt is `dbg>`, nicedbg's. `help` lists the commands, and `help
CMD` describes one. Its messages say "the processor", which is the core
here. Leaving changes nothing on the board: a running program goes on.

- `load FILE`, and a `FILE.bin` at the start, refuse a word that the
  board has no memory at, as `load.py` does: one beyond the MEGA65's
  RAM and the screen, or beyond the RAM that `0xFFFFFF9E` reads.
- The MEGA65 and the Nexys4DDR have 4 breakpoints.
- While the core runs, the link reaches only its debug registers at
  `FFFFFFE0`–`FF`. Pause or hold the core to read the rest. `regs`
  shows R0 to R15 live while it runs.
- Bytes sent while the core is held in reset or has halted are dropped,
  and bytes sent while it is paused wait for it.

## hwtest.py

`tools/hwtest.py` programs the FPGA and tests the system on the board,
which [CONTRIBUTING.md](../CONTRIBUTING.md#testing-the-board) describes
check by check. It needs the board's debug UART, `--port`, and finds the
JTAG cable on the same USB device:

    tools/hwtest.py --port /dev/ttyUSB1 [--baud 230400] [--bit FILE]
                    [--board mega65|nexys4ddr] [--no-program]
                    [--eth HOST[:PORT]]

- `--bit FILE` is the bitstream to program, `synth/r6/build/top.bit` by
  default. The FPGA's IDCODE must be the part the bitstream was built
  for, and tells which board is tested. `--board` names the board
  instead; without either, a path with `nexys4ddr` in it means the
  Nexys4DDR.
- `--no-program` skips the programming and the boot test, for a board
  that is already programmed. Programming needs Linux; with
  `--no-program` the script runs wherever `load.py` does.
- `--eth HOST` tests the Ethernet station too, after every other check:
  it gives the board the IP address HOST through the monitor's `i`,
  pings it, and runs the programs over TCP. Without `--eth`, or when no
  frame reaches the station, the summary names the station after NOT
  COVERED, and the run still passes.
- It prints a line for each check, and last how many passed, with
  SKIPPED for the checks that need niceemu when it is missing.

`make hwtest PORT=/dev/ttyUSB1 [BIT=FILE] [ETH=IP]` builds the examples
and niceemu first, and runs it.

## flash.py

`tools/flash.py` writes the flash that a board starts from, over the
JTAG cable on the USB device of `--port`, with openFPGALoader, and
checks the FPGA first, as `hwtest.py` does. It runs on Linux only, and
the MEGA65 needs pyftdi.

    tools/flash.py --port /dev/ttyUSB1 [--bit FILE | --erase]
    tools/flash.py --port /dev/ttyUSB1 --cor FILE --slot N

- On the Nexys4DDR, `--bit FILE` is the bitstream to write,
  `synth/nexys4ddr/build/top.bit` by default, and `--erase` erases the
  flash instead. It refuses a MEGA65's bitstream, verifies the flash,
  and waits for the board to start from it.
- On the MEGA65, `--cor FILE --slot N` writes a core file into slot N of
  the flash, 1 to 7, with no MEGAFLASH: it checks that slot 0's core is
  for the file's board revision, shows what the slot held, clears the
  protection of the slot's sectors, writes, verifies, and loads the slot
  into the FPGA.

`make flash PORT=/dev/ttyUSB1 [BIT=FILE]` is the Nexys4DDR's form, with
`ARGS=--erase` to erase, and `make flash PORT=/dev/ttyUSB1 COR=FILE
SLOT=N` the MEGA65's ([synth/README.md](../synth/README.md#building)).

## sdcard.py

`sdcard.py` reads and writes the board's SD card over the link, so a
file goes to the card and comes off it with no PC slot. It reads and
writes the card's FAT32 itself, as the monitor does, and only the
monitor's folder `NICE` (see
[SYSTEM.md](../doc/SYSTEM.md#the-sd-card-slots)):

- `ls` lists the folder as the monitor's `dir` does, with the long names
  after the rows.
- `get NAME [DEST]` copies a file to `DEST`, by default its name in the
  current directory, or with `-` to stdout. The name it writes is the
  long name when that is a plain file name, or else the 8.3 name, so a
  card's long name with a path in it writes nowhere else.
- `put SRC [NAME]` writes the host's file `SRC`, or stdin for `-`, as the
  file `NAME`, by default `SRC`'s own name. It makes the file, or
  truncates it when it is there, as the monitor's `save` does.
- `del NAME` deletes a file, with its long name, if it has one.

```
tools/sdcard.py --eth 192.168.1.65 ls
tools/sdcard.py --eth 192.168.1.65 get HELLO.BIN
tools/sdcard.py --eth 192.168.1.65 put prog.bas
make sdcard ETH=192.168.1.65 CMD="del PROG.BAS"
```

`get` and `del` take the 8.3 name or the long name, in either case.
`put` writes only 8.3 names, as the monitor does: a host file such as
`my program.bas` needs a `NAME`, such as `PROG.BAS`. `--folder` names
another folder of the root, and `--slot` the slot.

The writes keep to the order of the monitor's FAT32 code, so that a
reset at any point leaves the card no worse than with lost clusters,
which `fsck.fat` frees. A new entry has the host's date and time. When
the card fills up, the file keeps what fitted, and `put` says error 30.

The core can be in any state. `put` and `del` hold a running or paused
core, and start it again from reset after the write, as the monitor
keeps a sector of the FAT and its mount between commands, which the
write makes stale. So a program at `0x8000` under the monitor is gone
afterwards, and the monitor shows its prompt again. A held core stays
held. For `ls` and `get`, a running core is paused for the reads,
and goes on after them. While it is paused, the tool uses the program's
card as it is: its slot, which the monitor's `dir` or `load` must have
started up, and it puts back `SD_LBA`, `SD_CHUNK`, and the buffer at the
end. `--slot` of another slot is refused then. While the core is held or
has halted, the tool takes the slot of `--slot`, or slot 0, or slot 1
when slot 0 has no card, as the monitor does, and starts the card up.

`--hold` makes `ls` and `get` hold a running or paused core too, and
start it again from reset afterwards, as `put` and `del` do, so that
they read any slot, whatever the program had. Without it, they need the
program's own card: after a write, the monitor starts again with slot 0
selected, so with the card in slot 1 an `ls` while it runs needs a
`dir 1` on the board first, or `--hold`:

```
tools/sdcard.py --eth 192.168.1.65 --slot 1 put prog.bas
tools/sdcard.py --eth 192.168.1.65 --slot 1 --hold get PROG.BAS
```

A sector takes 16 writes and 16 reads on the link, each a request that
waits for its answer. On an R6, a file comes at about 115 KB a second
over Ethernet, and goes at about 80 KB a second, and on the serial port
at about 0.9 KB and 0.65 KB a second, 0.58 s a sector to read, as each
request waits for the 16 ms latency timer of the FTDI chip. Linux sets the timer in
`/sys/bus/usb-serial/devices/ttyUSB1/latency_timer`, for the board's
port; the timer, not the baud rate, sets the speed there.
`make sdtest` checks the tool on `niceemu --link`, without a board.

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
- `tools/linktest.py` and `tools/cosimtest.py` take no options. Both
  need niceemu, and say so when `nice_cpu/emulator/zig-out/bin/niceemu`
  is missing; `make linktest` and `make cosimtest` build it first
  ([CONTRIBUTING.md](../CONTRIBUTING.md#the-tools-and-niceemu)).
- `tools/screenshot.py [-i FILE] [-n N] [--debugger] [-o FILE] prog.bin`
  runs the program in niceemu, with the console input of `-i` and at
  most `-n` steps, as niceemu's options, and draws the screen as the
  display shows it into `-o`, `screen.png` by default, with the on-board
  debugger's strip under it with `--debugger`. The README's pictures are
  drawn with it, as its docstring says.
