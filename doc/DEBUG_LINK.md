# The debug link

The debug link is remote control: with it, a host, a PC with the tools
of `tools/`, loads a program into the board, starts, pauses, and steps
it, and reads and writes its memory. This document has the words used
for the link, what a host does with it, the control register, the
UART's baud rate, and the link over TCP on the Ethernet port, on the
MEGA65 R3 and R6 and on the Nexys4DDR. [SYSTEM.md](SYSTEM.md) has the
rest of the system, with the address map and the link's other
registers. The link is specified by nice_cpu's
[doc/DEBUG.md](https://github.com/MJoergen/nice_cpu/blob/main/doc/DEBUG.md),
in `nice_cpu/doc/`, which has the packets and every register, and which
is cited here as DEBUG.md.

## The words

These words are used here and in the other documents and sources:

| Word | Meaning |
|---|---|
| The core | The NICE CPU in the FPGA. A core file of the MEGA65 is something else: the whole system, as the MEGA65 loads it. |
| The link | nice_cpu's debug link: packets between the console bytes on the line, with which a host reads and writes memory and the debug registers. |
| The line | The connection that carries the console and the link: the debug UART, or a TCP connection to the Ethernet port. |
| The host | The computer at the other end of the line. |
| Hold | Bit 0 of the control register at `0xFFFFFFF0` is 1: the core is in reset, and the link reaches all of memory. Without a ROM, the core is held at power-up. |
| Start | Bit 0 goes from 1 to 0: the devices are reset, and the core runs from address 0. |
| Hide | Bit 3 of the control register is 1: the ROM is out of the way, so the RAM is at 0, as in the emulator. |
| Clear | A write with bit 2 set fills the RAM, the screen, and the font RAM with 0, and sets the screen's registers as a reset does. |
| Pause | Bit 4 of the control register is 1: the core stops between two instructions, and the link reaches all of memory and the core's registers. Writing 0 to bit 4 makes the program go on. |
| Step | Bits 4 and 5 written to a paused core: it runs one instruction, or enters an interrupt, and pauses again. |
| Notice | A packet that the board sends on its own, such as `h` when the core halts (see [The line](#the-line)). |
| Break | The end of the line's input: a break on the UART, or a host's half-close over TCP. The program then reads the end of its input from the console. |

## The line

The MEGA65's debug UART runs at 230400 baud, 8-N-1, as the tools do by
default, and `0xFFFFFF9F` sets another rate (see
[The baud rate](#the-baud-rate)). The line passes the program's console
bytes both ways, and between them it carries packets, which start with
the byte `0xFF`. A console byte `0xFF` is sent as two. With the packets,
a host reads and writes memory and the debug registers at
`0xFFFFFFD0`–`FF` (see [I/O registers](SYSTEM.md#io-registers)). The
tools in `tools/` are such a host, and `niceemu --link` serves the same
link, so the tools drive the emulator as they drive the board.

The board sends these notices:

| Notice | When |
|---|---|
| `b07` | At reset. The link's version is 7. |
| `h` and the reason | The core has halted. |
| `p` | The core has paused. |
| `x` and a number | The core has paused at a breakpoint. |
| `w` and a number | The core has paused after a step that hit a watchpoint. |
| `o` | An input byte was lost, as the core's input FIFO was full. |

Every stop of the core sends one of `h`, `w`, `x`, and `p`: the first
of them, in this order, that fits.

The Ethernet port carries the same line over TCP (see [The debug link
over TCP](#the-debug-link-over-tcp)). While a host is connected there,
its connection takes the UART's place in what this document says of the
UART: the console bytes, the packets, the notices, and the break.

The on-board debugger ([DEBUGGER.md](DEBUGGER.md)) is a second client
of the link, inside the system, through the link's side port
([DEBUG.md §3](https://github.com/MJoergen/nice_cpu/blob/main/doc/DEBUG.md#3-requests-and-answers)).
While it is up, the host keeps its line, and gets the notices of a stop
that the debugger caused.

A terminal on the line, a plain TCP client such as `nc` on the Ethernet
port or a terminal program on the UART, shows what the program prints,
and what you type goes to the program while it runs. Bytes typed while
it is paused wait for it, and bytes typed while the core is held in
reset or has halted are dropped. The notices show up in the terminal
too, as a few letters after a stray character, such as `h01#C9` after a
`HALT`.

## What the link reaches

| The core | The link reaches |
|---|---|
| Runs | Only its debug registers, `0xFFFFFFD0`–`FF`, with R0–R15 live. A request for any other word gets the error answer `e` with code 02. |
| Is paused | The whole address map, and R0–R15 as the program left them. The counters and the timer stop. |
| Is held in reset, or has halted | The whole address map. |

A write to the control register that holds the core works at any time,
so a host can always stop a program.

## Loading and starting a program

Without a ROM, the core is held in reset at power-up; with one, it runs
the ROM ([PROGRAMMING.md](PROGRAMMING.md#programs-in-the-rom)). A host
loads a program with two writes to the control register at
`0xFFFFFFF0`, around the writes of its words:

1. `0x0000000D` holds the core, clears the memory, and hides the ROM.
2. The host writes the program's words.
3. `0x00000008` starts the core, with the ROM still hidden.

A start without bit 3 shows the ROM again, which boots instead of the
program. `tools/load.py` does all of this (see
[The control register](#the-control-register)).

The clear also ends the halt and the stop of the program that it wipes.
When the clear starts, bit 1 of the control register, the halt reason,
and the stop register become 0. So after `0x0000000D` the control register
reads `0x00000009`, also after a halt. A hold alone keeps them.

## Pausing and stepping

- **Pause.** A write of `0x00000018` asks for a pause: the core stops
  at the next step boundary, and the link sends `p`, which may come
  before the `k` that answers the write. A write of `0x00000008` makes
  the program go on.
- **Step.** A write of `0x00000038` to a paused core runs one step, an
  instruction or an interrupt entry, and the core pauses again: the
  link sends `p`, or `h` if the step halted. Bit 5 reads 0, and does
  nothing unless the core is paused. During the step the link reaches
  only its debug registers, and the counters and the timer run.
- **From the first instruction.** A write of `0x00000018` to a held
  core starts it paused at address 0, so a host can step a program from
  its first instruction.
- **The registers.** While the core is paused, R0–R15 at
  `0xFFFFFFE0`–`EF` hold the core's registers, and a host may write
  R1–R15: the program goes on with them. A write of R0 changes nothing,
  and the link answers a write of R0–R15 while the core is not paused
  with the error `04`. A hold of a paused core keeps R0–R15 until the
  next start or clear, and a hold of a running core leaves them
  undefined.

## Breakpoints and watchpoints

The board has four breakpoints. A host writes an address to
`0xFFFFFFF8`–`FB` and sets its bit in `0xFFFFFFF4`. The core then
pauses before the instruction at that address, and the link sends `x`
with the breakpoint's number, such as `x00#D8`, instead of `p`. After
`x` the core is paused as after `p`, and the stop register at
`0xFFFFFFF6` tells which breakpoint it stopped at. When the program
goes on, it runs that instruction, and does not stop at it again. A
step or a pause that ends at a breakpoint sends `x` too.

The board also has four watchpoints, which stop the program when it
reads or writes a word of data. `0xFFFFFFD5` reads their number, as
`0xFFFFFFF5` reads the breakpoints'. A host writes the word's address to
`0xFFFFFFD8`–`DB`, and sets the watchpoint's bits in `0xFFFFFFD4`: bit
2n for the reads of watchpoint n, and bit 2n + 1 for its writes. The
core pauses after the step that read or wrote the word, and the link
sends `w` with the watchpoint's number. `0xFFFFFFD6` then holds the
address of the instruction that did it, and bit 9 of the stop register
is 1. While a watchpoint is enabled, the pipelined core runs more
slowly.

Both take a write at any time, and a start keeps them: only a reset
clears them. So `tools/load.py` and `tools/run.py` disable them before
they load a program.
[DEBUG.md §6](https://github.com/MJoergen/nice_cpu/blob/main/doc/DEBUG.md#6-the-debug-registers)
has the rules of both.

## Interrupts and waiting

Bits 6 to 10 of the control register show what the core's interrupts
are doing: whether the core waits for an interrupt after `WAIT`,
whether it is in an interrupt routine, and whether a request is pending
(see [The control register](#the-control-register)). `0xFFFFFFD0` and
`D1` read `saved_pc` and `saved_sr`, the PC and the status register
that an interrupt routine returns to.

## Versions

The link's version is 7, which the board sends as `b07` at reset, and
which `0xFFFFFFF2` reads. A host written for an older version works
unchanged. Each version added to the one before:

| Version | What it added |
|---|---|
| 2 | The pause, and the notice `p`. |
| 3 | The step. |
| 4 | The breakpoints, and the notice `x`. |
| 5 | A clear ends the halt and the stop. |
| 6 | The writes of R1–R15. Over TCP, a console byte waits for room in the full input FIFO before it is lost. |
| 7 | With nice_cpu V2.0: the wait for an interrupt, the state of an interrupt routine, and the watchpoints with the notice `w`. The link's registers start at `0xFFFFFFD0`, where they started at `0xFFFFFFE0`. |

## The control register

| Bit | Name | Meaning |
|---|---|---|
| 0 | Hold | 1 holds the core in reset. A write of 0 starts it. |
| 1 | Halted | Read only. 1 after a halt, and stays 1 while the core is held in reset, until the next start or clear. |
| 2 | Clear | A write with bit 2 set first clears the RAM, the screen, and the font RAM to 0, with the core held, and is answered when the memory is clear, after 1.3 ms on the MEGA65 and 0.73 ms on the Nexys4DDR. Bit 3 takes effect when the clear starts, and bit 0 when it ends. |
| 3 | Hide | 1 hides the ROM, so that the RAM is at 0. Reset clears it in a bitstream with a ROM; in one without a ROM it reads 1. |
| 4 | Pause | A write of 1 pauses the core at the next step boundary, and the link sends `p`. It reads 1 while the core is paused, and a write of 0 makes the program go on. A start with bit 4 set pauses before the first instruction. |
| 5 | Step | A write with bits 4 and 5 set to a paused core runs one step, and the link sends `p` again, or `h`. It reads 0. |
| 6 | Waiting | Read only. 1 while the core waits for an interrupt after `WAIT`, also while paused, until a request is pending. |
| 7 | In service | Read only. 1 from the entry of an interrupt routine until its `RTI`, read as R0–R15 are, so not defined after a clear. |
| 8 | After RTI | Read only. 1 from an `RTI` until the next instruction completes, read as R0–R15 are. |
| 9 | NMI pending | Read only. Always 0, as the board raises no NMI. |
| 10 | IRQ pending | Read only. 1 while the timer's request is pending, also while E = 0 or an interrupt routine keeps it from being taken, and 0 while the core is held or has halted. |

The tools write these values:

| Value | Bits | Effect |
|---|---|---|
| `0x0000000D` | Hold, clear, and hide | Stops the core and prepares the memory for a load. |
| `0x00000008` | Hide | Starts or continues the program, with the ROM still hidden. |
| `0x00000018` | Hide and pause | Pauses a running core, or starts a held one paused at address 0. |
| `0x00000038` | Hide, pause, and step | Runs one step of a paused core. |

## The baud rate

The UART runs at 230400 baud after reset, on every board, and
`0xFFFFFF9F` holds the rate in bit/s, `230400`. It is the highest rate
that the termios of both Linux and macOS have a constant for, so a host
of either reaches the board as it is. A core built before `V1.9` runs
at 2 Mbaud after reset. A write of 115200,
230400, 460800, 921600, 1000000, 1500000, or 2000000 sets it, for the
core and the link alike, and a write of any other value is dropped. The
board's USB serial chip makes all of them, and 1 to 2 Mbaud exactly. The
clocks of 100 MHz and 90 MHz make each to within 0.5 %.

The UART takes the new rate once it has sent nothing for 1 ms after
the write, and receives nothing at that moment. So the `k` that answers the write still
goes out at the old rate. A host waits for the `k`, waits a few
milliseconds more, and then changes its own rate, as `tools/hwtest.py`
does. A program that keeps printing keeps the old rate until it stops for
1 ms.

Only a reset brings back 230400 baud. A start of the core keeps the
rate, so a host at another rate still loads and runs programs; the tools
take its rate with `--baud`. A program that sets a rate the host does
not expect cuts the host off until the next reset, so a program should
leave this register to the user, who sets it with the monitor's `baud`,
or the on-board debugger's settings page. Over TCP the rate does not
matter, and the line on the UART changes for the next host there. The
emulator has plain memory at `0xFFFFFF9F`.

## The debug link over TCP

The Ethernet station ([SYSTEM.md](SYSTEM.md#the-ethernet-station))
serves the debug link on TCP port 4510 of its IP address, to one host
at a time. The tools take `--eth HOST`, or `--eth HOST:PORT`, for it:

    python3 tools/run.py --eth 192.168.1.65 prog.bin
    make mon ETH=192.168.1.65

The link reads and writes all memory with no password, so anyone who
can reach the port can do the same. The IP address is 0 after reset,
which serves nothing, so a board is reachable only after a program, the
monitor, or the UART's link gives it an address. Give it one only on a
network you trust.

**The connection is the line**, as the UART is:

- While a host is connected, the link's bytes come from it and go to
  it, and not to the UART, whose bytes are dropped.
- Connecting sends no `b` notice and resets nothing, unlike
  `niceemu --link`
  ([DEBUG.md §7](https://github.com/MJoergen/nice_cpu/blob/main/doc/DEBUG.md#7-transports)).
- A host's half-close, its FIN, is a break, which ends the line's
  input.
- A host is connected from its ACK of the board's SYN-ACK on, so a SYN
  alone, as of a port scan, leaves the link on the UART.
- A console byte that finds the core's input FIFO full waits up to
  50 ms for room, and TCP holds the host back meanwhile. Only then is
  it lost, with the notice `o`.

**The end of a connection:**

- The board keeps the connection after a host's FIN, so a host that is
  done ends it with a reset. The tools set `SO_LINGER` to 0 for that,
  so that each close of theirs, also at an exit or a kill, sends one.
- A connection that a host closed with only a FIN stays until that host
  connects again, or the board resets.
- When a connection ends, the link stays with it until it has taken the
  input that came before, and the output in that time is dropped.

**A new connection:**

- From the same host, it replaces the old one. The old one gets the
  output that came before the new connection, and then the board closes
  it, and only then takes the new one: when the host has acknowledged
  the board's FIN, or reset the old connection, or after the tries
  below. The tools half-close the old one first, at the end of a
  program's input. If that FIN was lost, the old connection still takes
  the host's data and FIN until it ends, and if the FIN has not come by
  then, the end is a break.
- From another host, it gets a reset while one is open, so that its
  `connect` fails at once with "connection refused".
- It starts the line's input anew, as one to `niceemu --link` does
  ([DEBUG.md §7](https://github.com/MJoergen/nice_cpu/blob/main/doc/DEBUG.md#7-transports)):
  once the program has read the old connection's bytes, the console no
  longer reads `0x200`, the end of the input, and the new host's bytes
  reach the program. So a host can type to a monitor that another host
  has left.

**Lost segments:**

- The board resends what the host does not acknowledge, after 300 ms,
  and drops the connection after 17 tries.
- While the host's window is 0, it sends one byte beyond it every
  300 ms, and keeps the connection while the host answers.
- It answers a host's keepalive probe with an ACK, and sends no probe
  itself.
- Its SYN-ACK has no TCP options, so the host sends segments of at most
  536 bytes, and the board sends no more either.

**What gets a reset, or no answer:**

- A segment to the port that fits no connection, as one of a connection
  that the board dropped, gets a reset, as RFC 9293 has it, but for a
  reset, which gets nothing.
- Once a connection is open, a segment without ACK is dropped, and one
  that acknowledges what the board has not sent gets an ACK and is
  dropped.
- Segments to other ports get nothing, and neither does anything while
  the IP address is 0, also after the board resets, until it has an
  address again.
