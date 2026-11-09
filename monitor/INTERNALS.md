# The monitor's internals

What the ROM has for itself, behind the dispatch table of
[README.md](README.md): the routines with no entries, which only the
monitor's commands and its C code call, the C in the ROM, and the build
and the tests. A program does not call these routines, as they have no
entries and their addresses change with every build; it calls the
entries, or drives the registers itself.

## The sector routines

The ROM has three sector routines of its own, with no entries in the
dispatch table ([doc/SDCARD.md](../doc/SDCARD.md), "The ROM"). They drive
the controller's registers at `0xFFFFFFA0`, which nice_cpu's SYSTEM.md §5
specifies, the same on every board and in `niceemu`. They follow the C
ABI, wait for busy before the command and after it, and return 0, or the
negative of `SD_ERROR`:

| Routine | Arguments | What it does |
|---|---|---|
| `sd_init` | R1 the slot | Selects the slot, and starts its card up |
| `sd_read` | R1 the sector, R2 a buffer of 128 words | Reads the sector into the buffer |
| `sd_write` | R1 the sector, R2 a buffer of 128 words | Writes the buffer to the sector |

- `sd_read` and `sd_write` use the selected slot, the slot of the last
  `sd_init`. The controller has one "ready" for both slots, so a change
  of slot costs an Init, up to hundreds of milliseconds on a board.
- The buffer is in RAM, 4 bytes a word, little-endian, as the
  controller's is: byte 4n of the sector is bits 7..0 of word n. The
  routines copy it through `SD_CHUNK` and `SD_BUF0`–`SD_BUF7`.
- `sd` calls `sd_init` only when its slot is not the selected one, or
  the card there is not ready, or has changed since its last Init, so a
  second `sd` on a slot reads at once. Its buffer is at `0xFFFFF080`,
  with the monitor's variables.
- FAT32 (README.md, "Files") calls the routines, and its file API is
  the table's entries for the card. A program that wants sectors drives
  the registers itself, and calls `fs_mount` before it uses the files
  again.

## The frame routines

The ROM has frame routines of its own, with no entries in the dispatch
table, as the sector routines have none. They drive the port for
Ethernet frames at `0xFFFFFFC0`, which nice_cpu's SYSTEM.md §7
specifies, the same on every board and in `niceemu`, and follow the C
ABI. A frame is in RAM as the port's buffers have it: from byte 2 of its
buffer, 4 bytes a word, big-endian, so that the fields fall on the words
of SYSTEM.md §7.

| Routine | Arguments | What it does |
|---|---|---|
| `eth_on` | | Enables the port, with its queue emptied |
| `eth_recv` | R1 a buffer of 380 words | Copies the frame at the head of the queue to the buffer, and releases it. R1 is its length in bytes, 0 when the queue is empty |
| `eth_send` | R1 a frame, R2 its length in bytes | Waits while the port is busy, then copies the frame to the send buffer and sends it |
| `arp_resolve` | R1 an IP address | R1 is 0, and R2 and R3 its MAC address as `NET_MAC_HI` and `NET_MAC_LO` have it; or R1 is -1 when no reply came |

- `arp_resolve` looks in the ARP cache, 4 entries at `0xFFFFF100`, which
  the cold start empties. Else it broadcasts a request, up to 3 times,
  waits a second for each reply, and puts the reply into the cache. An
  entry is kept about a minute, and a new one takes the entry of its
  address, or else the next in turn. The frames that come while it
  waits and are no ARP reply are released unread. The port must be
  enabled. The station answers the requests for its own address itself.
- `i dhcp` and `tftp` (README.md, "The network") use the frame
  routines, and `udp_send` calls `arp_resolve` for the MAC address of a
  datagram's host, or of the gateway. Programs do not call them: they
  have no entries, so their addresses change with every build.
  `test/arp.nasm` calls `arp_resolve` by its label, as `test/sd.nasm`
  calls the sector routines, as both are assembled after the monitor's
  sources (Building and testing below).

## C in the ROM

