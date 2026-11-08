# monitor

The ROM at `0x0000`, which the core boots from, holds the monitor: a
hardware abstraction layer, the HAL, of twenty routines that reach the
hardware or the state the monitor keeps, called through a dispatch table
at the start of the ROM, and a main loop with a few commands. It is not a
library: what a program can do for itself stays in the program.

A program under the monitor sees three levels, which
[doc/PROGRAMMING.md](../doc/PROGRAMMING.md#three-levels) describes for
those who write programs:

1. **The hardware**: the I/O registers of
   [doc/SYSTEM.md](../doc/SYSTEM.md) and nice_cpu's SYSTEM.md, the same
   in `niceemu` but for the differences of
   [doc/EMULATOR.md](../doc/EMULATOR.md). Every program has them.
2. **The ROM**: the entries of the dispatch table (The dispatch table
   below), which are there whenever the ROM is visible. A host that
   loads a program at 0 hides the ROM, and the entries go with it.
   `niceemu` has no ROM: there the monitor is a program at 0 like any
   other, and `cat monitor.bin prog.bin` runs it with a program at
   `0x8000` (Programs below).
3. **The library**: the routines of `monlib.nasm` (The shared routines
   below), and the stubs of `mon.nasm`, which are joined to a program
   when it is built, so they are in its image only when it joins them.
   There is no linker, so a program that joins a file has all of it.

The ROM also has routines of its own, which have no entries and which
programs do not call: the sector routines of the SD cards, the frame
routines and the ARP cache of the network, and FAT32 in C.
[INTERNALS.md](INTERNALS.md) describes them, with the build and the
tests.

The monitor is in NICE assembly, with FAT32 in C. `monitor.nasm` is the
ROM, with its disassembler in `monitor_dis.nasm`, its SD cards in
`monitor_sd.nasm`, and its network in `monitor_eth.nasm`, and `fat32.c`
is its FAT32; `monlib.nasm` has the routines that programs join and the
monitor's commands use too; `mon.nasm` has the stubs through which a
program calls the entries, and `mon.h` their declarations for C.
`make -C monitor` builds `build/monitor.bin`, and `make -C monitor test`
runs it in `niceemu` ([INTERNALS.md](INTERNALS.md#building-and-testing)).
It was written for
[#24](https://github.com/MJoergen/NiceMonMEGA65/issues/24), and what is
finished in
[#64](https://github.com/MJoergen/NiceMonMEGA65/issues/64). Loading
from storage is the SD card's,
[#62](https://github.com/MJoergen/NiceMonMEGA65/issues/62). The QNICE
monitor (QMON) of [QNICE-FPGA](https://github.com/sy2002/QNICE-FPGA) is
the inspiration, not the model: the decisions below were made for a port
of it, and #24 revisited them. Debugging is the on-board debugger's
([#52](https://github.com/MJoergen/NiceMonMEGA65/issues/52),
[doc/DEBUGGER.md](../doc/DEBUGGER.md)), which needs no ROM.

## Where it lives

- The monitor is in the ROM at `0x0000`–`0x7FFF`, as QMON is, and the core
  boots from it at reset. The RAM is above it, from `0x8000`, and the
  monitor's variables are at `0xFFFFF000` and up, below the I/O page, as
  QMON's are below `0xFF00`. The stack grows down from `0xFFFFF000`.
  The words that the ROM's C code writes are at `0xFFFFF400`–`0xFFFFFEFF`
  with them ([INTERNALS.md](INTERNALS.md#c-in-the-rom)). The demo follows the monitor in the
  ROM, from `0x6000` (The demo below).
  Nothing of the monitor's is written below `0x8000`: a write to the ROM
  is dropped, so a stack there loses its return addresses (`sim/rom.nasm`
  says what happens then).
- `make r6` (or `r3`, or `nexys4ddr`) puts the monitor in the ROM, with
  the demo behind it, `demo/build/rom.bin`, as the release does (The
  demo below); `make r6 ROM=monitor/build/monitor.bin` puts the monitor
  alone (see [synth/](../synth/README.md) and
  [SYSTEM.md](../doc/SYSTEM.md#the-rom)). The ROM changes only with a new
  bitstream, so the monitor is developed in the emulator, `niceemu`, which
  runs it like any program, with its keystrokes in an input file; the
  board is for checking.
- The debug link stays. While the monitor runs, the link reaches only its
  debug registers, and a host holds the core to reach the rest, as
  `load.py` and `run.py` do. They hide the ROM too, so that a program at
  address 0 runs as in the emulator, and the reset button boots the monitor
  again. With `--monitor` they keep the ROM, and run a program at
  `0x8000` under the monitor (Loading from a host below).

## The commands

At the cold start the monitor clears the screen, prints its banner,
`NiceMon` and the version, and prints a prompt, `> `, on the screen and
on the line. It reads a line from the console: the keyboard and the line,
which the hardware merges. A command is a letter, in either case, or
`sd`, `dir`, `load`, `save`, `del`, or `tftp`, and after `d` and `u` a hex address and a hex
count, each of them optional. DEL and
backspace delete the character before the cursor, CTRL-C empties the
line, and the cursor and function keys, the other control codes, and the
bytes `0x80` to `0x9F` do nothing. RETURN runs the line.

Before the first key of a line, Page Up and Page Down scroll back
through the rows that left the top of the screen, 24 rows at a time.
On the MEGA65 they are MEGA with CRSR↑ and CRSR↓. Any other key shows
the screen again, and goes on to the line. The history has 384 rows on
the MEGA65 and 77 on the Nexys4DDR (Input and output below).

| Command | What it does |
|---|---|
| `r [ADDR]` | Runs the program at `ADDR` in hex, or at `0x8000` without it (Programs below), and prints its status when it returns: `Returned 0000002A`. A word of 0 at `ADDR` is no program, and `r` says so: `No program at 00008000`. `r 0` runs entry 0 of the dispatch table, the cold start, so it restarts the monitor and leaves the RAM from `0x8000` alone. |
| `d [ADDR] [N]` | Shows `N` words from `ADDR`, 4 to a row with the row's address first, all in hex. Without `ADDR`, the words after the last shown; without `N`, 32 words. |
| `u [ADDR] [N]` | Disassembles `N` instructions from `ADDR`, a row each: the address, the instruction's 1 to 4 words, and its text, all in hex (The disassembler below). Without `ADDR`, the instructions after the last shown; without `N`, 20. |
| `c` | Clears the screen. |
| `v` | The version of the monitor, and of the dispatch table: `NiceMon V1.9.1, table 1.3`. |
| `i [A.B.C.D]` | Shows the Ethernet station's IP address, `IP address 192.168.1.65`, or writes it first: four decimal numbers of 0 to 255 with dots between them, such as `i 192.168.1.65`. Anything but an address or `dhcp` is no address, and `i` says so and writes nothing. It writes `0xFFFFFFB0`, `NET_IP` ([SYSTEM.md](../doc/SYSTEM.md#the-ethernet-station)), so a host connected over TCP loses its connection. In `niceemu` it is a register that keeps what is written. |
| `i dhcp` | Gets the IP address from the network's DHCP server and writes it, as `i A.B.C.D` does, then shows it, with the mask, the gateway, and the server, a line each (The network below). Without an answer, it prints `No answer from a DHCP server` after about 16 seconds, and leaves the address as it was. |
| `m [MAC]` | Shows the station's MAC address, `MAC address 02:4E:49:43:45:00`, or writes it first: six bytes of one or two hex digits, in either case, with colons between them, such as `m 02:4E:49:43:45:01`. The first byte must be even, as an odd one makes a group address. Anything else is no address, and `m` says so and writes nothing. It writes `0xFFFFFFB1` and `B2`, so a host connected over TCP loses its connection. Two boards on one network need different MAC addresses. In `niceemu` they are registers too, with the address of a board after reset. |
| `l` | Loads words into the RAM from lines of `ADDR WORD` in hex, as a `.bin` file has them (Loading without a host below), up to an empty line, and prints the words written and the lines skipped: `Words loaded: 600, 00008000 to 00008257`. |
| `sd [SLOT] LBA` | Shows the sector `LBA` of the SD card in `SLOT`, both in hex, as 32 rows of 16 bytes: the offset in the sector, the bytes in hex, and the bytes as text, with a dot for a byte outside `0x20` to `0x7E` ([INTERNALS.md](INTERNALS.md#the-sector-routines)). Without `SLOT`, the slot of the last `sd`, 0 after reset. An error of the controller is shown with its number and its meaning: `SD error 1 in slot 1, no card`. |
| `dir [SLOT]` | Lists the folder `NICE` of the SD card's FAT32 file system (Files below): `Directory of NICE`, then a row for each file, its 8.3 name and its size in decimal, and for each directory, its name and `<DIR>`, then `Files: 25, directories: 1`. With `SLOT` in hex, it mounts the card in it first; without, it lists the card mounted, which the first `dir` or `load` after reset mounts. An error is shown with its number and meaning: `File error 18, FAT16, which is not supported`. |
| `load NAME` | Loads the `.bin` file `NAME` of the card's folder `NICE` as `l` loads lines, and prints the same summary, so a program copied to the card on a PC loads with no host. Unlike `l`, an empty line is passed over, the end of the file ends the load, and a skipped line is counted from the first line of the file. `NAME` is an 8.3 name, in either case. |
| `save NAME ADDR N` | Writes `N` words from `ADDR`, both in hex, to the file `NAME` of the card's folder `NICE` as a `.bin` file, a line of `ADDR WORD` in hex for each, and prints `Words saved: 600, 00008000 to 00008257`. It makes the file, or truncates it when it is there, and `load` reads it back. When the card fills up, the file keeps what fitted, and `save` prints error 30. |
| `del NAME` | Deletes the file `NAME` of the card's folder `NICE`, with its long name, if it has one, and prints `Deleted NAME`. |
| `tftp IP NAME` | Loads the `.bin` file `NAME` from the TFTP server at the IP address `IP`, such as `tftp 192.168.1.10 hello.bin`, as `load` loads one from the card, and prints the same summary (The network below). `IP:PORT` sends the request to `PORT` instead of 69. It needs an IP address, from `i`. Without an answer, it prints `No answer from the TFTP server` after about 5 seconds; an error of the server is shown with its code and its message: `TFTP error 1, File not found`. |
| `tftp IP [PAT]` | Lists the files of the server `tools/tftpd.py` at `IP` whose names match the pattern `PAT`, with `*` and `?`, such as `tftp 192.168.1.10 *.bin`, a line each with the name and the size; without `PAT`, all of them. Another server answers with an error. |
| `x` | Runs the demo of the ROM, for the time being (The demo below). Without a demo in the ROM, `x` says so. |
| `h` | Halts the core, which the reset button, or a host over the link, starts again. The tests end with it. |
| `?` | Lists the commands, and the keys of the history. |

Anything else prints `Unknown command; ? lists them`. The debugger has
pause, step, and inspect, so the monitor adds only `l`, which loads a
program with no host's tools and no storage, `u`, which reads code
with no host
([#72](https://github.com/MJoergen/NiceMonMEGA65/issues/72)), and `sd`,
which reads a card with no file system, for the bring-up of the SD card's
storage
([#57](https://github.com/MJoergen/NiceMonMEGA65/issues/57)). `dir`
and `load` read programs from a card's FAT32 file system
([#58](https://github.com/MJoergen/NiceMonMEGA65/issues/58)), and
`save` and `del` write it
([#59](https://github.com/MJoergen/NiceMonMEGA65/issues/59)).
`i dhcp`
gives a board on a network an address with no host
([#83](https://github.com/MJoergen/NiceMonMEGA65/issues/83)), and `tftp`
loads a program from a server on it
([#84](https://github.com/MJoergen/NiceMonMEGA65/issues/84)).

## Files

The ROM reads and writes FAT32
([#58](https://github.com/MJoergen/NiceMonMEGA65/issues/58),
[#59](https://github.com/MJoergen/NiceMonMEGA65/issues/59),
[doc/SDCARD.md](../doc/SDCARD.md), "The file system") with `fat32.c`,
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
  mounted one, as after `sd` on the other slot, or the card there is not
  ready or has changed. A mount of a slot that the system does not have
  changes nothing.
- **The folder `NICE`** of the root directory only (#91), with 8.3
  names, matched in either case. A card may be shared by several cores
  on the MEGA65, each with a folder of its own in the root, so NiceMon
  keeps to its own. A mount fails with error -29 when the root has no
  directory of that name, even when it has a file of it, and the root's
  own files are never reached. The folder's name is set when the monitor
  is built, `make monitor FOLDER=NAME`, an 8.3 name of 1 to 8 letters,
  digits, `_`, and `-`, in either case, which error -29's text names; the
  tests need `NICE`. Long names are passed over, so a file shows its 8.3
  name, such as `ALONGN~1.TXT`, and so are deleted entries, `.`, and
  `..`.
- **Writing** (mode 1 of `fs_open`) makes the file, with the 8.3 name
  only, or truncates it. Its clusters are taken as its data reaches them,
  and `fs_close` puts its size into its directory entry, so a file is
  finished only when it is closed: a reset in the middle of a write leaves
  at worst clusters that no file has, which `fsck.fat` frees. `fs_delete`
  deletes a file, with its long name, and no directory. A file open to
  write may not be opened again, a file open at all may not be truncated
  or deleted, and a read-only one is not changed. A new file has the date
  2026-01-01, as there is no clock of the time of day. FSInfo's count of
  the free clusters is set to unknown, which `fsck.fat` reports as
  uninitialized, and its hint is kept.
- **The caches** are one sector of the FAT, and one for each of the two
  files that may be open at once, in the C code's RAM. The FAT and the
  folder are written through; a file's sector is written when it is full,
  and at `fs_close`.
- **Sectors** are not the HAL's: a program that wants them drives the
  SD controller's registers at `0xFFFFFFA0` itself, which are the same
  on every board and in `niceemu` (nice_cpu's SYSTEM.md §5), and calls
  `fs_mount` before it uses the files again.

The entries 9 to 15 of the dispatch table (below) are its file API, in
the C ABI. A name is one character per word up to a 0 word, and an
address is a word address. An error is negative: those of the SD
controller, -1 to -8, as `sd` shows them, and these:

| Error | Meaning |
|---|---|
| -16 | No FAT32 file system |
| -17 | FAT12, which is not supported |
| -18 | FAT16, which is not supported |
| -19 | exFAT, which is not supported |
| -20 | Not an 8.3 name |
| -21 | No such file |
| -22 | A directory, opened as a file |
| -23 | Too many open files: two are |
| -24 | Not an open file, or not one of the right kind |
| -25 | No such mode |
| -26 | The FAT is damaged: a cluster outside the volume, or a chain shorter than the file |
| -27 | No such slot |
| -28 | The card has changed, and the mount was dropped |
| -29 | No folder `NICE` on the card, or the folder of the build |
| -30 | The card is full, or the folder has 65536 entries |
| -31 | The file is open: to write, or at all for a write or a deletion |
| -32 | The file is read-only |

## The network

A program reaches the network through the UDP entries below, or drives
the port for Ethernet frames at `0xFFFFFFC0` itself, which nice_cpu's
SYSTEM.md §7 specifies, the same on every board and in `niceemu`. The
ROM's own frame routines and its ARP cache, which `i dhcp`, `tftp`, and
the UDP entries use, have no entries in the dispatch table
([INTERNALS.md](INTERNALS.md#the-frame-routines)).

- The cold start and the return of a program, `mon_exit`, disable the
  port, so a program that does not use the network sees no frame. A
  program that enables it reads the frames itself.
- `i dhcp` enables the port, broadcasts a DISCOVER, and waits 2 seconds
  for an OFFER, then broadcasts a REQUEST of the address offered and
  waits as long for the ACK (RFC 2131). A timeout or a NAK starts again
  from the DISCOVER, up to 4 times; an OFFER or an ACK without an
  address is passed over. The ACK's address is written to `NET_IP`,
  which breaks a host's connection over TCP, as `i A.B.C.D` does, and
  the port is disabled again. The frames come from 0.0.0.0, to everyone,
  with the broadcast flag set, and ask for the mask, the gateway, and
  the DNS servers. The transaction's number is the microsecond counter
  at the start, XOR the low word of the MAC address. The lease is not
  renewed: a board that runs longer than its lease may have its address
  given to another station.
- `i dhcp` keeps the mask and the gateway of the ACK, which UDP uses
  below; `i A.B.C.D` and the cold start set both to none.

The UDP endpoint is the entries 16 to 19 of the dispatch table (below)
([#84](https://github.com/MJoergen/NiceMonMEGA65/issues/84)), so that a
program, such as a game of two boards, or the BASIC of #54, needs no
network stack of its own. They are in the C ABI, and the data of a
datagram is one byte per word, bits 7..0, as the file entries have it:

- **One endpoint**, one local port, which `udp_open` opens and enables
  the port for Ethernet frames, with its queue emptied, and `udp_close`
  closes, with the port disabled. The cold start and a program's return
  close it too. Port 0 picks one from 49152 to 65535.
- **Sending**: a datagram goes to its address, through the gateway when
  the mask puts the address in another network, and to everyone for
  255.255.255.255, after the ROM's ARP finds the MAC address. It is IPv4
  with no options, not to be fragmented, and with the UDP checksum 0,
  none, as IPv4 allows; up to 1472 bytes, which fill a frame.
- **Receiving** does not wait: `udp_recv` returns the next datagram to
  the endpoint's port of the station's address or 255.255.255.255, or 0
  when none waits. The frames before it that are not one are released
  unread, so a program that also wants other frames drives the port
  itself. An empty datagram, a fragment, and IP options are passed
  over. A call with no room, 0 bytes, copies nothing and leaves the
  queue as it is, so no datagram is lost to it. The queue holds 4 frames
  (nice_cpu's SYSTEM.md §7), so a program that receives a burst reads it
  soon.

| Error | Meaning |
|---|---|
| -40 | No IP address: `NET_IP` is 0 |
| -41 | No such port: 0 to send to, or past 65535 |
| -42 | The endpoint is not open |
| -43 | More than 1472 bytes |
| -44 | No answer to ARP from the host, or from the gateway, or none for a host in another network |

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
which no other server does
([#95](https://github.com/MJoergen/NiceMonMEGA65/issues/95)). To serve
the examples from a PC:

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
  of nice_cpu's ISA.md §10.2. Constants are in lower-case hex without
  leading zeros, and INT's vector is in decimal.
- A reserved control word, and an instruction with a field that its
  mnemonic does not use and that is not R0, are a `.DAT` of their words,
  with what they would do as a comment, as nicedis.py writes them:
  `.DAT 0x00000001 ; MOVE R0, R0 (s1: R1)`.
- `ADD @--R13, n, R15` followed by `MOVE R15, target`, where `n` is the
  number of words of the `MOVE`, is one row, `CALL target`, and
  `MOVE R15, @R13++` is `RET`: pseudo-instructions of ISA.md §10.1,
  which `niceasm` assembles back to the same words. A condition applies
  to both instructions of a `CALL`, so the two must have the same one,
  as in `?Z CALL 0x8123`. A pair with two conditions, an `ADD` with a
  modifier, an `n` that is not the length of the `MOVE`, or a `MOVE`
  with a modifier, is two rows.
- The other pseudo-instructions of §10.1 are one instruction each, and
  are shown in its place
  ([#73](https://github.com/MJoergen/NiceMonMEGA65/issues/73)). Some
  words match two of them, and the first that matches, in this order, is
  shown:

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

- Programs for the monitor are assembled at `0x8000`, as QNICE programs
  are, with nice_cpu's `start_mon.nasm`, `start_wasm_mon.nasm`, or
  `start_wasm_trap_mon.nasm` in place of its start-up files at 0
  (`nice_cpu/runtime/ABI.md`, "Programs under a monitor"), and
  `nicebuild.py --monitor` builds a C, Zig, or Rust program so. They
  return to the monitor instead of halting: when `main` returns, through
  `exit`, or with `RET` on the SP of the entry. `test/hello.nasm` and
  `test/hello.c` are two such programs, and the Makefile shows how they
  are built.
- The monitor runs a program as a subroutine on its own stack: it pushes
  a return address and jumps to `0x8000` with E = 0, R1 = the address of
  `mon_putc`'s entry, and R2 = 0 and R3 = 0, `argc` and `argv` for a
  command line later. The start-up code stores R1 in `___putc_vector`, so
  `nice_putc`, `nice_print`, the C library's `printf`, and the trap report
  print through `mon_putc`. At the return the monitor relies on SP and
  R1, the status, and on nothing else. It clears E, stops the timer, and
  sets VBASE back to 0 itself, so a program may own the interrupts, with
  a vector table in its own image.
- A program may use the RAM from `0x8000` up to, but not including, the
  SP it was called with, and must leave room below that for the stack it
  shares with the monitor. The monitor's variables are at `0xFFFFF000`
  and up, as the demo's are, and its stack grows down from there. The
  RAM repeats through the address space, so those words are the top 4K
  of the RAM, and programs have `0x8000` up to them for their image and
  their stack: `0x8000`–`0x1EFFF`, 92K words, on the MEGA65, with 128K
  words of RAM, and `0x8000`–`0xEFFF`, 28K words, on the Nexys4DDR, with
  64K. A program learns the size of the RAM from `0xFFFFFF9E`
  ([SYSTEM.md](../doc/SYSTEM.md#address-map)), which reads 0 in
  `niceemu`, where it is plain memory and the memory has no limit. The
  monitor's routines use at most 32 words of the stack when a program
  calls them. The stack is in use before the program runs: `r` pushes
  its return address at the top word of the program's RAM, `0x1EFFF` or
  `0xEFFF`, and `l`'s own summary reaches 13 words below it. `l` and
  `load.py --monitor` take a word there, which is then overwritten, as
  any word in the room the stack needs is.
- A program runs once per load: the load initializes its static data and
  its wasm linear memory. A wasm trap halts the core, as in nice_cpu,
  after the trap report's line on the monitor's output; the on-board
  debugger then has the state, and the reset button boots the monitor
  again.
- The monitor's routines are called through a dispatch table at the start
  of the ROM, as QMON's `getc!` and `putc!` are, so that programs need
  not be reassembled when the monitor changes. The table is below.
- In `niceemu`, which has no ROM, the monitor is a program at 0 like any
  other, and `cat monitor.bin prog.bin` runs it with a program at
  `0x8000`, for a `.bin` file is address and word pairs. Its keystrokes
  come from an input file. nice_cpu's own tests use a stand-in for the
  monitor, `nice_cpu/runtime/test/monitor.nasm`, which shows what the
  monitor does to run a program.

## The dispatch table

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
of the SD card is such entries
([#58](https://github.com/MJoergen/NiceMonMEGA65/issues/58)): with FAT32
in the ROM, the mounted card and the caches are state that the monitor
keeps. Its sector routines are not: a program loads and saves
files, not sectors, and one that wants sectors drives the registers,
which are the same everywhere. Strings, memory, number
formatting, line editing, and random numbers are not the HAL's: assembly
programs join `monlib.nasm` (The shared routines below), which the
monitor's own commands use too, and C programs have nice_cpu's `libc`.
The ROM's routines could not serve C anyway, for a C string is bytes
packed four to a word in wasm's linear memory
(`nice_cpu/translator/WASM.md`), and libc must run in `niceemu`, which
has no ROM.

The routines follow the C ABI of `nice_cpu/runtime/ABI.md`, not QMON's
registers from R8 up: arguments in R1–R4, the result in R1, R1–R6
changed, and R7–R13 kept. A C program for the monitor declares them with
`mon.h`, and is joined with the stubs of `mon.nasm`
(`nicebuild.py --monitor --asm mon.nasm`), as the translator makes a call
to the `env` import `mon_putc` a call to `_mon_putc`. For C, `mon.nasm`
also has `_scr_getx` and `_scr_gety`, as `scr_getxy` returns two values.
Such a program runs only with the ROM visible, as every program built at
`0x8000` for the monitor does.

VBASE is 0 at reset and stays 0. The monitor has no interrupts of its
own, as the debugger is hardware and the board has no NMI source, and it
keeps E at 0, so the vector table that would overlap the dispatch table
is never read. A program that wants interrupts sets VBASE to a page of
its own image, and the monitor clears E, stops the timer, and sets VBASE
back to 0 at every return. It sets the font base back to 0 then too, so
that the screen shows Spleen, and leaves the font RAM as the program left
it. It also shows the cursor again, blinking, and turns the display
offset off, as a program may have hidden the one or used the other.

| # | Addr | Name | Arguments → result | QMON |
|---|---|---|---|---|
| 0 | `00` | `mon_reset` | Cold start: E, the timer, VBASE, and the font base cleared, the stack, the variables, the screen, the banner, the main loop. The RAM from `0x8000` is left alone. | `reset!` |
| 1 | `02` | `mon_exit` | R1 a status. Back to the main loop with a fresh stack, with E, the timer, VBASE, and the font base cleared, the cursor shown and blinking, the display offset off, and the status printed; for a program that has not kept the SP of its entry. A program with the runtime's start-up code returns or calls `exit` instead, which lands here too. | `exit!` |
| 2 | `04` | `mon_version` | → R1 the version of the table, major in bits 31..16, minor in 15..0: `0x00010003`, 1.3. | — |
| 3 | `06` | `mon_putc` | R1 a character, to the outputs `mon_out` selects. On the screen it goes at the cursor, which moves on, to the next row after the last column; CR moves the cursor to column 0, LF to column 0 of the next row, BS one back, and TAB to the next multiple of 8; the other control codes and `0x7F` do nothing, and `0x80` to `0x9F` go on the screen as any character, blank in Spleen and drawn from the font RAM when a program selected it; past the last row the rows move up by one. On the line every byte goes as it is. | `putc!` |
| 4 | `08` | `mon_out` | R1 the outputs: bit 0 the line, bit 1 the screen; both at reset. → R1 the old ones. | — |
| 5 | `0A` | `scr_cls` | Clears the screen in the current color, cursor home, shown and blinking, display offset 0. | `vga_cls!` |
| 6 | `0C` | `scr_moveto` | R1 the column, R2 the row; a column past 79 is 79, and a row past 24 is 24. | `vga_moveto!` |
| 7 | `0E` | `scr_getxy` | → R1 the column, R2 the row. | `vga_getxy!` |
| 8 | `10` | `scr_color` | R1 the color for later characters, bits 31..8 of a screen word. → R1 the old one. | — |
| 9 | `12` | `fs_mount` | R1 a slot. Mounts its card, and closes the files that were open (Files above). → R1 0, or an error. Table 1.1. | — |
| 10 | `14` | `fs_open` | R1 a name, R2 a mode: 0 to read a file of the folder `NICE`, 1 to write one, which is made or truncated (table 1.2), 2 for the folder itself, whose name is empty or `/`. Mounts a card when none is. → R1 a handle, 0 or 1, or an error. Table 1.1. | — |
| 11 | `16` | `fs_read` | R1 a handle of a file, R2 a buffer, R3 a number of bytes. Reads up to that many, one byte per word. → R1 the number read, 0 at the end, or an error. Table 1.1. | — |
| 12 | `18` | `fs_readdir` | R1 a handle of a directory, R2 a buffer of 4 words. The next entry: in words 0 to 2 the 11 bytes of its 8.3 name, padded with blanks, and its attributes, as FAT has them, 4 bytes to a word from bits 7..0, and in word 3 its size. → R1 1, 0 at the end, or an error. Table 1.1. | — |
| 13 | `1A` | `fs_close` | R1 a handle. Finishes a file opened to write: its last sector, and its size in its directory entry. The handle is closed also after an error. → R1 0, or an error. Table 1.1. | — |
| 14 | `1C` | `fs_write` | R1 a handle of a file opened to write, R2 a buffer, R3 a number of bytes, one per word, bits 7..0. → R1 the number written, fewer when the card is full, or an error. Table 1.2. | — |
| 15 | `1E` | `fs_delete` | R1 a name. Deletes the file of the folder `NICE`, with its long name. → R1 0, or an error. Table 1.2. | — |
| 16 | `20` | `udp_open` | R1 a local port, or 0 for one of 49152 to 65535. Opens the UDP endpoint, and enables the port for Ethernet frames (The network above). → R1 the port, or an error. Table 1.3. | — |
| 17 | `22` | `udp_send` | R1 an IP address, R2 a port, R3 a buffer, R4 a number of bytes, one per word, up to 1472. Sends them as a datagram. → R1 0, or an error. Table 1.3. | — |
| 18 | `24` | `udp_recv` | R1 a buffer, R2 a number of bytes, R3 the address of 2 words, or 0. Does not wait. Copies up to that many bytes of the next datagram, one per word, and its source's IP address and port to the 2 words; with R2 0 copies nothing, and leaves the datagram waiting. → R1 the bytes copied, 0 when none waits, or an error. Table 1.3. | — |
| 19 | `26` | `udp_close` | Closes the endpoint, and disables the port for Ethernet frames. → R1 0. Table 1.3. | — |

Three entries of the first draft went on 2026-10-30, by the table's own
rule ([#24](https://github.com/MJoergen/NiceMonMEGA65/issues/24), the
comments of that day): `mon_getc` and `mon_getc_nb`, as the console at
`0xFFFFFF00` is the same on every board and in the emulator, with the
line and the keyboard merged by the hardware, and nice_cpu's `nice_getc`
and `nice_pollc` read it; and `mon_setvec`, as the monitor keeps no
vector table. `mon_out` stayed, one routine and one piece of state in
place of a `scr_putc` and a `ser_putc`: the line is the console, which
any program can write, and the screen's memory is the same everywhere,
so what the HAL adds is the terminal, the cursor, the scrolling, and the
copy to the line.

What QMON's table has that this one leaves out:

- `getc!`: see above.
- `puts!`, `crlf!`, `gets!`, `gets_s!`, `gets_slf!`, `puthex!`,
  `gethex!`, and `h2dstr!`: they are built on `getc!` and `putc!`, and
  are in `monlib.nasm`.
- `memset!`, `memcpy!`, `strlen!`, `strcmp!`, `strcpy!`, `strchr!`,
  `strstr!`, `chr2upper!`, `chr2lower!`, `str2upper!`, `chomp!`, and
  `split!`: they go in `monlib.nasm` when a program needs them.
- `wait!`, `srand!`, and `rand!`: a program reads the microsecond
  counter at `0xFFFFFF44` itself, the same on every board and in the
  emulator, and libc has `clock`, `rand`, and `srand`.
- `muls!`, `mulu!`, `divu!`, `divs!`, `mulu32!`, `divu32!`,
  `in_range_u!`, and `in_range_s!`: the math unit at `0xFFFFFF20` does
  them, and a word has 32 bits.
- `shl32!` and `shr32!`: a word has 32 bits.
- `til!`: there are LEDs and a seven-segment display only on the
  Nexys4DDR, as registers.
- `enter!` and `leave!`: NICE has no register banks.
- `vga_init!`, `vga_copyfont!`, and `vga_copypal!`: a program copies the
  character ROM into the font RAM itself, a loop of 8192 words
  ([SYSTEM.md](../doc/SYSTEM.md#the-font)), and the colors are in each
  screen word. The monitor writes 0 to the font base at its start and at
  a program's return, so that its text is in Spleen.
- The `sd_*!` entries: the sector routines stay inside the ROM (#57).
  A program that drives the SD registers itself mounts the card again
  afterwards. The frame routines and the ARP cache stay inside it too
  (#83): a program gets datagrams through the UDP entries of #84, or
  drives the port for Ethernet frames itself.
- The `f32_*!` entries: the file API, `fs_mount` to `fs_delete`, is the
  entries 9 to 15, from #58 and #59, as
  [doc/SDCARD.md](../doc/SDCARD.md) says.

## The shared routines

`monlib.nasm` is a library: it is joined after a program when the
program is built, with `mon.nasm`, whose stubs its routines call, so
its routines are in the program's image, and only in a program that
joins it. They print through `mon_putc`, entry 3, so they need the ROM,
as the entries do; in `niceemu` the monitor is joined at 0 (Programs
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

## Input and output

- Output goes to the line (Ethernet or the UART) and to the screen, as
  `mon_out` selects, both at reset; input comes from the line and the
  keyboard, which the hardware already merges into the console at
  `0xFFFFFF00`. A read returns 0 while no byte has arrived, so the monitor
  polls, which works in the emulator too, where a read waits.
- A break on the UART, or a host's half-close over Ethernet, ends the
  line's input and not the keyboard's (nice_cpu's SYSTEM.md §8): the
  host's bytes are dropped until the core is started again, a read
  returns `0x200` once the FIFO is empty, and the keyboard's bytes still
  come. So the monitor reads on, and a program that reads until `0x200`
  ends with the host's input. A new connection over Ethernet starts the
  line anew, as one to `niceemu --link` does (nice_cpu's DEBUG.md §7,
  through its link's `rx_resume_i` of MJoergen/nice_cpu#90), so the
  next host can type to a monitor that one host has left.
- The screen is memory at `0xFFFF0000`, one word per character with its
  color, so `mon_putc` writes the words directly where QMON writes a
  register. The hardware has a cursor, in registers numbered as
  QNICE-FPGA's VGA registers (`0xFFFFFF80` for `0xFF30`, and so on; see
  [SYSTEM.md](../doc/SYSTEM.md#the-screen)), which `mon_putc` keeps at
  the next character, and a display offset. Past the last row
  `mon_putc` moves the rows up by one, by copying, so the rows shown are
  always the 2000 words at `0xFFFF0000`, as in `niceemu`, and a program
  can write them directly. The screen is cleared by a loop over its
  words.
- The scrollback uses the rest of the screen's memory, past the 2000
  words: before the rows move up, row 0 is copied into a ring of rows,
  the history, which runs down from the top of the memory. The cold
  start finds the size of the memory from the display offset, which a
  board keeps only in the bits that address the memory: 32768 words on
  the MEGA65 and 8192 on the Nexys4DDR, so one `monitor.bin` serves
  every board. Page Up shows `k` rows back with the offset `size - 80k`,
  which wraps to row 0 of the screen, and the cursor off; the first
  Page Up turns the ring so that its newest row is the last of the
  memory. `niceemu` has no display offset, and keeps it as memory, so
  there the history is kept, 384 rows, and can be read with `d` or
  `--dump`, but is not shown. `c` and `scr_cls` leave it, as `clear`
  in a terminal does, and the cold start empties it.

## Loading from a host

A host loads a program at `0x8000` over the debug link, on the board's
Ethernet port or its UART, with `--monitor`:

    tools/load.py --eth 192.168.1.65 --monitor prog.bin
    tools/run.py --eth 192.168.1.65 --monitor -i in.txt prog.bin
    make load FILE=prog.bin ETH=192.168.1.65 ARGS=--monitor

Each holds the core with the ROM visible, clears the memory, which
leaves the ROM alone, writes the program, and starts the core. The
monitor boots cold, which leaves the RAM from `0x8000` alone, and the
tool types `r` and CR, which run the program. A program with a word
below `0x8000` is refused, as it would be in the ROM, and so is a
bitstream without a ROM. `--rom FILE` loads FILE at 0, with the ROM
hidden, in the ROM's place: for `niceemu --link`, `make cosim`, a
bitstream without a ROM, or another build of the monitor, such as
`build/monitor_test.bin`.

`run.py --monitor` prints what `niceemu` prints for the monitor and the
program joined, with `r` and CR before the input. The monitor reads on
at the end of the input, so the input ends with `h`, which halts the
core, as in the tests here:

    printf 'h\r' > h.txt
    tools/run.py --tcp PORT --monitor --rom build/monitor_test.bin \
        -i h.txt build/hello.bin
    printf 'r\rh\r' > rh.txt
    cat build/monitor_test.bin build/hello.bin > joined.bin
    niceemu -i rh.txt joined.bin

`make hwtest`, `make linktest`, and `make cosimtest` compare the two so
with `test/hello.nasm`, and `make hwtest` also runs it under the monitor
in the board's ROM, over the UART and Ethernet.

## Loading without a host

`l` loads a program that is typed on the keyboard, or pasted into a
terminal on the line, with no tools on the host and no storage. It reads
lines of `ADDR WORD`, two hex numbers of 1 to 8 digits with blanks or
tabs between them, which is what a `.bin` file has (nice_cpu's ISA.md
§10.4), and writes each word. CR, LF, and CR LF end a line, the `l`
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
`load.py --eth 192.168.1.65 --monitor prog.bin` (Loading from a host
above) is faster, as it writes the words into the memory.

## The demo

The demo is nice_cpu's
([nice_cpu#91](https://github.com/MJoergen/nice_cpu/issues/91)), and the
BASIC interpreter of
[#54](https://github.com/MJoergen/NiceMonMEGA65/issues/54) takes its place
in the ROM. Until then
([#65](https://github.com/MJoergen/NiceMonMEGA65/issues/65)), the ROM of
the boards and of the release has the demo behind the monitor, and `x`
runs it. The demo is a program assembled at `0x8000`
([demo/](../demo/README.md)), and `demo/join.py` puts it in the ROM at
`DEMO`, `0x6000`: the number of its words first, then the words. `x`
copies them to `0x8000` and runs them as `r` runs a program, and the
demo's F12 returns. The demo clears the screen before it returns, and
leaves the cursor at the top left, but the monitor keeps a cursor of its
own, so `x` calls `scr_cls` after the return, and then goes on as at
`mon_exit`. A number of 0, as in the ROM of the monitor alone
and in `niceemu` without the demo, is no demo, and so is one that would
not fit below `0x8000`. Neither the copy nor the demo has an entry in
the dispatch table, and both go when the demo goes; `release.py` and
`demo_hw.py` follow.

## What QMON has that this port will not

- QMON's SD card and FAT32 code, about half of QMON, is for QNICE's
  registers, and `qtransfer` has no hardware here. The sector routines
  were written anew for nice_cpu's registers
  ([INTERNALS.md](INTERNALS.md#the-sector-routines)), and FAT32 in C
  (Files above), with
  [#58](https://github.com/MJoergen/NiceMonMEGA65/issues/58) and
  [#59](https://github.com/MJoergen/NiceMonMEGA65/issues/59).
- QMON's disassembler is for QNICE; `u` was written anew for the NICE
  instruction set, with nice_cpu's `assembler/nicedis.py` as the model
  (The disassembler above).
