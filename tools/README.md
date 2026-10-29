# The host tools

The tools run on the host, and talk to the board over its Ethernet port
or its debug UART, with the debug link of
[DEBUG.md](../nice_cpu/doc/DEBUG.md). They use
only the Python standard library, and run on Linux and macOS. Each one
prints its options with `--help`, and its header says more.

| Tool | What it does |
|---|---|
| `nicelink.py` | The debug link, which the other tools use: over TCP to the board's Ethernet port, on the UART, over TCP to `niceemu --link`, or over TCP to `make cosim`. |
| `load.py` | Loads a `.bin` file into cleared memory and starts it, or with `--no-run` leaves the core held in reset. |
| `run.py` | Runs a program on the board and prints what `niceemu` prints, for diffing. |
| `mon.py` | An interactive shell on the link: memory, pause, step, breakpoints, and the console. |
| `hwtest.py` | Programs the FPGA with openFPGALoader and tests the system on the board. |
| `flash.py` | Writes a bitstream into the Nexys4DDR's flash, from which the board starts. |
| `linktest.py` | Checks `run.py` and the link on `niceemu --link` against plain `niceemu`, without a board. |
| `cosimtest.py` | Checks `run.py` and the RTL on `make cosim` against plain `niceemu`, without a board. |
| `screenshot.py` | Runs a program in `niceemu` and draws its screen as a PNG picture, as the text display shows it. |
| `bump.py` | Moves nice_cpu to a tag, builds the R6 bitstream, and writes the badge files. |
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

