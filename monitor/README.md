# monitor

- [Hardware abstraction layer](#hardware-abstraction-layer)
  - [The dispatch table](#the-dispatch-table)
  - [The shared routines](#the-shared-routines)
- [The commands](#the-commands)
- [Files](#files)
- [The network](#the-network)
- [The disassembler](#the-disassembler)
- [Programs](#programs)
- [Remote control](#remote-control)
- [Loading without a host](#loading-without-a-host)
- [The demo](#the-demo)

The ROM at `0x0000`–`0x7FFF`, which the core boots from, holds:

- a hardware abstraction layer, the HAL, of twenty routines that reach
  the hardware or the state the monitor keeps, called through a dispatch
  table at the start of the ROM. It is not a library: what a program can
  do for itself stays in the program.
- the monitor's main loop with a few commands.

The rest of the ROM is free. The demo is no longer in it, but a program
of its own (The demo below).

The monitor's variables are in the RAM at `0xFFFFF000` and up, and its
stack grows down from there ([SYSTEM.md](../doc/SYSTEM.md#stack-heap-and-variables)).

## Hardware abstraction layer

A program under the monitor sees three levels, which
[doc/PROGRAMMING.md](../doc/PROGRAMMING.md) describes for
those who write programs:

1. **The hardware**: the I/O registers of
   [doc/SYSTEM.md](../doc/SYSTEM.md) and nice_cpu's SYSTEM.md, the same
   in `niceemu` but for the differences of
   [doc/EMULATOR.md](../doc/EMULATOR.md). Every program has them. The
   hardware also has the integrated debugger, on the board's own
   keyboard and screen (the README's
   [The on-board debugger](../README.md#the-on-board-debugger), and
   [doc/DEBUGGER.md](../doc/DEBUGGER.md)), and remote control, through
   which a host loads, runs, and debugs a program over Ethernet or the
   UART (nice_cpu's
   [DEBUG.md](https://github.com/MJoergen/nice_cpu/blob/main/doc/DEBUG.md),
   and the host tools in [tools/](../tools/README.md)). Neither needs
   the ROM.
2. **The ROM**: the entries of the dispatch table (The dispatch table
   below), which are there whenever the ROM is visible. A host that
   loads a program at 0 hides the ROM, and the entries go with it.
   `niceemu` has no ROM: there the monitor is a program at 0 like any
   other, and `cat monitor.bin prog.bin` runs it with a program at
   `0x8000`, for a `.bin` file is address and word pairs.
3. **The library**: the routines of `monlib.nasm` (The shared routines
   below), and the stubs of `mon.nasm`, which are joined to a program
   when it is built, so they are in its image only when it joins them.
   There is no linker, so a program that joins a file has all of it.

The ROM also has routines of its own, which have no entries and which
programs do not call: the sector routines of the SD cards, the frame
routines and the ARP cache of the network, and FAT32 in C.
[INTERNALS.md](INTERNALS.md) describes them, with the build and the
tests.

The monitor is in NICE assembly, with FAT32 and the clock in C. The ROM
is its files in this order, and the words of each are those of the build
of 2026-11-11, less the command `x` and its copy of the demo (#129):

| File | What it is | Words |
|---|---|---:|
| `monitor.nasm` | The dispatch table, the HAL, the screen, and the line with its scrollback | 696 |
| `monitor_cmd.nasm` | The main loop and the commands, which BASIC is to replace | 3949 |
| `monitor_dis.nasm` | The disassembler of `u` | 1079 |
| `monitor_sd.nasm` | The routines for the SD cards | 390 |
| `monitor_eth.nasm` | The routines for the network | 1856 |
| `monlib.nasm` | The routines that programs join, which the commands use too | 259 |
| `mon.nasm` | The stubs through which a program calls the entries | 50 |
| `fat32.c` | FAT32, translated by `nicewasm --ram`, with the data of the module | 9435 |
| `clock.c` | The `time` command, the dates of files, and the real-time clock | 1199 |
| nice_cpu's `lib.nasm` and `muldiv_mpu.nasm` | The runtime of the C code | 259 |
| `build/version.nasm` and `build/folder.nasm` | The version and the card's folder, which the Makefile writes | 49 |
| | All of the monitor, of the ROM's 32768 words | 19221 |

`mon.h` has the entries' declarations for C, and is no part of the ROM.

`make -C monitor` builds `build/monitor.bin`, and `make -C monitor test`
runs it in `niceemu` ([INTERNALS.md](INTERNALS.md#building-and-testing)).
The QNICE monitor (QMON) of
[QNICE-FPGA](https://github.com/sy2002/QNICE-FPGA) is the inspiration,
not the model.

### The dispatch table

Each entry is one `JMP routine`, two words, so entry n is at address
2n, and entry 0 is the reset. A program calls entry n as it calls any
routine, `CALL 2n`, through the names that `mon.nasm` gives: an `.EQU`
for each entry, such as `MON_PUTC`, and a stub for each, such as
`_mon_putc  JMP MON_PUTC`. Entries are only ever added at the end, never
moved or removed, so a program built for one monitor runs on every later
one.

An entry is added only when a program cannot do without it: it reaches
hardware that the monitor owns or that differs between boards, or state
that the monitor keeps, such as the cursor and the outputs. The file API
of the SD card is such entries: with FAT32 in the ROM, the mounted card
and the caches are state that the monitor keeps. Its sector routines are
not: a program loads and saves files, not sectors, and one that wants
sectors drives the registers, which are the same everywhere. Strings,
memory, number formatting, line editing, and random numbers are not the
HAL's: assembly programs join `monlib.nasm` (The shared routines below),
which the monitor's own commands use too, and C programs have nice_cpu's
`libc`. The ROM's routines could not serve C anyway, for a C string is
bytes packed four to a word in wasm's linear memory
(`nice_cpu/translator/WASM.md`), and libc must run in `niceemu`, which
has no ROM.

The routines follow the C ABI of `nice_cpu/runtime/ABI.md`: arguments in
R1–R4, the result in R1, R1–R6 changed, and R7–R13 kept. A C program for
the monitor declares them with `mon.h`, and is joined with the stubs of
`mon.nasm` (`nicebuild.py --monitor --asm mon.nasm`), as the translator
makes a call to the `env` import `mon_putc` a call to `_mon_putc`. For
C, `mon.nasm` also has `_scr_getx` and `_scr_gety`, as `scr_getxy`
returns two values. Such a program runs only with the ROM visible, as
every program built at `0x8000` for the monitor does.

VBASE is 0 at reset and stays 0. The monitor has no interrupts of its
own, as the debugger is hardware and the board has no NMI source, and it
keeps E at 0, so the vector table that would overlap the dispatch table
is never read. A program that wants interrupts sets VBASE to a page of
its own image, and the monitor clears E, stops the timer, and sets VBASE
back to 0 at every return. It sets the font base back to 0 then too, so
that the screen shows Spleen, and leaves the font RAM as the program left
it. It also shows the cursor again, blinking, and turns the display
offset off, as a program may have hidden the one or used the other.

| # | Addr | Name | Arguments → result |
|---|---|---|---|
| 0 | `00` | `mon_reset` | Cold start: E, the timer, VBASE, and the font base cleared, the stack, the variables, the screen, the clock of the time of day from the MEGA65's real-time clock while it is not set, the banner, the main loop. The RAM from `0x8000` is left alone. |
| 1 | `02` | `mon_exit` | R1 a status. Back to the main loop with a fresh stack, with E, the timer, VBASE, and the font base cleared, the cursor shown and blinking, the display offset off, and the status printed where the program left the cursor, on a new line if that is not column 0; for a program that has not kept the SP of its entry. A program with the runtime's start-up code returns or calls `exit` instead, which lands here too. |
| 2 | `04` | `mon_version` | → R1 the version of the table, major in bits 31..16, minor in 15..0: `0x00010005`, 1.5. |
| 3 | `06` | `mon_putc` | R1 a character, to the outputs `mon_out` selects. On the screen it goes at the cursor, which moves on, to the next row after the last column; CR moves the cursor to column 0, LF to column 0 of the next row, BS one back, and TAB to the next multiple of 8; the other control codes and `0x7F` do nothing, and `0x80` to `0x9F` go on the screen as any character, blank in Spleen and drawn from the font RAM when a program selected it; past the last row the rows move up by one, by copying, so the rows shown are always the 2000 words at `0xFFFF0000`, as in `niceemu`. On the line every byte goes as it is. |
| 4 | `08` | `mon_out` | R1 the outputs: bit 0 the line, bit 1 the screen; both at reset. → R1 the old ones. |
| 5 | `0A` | `scr_cls` | Clears the screen in the current color, cursor home, shown and blinking, display offset 0. |
| 6 | `0C` | `scr_moveto` | R1 the column, R2 the row; a column past 79 is 79, and a row past 24 is 24. |
| 7 | `0E` | `scr_getxy` | → R1 the column, R2 the row. |
| 8 | `10` | `scr_color` | R1 the color for later characters, bits 31..8 of a screen word. → R1 the old one. |
| 9 | `12` | `fs_mount` | R1 a slot. Mounts its card, and closes the files that were open (Files below). → R1 0, or an error. Table 1.1. |
| 10 | `14` | `fs_open` | R1 a name, R2 a mode: 0 to read a file of the folder `NICE`, 1 to write one, which is made or truncated (table 1.2), 2 for the folder itself, whose name is empty or `/`. The name is a long name or an 8.3 name, in either case (table 1.4). Mounts a card when none is. → R1 a handle, 0 or 1, or an error. Table 1.1. |
| 11 | `16` | `fs_read` | R1 a handle of a file, R2 a buffer, R3 a number of bytes. Reads up to that many, one byte per word. → R1 the number read, 0 at the end, or an error. Table 1.1. |
| 12 | `18` | `fs_readdir` | R1 a handle of a directory, R2 a buffer of 4 words. The next entry: in words 0 to 2 the 11 bytes of its 8.3 name, padded with blanks, and its attributes, as FAT has them, 4 bytes to a word from bits 7..0, and in word 3 its size. → R1 1, 0 at the end, or an error. Table 1.1. |
| 13 | `1A` | `fs_close` | R1 a handle. Finishes a file opened to write: its last sector, and its size in its directory entry. The handle is closed also after an error. → R1 0, or an error. Table 1.1. |
| 14 | `1C` | `fs_write` | R1 a handle of a file opened to write, R2 a buffer, R3 a number of bytes, one per word, bits 7..0. → R1 the number written, fewer when the card is full, or an error. Table 1.2. |
| 15 | `1E` | `fs_delete` | R1 a name, as for `fs_open`. Deletes the file of the folder `NICE`, with its long-name entries. → R1 0, or an error. Table 1.2. |
| 16 | `20` | `udp_open` | R1 a local port, or 0 for one of 49152 to 65535. Opens the UDP endpoint, and enables the port for Ethernet frames (The network below). → R1 the port, or an error. Table 1.3. |
| 17 | `22` | `udp_send` | R1 an IP address, R2 a port, R3 a buffer, R4 a number of bytes, one per word, up to 1472. Sends them as a datagram. → R1 0, or an error. Table 1.3. |
| 18 | `24` | `udp_recv` | R1 a buffer, R2 a number of bytes, R3 the address of 2 words, or 0. Does not wait. Copies up to that many bytes of the next datagram, one per word, and its source's IP address and port to the 2 words; with R2 0 copies nothing, and leaves the datagram waiting. → R1 the bytes copied, 0 when none waits, or an error. Table 1.3. |
| 19 | `26` | `udp_close` | Closes the endpoint, and disables the port for Ethernet frames. → R1 0. Table 1.3. |
| 20 | `28` | `fs_readname` | R1 a handle of a directory, R2 a buffer of 4 words, R3 a buffer of 256 words. The next entry, as `fs_readdir` gives it, and its name in R3's buffer, one character per word up to a 0 word: its long name, or else its 8.3 name as a name, `HELLO.BIN`, in lower case where the entry says so. A character of a long name outside ASCII is `?`. → R1 1, 0 at the end, or an error. Table 1.4. |
| 21 | `2A` | `net_config` | R1 the word address of 4 words. Writes the IP address, the mask, the gateway, and the DNS server to them, each 0 for none (TCP and DNS below). → R1 0. Table 1.5. |
| 22 | `2C` | `net_set` | R1 the word address of 4 words, as `net_config` gives them. Sets the four, for a network with no DHCP, and forgets the lease. A new IP address breaks a host's connection over TCP, as `i A.B.C.D` does, and ends every TCP connection of the program in `E_TRESET`. → R1 0. Table 1.5. |
| 23 | `2E` | `net_dhcp` | What `i dhcp` does, printing nothing: the address, the mask, the gateway, the DNS server, and the lease. With an address set, it asks for that one. Waits up to 16 seconds. → R1 0, or an error. Table 1.5. |
| 24 | `30` | `net_poll` | Takes the frames that wait, and sends what is due: ACKs, retransmissions, and the lease's renewal. Never waits. A program that uses the network calls it every 100 ms or so. → R1 not negative, of no meaning yet. Table 1.5. |
| 25 | `32` | `dns_lookup` | R1 the byte address of a name, up to a 0 byte, R2 the word address of the result. Writes the name's IPv4 address to the word at R2. A name of four decimal numbers with dots is taken as it is. Waits up to about 9 seconds. → R1 0, or an error. Table 1.5. |
| 26 | `34` | `tcp_open` | R1 the word address of a control block, R2 an IP address, R3 a port, R4 the sizes of the rings in bytes, to receive in bits 31..16 and to send in 15..0, each 64 or more. Opens a connection: waits up to 3 seconds for ARP, sends the SYN, and does not wait for the answer. → R1 a handle, 0 to 3, or an error. Table 1.5. |
| 27 | `36` | `tcp_state` | R1 a handle. → R1 its state, `TCP_FREE` to `TCP_LISTEN`, or the connection's error. Table 1.5. |
| 28 | `38` | `tcp_send` | R1 a handle, R2 the byte address of a buffer, R3 a number of bytes. Takes as many as fit into the ring to send, and sends what the windows let go. → R1 the bytes taken, 0 when none fit, or an error. Table 1.5. |
| 29 | `3A` | `tcp_recv` | R1 a handle, R2 the byte address of a buffer, R3 a number of bytes. Copies up to that many of the bytes received. → R1 the bytes copied, 0 when none wait, `E_TEOF` once the peer has closed and every byte is read, or an error. Table 1.5. |
| 30 | `3C` | `tcp_close` | R1 a handle, R2 0 to close, or 1 to abort. A close sends the bytes that wait, then the FIN, and the handle frees itself later; an abort sends a RST and frees it at once. → R1 0, or an error. Table 1.5. |
| 31 | `3E` | `tcp_listen` | R1 the word address of a control block, R2 a local port, 1 to 65535 but 4510, R3 the sizes of the rings, as R4 of `tcp_open`. Makes a handle that waits for a peer to connect to the port. Sends nothing, and does not wait. → R1 a handle, 0 to 3, or an error. Table 1.5. |

By the table's own rule, it has no `mon_getc` or `mon_getc_nb`, as the
console at `0xFFFFFF00` is the same on every board and in the emulator,
with the line and the keyboard merged by the hardware, and nice_cpu's
`nice_getc` and `nice_pollc` read it; and no `mon_setvec`, as the
monitor keeps no vector table. `mon_out` is one routine and one piece of
state in place of a `scr_putc` and a `ser_putc`: the line is the
console, which any program can write, and the screen's memory is the
same everywhere, so what the HAL adds is the terminal, the cursor, the
scrolling, and the copy to the line.

### The shared routines

`monlib.nasm` is a library: it is joined after a program when the
program is built, with `mon.nasm`, whose stubs its routines call, so
its routines are in the program's image, and only in a program that
joins it. They print through `mon_putc`, entry 3, so they need the ROM,
as the entries do; in `niceemu` the monitor is joined at 0 (The ROM
above). The monitor joins the file too, for its own commands, but a
program does not reach the monitor's copy, which has no entry. A C
program has nice_cpu's `libc` instead. The routines follow the C
ABI, and their names start with `_io_`, so that they clash with nothing
in nice_cpu's runtime or C library:

| Routine | What it does |
|---|---|
| `_io_puts` | The string at R1, one character per word up to a 0 word, through `mon_putc`. |
| `_io_crlf` | CR LF, which ends a line on the screen and on the line. |
| `_io_puthex` | R1 in hex, 8 digits. |
| `_io_putdec` | R1 in decimal, unsigned, with the math unit. |
| `_io_gethex` | A hex number in the string at R1, after any blanks. → R1 the value, R2 the number of digits, 0 for none, R3 the address after them. |
| `_io_gets` | A line into the buffer at R1, up to R2 characters and a 0 word, edited as The commands says and echoed through `mon_putc`. → R1 the number of characters. `_io_gets.first` is the same, with R3 a first byte already read, for the monitor's own line. |
| `_io_getc` | → R1 the next byte of the console, which it waits for. The end of the line's input, `0x200`, is no byte, as the keyboard's bytes still come. |

## The commands

At the cold start the monitor clears the screen, prints its banner,
`NiceMon` and the version, and prints a prompt, `> `, on the screen and
on the line. It reads a line from the console: the keyboard and the
line, which the hardware merges. A command is a letter, in either case,
or `baud`, `dir`, `load`, `save`, `del`, or `tftp`, and after `d` and
`u` a hex address and a hex count, each of them optional. DEL and
backspace delete the character before the cursor, CTRL-C empties the
line, and the cursor and function keys, the other control codes, and the
bytes `0x80` to `0x9F` do nothing. RETURN runs the line. A break on
the UART, or a host's half-close over Ethernet, ends the line's input
and not the keyboard's, and the next host to connect over Ethernet can
type again ([SYSTEM.md](../doc/SYSTEM.md#io-registers), `0xFFFFFF00`).

Before the first key of a line, the cursor keys up and down scroll
back through the rows that left the top of the screen a row at a time,
and Page Up and Page Down 24 rows at a time. On the MEGA65 Page Up and
Page Down are CTRL and MEGA with CRSR↑ and CRSR↓, and CRSR↑ and CRSR↓
are the cursor keys, with MEGA or without. Any other key shows
the screen again, and goes on to the line. The history has 384 rows on
the MEGA65 and 77 on the Nexys4DDR. `c` leaves it, as `clear` in a
terminal does, and the cold start empties it. `niceemu` has no display
offset, so there the history is kept but not shown.

| Command | What it does |
|---|---|
| `r [ADDR]` | Runs the program at `ADDR` in hex, or at `0x8000` without it (Programs below), and prints its status when it returns: `Returned 0000002A`. A word of 0 at `ADDR` is no program, and `r` says so: `No program at 00008000`. `r 0` runs entry 0 of the dispatch table, the cold start, so it restarts the monitor and leaves the RAM from `0x8000` alone. |
| `d [ADDR] [N]` | Shows `N` words from `ADDR`, 4 to a row with the row's address first, all in hex. Without `ADDR`, the words after the last shown; without `N`, 32 words. |
| `u [ADDR] [N]` | Disassembles `N` instructions from `ADDR`, a row each: the address, the instruction's 1 to 4 words, and its text, all in hex (The disassembler below). Without `ADDR`, the instructions after the last shown; without `N`, 20. |
| `c` | Clears the screen. |
| `v` | The version of the monitor, and of the dispatch table: `NiceMon V2.1, dispatch table 1.5`. |
| `i [A.B.C.D]` | Shows the Ethernet station's IP address, `IP address 192.168.1.65`, or writes it first: four decimal numbers of 0 to 255 with dots between them, such as `i 192.168.1.65`. Anything but an address or `dhcp` is no address, and `i` says so and writes nothing. It writes `0xFFFFFFB0`, `NET_IP` ([SYSTEM.md](../doc/SYSTEM.md#the-ethernet-station)), so a host connected over TCP loses its connection. In `niceemu` it is a register that keeps what is written. |
| `i dhcp` | Gets the IP address from the network's DHCP server and writes it, as `i A.B.C.D` does, then shows it, with the mask, the gateway, the DNS server, and the DHCP server, a line each (The network below). Without an answer, it prints `No answer from a DHCP server` after about 8 seconds, and leaves the address as it was. |
| `m [MAC]` | Shows the station's MAC address, `MAC address 02:4E:49:43:45:06`, or writes it first: six bytes of one or two hex digits, in either case, with colons between them, such as `m 02:4E:49:43:45:01`. The first byte must be even, as an odd one makes a group address. Anything else is no address, and `m` says so and writes nothing. It writes `0xFFFFFFB1` and `B2`, so a host connected over TCP loses its connection. Each kind of board has its own after reset: `02:4E:49:43:45:03` on the R3, `02:4E:49:43:45:06` on the R6, and `02:4E:49:43:45:0A` on the Nexys4DDR. Two boards of the same kind on one network need different MAC addresses. In `niceemu` they are registers too, `02:4E:49:43:45:00` after reset. |
| `time [YYYY-MM-DD HH:MM:SS]` | Shows the clock of the time of day, `2026-11-11 14:30:00`, or sets it first to the date and the time given, two digits for each part but the year, in the years 1970 to 2105, with blanks around them, such as `time 2026-11-11 14:30:00`. The clock keeps local time, as the MEGA65's real-time clock does, and knows no time zones. After a reset of the system it is not set. The monitor's cold start sets it from the MEGA65's real-time clock, unless the real-time clock lost its time ([SYSTEM.md](../doc/SYSTEM.md#the-i2c-bus)), and leaves a clock that is set already. On the MEGA65, `time` with a date and a time in the years 2000 to 2099 sets the real-time clock too, so that later starts, and the MEGA65's other cores, have the time. Until the clock is set, as on the Nexys4DDR, which has no real-time clock, `time` prints `Clock not set`; a program, a host, or `time` sets it. A start of a program keeps it. Anything else is no time, and `time` says so and sets nothing. A clock that a program set past 2106-02-07 shows as `Clock past 2106`. In `niceemu` the clock is the host's time in UTC from the start. |
| `baud [RATE]` | Shows the UART's baud rate, `Baud rate 230400`, or writes it first: 115200, 230400, 460800, 921600, 1000000, 1500000, or 2000000, in decimal, such as `baud 921600`. Anything else is no rate, and `baud` says so and writes nothing. It writes `0xFFFFFF9F` ([DEBUG_LINK.md](../doc/DEBUG_LINK.md#the-baud-rate)), as the on-board debugger's settings page does. The UART takes the new rate once it has sent nothing for 1 ms, so the answer and the prompt still come at the old rate, and a terminal on the UART then changes to the new one; only a reset brings back 230400. Over Ethernet the rate does not matter. In `niceemu` the word is memory, which reads 0 after a clear. |
| `l` | Enters words into the RAM from lines of `ADDR WORD` in hex, as a `.bin` file has them (Loading without a host below), up to an empty line, and prints the words written and the lines skipped: `Words loaded: 600, 00008000 to 00008257`. |
| `dir [SLOT]` | Lists the folder `NICE` of the SD card's FAT32 file system (Files below): `Directory of NICE`, then a row for each file, its name in 24 columns, the long name where it has one or else the 8.3 name, and its size in decimal, and for each directory, its name and `<DIR>`, then `Files: 25, directories: 1`. A name of 24 characters or more has a row of its own, and the size is on the next. With `SLOT` in hex, it mounts the card in it first; without, it lists the card mounted, which the first `dir` or `load` after reset mounts. An error is shown with its number and meaning: `File error 18, FAT16, which is not supported`. |
| `load NAME` | Loads the `.bin` file `NAME` of the card's folder `NICE` as `l` loads lines, and prints the same summary, so a program copied to the card on a PC loads with no host. Unlike `l`, an empty line is passed over, the end of the file ends the load, and a skipped line is counted from the first line of the file. `NAME` is the long name or the 8.3 name, in either case, in quotes when it has a blank: `load "my prog.bin"`. |
| `save NAME ADDR N` | Writes `N` words from `ADDR`, both in hex, to the file `NAME` of the card's folder `NICE` as a `.bin` file, a line of `ADDR WORD` in hex for each, and prints `Words saved: 600, 00008000 to 00008257`. `NAME` is as for `load`. It makes the file, or truncates it when it is there, and `load` reads it back. When the card fills up, the file keeps what fitted, and `save` prints error 30. |
| `del NAME` | Deletes the file `NAME` of the card's folder `NICE`, its long name or its 8.3 name, as for `load`, with its long-name entries, if it has them, and prints `Deleted NAME`. |
| `tftp IP NAME` | Loads the `.bin` file `NAME` from the TFTP server at the IP address `IP`, such as `tftp 192.168.1.10 hello.bin`, as `load` loads one from the card, and prints the same summary (The network below). `IP:PORT` sends the request to `PORT` instead of 69. It needs an IP address, from `i`. Without an answer, it prints `No answer from the TFTP server` after about 5 seconds; an error of the server is shown with its code and its message: `TFTP error 1, File not found`. |
| `tftp IP [PAT]` | Lists the files of the server `tools/tftpd.py` at `IP` whose names match the pattern `PAT`, with `*` and `?`, such as `tftp 192.168.1.10 *.bin`, a line each with the name and the size; without `PAT`, all of them. Another server answers with an error. |
| `h` | Halts the core, which the reset button, or a host over the link, starts again. The tests end with it. |
| `?` | Lists the commands, and the keys of the history. |

Anything else prints `Unknown command; ? lists them`. The debugger has
pause, step, and inspect, so the monitor adds only `l`, which loads a
program with no host's tools and no storage, `u`, which reads code
with no host. `dir` and `load` read programs from
a card's FAT32 file system, and `save` and `del` write it. `time`
shows the clock, which the dates of the files come from. `i dhcp`
gives a board on a network an address with no host, and `tftp` loads a
program from a server on it.

## Files

The ROM reads and writes FAT32
([doc/SDCARD.md](../doc/SDCARD.md), "The file system") with `fat32.c`,
the ROM's C code ([INTERNALS.md](INTERNALS.md#c-in-the-rom)).

To load a program from a card, make the folder `NICE` in its root on a
PC, copy the `.bin` file into it, and type `dir` and `load NAME` on the
board:

    mkdir /media/card/NICE
    cp build/hello.bin /media/card/NICE/

`save NAME ADDR N` writes a program back, and the ROM never makes the
folder itself, so a card is written only where its user made room.

- **The card** is FAT32 when its sector 0 is a FAT32 boot sector, as
  `mkfs.fat` makes on a whole card, or an MBR whose first partition of
  type `0x0B` or `0x0C` has one. FAT12, FAT16, and exFAT are rejected with
  errors of their own. The type is told by the count of clusters, as
  Microsoft's specification says.
- **The mount**: `fs_mount` mounts the card in a slot. `fs_open`, `dir`,
  and `load` mount the slot of the last mount when there is none, or
  after reset slot 0, or slot 1 when slot 0 has no card. The mount, and
  the files open, are dropped when the selected slot is no longer the
  mounted one, as after a program selects the other slot, or the card
  there is not ready or has changed. A mount of a slot that the system
  does not have changes nothing.
- **The folder `NICE`** of the root directory only. A card may be shared by several cores
  on the MEGA65, each with a folder of its own in the root, so NiceMon
  keeps to its own. A mount fails with error -29 when the root has no
  directory of that name, even when it has a file of it, and the root's
  own files are never reached. The folder's name is set when the monitor
  is built, `make monitor FOLDER=NAME`, an 8.3 name of 1 to 8 letters,
  digits, `_`, and `-`, in either case, which error -29's text names; the
  tests need `NICE`. Deleted entries, `.`, and `..` are passed over.
- **Names** are long names (VFAT) of up to 255 characters, or 8.3
  names, matched in either case: `mandelbrot.bin` and `MANDEL~1.BIN`
  are the same file. A long name is read from the long-name entries
  before a file's 8.3 entry when their numbers and checksum check; a set
  that does not is passed over, and the 8.3 name stands. An 8.3 name
  shows in lower case where its entry says so, as Linux and Windows
  write `hello.bin`. A character of a long name outside ASCII is `?`,
  and such a file is reached by its 8.3 name only.
- **Writing** (mode 1 of `fs_open`) makes the file, or truncates it. A
  new file whose name is an 8.3 name in upper case, or in lower case in
  either part, gets an 8.3 entry only; any other name gets long-name
  entries and an 8.3 alias, as mtools makes them: `mixed.Bin` is
  `MIXED.BIN`, and a name that does not fit, `mandelbrot.bin`, gets a
  tail, `MANDEL~1.BIN`, or `~2` and on when that is taken. A name may
  not have the characters `"*/:<>?\|` or control codes, nor end in a blank
  or a dot (error -20). The long-name entries are written before the 8.3
  entry, so a reset between them leaves orphans, which `fsck.fat`
  removes. Its clusters are taken as its data reaches them,
  and `fs_close` puts its size into its directory entry, so a file is
  finished only when it is closed: a reset in the middle of a write leaves
  at worst clusters that no file has, which `fsck.fat` frees. `fs_delete`
  deletes a file, with its long name, and no directory. A file open to
  write may not be opened again, a file open at all may not be truncated
  or deleted, and a read-only one is not changed. A file written gets the
  date and the time of the clock (`time` above), and a new one as its
  creation too; while the clock is not set, or its year is before 1980
  or after 2106, the date is 2026-01-01 at 00:00.
  FSInfo's count of
  the free clusters is set to unknown, which `fsck.fat` reports as
  uninitialized, and its hint is kept.
- **The caches** are one sector of the FAT, and one for each of the two
  files that may be open at once, in the C code's RAM. The FAT and the
  folder are written through; a file's sector is written when it is full,
  and at `fs_close`.
- **Sectors** are not the HAL's: a program that wants them drives the
  SD controller's registers at `0xFFFFFFA0` itself, which are the same
  on every board and in `niceemu` ([nice_cpu's SYSTEM.md §5](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#5-sd-card)), and calls
  `fs_mount` before it uses the files again.

The entries 9 to 15 and 20 of the dispatch table (above) are its file
API, in the C ABI. A name is one character per word up to a 0 word, and an
address is a word address. An error is negative
([doc/PROGRAMMING.md](../doc/PROGRAMMING.md#the-monitors-error-codes)).

## The network

A program reaches the network through the entries above, UDP's 16 to
19 here and the IP settings, DNS, and TCP of 21 to 31 in TCP and DNS
below, or drives the port for Ethernet frames at `0xFFFFFFC0` itself, which [nice_cpu's
SYSTEM.md §7](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#7-ethernet-frames) specifies, the same on every board and in `niceemu`. The
ROM's own frame routines and its ARP cache, which `i dhcp`, `tftp`, and
the entries use, have no entries in the dispatch table
([INTERNALS.md](INTERNALS.md#the-frame-routines)).

The network of programs is separate from remote control (Remote control
below), but both use the board's one MAC address and one IP address,
those of its Ethernet station
([SYSTEM.md](../doc/SYSTEM.md#the-ethernet-station)). The station
answers ARP for that IP address and pings to it, and serves remote
control on TCP port 4510. Every other frame to the board, UDP to any
port among them, goes to the port for Ethernet frames while a program
or the entries have it enabled. The address that `i` or `i dhcp`
sets serves both.

- The cold start and the return of a program, `mon_exit`, disable the
  port, so a program that does not use the network sees no frame. A
  program that enables it reads the frames itself.
- **DHCP in the background** (issue #126). When the board has no IP
  address at the cold start, as after a reset, the monitor gets one from
  DHCP on its own. It does so only while it waits for the first key of
  a line at its prompt, so a command or a program is never slowed by
  it. The first DISCOVER goes 2 seconds after the cold start, as the
  Ethernet PHY needs that long to bring the link up after a reset. The
  next goes 4 seconds later, and each after it twice as late, up to
  every 64 seconds, plus up to a second more (RFC 2131). The ACK sets
  the address, as `i dhcp` does, and the monitor shows it over its
  prompt, `IP address 192.168.1.253 from DHCP`, and then the prompt
  again. An address from `i`, a program, or a host ends it. A start of
  the core, such as a host's load, keeps the station's address, so it
  starts no exchange when the board has one.
- `i dhcp` enables the port, broadcasts a DISCOVER, and waits 2 seconds
  for an OFFER, then broadcasts a REQUEST of the address offered and
  waits as long for the ACK (RFC 2131). A timeout or a NAK starts again
  from the DISCOVER, up to 4 times; an OFFER or an ACK without an
  address is passed over. When the board has an address already, the
  DISCOVER asks for it, so that the server offers it again. The ACK's
  address is written to `NET_IP` only when it is another, which breaks a
  host's connection over TCP, as `i A.B.C.D` does. So `i dhcp` on a board
  that a host reaches over Ethernet keeps the host's connection when the
  server gives the same address. Then the port is disabled again. The
  frames come from 0.0.0.0, to everyone,
  with the broadcast flag set, and ask for the mask, the gateway, and
  the DNS servers. They name the board to the server, as a router's
  list of stations shows it: the host name is `nicemon-` and the last
  three bytes of the MAC address, such as `nicemon-434506`, and the
  vendor class is `NiceMonMEGA65` and the monitor's version, such as
  `NiceMonMEGA65 V2.1`. The transaction's number is the microsecond counter
  at the start, XOR the low word of the MAC address. The lease is
  kept, and renewed while the monitor waits at its prompt, and by a
  program's polls while the network is on, as `net_poll` has it. A
  program that does not use the network renews nothing, so a board
  that runs one longer than its lease may have its address given to
  another station.
- `i dhcp` keeps the mask and the gateway of the ACK, which UDP uses
  below, and the first DNS server, which it shows; `i A.B.C.D` and the
  cold start set the three to none, and forget the lease.

The UDP endpoint is the entries 16 to 19 of the dispatch table (above),
so that a program, such as a game of two boards, or a BASIC interpreter,
needs no network stack of its own. They are in the C ABI, and the data
of a datagram is one byte per word, bits 7..0, as the file entries have
it:

- **One endpoint**, one local port, which `udp_open` opens and enables
  the port for Ethernet frames, with its queue emptied if the port was
  disabled, and `udp_close` closes, with the port disabled unless a TCP
  handle is open. The cold
  start and a program's return close it too. Port 0 picks one from 49152
  to 65535.
- **Sending**: a datagram goes to its address, through the gateway when
  the mask puts the address in another network, and to everyone for
  255.255.255.255, after the ROM's ARP finds the MAC address. It is IPv4
  with no options, and with the UDP checksum 0, none, as IPv4 allows; up
  to 1472 bytes, which fill a frame. A router on a path with a smaller
  MTU may fragment it: the "don't fragment" bit is clear, and each
  packet has an identification of its own, one more than the one before.
- **Receiving** does not wait. The ROM polls the queue in every UDP
  entry, and in its own waits: it takes the frames that wait, up to 4,
  and holds one datagram to the endpoint's port of the station's
  address or 255.255.255.255. `udp_recv` returns that datagram, or 0
  when none is held. The other frames are released unread, so a
  program that also wants other frames drives the port itself. An empty
  datagram, a fragment, and IP options are passed over. A datagram that
  comes while one is held is dropped: a program reads the one held
  before the next poll, or loses the next. A call with no room, 0 bytes,
  copies nothing and leaves the datagram held, so no datagram is lost to
  it. The queue holds 4 frames
  ([nice_cpu's SYSTEM.md §7](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#7-ethernet-frames)), so a program that receives a burst reads it
  soon.

An error of the UDP entries is negative
([doc/PROGRAMMING.md](../doc/PROGRAMMING.md#the-monitors-error-codes)).

`tftp IP NAME` reads a file of a TFTP server (RFC 1350), in octet mode,
through the endpoint, which it opens on a port of its own choice and
closes at the end. The RRQ goes to port 69, or to `PORT` of `IP:PORT`,
and the server's first DATA
gives the port that the rest come from; packets of other hosts and
ports are passed over. Each DATA is answered with its ACK, a DATA of the
block before with the ACK again, and a block of less than 512 bytes is
the last. A packet with no answer within a second is sent again, up to
5 times in all. The lines are taken as `load` takes those of a file, and
the words written as `l` writes them.

A `NAME` with `*` or `?` is a pattern, and no `NAME` is `*`: the lines
received are shown instead of loaded. The repository's own server,
`tools/tftpd.py`, answers a pattern with a listing of the files of its
folder that match it, a line each with the name and the size in bytes,
which no other server does. To serve the examples from a PC:

    make tftpd

It serves `examples/build`, the folder of `make examples`, or with
`TFTP_DIR=FOLDER` another folder, its regular files and nothing else.
Port 69 needs root, or the capability that `tools/tftpd.py --help`
gives; without either, `make tftpd TFTP_PORT=6969` serves on port
6969. On the board, `i dhcp`, then
`tftp 192.168.1.10 *.bin` lists the programs, and `tftp 192.168.1.10
hello.bin` loads one, with the PC's address, and `:6969` after it for
the other port. Any other TFTP server, such as `tftpd-hpa`, serves the
files too, but answers a pattern with an error.

## TCP and DNS

The entries 21 to 31 (table 1.5, issue #111) give a program the IP
settings, DHCP, DNS, and TCP: up to 4 connections at once, which the
board opens to a server, or which a peer opens to a port where the
board listens. A program that needs them checks that `mon_version` is
`0x00010005` or more at its start, and stops with a message on an
older monitor. Libraries such as HTTP or JSON are the program's.

**The addresses.** These entries take addresses through the byte
windows ([SYSTEM.md](../doc/SYSTEM.md#the-byte-windows)), so that a
buffer of bytes is packed, 4 to a word, as a C program has it:

- A word address, of the 4 words of `net_config` and `net_set`, the
  result of `dns_lookup`, and a control block, is a plain address, or
  one of the word window, `0x10000000 + 4*W` for word W.
- A byte address, of a name and of the buffers of `tcp_send` and
  `tcp_recv`, is one of the byte window, `0x20000000 + 4*W + b` for
  byte b of word W, bits 8b+7 to 8b, so a buffer may start at any byte.
  An assembly program passes `0x20000000 + 4*W` for a buffer at word W.
- An IP address is a word, its first byte in bits 31..24, as `NET_IP`
  has it.

A C program declares the entries with `mon.h`, which takes C's own
pointers, and is built with `nicebuild.py --monitor --asm mon.nasm
--asm mon_c.nasm`. `mon_c.nasm` has the stubs that turn a pointer into
an address of the windows, as only assembly knows where the program's
memory is.

**The poll.** The network moves only when the program calls an entry
of the network; there are no interrupts. `net_poll` takes the frames
that wait, and sends the ACKs, the retransmissions, and the lease's
renewal that are due. The other entries of the network poll too. So:

- A program that has a connection open, a handle listening, or the UDP
  endpoint open calls `net_poll` every 100 ms or so. Between polls the
  board answers nothing, and the 4 frames of the queue fill with the
  peer's copies.
- It waits for a key in a loop of `nice_pollc` and `net_poll`, never
  with `getchar` or `nice_getc`, which wait and do not poll.
- The file entries do not poll, so a program reads or writes a large
  file in parts, with a poll between them.
- `net_dhcp`, `dns_lookup`, and the ARP of `tcp_open` and `udp_send`
  wait, and poll while they wait.
- A connection that is not polled stalls first, and breaks in the end:
  the peer's next retransmission may be minutes away, and Linux gives up
  after about 15 minutes.

**The settings.** `net_config` gives the IP address, the mask, the
gateway, and the DNS server, and `net_set` sets them, each 0 for none.
`net_dhcp` gets them from a DHCP server, as `i dhcp` does, with the
first DNS server of the reply, and keeps the lease. While the network
is on, the poll renews the lease: from half its time by unicast to the
server, about every minute, then from 7/8 of it by broadcast, until its end.
An ACK of another address writes `NET_IP`, which breaks a host's
connection over TCP. After a NAK, or at the lease's end, the address
stays, and nothing is renewed.

**DNS.** `dns_lookup` asks the DNS server for the A record of a name,
one question to port 53, sent again after 2 seconds, 3 times in all. It
takes the first A record of the answer, past any CNAMEs. A name of four
decimal numbers with dots, `192.168.1.10`, is taken as it is, with no
query. A name has labels of 1 to 63 bytes, 253 bytes in all, and may
end in a dot. There is no cache, so a program keeps the address it got.

**A connection** lives in a control block in the program's RAM: 32
words, then the ring of the bytes received and the ring of the bytes to
send, packed, so `TCP_CB_WORDS(rx, tx)` of `mon.h` words in all. Its
address in the word window has bits 1..0 clear, or `tcp_open` and
`tcp_listen` give `E_TSIZE`. The block is the
ROM's from `tcp_open` or `tcp_listen` until `tcp_state` gives
`TCP_FREE`, and the program does not touch it meanwhile. `tcp_state`
gives the state:

| State | Value | What it means |
|---|---|---|
| `TCP_FREE` | 0 | The handle is free. |
| `TCP_CONNECTING` | 1 | The handshake. Bytes that `tcp_send` takes go after it. |
| `TCP_OPEN` | 2 | Bytes go both ways. |
| `TCP_PEER_CLOSED` | 3 | The peer has closed. The program reads what is left, then gets `E_TEOF`, and may still send. |
| `TCP_CLOSING` | 4 | After `tcp_close`. The handle frees itself. |
| `TCP_LISTEN` | 5 | A handle of `tcp_listen`, until a peer connects. |
| an error | negative | The connection ended, such as `E_TRESET`. `tcp_close` frees the handle. |

- **Opening.** `tcp_open` sends the SYN from a local port of 49152 to
  65535, 4 times in 15 seconds, then the connection ends in
  `E_TTIMEOUT`; a RST ends it in `E_TREFUSED`.
- **Listening.** `tcp_listen` makes a handle in `TCP_LISTEN`. The first
  SYN to its port takes it, through `TCP_CONNECTING`, to `TCP_OPEN`: one
  connection for each handle. A program that wants to serve two peers
  at once listens with two handles on the same port. A SYN that comes
  while every handle of the port is busy is passed over, and the peer
  sends it again; a SYN to a port where nothing listens gets a RST. Port
  4510 is the station's, for remote control, so `tcp_listen` gives
  `E_PORT` for it.
- **Sending and receiving** never wait. `tcp_send` takes what fits into
  the ring, and the poll sends it in segments of up to 1460 bytes, as
  far as the peer's window and the congestion window let it, and sends
  it again after a timeout, from 200 ms to 60 s, measured from the
  round trips. After 120 s with no answer the connection ends in
  `E_TTIMEOUT`. `tcp_recv` takes from the ring received. Each
  connection announces a window of at most the free room of its ring,
  and 4096 bytes divided by the number of connections, so that together
  they announce about 4096 bytes, as the queue holds only 4 frames.
- **Closing.** `tcp_close` with 0 ends both directions: the bytes that
  wait to be read are dropped, and so are those that come later, and
  `tcp_recv` gives `E_TCLOSED`. The FIN goes after the bytes that wait
  to be sent, and the handle frees itself once the peer has
  acknowledged it and sent its own FIN, or 60 s after the
  acknowledgment, or when the sends give up. With 1 it sends a RST and frees the handle at once. A
  close of a handle in `TCP_LISTEN`, or of one with an error, frees it
  at once and sends nothing. There is no TIME-WAIT.
- **The cold start and a program's return** send a RST for each
  connection, free every handle, close the endpoint, and disable the
  port. They trust a control block only by its first word, which the
  ROM writes, so a block that a new program overwrote is just freed.

The errors are those of UDP, -40 to -44, and -45 to -57
([doc/PROGRAMMING.md](../doc/PROGRAMMING.md#the-monitors-error-codes)).
The entries run on the program's stack. The deepest, `tcp_recv`, takes
24 words of it with the return address, `dns_lookup` 15, and `net_dhcp`
11, as measured in the tests in `niceemu` on 2026-11-14, within the 32
words of Programs below.

## The disassembler

`u` shows each instruction as nice_cpu's `assembler/nicedis.py` and
`mon.py` do, so the three disassemblers agree, but for the
pseudo-instructions below, which only `u` shows:

    > u 8000 5
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

## Programs

- A program for the monitor is assembled at `0x8000`, with nice_cpu's
  `start_mon.nasm`, `start_wasm_mon.nasm`, or `start_wasm_trap_mon.nasm`
  in place of its start-up files at 0 (`nice_cpu/runtime/ABI.md`,
  "Programs under a monitor"), and `nicebuild.py --monitor` builds a C,
  Zig, or Rust program so. `test/hello.nasm` and `test/hello.c` are two
  such programs, and the Makefile shows how they are built.
- The monitor runs a program as a subroutine on its own stack: it pushes
  a return address and jumps to `0x8000` with E = 0, R1 = the address of
  `mon_putc`'s entry, and R2 = 0 and R3 = 0, `argc` and `argv` for a
  command line later. The start-up code stores R1 in `___putc_vector`, so
  `nice_putc`, `nice_print`, the C library's `printf`, and the trap report
  print through `mon_putc`. The program returns when `main` returns,
  through `exit`, or with `RET` on the SP of the entry. The monitor then
  relies on SP and R1, the status, and on nothing else, and restores the
  rest as at `mon_exit` (The dispatch table above).
  `nice_cpu/runtime/test/monitor.nasm`, the stand-in for the monitor in
  nice_cpu's own tests, does the same.
- A program may use the RAM from `0x8000` up to, but not including, the
  SP it was called with, and must leave room below that for the stack it
  shares with the monitor. That is `0x8000`–`0x1EFFF`, 92K words, on the
  MEGA65, and `0x8000`–`0xEFFF`, 28K words, on the Nexys4DDR, as the
  monitor's variables are the top 4K words of the RAM. A program learns
  the size of the RAM from `0xFFFFFF9E`
  ([SYSTEM.md](../doc/SYSTEM.md#io-registers)), which reads 0 in
  `niceemu`, where the memory has no limit. The monitor's routines use
  at most 32 words of the stack when a program calls them. The stack is
  in use before the program runs: `r` pushes its return address at the
  top word, `0x1EFFF` or `0xEFFF`, and `l`'s own summary reaches 13
  words below it. `l` and `load.py --monitor` take a word there, which
  is then overwritten, as any word in the room the stack needs is.
- A program runs once per load: the load initializes its static data and
  its wasm linear memory. A wasm trap halts the core, as in nice_cpu,
  after the trap report's line on the monitor's output; the on-board
  debugger then has the state, and the reset button boots the monitor
  again.

## Remote control

A host, over the board's Ethernet port or its UART, controls the board
with the tools of [tools/](../tools/README.md): it holds, starts,
pauses, and steps the core, and reads and writes the memory. While the
monitor runs, the link reaches only its debug registers, so the tools
hold the core first. They also hide the ROM, so that a program at 0 runs
as in the emulator, and the reset button boots the monitor again. With
`--monitor`, `load.py` and `run.py` keep the ROM, load a program at
`0x8000`, and run it under the monitor:

    tools/load.py --eth 192.168.1.65 --monitor prog.bin

The tools' README has the details, in [Running a program under the
monitor](../tools/README.md#running-a-program-under-the-monitor).

## Loading without a host

`l` loads a program that is typed on the keyboard, or pasted into a
terminal on the line, with no tools on the host and no storage. It reads
lines of `ADDR WORD`, two hex numbers of 1 to 8 digits with blanks or
tabs between them, which is what a `.bin` file has ([nice_cpu's ISA.md
§10.4](https://github.com/MJoergen/nice_cpu/blob/main/doc/ISA.md#104-object-format)), and writes each word. CR, LF, and CR LF end a line, the `l`
line itself too. An empty line ends the load, and so does CTRL-C, which
drops the line it is in; a line of blanks only is passed over, as
`niceemu` passes it. DEL and backspace delete, and the cursor and
function keys do nothing. A line with anything else, one longer than 76
characters, or one with an address outside a program's RAM, `0x8000` to
`0x1EFFF` on the MEGA65 and to `0xEFFF` on the Nexys4DDR (Programs
above), is skipped: the RAM repeats through the address space, so a
larger address could reach the ROM or the monitor's variables and
stack. The top of that range is the stack itself, which `r` uses, so a
program's words stay below it. A second line for an address writes its
word over the first's, where `niceemu` rejects the file. In `niceemu`,
where `0xFFFFFF9E` reads 0, the program's RAM goes up to the screen,
`0xFFFEFFFF`. Its font RAM at `0xFFFE0000`–`0xFFFE1FFF` keeps
only bits 15..0 of a word, and its character ROM at
`0xFFFE2000`–`0xFFFE3FFF` drops one, so a program there does not read
back as loaded. At the end `l` prints the number of words written, with
the lowest and the highest address, and the number of lines skipped,
with the first of them and the last address that a line may have:

    Words loaded: 601, 00008000 to 00009000
    Lines skipped: 4, first line 2; ADDR WORD in hex, ADDR 00008000 to 0001EFFF

The lines are shown in one row of the screen, which each line clears,
and not on the line, so the screen does not scroll, and a paste over the
UART at 2 Mbaud keeps up: a line takes about 1400 instructions, and
arrives in about 90 µs. On the R6, 20600 lines pasted at full speed, in
LF lines and in CR LF lines, were all written, with no byte lost.

Over Ethernet, a paste into a plain client, such as
`nc 192.168.1.65 4510`, keeps up too. The station takes the host's
bytes at 100 Mbit/s, faster than `l` reads them, but a byte that finds
the core's input FIFO of 2048 bytes full waits up to 50 ms for room,
and TCP holds the host back meanwhile. A byte is lost, with the link's
`o`, only when the program reads nothing for 50 ms. On the R6, 20600
lines pasted at full speed over TCP, in LF lines and in CR LF lines,
and through `nc`, were all written, with no byte lost, in about 0.7 s.
`load.py --eth 192.168.1.65 --monitor prog.bin` (Remote control above)
is faster, as it writes the words into the memory.

## The demo

The demo is nice_cpu's, built with the boards' text
([demo/](../demo/README.md)). It is a program at `0x8000`, `demo.bin`,
which each release has as a file of its own. Copied into the card's
folder `NICE`, `load demo.bin` and `r` run it, and its F12 returns to the
monitor with `Returned 00000000`. `tftp` loads it too, and so does
`tools/load.py --monitor`. Up to V2.0.1 it was in the ROM, behind the
monitor, and the command `x` ran it; it left the ROM to make room for
the network of #111 and for BASIC (#129).
