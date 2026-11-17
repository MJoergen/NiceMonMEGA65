# The monitor's internals

What the ROM has for itself, behind the dispatch table of
[README.md](README.md): the routines with no entries, which only the
ROM's statements call, FAT32, the scrollback, the ROM's words, and the
build and the tests. A program does not call these routines, as they
have no entries and their addresses change with every build; it calls
the entries, or drives the registers itself.

- [The sector routines](#the-sector-routines)
- [The frame routines](#the-frame-routines)
- [FAT32](#fat32)
- [The scrollback](#the-scrollback)
- [The ROM's words](#the-roms-words)
  - [Keeping the tables](#keeping-the-tables)
- [Building and testing](#building-and-testing)
  - [What the build needs](#what-the-build-needs)
  - [The build](#the-build)
  - [The tests](#the-tests)
  - [The cards of the tests](#the-cards-of-the-tests)
  - [The expected files](#the-expected-files)
  - [On a board](#on-a-board)

## The sector routines

The ROM has three sector routines of its own, with no entries in the
dispatch table ([doc/SDCARD.md](../doc/SDCARD.md), "The ROM"). They drive
the controller's registers at `0xFFFFFFA0`, which [nice_cpu's DEVICES.md §5](https://github.com/MJoergen/nice_cpu/blob/main/doc/DEVICES.md#5-sd-card)
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
Ethernet frames at `0xFFFFFFC0`, which [nice_cpu's DEVICES.md §7](https://github.com/MJoergen/nice_cpu/blob/main/doc/DEVICES.md#7-ethernet-frames)
specifies, the same on every board and in `niceemu`, and follow the C
ABI. A frame is in RAM as the port's buffers have it: from byte 2 of its
buffer, 4 bytes a word, big-endian, so that the fields fall on the words
of [DEVICES.md §7](https://github.com/MJoergen/nice_cpu/blob/main/doc/DEVICES.md#7-ethernet-frames).

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
  own wait, 68 while `DHCP` or `net_dhcp` waits, or `getline` while
  DHCP runs in the background, or the query's port while `dns_lookup`
  waits, is copied to `V_RXF` too, in place of a datagram held, which is lost, and the poll stops
  there, so that the wait parses it. Every other frame is released
  unread. The UDP entries, `arp_resolve`, and the waits of DHCP and DNS
  poll.
- **The network is on** while the endpoint is open, or `net_dhcp` or
  `dns_lookup` runs, and while `getline` waits for the first key of a
  line with DHCP in the background or a lease kept. `getline` disables
  the port again when the key comes.
  `net_on` enables the port only if it is disabled, so it does not empty
  the queue of an open endpoint, and `net_off` disables it only when the
  endpoint is closed. The cold start and `mon_exit` close it all with
  `net_close`.
- **The clocks.** The fine clock, `net_clock`, is the microsecond
  counter plus `0xFFC2F700`, so that it wraps 4 seconds after reset, and
  every run crosses a wrap. A deadline on it is due when the signed
  difference of the clock and the deadline is not negative. The poll
  checks the nearest deadline only while a flag says it is armed, so a
  stale one is never due. TCP's connections arm theirs (below), and
  so does the lease. The coarse clock is `arp_tick`, 2^20
  microseconds, about a second.
- **The lease** (issue #111). `net_dhcp` and `DHCP` keep the lease of
  the ACK: its server, the MAC address that the ACK came from, and T1,
  T2, and the end, options 58, 59, and 51, on the coarse clock. Without
  T1 and T2 they are half and 7/8 of the lease. A lease of
  `0xFFFFFFFF` is not kept. While the network is on, a housekeeping
  deadline on the fine clock stands for the next REQUEST, at most 2^30
  microseconds ahead, and the poll checks the coarse clock when it is
  due. From T1 a REQUEST goes to the server by unicast every 60 ticks,
  and from T2 it is broadcast, until the end. It comes from the board's
  address, with it in `ciaddr`, no options 50 and 54, and the broadcast
  flag clear (RFC 2131 §4.3.2). The poll gives a reply to the lease's
  transaction to `lease_reply` in `V_RXF`. An ACK starts the lease
  again, and writes `NET_IP` if its address is another. A NAK, or the
  end, forgets the lease, and the address stays. A REQUEST that is due
  while `net_dhcp` or `dns_lookup` waits goes a tick later, as they use
  `V_TXF`. `net_set`, `IP "A.B.C.D"`, and the cold start forget the
  lease.
- **DHCP in the background** (issue #126). The cold start begins it
  with `bg_start` when `NET_IP` is 0, with a transaction of its own.
  `getline_wait`, while it waits for the first key of a line, enables
  the port, polls with `V_NWAIT` at 68, and gives the frame to
  `bg_step`. `V_BSTATE` is the reply that it waits for, an OFFER or an
  ACK, and `V_BDUE` the time of the next DISCOVER on the fine clock,
  which waits `V_BWAIT` microseconds after it, doubled each time. It
  shares `dhcp_send`, `dhcp_parse`, and `dhcp_commit` with `net_dhcp`.
  An ACK sets the address and keeps the lease, and `bg_show` prints the
  line on the empty line after `READY.`. `IP`, `net_set`, and `net_dhcp` end it, and so
  does an address that a host writes, as `bg_step` stops when `NET_IP`
  is not 0.
- **DNS** (issue #111), `dns_lookup`, entry 25, builds its query in
  `V_TXF` at `0xFFFFF120`, the name packed from byte 56, with one
  question, type A, class IN, and RD set. Its ID, at `0xFFFFF388`, and
  its local port, 49152 to 65535 and not the endpoint's, come from the
  fine clock. The next hop's ARP, by `net_hop`, as `udp_send` finds it,
  writes only the first 11 words of `V_TXF`, below the message, so the
  name is checked and packed before the ARP, and a bad name sends
  nothing. The query goes again after 2 seconds, 3 times in all, with
  the same ID and port. `dns_parse` skips a name up to its 0 byte or its
  first compression pointer, which ends it: the names are never compared,
  so no pointer is followed, and a loop of pointers costs nothing.
- **TCP** (issue #111), `monitor_tcp.nasm`, entries 26 to 31, keeps
  each connection in the program's control block: 32 words, a check
  word first, then the rings, received and sent, packed 4 bytes to a
  word. `V_TCB` at `0xFFFFF3A0` has the plain address of each handle's
  block, 0 when it is free. A connection's one deadline, `CB_DUE`, is
  on the fine clock: the SYN's or a segment's timeout, or the end of
  FIN-WAIT-2. It is never later than the time to give up, so the
  connection ends in `E_TTIMEOUT` on time. `tcp_rearm` gives the poll
  the nearest deadline of all. A segment that wants an ACK sets a flag,
  and the poll sends one ACK for all of them, by `tcp_work`. The
  checksum of a segment's data is summed in a pass of its own over the
  ring, not as the bytes are copied, so the copy stays simple.
- **Listening.** A handle of `tcp_listen` has the flag `TF_PASSIVE`
  for its whole life, and waits in the state LISTEN. A SYN that fits no
  connection goes to the first handle in LISTEN on its port, which
  takes the peer's address and port, and the MAC address of the frame's
  source, so no ARP is sent. When the port has handles of `tcp_listen`,
  but none in LISTEN, the SYN is passed over, with no RST, and the peer
  sends it again. A failed handshake, by a RST, 15 seconds with no ACK,
  or a new IP address, goes through `tcp_fail`, which puts a handle in
  SYN-RECEIVED back in LISTEN, with the bytes that `tcp_send` took.
- **The identification** of each IPv4 packet sent, of UDP, DHCP, and
  DNS, counts up by one from the fine clock at the cold start, with the
  "don't fragment" bit clear (RFC 6864).
- `DHCP`, `NTP`, and TFTP (README.md, "The network") use the frame
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
rows there, which `DUMP` and `--dump` read.

## FAT32

`monitor_fat.nasm` is FAT32 (README.md, "Files"), in NICE assembly, as
all of the ROM is. The order of its sector writes is in its header, and
the tests pin it (The tests, below).

- **Entries.** The entries 9 to 15 and 20 of the dispatch table jump to
  `fs_mount` to `fs_delete`, and `fs_readname`. The statements call
  `fat_dir`, `fat_load`, `fat_save`, and `fat_complete` (TAB) by their
  labels. Each sets R6 to its body and goes to `fat_call`, which saves
  R7-R12 and SP, so the body uses every register.
- **Errors.** A routine that meets an error jumps to `fat_fail` with
  the negative error in R1, which takes SP back to that of `fat_call`
  and returns R1 from the entry. So no routine checks the result of
  the one it called, and the state is as the error left it. An error
  of the SD controller other than 6, write-protected, and 7, a sector
  after the last, drops the mount and closes the files first (`chk`),
  as the card's state is not known: on the R3's slot 1, which has no
  card detect, a swapped card stays "ready" and times out until the
  next start-up. `fat_call` then runs the routine once more, with its
  R1-R4, when a mount stood and no file was open at the start, so the
  retry mounts again; with a file open, its handle is gone, and the
  error goes to the caller.
- **The RAM.** The state is in the variables from `FAT_RAM`,
  `0xFFFFF980`, up to below the I/O page (`monitor.nasm`): the mounted
  volume, the sector of the FAT in `FATBUF`, a sector `SEC`, the names
  `LNAME` and `WANT`, a character a word, and the folder `DIRF` and the
  two files, each with its sector. Only the cold start clears it, with
  `fat_reset`, so a program's return keeps the mount and the open
  files.
- **The stack.** The entries run on the caller's stack. The deepest
  takes 27 words of it with the return address: 21 as measured in the
  tests in `niceemu`, and the 6 that `fat_call` keeps for a retry.

## The ROM's words

The ROM has 32768 words, at `0x0000`–`0x7FFF`. The monitor fills it
from 0, and the rest is free. The demo is not in it: it is a program,
`demo.bin`, whose words
[demo/README.md](../demo/README.md#its-words) counts.

<!-- romsize layout -->
| Part | Address | Words |
|---|---|---:|
| The monitor | `0x0000`–`0x36A2` | 13987 |
| Free | `0x36A3`–`0x7FFF` | 18781 |
<!-- /romsize layout -->

The monitor's words, by the source they come from, in the order
the Makefile joins them. The column "Text" counts the words of the
texts, which are part of "Words". They are packed, four characters a
word, with `.ASCII_B`, and a `.DAT 0` after a text whose length is a
multiple of 4 ends it (#131), which `test/texts.py` checks whenever the
ROM is built:

<!-- romsize monitor -->
| Source | What it is | Words | Text |
|---|---|---:|---:|
| `monitor.nasm` | The dispatch table, the HAL, and the cold start | 865 | 2 |
| `monitor_cmd.nasm` | The routines of the statements that were the commands | 1277 | 225 |
| `basic.nasm` | BASIC: the main loop, the scanner, the keywords, the messages, and the help | 834 | 440 |
| `monitor_dis.nasm` | The disassembler of `DIS` | 871 | 79 |
| `monitor_sd.nasm` | The sector routines | 206 | 59 |
| `monitor_fat.nasm` | FAT32, `DIR`, `LOAD`, `SAVE`, `DELETE`, and TAB | 3109 | 10 |
| `monitor_eth.nasm` | The network | 3338 | 160 |
| `monitor_tcp.nasm` | TCP | 2414 | 0 |
| `monitor_clock.nasm` | The clock and `TIME` | 698 | 44 |
| `monlib.nasm` | The routines that programs join | 274 | 0 |
| `mon.nasm` | The stubs of the entries | 82 | 0 |
| `build/folder.nasm` | The folder's name, and the error of a card without it | 17 | 17 |
| `build/version_test.nasm` | The version in the banner, the tests' `V9.9` | 2 | 2 |
| In all | | 13987 | 1038 |
<!-- /romsize monitor -->

- `build/folder.nasm` and the version always end with a `.DAT 0`, as
  the Makefile does not count their characters.
- The version is that of the tests, `V9.9`, so that the tables do not
  change with every commit. A release's version, such as `V2.3`, has
  as many words.

### Keeping the tables

`tools/romsize.py` writes the tables above. It joins the sources as
the Makefiles do, with a label in front of each part and of each
run of texts, assembles them with `niceasm.py --symbols`, and
takes each part's words from the labels' addresses. The words it
assembles must be those of the build, so a label never moves one.
`make -C monitor test` checks the tables of the ROM and the monitor,
and `make -C demo test` the demo's, in `demo/README.md`. Each fails when
a table differs from the build. `make romsize` writes the new tables.

## Building and testing

### What the build needs

- **For the monitor:** Python 3, for nice_cpu's assembler. The ROM is
  assembly only, so a bitstream with the monitor in its ROM needs no
  more.
- **For the tests:** nice_cpu's `niceemu`; `mkfs.fat`, `sfdisk`, and
  mtools, from the `dosfstools`, `fdisk`, and `mtools` packages on
  Debian and Ubuntu, for the images of the SD cards; and clang with the
  wasm32 target, `wasm-ld`, and `llvm-ar`, from the `clang`, `lld`, and
  `llvm` packages, for the test programs in C.

### The build

`make -C monitor` writes `build/monitor.bin`. The assembler has no
include, so the Makefile joins the sources with `cat` and assembles the
result with `niceasm`. In this order:

1. `monitor.nasm`, `monitor_cmd.nasm`, `basic.nasm`, `monitor_dis.nasm`,
   `monitor_sd.nasm`, `monitor_fat.nasm`, `monitor_eth.nasm`,
   `monitor_tcp.nasm`, `monitor_clock.nasm`, `monlib.nasm`, and
   `mon.nasm`.
2. `build/version.nasm`, which defines `VERSION`, the text of the
   banner: `git describe` of the tree, or the `VERSION=` of the command
   line.
3. `build/folder.nasm`, the card's folder (README.md, "Files"): its
   name, as an 8.3 name, and in the text of `DIR` and of error 29.

`version.nasm` and `folder.nasm` are written only when they change, so
that the monitor, and a bitstream with it, is not built again for
nothing. The build fails if the monitor reaches `PROGRAM`, `0x8000`,
the end of the ROM.

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
3. **The disassembler.** `test/dis.py` runs `DIS` over `test/dis.nasm`,
   which has every opcode, operand mode, condition, and modifier, the
   control instructions, the reserved words, and each pseudo-instruction
   with its near-misses. It compares each row with the text of
   `nicedis.py`, rewritten by the rules of README.md, "The disassembler",
   for a pseudo-instruction. It assembles each row again and compares the
   words.
4. **DHCP.** `test/dhcp.py` runs `DHCP` with `--step-time`, so that
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
   `test/bgdhcp.py` runs the monitor with no input, so that `getline`
   waits and carries DHCP on in the background: the times of the
   DISCOVERs, an `IP` that ends it, an OFFER and an ACK, with the line
   shown after `READY.` and the lease's first REQUEST at T1, and a NAK.
5. **DNS.** `test/dns.py` runs `test/dns.nasm`, which calls
   `dns_lookup` with its names packed from an odd byte, under the
   monitor with `--step-time`. A query's ID and port change with the
   steps of the code, so the script learns them from a run, adds the
   answer after the frame of the query, and runs again, until every
   frame that wants an answer has one; a run stops after a million
   steps, doubled while no new frame comes, so the runs take about 2
   seconds in all. It covers a dotted address, each error, names too
   long and with empty labels, datagrams that are passed over, CNAMEs,
   compression pointers, a loop of them, records of other types and
   classes, an answer cut short, a second query, the gateway, no answer
   to ARP, and no answer. It compares the output and the frames sent
   with `test/dns.expected`, with the ID and the port as `qq` and `pp`.
6. **NTP.** `test/ntp.py` types `NTP` and `DHCP` into the
   monitor with `--step-time`, and learns the frames of each run as
   `test/dns.py` does. DHCP gives the DNS server and an NTP server in
   option 42. It covers no IP address, DHCP's server, a server by name
   and by address, an offset east and west, a time of era 1, datagrams
   that are passed over, a kiss-o'-death, a leap indicator of 3, a
   stratum of 16, a time before 1970, no answer, an answer to the
   second send, no such name, and offsets that are not. It covers the
   edges of the eras too: the last second of era 0 before 1970, and the
   last second of era 1 that the clock takes, and the next; the largest
   offsets east and west, and a clock 0 s off. It compares the
   output and the frames sent with `test/ntp.expected`, with a query's
   port as `pp` and its transmit timestamp as `tt`. It runs on an I2C
   master that is present and never busy, as `test/rtc.py` has it, and
   checks that `NTP` writes the real-time clock: the master's last
   command is the cold start's read while no time is set, and the write
   of the chip's status after the times of the run.
7. **The lease.** `test/lease.py` runs `test/lease.nasm`, which takes
   a lease with `net_dhcp`, opens the endpoint, and polls, under the
   monitor with `--step-time`. Between its polls it writes the time to
   the next one to `TIME_SKIP`, `0xFFFFFF5F`, so minutes of the clock
   take a second, and notes when a frame goes.
   The script answers the frames of a run, and runs it again, until no
   new answer is needed. It covers the REQUESTs by unicast from T1 and
   broadcast from T2, 60 ticks apart, the lease's end, an ACK that
   starts the lease again, an ACK of another address, a NAK, a T1 past
   the housekeeping deadline, and a lease forever.
8. **TFTP.** `test/tftp.py` runs `LOAD` and `DIR` from a TFTP server the same way, against
   `test/tftp.expected`. It covers a file of two blocks among packets of
   other hosts and ports, lost packets, an ERROR, an ERROR after the
   first block, whose summary comes first, files of 512 and 0
   bytes, a listing, a port given as `"IP:PORT"`, bad arguments, and no
   answer to ARP.
9. **The real-time clock.** `test/rtc.py` starts the monitor on the
   words of an I2C master, which are memory in `niceemu`: a status that
   says that a master is present, and data that are the registers of the
   R6's real-time clock. With `--step-time` the clock is not set, so the
   cold start reads them, and `TIME` shows the result. It covers dates
   and times that the chip holds, the chip's flags that say that it lost
   its time, no master, a digit over 9 in each register, and numbers
   that are no date or time. Then it types `TIME` with a date and a
   time, and checks the master's command: left alone without a master,
   and in a year that the chip does not hold. A cold start with the
   clock set leaves it alone. The R3's chip is read only when the R6's
   does not answer, which memory cannot do, so the script then runs
   `niceemu --link` with `--no-cycle-counter`, so that the clock's words
   are memory too. A watchpoint stops the core at each command of the
   master, and the script answers it as the R6's chip, the R3's, or no
   chip would. It checks the transactions, and the seconds and the
   microseconds that the cold start writes: the R3's chip in 24-hour and
   12-hour mode, its flag that says that it lost its time, digits over
   9, and no chip at all. Then it types `TIME`, and checks each
   transaction with its data, for each chip.
10. **The suites of FAT32.** `test/fat_runs.py` runs the suites of
   `FAT_SUITES`, each a few runs of the monitor with `--step-time` on
   copies of the cards below, and compares each with
   `test/SUITE.expected`. A run types its input, and may run a program
   that `test/fat_tool.py` builds from a file of `fs_*` calls,
   `test/SUITE.ops`: its output has each call with its arguments and its
   result. Then it shows what each card holds that its image did not
   (`fat_tool.py diff`, below), and, for some runs, `fsck.fat -n` and
   the order of the sector writes (`fat_tool.py order`). The behavior
   of FAT32 that is odd but pinned, until a change of its own fixes
   it, is marked "known oddity" in the titles and the `.ops` files.
   The suites are in the table below the next one.
11. **The runs.** The monitor runs once for each test below, with its
   keystrokes from an input file that ends with `HALT`, so that the run
   halts. Some runs add a program at `0x8000`, SD card images, or
   Ethernet frames.

Each run's console output, a few memory words, and the screen are
compared with `test/NAME.expected`:

| Test | What runs | What it checks |
|---|---|---|
| `cmds` | The monitor alone | Every statement, its bad arguments, keywords in either case, numbers that do not fit, and the edits of a line. |
| `basic` | The monitor alone, with no card and no IP address | The scanner of a line: keywords glued to a letter or a digit, the HELP lines of each statement's Syntax error, numbers at their limits, `0x` without digits and a number that fails before a string, which are no numbers, strings without a closing quote, too few or too many arguments, and the 0s and the `.BIN` that the scanner writes into the line. |
| `scroll` | The monitor alone | 448 rows of `DUMP`, which go round the history, and Page Up and Page Down. |
| `load` | The monitor, with 128K words of RAM, as on the MEGA65 | `LOAD` with `build/hello.bin` pasted: CR LF and LF line ends, tabs, blank lines, skipped lines, a line too long, blanks after a line's 76 characters, a DEL that takes back the key after them, an address given twice, and CTRL-C. Then `SYS 0x8000` runs it. |
| `load_64k` | The monitor, with 64K words, as on the Nexys4DDR | `LOAD` at the end of that RAM. |
| `load_emu` | The monitor, with `0xFFFFFF9E` reading 0, as in `niceemu` | `LOAD` up to the screen. |
| `sd_write` | `test/sd.nasm`, with a card of 4 sectors in slot 0 and none in slot 1 | `sd_init`, `sd_read`, and `sd_write`: the empty slot, a sector read and written, and the sector past the end. The card must then equal the image of `test/sd_image.py --written`. |
| `arp` | `test/arp.nasm`, with the frames of `test/arp.eth` | `arp_resolve`: a reply after other frames, the cache, no reply, an entry aged out, and the cache filled and gone round. The frames sent are compared too. |
| `udp` | `test/udp.nasm`, with the frames of `test/udp.eth` | The UDP entries: each error, a datagram sent after ARP, a broadcast, datagrams received among other frames, one cut short, and one sent through the gateway. The frames sent are compared too. |
| `net` | `test/net.nasm`, with the frames of `test/net.eth` | The poll and the IP settings of issue #111: `net_config` at a word-window address and a plain one, `net_set`, `net_poll`, a datagram held and a second dropped, ARP replies learned in place, so that no request goes, a TCP segment released, and a deadline armed, not due, and due. The frames sent are compared too. |
| `fpu` | `test/fpu.nasm` | The FPU at a program's end (issue #141): each run leaves 10 values and the four flags on it, and the next one, after a return, `mon_exit`, or a jump to 0, the cold start, finds it empty with no flag. |
| `fs` | `test/fs.nasm`, with FAT images in both slots | The file entries, through `mon.nasm`'s stubs: handles, reads across the fragments of a file and at its end, the folder's entries, mounts, each error a program can cause, and `fs_readname`'s long name and 8.3 name in lower case, and a file opened by its long name. |
| `fsw` | `test/fsw.nasm`, with a copy of the card with partitions, one file read-only, and a write-protected card | The entries that write: a file written in pieces across clusters and read back, truncated, a file of ten clusters, deletions, one of a long name, a folder that grows a cluster, a mount that drops an open file, and each error. |
| `hal16` | `test/hal16.nasm`, with a line typed after `SYS` | The entries of table 1.6, through `mon.nasm`'s stubs: `con_getline` with a DEL, a full line, and TAB with no card, `bin_line`'s results and counts, `clock_set` and the clock it set, `net_servers` with none, and `mon_restore` after a program that stopped the cursor, set the timer, and moved the cursor off the screen. |
| `fat` | The monitor, with FAT images in both slots | `DIR` and `LOAD`: the fragmented `FRAG.BIN`, a text file, bad arguments, and `HELLO.BIN` loaded and run. |
| `fatw` | The monitor, with a copy of the card without partitions, and one that a write fills | `SAVE`, `LOAD`, `DIR`, and `DELETE`: a program saved and loaded back, a file truncated and deleted, bad arguments, and a full card, error 30, which has room again after `DELETE`. |
| `fatl` | The monitor, with `lfn.img`, long names that mtools wrote | `DIR` and `LOAD` by long names, in quotes and in either case, and by 8.3 names: a long name with a blank, one in mixed case, one of 255 characters, one outside ASCII, an 8.3 name with the lower-case flags, sets of long-name entries across a sector and across a cluster, and one with a wrong checksum, which only its 8.3 name reaches. |
| `tab` | The monitor, with `lfn.img` | TAB in the line: a unique name with an opening quote, with BS, and in quotes; a shared start, a TAB that lists, and the case of the card's name; nothing in the keyword, with no match, for a name outside ASCII, for a directory, for a name that does not fit, and with no card. |
| `fatlw` | The monitor, with a copy of `lfn.img` | `SAVE` of long names: the aliases with no tail, `~1`, and `~3`, by the 8.3 names that mtools left, a name in lower case with byte 12's flags, a truncation by the 8.3 name, names that are not valid, and a long name in the run of entries that two deletions freed; `fsck.fat -n`, `mdir`, and `mtype` check the card. |
| `fatbad` | The monitor, with a FAT16 card and an exFAT card | `DIR` rejects each. |
| `fat1` | The monitor, with no card in slot 0 | `DIR` mounts slot 1. |
| `fatnone` | The monitor, with a card without the folder `NICE`, and one whose `NICE` is a file | `DIR` and `LOAD` fail with error 29. |
| `time` | The monitor, with `--step-time` and a copy of the card without partitions | `TIME` not set, set, and shown; dates that are not, such as leap days of years without one, fields of one digit, month 0, day 0, letters, wrong separators, and 2106, and the clock left alone after them; the edges that are, 2000-02-29, 2100-03-01, 2104-02-29, 2^31 seconds, 2105-12-31, the last day of a leap year, and blanks in the quotes; and the dates of `SAVE`, from the clock and while it is not set or before 1980, which `mdir` shows. |
| `clock` | The monitor, with `--no-cycle-counter`, so that the clock's words are memory, set to a time with 999999 microseconds, and a copy of the card without partitions | The dates and the times of `SAVE` to the hundredths, which `test/fat_check.py --stamps` shows: the most hundredths, 0, the first second of 1980, and the fixed date before it; and the clock's words that `TIME` writes. |
| `clockpast` | The same, with 2^32 seconds | `TIME` shows that the clock is past 2106, and `SAVE` writes the fixed date. |
| `hello` | `test/hello.nasm`, under nice_cpu's `start_mon.nasm` | A program in assembly, run with `SYS 0x8000`, that returns to the monitor. |
| `reset` | The same | `SYS 0`, the cold start, and `SYS 0x8000` again. |
| `hello_c` | `test/hello.c`, built with `nicebuild.py --monitor --asm mon.nasm` | A program in C. |

`sd_write`, `arp`, `udp`, and `net` call the monitor's routines or
reach its variables by their labels, so they are assembled after the
monitor's sources, and only their words from `0x8000` are kept. `fs`,
`fsw`, `hello`, and `hello_c` call the entries through `mon.nasm`'s
stubs, as any program does, and so do `udp` and `net`. `arp`, `udp`, and
`net` run with `--step-time`, as their timeouts count steps, and
`fsw`, `fatw`, `fatlw`, and `time` too, so that the clock starts at 0,
not set, and counts the same each time, and the files they write have
the fixed date, 2026-01-01 at 00:00:00. `clock` and `clockpast` run with
`--no-cycle-counter`, so that their clock stands still.

A test that writes to a card, `fsw`, `fatw`, `fatlw`, `time`, `clock`,
and `clockpast`, runs on a fresh copy of its image, and its output ends
with what each card holds that the image did not, from `test/fat_tool.py
diff`, and the order of the sector writes, from a second run with `-t`
and `test/fat_tool.py order`. The card is so checked byte for byte:
every byte that differs is shown, decoded, and every other byte is the
image's. `time` sets the clock, whose seconds count steps, so its diff
shows the times as `**`. `fsw`'s slot 1 is write-protected, and is
compared with `cmp`.

The suites of `test/fat_runs.py`, step 10:

| Suite | What it checks |
|---|---|
| `fatstate` | What `SYS 0` and a program's return keep: a handle across the cold start, both handles left open, so that `LOAD` and `SAVE` give error 23 while `DIR` and TAB work, the mount of slot 1 forgotten, and `DIR 0`, which mounts again and closes a program's handle. |
| `fatload` | `LOAD`'s lines (`lines.img`): CR LF, blank lines only, a chain cut after its second cluster, whose summary comes before the error, and lines of every kind, with bytes that are not printable ASCII and blanks and text after 76 characters, and the words of `V_LSTATS`. |
| `fattab` | TAB: after a quote, in either case, an alias, words after blanks and strings, a list longer than the screen; with slot 1 mounted (`tab1.img`), a directory, and names that end at the line's end or past it; and after `SAVE` and `DELETE` (issue #145). |
| `fatdrop` | The mount dropped under open files when `SD_SELECT` changes, and `fs_mount` under a file open to write. |
| `fatchain` | Damaged chains (`chains.img`): a chain cut, a size past the chain, cluster 0, the last cluster, one past it, a bad mark, a loop; their reads, deletes, and a `SAVE` over one. |
| `fatlfn` | Long names of 13 and 26 characters; damaged entries (`lfnx.img`): 0x05, orphans, a label, a broken set, a name of 256 characters; and deletes of long names across a sector and a cluster. |
| `fatmount` | `DIR` of 28 cards that are not FAT32 or are damaged (`m_*.img`), each check of the MBR and the boot sector, the bounds of FAT12, FAT16, and FAT32, FATs whose count of entries wraps to 0, an empty folder, a folder whose chain breaks, no card, and slots from 2^31. |
| `fatgeo` | `SAVE`, `LOAD`, `DIR`, and `DELETE` on clusters of 8 and 64 sectors, and on a card with one FAT. |
| `fatinfo` | FSInfo: its hint, at the last cluster, free and in use, and 0xFFFFFFFF; no signature; no FSInfo in the boot sector; free entries with their top 4 bits set; and a volume larger than its FATs. |
| `fatfull` | `fs_write` on a card with 3 free clusters, and a folder of 65536 entries. |
| `fatrows` | `DIR`'s rows: names of 23 to 26 characters, hidden and system files, a directory, and a size of 10 digits. |
| `fatapi` | The entries' small cases: names and modes, reads of 0 bytes, a file open twice, words above 0xFF written, a directory handle's sector, a directory in mode 1, the order of the errors, and `fs_delete` of a file open to write. |

`make test FAT_SUITES=fatapi` runs one suite; `FAT_SUITES=` none.

`niceemu` has no I2C master: its status word is memory, which reads 0,
so the cold start of every run finds none, and `TIME` shows that the
clock is not set. `test/rtc.py` alone sets that memory, as step 9 says.
The I2C bus and the chip are tested in the simulated
system, whose bus has a model of the R6's real-time clock: `make
cosimtest` runs the monitor's cold start there, and checks the clock
after it, and then types `TIME` with a date and a time, and reads the
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
- `lfn.img`: long names, written by mtools.

The images do not depend on the host's time or its time zone: the tools
run with `SOURCE_DATE_EPOCH` and `TZ=UTC`, so that every date is
2025-06-15 12:34:56, and the disk's and the volume's IDs are fixed. So
`fat_tool.py diff` can show the entries that a test did not write, too.

The suites of `test/fat_runs.py` have more images, which
`test/fat_image.py` makes from those with `test/fat_tool.py`, by
changing bytes: `lines.img`, `tab1.img`, `chains.img`, `lfnx.img`,
`rows.img`, `bigdir.img`, the 28 `m_*.img` of `fatmount`, the `i_*.img`
of `fatinfo`, and `spc8.img`, `spc64.img`, and `fat1.img`, which
`mkfs.fat` makes with those geometries. The comments in
`test/fat_image.py` say what each holds.

After `fsw` and `fatw`, `test/fat_check.py` checks the cards that were
written: `fsck.fat -n`, the folder with `mdir`, and the files written
with `mtype`. After `clock` and `clockpast`, it reads the dates and the
times of the files written from their entries, as `mdir` shows no
seconds and no hundredths.

### The expected files

The expected files were checked by hand. After a change that alters an
expected output, check the new output the same way before you copy it
from `build/` to `test/`. The `Halted` line and the registers are left
out, as they change with the code, except for VBASE, which must be 0
after every run.

A change of `monitor_fat.nasm` that is not meant to change its behavior
must leave the outputs of the tests of FAT32 as they are, the cards
and the order of the writes too. What changes with no fault is
elsewhere: `cmds` shows the addresses of the dispatch
table, and the table of "The ROM's words" changes with the code, which
`make romsize` writes again. To run one test of the
loop, run `make test FAT_SUITES=` and read its `build/NAME.out`; to run
one suite, `make test FAT_SUITES=NAME`, whose output is
`build/NAME.out`. A suite's output is the new expected file as it
stands: check it, then copy it to `test/NAME.expected`.

`make tftptest`, in the repository's root, runs the monitor against
`tools/tftpd.py`, and `make tcptest` runs `test/tcp.nasm`,
`test/tcpt.nasm`, `test/tcp_c.c`, and `test/tcphw.nasm` against
`tools/tcppeer.py` (CONTRIBUTING.md).

### On a board

`make r6` builds a bitstream that boots the monitor, alone in the ROM.
`make hwtest` loads the monitor of the tests into the RAM at 0, with
the ROM hidden, and with it the demo at `0x8000`, which it runs with
`SYS 0x8000` ([demo/](../demo/README.md), and README.md, "The demo").

What `niceemu` cannot show about the SD cards is checked by hand, with
the monitor in the ROM, after a change to `monitor_fat.nasm`. Each
step needs a card prepared on a PC with a folder `NICE` that holds
`HELLO.BIN`:

1. **A card pulled out and pushed in.** `DIR` lists it. Push another
   card in, with another `NICE`: `DIR` lists the new card, with no
   error. Pull it out: `DIR` gives `SD error 1 in slot 0, no card`, on
   the MEGA65 with slot 1 empty. Push it in: `LOAD "HELLO.BIN"` and
   `SYS 0x8000` run it.
2. **A card changed under an open file.** A program opens `HELLO.BIN`,
   reads 100 bytes, waits for a key, and reads again. Swap the card
   while it waits: the second read gives -28, a third -24.
3. **A write-protected card**, by the switch of a full-size card, or of
   an adapter, in slot 1 of an R6, the only slot with write protect (the
   R3's slot 1 has none): `DIR 1` and `LOAD` work, and `SAVE "X",
   0x8000, 1` and `DELETE "HELLO.BIN"` give `SD error 6 in slot 1, the
   card is write-protected`. The PC finds the card unchanged.
4. **SDSC and SDHC.** On a card of 2 GB or less and one of 4 to 32 GB:
   `SAVE "BIG", 0x8000, 4000`, `LOAD "BIG.BIN"`, `DIR`, and `DELETE
   "BIG.BIN"`. Then `fsck.fat -n` on the PC reports only the free count,
   as not known. On a card of 32 GB, half full, time a `SAVE`, as the
   search for a free cluster starts at the hint.
5. **Slot 1 of the MEGA65.** With no card in slot 0, `DIR` lists slot 1
   after a reset. With cards in both, `DIR` lists slot 0, `DIR 1` slot 1,
   `LOAD "` and TAB complete the names of slot 1, and `DIR 0` goes back.
6. **The Nexys4DDR's one slot.** With no card, `DIR` gives `SD error 1
   in slot 0, no card`, and `DIR 1` gives `File error 27, no such slot`.
7. **Cards formatted by Windows and macOS**: `DIR`, `SAVE`, `LOAD`, and
   `DELETE`, then the PC's check. An exFAT card, as SDXC cards are sold,
   gives `File error 19, exFAT, which is not supported`.
8. **A reset during a write.** Reset during `SAVE "BIG", 0x8000, 20000`:
   `fsck.fat -n` reports at most lost clusters, orphan long-name
   entries, and the free count.
9. **A card from a camera or a phone**, with names outside ASCII: `DIR`
   shows `?` for each such character, and `DELETE` with the name as
   `DIR` shows it, with the `?`, deletes such a file.