Each tool takes the line as an option: `--eth 192.168.1.65` for the
Ethernet port (see [Over Ethernet](#over-ethernet)), or `--port` for
the serial port (see [The serial port](#the-serial-port)), which is
`/dev/ttyUSB1` when neither is given.

`make` has a target for each tool:

- `make load FILE=prog.bin` loads a program into the board and starts it.
- `make run FILE=prog.bin` runs one as `niceemu` runs it (see
  [Comparing with the emulator](#comparing-with-the-emulator)).
- `make mon` opens an interactive shell on the link (see
  [mon.py](#monpy)).

They take `ETH=192.168.1.65` for the Ethernet port, and use
`PORT=/dev/ttyUSB1` without it. They pass `ARGS=` on to the tool, for
example `ARGS=--no-run` or `ARGS="-i in.txt -d 0x100:16 -s --timeout 5"`.
`ARGS="--tcp 4000"` drives `niceemu --link 4000` instead of the board.

## Over Ethernet

The board serves the debug link on TCP port 4510 of its Ethernet
station, once it has an IP address
([SYSTEM.md](../doc/SYSTEM.md#the-debug-link-over-tcp)). After reset it
has none. The demo's F11 gives it one: I types a new IP address. Then
use `--eth` with any tool:

    tools/run.py --eth 192.168.1.65 prog.bin

`--eth HOST:PORT` names another port. A plain TCP client, such as
`nc -N 192.168.1.65 4510`, shows the program's console. It sends each
line you type, and Ctrl-D sends a break, which ends the program's input
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

The MEGA65's debug UART runs at 2 Mbaud (2000000), 8-N-1, and needs the
JTAG cable, whose USB port carries it. The tools use the serial device
`/dev/ttyUSB1`. If yours is another, give it to the tools with `--port`,
or to `make` with `PORT=`, and open it in your terminal program. On
macOS, use the `/dev/cu.*` device, as a `/dev/tty.*` device blocks on
open. The port must not be open in a terminal while a tool runs.

A terminal program that runs at 2 Mbaud, such as `picocom`, shows the
program's console: `picocom -b 2000000 /dev/ttyUSB1`. In picocom,
`Ctrl-A Ctrl-\` sends a break, which ends the program's input.

The serial port also gives the board its IP address without the demo:

    tools/mon.py --port /dev/ttyUSB1
    mon> w FFFFFF9A C0A80141
    mon> q

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
held in reset or has halted. To end a program's input, send a break:
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
  the words `0` to `0xFFFF`, and the screen is the words `0xFFFF0000` to
  `0xFFFF1FFF`, the 8192 that both boards have.

Any other address would land on a RAM word, or on a register of the I/O
page, where the emulator has a word of its own, so the program would run
differently. A program can still write the rest of the MEGA65's screen
when it runs.

`load.py` holds the core first, so it also works while a program runs.

## Running a C program

Build the C examples (see [PROGRAMMING.md](../doc/PROGRAMMING.md) for what
that needs):

    make examples

That builds `examples/build/primes.bin` from `examples/primes.c`, which
counts primes. Load it with `mon.py`, start it, and pass the terminal to
it with `console`, so that its first prompt is not lost:

    tools/mon.py --eth 192.168.1.65 examples/build/primes.bin
    mon> go
    mon> c

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
`--symbols` options, so the output of the two can be compared:

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
emulator. Input that the program has not read when it halts is dropped,
as by the emulator. The link's halt notice comes after the program's last
byte, so the output ends there.

### Dumps and symbols

- `-d ADDR:N` takes numbers as `niceemu` does, up to 32 bits, with no sign
  or underscore, but N is at most 65536 words.
- The words at `0xFFFFFFE0` to `0xFFFFFFFF` are read through their RAM
  alias `0x0000FFE0` to `0x0000FFFF`, for the link has its debug
  registers there. The link reads the console and the read counter,
  `0xFFFFFF00` and `01`, as 0.
- The memory is 64K words, repeated through the address space, so `-d`
  beyond them shows the same words again.
- `--symbols FILE` reads the labels that `niceasm.py --symbols` writes.
  After a halt other than `HALT`, it prints where the program was, `At
  label+0x1f`, if the file has any labels. After a halt at
  `___wasm_trap`, the default wasm trap handler, it prints the trap's
  code and location from R1 and R2, as `niceemu` does.
- `-2004` prints the screen from `0x400`, as `niceemu -2004` does. That
  is plain RAM on the board, not the screen that the display shows.

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
the registers and the memory, and disassembles, with one short command
each. It also passes text to and from the program. The README has [a worked
example](../README.md#using-the-interactive-shell).

### Starting it

    tools/mon.py [--eth HOST[:PORT]] [--port /dev/ttyUSB1] [--baud 2000000]
                 [--tcp PORT] [--cosim PORT] [--symbols FILE] [FILE.bin]

- `--eth HOST` talks to the board over its Ethernet port, at its IP
  address HOST (see [Over Ethernet](#over-ethernet)).
- `--port` names the serial device of the board's debug UART,
  `/dev/ttyUSB1` by default, and `--baud` its rate, 2000000 by default.
- `--tcp PORT` talks to `niceemu --link PORT` instead of the board.
- `--cosim PORT` talks to the simulated system of `make cosim`, at
  about 250 UART bytes a second.
- `--symbols FILE` reads the labels of a `.sym` file, which
  `niceasm.py --symbols` and `nicebuild.py --symbols` write, as the
  `symbols` command does.
- `FILE.bin` is optional. It is loaded at the start, as the `load`
  command does, and the core is left held in reset. Without it, `mon.py`
  starts with `status`, and leaves the core as it is.

`make mon ETH=192.168.1.65` runs it over the Ethernet port, and
`make mon` on `PORT=/dev/ttyUSB1`. It takes `FILE=` and `ARGS=`, for
example `make mon ARGS="--tcp 4000"`. On the serial port, no other
program may have the port open while it runs.

### At the prompt

The prompt is `mon>`. Numbers are hex, with or without `0x`, and fit in
32 bits. `help` lists the commands, and `help CMD` describes one.

With labels from `--symbols` or `symbols`, an address may also be a
label, `label+N`, or `label-N`, with N in hex. A label comes before a
hex number with the same spelling, such as `add`; write `0xadd` for the
number. Addresses are then shown with their labels too, as `LOOP` or
`LOOP+0x2`.

The disassembler is nice_cpu's `assembler/nicedis.py`, which nice_cpu
has from `V1.1` on.

The program's output and the link's notices are shown as they arrive,
above the prompt and what you have typed. The notices are:

- `[paused, PC=...]` after a pause.
- `[breakpoint N, PC=...]` when the core stops at a breakpoint.

After these two, and after each step, the instruction at the PC comes
after it, which is the next one to run.
- `[halted: REASON, PC=...]` after a halt, where the reason is `HALT`,
  `reserved control instruction`, `INT inside an interrupt routine`,
  `RTI outside an interrupt routine`, or `step limit`.
- `[boot]` after a reset of the board.
- `[input overflow]` when an input byte is lost.
- `[bad packet dropped]` when a packet has a bad checksum.

An error, such as a bad number or a link that does not answer, prints a
line that starts with `error:`, and the prompt comes back. Ctrl-C stops
the command that runs, and Ctrl-D, `quit`, `q`, or `exit` leaves
`mon.py`. Leaving changes nothing on the board: a running program goes
on.

### The commands

The short names are `s` for `step`, `g` for `go`, `c` for `console`, and
`q` for `quit`. `help` takes them too, as in `help s`.

#### The state of the core

- `status` shows whether the core is running, paused, at a breakpoint,
  held in reset, halted, or held after a halt (`held, after a halt:
  REASON`, until a clear), and why it halted. It also shows whether the ROM is
  hidden, the control register, the link's version as major.minor, and
  the free space in the program's input buffer. When the core is paused
  or halted, it shows the PC.
- `regs` shows R0 to R15. They are defined while the core is paused, and
  after a halt.

#### Loading and running

- `load FILE` holds the core, hides the ROM, clears the memory, disables
  the breakpoints, and loads the `.bin` file. The core stays held in
  reset.
- `go` (`g`) starts a held core at 0, or goes on from a pause.
- `run` starts the program at 0 again: from a hold, a halt, a pause, or
  while it runs. It does not load the memory again.
- `hold` holds the core in reset. A hold of a paused core keeps R0 to
  R15, and a hold of a running core leaves them undefined.
- `pause` pauses a running core, and shows where.
- `step N` (`s N`) runs N steps of a paused core, 1 by default. It shows
  the PC after each step, or, for more than 16 steps, after the last one
  only. It stops at a breakpoint and at a halt. An empty line repeats
  the last `step`, with its N; after other commands it does nothing.

#### Breakpoints

The MEGA65 and the Nexys4DDR have 4 breakpoints. The core stops before
the instruction at a breakpoint's address. When it goes on, it runs that
instruction and does not stop at it again.

- `b ADDR` sets a breakpoint at ADDR, in the first free slot, and shows
  its number.
- `b` lists the breakpoints that are set.
- `bd N` disables breakpoint N, and `bd all` disables all of them.

#### Memory and the control register

- `r ADDR N` reads N words from ADDR, 16 by default, 8 words to a line.
  `r` alone goes on after the last read.
- `w ADDR WORD...` writes the words from ADDR on. It does not write the
  control register.
- `ctl` reads the control register, and `ctl VALUE` writes it. The
  values are in [SYSTEM.md](../doc/SYSTEM.md#the-control-register).

While the core runs, the link reaches only its debug registers at
`FFFFFFE0`–`FF`. Pause or hold the core to read the rest.

#### Disassembly and labels

- `d ADDR N` disassembles N instructions from ADDR, 16 by default. Each
  line has the address, the instruction's words, and the instruction,
  and the labels at an address come on lines of their own before it.
  `d` alone goes on after the last `d`, or starts at the PC after a
  pause, a step, or a breakpoint.
- `symbols FILE` reads the labels of a `.sym` file, in place of those
  read before, and shows how many there are. `symbols` alone shows the
  count.

The instructions are in the syntax that `niceasm` takes. Words that no
instruction gives, such as a reserved control word, are a `.DAT`, with
what they would do as a comment. With labels, a constant of `0x10` or
more at a label is shown as the label.

The disassembler reads the words one after another, and does not tell
code from data. So it may show the words of a string as instructions,
and get out of step after them. With labels, it starts again at each
one: an instruction never spans a label, and when it would, its words
before the label are a `.DAT`, marked `(cut off)`.

#### The program's input

- `send TEXT` sends the text to the program, with escapes such as `\n`,
  `\r`, and `\x1b`.
- `eof` ends the program's input, as the end of a file does. A read of
  the console then returns `0x200`, until the program starts again.
- `console` (`c`) passes the terminal through to the program: each key
  goes to its input as you type it, and its output is shown as it
  arrives, with nothing echoed but what the program echoes. Ctrl-]
  returns to the prompt.

The text is sent no faster than the program's input buffer takes it, so
no byte is lost. Bytes sent while the core is held in reset or has
halted are dropped, and bytes sent while it is paused wait for it.
