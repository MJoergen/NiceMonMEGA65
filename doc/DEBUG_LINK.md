# The debug link

This is the debug link on the MEGA65 R3 and R6, and on the Nexys4DDR:
its words, how a host loads, pauses, steps, and stops a program, the
control register, the UART's baud rate, and the link over TCP on the
Ethernet port. [SYSTEM.md](SYSTEM.md) has the rest of the system, with
the address map and the link's other registers. DEBUG.md is nice_cpu's, in `nice_cpu/doc/`.

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
| Notice | A packet that the board sends on its own: `b07` at reset (the link's version, 7), `h` when the core halts, `p` when it pauses, `x` when it stops at a breakpoint, `w` when it stops after a watchpoint's hit, and `o` when an input byte is lost. |

The MEGA65's debug UART runs at 230400 baud, 8-N-1, and carries the
debug link of nice_cpu's [doc/DEBUG.md](https://github.com/MJoergen/nice_cpu/blob/main/doc/DEBUG.md). It passes
the program's console bytes both ways, and between them it carries
packets, which start with the byte `0xFF`. A console byte `0xFF` is sent
as two. With the packets, a host reads and writes memory and the debug
registers at `0xFFFFFFD0`–`FF` (see [I/O registers](SYSTEM.md#io-registers)). The
board sends a notice at reset (`b07`), when the core halts (`h` and the
reason), and when an input byte is lost (`o`). The tools in `tools/` are
such a host, and `niceemu --link` serves the same link, so the tools
drive the emulator as they drive the board. The tools use 230400 baud too.
`0xFFFFFF9F` sets another rate (see [The baud rate](#the-baud-rate)).

The Ethernet port carries the same line over TCP (see [The debug link
over TCP](#the-debug-link-over-tcp)). While a host is connected there,
its connection takes the UART's place in what this document says of the
UART: the console bytes, the packets, the notices, and the break.
The on-board debugger ([DEBUGGER.md](DEBUGGER.md)) is a client of the
link inside the system, through its side port ([nice_cpu's DEBUG.md §3](https://github.com/MJoergen/nice_cpu/blob/main/doc/DEBUG.md#3-requests-and-answers)):
while it is up, the host keeps its line, and gets the notices of a stop
that the debugger caused.

Without a ROM, the core is held in reset at power-up; with one, it runs
the ROM (see [The ROM](SYSTEM.md#the-rom)). A host loads a program with two
writes to the control register at `0xFFFFFFF0` around the writes of its
words. `0x0000000D` holds the core, clears the memory, and hides the ROM,
and `0x00000008` starts the core with the ROM still hidden (see
[The ROM](SYSTEM.md#the-rom)). A start without bit 3 shows the ROM again, which
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

With link version 6, a host writes R1–R15 at `0xFFFFFFE1`–`EF` while
the core is paused, and the program goes on with them. A write of R0,
or one while the core is not paused, changes nothing, and the link
answers a write of R0–R15 while it is not paused with the error `04`.

Link version 7 (nice_cpu V2.0) adds a wait for an interrupt, the hidden
state of an interrupt routine, and watchpoints, and its registers start
at `0xFFFFFFD0`. Bits 6 to 10 of the control register read the wait, the
hidden state, and the pending requests, and `0xFFFFFFD0` and `D1`
`saved_pc` and `saved_sr` (see [The control register](#the-control-register)).
The board has four watchpoints: their number at `0xFFFFFFD5` is 4.
A host of version 6 works unchanged.

A terminal on the line, a plain TCP client such as `nc` on the Ethernet
port or a terminal program on the UART, shows what the program prints,
and what you type goes to the program while it runs. Bytes typed while it is paused wait
for it, and bytes typed while the core is held in reset or has halted
are dropped. The notices show up in the terminal too, as a few letters
after a stray character, such as `h01#C9` after a `HALT`.

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
serves the debug link on TCP port 4510 of its IP address,
to one host at a time. While a host is connected, the link's bytes come
from it and go to it, and not to the UART, whose bytes are dropped. A
host is connected from its ACK of the board's SYN-ACK on, so a SYN alone,
as of a port scan, leaves the link on the UART. The
connection is the line, as the UART is: connecting sends no `b` notice
and resets nothing, unlike `niceemu --link` ([DEBUG.md §7](https://github.com/MJoergen/nice_cpu/blob/main/doc/DEBUG.md#7-transports)), and a host's
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
([DEBUG.md §7](https://github.com/MJoergen/nice_cpu/blob/main/doc/DEBUG.md#7-transports)): once the program has read the old connection's bytes, the
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
