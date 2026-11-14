# Release notes

The releases of NiceMonMEGA65, newest first: the versions from `V1.0` on,
and the release candidates `RC02` to `RC06` before them. Each section lists
the changes since the one before that a user of the bitstreams, the boards,
or the tools can see. The git log has the full story, and
[nice_cpu's release notes](https://github.com/MJoergen/nice_cpu/blob/main/RELEASE_NOTES.md) have the changes to
the cores, the emulator, and the tools that come with the submodule.

From `V1.0` on, a release here has the name of the nice_cpu tag it pins,
and a release that leaves the submodule alone adds a third number:
`V1.0.1` and `V1.0.2` pin `V1.0` ([RELEASE.md](RELEASE.md#version-names)).
The release candidates pinned these:

| NiceMonMEGA65 | nice_cpu |
|---|---|
| `RC06` | `RC06` |
| `RC05` | `RC05` |
| `RC04` | `RC04` |
| `RC02` | `4cd869e`, a commit before nice_cpu's `RC02` |

nice_cpu's `RC01` and `RC03` have no tag here.

## V2.1

**Upgrade notes.**

- The demo is no longer in the ROM, and the monitor's `x` is gone
  ([#129](https://github.com/MJoergen/NiceMonMEGA65/issues/129)). The
  demo is `demo.bin`, a file of the release: copy it into the folder
  `NICE` of an SD card, and type `load demo.bin` and then `r`. F12
  returns to the monitor as before. A program's return now prints its
  status where the program left the cursor's registers, so at the top
  after the demo, which clears the screen. With the network of #111 in
  it, and its texts packed four characters a word
  ([#131](https://github.com/MJoergen/NiceMonMEGA65/issues/131)), the
  ROM has 11876 words free, where it had 5117 below the demo, for BASIC.
- `make demo` builds `demo/build/demo.bin` alone, and the boards'
  targets put the monitor alone in the ROM, `monitor/build/monitor.bin`.
  `demo/join.py`, `demo/build/rom.bin`, and `demo/demo_hw.py` are gone.
- Each kind of board has a MAC address of its own after reset:
  `02:4E:49:43:45:03` on the R3, `02:4E:49:43:45:06` on the R6, and
  `02:4E:49:43:45:0A` on the Nexys4DDR, where all three had
  `02:4E:49:43:45:00`
  ([#124](https://github.com/MJoergen/NiceMonMEGA65/issues/124)). So an
  R3, an R6, and a Nexys4DDR on one network no longer clash. A DHCP
  server sees a new station, and may give it another address than
  before.
- A PC remembers the MAC address of an IP address for a while. After a
  new bitstream, or another board at the same IP address, the PC's
  first pings and connections may fail for a few seconds. A `ping` of
  the address, repeated until it answers, makes the PC learn the new
  MAC address.
- The UDP entries hold one datagram for the endpoint, which `udp_recv`
  returns, and drop a second that comes before it is read
  ([#111](https://github.com/MJoergen/NiceMonMEGA65/issues/111)). They
  used to leave the datagrams in the queue. So a datagram never blocks
  the frames behind it, but a program reads each datagram before the
  next comes, or loses the next. The monitor's `tftp` sends one packet,
  and waits for its answer, so it is not affected.

- The dispatch table is 1.5, with 11 entries more, 21 to 31, for the
  network ([#111](https://github.com/MJoergen/NiceMonMEGA65/issues/111)).
  A program built for 1.4 runs as before.

**New.**

- Programs under the monitor get the IP settings, DHCP, DNS, and TCP
  from the ROM ([#111](https://github.com/MJoergen/NiceMonMEGA65/issues/111)):
  `net_config`, `net_set`, `net_dhcp`, `net_poll`, `dns_lookup`, and up
  to 4 TCP connections at once, which a program opens to a server with
  `tcp_open`, or a peer opens to a port where it listens with
  `tcp_listen`. The network moves when the program polls, every 100 ms
  or so, and the polls renew the DHCP lease. `mon.h` declares the
  entries for C, and `monitor/mon_c.nasm` has their stubs.
  [doc/PROGRAMMING.md](PROGRAMMING.md#the-sd-card-and-the-network) has a
  client and a server in C, and `make tcptest` tests the entries without a
  board.
- The monitor's `i dhcp` also shows the DNS server, and asks the DHCP
  server for the address that the board has, if it has one. It writes
  the address only when the server gives another, so a host's
  connection over Ethernet survives an `i dhcp` that gets the same
  address ([#111](https://github.com/MJoergen/NiceMonMEGA65/issues/111)).
- The ROM's IPv4 packets, of UDP and of DHCP, have the "don't fragment"
  bit clear and an identification that counts up, so a router on a path
  with a smaller MTU fragments a datagram instead of dropping it.

- After a reset, the monitor gets an IP address from DHCP on its own,
  in the background while it waits at its prompt, and shows it over the
  prompt: `IP address 192.168.1.253 from DHCP`
  ([#126](https://github.com/MJoergen/NiceMonMEGA65/issues/126)). With
  no cable or no server it shows nothing, and asks again, less and less
  often. The lease is renewed at the prompt too. An address from `i`, a
  program, or a host ends it.

- The monitor's `i dhcp` names the board to the DHCP server: the host
  name `nicemon-` and the last three bytes of the MAC address, such as
  `nicemon-434506`, and the vendor class `NiceMonMEGA65` and the
  monitor's version. A router that serves DNS then knows the board by
  that name, such as `ping nicemon-434506`
  ([monitor/README.md](../monitor/README.md#the-network)).

## V2.0.1 (2026-11-12)

**Upgrade notes.**

- The dispatch table is 1.4, with one entry more, `fs_readname` (#102).
  A program built for 1.3 runs as before.
- `dir` shows a file's long name, so a file that a PC wrote as
  `mandelbrot.bin` shows so, where it showed as `MANDEL~1.BIN`. Either
  name still reaches it.
- On the MEGA65, the clock of the time of day is set after the cold
  start, when the real-time clock has the time, where it was not set
  until a program set it (#105).

**New.**

- The monitor reads and writes long file names on FAT32 cards, of up to
  255 characters
  ([#102](https://github.com/MJoergen/NiceMonMEGA65/issues/102)). `dir`
  shows them, and `load`, `save`, and `del` take the long name or the
  8.3 name, in either case, in quotes when it has a blank:
  `load "my prog.bin"`. `save` writes a long name when the name is no
  8.3 name, with an 8.3 alias as mtools makes them. Programs read the
  names with the new entry `fs_readname`, and `fs_open` takes either
  name. A character outside ASCII shows as `?`
  ([monitor/README.md](../monitor/README.md#files)).
- The monitor's `time` shows the clock of the time of day, and
  `time 2026-11-11 14:30:00` sets it first, in the years 1970 to 2105
  ([#109](https://github.com/MJoergen/NiceMonMEGA65/issues/109)). The
  clock keeps local time, as the MEGA65's real-time clock does. A file
  that the monitor writes gets the clock's date and time, where every
  file got 2026-01-01, which it still gets while the clock is not set.
- Every board has an I2C master at `0xFFFFFF97`–`9D`, which does a whole
  transaction of up to 16 bytes with a chip on the board's bus: the
  MEGA65's real-time clock, or the Nexys4DDR's temperature sensor
  ([#105](https://github.com/MJoergen/NiceMonMEGA65/issues/105),
  [SYSTEM.md](SYSTEM.md#the-i2c-bus)).
- On the MEGA65, the monitor's cold start sets the clock from the
  real-time clock, the R6's RV-3032-C7 or the R3's ISL12020M, unless the
  chip says that it lost its time. `time` with a date and a time in the
  years 2000 to 2099 sets the real-time clock too, so `time` once sets
  the clock for every later start, and for the MEGA65's other cores.
- `tools/sdnbd.py`, and `make sdnbd`, serve the board's SD card over
  the link as a disk of Linux's network block device, which
  `nbd-client` connects and the PC mounts as a folder, all of the card,
  for the file manager. The core is held meanwhile, and starts again
  from reset at the end ([tools/README.md](../tools/README.md#sdnbdpy)).
- `tools/sdcard.py` lists, reads, writes, and deletes files by their
  long names, as the monitor does.
- `make flash COR=f.cor SLOT=N` writes an R3 whose flash is an
  S25FL256S of 32 MiB, in the slots 1 to 3, where it knew only the R6's
  S25FL512S ([synth/README.md](../synth/README.md#building)).
- `doc/BASIC.md` is the design note of the BASIC interpreter for the
  ROM ([#54](https://github.com/MJoergen/NiceMonMEGA65/issues/54)), with
  its decisions and its stages. Nothing of it is written.

**Tests.**

- `sim/tb_i2c.vhd` tests the I2C master on models of the three chips,
  and `i2c.sby` proves it. `make cosimtest` checks the clock after the
  cold start on a model of the R6's real-time clock, types `time`, and
  reads the model back. `make hwtest` checks the bus on the boards, sets
  the MEGA65's real-time clock to the host's local time, and reads it
  back.
- The monitor's tests read and write a card with long names, `lfn.img`,
  against mtools and `fsck.fat -n`, check `time` and the dates of the
  files with `mdir`, and run the cold start and `time` in `niceemu` on
  the registers of a real-time clock, with digits over 9 and dates that
  are none (`test/rtc.py`).
- `make sdtest` checks `tools/sdnbd.py` with an NBD client of its own on
  `niceemu --link`: the handshakes, reads, the writes that mtools made
  on a copy, a bad option, and a write that is too long.

## V2.0 (2026-11-10)

**Upgrade notes.**

- nice_cpu is at `V2.0`. `WAIT` is a mnemonic, so a program with a label
  or an `.EQU` name `WAIT`, in any case of letters, no longer assembles
  until it is renamed; the testbenches renamed theirs (#92).
- The debug link is version 7, and the board sends `b07` at reset. Its
  registers start at `0xFFFFFFD0`, so a link request to
  `0xFFFFFFD0`–`DF` reaches the link, where it reached the RAM. A host
  of version 6 works unchanged.
- The monitor has no `sd` command any more, which showed a sector of the
  SD card, for the bring-up of the cards. `dir`, `load`, `save`, and
  `del` reach the card's files, and a program or a host drives the
  controller's registers for its sectors.
- On the MEGA65, Page Up and Page Down are CTRL and MEGA with CRSR↑ and
  CRSR↓, where they were MEGA with them, and MEGA with CRSR↑ and CRSR↓
  is the cursor key. This holds for programs and for the on-board
  debugger's page of memory too.

**New.**

- The monitor's `baud [RATE]` shows the UART's baud rate, or sets it
  to one of the seven rates of `0xFFFFFF9F`, as the on-board debugger's
  settings page does.
- At the monitor's prompt, the cursor keys up and down scroll back a
  row at a time, and Page Up and Page Down still a page.
- The link shows a wait for an interrupt in bit 6 of the control
  register ([#93](https://github.com/MJoergen/NiceMonMEGA65/issues/93)),
  and the hidden state of an interrupt routine in bits 7 and 8,
  `saved_pc` at `0xFFFFFFD0`, and `saved_sr` at `0xFFFFFFD1`, with the
  timer's pending IRQ in bit 10
  ([#98](https://github.com/MJoergen/NiceMonMEGA65/issues/98)).
  `nicedbg status` shows them on the board, and the on-board debugger's
  state is `WAITING` in a wait, and `PAUSED W` paused in one (#93).
- The four watchpoints of link version 7 at `0xFFFFFFD4`–`DB`
  ([#99](https://github.com/MJoergen/NiceMonMEGA65/issues/99)): a host
  sets them, `mon.py` among them, and the core pauses after a step that
  read or wrote a watched word. The on-board debugger's state is
  `WCH n` then. The pipelined core runs more slowly while one is
  enabled.
- The clock of the time of day at `0xFFFFFF46`–`49`
  ([#97](https://github.com/MJoergen/NiceMonMEGA65/issues/97)), from
  the board's clock. It holds no time until a program sets it.
- The byte windows of nice_cpu's SYSTEM.md §9 at `0x10000000`–`0x5FFFFFFF`
  ([#90](https://github.com/MJoergen/NiceMonMEGA65/issues/90)): a data
  access there reaches a word, a byte, or a halfword of the RAM, with
  byte enables on the block RAM, so that a program built with nicewasm's
  `--byte-windows` runs on the board. The link reads and writes through
  them too. A read of a byte or a halfword takes a cycle more than one of
  a word, for the timing at 100 MHz, as a read of the fonts does.
- `make examples` builds `primes.bin` with nicewasm's `--byte-windows`
  and `--trust-alignment`, and `bench_win.bin`, nice_cpu's benchmark
  built so, beside `bench.bin`, which is built as before. On the R6
  `bench_win.bin` takes 10% fewer cycles. `make hwtest` and `make
  linktest` run both benchmarks.
- `run.py --symbols` names wasm trap 8, `memory beyond the byte windows`,
  as niceemu does
  ([#101](https://github.com/MJoergen/NiceMonMEGA65/issues/101)).

**Changed.**

- The monitor's `u` and the on-board debugger's row 27 show
  `0x0C600000` as `WAIT`, as nicedis does, where they showed a reserved
  control word (#93).
- The MEGA65's builds use `FLOW=timing` alone, as the Nexys4DDR's do,
  so `make r6`, `make r3`, and `make cor` need it no more. Their RAM is
  built from block RAMs that are not cascaded in pairs, which gives the
  core's paths from the RAM more slack: the R6 meets 100 MHz by
  0.196 ns without a ROM, where it met it by 0.058 ns, and its builds
  take less time
  ([#107](https://github.com/MJoergen/NiceMonMEGA65/issues/107)).

**Fixed.** A link read of the fonts while the core was held could go
unanswered, when the read before it had been the core's, so that the
host waited for its answer in vain (#90).

## V1.9.1 (2026-11-08)

**Upgrade notes.**

- The dispatch table is 1.3, with six entries more: `fs_write` and
  `fs_delete` (#59), and `udp_open`, `udp_send`, `udp_recv`, and
  `udp_close` (#84). A program built for 1.1 runs as before.
- The demo is at `0x6000` in the ROM, from `0x4000`, so that the
  monitor has room (#84). A ROM made with `demo/join.py` of an earlier
  release has the demo where `x` no longer looks.

**New.**

- The monitor writes FAT32 cards, in the folder `NICE`
  ([#59](https://github.com/MJoergen/NiceMonMEGA65/issues/59)).
  `save NAME ADDR N` writes N words from ADDR as a `.bin` file, which
  `load` reads back, and `del NAME` deletes a file. Programs write files
  through `fs_open` with mode 1, `fs_write`, and `fs_close`, and delete
  them with `fs_delete`. A reset in the middle of a write leaves at worst
  clusters that `fsck.fat` frees.
- The monitor's `tftp IP NAME` loads a `.bin` file from a TFTP server,
  as `load` loads one from the card
  ([#84](https://github.com/MJoergen/NiceMonMEGA65/issues/84)).
  Programs send and receive UDP datagrams through four new entries,
  with ARP and the gateway of `i dhcp` resolved in the ROM, so that a
  game of two boards needs no network stack of its own.
- `tools/tftpd.py`, a TFTP server of the repository's own, `make tftpd`,
  also answers a name with `*` or `?` with a listing of its folder, which
  `tftp IP *.bin` shows on the board
  ([#95](https://github.com/MJoergen/NiceMonMEGA65/issues/95)).
  `tftp IP:PORT NAME` reaches a server on another port than 69.
- `tools/sdcard.py`, `make sdcard`, lists the folder `NICE` of the
  board's SD card, copies its files to the host, writes them, and
  deletes them, over the debug link, with no PC slot
  ([#61](https://github.com/MJoergen/NiceMonMEGA65/issues/61)). A
  running core is paused for `ls` and `get` and goes on after them, with
  the program's card as it was; `put` and `del` start it again from
  reset, and so do `ls` and `get` with `--hold`, which reach any slot.

**Tests.**

- The monitor's tests write to cards made by dosfstools and mtools, and
  check them with `fsck.fat -n`, `mdir`, and `mtype`: files written
  across clusters, a truncated file, deletions with long names, a folder
  that grows by a cluster, a full card, and a write-protected one.
- The UDP entries and `tftp` run in `niceemu` against frames of
  `--eth-in`, with the frames sent compared: `test/udp.nasm` and
  `test/tftp.py`, with lost packets, duplicates, and an ERROR.
  `make tftptest` runs the monitor in `niceemu` against `tools/tftpd.py`
  itself, in CI too.
- `make sdtest` checks `tools/sdcard.py` on `niceemu --link` with cards
  made by dosfstools and mtools, which `fsck.fat -n` and mtools check
  after its writes, and with the monitor, in CI too. `make hwtest` reads the
  folder `NICE` with the same code.

## V1.9 (2026-11-08)

There is no `V1.8` here: with nice_cpu's `V1.8`, the R6 missed timing at
100 MHz (nice_cpu#141). This release pins nice_cpu's `V1.9`, which
meets it again, and has V1.8's changes too.

**Upgrade notes.**

- nice_cpu is at `V1.9`. Its SYSTEM.md §3 has five event counters, its
  MICROARCH.md §8.1 new fetch statistics, and its SYSTEM.md §2 new
  words of the math unit. The ports of the cores but the fetch
  statistics', and the debug link, are as in V1.7.
- The performance counters take `0xFFFFFF40`–`5F`, from `40`–`4F`, and
  the fetch statistics `0xFFFFFF60`–`7F`, from `50`–`7F`, with new words
  (#85). `FS_CTRL` moved from `0xFFFFFF50` to `0xFFFFFF60`, and
  `FS_HIST` is gone: the fetch statistics now give a cause for each cycle,
  and the flushes by cause. A program that read them reads the new map.

- A program that joins nice_cpu's `lib.nasm` joins `muldiv_mpu.nasm` or
  `muldiv_soft.nasm` after it, and one that calls `scanf` joins
  `float.nasm` too. The monitor's tests and the C examples do (#89).
- The monitor has C code in the ROM, so building it, and a bitstream with
  it in the ROM, needs clang with the wasm32 target, lld, and llvm, as
  the C examples do (#86).
- The demo is at `0x4000` in the ROM, from `0x2000`, behind the monitor,
  which FAT32 made larger. The dispatch table is 1.1, with entries 9 to
  13 for files (#58).
- The debug UART runs at 230400 baud after reset, from 2 Mbaud, and the
  tools' `--baud` is 230400 by default (#88): the highest rate that the
  termios of both Linux and macOS have a constant for, so a Mac reaches
  the board on its serial port. A load over the UART takes about nine
  times as long; Ethernet is unchanged, and on Linux the settings page
  or `0xFFFFFF9F` sets 2 Mbaud again, with `--baud 2000000`. A core
  file older than `V1.9` still runs at 2 Mbaud after reset, so the
  tools need `--baud 2000000` with it.
- The tools take the debug link, the loader, and the debugger from
  nice_cpu's `debugger/` (#87). `tools/nicelink.py` is now
  `tools/boardlink.py`, with only the board's own links, Ethernet and
  `make cosim`, and `mon.py` is nice_cpu's `nicedbg.py` with them. Its
  prompt is `dbg>`, and its messages say "the processor" for the core.
  A send of console bytes to a program that does not read them for 2 s
  is an error, where it waited forever.

**New.**

- The event counters at `0xFFFFFF4A`–`53` count a program's data reads,
  stores, skipped instructions, jumps, and interrupts, as niceemu counts
  them, on both cores. The link's reads and writes do not count.
- The math unit counts the leading and trailing 0 bits and the 1 bits of
  A at `0xFFFFFF2A`–`2C`, and takes the square root of C, with its
  remainder, at `0xFFFFFF3C`–`3E`, as niceemu does.
- The monitor's ROM joins C code through nice_cpu's `nicewasm --ram`,
  with its writable words at `0xFFFFF400`–`0xFFFFFEFF`, which the cold
  start initializes
  ([#86](https://github.com/MJoergen/NiceMonMEGA65/issues/86)). It is
  empty until the FAT32 code of #58. A wasm trap in it prints `Trap N at
  ADDR` and goes back to the monitor's prompt.
- The monitor reads FAT32 SD cards
  ([#58](https://github.com/MJoergen/NiceMonMEGA65/issues/58)): `dir
  [SLOT]` lists the folder `NICE` of the root directory, and `load
  NAME` loads a `.bin` file from it as `l` loads lines, so a program
  copied to the card on a PC runs with no host. A card without the
  folder is refused with error 29, as a card may be shared with other
  cores, each with a root folder of its own, and `make monitor
  FOLDER=NAME` builds a monitor with another
  ([#91](https://github.com/MJoergen/NiceMonMEGA65/issues/91)). Programs read files through the dispatch table's
  new entries `fs_mount`, `fs_open`, `fs_read`, `fs_readdir`, and
  `fs_close`. The card is FAT32 on the whole, or in the first FAT32
  partition of an MBR; FAT12, FAT16, and exFAT are rejected. Writing
  comes with #59.
- `make bump` also builds the Nexys4DDR, and writes
  `badge-nexys4ddr.json`, the badge of nice_cpu's core at 90 MHz there,
  beside the MEGA65's, with the Nexys4DDR's timing in `verified.json`
  under `nexys4ddr`
  ([#77](https://github.com/MJoergen/NiceMonMEGA65/issues/77)).

**Tests.**

- `tb_nicemon` checks the event counters after `hello.nasm` against the
  counts that `make -C sim check-steps` takes from niceemu, and `make
  hwtest` those after `sim/emu.nasm` against niceemu's own.
- `tb_nicemon` and `sim/counters.nasm` read the fetch statistics at
  their new addresses, and check that the causes sum to the cycles.
  `make hwtest` checks `FS_CTRL` at `0xFFFFFF60`.

## V1.7.2 (2026-11-07)

**New.**

- Every board has the port for Ethernet frames of nice_cpu's SYSTEM.md
  §7 at `0xFFFFFFC0`–`CF`
  ([#82](https://github.com/MJoergen/NiceMonMEGA65/issues/82)), which
  were memory before. A program receives the frames that the station
  does not serve, and every frame to its MAC address while the IP
  address is 0, and sends frames of its own, as in niceemu. `NET_TX`
  counts them too. `sim/udp.nasm` is an example, which answers a UDP
  datagram to port 4511, and `make hwtest ETH=...` runs it.
- The monitor's `i dhcp` gets the IP address from the network's DHCP
  server, and shows it with the mask, the gateway, and the server
  ([#83](https://github.com/MJoergen/NiceMonMEGA65/issues/83)). It
  does not renew the lease. The ROM's frame routines and ARP cache have
  no entries for programs yet. The monitor disables the port at its
  start and when a program returns. `make hwtest ETH=...` runs `i dhcp`
  last, so the board keeps the address it gets, and names it after NOT
  COVERED when no server answers.

## V1.7.1 (2026-11-06)

**Upgrade notes.**

- The on-board debugger's keys have moved
  ([#81](https://github.com/MJoergen/NiceMonMEGA65/issues/81)). F3
  pauses a running program and goes on from a paused one, F4 (SHIFT and
  F3) restarts, and F5 shows the settings page. F7, F9, and F10 do
  nothing. The letters are as they were, and `h` still holds. On the
  Nexys4DDR, BTNR pauses or goes on as F3 does.

**New.**

- The monitor's `sd [SLOT] LBA` shows a sector of an SD card, in hex and
  as text ([#57](https://github.com/MJoergen/NiceMonMEGA65/issues/57)),
  or the controller's error, such as `SD error 1 in slot 1, no card`.
  It starts the card up when it needs to. Without `SLOT`, it reads the
  slot of the last `sd`, 0 after reset.

## V1.7 (2026-11-06)

**Upgrade notes.**

- nice_cpu is at `V1.7`. Its SYSTEM.md has a network station at
  `0xFFFFFFB0`–`BF` (§6) and a port for Ethernet frames at
  `0xFFFFFFC0`–`CF` (§7), and its "Systems built on the FPGA core" is §8,
  from §6. The demo of the ROM moved to nice_cpu, to `nice_cpu/demo`
  (nice_cpu#91). The cores and the debug link are as in V1.6.
- The Ethernet station moved from `0xFFFFFF98`–`9D` to `0xFFFFFFB0`–`B6`,
  as nice_cpu's §6 has it (#78): `NET_IP`, `NET_MAC_HI`, `NET_MAC_LO`,
  `NET_RX_GOOD`, `NET_RX_BAD`, `NET_TX`, and `NET_STATUS`, which is new.
  `0xFFFFFF98`–`9D` read 0 now and take no write. A program or a script
  that wrote the IP address to `0xFFFFFF9A` writes it to `0xFFFFFFB0`.
- The tools and the ROM of V1.7 use the new addresses, so they need a
  bitstream of V1.7, and the tools of earlier releases a bitstream of
  theirs, for the station.

**New.**

- `NET_STATUS`, `0xFFFFFFB6`, has bit 31 while a host is connected to
  the link over TCP, and the port of the link, 4510, in bits 15..0. The
  demo's F11 shows it in the row "Debug link, TCP port".
- The station's registers are nice_cpu's `hdl/src/net_regs.vhd`, in
  `devices.vhd`, and only a reset of the system resets them, as before.
- The demo is nice_cpu's, built with the board's text, `demo/text.nasm`.
  It runs the same, but for F11's new row, and F12, which clears the
  screen itself before it returns to the monitor.

**Fixed.**

- A program that hid the cursor, as nice_chess does when it quits, left
  it hidden at the monitor's prompt. The monitor now shows the cursor,
  blinking, when a program returns to it (#79).
- The debugger shows a write refused because the core runs, from the
  memory page, the settings page, or a key, as "not paused" instead of
  `e02` (#80).
- The field of the debugger's settings page (F10) has a blinking cursor
  where the next character goes.

**Tests.**

- `tb_nicemon` reads and writes the station at `0xFFFFFFB0`, and checks
  that a start and a clear keep its addresses, that a reset sets them
  again, and `NET_STATUS` with and without a host. `make hwtest` reads
  `NET_STATUS` over the UART and over TCP.
- `make -C demo test` checks the join behind the monitor: `x`, the
  board's text, F12 back to the monitor, `v`, and `h`. nice_cpu's own
  test checks the demos.
- The monitor's hello test hides the cursor before it returns, and
  `tb_dbg` checks "not paused" and the settings page's cursor.

## V1.6 (2026-11-06)

**Upgrade notes.**

- nice_cpu is at `V1.6`. Its emulator's window draws from a font in the
  address space: a font RAM at `0xFFFE0000`–`1FFF`, Spleen as a
  character ROM at `0xFFFE2000`–`3FFF`, and a font base at
  `0xFFFFFF86` (nice_cpu's SYSTEM.md §1.8). The cores, the devices, and
  the debug link are as in V1.5.
- A program's data accesses to `0xFFFE0000`–`3FFF` reach the fonts now,
  not the RAM there, and `0xFFFFFF86` is a register. A program that kept
  data in the RAM words `0x0000`–`3FFF` through those addresses must use
  others. An instruction fetch there still reads the RAM.

**New.**

- The boards draw the screen from the same fonts as the emulator (#71):
  the font RAM, which a program writes, and Spleen in the character ROM,
  selected by the font base. A program draws its own characters, such as
  the pieces of a game, and the debugger's strip and page stay in Spleen.
  A clear zeros the font RAM and the base (doc/SYSTEM.md, The font).
- The monitor writes 0 to the font base at its start and when a program
  returns, so that its text is in Spleen, and `mon_putc` puts `0x80`–`0x9F`
  on the screen as any character.
- `tools/screenshot.py` draws a program's screen in the font that it
  selected.
- The UART's baud rate is a register, `0xFFFFFF9F`, in bit/s (#75): a
  write of 115200, 230400, 460800, 921600, 1000000, 1500000, or 2000000
  sets it, and the UART takes it once it has sent nothing for 1 ms
  after the write. A
  reset brings back 2000000, and a start keeps the rate, which the tools
  then take with `--baud` (doc/SYSTEM.md, The baud rate).
- The debugger's F10, or `n`, shows the settings page (#75): the IP
  address, the MAC address, the TCP port, and the baud rate, live, in
  their usual notation. The first two and the rate are typed there, or
  the rate stepped with CRSR left and right, and written while the
  program is stopped. Row 28 names F10, with single spaces between the
  keys.
- `make hwtest` sets each baud rate and reads the link back at it.

## V1.5 (2026-11-05)

**Upgrade notes.**

- nice_cpu is at `V1.5`. Its emulator has an SD card controller at
  `0xFFFFFFA0`–`AF`, with the image files of `--sd0` and `--sd1`, where
  it had memory, and so do the boards now. nice_cpu's SYSTEM.md §5 is
  the SD card, and the systems built on the FPGA core are §6. The cores
  and the debug link are as in V1.4.

**System**

- The SD card controller of nice_cpu's SYSTEM.md §5 at
  `0xFFFFFFA0`–`AF`, in SPI mode, on the MEGA65's two slots and the
  Nexys4DDR's one (#55, #56). It starts SDSC, SDHC, and SDXC cards, reads
  their size, checks the CRCs, and has a timeout for every step. A
  command takes time on a board, so a program waits for busy, as
  SYSTEM.md §5 asks.

**Tools**

- `make hwtest` tests the SD card controller, and reads each card: its
  sector 0, the FAT boot sector, and its last sector. It never writes
  to a card. A slot without a card, and a card without a FAT file
  system, are NOT COVERED (#56).

## V1.4 (2026-11-04)

**Upgrade notes.**

- nice_cpu is at `V1.4`. Its assembler has the pseudo-instructions
  `JMP`, `CMP`, `TST`, `PUSH`, `POP`, `CLR`, and `NOP` (ISA.md §10.1),
  so a program that uses one of them as a label or an `.EQU` name no
  longer assembles. The cores, the devices, and the debug link are as
  in V1.3.

**Monitor**

- `u` shows the words of the pseudo-instructions `NOP`, `JMP`, `PUSH`,
  `POP`, `CLR`, `TST`, and `CMP` as those, as it showed `CALL` and
  `RET`, such as `?Z JMP 0x8000` and `CMP R1, 0x20`. Empty RAM shows as
  `NOP`. Where a word matches two, the README's order says which is
  shown, and `niceasm` assembles each row back to its words (#73).
- A program that `r` or `x` ran and that returns with `RET` comes back
  to the start of `mon_exit`, which clears E and VBASE in R14. In V1.3
  it came back one word late and kept both.

## V1.3 (2026-11-03)

**Upgrade notes.**

- nice_cpu is at `V1.3`, with debug link version 6: the reset notice is
  `b06`, and `0xFFFFFFF2` reads 6. A host writes R1–R15 while the core
  is paused, and the program goes on with them. A write of R0–R15 while
  the core is not paused gets the error `e04`, where it got `k` and
  changed nothing.
- Over Ethernet, a console byte that finds the core's input FIFO full
  waits up to 50 ms for room, and holds back the bytes behind it,
  before it is lost with `o`. On the UART it is lost at once, as before.
- `niceemu`'s microsecond counter counts the host's time, so a
  program's microseconds in `niceemu` vary from run to run, as on the
  board. `niceemu --step-time` counts one per step, as it did.

**Monitor**

- A paste into `l` over Ethernet, such as into `nc 192.168.1.65 4510`,
  no longer loses bytes, as the link waits for room in the FIFO. In
  V1.2.1 it did, and `load.py --monitor` was needed there.
- `r ADDR` runs the program at ADDR, and `r` alone the one at `0x8000`.
  `r 0` is the cold start, which leaves the RAM from `0x8000` alone.
- `u [ADDR] [N]` disassembles `N` instructions from `ADDR`, a row each,
  with no host, in the text of nice_cpu's `nicedis.py` and `mon.py`
  (#72). A call, `ADD @--R13, n, R15` and `MOVE R15, target`, shows as
  `CALL target`, and `MOVE R15, @R13++` as `RET`.
- `m` shows the Ethernet station's MAC address, and `m
  02:4E:49:43:45:01` writes it first, so two boards on one network can
  have different ones without the demo's F11. The first byte must be
  even.

**Demo**

- The welcome sends the reader to the monitor's `i` for the IP address,
  where it named F11.

**Tools**

- `mon.py` sets a register of a paused core with `set Rn VALUE`, and
  the PC with `pc ADDR`, where the core goes on at the next `go` or
  `step`. `pc` alone shows the PC and its instruction.
- `hwtest.py` writes R0–R15 of a paused program, steps it to its halt,
  and compares all of it with the same on `niceemu --link`, with `e04`
  for a write while halted and while held. `make linktest` and `make
  cosimtest` run it too.

## V1.2.1 (2026-11-02)

**Upgrade notes.**

- The ROM of the boards and of the release now boots the monitor
  (`monitor/`), with its prompt, and the demo is behind it: `x` and
  RETURN start the demo, and F12, SHIFT and F11 on the MEGA65, goes back
  to the monitor. This is for the time being: the demo moves to
  nice_cpu, and a BASIC interpreter takes its place
  ([#65](https://github.com/MJoergen/NiceMonMEGA65/issues/65)). A
  terminal or a script that typed into the demo at power-up types `x`
  and CR first.

**Memory**

- The MEGA65's RAM is 128K words, where it was 64K, so a program under
  the monitor has `0x8000` to `0x1EFFF`, 92K words, where it had 28K
  ([#68](https://github.com/MJoergen/NiceMonMEGA65/issues/68)). The
  Nexys4DDR keeps 64K words, as its block RAM is nearly full.
- `0xFFFFFF9E` reads the words of the RAM, `0x20000` on the MEGA65 and
  `0x10000` on the Nexys4DDR. In `niceemu` it is plain memory, which
  reads 0, meaning no limit, so one program can take what each target
  has (`doc/PROGRAMMING.md`).
- A clear of the memory takes 1.3 ms on the MEGA65, where it took
  0.66 ms.

**Demo**

- The demo is a program at `0x8000` under the monitor, which copies it
  there from the ROM. Its variables moved to `0xA000`, and F11 tests the
  RAM from `0x0000B000` to `0x0000DFFF`, below the monitor's stack and
  variables, where it tested `0xFFFF8000` to `0xFFFFEFFF`.
- `make demo` builds `demo/build/rom.bin`, the monitor with the demo
  behind it, which `make r6`, `make r3`, `make nexys4ddr`, `make cor`,
  and the release put in the ROM. `demo/build/demo.bin` is now the demo
  alone, at `0x8000`.

**Monitor**

- `x` copies the demo from the ROM to `0x8000` and runs it, as `r` runs
  a program, or says that the ROM has none.
- `i 192.168.1.65` gives the Ethernet station its IP address, and `i`
  alone shows it, so the board needs neither the demo nor the link for
  it. `make hwtest ETH=IP` types it in place of the demo's F11.
- Page Up and Page Down at the prompt scroll back through the rows that
  left the screen, 384 on the MEGA65 and 77 on the Nexys4DDR, and any
  other key shows the screen again. On the MEGA65 they are MEGA with
  CRSR↑ and CRSR↓. The rows shown stay at `0xFFFF0000`, as in
  `niceemu`, which keeps the history but cannot show it.
- `l` loads a program from lines of `ADDR WORD` in hex, the `.bin`
  format, typed on the keyboard or pasted into a terminal on the
  UART, up to an empty line, so the board needs neither the host's
  tools nor storage for it, and `r` runs it (`monitor/README.md`,
  "Loading without a host"). A paste over Ethernet loses bytes, so
  use `load.py --monitor` there. Its lines may have addresses up to the
  monitor's variables, which `0xFFFFFF9E` gives: `0x1EFFF` on the
  MEGA65 and `0xEFFF` on the Nexys4DDR, where the top words are the
  stack that `r` uses. Tabs are blanks, a line of blanks is passed
  over, a line longer than 76 characters is skipped, and a terminal
  that ends the `l` line with CR LF is fine.

**Tools**

- `load.py` and `run.py` refuse a word beyond the board's RAM, or under
  `--monitor` at its variables or above, which would wrap onto another,
  and take the MEGA65's 128K words; `run.py -d` reads up to 131072
  words. `make hwtest` checks the size and the top word of the RAM.
- `run.py` on the UART lost output, and with it the halt notice, when
  the program was still printing at the end of the input: it read
  nothing while it sent the break, and the serial port's buffer
  overflowed, so a long run ended at the time limit. It now reads on
  meanwhile, with the break's ioctls of Linux or of macOS
  ([#67](https://github.com/MJoergen/NiceMonMEGA65/issues/67)).
- `load.py --monitor` and `run.py --monitor` refuse a word in the
  screen, which the monitor clears when it boots.
- `--tcp HOST:PORT` refuses an IPv6 HOST without brackets, whose
  colons it cannot tell from the one before PORT.
- `--tcp HOST:PORT` reaches `niceemu --link ADDR:PORT` on another
  computer, with the transport of `--tcp PORT`, which stays 127.0.0.1
  (`tools/README.md`, "Without a board"). The link has no
  authentication, so serve it beyond 127.0.0.1 only on a trusted
  network ([#51](https://github.com/MJoergen/NiceMonMEGA65/issues/51)).
- `load.py --monitor` and `run.py --monitor` run a program at `0x8000`
  under the monitor in the ROM: they keep the ROM, load the program,
  start the core, which boots the monitor, and type `r`. `--rom FILE`
  loads a monitor in the ROM's place, for `niceemu --link` and `make
  cosim`. `run.py --monitor` prints what `niceemu` prints for the two
  joined, and `make hwtest`, `make linktest`, and `make cosimtest`
  compare them (`monitor/README.md`, "Loading from a host").
- `make flash COR=f.cor SLOT=N` works on the MEGA65 R6, tested into
  slot 5. The MEGA65's flash protects its sectors with their DYB bits,
  and openFPGALoader's erase failed on them with `timeout: 23`
  ([trabucayre/openFPGALoader#752](https://github.com/trabucayre/openFPGALoader/issues/752)).
  `flash.py` now clears them first through openFPGALoader's bridge,
  which needs pyftdi (`pip install pyftdi`). It then loads the slot's
  bitstream into the FPGA over JTAG. It no longer starts the slot
  through slot 0's serial monitor, which is gone when slot 0's core
  starts another slot at power on. Hold No Scroll at power on to start
  the slot from the flash
  ([#41](https://github.com/MJoergen/NiceMonMEGA65/issues/41)).
- `make r3`, `make r6`, `make nexys4ddr`, and `make cor` put the ROM of
  the release in the ROM by default, and build it first, as the release does. `ROM=`
  (empty) builds a bitstream without a ROM, whose core waits, held, for
  the link, as these targets did before.
- `make flash` warns when the bitstream has no ROM, as the board then
  starts from the flash with an empty screen.
- `make hwtest` tells the board from the FPGA it programs, an xc7a100t
  on the Nexys4DDR, and no longer from the path of the bitstream. It
  pastes `hello.bin` into the monitor's `l` at the UART's full rate,
  and checks that `load.py` refuses a word beyond the RAM; `make
  cosimtest` does the same on the RTL. `make -C monitor test` checks
  `l` with 64K words of RAM, and the ring of the history at the sizes
  of both boards, and `tb_nicemon` reads `0xFFFFFF9E`.

**Nexys4DDR**

- Its screen, font, and UART FIFO are in block RAM, where Vivado had
  put them in LUTs, so its build takes 17878 LUTs, where it took
  28964, and 123 of the 135 block RAMs
  ([#70](https://github.com/MJoergen/NiceMonMEGA65/issues/70)). It
  still meets 90 MHz, by 0.020 ns.

## V1.2 (2026-10-31)

**Upgrade notes.**

- nice_cpu moves to `V1.2`. The debug link stays at version 5, and
  R0–R15 at `0xFFFFFFE0`–`EF` now read the core's registers live while
  it runs, where they were undefined before. A hold of a running core
  still leaves them undefined. `mon.py`'s `regs` shows them live.
- nice_cpu V1.2's runtime moves `_exit` from `lib.nasm` into the
  start-up files, and its C library's `nice_putc` is an import, so a C
  program of your own needs a rebuild, and a program that joins
  `lib.nasm` without a start-up file of the runtime's must define
  `_exit` itself
  ([nice_cpu's release notes](https://github.com/MJoergen/nice_cpu/blob/main/RELEASE_NOTES.md)).
  `make examples` rebuilds the examples. A program that runs with the
  runtime's start-up files needs no change.
- The program's 25 rows sit 64 lines higher on HDMI and VGA: the
  picture has 29 rows centered, the program's and the 4 rows of the
  on-board debugger's strip under them, which are black until MEGA+HELP
  shows the strip.
- A break on the UART, or a host's half-close over Ethernet, ends the
  line's input and no longer the keyboard's, as nice_cpu's SYSTEM.md §5
  says from V1.2 on: once the bytes before it are read, the console
  reads `0x200`, while the keyboard's bytes still come. Before, every
  byte after a break was lost until the core was started again. A new
  connection over Ethernet starts the line anew, as a connection to
  `niceemu --link` does: the next host's bytes reach the program, so a
  host can type to a monitor that another host has left. The demo
  still ends at a break, as it does in `niceemu`.
- Keys that gave nothing have meanings now. On the MEGA65, CLR/HOME is
  Home, MEGA with CRSR↑ or CRSR↓ is Page Up or Page Down, and MEGA+HELP
  is the on-board debugger's; on the Nexys4DDR, Home, Page Up, and Page
  Down are the keys of those names, and Scroll Lock is the debugger's.
  A program gets `ESC [ H`, `ESC [ 5 ~`, and `ESC [ 6 ~` for Home, Page
  Up, and Page Down, as xterm sends them, and nothing for the
  debugger's key.
- The Ethernet station answers a segment that fits no connection with a
  reset, so a second host's `connect` fails at once while one host is
  connected, where it waited for its retries (see Ethernet).

**The on-board debugger**

- MEGA+HELP brings up a debugger in the FPGA, with no cable and no PC
  ([DEBUGGER.md](DEBUGGER.md),
  [#52](https://github.com/MJoergen/NiceMonMEGA65/issues/52) and
  [#53](https://github.com/MJoergen/NiceMonMEGA65/issues/53)): a strip
  of four rows under the program's screen, white on dark blue, and the
  keyboard is the debugger's until MEGA+HELP again. On the Nexys4DDR
  the key is Scroll Lock. Nothing changes for those who never press it.
  The README's [On its own](../README.md#the-on-board-debugger) says
  how to use it, with a picture.
- The strip shows R0–R15, live while the program runs, and dimmed
  while the core is held; the state, `RUNNING`, `PAUSED`, `BRK n` at
  breakpoint n, `HALTED n` with the reason, `HELD`, or `NO LINK` until
  the link has answered after reset; the PC, the instruction word
  there, and the flags of the status register; and the instruction
  decoded, as `nicedis.py` writes it, with the constant words folded
  in.
- F1 steps, F3 goes on, F5 pauses, F7 holds, and F9 restarts the
  program at 0, with the ROM as it is. The letters `s`, `g`, `p`, `h`,
  and `r` do the same, as in `mon.py`. A key that needs a stopped core
  shows the link's answer, `e02`, and does nothing else.
- F11 shows the page, a window on the memory over the program's rows:
  the window's and the cursor's addresses and the four breakpoints in
  its header, 22 rows of 8 words, the cursor's word in swapped colors,
  and a word at a breakpoint white on dark red. The cursor keys, Page
  Up and Page Down, and Home move; hex digits, DEL, and RETURN write a
  word at the cursor; `a` on an empty field, an address, and RETURN
  move the window there; `b` on an empty field sets a breakpoint at the
  cursor, the lowest free of the four, or clears the one that is there,
  and says `none free`; and ESC clears the field, or leaves the page.
  The words are read while the core is stopped, and dimmed while it
  runs.
- F12 toggles a sticky setting, off after reset: whether MEGA+HELP
  leaves the strip up, live, with the keys the program's. With the
  strip up, a halt, a breakpoint, or a pause the debugger did not ask
  for brings the debugger back, with the keyboard. From off, nothing
  does.
- The debugger is a client of the debug link inside the system, through
  the side port of nice_cpu V1.2's link
  ([nice_cpu#86](https://github.com/MJoergen/nice_cpu/issues/86)): a
  host on the UART or over TCP keeps its line while the debugger is up,
  and gets the `p`, `x`, or `h` of a stop that the debugger caused, as
  it does for a breakpoint. The debugger cannot load a program, write
  a register, or know a label; a host does that.
- On the Nexys4DDR, while the debugger has the keyboard, BTNL steps,
  BTNR goes on, BTNU and BTND move the page's cursor, BTNC leaves, and
  the seven-segment display shows the PC, live, or dashes while the
  core is held. The program reads the buttons as 0 meanwhile, and its
  display shows again after.

**Boards**

- The MEGA65's keyboard sends `ESC [ H` for CLR/HOME, and `ESC [ 5 ~`
  and `ESC [ 6 ~` for MEGA with CRSR↑ and CRSR↓, so MEGA is a modifier
  of those two keys. The Nexys4DDR's keyboard sends the same for Home,
  Page Up, and Page Down, apart from the keypad's keys with the same
  scan codes. nice_cpu's SYSTEM.md §1 now defines the bytes of the keys
  that every keyboard has, which the MEGA65's keyboard follows and
  `niceemu --window` sends too.
- The R6 meets 100 MHz with 0.33 ns of setup slack, and the Nexys4DDR
  90 MHz with 0.17 ns, with the debugger. The TCP server's paths were
  registered, so the worst paths are the core's again, and the
  station's have about 2.3 ns to spare on the R6
  ([#49](https://github.com/MJoergen/NiceMonMEGA65/issues/49)). The
  debugger's overlay takes 4 block RAMs on each board.
- The R3 build has the debugger and the station, and has not been
  tested on hardware yet.

**Ethernet**

- The station answers a segment that fits no connection with a reset,
  as RFC 9293 has it, where it answered nothing: a `connect` from a
  second host while one is connected fails at once with "connection
  refused", where it waited about two minutes, and a host on a
  connection the board has dropped learns of it at once, where it
  retried for a quarter of an hour. `nicelink.py` says that another
  host has a connection to the board when it is refused
  ([#46](https://github.com/MJoergen/NiceMonMEGA65/issues/46)).
  Segments to other ports, and every segment while the IP address is
  0, get nothing, as before.
- Once a connection is open, a segment without ACK is dropped, and one
  that acknowledges what the board has not sent gets an ACK and is
  dropped, as RFC 9293 has it
  ([#50](https://github.com/MJoergen/NiceMonMEGA65/issues/50)).
- A new connection starts the line's input anew (see the upgrade
  notes), as one to `niceemu --link` does, through `rx_resume_i` of
  nice_cpu V1.2's link
  ([nice_cpu#90](https://github.com/MJoergen/nice_cpu/issues/90)).
- Fixed: after a reset from the host, or the last of the 17 tries, with
  data out, the retransmission timer stayed armed and ran out every
  300 ms until the next connection
  ([#45](https://github.com/MJoergen/NiceMonMEGA65/issues/45)); an ACK
  that covered the data and the board's FIN at once was not booked; an
  ACK that came while a segment was sent again freed its first bytes,
  which the link's next output could overwrite while the sender still
  read them, so the host got wrong bytes with a wrong checksum; and a
  segment of an old connection could, with odds of 1 in 2³², be taken
  for a new connection from the same port.
- The server is split into its parser of segments, its choice of the
  segments to send and their sender, its buffers, and its
  retransmission timer, and the arbiter of the frames to send is an
  entity of its own
  ([#39](https://github.com/MJoergen/NiceMonMEGA65/issues/39)), each
  with a formal proof (see Tests). A segment is answered a cycle or two
  later than before, which no timeout sees.

**Monitor**

- The monitor for the ROM is written and tested in `niceemu`, not on a
  board yet ([monitor/](../monitor/README.md),
  [#24](https://github.com/MJoergen/NiceMonMEGA65/issues/24)): a
  dispatch table at 0 with nine entries, a hardware abstraction layer
  for programs at `0x8000` in the C ABI, with the reset, the exit, the
  version, the console, and the screen, and a main loop with the
  commands `r`, `d`, `c`, `v`, `h`, and `?`. `make monitor` builds it,
  `make -C monitor test` runs it in `niceemu` with programs built by
  nice_cpu's `nicebuild.py --monitor`, and `make cor
  ROM=monitor/build/monitor.bin` puts it in a core of your own. It
  cannot load a program on its own, so the release's ROM still holds
  the demo.

**Demo**

- The demo runs in `niceemu --window` too, from nice_cpu V1.2 on, with
  the keys typed into the window, and the comet keeps its pace, as the
  window runs one step per microsecond ([demo/](../demo/README.md)).

**Tools**

- `make flash COR=f.cor SLOT=N` writes a core file into slot N, 1 to 7,
  of the MEGA65's flash over the JTAG cable, with no SD card and no key
  held at power on. It stops unless slot 0's core is for the core
  file's revision, shows what the slot held, verifies the flash, and
  starts the slot, through the serial monitor of slot 0's core if that
  core does not start it. It is written against the MEGA65's
  documentation and openFPGALoader, and has not been run on a board yet
  ([#41](https://github.com/MJoergen/NiceMonMEGA65/issues/41)).
- `tools/screenshot.py --debugger` draws the on-board debugger's strip
  under the screen, as the board shows it at the stop. The README's
  picture of the debugger is made with it.
- `make monitor` builds the monitor, and `make diagrams` draws the
  block diagrams of `src/` (needs pdflatex and pdftoppm).

**Documentation**

- `doc/DEBUGGER.md` is the design note of the on-board debugger: the
  states, the display, the keys, the Nexys4DDR, the side port, the
  modules, the tests, the stages, and the decisions with their reasons.
- `src/README.md` and `src/eth/README.md` have block diagrams of the
  system and of the Ethernet station, drawn by `make diagrams` from the
  `.tex` files beside them.
- `doc/EMULATOR.md`'s table has `niceemu --window`, and a row for the
  keyboard. `doc/SYSTEM.md` has the keys, the 29 rows, the line's
  input, the debugger, and the station's resets.
- `doc/BASIC_SURVEY.md` surveys the BASIC dialects behind the
  interpreter planned for the ROM
  ([#54](https://github.com/MJoergen/NiceMonMEGA65/issues/54),
  milestone V2.0).
- `monitor/README.md` has the monitor's table, the entry ABI, its
  decisions, and what is not decided yet.

**Tests**

- `make test` runs `tb_dbg`, the debugger on the system, driven by
  keys, toggles, and the Nexys4DDR's buttons; `tb_dbg_host`, its
  adapter against the link's side port, with a host on the UART beside
  it; `tb_dbg_decode`, the decode of row 27 against `nicedis.py` on
  about 3000 words from `sim/gen_decode.py`; and the monitor's test in
  `niceemu`. `tb_text` checks the strip and the page, `tb_kbd` and
  `tb_ps2` the toggle keys and the new keys, and `tb_nicemon` the live
  registers, the keyboard after a break, and the station's ports.
- `tb_eth_tcp` has steps for the edges of RFC 9293, and
  `tb_eth_tcp_random` runs 2500 random actions of the host and the link
  on one connection whose sequence numbers cross 2³², which found the
  retransmission bug above.
- `make formal` proves the check of the frame check sequence, the
  arbiter, the two FIFOs of frames across their clocks, the TCP
  server's timer, buffers, choice, parser, and sender, the connection
  itself with free models of its parser and choice, and the debugger's
  adapter to the side port
  ([#37](https://github.com/MJoergen/NiceMonMEGA65/issues/37)).
- `make lint` checks `src/dbg/`, and every Vivado build writes the
  worst paths of the TCP server to `build/tcp_paths.rpt`.

## V1.1 (2026-10-29)

**Upgrade notes.**

- `0xFFFFFF98`–`9D` are the Ethernet station on every board. They read
  0 and took no write before, on the MEGA65 and on the Nexys4DDR.
- The debug link over Ethernet reads and writes all memory with no
  password. The station is silent until it gets an IP address, so give
  it one only on a network you trust.
- nice_cpu moves to `V1.1`, and the debug link to version 5. A clear of
  the memory now ends the halt and the stop of the program it wipes:
  bit 1 of the control register, the halt reason, and the stop register
  read 0 after it. So after `load` in `mon.py`, `status` shows `held`,
  not `held, after a halt`, and the control register reads `00000009`.
  A hold alone keeps them, as before
  ([#32](https://github.com/MJoergen/NiceMonMEGA65/issues/32)).
- `load.py`, `run.py`, and `mon.py` have no default line: they need
  `--eth`, `--port`, `--tcp`, or `--cosim`, and stop with an error
  without one. `/dev/ttyUSB1` was the default before. `hwtest.py`,
  `flash.py`, `release.py`, and `demo_hw.py` need `--port`. Likewise,
  `make load`, `make run`, and `make mon` need `ETH=` or `PORT=`, and
  `make hwtest`, `make flash`, and `make release` without
  `ARGS=--publish` need `PORT=`.

**Ethernet**

- Every board has an Ethernet station on its Ethernet port, at
  100 Mbit/s ([SYSTEM.md](SYSTEM.md#the-ethernet-station)). A write of
  its IP address to `0xFFFFFF9A`, by a program or over the link on the
  UART, turns it on. It is 0 after reset, which answers nothing.
  There is no DHCP client yet, so a board needs its USB cable, a
  program that sets the address, or the demo's F11, before `--eth` can
  reach it ([#34](https://github.com/MJoergen/NiceMonMEGA65/issues/34)).
- The R3 build has the station but has not been tested on hardware yet.
- The station answers ARP requests and pings to its IP address. Its MAC
  address is 02:4E:49:43:45:00 after reset, and `0xFFFFFF9B`–`9C` change
  it, which two boards on one network need.
- It serves the debug link on TCP port 4510, to one host at a time. The
  connection is the line, as the UART is: it sends no `b` notice, and a
  half-close is a break. While a host is connected, the UART's link
  bytes are dropped. A new connection from the same host replaces the
  old one.
- The board resends what the host does not acknowledge after 300 ms, and
  drops the connection after 17 tries.
- `0xFFFFFF98`, `99`, and `9D` count the good frames received, the bad
  and dropped ones, and the frames sent.

**Boards**

- F1 to F12 give xterm's escape sequences, on the Nexys4DDR's keyboard
  and on the MEGA65's, which has F1, F3, and so on to F11, and the even
  keys with SHIFT. They gave nothing before.

**Demo**

- The welcome says to give the board an IP address with F11, then to
  load and debug programs over Ethernet with `tools/mon.py --eth`. It
  pointed to the debug UART before.
- The function keys switch between the demos in the ROM, which a menu in
  the second row lists. The typewriter is F1, and runs at power-up. The
  other five are the ideas of
  [#28](https://github.com/MJoergen/NiceMonMEGA65/issues/28), each on a
  key of its own.
- An ESC that no byte follows within 10 ms is a key of its own, as the
  MEGA65's ESC key sends it. The typewriter dropped it before, and took
  the key after it as it was, and it held up the other demos until the
  next key.
- F3 shows the bytes of each key, in hex and as characters.
- F5 shows the 256 characters of the font and ramps of seven colors, as
  backgrounds and as foregrounds, to check the video output.
- F7 shows the performance counters since reset, as a clock and in
  decimal, with the clock's frequency, and those of a prime sieve that
  runs again and again, with its cycles per instruction.
- F9 is a game: the cursor keys steer a comet to the stars, and its tail
  grows with each one.
- F11 is the board. It tests the RAM, the math unit, the timer's
  interrupts, and the performance counters, with PASS or FAIL for each.
  Below the tests it shows the Ethernet station's IP and MAC addresses
  and its three counts, and the I and M keys type a new IP or MAC
  address and write it to the station
  ([#40](https://github.com/MJoergen/NiceMonMEGA65/issues/40)). ESC,
  CTRL-C, or RUN/STOP cancels the typing. A byte of a MAC address has
  one or two hex digits, and a number of an IP address any number of
  digits, such as `001`, as long as it is 255 at most. A
  board with the demo in its ROM can thus get its IP address from its
  own keyboard, with no USB cable.

**Tools**

- `load.py`, `run.py`, and `mon.py` take `--eth HOST[:PORT]` for the
  link over the board's Ethernet port. They close each connection with a
  reset, by `SO_LINGER` 0.
- `make flash` (`tools/flash.py`) writes a bitstream into the
  Nexys4DDR's flash, verifies it, and waits for the board to start from
  it. With jumper JP1 on QSPI, the board then starts the system at power
  on, and with the release's bitstream it shows the demo, as a MEGA65
  does with a core file in its flash.
- `mon.py` disassembles with `d ADDR N`, and shows the instruction at the
  PC after a pause, a step, and a breakpoint. The disassembler is
  nice_cpu's `assembler/nicedis.py`, new in nice_cpu's `V1.1`.
- `mon.py --symbols FILE` and its `symbols FILE` command read the labels
  of `niceasm.py --symbols` and `nicebuild.py --symbols`. An address may
  then be a label, `label+N`, or `label-N`, and the output shows the
  labels.
- `mon.py` ends without a traceback on `quit`, also over `--tcp` and
  `--cosim` ([#29](https://github.com/MJoergen/NiceMonMEGA65/issues/29)).
- `tools/screenshot.py` runs a program in `niceemu` and draws its screen
  as a PNG picture, as the text display shows it. The README's pictures
  of the demo are made with it.
- `make linktest` checks `mon.py`'s commands on `niceemu --link` too.
- The tools read the link's version when they connect, and stop with a
  message on a major other than 0 (nice_cpu's DEBUG.md §9). `mon.py`'s
  `status` shows the version as major.minor, and `hwtest.py` checks the
  version of the pinned nice_cpu's `debug_link.vhd`, not a fixed 4.

**Documentation**

- `SYSTEM.md`, `EMULATOR.md`, `CODING_STYLE.md`, `RELEASE.md`, and
  `RELEASE_NOTES.md` move into `doc/`. `README.md` and `CONTRIBUTING.md`
  stay at the root.
- The README is for users of the core files, on their own and with the
  serial port, with a worked example. The guide to `load.py`, `run.py`,
  and `mon.py` moves to `tools/README.md`. The new `doc/PROGRAMMING.md`
  says how to write and build programs, and the new `doc/README.md`
  lists the documents.

**Tests**

- `make test` runs the Ethernet station's testbenches: `tb_rmii_rx`,
  `tb_rx_fcs`, `tb_eth_rx_fifo`, `tb_eth_tx_fifo`, `tb_rmii_tx`,
  `tb_eth`, which drives the station at its pins, and `tb_eth_tcp`,
  which checks the TCP server against a host modeled in VHDL.
- `make hwtest` and `make linktest` run the demo's self-test, F11, and
  check that its four tests pass. The tests of the timer and of the
  counters depend on the core's timing, so a nice_cpu bump that changes
  it fails them
  ([#43](https://github.com/MJoergen/NiceMonMEGA65/issues/43)).
- `make -C demo test` also checks how a failed self-test shows, the
  colors of the menu and of PASS and FAIL, and the keys that no test had.

**Release**

- `make release` builds the Nexys4DDR only with `FLOW=timing`, as its
  Makefile does, and no longer tries the default flow first, which never
  meets timing there.
- `make release` builds the R6 with the flow of `verified.json` first,
  and then with the other one, for the ROM can cost the margin of the
  bump's build. The notes say when the other flow was needed.
- `make hwtest ETH=IP` tests the Ethernet station too, after all the
  other checks: the demo's F11 gets the address as keys over the UART,
  and gives it to the station, which is pinged, reached by the link over
  TCP, and runs the programs of the comparison over `run.py --eth`. A
  board that receives no frame has no Ethernet connection, and the
  summary names the rest of the test after NOT COVERED, which fails
  nothing; without `ETH`, it names the station there.
  `make release ARGS="--eth IP"` passes it on.

## V1.0 (2026-10-28)

**Upgrade notes.**

- nice_cpu `V1.0` builds `niceemu` with Zig 0.17.0, and no longer with
  0.15. The tools, `make hwtest`, and `make -C sim check-steps` need the rebuilt
  binary: `make -C nice_cpu/emulator build`.
- This is the first release with files: the three bitstreams, the two
  MEGA65 core files, and the C examples are on the GitHub Release.

**Boards**

- `make cor` builds core files for the R3 and the R6, which MEGAFLASH
  writes to a slot of the MEGA65's flash. The board then starts NiceMon
  without a JTAG cable.
- Every build writes the core's worst paths in and out of the core,
  `build/core_in.rpt` and `build/core_out.rpt`, from which nice_cpu sets
  its budget for the core's ports.

**Tools**

- `tools/mon.py` is an interactive shell on the debug link, and `make mon
  [FILE=p.bin]` runs it. It reads and writes memory, loads a `.bin` file,
  starts, holds, pauses, steps, and goes on, sets the breakpoints, and
  shows the registers and the state. It shows the program's output and
  the link's notices as they arrive, and sends console input or passes
  the terminal through to the program. It takes `--port`, `--tcp`, and
  `--cosim`, as `load.py` does.

**Documentation**

- `README.md` is now for users of the core files: the MEGA65 on its own,
  and with the serial port. The address map, the link, the screen, the
  ROM, and the Nexys4DDR's devices are in `SYSTEM.md`. The tests, the
  formal checks, `make hwtest`, and the badge are in `CONTRIBUTING.md`.

**System**

- `nicemon.vhd` is split into `mem.vhd`, `devices.vhd`, `scr_regs.vhd`,
  and `board_io.vhd`, with no change in behavior or address map.
  `kbd_ascii.vhd` is now `kbd_m65_ascii.vhd`.
- `formal/mem.sby` proves the memory by k-induction, and that a read
  returns what was written, 0 after a clear, or the ROM's word.

**Tests**

- The `.nasm` files of `sim/` are laid out in nice_cpu's columns, and
  `make test` checks the layout with nice_cpu's `nicefmt.py`.

**Demo**

- The bitstreams and the core files of the release have a demo in the
  ROM (`demo/`), so a MEGA65 with no computer on its debug UART no longer
  starts with a black screen. It shows a welcome with the version, and
  then a typewriter: what is typed on the keyboard appears on the screen,
  with RETURN, DEL, TAB, the cursor keys, CTRL-L to clear, and scrolling.
  The tools hide the ROM, and load programs as before.
- `make demo` builds it, and `make test` and CI run it in `niceemu`.

**Release**

- `make bump TAG=V1.0` moves nice_cpu to a tag, builds the R6 bitstream,
  and records the timing in `badge-mega65.json`, the badge that nice_cpu's
  README shows, and in `verified.json`.
- `make release` builds, tests, and publishes a release
  ([RELEASE.md](RELEASE.md)).
- The tags follow nice_cpu's version names, and CI takes its Zig version
  from nice_cpu's CI.

## RC06 (2026-10-27)

**Upgrade notes.**

- The debug link is version 4. `load.py` and `run.py` disable the
  breakpoints before a load, as the board keeps them until a reset, where
  `niceemu` clears them at each connection.

**Debug link and tools**

- Four breakpoints on every board, at `FFFFFFF4`–`FF`. The core pauses
  before an enabled one, and the link sends `x` with its number.
- `nicelink.py` has `set_breaks()`, and takes `x` as a pause.

**Tests**

- `tb_nicemon` stops `sim/break.nasm` at a read of memory and in an
  interrupt routine, and checks that a reset clears the breakpoints.
- `hwtest.py` has `test_break`, which runs on the board, in `make
  linktest`, and in `make cosimtest`.

**Timing**

- The R6 meets 100 MHz by 0.595 ns, and the Nexys4DDR 90 MHz by
  0.111 ns.

## RC05 (2026-10-26)

**Upgrade notes.**

- The debug UART runs at 2 Mbaud, not 115200 baud. The tools default to
  it. A bitstream from before needs `--baud 115200`.
- The debug link is version 3.

**Debug link and tools**

- Bit 4 of the control register pauses the core at a step boundary, and
  the link sends `p` (version 2). The link reaches all of the memory and
  the registers while the core is paused. The counters, the timer, and the
  fetch statistics stop. Console and keyboard bytes wait in the input
  FIFO.
- Bits 4 and 5 run one step of a paused core, and the link sends `p`
  again, or `h` if the step halted (version 3).
- Loading `primes.bin` takes 0.7 s instead of 6.9 s.
- `nicelink.py` has `PAUSE` and `step()`.

**Simulation**

- `make cosim` runs the system in GHDL with its debug UART on a TCP port,
  and the tools reach it with `--cosim PORT`.
- `make cosimtest` runs `hwtest`'s checks and programs on it against
  `niceemu`, without a board. CI runs it on both cores.

**Tests**

- `hwtest.py` has `test_pause` and `test_step`. `test_step` compares
  R0–R15 after each step with `niceemu --trace`.

**Timing**

- The R6 meets 100 MHz by 0.628 ns, and the Nexys4DDR 90 MHz by
  0.187 ns.

## RC04 (2026-10-24)

**Upgrade notes.**

- The command line on the debug UART is gone. The board speaks nice_cpu's
  debug link instead, as `niceemu --link` does, and the tools of `RC02` do
  not work with it.
- `run.py` ends at the link's halt notice, not at the halt message in the
  output. On `--timeout` it holds the core, prints the dumps, and exits
  with status 3.

**Debug link and tools**

- `tools/nicelink.py` speaks the link over the debug UART, or over TCP to
  `niceemu --link` with `--tcp PORT`. It retries a bad packet, and paces
  the input by the free space of the input FIFO.
- `run.py` takes `niceemu`'s options, including `--symbols`, and names
  where a program stopped after a halt other than `HALT`.
- `make linktest` checks the tools on `niceemu --link`, without a board.

**System**

- The microsecond counter, `TIME_LO` and `TIME_HI` at `FFFFFF44` and
  `FFFFFF45`, is exact on every board.
- The fetch statistics stop while the core is held or halted.

**Boards**

- The Nexys4DDR's 16 LEDs, two RGB LEDs, seven-segment display, five
  buttons, and 16 switches are registers at `FFFFFF90`–`96`. On the
  MEGA65, the block reads 0, as in the emulator.
- DEL with CTRL held stays DEL on the PS/2 keyboard, as on the MEGA65.
- A failed Vivado build fails `make`.

**Tests**

- `tb_board_io` checks the Nexys4DDR's drivers, and `tb_ps2_nicemon` the
  PS/2 keyboard into the core's input. Keys typed while the input is full
  are lost on the Nexys4DDR, as a PS/2 keyboard cannot wait.
- CI runs on Ubuntu 24.04, with both cores and the examples.

## RC02 (2026-10-23)

The first release candidate here. It holds:

- **The system**, `src/nicemon.vhd`: nice_cpu's pipelined core, or its
  multi-cycle core with `NICE=multi`, with RAM, a ROM at address 0,
  nice_cpu's devices, and an input FIFO fed by the debug UART and the
  keyboard.
- **Three boards**: the MEGA65 R3 and R6 at 100 MHz, and the Digilent
  Nexys4DDR at 90 MHz with a PS/2 keyboard.
- **A text display** on VGA and HDMI, with QNICE's screen registers at
  `FFFFFF80`, a cursor, and 12-bit RGB colors.
- **A command line** on the debug UART at 115200 baud, and the host tools
  `load.py`, `run.py`, and `hwtest.py`. `run.py` runs a program as
  `niceemu` does, for diffing, and `make hwtest` tests a board, with
  nice_cpu's benchmark.
- **Tests**: GHDL testbenches of the system, the keyboard, and the
  display, formal checks of the command line, the input FIFO, and the
  buses, and `vsg` lint, all in CI.
- **[EMULATOR.md](EMULATOR.md)**, the known differences from the emulator.
