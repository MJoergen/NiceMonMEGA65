# The debug link

The debug UART of the MEGA65 carries two things at once: the console of the
program on the NICE core, and a small binary protocol through which a host
reads and writes the memory and controls the core. The board only answers
requests. Everything that a person sees, such as hex dumps, the disassembler,
and the command prompt, is in the host tool, `tools/nicemon.py`.

The UART runs at 2,000,000 baud, 8-N-1, with no flow control.
`src/link.vhd` implements the protocol on the board, and `src/run_ctl.vhd`
the run control and the trace.

## Bytes and packets

The byte 0xFF is the escape byte, ESC. It starts a packet in either
direction. Any other byte is a console byte.

- From the host, a console byte goes to the core's input, at `0xFFFFFF00`.
  ESC ESC sends the console byte 0xFF.
- From the board, a console byte is one that the core wrote to
  `0xFFFFFF00`. A byte 0xFF that the core writes is sent as ESC ESC.

So the console is 8-bit clean, and a terminal that ignores packets shows
the program's output, apart from the rare 0xFF.

A packet is ESC, a tag byte, and a fixed number of bytes that the tag and
its header give. Nothing else is sent inside a packet: no console byte goes
between the bytes of a packet. Numbers are little-endian. An address is 4
bytes, a count is 2 bytes, and a word is 4 bytes.

### Requests, from the host

| Packet | Meaning | Answer |
|---|---|---|
| ESC `R` addr n | Read n words, from addr upwards | ESC `r`, then the n words |
| ESC `P` addr n | Read the word at addr n times, for a register that returns the next value of a stream, such as the trace | ESC `r`, then the n words |
| ESC `W` addr n, then n words | Write n words, from addr upwards | ESC `k`, once the last word is written |

The tags are the ASCII letters. n is 0 to 65535. ESC with any other tag
byte is dropped, and both bytes are lost. A request that stops for longer
than 10 ms before its last byte is dropped, so that a host that died in the
middle of one does not leave the board waiting. The words of a `W` written
before it stopped stay written.

The host sends nothing after a request until its answer has arrived, apart
from the data of a `W`. So the board need not buffer what comes while it
answers. A console byte sent meanwhile may be lost.

### Notices, from the board

| Packet | Meaning |
|---|---|
| ESC `b` version | The board has been reset. The version of this protocol is 1. |
| ESC `h` reason | The core has stopped: it has halted, or it is paused. The last byte that it wrote to the console comes before this. |

The reasons of `h` are these:

| Reason | Why the core stopped |
|---|---|
| 0x01 | A pause request, written to `0xFFFFFFF2` |
| 0x02 | The steps written to `0xFFFFFFF3` are done |
| 0x10 + k | Breakpoint k: the next instruction is at its address |
| 0x20 + k | Watchpoint k: the step read its address |
| 0x30 + k | Watchpoint k: the step wrote its address |
| 0x81 | HALT |
| 0x82 | A reserved control word |
| 0x83 | INT inside an interrupt routine |
| 0x84 | RTI outside an interrupt routine |

0x81 to 0x84 are 0x80 plus the halt reason at `0xFFFFFFF1`.

## The address space

The link's reads and writes go to the same address space as the core's data
bus, with the address map in `src/nicemon.vhd`. The difference is that the
words `0xFFFFFFE0` to `0xFFFFFFFF` are the debug registers below for the
link, and memory for the core.

| Address | Register |
|---|---|
| `FFFFFFE0`–`EF` | R0 to R15 of the core, read only. They are the values after the last step, and R15 is the address of the next instruction. |
| `FFFFFFF0` | Control. Bit 0 holds the core in reset while it is 1. A write with bit 2 set first clears the memory, the screen included, with the core held, and is answered when the memory is clear. Bit 3 hides the ROM, so that the RAM is at 0. A read returns bits 0 and 3, the halted flag in bit 1, and the paused flag in bit 4. |
| `FFFFFFF1` | Why the core halted, read only: 0 while it has not halted, 1 for HALT, 2 for a reserved control word, 3 for INT inside an interrupt routine, and 4 for RTI outside one. |
| `FFFFFFF2` | Run. Write 1 to pause the core, or 2 to let it go on. A read returns bit 0 while it is paused, bit 1 while a pause is waiting to happen, and the reason of the last stop in bits 15..8. |
| `FFFFFFF3` | Step. Writing n lets the core go on for n steps, and then pause. A read returns the steps left. |
| `FFFFFFF4` | Trace. A read returns the number of steps in the trace. A write sets the step that `FFFFFFF5` returns next: 0 is the oldest. |
| `FFFFFFF5` | Trace data. Each read returns the next word of the trace: three words for each step, oldest first. |
| `FFFFFFF6` | Info, read only: the protocol version in bits 7..0, the number of breakpoints in bits 11..8, the base-2 logarithm of the trace's length in bits 15..12, and the address bits of the RAM in bits 20..16. |
| `FFFFFFF7` | Reads 0. |
| `FFFFFFF8`–`FB` | The addresses of breakpoints 0 to 3. |
| `FFFFFFFC`–`FF` | The kinds of breakpoints 0 to 3. Bit 0 stops before an instruction at the address is run, bit 1 after a step that reads the address, and bit 2 after a step that writes it. 0 turns the breakpoint off. |

## Run control

The core pauses between two steps, before it begins the next instruction.
A step is one instruction, or the entry into an interrupt, as in the
emulator. While a pause waits to happen, the core takes no interrupt, so
it pauses before the next instruction. While the core is paused, the
cycle counter and the timer go on counting.

- A pause request stops the core at the next step boundary. A pause
  requested while the core is held in reset stops it before its first
  instruction, at address 0.
- Writing 2 to `FFFFFFF2` lets a paused core go on. It also cancels a
  waiting pause and the steps left. A breakpoint at the address of the
  next instruction does not stop it again at once.
- Holding the core in reset ends a pause, but keeps a pause request.
- A breakpoint stops the core before an instruction at its address. A
  watchpoint stops it after the step that read or wrote its address
  through the data bus. Instruction fetches are not reads in this sense.
  The pipelined core may run one more instruction first, if that one has
  already issued a data read of its own.
- The halted flag and the paused flag are never both 1.

Each stop sends one `h` notice. The core's registers can then be read at
`FFFFFFE0`.

## The trace

The board keeps the last steps of the core, 1024 on the board, in a ring
buffer. It is cleared each time the core starts. Each step is three words:

1. The address of the instruction. For an interrupt entry, the address of
   the instruction that the interrupt came before.
2. The instruction word. It is 0 for an interrupt entry.
3. Flags: bit 0 for an interrupt entry, bit 1 for an NMI, bit 2 for a
   skipped instruction, bit 3 for a step that wrote memory, the vector of
   an interrupt in bits 15..8, and the halt reason of the step in bits
   18..16.

Pause the core before reading the trace, or the steps move while it is
read.

## An example

Load the two words `0x11223344` and `0x55667788` at address 0x100, and read
the first back:

    host:  FF 57 00 01 00 00 02 00 44 33 22 11 88 77 66 55   ESC W 0x100 n=2 ...
    board: FF 6B                                             ESC k
    host:  FF 52 00 01 00 00 01 00                           ESC R 0x100 n=1
    board: FF 72 44 33 22 11                                 ESC r 0x11223344
