# The monitor's internals

What the ROM has for itself, behind the dispatch table of
[README.md](README.md): the routines with no entries, which only the
monitor's commands and its C code call, the scrollback, the C in the
ROM, the ROM's words, and the build and the tests. A program does not call these routines, as they have no
entries and their addresses change with every build; it calls the
entries, or drives the registers itself.

## The sector routines

The ROM has three sector routines of its own, with no entries in the
dispatch table ([doc/SDCARD.md](../doc/SDCARD.md), "The ROM"). They drive
the controller's registers at `0xFFFFFFA0`, which [nice_cpu's SYSTEM.md §5](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#5-sd-card)
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
- FAT32 (README.md, "Files") calls the routines, and its file API is
  the table's entries for the card. A program that wants sectors drives
  the registers itself, and calls `fs_mount` before it uses the files
  again.

## The frame routines

The ROM has frame routines of its own, with no entries in the dispatch
table, as the sector routines have none. They drive the port for
Ethernet frames at `0xFFFFFFC0`, which [nice_cpu's SYSTEM.md §7](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#7-ethernet-frames)
specifies, the same on every board and in `niceemu`, and follow the C
ABI. A frame is in RAM as the port's buffers have it: from byte 2 of its
buffer, 4 bytes a word, big-endian, so that the fields fall on the words
of [SYSTEM.md §7](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#7-ethernet-frames).

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
  address, or else the next in turn. It polls while it waits, as below.
  The port must be enabled. The station answers the requests for its
  own address itself.
- **The poll** (issue #111), `net_step`, which `net_poll` is too, takes
  the frames that wait, up to the queue's 4, where they go, and releases
  each. It copies the first 16 words of a frame, its headers, to
  `0xFFFFF390`, and decides from them. An ARP reply, to anyone, is
  learned from there, in place, so ARP never touches the buffer of a
  frame received, `V_RXF` at `0xFFFFF180`. A datagram for the endpoint
  is copied to `V_RXF`, and held there for `udp_recv`, unless one is
  held already; then it is dropped. A datagram to the port of the ROM's
  own wait, 68 while `i dhcp` or `net_dhcp` waits, is copied to `V_RXF`
  too, in place of a datagram held, which is lost, and the poll stops
  there, so that the wait parses it. Every other frame is released
  unread. The UDP entries, `arp_resolve`, and the waits of DHCP poll.
- **The network is on** while the endpoint is open or `net_dhcp` runs.
  `net_on` enables the port only if it is disabled, so it does not empty
  the queue of an open endpoint, and `net_off` disables it only when the
  endpoint is closed. The cold start, `mon_exit`, and `mon_trap` close
  it all with `net_close`.
- **The clocks.** The fine clock, `net_clock`, is the microsecond
  counter plus `0xFFC2F700`, so that it wraps 4 seconds after reset, and
  every run crosses a wrap. A deadline on it is due when the signed
  difference of the clock and the deadline is not negative. The poll
  checks the nearest deadline only while a flag says it is armed, so a
  stale one is never due. Nothing arms one yet: TCP and the lease's
  renewal will. The coarse clock is `arp_tick`, about a second.
- **The identification** of each IPv4 packet sent, of UDP and of DHCP,
  counts up by one from the fine clock at the cold start, with the
  "don't fragment" bit clear (RFC 6864).
- `i dhcp` and `tftp` (README.md, "The network") use the frame
  routines, and `udp_send` calls `arp_resolve` for the MAC address of a
  datagram's host, or of the gateway. Programs do not call them: they
  have no entries, so their addresses change with every build.
  `test/arp.nasm` calls `arp_resolve` by its label, as `test/sd.nasm`
  calls the sector routines, as both are assembled after the monitor's
  sources (Building and testing below).

## The scrollback

The history is a ring of rows in the screen's memory past its 2000
words, from the top of the memory down. Before `mon_putc` moves the rows
up, it copies row 0 into the ring. The cold start finds the size of the
memory from the display offset, which a board keeps only in the bits
that address the memory: 32768 words on the MEGA65 and 8192 on the
Nexys4DDR, so one `monitor.bin` serves every board. `k` rows back is the
display offset `size - 80k`, which wraps to row 0 of the screen, with
the cursor off. The first key that scrolls back turns the ring so that
its newest row is the last of the memory. In `niceemu` the display
offset is plain memory, so all its bits are kept: the history has 384
rows there, which `d` and `--dump` read.

## C in the ROM

Part of the ROM is C, through nice_cpu's wasm translator: the FAT32
code and the clock's. The files
of the Makefile's `ROM_C`, `fat32.c` and `clock.c`, are compiled to one wasm
module, which `nicewasm --ram` translates for code
that runs from a ROM (nice_cpu's translator README, "Code in a ROM"),
at `-Oz`, which makes it more than a quarter smaller than `-O2`. The Makefile joins
it after `mon.nasm`, with nice_cpu's `lib.nasm` and `muldiv_mpu.nasm`.
`fat32.c` is FAT32 (README.md, "Files"), about 9100 words, and
`clock.c` the `time` command, the dates of FAT's entries, and the clock
set from the MEGA65's real-time clock at the cold start and written by
`time`, through the I2C master (doc/SYSTEM.md, "The I2C bus"), about
1200 words, small rather
than general, as its header says.

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

## The ROM's words

The ROM has 32768 words, at `0x0000`–`0x7FFF`. The monitor fills it
from 0, and the rest is free. The demo is no longer in it (#129): it is
a program, `demo.bin`, whose words
[demo/README.md](../demo/README.md#its-words) counts.

<!-- romsize layout -->
| Part | Address | Words |
|---|---|---:|
| The monitor | `0x0000`–`0x4CF0` | 19697 |
| Free | `0x4CF1`–`0x7FFF` | 13071 |
<!-- /romsize layout -->

The monitor's words, by the source they come from, in the order
the Makefile joins them. The column "Text" counts the words of the
`.ASCII_L` strings, one character a word, which are part of
"Words":

<!-- romsize monitor -->
| Source | What it is | Words | Text |
|---|---|---:|---:|
| `monitor.nasm` | The dispatch table, the HAL, the cold start, and the traps | 725 | 27 |
| `monitor_cmd.nasm` | The main loop and the commands | 3949 | 2394 |
| `monitor_dis.nasm` | The disassembler of `u` | 1079 | 269 |
| `monitor_sd.nasm` | The sector routines | 390 | 223 |
| `monitor_eth.nasm` | The network | 2312 | 298 |
| `monlib.nasm` | The routines that programs join | 259 | 0 |
| `mon.nasm` | The stubs of the entries | 58 | 0 |
| `nicewasm` | `___wasm_start`, which copies the C code's data to the RAM | 85 |  |
| `fat32.c` | FAT32 | 9102 |  |
| `clock.c` | The clock and `time` | 1199 |  |
| nice_cpu's C library | `nice_print` | 53 |  |
| `nicewasm` | The helpers of the translated code: loads, stores, and traps | 125 |  |
| `nicewasm` | The initial values of the C code's data: its strings and tables | 70 |  |
| nice_cpu's `lib.nasm` | The runtime of the C code | 131 | 0 |
| nice_cpu's `muldiv_mpu.nasm` | Multiply and divide | 128 | 0 |
| `build/folder.nasm` | The error of a card without the folder | 27 | 27 |
| `build/version_test.nasm` | The version in the banner, the tests' `V9.9` | 5 | 5 |
| In all | | 19697 | 3243 |
<!-- /romsize monitor -->

- The C code's strings are in its initial values, four characters a
  word, so the column "Text" leaves them out.
- The version is that of the tests, `V9.9`, so that the tables do not
  change with every commit. A release's version, such as `V2.1`, has
  as many words.

### Keeping the tables

`tools/romsize.py` writes the tables above. It joins the sources as
the Makefiles do, with a label in front of each part and of each
`.ASCII_L` string, assembles them with `niceasm.py --symbols`, and
takes each part's words from the labels' addresses. The words it
assembles must be those of the build, so a label never moves one.
`make -C monitor test` checks the tables of the ROM and the monitor,
and `make -C demo test` the demo's, in `demo/README.md`. Each fails when
a table differs from the build. `make romsize` writes the new tables.

## Building and testing

### What the build needs

- **For the monitor:** clang with the wasm32 target, `wasm-ld`, and
  `llvm-ar`, for the ROM's C code. On Debian and Ubuntu these are the
  `clang`, `lld`, and `llvm` packages. A bitstream with the monitor in its
  ROM needs them too.
- **For the tests:** also `mkfs.fat`, `sfdisk`, and mtools, from the
  `dosfstools`, `fdisk`, and `mtools` packages, for the images of the SD
  cards, and nice_cpu's `niceemu`.

### The build

`make -C monitor` writes `build/monitor.bin`. The assembler has no
include, so the Makefile joins the sources with `cat` and assembles the
result with `niceasm`. In this order:

1. `monitor.nasm`, `monitor_cmd.nasm`, `monitor_dis.nasm`,
   `monitor_sd.nasm`, `monitor_eth.nasm`, `monlib.nasm`, and `mon.nasm`.
2. `build/rom_c.nasm`, the ROM's C code (C in the ROM, above).
3. nice_cpu's `lib.nasm` and `muldiv_mpu.nasm`.
4. `build/version.nasm`, which defines `VERSION`, the text of the
   banner: `git describe` of the tree, or the `VERSION=` of the command
   line.
5. `build/folder.nasm`, the text of error 29, with the card's folder
   (README.md, "Files").

`version.nasm` and `folder.nasm` are written only when they change, so
that the monitor, and a bitstream with it, is not built again for
nothing. The build fails if the monitor reaches `DEMO`, where the demo
starts in the ROM.

### The tests

`make -C monitor test` runs everything in `niceemu`, with no board. The
monitor of the tests, `build/monitor_test.bin`, has the version `V9.9`,
so that the expected output does not change with every commit. The test
needs `FOLDER=NICE`, the default. It runs these steps in order:

1. **The layout.** nice_cpu's `nicefmt` checks the sources and the
   tests' `.nasm` files.
2. **The scrollback.** `test/ring.py` checks the ring of the history at
   three sizes of the screen's memory: 32768 words, as in `niceemu` and
   on the MEGA65, 8192, as on the Nexys4DDR, and 2048, which has no room
   for it. For each, it reads the rows a board would show from a dump of
   the memory, and compares them with the console output. It does this
   with the history partly filled and gone round, and after Page Up, Page
   Down, the cursor keys, and a key that shows the screen again.
3. **The disassembler.** `test/dis.py` runs `u` over `test/dis.nasm`,
   which has every opcode, operand mode, condition, and modifier, the
   control instructions, the reserved words, and each pseudo-instruction
   with its near-misses. It compares each row with the text of
   `nicedis.py`, rewritten by the rules of README.md, "The disassembler",
   for a pseudo-instruction. It assembles each row again and compares the
   words.
4. **DHCP.** `test/dhcp.py` runs `i dhcp` with `--step-time`, so that
   each run takes the same steps. A first run with no server gives the
   transaction's number. Then it builds the OFFER and the ACK, among
   frames that are not for the monitor, an OFFER without an address, and
   a NAK. Two more runs call `net_dhcp`, entry 23, from
   `test/netdhcp.nasm`, with the endpoint open: with no server, and with
   one, and an ARP reply that is learned while it waits. It compares the
   output and the frames sent with `test/dhcp.expected`, and checks the
   IPv4 checksums, the identification, which counts up by one, and that
   DF is clear. The transaction, the identification, and the checksum
   change with the steps of the code, so the expected file has them as
   `xx`, `ii`, and `cc`.
5. **TFTP.** `test/tftp.py` runs `tftp` the same way, against
   `test/tftp.expected`. It covers a file of two blocks among packets of
   other hosts and ports, lost packets, an ERROR, files of 512 and 0
   bytes, a listing, a port given as `IP:PORT`, bad arguments, and no
   answer to ARP.
6. **The real-time clock.** `test/rtc.py` starts the monitor on the
   words of an I2C master, which are memory in `niceemu`: a status that
   says that a master is present, and data that are the registers of the
   R6's real-time clock. With `--step-time` the clock is not set, so the
   cold start reads them, and `time` shows the result. It covers dates
   and times that the chip holds, the chip's flags that say that it lost
   its time, no master, a digit over 9 in each register, and numbers
   that are no date or time. Then it types `time` with a date and a
   time, and checks the master's command: left alone without a master,
   and in a year that the chip does not hold. The R3's chip is read only
   when the R6's does not answer, which memory cannot do, so that part
   runs only on an R3.
7. **The runs.** The monitor runs once for each test below, with its
   keystrokes from an input file that ends with `h`, so that the run
   halts. Some runs add a program at `0x8000`, SD card images, or
   Ethernet frames.

Each run's console output, a few memory words, and the screen are
compared with `test/NAME.expected`:

| Test | What runs | What it checks |
|---|---|---|
| `cmds` | The monitor alone | Every command, its bad arguments, and the edits of a line. |
| `scroll` | The monitor alone | 448 rows of `d`, which go round the history, and Page Up and Page Down. |
| `load` | The monitor, with 128K words of RAM, as on the MEGA65 | `l` with `build/hello.bin` pasted: CR LF and LF line ends, tabs, blank lines, skipped lines, a line too long, an address given twice, and CTRL-C. Then `r` runs it. |
| `load_64k` | The monitor, with 64K words, as on the Nexys4DDR | `l` at the end of that RAM. |
| `load_emu` | The monitor, with `0xFFFFFF9E` reading 0, as in `niceemu` | `l` up to the screen. |
| `sd_write` | `test/sd.nasm`, with a card of 4 sectors in slot 0 and none in slot 1 | `sd_init`, `sd_read`, and `sd_write`: the empty slot, a sector read and written, and the sector past the end. The card must then equal the image of `test/sd_image.py --written`. |
| `arp` | `test/arp.nasm`, with the frames of `test/arp.eth` | `arp_resolve`: a reply after other frames, the cache, no reply, an entry aged out, and the cache filled and gone round. The frames sent are compared too. |
| `udp` | `test/udp.nasm`, with the frames of `test/udp.eth` | The UDP entries: each error, a datagram sent after ARP, a broadcast, datagrams received among other frames, one cut short, and one sent through the gateway. The frames sent are compared too. |
| `net` | `test/net.nasm`, with the frames of `test/net.eth` | The poll and the IP settings of issue #111: `net_config` at a word-window address and a plain one, `net_set`, `net_poll`, a datagram held and a second dropped, ARP replies learned in place, so that no request goes, a TCP segment released, and a deadline armed, not due, and due. The frames sent are compared too. |
| `rom` | `build/rom.bin`: the monitor with `test/rom.c` in its C code, and `test/rom.nasm` | The C code in the ROM: a global's initial value, a static array set to 0, both again after `r 0`, `nice_print`, and a trap, whose address must be the label `_rom_trap`. |
| `fs` | `test/fs.nasm`, with FAT images in both slots | The file entries, through `mon.nasm`'s stubs: handles, reads across the fragments of a file and at its end, the folder's entries, mounts, each error a program can cause, and `fs_readname`'s long name and 8.3 name in lower case, and a file opened by its long name. |
| `fsw` | `test/fsw.nasm`, with a copy of the card with partitions, one file read-only, and a write-protected card | The entries that write: a file written in pieces across clusters and read back, truncated, a file of ten clusters, deletions, one of a long name, a folder that grows a cluster, a mount that drops an open file, and each error. |
| `fat` | The monitor, with FAT images in both slots | `dir` and `load`: the fragmented `FRAG.BIN`, a text file, bad arguments, and `HELLO.BIN` loaded and run. |
| `fatw` | The monitor, with a copy of the card without partitions, and one that a write fills | `save`, `load`, `dir`, and `del`: a program saved and loaded back, a file truncated and deleted, bad arguments, and a full card, error 30, which has room again after `del`. |
| `fatl` | The monitor, with `lfn.img`, long names that mtools wrote | `dir` and `load` by long names, in quotes and in either case, and by 8.3 names: a long name with a blank, one in mixed case, one of 255 characters, one outside ASCII, an 8.3 name with the lower-case flags, sets of long-name entries across a sector and across a cluster, and one with a wrong checksum, which only its 8.3 name reaches. |
| `fatlw` | The monitor, with a copy of `lfn.img` | `save` of long names: the aliases with no tail, `~1`, and `~3`, by the 8.3 names that mtools left, a name in lower case with byte 12's flags, a truncation by the 8.3 name, names that are not valid, and a long name in the run of entries that two deletions freed; `fsck.fat -n`, `mdir`, and `mtype` check the card. |
| `fatbad` | The monitor, with a FAT16 card and an exFAT card | `dir` rejects each. |
| `fat1` | The monitor, with no card in slot 0 | `dir` mounts slot 1. |
| `fatnone` | The monitor, with a card without the folder `NICE`, and one whose `NICE` is a file | `dir` and `load` fail with error 29. |
| `time` | The monitor, with `--step-time` and a copy of the card without partitions | `time` not set, set, and shown; dates that are not, such as leap days of years without one, fields of one digit, and 2106, and the edges that are, 2000-02-29, 2100-03-01, 2104-02-29, 2^31 seconds, and 2105-12-31; and the dates of `save`, from the clock and while it is not set or before 1980, which `mdir` shows. |
| `hello` | `test/hello.nasm`, under nice_cpu's `start_mon.nasm` | A program in assembly, run with `r`, that returns to the monitor. |
| `reset` | The same | `r 0`, the cold start, and `r` again. |
| `hello_c` | `test/hello.c`, built with `nicebuild.py --monitor --asm mon.nasm` | A program in C. |

`sd_write`, `arp`, `udp`, `net`, and `rom` call the monitor's routines
or reach its variables by their labels, so they are assembled after the
monitor's sources, and only their words from `0x8000` are kept. `fs`,
`fsw`, `hello`, and `hello_c` call the entries through `mon.nasm`'s
stubs, as any program does, and so do `udp` and `net`. `arp`, `udp`, and
`net` run with `--step-time`, as their timeouts count steps, and
`time` too, so that its clock starts at 0, not set, and counts the same
each time. The other tests run with the host's clock, so the files they
write have the host's date, which no test shows.

`niceemu` has no I2C master: its status word is memory, which reads 0,
so the cold start of every run finds none, and `time` shows that the
clock is not set. `test/rtc.py` alone sets that memory, as step 6 says.
The I2C bus and the chip are tested in the simulated
system, whose bus has a model of the R6's real-time clock: `make
cosimtest` runs the monitor's cold start there, and checks the clock
after it, and then types `time` with a date and a time, and reads the
model back (CONTRIBUTING.md).

The comments above each input in the Makefile say what each keystroke
tests.

### The cards of the tests

`test/fat_image.py` makes the FAT images with `mkfs.fat`, `sfdisk`, and
mtools, so that the monitor's FAT32 is tested against those tools:

- `fat32.img`: an MBR with a FAT16 partition and a FAT32 one. Its root
  has a volume label, another core's folder, a `HELLO.BIN` that is not
  NiceMon's, and the folder `NICE`. `NICE` has a subdirectory, a long
  name, a name in lower case, 20 more files past its first cluster,
  deleted entries, and `FRAG.BIN`, whose clusters are not contiguous.
- `super.img`: FAT32 on the whole card, with no partition table.
- `nonice.img`, without the folder `NICE`, and `nicefile.img`, whose
  `NICE` is a file.
- `fat16.img` and `exfat.img`.
- `full.img`: FAT32 with all free clusters marked bad but three, so
  that a write fills it.

After `fsw` and `fatw`, `test/fat_check.py` checks the cards that were
written: `fsck.fat -n`, the folder with `mdir`, and the files written
with `mtype`.

### The expected files

The expected files were checked by hand. After a change that alters an
expected output, check the new output the same way before you copy it
from `build/` to `test/`. The `Halted` line and the registers are left
out, as they change with the code, except for VBASE, which must be 0
after every run.

`make tftptest`, in the repository's root, runs the monitor against
`tools/tftpd.py` (CONTRIBUTING.md).

### On a board

`make r6` builds a bitstream that boots the monitor, with the demo
behind it in the ROM. `make hwtest` loads the same, with the versions of
the tests, into the RAM, and types `x` for the demo
([demo/](../demo/README.md), and README.md, "The demo").