Part of the ROM is C, through nice_cpu's wasm translator: the FAT32
code. The files
of the Makefile's `ROM_C`, `fat32.c` for now, are compiled to one wasm
module, which `nicewasm --ram` translates for code
that runs from a ROM (nice_cpu's translator README, "Code in a ROM"),
at `-Oz`, which makes it more than a quarter smaller than `-O2`. The Makefile joins
it after `mon.nasm`, with nice_cpu's `lib.nasm` and `muldiv_mpu.nasm`.
`fat32.c` is FAT32 (README.md, "Files"), about 7100 words.

- **Calls.** Every function of the C code that is not `static` is
  exported, and the monitor's assembly calls it as `_name`, in the C ABI;
  the entries 9 to 15 jump to `fat32.c`'s `fat_mount` to `fat_delete`.
  Their names in `mon.nasm` and `mon.h` are `fs_mount` to `fs_delete`,
  as the stubs `_fs_mount` to `_fs_delete` of `mon.nasm`, which the
  monitor joins for `monlib.nasm`, would clash with C functions of those
  names.
  The C code calls the monitor's routines by their labels too: they are
  undefined in the module, and the assembler finds them, such as
  `_fat_sd_read` and `_fat_sd_write`, which turn the C code's byte
  address of a buffer into a word address for `sd_read` and `sd_write`.
- **The RAM.** The words that the module writes, its mutable globals and
  its memory, with its stack of 4096 bytes, are in the RAM from
  `WASM_RAM`, `0xFFFFF400`, up to below `WASM_END`, `0xFFFFFF00`, with the
  monitor's variables. The Makefile checks `___wasm_ram_end`, the word
  after them, against `WASM_END`. The module may use no floats and no
  `malloc`, which `--ram` rejects.
- **The cold start** calls `___wasm_start`, which copies the initial
  values to the RAM and sets the rest of the module's memory to 0, at
  every start, also after `r 0`, which leaves the rest of the RAM alone.
- **The vectors** that `lib.nasm` jumps through are words of the
  variables, `0xFFFFF300` and `0xFFFFF301`, which the cold start sets:
  `___putc_vector` to `mon_putc`, so that `nice_print` prints on the
  outputs of `mon_out`, and `___wasm_trap_vector` to `mon_trap`. A
  program at `0x8000` that joins `lib.nasm` has its own vectors.
- **A trap** of the C code prints `Trap N at ADDR`, with the trap's code
  of nice_cpu's WASM.md in decimal and its address in hex, and goes back
  to the main loop as a program's return does, with the state that
  `mon_exit` restores. So a trap does not halt the core, also when a
  program called the C code.

## Building and testing

`make -C monitor` assembles `monitor.nasm`, `monitor_dis.nasm`,
`monitor_sd.nasm`, `monitor_eth.nasm`, `monlib.nasm`, `mon.nasm`,
`build/rom_c.nasm`, nice_cpu's `lib.nasm` and `muldiv_mpu.nasm`, and
`build/version.nasm`, the `cat` of them, with `niceasm` into
`build/monitor.bin`, as the assembler has no include. `build/rom_c.nasm`
is the ROM's C code (C in the ROM above), so the monitor, and a
bitstream with it in the ROM, needs clang with the wasm32 target,
`wasm-ld`, and `llvm-ar` (on Debian and Ubuntu, the `clang`, `lld`, and
`llvm` packages). The test's images need `mkfs.fat`, `sfdisk`, and
mtools (`dosfstools`, `fdisk`, and `mtools`). `test/fat_image.py` makes
them with these tools, so FAT32 is tested against them: a card with an
MBR, a FAT16 partition, and a FAT32 one, whose root has a volume label,
another core's folder, a `HELLO.BIN` that is not NiceMon's, and the
folder `NICE`, with a subdirectory, a long name, a name in lower case, 20
more files past its first cluster, deleted entries, and `FRAG.BIN`, whose
clusters are not contiguous; a card that is FAT32 on the whole, with no
partition table; a card without `NICE`, and one whose `NICE` is a file; a
FAT16 card; an exFAT one; and a FAT32 card whose free clusters are
marked bad but the last three, so that a write fills it. After a test
that writes, `test/fat_check.py` checks the card with `fsck.fat -n`, and
lists the folder and shows the files written with `mdir` and `mtype`. `version.nasm` defines `VERSION`, the string of the
banner, `git describe` of the tree unless `VERSION=` is given, and is
written only when it changes.

`make -C monitor test` checks the layout of the sources with nice_cpu's
`nicefmt`, checks that the monitor ends below `DEMO`, where the demo
goes in the ROM, assembles the monitor with the version `V9.9`, and runs
it in `niceemu` twenty times, with its keystrokes in an input file and
`h` as the last command, so that the run ends: alone, with every command
and the edits of a line; alone, with 448 rows of `d`, which go round the
ring of the history, and Page Up and Page Down; alone, with `l` and
`build/hello.bin` pasted, lines that are skipped, tabs, a line of
blanks, a line too long, a second line for an address, and CTRL-C, then
`r`, with 128K words of RAM, as on the MEGA65, which a word of the
input file gives `0xFFFFFF9E`; alone, with `l` at the bounds of 64K
words, as on the Nexys4DDR; alone, with `l` where `0xFFFFFF9E` reads 0,
as in `niceemu`; alone, with `sd` on the image of `test/sd_image.py`
in slot 0, 4 sectors, and none in slot 1: a sector with every byte, the
last sector, the one after it, the empty slot, the slot of the last `sd`,
a slot that the system does not have, and arguments that are not; with
`test/sd.nasm` at `0x8000`, which calls `sd_init`, `sd_read`, and
`sd_write` by their labels, as it is assembled after the monitor's
sources, and writes a sector, which `sd` then shows, and the image is
compared with the one that `test/sd_image.py --written` makes; with
`test/arp.nasm` at `0x8000`, built as `test/sd.nasm` is, which calls
`arp_resolve` with the frames of `test/arp.eth` and `--step-time`: a
reply after frames that are not, the cache, an address with no reply, an
entry aged out, and the cache filled and gone round, and its frames sent
are compared too; with `test/udp.nasm` at `0x8000`, built as
`test/arp.nasm` is, which calls the UDP entries with the frames of
`test/udp.eth`: each error, a datagram sent after ARP, a broadcast, two
received after frames that are no datagram for the endpoint, one cut
short, one sent through the gateway, and its frames sent are compared
too; with `test/rom.c` joined to the ROM's C code, in
`build/rom.bin`, the monitor of the tests with `test/rom.nasm` at
`0x8000`, which calls its functions by their labels: the initial value
of a global, a static array set to 0, both again after `r 0`,
`nice_print`, and a trap, whose address is compared as the label it
must be; with `test/fs.nasm` at `0x8000`, which calls the file entries
through `mon.nasm`'s stubs, with the images of `test/fat_image.py` in
both slots: handles, reads across the fragments of a file and at its end,
the folder's entries, each error that a program can cause, and
mounts; with `test/fsw.nasm` at `0x8000`, which calls the entries that
write, on a copy of the card with the partitions, one of whose files is
read-only, and a write-protected copy of the card with none: a file
written in three pieces across clusters and read back, a file
truncated, a file of ten clusters, deletions, one of a long name, the
folder filled until it takes a new cluster, a mount that drops a file
open to write, and each error that a program can cause; with the
commands `dir` and `load` on those images, the
fragmented `FRAG.BIN` and a text file loaded, the errors and the
arguments that are not, and `HELLO.BIN` loaded and run; with `dir` on a
FAT16 and an exFAT card; with `dir` and no card in slot 0, which mounts
slot 1; with `dir` and `load` on the cards without the folder, which fail
with error 29; with `save`, `load`, `dir`, and `del` on a copy of the
card with no partitions, a program saved and loaded back, a file
truncated and deleted, and the arguments that are not, and on a copy of
the card that a write fills, which `save` fills with error 30, and
which has room again after `del`; with `test/hello.nasm` at `0x8000`, an assembly program under
nice_cpu's `start_mon.nasm`, also after `r 0`; and with `test/hello.c`,
built with `nicebuild.py --monitor --asm mon.nasm`. The console output, which is the copy on the line, a few
memory words, and the screen are compared with `test/NAME.expected`. The
expected files were checked by hand; after a change that moves them,
check the new output the same way before copying it from `build/`.
`test/ring.py` checks the ring of the history first, at the sizes of the
screen's memory of `niceemu` and the MEGA65, 32768 words, of the
Nexys4DDR, 8192, and of 2048, which has no room for it, with the monitor
built to take each size: it reads the rows a board would show from the
dump of the memory, at the display offset the monitor set, and compares
them with the console output, with the history filled in part and gone
round, after Page Ups, Page Downs, and a key that shows the screen
again. `test/dis.py` runs `u` over `test/dis.nasm` at `0x8000`, which
has every opcode, operand mode, condition, and modifier, the control
instructions, the reserved control words, unused fields that are not R0,
the pairs that are `CALL` and `RET` and those that are not, and the
words of the other pseudo-instructions, with a register, a constant, a
memory operand, and a condition each, the words that match two of them,
and the near-misses. It compares each row with nicedis.py's text, or,
for a pseudo-instruction, with nicedis.py's text rewritten by the rules
of README.md, "The disassembler", and assembles it with `niceasm` and compares the words. It checks
that each pseudo-instruction occurs, and that `u` without `ADDR` goes on
after the last row. `test/dhcp.py` runs `i dhcp` with `--step-time`, so
that each run takes the same steps: first with no server, which gives it
the transaction's number, and then with the OFFER and the ACK that it
builds from it, among frames that are not for the monitor and an OFFER
without an address, and with a NAK, which starts again. It compares the
output and the frames sent, with the transaction as `xx`, with
`test/dhcp.expected`, and checks the IPv4 checksums. `test/tftp.py`
runs `tftp` the same way: first with no server, which gives it the
client's port, and then with a file of two blocks among packets of
another host and another port and a DATA again, with a DATA and an ACK
lost, with an ERROR, with a file of 512 bytes, and with an empty file,
with a listing, with the request to port 6969 of `IP:PORT`, and with
the arguments that are not, no IP address, and no answer to ARP. It compares the output and the frames sent, with the client's port
as `pp pp`, with `test/tftp.expected`, and checks the IPv4 checksums
and the ports. `make tftptest`, in the repository's root, runs the
monitor against `tools/tftpd.py` itself (CONTRIBUTING.md).

On a board, `make r6` builds a bitstream that boots the monitor, with the
demo behind it in the ROM. `make hwtest` loads the same, with the
versions of the tests, into the RAM, and types `x` for the demo
([demo/](../demo/README.md), and README.md, "The demo").
