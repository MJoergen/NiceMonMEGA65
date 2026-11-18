# BASIC

- [The statements](#the-statements)
- [The disassembler](#the-disassembler)
- [Loading without a host](#loading-without-a-host)
- [Building](#building)
- [Testing](#testing)
- [Its words](#its-words)

The BASIC of the ROM, whose `READY.` the boards show at power-up. Its
design, with the stages to come, is in [doc/BASIC.md](../doc/BASIC.md),
and the monitor that it runs on, with the files, the network, and the
programs at `0x8000`, in [monitor/README.md](../monitor/README.md).

BASIC is an image of its own in the ROM, at `0x4000`, assembled apart
from the monitor's at `0x0000` (#152). It calls the monitor through the
entries of the dispatch table alone, as a program at `0x8000` does, so
everything that BASIC does, a program can do too. The monitor knows of
BASIC only its two vectors, at `0x4000`, the cold start, and `0x4002`,
the warm start, after a program. BASIC's variables are its own 2K words
at `0xFFFFE800`, below the monitor's, and the stack starts below them.

## The statements

The ROM's user interface is BASIC (issue #54,
[doc/BASIC.md](../doc/BASIC.md)). Stage 1 (issue #112) is the shell:
the monitor's commands as statements, run one line at a time, with no
expressions, no variables, and no stored program yet.

At the cold start the ROM clears the screen, prints its banner,
`NiceMon` and the version, then `HELP lists the statements` and
`READY.`, on the screen and on the line. It reads a line from the
console: the keyboard and the line, which the hardware merges. DEL and
backspace delete the character before the cursor, CTRL-C empties the
line, and the cursor and function keys, the other control codes, and
the bytes `0x80` to `0x9F` do nothing. RETURN runs the line, and BASIC
prints `READY.` after it. A line of blanks only runs nothing and gets no
`READY.`. A break on the UART, or a host's half-close over Ethernet,
ends the line's input and not the keyboard's, and the next host to
connect over Ethernet can type again
([SYSTEM.md](../doc/SYSTEM.md#io-registers), `0xFFFFFF00`).

A statement is a keyword, in either case, and its arguments, with
commas between them. A keyword is a whole word: `LOADX` is no `LOAD`.
An argument is a number, in decimal, or in hex after `0x`, such as
`SYS 0x8000`, or a string in quotes, such as `LOAD "HELLO.BIN"`. A
string that the line ends without its closing quote ends with the line.
A line that is no statement prints `Syntax error` and the lines of
`HELP` of its statement, or `Syntax error; HELP lists the statements`
when its first word is no keyword. A number that does not fit 32 bits
prints `Illegal quantity`. The line is scanned from the left, and the
first error decides: `SYS 99999999999X` is an `Illegal quantity`, and
`SAVE "X", "Y", 99999999999` a `Syntax error`, as `SAVE` with an IP
address takes nothing after it. `0x` without digits is no number.

Before the first key of a line, the cursor keys up and down scroll
back through the rows that left the top of the screen a row at a time,
and Page Up and Page Down 24 rows at a time. On the MEGA65 Page Up and
Page Down are CTRL and MEGA with CRSR↑ and CRSR↓, and CRSR↑ and CRSR↓
are the cursor keys, with MEGA or without. Any other key shows
the screen again, and goes on to the line. The history has 384 rows on
the MEGA65 and 77 on the Nexys4DDR. `CLS` leaves it, as `clear` in a
terminal does, and the cold start empties it. `niceemu` has no display
offset, so there the history is kept but not shown.

TAB completes the name of a file of the card's folder `NICE`, as Bash
does, in the word before the cursor when it is not the keyword itself
(issue #137). A name not yet in quotes gets its opening quote. When one
file matches, the rest of its name follows, then the closing quote and
a blank. When several match, the word goes on to the start that they
all share, and a TAB that adds nothing lists them and shows the line
again. Names match in either case, and the word takes the case of the
card's name. Directories, names outside ASCII, and a name that does not
fit the line are left out. With no match, no card, or a card that
fails, TAB does nothing.

| Statement | What it does |
|---|---|
| `SYS A` | Calls the program at `A` ([Programs](../monitor/README.md#programs)), and prints its status when it returns: `Returned 0000002A`. A word of 0 at `A` is no program, and `SYS` says so: `No program at 00008000`. `SYS 0` runs entry 0 of the dispatch table, the cold start, so it restarts BASIC and leaves the RAM from `0x8000` alone. |
| `DUMP [A] [, N]` | Shows `N` words from `A`, 4 to a row with the row's address first, all in hex. Without `A`, the words after the last shown; without `N`, 32 words. |
| `DIS [A] [, N]` | Disassembles `N` instructions from `A`, a row each: the address, the instruction's 1 to 4 words, and its text, all in hex (The disassembler below). Without `A`, the instructions after the last shown; without `N`, 20. |
| `CLS` | Clears the screen. |
| `VER` | The versions of the monitor and of BASIC, and of the dispatch table: `NiceMon V2.3.1, BASIC V2.3.1, dispatch table 1.7`. |
| `IP ["A.B.C.D"]` | Shows the Ethernet station's IP address, `IP address 192.168.1.65`, or writes it first: four decimal numbers of 0 to 255 with dots between them, such as `IP "192.168.1.65"`. Anything else is no address, and `IP` says so and writes nothing. It sets the address with `net_set`, with no mask, no gateway, and no DNS server, and writes `0xFFFFFFB0`, `NET_IP` ([SYSTEM.md](../doc/SYSTEM.md#the-ethernet-station)), when the address is another, so a host connected over TCP loses its connection; the same address again changes nothing there. In `niceemu` it is a register that keeps what is written. |
| `DHCP` | Gets the IP address from the network's DHCP server and writes it, as `IP` does, then shows it, with the mask, the gateway, the DNS server, the DHCP server, and the NTP server, if it gives one, a line each ([The network](../monitor/README.md#the-network)). Without an answer, it prints `No answer from a DHCP server` after about 8 seconds, and leaves the address as it was. |
| `MAC ["MAC"]` | Shows the station's MAC address, `MAC address 02:4E:49:43:45:06`, or writes it first: six bytes of one or two hex digits, in either case, with colons between them, such as `MAC "02:4E:49:43:45:01"`. The first byte must be even, as an odd one makes a group address. Anything else, an empty string too, is no address, and `MAC` says so and writes nothing. It writes `0xFFFFFFB1` and `B2`, so a host connected over TCP loses its connection. Each kind of board has its own after reset: `02:4E:49:43:45:03` on the R3, `02:4E:49:43:45:06` on the R6, and `02:4E:49:43:45:0A` on the Nexys4DDR. Two boards of the same kind on one network need different MAC addresses. In `niceemu` they are registers too, `02:4E:49:43:45:00` after reset. |
| `TIME ["YYYY-MM-DD HH:MM:SS"]` | Shows the clock of the time of day, `2026-11-11 14:30:00`, or sets it first to the date and the time given, two digits for each part but the year, in the years 1970 to 2105, such as `TIME "2026-11-11 14:30:00"`. The clock keeps local time, as the MEGA65's real-time clock does, and knows no time zones. After a reset of the system it is not set. The cold start sets it from the MEGA65's real-time clock, unless the real-time clock lost its time ([SYSTEM.md](../doc/SYSTEM.md#the-i2c-bus)), and leaves a clock that is set already. On the MEGA65, `TIME` with a date and a time in the years 2000 to 2099 sets the real-time clock too, so that later starts, and the MEGA65's other cores, have the time. Until the clock is set, as on the Nexys4DDR, which has no real-time clock, `TIME` prints `Clock not set`; a program, a host, `TIME`, or `NTP` sets it. A start of a program keeps it. Anything else is no time, and `TIME` says so and sets nothing. A clock that a program set past 2106-02-07 shows as `Clock past 2106`. In `niceemu` the clock is the host's time in UTC from the start. |
| `NTP ["SERVER"] [, "+HH:MM"]` | Sets the clock from a time server on the network, and on the MEGA65 the real-time clock too, as `TIME` with a date does, and shows the time it set, the server, and how far the clock was off, such as `Clock set 2026-11-14 12:30:05 from 192.168.1.1, was 7 s behind`. SERVER is a name, such as `"pool.ntp.org"`, or an IP address. Without it, or with `""`, the server is the NTP server that `DHCP` got, or else `pool.ntp.org`. A time server gives UTC, and the clock keeps local time, so the offset is local time less UTC, `"+HH:MM"` or `"-HH:MM"` from `-12:00` to `+14:00`, such as `NTP "", "+01:00"` for Central European Time and `"+02:00"` for its summer time; without it the clock is set to UTC. It needs an IP address, and for a name a DNS server, from `DHCP`. Its errors are a line each: no IP address, no answer to ARP from the server or the gateway, no DNS server, no such name, an error of the DNS server, no answer from the DNS server or the time server after 3 tries of 2 seconds, a server that refused, and an answer that is not to be trusted ([The network](../monitor/README.md#the-network)). |
| `BAUD [RATE]` | Shows the UART's baud rate, `Baud rate 230400`, or writes it first: 115200, 230400, 460800, 921600, 1000000, 1500000, or 2000000, such as `BAUD 921600`. Anything else is no rate, and `BAUD` says so and writes nothing. It writes `0xFFFFFF9F` ([DEBUG_LINK.md](../doc/DEBUG_LINK.md#the-baud-rate)), as the on-board debugger's settings page does. The UART takes the new rate once it has sent nothing for 1 ms, so the answer and `READY.` still come at the old rate, and a terminal on the UART then changes to the new one; only a reset brings back 230400. Over Ethernet the rate does not matter. In `niceemu` the word is memory, which reads 0 after a clear. |
| `LOAD` | Enters words into the RAM from lines of `ADDR WORD` in hex, as a `.bin` file has them (Loading without a host below), up to an empty line, and prints the words written and the lines skipped: `Words loaded: 600, 00008000 to 00008257`. |
| `DIR [SLOT]` | Lists the folder `NICE` of the SD card's FAT32 file system ([Files](../monitor/README.md#files)): `Directory of NICE`, then a row for each file, its name in 24 columns, the long name where it has one or else the 8.3 name, and its size in decimal, and for each directory, its name and `<DIR>`, then `Files: 25, directories: 1`. A name of 24 characters or more has a row of its own, and the size is on the next. With `SLOT`, it mounts the card in it first, and a slot that the board does not have is `File error 27`; without, it lists the card mounted, which the first `DIR` or `LOAD` after reset mounts. It reads the folder through a handle, as a program does, so after a program that left both handles open it is `File error 23`, as `LOAD` and `SAVE` are; `DIR 0` mounts again, which closes them. An error is shown with its number and meaning: `File error 18, FAT16, which is not supported`. |
| `LOAD "NAME.BIN"` | Loads the `.bin` file `NAME.BIN` of the card's folder `NICE` as `LOAD` loads lines, and prints the same summary, so a program copied to the card on a PC loads with no host. Unlike the lines typed, an empty line is passed over, the end of the file ends the load, and a skipped line is counted from the first line of the file. A line with a byte that is not printable ASCII, a control code other than TAB, CR, or LF, DEL, or a byte from `0x80`, is skipped, as `niceemu` rejects it, so that no byte is dropped from the middle of a number. An error in the middle of the file, such as `File error 26, the FAT is damaged`, comes after the summary of the lines before it, whose words are in the RAM. The name is the long name or the 8.3 name, in either case, such as `LOAD "my prog.bin"`. A name that does not end in `.BIN`, in either case, is no program, and `LOAD` says so; other kinds of files are for the later stages of BASIC. |
| `SAVE "NAME", A, N` | Writes `N` words from `A` to the file `NAME` of the card's folder `NICE` as a `.bin` file, a line of `ADDR WORD` in hex for each, and prints `Words saved: 600, 00008000 to 00008257`. A name with no extension gets `.BIN`: `SAVE "PROG", 0x8000, 600` writes `PROG.BIN`. It makes the file, or truncates it when it is there, and `LOAD` reads it back. When the card fills up, the file keeps what fitted, and `SAVE` prints error 30. SAVE writes only to the card: `SAVE "NAME", "IP"` says so. |
| `DELETE "NAME"` | Deletes the file `NAME` of the card's folder `NICE`, its long name or its 8.3 name, as for `LOAD`, with its long-name entries, if it has them, and prints `Deleted NAME`. |
| `LOAD "NAME.BIN", "IP"` | Loads the `.bin` file `NAME.BIN` from the TFTP server at the IP address `IP`, such as `LOAD "HELLO.BIN", "192.168.1.10"`, as `LOAD` loads one from the card, and prints the same summary ([The network](../monitor/README.md#the-network)). `"IP:PORT"` sends the request to `PORT` instead of 69. It needs an IP address, from `IP` or `DHCP`. Without an answer, it prints `No answer from the TFTP server` after about 5 seconds; an error of the server is shown with its code and its message: `TFTP error 1, File not found`. |
| `DIR "IP" [, "PAT"]` | Lists the files of the server `tools/tftpd.py` at `IP` whose names match the pattern `PAT`, with `*` and `?`, such as `DIR "192.168.1.10", "*.BIN"`, a line each with the name and the size; without `PAT`, all of them. Another server answers with an error. |
| `HALT` | Halts the core, which the reset button, or a host over the link, starts again. The tests end with it. |
| `HELP` | Lists the statements, and the keys of the history. |

The debugger has pause, step, and inspect, so BASIC adds only `LOAD`
with no name, which loads a program with no host's tools and no
storage, and `DIS`, which reads code with no host. `DIR` and `LOAD` read
programs from a card's FAT32 file system, and `SAVE` and `DELETE` write
it. `TIME` shows the clock, which the dates of the files come from.
`DHCP` gives a board on a network an address with no host, and `LOAD`
with a server loads a program from a server on it.

## The disassembler

`DIS` shows each instruction as nice_cpu's `assembler/nicedis.py` and
`mon.py` do, so the three disassemblers agree, but for the
pseudo-instructions below, which only `DIS` shows:

    DIS 0x8000, 5
    00008000 0077580f 00000002 0003d800 00008123  CALL 0x8123
    00008004 0003f680                             RET
    00008005 022000b0 00000020                    CMP R1, 0x20
    00008007 3003d800 00008000                    ?Z JMP 0x8000
    00008009 3c400007                             ?Z INT 7

- The text has the condition, the mnemonic with `[C]` and `[M]`, the
  SHIFT aliases, such as `SHL` and `ROR`, and the operands in the syntax
  of [nice_cpu's ISA.md §10.2](https://github.com/MJoergen/nice_cpu/blob/main/doc/ISA.md#102-operands). Constants are in lower-case hex without
  leading zeros, and INT's vector is in decimal.
- A reserved control word, and an instruction with a field that its
  mnemonic does not use and that is not R0, are a `.DAT` of their words,
  with what they would do as a comment, as nicedis.py writes them:
  `.DAT 0x00000001 ; MOVE R0, R0 (s1: R1)`.
- `ADD @--R13, n, R15` followed by `MOVE R15, target`, where `n` is the
  number of words of the `MOVE`, is one row, `CALL target`, and
  `MOVE R15, @R13++` is `RET`: pseudo-instructions of [ISA.md §10.1](https://github.com/MJoergen/nice_cpu/blob/main/doc/ISA.md#101-statements),
  which `niceasm` assembles back to the same words. A condition applies
  to both instructions of a `CALL`, so the two must have the same one,
  as in `?Z CALL 0x8123`. A pair with two conditions, an `ADD` with a
  modifier, an `n` that is not the length of the `MOVE`, or a `MOVE`
  with a modifier, is two rows.
- The other pseudo-instructions of §10.1 are one instruction each, and
  are shown in its place. Some words match two of them, and the first
  that matches, in this order, is shown:

  | Words | Shown as |
  |---|---|
  | `MOVE R0, R0`, the word 0, also of empty RAM | `NOP`, not `CLR R0` |
  | `MOVE R15, @R13++` | `RET`, not `POP R15` or `JMP @R13++` |
  | `ADD @--R13, n, R15` and `MOVE R15, target` | `CALL target`, whose `MOVE` is no `JMP` |
  | `MOVE R15, target` | `JMP target`, so `MOVE R15, R0` is `JMP R0`, not `CLR R15` |
  | `MOVE @--R13, x` | `PUSH x`, so `MOVE @--R13, R0` is `PUSH R0` |
  | `MOVE x, @R13++` | `POP x` |
  | `MOVE x, R0` | `CLR x` |
  | `MOVE[M] R0, a` | `TST a` |
  | `SUB[M] R0, a, b` | `CMP a, b` |

  As with `CALL` and `RET`, a condition is shown, as in `?Z JMP 0x8000`,
  and any other modifier makes the plain instruction: `MOVE[C] R15, R1`
  and `SUB[CM] R0, R1, R2` stay as they are, and so do `MOVE[M]` and
  `SUB[M]` with a dest that is not R0. A field that the `MOVE` does not
  use and that is not R0 makes a `.DAT`, as before. `niceasm` assembles
  each back to the same word. nicedis.py and `mon.py`, and the
  debugger's decode of row 27, show the plain instructions.
- An instruction of 4 words, with constants in all three fields, has a
  text longer than the 34 columns left, and goes on in the next row of
  the screen.

## Loading without a host

`LOAD` with no name loads a program that is typed on the keyboard, or pasted into a
terminal on the line, with no tools on the host and no storage. It reads
lines of `ADDR WORD`, two hex numbers of 1 to 8 digits with blanks or
tabs between them, which is what a `.bin` file has ([nice_cpu's ISA.md
§10.4](https://github.com/MJoergen/nice_cpu/blob/main/doc/ISA.md#104-object-format)), and writes each word. CR, LF, and CR LF end a line, the `LOAD`
line itself too. An empty line ends the load, and so does CTRL-C, which
drops the line it is in; a line of blanks only is passed over, as
`niceemu` passes it. DEL and backspace delete, and the cursor and
function keys do nothing. A line keeps 76 characters: blanks after them
are dropped, as `niceemu` ignores them, and anything else after them
skips the line. A line with anything else, or one with an address
outside a program's RAM, `0x8000` to `0x1E7FF` on the MEGA65 and to
`0xE7FF` on the Nexys4DDR ([Programs](../monitor/README.md#programs)), is skipped: the RAM repeats through the address space, so a
larger address could reach the ROM, the variables, or the stack. The top of that range is the stack itself, which `SYS` uses, so a
program's words stay below it. A second line for an address writes its
word over the first's, where `niceemu` rejects the file. In `niceemu`,
where `0xFFFFFF9E` reads 0, the program's RAM goes up to the screen,
`0xFFFEFFFF`. Its font RAM at `0xFFFE0000`–`0xFFFE1FFF` keeps
only bits 15..0 of a word, and its character ROM at
`0xFFFE2000`–`0xFFFE3FFF` drops one, so a program there does not read
back as loaded. At the end `LOAD` prints the number of words written, with
the lowest and the highest address, and the number of lines skipped,
with the first of them and the last address that a line may have:

    Words loaded: 601, 00008000 to 00009000
    Lines skipped: 4, first line 2; ADDR WORD in hex, ADDR 00008000 to 0001E7FF

The lines are shown in one row of the screen, which each line clears,
and not on the line, so the screen does not scroll, and a paste over the
UART at 2 Mbaud keeps up: a line takes about 1400 instructions, and
arrives in about 90 µs. On the R6, 20600 lines pasted at full speed, in
LF lines and in CR LF lines, were all written, with no byte lost.

Over Ethernet, a paste into a plain client, such as
`nc 192.168.1.65 4510`, keeps up too. The station takes the host's
bytes at 100 Mbit/s, faster than `LOAD` reads them, but a byte that finds
the core's input FIFO of 2048 bytes full waits up to 50 ms for room,
and TCP holds the host back meanwhile. A byte is lost, with the link's
`o`, only when the program reads nothing for 50 ms. On the R6, 20600
lines pasted at full speed over TCP, in LF lines and in CR LF lines,
and through `nc`, were all written, with no byte lost, in about 0.7 s.
`load.py --eth 192.168.1.65 --monitor prog.bin` ([Remote control](../monitor/README.md#remote-control))
is faster, as it writes the words into the memory.

## Building

`make -C basic` builds BASIC's image, `build/basic_image.bin`, and
`make rom` at the top joins it with the monitor's into the ROM,
`build/rom.bin` ([rom.mk](../rom.mk)). Both write the image as a file
for a card too, `build/basic.rom`
([doc/BASIC_ROM.md](../doc/BASIC_ROM.md), #153). The image is the cat of
`basic.nasm`, `basic_cmd.nasm`, `basic_net.nasm`, `basic_time.nasm`,
and `basic_dis.nasm`, BASIC's copies of the monitor's `common.nasm`,
`monlib.nasm`, and `mon.nasm`, the version, and the texts with the
card's folder. `basic.nasm`'s header says what each file has, and
"Its words" below has the words of each.

The image starts with its header, after the two vectors: a magic word,
the interface, the length, a checksum, the address of the version
text, the version as a number, the flags, and the words of BASIC's
RAM ([doc/BASIC_ROM.md](../doc/BASIC_ROM.md#the-image)). The assembler
writes `build/basic_asm.bin`, with 0 for the length, the checksum, the
version as a number, and the flags, and `../tools/basic_rom.py fill`
fills them in. The tests' image has the flag "keep", and the version
`V9.9`, `0x09090000`. `tools/basic_rom.py check FILE` checks an image,
and prints its header.

To try a build on the board, copy `build/basic.rom` to a card's folder
as a `BASIC*.ROM` file, which the monitor loads when the board is
switched on ([README.md](../README.md#a-new-basic)), or put it into the
ROM at once with `make load FILE=basic/build/basic.rom ETH=IP
ARGS=--basic` ([tools/README.md](../tools/README.md#loading-basic-into-the-rom)).

## Testing

`make -C basic test` runs the tests of BASIC's statements in `niceemu`,
with no board, on the ROM of the tests, `../build/rom_test.bin`, which
has the version `V9.9`. The tests of the monitor's code are those of
`make -C monitor test` ([monitor/INTERNALS.md](../monitor/INTERNALS.md#the-tests)),
which builds what these share with them: `hello.bin`, the cards'
images, and the scripts of `monitor/test`. The test needs `FOLDER=NICE`,
the default. It runs these steps in order:

1. **The layout.** nice_cpu's `nicefmt` checks the sources and
   `test/dis.nasm`.
2. **The disassembler.** `test/dis.py` runs `DIS` over `test/dis.nasm`,
   which has every opcode, operand mode, condition, and modifier, the
   control instructions, the reserved words, and each pseudo-instruction
   with its near-misses. It compares each row with the text of
   `nicedis.py`, rewritten by the rules of "The disassembler" above,
   for a pseudo-instruction. It assembles each row again
   and compares the words.
3. **NTP.** `test/ntp.py` types `NTP` and `DHCP` with `--step-time`,
   and learns the frames of each run as the monitor's `test/dns.py`
   does, with the frames of DHCP and DNS of the monitor's
   `test/dhcp.py` and `test/dns.py`. DHCP gives the DNS server and an
   NTP server in option 42. It covers no IP address, DHCP's server, a
   server by name and by address, an offset east and west, a time of
   era 1, datagrams that are passed over, a kiss-o'-death, a leap
   indicator of 3, a stratum of 16, a time before 1970, no answer, an
   answer to the second send, no such name, and offsets that are not.
   It covers the edges of the eras too: the last second of era 0
   before 1970, and the last second of era 1 that the clock takes, and
   the next; the largest offsets east and west, and a clock 0 s off.
   It compares the output and the frames sent with `test/ntp.expected`,
   with a query's port as `pp` and its transmit timestamp as `tt`. It
   runs on an I2C master that is present and never busy, as the
   monitor's `test/rtc.py` has it, and checks that `NTP` writes the
   real-time clock: the master's last command is the cold start's read
   while no time is set, and the write of the chip's status after the
   times of the run.
4. **TFTP.** `test/tftp.py` runs `LOAD` and `DIR` from a TFTP server
   the same way, against `test/tftp.expected`. It covers a file of two
   blocks among packets of other hosts and ports, lost packets, an
   ERROR, an ERROR after the first block, whose summary comes first,
   files of 512 and 0 bytes, a listing, a port given as `"IP:PORT"`,
   bad arguments, and no answer to ARP.
5. **The runs.** The ROM runs once for each test below, with its
   keystrokes from an input file that ends with `HALT`, so that the run
   halts. Each run's console output, a few memory words, and the screen
   are compared with `test/NAME.expected`:

| Test | What runs | What it checks |
|---|---|---|
| `cmds` | The ROM alone | Every statement, its bad arguments, keywords in either case, numbers that do not fit, and the edits of a line. |
| `basic` | The ROM alone, with no card and no IP address | The scanner of a line: keywords glued to a letter or a digit, the HELP lines of each statement's Syntax error, numbers at their limits, `0x` without digits and a number that fails before a string, which are no numbers, strings without a closing quote, too few or too many arguments, and the 0s and the `.BIN` that the scanner writes into the line. |
| `load` | The ROM, with 128K words of RAM, as on the MEGA65 | `LOAD` with the monitor's `build/hello.bin` pasted: CR LF and LF line ends, tabs, blank lines, skipped lines, a line too long, blanks after a line's 76 characters, a DEL that takes back the key after them, an address given twice, and CTRL-C. Then `SYS 0x8000` runs it. |
| `load_64k` | The ROM, with 64K words, as on the Nexys4DDR | `LOAD` at the end of that RAM. |
| `load_emu` | The ROM, with `0xFFFFFF9E` reading 0, as in `niceemu` | `LOAD` up to the screen. |
| `time` | The ROM, with `--step-time` and a copy of the card without partitions | `TIME` not set, set, and shown; dates that are not, such as leap days of years without one, fields of one digit, month 0, day 0, letters, wrong separators, and 2106, and the clock left alone after them; the edges that are, 2000-02-29, 2100-03-01, 2104-02-29, 2^31 seconds, 2105-12-31, the last day of a leap year, and blanks in the quotes; and the dates of `SAVE`, from the clock and while it is not set or before 1980, which `mdir` shows. |

`time` runs with `--step-time`, so that the clock starts at 0, not
set, and counts the same each time, and the files that it writes while
the clock is not set have the fixed date, 2026-01-01 at 00:00:00. It
writes to a fresh copy of the monitor's `super.img`, and its output ends
with what the card holds that the image did not, from the monitor's
`test/fat_tool.py diff`, with the times as `**`, as the clock's seconds
count steps, and the order of the sector writes, from a second run with
`-t` and `test/fat_tool.py order`.

The comments above each input in the Makefile say what each keystroke
tests. The expected files were checked by hand: after a change that
alters an expected output, check the new output the same way before you
copy it from `build/` to `test/`. `cmds` shows the addresses of the
dispatch table, which change with the monitor's code.

## Its words

BASIC's image is at `0x4000`–`0x7FFF`, 16384 words, of which the
table of the ROM in [monitor/INTERNALS.md](../monitor/INTERNALS.md#the-roms-words)
has those in use and those free. These are its words, by the source
they come from, in the order that the Makefile joins them. The column
"Text" counts the words of the texts, which are part of "Words", packed
four characters a word with `.ASCII_B`. `common.nasm`, `monlib.nasm`,
and `mon.nasm` are BASIC's copies of the monitor's files, and the
version is that of the tests, `V9.9`. `make -C monitor test` checks the
table, and `make romsize` writes it again.

<!-- romsize basic -->
| Source | What it is | Words | Text |
|---|---|---:|---:|
| `basic.nasm` | The vectors, the header, the main loop, the scanner, the keywords, the messages, and the help | 842 | 440 |
| `basic_cmd.nasm` | The routines of the statements that were the commands | 1586 | 294 |
| `basic_net.nasm` | `DHCP`, `NTP`, and TFTP | 907 | 150 |
| `basic_time.nasm` | `TIME`, and the clock's side of `NTP` | 275 | 44 |
| `basic_dis.nasm` | The disassembler of `DIS` | 871 | 79 |
| `common.nasm` | What the monitor and BASIC share: texts, IP addresses, and dates | 237 | 5 |
| `monlib.nasm` | The routines that programs join | 274 | 0 |
| `mon.nasm` | The stubs of the entries | 90 | 0 |
| `build/basic_folder.nasm` | The texts with the folder's name: `DIR`'s, and the error of a card without it | 14 | 14 |
| `build/version_test.nasm` | The version in the banner, the tests' `V9.9` | 2 | 2 |
| In all | | 5098 | 1028 |
<!-- /romsize basic -->
