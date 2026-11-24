# monitor

- [Hardware abstraction layer](#hardware-abstraction-layer)
  - [The dispatch table](#the-dispatch-table)
  - [The shared routines](#the-shared-routines)
- [Files](#files)
- [The network](#the-network)
- [TCP and DNS](#tcp-and-dns)
- [Programs](#programs)
- [Remote control](#remote-control)
- [The demo](#the-demo)

The ROM at `0x0000`–`0x7FFF`, which the core boots from, holds:

- a hardware abstraction layer, the HAL, of forty-two routines that reach
  the hardware or the state the monitor keeps, called through a dispatch
  table at the start of the ROM. It is not a library: what a program can
  do for itself stays in the program.
- BASIC, whose stage 1 is the shell with the monitor's commands as
  statements, an image of its own at `0x3000`, which
  [basic/README.md](../basic/README.md) describes.

The rest of the ROM is free. The demo is not in the ROM: it is a
program of its own (The demo below).

At the first cold start after the FPGA's configuration, the monitor
may put another BASIC into BASIC's part of the ROM, `0x3000`–`0x7FFF`: a file whose name
matches `BASIC*.ROM`, in the folder `NICE` of a card. It takes the one
with the highest version that passes its checks, and prints its name.
Then BASIC's part is locked until the next configuration
([doc/BASIC_ROM.md](../doc/BASIC_ROM.md)). It reads no card when a
host has already loaded a program at `0x8000`: the program stays, and
the ROM's own BASIC runs it.

The monitor's variables are in the RAM at `0xFFFFF000` and up, BASIC's
below them, as many words as its image's header says, 2K words at
`0xFFFFE800` for the build's BASIC, and the stack grows down from
there ([SYSTEM.md](../doc/SYSTEM.md#stack-heap-and-variables)).

## Hardware abstraction layer

A program under the monitor sees three levels, which
[doc/PROGRAMMING.md](../doc/PROGRAMMING.md) describes for
those who write programs:

1. **The hardware**: the I/O registers of
   [doc/SYSTEM.md](../doc/SYSTEM.md) and nice_cpu's DEVICES.md, the same
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
   other, and `cat rom.bin prog.bin` runs it with a program at
   `0x8000`, for a `.bin` file is address and word pairs.
3. **The library**: the routines of `monlib.nasm` (The shared routines
   below), and the stubs of `mon.nasm`, which are joined to a program
   when it is built, so they are in its image only when it joins them.
   There is no linker, so a program that joins a file has all of it.

The ROM also has routines of its own, which have no entries and which
programs do not call: the sector routines of the SD cards, the frame
routines and the ARP cache of the network, and FAT32.
[INTERNALS.md](INTERNALS.md) describes them, with the build and the
tests.

The monitor and BASIC are in NICE assembly. The ROM is two images,
assembled apart (#152): the monitor's at `0x0000`, and BASIC's at
`0x3000`, from the files of [../basic](../basic). BASIC calls the
monitor through the entries of the dispatch table alone, as a program
does, and the monitor jumps to BASIC through two vectors alone, at
`0x3000`, its cold start, and `0x3002`, its warm start. Neither image
has a label of the other. The monitor's image is its files in this
order, and [INTERNALS.md](INTERNALS.md#the-roms-words) has the words of
each, and the words that are free:

| File | What it is |
|---|---|
| `monitor.nasm` | The dispatch table, the HAL, the screen, and the line with its scrollback |
| `monitor_sd.nasm` | The routines for the SD cards |
| `monitor_fat.nasm` | FAT32: the file entries, and TAB |
| `monitor_eth.nasm` | The routines for the network: the frames, ARP, UDP, DHCP, and DNS |
| `monitor_tcp.nasm` | TCP |
| `monitor_clock.nasm` | `clock_set`, the dates of files, and the real-time clock |
| `monitor_basic.nasm` | The load of BASIC's image from a card's `BASIC*.ROM` at the first cold start |
| `common.nasm` | What the monitor and BASIC share: the devices' addresses, the packed texts, IP addresses, and the conversions of dates |
| `monlib.nasm` | The routines that programs join, which the statements use too |
| `mon.nasm` | The stubs through which a program calls the entries |
| `build/version.nasm` and `build/folder.nasm` | The version and the card's folder, which the Makefile writes |

BASIC's image is the files of [../basic](../basic/README.md#building),
then its own copies of `common.nasm`, `monlib.nasm`, `mon.nasm`, and
the version.

`mon.h` has the entries' declarations for C, and is no part of the ROM.
Each image has a RAM of its own: the monitor's at `0xFFFFF000`, and
BASIC's below it, at `0xFFFFE800` for 2K words.

`make -C monitor` builds the monitor's image,
`build/monitor_image.bin`, and `make rom` at the top joins it with
BASIC's into the ROM, `build/rom.bin`. `make -C monitor test` runs the
ROM of the tests in `niceemu`, with the tests of the monitor's code,
and `make -C ../basic test` with those of BASIC's statements
([INTERNALS.md](INTERNALS.md#building-and-testing)).
The QNICE monitor (QMON) of
[QNICE-FPGA](https://github.com/sy2002/QNICE-FPGA) is the inspiration,
not the model.

### The dispatch table

Each entry is one `JMP routine`, two words, so entry n is at address
2n, and entry 0 is the reset. A program calls entry n as it calls any
routine, `CALL 2n`, through the names that `mon.nasm` gives: an `.EQU`
for each entry, such as `MON_PUTC` and `SCR_CLS`, and a stub for each,
such as `_mon_putc  JMP MON_PUTC` and `_mon_scr_cls  JMP SCR_CLS`. Every
stub starts with `_mon_`, so that it clashes with none of a program's
labels. The stubs of the entries 5 to 31, `scr_cls` to `tcp_listen`, have a
second name without `mon_`, such as `_scr_cls`, for the programs that
call them by it. Entries are only ever added at the end, never
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
which the ROM's own statements use too, and C programs have nice_cpu's
`libc`. The ROM's routines could not serve C anyway, for a C string is
bytes packed four to a word in wasm's linear memory
(`nice_cpu/translator/WASM.md`), and libc must run in `niceemu`, which
has no ROM.

The routines follow the C ABI of `nice_cpu/runtime/ABI.md`: arguments in
R1–R4, the result in R1, R1–R6 changed, and R7–R13 kept. A C program for
the monitor declares them with `mon.h`, and is joined with the stubs of
`mon.nasm` (`nicebuild.py --monitor --asm mon.nasm`), as the translator
makes a call to the `env` import `mon_putc` a call to `_mon_putc`, and
one to `mon_scr_cls`, the entry `scr_cls`, a call to `_mon_scr_cls`. For
C, `mon.nasm` also has `_mon_scr_getx` and `_mon_scr_gety`, as
`scr_getxy` returns two values. Such a program runs only with the ROM visible, as
every program built at `0x8000` for the monitor does.

VBASE is 0 at reset and stays 0. The monitor has no interrupts of its
own, as the debugger is hardware and the board has no NMI source, and it
keeps E at 0, so the vector table that would overlap the dispatch table
is never read. A program that wants interrupts sets VBASE to a page of
its own image, and the monitor clears E, stops the timer, and sets VBASE
back to 0 at every return. It sets the font base and the mode word back
to 0 then too, so that the screen shows text in Spleen, and leaves the font RAM as the program left
it. It also shows the cursor again, blinking, and turns the display
offset off, as a program may have hidden the one or used the other. And
it empties the FPU's stack and clears its flags, so that the next
program starts with none of the values that this one left there.

| # | Addr | Name | Arguments → result |
|---|---|---|---|
| 0 | `00` | `mon_reset` | Cold start: E, the timer, the FPU, VBASE, the font base, and the mode word cleared, the stack, the variables, the screen, the clock of the time of day from the MEGA65's real-time clock while it is not set, the banner, BASIC's main loop. The RAM from `0x8000` is left alone. |
| 1 | `02` | `mon_exit` | R1 a status. Back to BASIC's main loop with a fresh stack, with E, the timer, the FPU, VBASE, the font base, and the mode word cleared, the cursor shown and blinking, the display offset off, and the status printed where the program left the cursor, on a new line if that is not column 0; for a program that has not kept the SP of its entry. A program with the runtime's start-up code returns or calls `exit` instead, which lands here too. |
| 2 | `04` | `mon_version` | → R1 the version of the table, major in bits 31..16, minor in 15..0: `0x00010008`, 1.8. |
| 3 | `06` | `mon_putc` | R1 a character, to the outputs `mon_out` selects. On the screen it goes at the cursor, which moves on, to the next row after the last column; CR moves the cursor to column 0, LF to column 0 of the next row, BS one back, and TAB to the next multiple of 8; the other control codes and `0x7F` do nothing, and `0x80` to `0x9F` go on the screen as any character, the blocks and arrows of the character ROM at `0x80` to `0x99`, blank at `0x9A` to `0x9F`, and drawn from the font RAM when a program selected it; past the last row the rows move up by one, by copying, so the rows shown are always the 2240 words at `0xFFFF0000`, as in `niceemu`. It keeps the word of `scr_links`: a wrap past the last column links the next row to its row, and a LF does not. A character that goes to column 0 of a row makes that row a line of its own, unless the cursor came there by that wrap: so a row written again from its start, after `scr_moveto` or a CR, is not part of the line above it. On the line every byte goes as it is. |
| 4 | `08` | `mon_out` | R1 the outputs: bit 0 the line, bit 1 the screen; both at reset. → R1 the old ones. |
| 5 | `0A` | `scr_cls` | Clears the screen in the current color, cursor home, shown and blinking, display offset 0, and the word of `scr_links`. |
| 6 | `0C` | `scr_moveto` | R1 the column, R2 the row; a column past 79 is 79, and a row past 27 is 27. A character put at column 0 after it starts a line of its own for `scr_links`, also where a wrap had left the cursor, since V2.4.1. |
| 7 | `0E` | `scr_getxy` | → R1 the column, R2 the row. |
| 8 | `10` | `scr_color` | R1 the color for later characters, bits 31..8 of a screen word. → R1 the old one. The `MON_FG_` and `MON_BG_` colors of `mon.h` and `mon.nasm`, added: `MON_FG_YELLOW+MON_BG_BLUE`. |
| 9 | `12` | `fs_mount` | R1 a slot. Mounts its card, and closes the files that were open (Files below). → R1 0, or an error. Table 1.1. |
| 10 | `14` | `fs_open` | R1 a name, R2 a mode: 0 to read a file of the folder `NICE`, 1 to write one, which is made or truncated (table 1.2), 2 for a folder: `NICE` itself, whose name is empty or `/`, or one inside it by its path. The name is a long name or an 8.3 name, in either case (table 1.4), and may be a path, `GAMES/CHESS.BIN` (Files below). Mounts a card when none is. → R1 a handle, 0 or 1, or an error. Table 1.1. |
| 11 | `16` | `fs_read` | R1 a handle of a file, R2 a buffer, R3 a number of bytes. Reads up to that many, one byte per word. A chain of clusters shorter than the file's size gives the bytes up to its break, and error -26 at the next call. → R1 the number read, 0 at the end, or an error. Table 1.1. |
| 12 | `18` | `fs_readdir` | R1 a handle of a directory, R2 a buffer of 4 words. The next entry: in words 0 to 2 the 11 bytes of its 8.3 name, padded with blanks, and its attributes, as FAT has them, 4 bytes to a word from bits 7..0, and in word 3 its size. An entry made or deleted while the handle is open is seen when the handle has not passed it. → R1 1, 0 at the end, or an error. Table 1.1. |
| 13 | `1A` | `fs_close` | R1 a handle. Finishes a file opened to write: its last sector, and its size in its directory entry. The handle is closed also after an error. → R1 0, or an error. Table 1.1. |
| 14 | `1C` | `fs_write` | R1 a handle of a file opened to write, R2 a buffer, R3 a number of bytes, one per word, bits 7..0. → R1 the number written, fewer when the card is full, or an error. Table 1.2. |
| 15 | `1E` | `fs_delete` | R1 a name, as for `fs_open`, or a path. Deletes the file of the folder `NICE`, or of the folder that the path names, with the long-name entries right before its entry, also those whose checksum does not fit it, which are orphans. A damaged chain that meets a free cluster ends there, so the file is deleted, and the clusters that it had after the break stay taken, which `fsck.fat` reclaims; the truncation of `fs_open` does the same. → R1 0, or an error. Table 1.2. |
| 16 | `20` | `udp_open` | R1 a local port, or 0 for one of 49152 to 65535. Opens the UDP endpoint, and enables the port for Ethernet frames (The network below). → R1 the port, or an error. Table 1.3. |
| 17 | `22` | `udp_send` | R1 an IP address, R2 a port, R3 a buffer, R4 a number of bytes, one per word, up to 1472. Sends them as a datagram. → R1 0, or an error. Table 1.3. |
| 18 | `24` | `udp_recv` | R1 a buffer, R2 a number of bytes, R3 the address of 2 words, or 0. Does not wait. Copies up to that many bytes of the next datagram, one per word, and its source's IP address and port to the 2 words; with R2 0 copies nothing, and leaves the datagram waiting. → R1 the bytes copied, 0 when none waits, or an error. Table 1.3. |
| 19 | `26` | `udp_close` | Closes the endpoint, and disables the port for Ethernet frames. → R1 0. Table 1.3. |
| 20 | `28` | `fs_readname` | R1 a handle of a directory, R2 a buffer of 4 words, R3 a buffer of 256 words. The next entry, as `fs_readdir` gives it, and its name in R3's buffer, one character per word up to a 0 word: its long name, or else its 8.3 name as a name, `HELLO.BIN`, in lower case where the entry says so. A character of a long name outside ASCII is `?`. → R1 1, 0 at the end, or an error. Table 1.4. |
| 21 | `2A` | `net_config` | R1 the word address of 4 words. Writes the IP address, the mask, the gateway, and the DNS server to them, each 0 for none (TCP and DNS below). → R1 0. Table 1.5. |
| 22 | `2C` | `net_set` | R1 the word address of 4 words, as `net_config` gives them. Sets the four, for a network with no DHCP, and forgets the lease. A new IP address breaks a host's connection over TCP, as `IP "A.B.C.D"` does, and ends every TCP connection of the program in `MON_E_TRESET`. → R1 0. Table 1.5. |
| 23 | `2E` | `net_dhcp` | What `DHCP` does, printing nothing: the address, the mask, the gateway, the DNS server, and the lease. With an address set, it asks for that one. Waits up to 16 seconds. → R1 0, or an error. Table 1.5. |
| 24 | `30` | `net_poll` | Takes the frames that wait, and sends what is due: ACKs, retransmissions, and the lease's renewal. Never waits. A program that uses the network calls it every 100 ms or so. → R1 not negative, of no meaning yet. Table 1.5. |
| 25 | `32` | `dns_lookup` | R1 the byte address of a name, up to a 0 byte, R2 the word address of the result. Writes the name's IPv4 address to the word at R2. A name of four decimal numbers with dots is taken as it is. Waits up to about 9 seconds. → R1 0, or an error. Table 1.5. |
| 26 | `34` | `tcp_open` | R1 the word address of a control block, R2 an IP address, R3 a port, R4 the sizes of the rings in bytes, to receive in bits 31..16 and to send in 15..0, each 64 or more. Opens a connection: waits up to 3 seconds for ARP, sends the SYN, and does not wait for the answer. → R1 a handle, 0 to 3, or an error. Table 1.5. |
| 27 | `36` | `tcp_state` | R1 a handle. → R1 its state, `MON_TCP_FREE` to `MON_TCP_LISTEN`, or the connection's error. Table 1.5. |
| 28 | `38` | `tcp_send` | R1 a handle, R2 the byte address of a buffer, R3 a number of bytes. Takes as many as fit into the ring to send, and sends what the windows let go. → R1 the bytes taken, 0 when none fit, or an error. Table 1.5. |
| 29 | `3A` | `tcp_recv` | R1 a handle, R2 the byte address of a buffer, R3 a number of bytes. Copies up to that many of the bytes received. → R1 the bytes copied, 0 when none wait, `MON_E_TEOF` once the peer has closed and every byte is read, or an error. Table 1.5. |
| 30 | `3C` | `tcp_close` | R1 a handle, R2 0 to close, or 1 to abort. A close sends the bytes that wait, then the FIN, and the handle frees itself later; an abort sends a RST and frees it at once. → R1 0, or an error. Table 1.5. |
| 31 | `3E` | `tcp_listen` | R1 the word address of a control block, R2 a local port, 1 to 65535 but 4510, R3 the sizes of the rings, as R4 of `tcp_open`. Makes a handle that waits for a peer to connect to the port. Sends nothing, and does not wait. → R1 a handle, 0 to 3, or an error. Table 1.5. |
| 32 | `40` | `con_getline` | R1 the word address of a buffer, R2 a number of characters. Reads a line typed on the console into it, one character a word, up to that many and a 0 word after them, so the buffer has R2 + 1 words: BASIC's line, with its keys ([basic/README.md](../basic/README.md#the-statements)), the scrollback's before it, and TAB, which completes the name of a file of the card's folder. While it waits for the first key, it keeps the network going, as BASIC's line does. → R1 the number of characters. Table 1.6. |
| 33 | `42` | `bin_line` | R1 the word address of a line, one character a word up to a 0 word, R2 the word address of 7 words, which the program clears before the first line of a load. Parses a line of a `.bin` file, `ADDR WORD` in hex, and writes the word, when the address is in a program's RAM, below the stack's first 1K words, as `LOAD` does ([basic/README.md](../basic/README.md#loading-without-a-host)). The 7 words count: the words written, the lowest and the highest address written, the lines skipped, the number of the first, and the lines, and the last is the end of a program's RAM, which it writes. → R1 1 when the word was written, 0 for a line of blanks only, or -1 when the line was skipped. Table 1.6. |
| 34 | `44` | `clock_set` | R1 the seconds since 1970, R2 the microseconds. Sets the clock of the time of day, as `TIME` does, and on the MEGA65 the real-time clock too, in the years 2000 to 2099. → R1 0. Table 1.6. |
| 35 | `46` | `net_servers` | R1 the word address of 2 words. Writes the DHCP server of the last exchange and the NTP server that DHCP gave to them, each 0 for none. → R1 0. Table 1.6. |
| 36 | `48` | `mon_restore` | The state after a program, for a program that runs another, as `SYS` does: E, the timer, the FPU, VBASE, the font base, and the mode word cleared, the network closed, and the cursor shown and blinking where the program left its registers, with the display offset off. When the program left them elsewhere than `mon_putc` and `scr_moveto` had the cursor, it wrote the screen itself, and the word of `scr_links` is cleared. What is put next at a row's column 0 starts a line of its own, also where a wrap of the program's left the cursor, since V2.4.1. → R1 0. Table 1.6. |
| 37 | `4A` | `mon_build` | → R1 the word address of the monitor's version, a packed text, four characters a word up to a 0 byte, such as `V2.5.1`, for BASIC's banner. Table 1.7. |
| 38 | `4C` | `con_key` | R1 the flags: bit 0 waits for a key, bit 1 shows an address that DHCP gets meanwhile, as BASIC's empty line does. → R1 the next byte of the console, or -1 when none waits and bit 0 is 0. While it waits, it keeps the network going, as `con_getline` does. Table 1.7. |
| 39 | `4E` | `scr_back` | R1 a number of rows: the scrollback that many rows further back when it is above 0, forward when below 0, and the screen again when it is 0 or reaches the screen. → R1 the rows shown back now, 0 for the screen. Table 1.7. |
| 40 | `50` | `fs_complete` | R1 the word address of a line, one character a word, R2 that of the cursor in it, and R3 that of the word after the last that the line may take. TAB on that line, as `con_getline` has it: completes the name of a file or a directory of the card's folder before the cursor, or of the folder that its path names, a directory with a `/` after it, or lists the matches and shows the line again, up to the cursor. → R1 the new cursor. Table 1.7. |
| 41 | `52` | `scr_links` | R1 the word of the rows of the screen that go on from the row above, bit r for row r, 1 to 27, or -1 to keep it; bit 0 and the bits from 28 are dropped. `mon_putc` sets a row's bit when it wraps to the row past the last column, clears it at a LF and when a row is written again from its column 0, and moves the bits up with the rows when the screen scrolls; `scr_cls` clears them, and so does the end of a program that moved the cursor through its registers. A wrap leaves the cursor at column 0 of the row it set the bit of, and what goes there next is more of that line, unless `scr_moveto` or the end of a program came between: BASIC's screen editor takes a line of up to four rows by them. The two forget the wrap since V2.4.1. The monitor of V2.4 does not, and its table is 1.8 too, so `mon_version` does not tell the two apart. A program that writes the screen's words itself, and leaves text for the editor, writes the word too, or 0. → R1 the old word. Table 1.8. |

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
above). The monitor joins the file too, for its own statements, but a
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
| `_io_gets` | A line into the buffer at R1, up to R2 characters and a 0 word, edited as BASIC says and echoed through `mon_putc`. → R1 the number of characters. `_io_gets.first` is the same, with R3 a first byte already read and R4 a routine for TAB or 0, for BASIC's own line; the routine takes R1 the buffer, R2 the cursor, and R3 the word after the last, and returns R1 the new cursor. `_io_gets` drops TAB. |
| `_io_getc` | → R1 the next byte of the console, which it waits for. The end of the line's input, `0x200`, is no byte, as the keyboard's bytes still come. |

nice_cpu's `libc` is a small C standard library, and its runtime
README lists every function it has and every one it lacks
([C library](https://github.com/MJoergen/nice_cpu/blob/main/runtime/README.md#c-library)).
In short: `stdio.h` with `printf`, `scanf`, `getchar`, and `fgets`, on
the console only, with no files; `string.h`, `stdlib.h` with `malloc`,
`strtol`, `strtod`, and `rand`, `math.h` in double and float, `ctype.h`,
`time.h` with `clock` and `time`, `assert.h`, and `errno.h`; and
`nice.h`, with the routines of the devices, such as `nice_pollc`,
`nice_micros`, and `nice_screen_put`. It needs no ROM, and has neither
the files of the SD card nor the network: a C program reaches those
through the entries, with `mon.h`.

## Files

The ROM reads and writes FAT32
([doc/SDCARD.md](../doc/SDCARD.md), "The file system") with
`monitor_fat.nasm`.

To load a program from a card, make the folder `NICE` in its root on a
PC, copy the `.bin` file into it, and type `DIR` and `LOAD "NAME.BIN"`
on the board:

    mkdir /media/card/NICE
    cp build/hello.bin /media/card/NICE/

`BSAVE "NAME", A, N` writes a program back, and the ROM never makes the
folder itself, so a card is written only where its user made room.
With no PC slot, `make sdcard CMD=mkdir` makes it over the link
([tools/README.md](../tools/README.md#nicemonpy-sd)).

- **The card** is FAT32 when its sector 0 is a FAT32 boot sector, as
  `mkfs.fat` makes on a whole card, or an MBR whose first partition of
  type `0x0B` or `0x0C` has one. FAT12, FAT16, and exFAT are rejected with
  errors of their own. The type is told by the count of clusters, as
  Microsoft's specification says. A volume larger than its partition,
  or than the card, is error -26, as its end is the guard of every
  write.
- **The mount**: `fs_mount` mounts the card in a slot. `fs_open`, `DIR`,
  and `LOAD` mount the slot of the last mount when there is none, or
  after reset slot 0, or slot 1 when slot 0 has no card. The mount, and
  the files open, are dropped when the selected slot is no longer the
  mounted one, as after a program selects the other slot, when the card
  there is not ready or has changed, and when the card fails a command
  with an SD error other than 6 and 7. Such an error of an entry that
  found a mount and no file open runs the entry once more, on a new
  mount, so a card swapped in the R3's slot 1, which has no card
  detect, starts up there. A mount of a slot that the system
  does not have changes nothing.
- **The folder `NICE`** of the root directory only. A card may be shared by several cores
  on the MEGA65, each with a folder of its own in the root, so NiceMon
  keeps to its own. A mount fails with error -29 when the root has no
  directory of that name, even when it has a file of it, and the root's
  own files are never reached. The folder's name is set when the monitor
  is built, `make rom FOLDER=NAME`, an 8.3 name of 1 to 8 letters,
  digits, `_`, and `-`, in either case, which error -29's text names; the
  tests need `NICE`. Deleted entries, `.`, and `..` are passed over.
- **Paths** reach the folders inside `NICE` (issue #168): a name may be
  `SUB/SUB/NAME`, split at each `/`, and each part before the last is a
  directory of the folder before it, found as a file is, by its long
  name or its 8.3 name, in either case. `LOAD "GAMES/CHESS.BIN"` reads
  `NICE/GAMES/CHESS.BIN`. A leading `/` is `NICE` itself. A part that is
  empty, `.`, or `..` is error -20, so a path never leaves `NICE`, and
  the whole path is at most 255 characters. A directory that is not
  there is error -21, and a file where a directory is due is -22. Mode
  2 of `fs_open` opens a folder by its path, `GAMES`, `/GAMES`, or
  `GAMES/`; modes 0 and 1 take no `/` at the end. The ROM makes no
  folder and deletes none: one is made on a PC, or with `make sdcard
  CMD="mkdir GAMES"` over the link.
- **Names** are long names (VFAT) of up to 255 characters, or 8.3
  names, matched in either case: `mandelbrot.bin` and `MANDEL~1.BIN`
  are the same file. A long name is read from the long-name entries
  before a file's 8.3 entry when their numbers and checksum check; a set
  that does not is passed over, and the 8.3 name stands. An 8.3 name
  shows in lower case where its entry says so, as Linux and Windows
  write `hello.bin`. A character outside ASCII is `?`, in a long name
  and in an 8.3 name, and such a file is reached by its name as `DIR`
  shows it, such as `DELETE "caf?.bin"` for `café.bin`, or by an 8.3
  name in ASCII. A `?` matches only such a character, and of two names
  that `DIR` shows alike, the first in the folder is reached.
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
  deletes a file, with its long name, and no directory (error -22). A file open to
  write may not be opened again, a file open at all may not be truncated
  or deleted, and a read-only one is not changed. A file written gets the
  date and the time of the clock, which BASIC's `TIME` sets, and a new one as its
  creation too; while the clock is not set, or its year is before 1980
  or after 2106, the date is 2026-01-01 at 00:00.
  FSInfo's count of
  the free clusters is set to unknown, which `fsck.fat` reports as
  uninitialized, and its hint is kept.
- **The caches** are one sector of the FAT, and one for each of the two
  files that may be open at once, in the monitor's RAM. The FAT and the
  folder are written through; a file's sector is written when it is full,
  and at `fs_close`.
- **Sectors** are not the HAL's: a program that wants them drives the
  SD controller's registers at `0xFFFFFFA0` itself, which are the same
  on every board and in `niceemu` ([nice_cpu's DEVICES.md §5](https://github.com/MJoergen/nice_cpu/blob/main/doc/DEVICES.md#5-sd-card)), and calls
  `fs_mount` before it uses the files again.

The entries 9 to 15 and 20 of the dispatch table (above) are its file
API, in the C ABI. A name is one character per word up to a 0 word, and an
address is a word address. An error is negative
([doc/PROGRAMMING.md](../doc/PROGRAMMING.md#the-monitors-error-codes)).

## The network

A program reaches the network through the entries above, UDP's 16 to
19 here and the IP settings, DNS, and TCP of 21 to 31 in TCP and DNS
below, or drives the port for Ethernet frames at `0xFFFFFFC0` itself, which [nice_cpu's
DEVICES.md §7](https://github.com/MJoergen/nice_cpu/blob/main/doc/DEVICES.md#7-ethernet-frames) specifies, the same on every board and in `niceemu`. The
ROM's own frame routines and its ARP cache, which `DHCP`, `NTP`, TFTP,
and the entries use, have no entries in the dispatch table
([INTERNALS.md](INTERNALS.md#the-frame-routines)).

The network of programs is separate from remote control (Remote control
below), but both use the board's one MAC address and one IP address,
those of its Ethernet station
([SYSTEM.md](../doc/SYSTEM.md#the-ethernet-station)). The station
answers ARP for that IP address and pings to it, and serves remote
control on TCP port 4510. Every other frame to the board, UDP to any
port among them, goes to the port for Ethernet frames while a program
or the entries have it enabled. The address that `IP` or `DHCP`
sets serves both.

- The cold start and the return of a program, `mon_exit`, disable the
  port, so a program that does not use the network sees no frame. A
  program that enables it reads the frames itself.
- **DHCP in the background.** When the board has no IP
  address at the cold start, as after a reset, the monitor gets one from
  DHCP on its own. It does so only while it waits for the first key of
  a line after `READY.`, so a statement or a program is never slowed by
  it. The first DISCOVER goes 2 seconds after the cold start, as the
  Ethernet PHY needs that long to bring the link up after a reset. The
  next goes 4 seconds later, and each after it twice as late, up to
  every 64 seconds, plus up to a second more (RFC 2131). The ACK sets
  the address, as `DHCP` does, and BASIC shows it on the empty line
  after `READY.`, `IP address 192.168.1.253 from DHCP`. A line that has
  text already, such as the number that `AUTO` types or the prompt of
  `INPUT`, is left as it is: the address is set, and `IP` shows it. An
  address from `IP`, a program, or a host ends it. A start of
  the core, such as a host's load, keeps the station's address, so it
  starts no exchange when the board has one.
- `DHCP` enables the port, broadcasts a DISCOVER, and waits 2 seconds
  for an OFFER, then broadcasts a REQUEST of the address offered and
  waits as long for the ACK (RFC 2131). A timeout or a NAK starts again
  from the DISCOVER, up to 4 times; an OFFER or an ACK without an
  address is passed over. When the board has an address already, the
  DISCOVER asks for it, so that the server offers it again. The ACK's
  address is written to `NET_IP` only when it is another, which breaks a
  host's connection over TCP, as `IP "A.B.C.D"` does. So `DHCP` on a board
  that a host reaches over Ethernet keeps the host's connection when the
  server gives the same address. Then the port is disabled again. The
  frames come from 0.0.0.0, to everyone,
  with the broadcast flag set, and ask for the mask, the gateway, the
  DNS servers, and the NTP servers. They name the board to the server, as a router's
  list of stations shows it: the host name is `nicemon-` and the last
  three bytes of the MAC address, such as `nicemon-434506`, and the
  vendor class is `NiceMonMEGA65` and the monitor's version, such as
  `NiceMonMEGA65 V2.5.1`. The transaction's number is the microsecond counter
  at the start, XOR the low word of the MAC address. The lease is
  kept, and renewed while BASIC waits for a line, and by a
  program's polls while the network is on, as `net_poll` has it. A
  program that does not use the network renews nothing, so a board
  that runs one longer than its lease may have its address given to
  another station.
- `DHCP` keeps the mask and the gateway of the ACK, which UDP uses
  below, and the first DNS server and the first NTP server, which it
  shows; `IP "A.B.C.D"` and the cold start set the four to none, and
  forget the lease, and so does `net_set` for the NTP server.
- `NTP` sets the clock from a time server by SNTP (RFC 4330): one
  query of 48 bytes from a local port of its own to port 123, sent
  again after 2 seconds, 3 times in all. It takes the answer of mode 4
  from the server's address and port 123 whose originate timestamp is
  the query's transmit timestamp. A stratum of 0 is a kiss-o'-death,
  whose code it shows, such as `The time server refused: RATE`. A leap
  indicator of 3, a stratum over 15, a transmit timestamp of 0, or a
  time the clock does not take, is not to be trusted. The clock takes
  the seconds and the microseconds of the transmit timestamp, plus the
  offset, with no correction for the delay, which is far below the
  second that `TIME` shows. Seconds below 2^31 are of NTP's era 1,
  from 2036 on (RFC 4330 §3). With no server named, it asks the NTP
  server of DHCP, or else `pool.ntp.org`, through the DNS server.

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
  address or 255.255.255.255. The poll stops at that datagram, so the
  frames after it wait in the queue. `udp_recv` returns the datagram
  held, and polls only when none is, so datagrams that come together
  are read one after another. The other frames are released unread, so
  a program that also wants other frames drives the port itself. An
  empty datagram, a fragment, and IP options are passed over. A
  datagram that a poll of another entry finds while one is held is
  dropped: a program reads the one held before it calls another UDP
  entry or `net_poll`, or may lose the next. A call with no room, 0 bytes,
  copies nothing and leaves the datagram held, so no datagram is lost to
  it. The queue holds 4 frames
  ([nice_cpu's DEVICES.md §7](https://github.com/MJoergen/nice_cpu/blob/main/doc/DEVICES.md#7-ethernet-frames)), so a program that receives a burst reads it
  soon.

An error of the UDP entries is negative
([doc/PROGRAMMING.md](../doc/PROGRAMMING.md#the-monitors-error-codes)).

`LOAD "NAME.BIN", "IP"` reads a file of a TFTP server (RFC 1350), in octet mode, as
`LOAD "NAME", "IP"` reads BASIC's program `NAME.BAS`,
through the endpoint, which it opens on a port of its own choice and
closes at the end. The RRQ goes to port 69, or to `PORT` of `IP:PORT`,
and the server's first DATA
gives the port that the rest come from; packets of other hosts and
ports are passed over. Each DATA is answered with its ACK, a DATA of the
block before with the ACK again, and a block of less than 512 bytes is
the last. A packet with no answer within a second is sent again, up to
5 times in all. The lines are taken as `LOAD` takes those of a file, and
the words written as `LOAD` with no name writes them. When an ERROR or
no answer ends a load after a line, the summary of the lines before it
comes first, as their words are in the RAM.

`SAVE "NAME", "IP"` and `BSAVE "NAME", A, N, "IP"` write a file to the
server, the bytes that they write to the card (issue #155). The WRQ
goes to port 69, or to `PORT`, and the server's ACK of block 0 gives the
port of the rest. The bytes go in DATA blocks of 512, each sent when it
fills, and the last of less than 512 bytes, which is empty when the
file is a multiple of 512. Each block is sent again when its ACK does
not come within a second, up to 5 times in all, and ACKs of other
blocks, hosts, and ports are passed over. An ERROR of the server, or no
answer, ends the write, and CTRL-C in `SAVE` sends the server an ERROR,
so that it drops the file.

`DIR "IP", "PAT"` asks for the pattern `PAT`, with `*` or `?`, and
`DIR "IP"` for `*`: the lines received are shown instead of loaded,
each without its bytes that are not printable ASCII, such as those of
a name in UTF-8, and up to its first 77 characters. The repository's own server,
`tools/nicemon.py tftpd`, answers a pattern with a listing of the files of its
folder that match it, a line each with the name and the size in bytes,
which no other server does. To serve the examples from a PC:

    make tftpd

It serves `examples/build`, the folder of `make examples`, or with
`TFTP_DIR=FOLDER` another folder, its regular files and nothing else.
Port 69 needs root, or the capability that
[tools/README.md](../tools/README.md#nicemonpy-tftpd) names; without either, `make tftpd TFTP_PORT=6969` serves on port
6969. `make tftpd ARGS=--write` takes the files of `SAVE` and `BSAVE`
too, which replace those of the same name, and anyone who reaches the
port may write while it runs, as TFTP has no login. On the board, `DHCP`, then `DIR "192.168.1.10", "*.BIN"` lists
the programs, and `LOAD "HELLO.BIN", "192.168.1.10"` loads one, with the
PC's address, and `:6969` after it for the other port. Any other TFTP
server, such as `tftpd-hpa`, serves the
files too, but answers a pattern with an error.

## TCP and DNS

The entries 21 to 31 (table 1.5) give a program the IP
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
  A plain address, one outside the byte windows, is a buffer of a byte
  a word, in bits 7..0 of each, as BASIC's strings are: `dns_lookup`,
  `tcp_send`, and `tcp_recv` take one, and BASIC's `NTP` and `HTTP$`
  use them so, with their buffers in the top words of the RAM.
- An IP address is a word, its first byte in bits 31..24, as `NET_IP`
  has it.

A C program declares the entries with `mon.h`, as `mon_net_config` to
`mon_tcp_listen`, which take C's own pointers, and is built with `nicebuild.py --monitor --asm mon.nasm
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
`net_dhcp` gets them from a DHCP server, as `DHCP` does, with the
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
send, packed, so `MON_TCP_CB_WORDS(rx, tx)` of `mon.h` words in all. Its
address in the word window has bits 1..0 clear, and the block lies in
the program's RAM, at `0x8000` or above, or `tcp_open` and `tcp_listen`
give `MON_E_TSIZE`. The block is the
ROM's from `tcp_open` or `tcp_listen` until `tcp_state` gives
`MON_TCP_FREE`, and the program does not touch it meanwhile. `tcp_state`
gives the state:

| State | Value | What it means |
|---|---|---|
| `MON_TCP_FREE` | 0 | The handle is free. |
| `MON_TCP_CONNECTING` | 1 | The handshake. Bytes that `tcp_send` takes go after it. |
| `MON_TCP_OPEN` | 2 | Bytes go both ways. |
| `MON_TCP_PEER_CLOSED` | 3 | The peer has closed. The program reads what is left, then gets `MON_E_TEOF`, and may still send. |
| `MON_TCP_CLOSING` | 4 | After `tcp_close`. The handle frees itself. |
| `MON_TCP_LISTEN` | 5 | A handle of `tcp_listen`, until a peer connects. |
| an error | negative | The connection ended, such as `MON_E_TRESET`. `tcp_close` frees the handle. |

- **Opening.** `tcp_open` sends the SYN from a local port of 49152 to
  65535, 4 times in 15 seconds, then the connection ends in
  `MON_E_TTIMEOUT`; a RST ends it in `MON_E_TREFUSED`.
- **Listening.** `tcp_listen` makes a handle in `MON_TCP_LISTEN`. The first
  SYN to its port takes it, through `MON_TCP_CONNECTING`, to `MON_TCP_OPEN`: one
  connection for each handle. A program that wants to serve two peers
  at once listens with two handles on the same port. A SYN that comes
  while every handle of the port is busy is passed over, and the peer
  sends it again; a SYN to a port where nothing listens gets a RST. Port
  4510 is the station's, for remote control, so `tcp_listen` gives
  `MON_E_PORT` for it.
- **Sending and receiving** never wait. `tcp_send` takes what fits into
  the ring, and the poll sends it in segments of up to 1460 bytes, as
  far as the peer's window and the congestion window let it, and sends
  it again after a timeout, from 200 ms to 60 s, measured from the
  round trips. After 120 s with no answer the connection ends in
  `MON_E_TTIMEOUT`. `tcp_recv` takes from the ring received. Each
  connection announces a window of at most the free room of its ring,
  and 4096 bytes divided by the number of connections, so that together
  they announce about 4096 bytes, as the queue holds only 4 frames.
- **Closing.** `tcp_close` with 0 ends both directions: the bytes that
  wait to be read are dropped, and so are those that come later, and
  `tcp_recv` gives `MON_E_TCLOSED`. The FIN goes after the bytes that wait
  to be sent, and the handle frees itself once the peer has
  acknowledged it and sent its own FIN, or 60 s after the
  acknowledgment, or when the sends give up. With 1 it sends a RST and frees the handle at once. A
  close of a handle in `MON_TCP_LISTEN`, or of one with an error, frees it
  at once and sends nothing. There is no TIME-WAIT.
- **The cold start and a program's return** send a RST for each
  connection, free every handle, close the endpoint, and disable the
  port. They trust a control block only by its first word, which the
  ROM writes, so a block that a new program overwrote is just freed.

The errors are those of UDP, -40 to -44, and -45 to -57
([doc/PROGRAMMING.md](../doc/PROGRAMMING.md#the-monitors-error-codes)).
The entries run on the program's stack. The deepest, `tcp_recv`, takes
24 words of it with the return address, `dns_lookup` 15, and `net_dhcp`
11, as measured in the tests in `niceemu`, within the 32 words of
Programs below.

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
  shares with the monitor. That is `0x8000`–`0x1E7FF`, 90K words, on the
  MEGA65, and `0x8000`–`0xE7FF`, 26K words, on the Nexys4DDR, as the
  variables are the top 6K words of the RAM: the monitor's 4K, and
  BASIC's 2K below them. A program learns
  the size of the RAM from `0xFFFFFF9E`
  ([SYSTEM.md](../doc/SYSTEM.md#io-registers)), which reads 0 in
  `niceemu`, where the memory has no limit. The monitor's routines use
  at most 32 words of the stack when a program calls them. The stack is
  in use before the program runs: `SYS` takes the top 2 words, from
  `0x1E7FF` or `0xE7FF` down, `LOAD` of typed lines reaches 8 words
  below the top, and `LOAD` from a card 22. So a load, `LOAD` and
  `bin_line`, writes no word in the stack's first 1K words, from
  `0x1E400` or `0xE400` up, which is BASIC's default `HIMEM` too, and
  skips such a line, as it skips one outside the RAM.
  `nicemon.py load --monitor` writes there, and its word is then
  overwritten, as any word in the room the stack needs is.
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
`--monitor`, `nicemon.py load` and `nicemon.py run` keep the ROM, load a program at
`0x8000`, and run it under the monitor:

    tools/nicemon.py load --eth 192.168.1.65 --monitor prog.bin

The tools' README has the details, in [Running a program under the
monitor](../tools/README.md#running-a-program-under-the-monitor).

## The demo

The demo is nice_cpu's, built with the boards' text
([demo/](../demo/README.md)). It is a program at `0x8000`, `demo.bin`,
which each release has as a file of its own. Copied into the card's
folder `NICE`, `LOAD "DEMO.BIN"` and `SYS 0x8000` run it, and its F12
returns to BASIC with `Returned 00000000`. `LOAD` from a TFTP server
loads it too, and so does
`tools/nicemon.py load --monitor`.
