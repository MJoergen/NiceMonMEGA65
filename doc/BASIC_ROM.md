# BASIC's image outside the bitstream

The design of issue
[#153](https://github.com/MJoergen/NiceMonMEGA65/issues/153): at the
start, the monitor replaces BASIC's half of the ROM with a file from
the SD card. **This is a draft. Of its [Stages](#stages), the first
three, the header, the RTL, and the monitor, are written, but for the
third's whole load in the RTL. The
decisions of 2026-11-18 are in [Decisions](#decisions), with those
that a review against the code changed the same day, and only the
details of [Open questions](#open-questions) are open.**

- [Goals](#goals)
- [What there is now](#what-there-is-now)
- [The proposal in short](#the-proposal-in-short)
- [The ROM](#the-rom)
- [Why not the control register](#why-not-the-control-register)
- [Why not the first fetch](#why-not-the-first-fetch)
- [The image](#the-image)
- [The cold start](#the-cold-start)
- [The monitor for later BASICs](#the-monitor-for-later-basics)
- [Over the link](#over-the-link)
- [The emulator and the tests](#the-emulator-and-the-tests)
- [The tools](#the-tools)
- [Releases](#releases)
- [Not included](#not-included)
- [Decisions](#decisions)
- [Open questions](#open-questions)
- [Stages](#stages)

## Goals

- A change of BASIC needs no new bitstream and no new `.cor` file. The
  monitor is expected to change much less often than BASIC from now on.
- A user can run another BASIC, or their own, by copying one file to
  the card, without Vivado.
- A board with no card, or with no file on it, works as it does today.
- The RAM under the ROM stays free for programs, as it is now.
- A program still runs on the board as `niceemu` runs it.
- No more block RAM, as the Nexys4DDR has little left, and the core's
  timing margin at 100 MHz is small.

## What there is now

- The ROM has 32768 words at `0x0000`–`0x7FFF`, in front of the RAM,
  from `build/rom.bin` at synthesis (`src/rom.vhd`, `src/mem.vhd`). A
  write to it is dropped.
- Since #152 it holds two images, assembled apart: the monitor's at 0,
  9590 words, and BASIC's at `BASIC_BASE`, `0x4000`, 5075 words
  ([monitor/INTERNALS.md](../monitor/INTERNALS.md#the-roms-words)).
- The monitor knows only BASIC's two vectors, `BAS_COLD` at `0x4000`
  and `BAS_WARM` at `0x4002`. BASIC calls the monitor only through the
  entries of the dispatch table, as a program does: table 1.6, with
  37 entries. Both share the
  layout of the RAM at the top, `STACK`, `BASIC_WORDS`, and `MON_RAM`
  of `monitor/common.nasm`.
- The cold start, `mon_reset`, ends with `JMP BAS_COLD`. `SYS 0` runs
  it too. It reads no card: the first `DIR` or `LOAD` mounts one.
- Bit 3 of the link's control register hides the whole ROM, so the RAM
  is at 0. The RAM under the ROM keeps its words while the ROM is
  shown.

## The proposal in short

- BASIC's half of the ROM, `0x4000`–`0x7FFF`, takes the core's writes
  from the FPGA's configuration until the monitor locks it, right
  before BASIC first runs. Then it is locked until the FPGA is
  configured again.
- At that first cold start, the monitor looks for the files
  `BASIC*.ROM` in the folder `NICE` of the cards, and takes the one
  whose header has the highest version. It reads the file once, into
  the program's RAM from `0x8000`, checks it there, and copies it into
  the ROM.
- An invalid file never touches the ROM, and the bitstream's BASIC
  runs.
- To get the bitstream's BASIC back, the card is taken out, or its
  file deleted, and the FPGA is configured again: a power cycle, or a
  new core from MEGAFLASH.
- The lock is set by a store of the monitor's. No new register, and no
  change of the control register.
- The monitor gets what later BASICs need of it, so that a release of
  BASIC alone needs no bitstream
  ([The monitor for later BASICs](#the-monitor-for-later-basics)).

## The ROM

- **A write port.** `src/rom.vhd` gets a write on port B, the data
  bus's port. Its two banks are the even and the odd words, so both
  get the write, for the upper half of each, which is BASIC's half of
  the ROM. The block RAM has the port already, as a true dual-port
  RAM: no block RAM more. Its contents at configuration still come
  from `build/rom.bin`. `synth/rompatch.tcl` finds the ROM's block
  RAMs by the names `a_even_reg` and `a_odd_reg`, which a memory that
  is written may not keep, so `make r6 ROMPATCH=` needs a look. The
  script stops when it does not find the layout that it knows.
- **The write is registered**, and reaches the ROM a cycle late. The
  worst path out of the core has 0.12 ns on the R6 in `V2.3`, and the
  register keeps the ROM's 32 block RAMs off the core's store paths. A
  read right behind the write must still return the new word, for the
  probe of [The cold start](#the-cold-start).
- **The lock.** A flag, 0 at configuration, that nothing resets: not
  the system's reset, not a start of the core, not a clear. A write by
  the core to the monitor's half, `0x0000`–`0x3FFF`, with the ROM
  shown, sets it. The write itself is dropped, as now. The monitor
  makes that write right before it goes to BASIC
  ([The cold start](#the-cold-start)). A write through a byte window
  that reaches the monitor's half sets it too. A fetch sets nothing
  ([Why not the first fetch](#why-not-the-first-fetch)).
- **The core's writes to BASIC's half.** While the flag is 0 and the
  ROM is shown, a write by the core to `0x4000`–`0x7FFF` goes to the
  ROM. Once it is 1, the write is dropped, as now.
- **The link's writes** to `0x4000`–`0x7FFF` with the ROM shown go to
  the ROM, whatever the flag says ([Over the link](#over-the-link)).
  A link's write to the monitor's half is dropped, as now, and does
  not set the flag.
  With the ROM hidden, they go to the RAM, as now, so the tools are
  unchanged: they hide the ROM before they load.
- **The RAM under the ROM** is untouched, and reached as now, with the
  ROM hidden.
- **In `src/mem.vhd`**, a write to the ROM's range today is dropped.
  It then reaches the ROM's port B, unless it is to the monitor's half,
  or by the core with the flag set. `mem.vhd` does not know today
  whether a request is the link's or the core's, so it gets an input
  for that from `nicemon.vhd`. BASIC's half is the upper half of the
  ROM by `G_ROM_ADDR_BITS`, as the ROM of `tb_nicemon` has 2K words.
  The slack is small on every board, so the timing is to be checked
  after the change.

## Why not the control register

The control register at `0xFFFFFFF0` is the link's, in nice_cpu's
`hdl/src/debug_link.vhd` (DEBUG.md §6). It is not usable here:

- **The core cannot reach it.** To the core, `0xFFFFFFD0`–`FF` are RAM
  ([doc/SYSTEM.md](SYSTEM.md)). The monitor loads the file at power-on,
  on the core, with no host.
- **It belongs to nice_cpu.** A new bit is a change of nice_cpu's link
  and of DEBUG.md, and a nice_cpu release, as the submodule pins only
  tags. V2.3.1 keeps nice_cpu at `V2.3`.

The lock above needs no register at all. A host has the link's own
path to the ROM ([Over the link](#over-the-link)). Two hide bits, one
for each half of the ROM, would be a change of nice_cpu's link for
later, if ever ([Not included](#not-included)).

## Why not the first fetch

The first design set the lock at the first instruction fetch from
BASIC's half, the monitor's `JMP BAS_COLD`. That does not hold on the
pipelined core:

- **Fetches run ahead.** nice_cpu's ISA.md §8.2 lets a core fetch for
  instructions that never run, and the pipelined core does. Its DECODE
  redirects FETCH for a `JMP label` as soon as it decodes it, also
  behind a jump that WRITE has yet to take, such as a `RET`
  (MICROARCH.md §5.4).
- **Measured.** In `tb_hello`, a `JMP 0x4000` right after a `RET`
  never runs, and `niceemu` halts after 5 steps. The core still
  fetches `0x4000`–`0x4006`.
- **Today's ROM would be safe by its layout alone.** Its only jumps
  into BASIC's half are `JMP BAS_COLD` and `JMP BAS_WARM`, each
  reached only past a `CALL`, whose jump DECODE takes itself, so no
  wrong path runs into them. A loader with a `JMP BAS_COLD` a few instructions after a
  `RET`, a taken conditional jump, or the back edge of the copy's loop
  would set the lock early. Then the card's BASIC is skipped, or the
  copy's later writes are dropped, and the ROM is left with a mix of
  two images.
- **`niceemu` cannot show it**, as it fetches only what runs. Every
  test would pass, and the board alone would fail.

Data accesses are exact, in order, and never speculative (ISA.md
§8.2), so a store is a safe trigger. It needs no register either, and
the monitor's write of a word back to itself changes nothing in
`niceemu`, where the ROM is RAM.

## The image

- **The files** are those of the card's folder (`NICE`, or `FOLDER`
  of the build) whose name, as `DIR` shows it, matches `BASIC*.ROM` in
  either case, such as `BASIC-V2.3.2.ROM`. The name is for people; the
  loader goes by the version in the header
  ([Choosing the file](#choosing-the-file)). So a new version is copied
  beside the old ones, which need not be deleted.
- Each is a `.bin` file as every other (nice_cpu's ISA.md §10.4): one
  line of an address and a word for each word. Its addresses must be in
  `0x4000`–`0x7FFF`, and rise from line to line, so the header comes
  first.
- The extension is not `.BIN`, so that BASIC's `LOAD` does not take
  the file for a program.
- **The header** follows the two vectors. The bitstream's BASIC has it
  too:

| Address | What it holds |
|---|---|
| `0x4000` | `JMP` to the cold start, two words, as now |
| `0x4002` | `JMP` to the warm start, two words, as now |
| `0x4004` | The magic word, `NBAS` in packed ASCII |
| `0x4005` | The interface: in bits 31..16 the version of the layout of the monitor's RAM, and in bits 15..0 the number of entries of the dispatch table that the image calls |
| `0x4006` | The image's length in words, from `0x4000`, at most 16384 |
| `0x4007` | The checksum: the 32-bit sum of the image's words, starting from `0x4000`, over the length at `0x4006`, this one included, is 0 |
| `0x4008` | The address of the image's version, a packed text, as the banner shows it |
| `0x4009` | The version as a number, which orders the files: the tag's major, minor, and patch numbers in bits 31..24, 23..16, and 15..8, and the commits since the tag, as `git describe` counts them, in bits 7..0, at most 255. `V2.3.2` is `0x02030200`, and the tests' `V9.9` is `0x09090000` |
| `0x400A` | The flags: bit 0 is "keep", and the others are 0 |
| `0x400B` | The words of BASIC's own RAM, below the monitor's at `0xFFFFF000`: 2048 now |

- **The interface.** The monitor takes an image whose RAM layout version
  is its own, and whose number of dispatch entries is at most its own,
  41 in `V2.3.1`. A new entry of the monitor then keeps older images
  running. The layout is that of the monitor's own RAM, from
  `0xFFFFF000`, alone, and a change of it refuses the older images.
- **BASIC's RAM.** Its size is the image's own, the word at `0x400B`.
  The monitor has it in three places today: SP at `mon_reset` and at
  `mon_exit`, and the end of a program's RAM in `bin_line`. It then
  takes them from the header of the BASIC that is in the ROM, or 2048
  where the ROM has no BASIC with the magic word. So a later BASIC
  grows its RAM, as [BASIC.md](BASIC.md#the-memory) plans, with no new
  bitstream, and a program under the monitor then has that much less.
- **"keep".** A BASIC in the ROM with this flag is not replaced: the
  monitor does not look at the cards
  ([The cold start](#the-cold-start)). It is for a monitor that runs
  from RAM. In a file on a card it does not stop the load.
- **The checksum** catches a file cut short, and a file of another
  image. A word that is not in the file counts as 0, as the staging
  area is zeroed first.
- `make rom` writes `basic/build/basic.rom`, and a release names it
  `BASIC-V2.3.2.ROM` after its tag, with the header filled in
  after assembly, as `romsize.py` reads the labels now.

### Choosing the file

- The loader lists the folder of slot 0, then of slot 1, and reads the
  header of each `BASIC*.ROM`: its first twelve lines, up to `0x400B`.
- A file whose header has a wrong magic word, an interface that does
  not fit, a size of BASIC's RAM out of its range, or an address out
  of place is passed over, with its reason on one line.
- Of the rest, it takes the one with the highest version. Of two with
  the same version, it takes the first: slot 0 before slot 1, and in a
  folder the one that comes first, as `DIR` lists it.
- If that file fails the whole check, it tries the next highest, and
  so on. So a new file that is broken still leaves an older one
  running, and the bitstream's BASIC runs only when no file passes.
- A version below that of the BASIC in the ROM is taken all the same,
  with a notice. The user copied it there, and may want an older BASIC
  back, but after a new core an old file on the card is easily
  forgotten.

## The cold start

`mon_reset` does what it does now, then this:

1. **Is the ROM still open?** The monitor writes the complement of the
   last word, `0x7FFF`, reads it back, and writes the word again. If
   the write did not stick, BASIC has run since the configuration, and
   the monitor goes to step 8. So `SYS 0`, and a start by the link, do
   not read the card again.
2. **Is the BASIC in the ROM to be kept?** If its header has the magic
   word and "keep", the monitor goes to step 8.
3. Choose a file ([Choosing the file](#choosing-the-file)). With none,
   the bitstream's BASIC runs, from step 8.
4. **The read stages** the file in the program's RAM, the staging
   area, 16384 words from `0x8000`, which it zeroes first. Each line's
   address must be in `0x4000`–`0x7FFF`, and above the line's before,
   and its word goes to that address plus `0x4000`. So the ROM is not
   touched yet.
5. **The check** reads the staged header: the magic word, the
   interface, the length, and the sum over the length must fit. If the
   file is not valid, print why on one line, such as
   `BASIC-V2.3.2.ROM on card 0: bad checksum`, zero the staging area,
   and try the next file.
6. **The copy** writes the staged words over the length, and zeroes
   the rest of `0x4000`–`0x7FFF` of the ROM. A loop from the RAM to
   the ROM cannot fail as a card can, so the ROM always ends up with a
   whole, checked BASIC.
7. Zero the staging area. Before the copy, the loader prints
   `BASIC-V2.3.2.ROM from card 0`, or, when its version is below that
   of the BASIC that the ROM had,
   `BASIC-V2.3.2.ROM from card 0, older than the core's V2.4`, as the
   copy overwrites the old BASIC's text.
8. **The lock and the jump.** The monitor writes a word of its own
   half back to itself, which sets the lock, and goes to `BAS_COLD`.
   Every path ends here, and it is the monitor's one jump to
   `BAS_COLD`.

- **The staging area** is the program's RAM, which is all zeros at the
  first cold start after a configuration, the only one that loads.
  Step 7 leaves it so, as the configuration did, and as `niceemu`
  starts. A program that a host loads at `0x8000` before that first
  cold start would be lost, but the boards boot at configuration on
  their own, before a host can load one. The RAM is at least 64K
  words, on the Nexys4DDR, so the area always fits below the stack.
- **A monitor that runs from RAM** finds the ROM open at every cold
  start: in `niceemu`, and where a tool loads a ROM image at 0 with
  the ROM hidden, as `load.py --monitor --rom` and `make hwtest` do.
  There the loader would replace the BASIC that was just loaded with
  the card's, and zero the program that the host put at `0x8000`.
  "keep" is for them: the tests' image has it, and the tools set it in
  an image that they load ([The tools](#the-tools)). A release's image
  has it clear, so `niceemu` with a card loads as the board does.
- **A file that hangs.** A `BASIC*.ROM` that passes the check and
  hangs at its cold start leaves the board with no BASIC while its
  card is in. The card is taken out, and the board switched on again:
  the bitstream's BASIC runs, the card goes back in, and `DELETE`
  removes the file. A host can load another image over the link too.
  There is no escape key ([Not included](#not-included)).
- **The banner** is BASIC's, with its own version and the monitor's,
  such as `NiceMon V2.3.1, BASIC V2.3.2`. The monitor's is a text of
  the monitor's image, which a new entry gives
  ([The monitor for later BASICs](#the-monitor-for-later-basics)).
- **A new `BASIC*.ROM`** takes effect at the next configuration, a power
  cycle, as the ROM is locked until then.
- **The time.** A cold start reads no card today. A file of 5067
  words is about 91 KB of text, 180 sectors, read once. The card
  reads 2 to 3 MB/s at 25 MHz. `LOAD` takes about 1400 instructions
  for a line, with its display
  ([basic/README.md](../basic/README.md#loading-without-a-host)), so
  the load may take tenths of a second after the card's Init. The
  Init can take hundreds of milliseconds, and waits up to a second
  for a card that stays idle (`C_OP_COND_MS` of `src/sd/sd_spi.vhd`),
  and on the R3, whose slot 1 has no card detect, an empty slot costs
  its timeout. This is to be measured. It happens once for each
  configuration.
- **The monitor's words.** The loader shares `bin_line`'s parse of a
  line with a range of its own, and FAT32's open and read. The guess is
  300 to 450 words, of the 6794 free below `0x4000`. The new entries
  are on routines that there are.

## The monitor for later BASICs

A release of BASIC alone cannot change the monitor. So the monitor of
`V2.3.1` has what BASIC's stages 2 and 3 need of it, as the check of
2026-11-18 found it
([BASIC.md](BASIC.md#what-the-stages-need-of-the-monitor)). The
dispatch table is 1.7, with four entries more, 41 in all:

| Entry | What it gives | For |
|---|---|---|
| `mon_build` | The monitor's version text | The banner and `VER`, with BASIC's own version |
| `con_key` | A byte of the console, with a wait or without, and the network kept going meanwhile | BASIC's line, `GET`, and the break poll |
| `scr_back` | The scrollback: some rows back or forward, or the screen again | BASIC's line |
| `fs_complete` | TAB's completion of a file's name, on a line of the caller's | BASIC's line |

- **BASIC's line.** From stage 3 on, BASIC keeps the keys that its
  break poll took in a ring, and reads them first. `con_getline`
  reads the console itself, so BASIC reads its line with a routine of
  its own, on the last three entries, which are on the routines that
  `con_getline` has: `getline_wait`, `hist_up`, `hist_down`,
  `hist_leave`, and `complete`. `con_getline` stays for the programs.
- **The size of BASIC's RAM** is the image's, in its header
  ([The image](#the-image)).
- Stage 2 needs nothing new.

## Over the link

A host can put a BASIC into the ROM over the link, on the UART or over
Ethernet, also after the lock: it holds the core, writes the image to
`0x4000`–`0x7FFF` with the ROM shown, and starts the core. The monitor
finds the ROM locked, and runs that image.

- This is the network load that #153 asks for, with the tools that
  are there now. A load by the board itself, with BOOTP and TFTP, is
  left out ([Not included](#not-included)).
- `load.py --basic` sets "keep" in the image that it writes, so the
  monitor runs it also where the ROM is still open.
- The tools hide the ROM before every other load, so a program loaded
  at 0 never reaches the ROM.
- The link's clear zeroes the RAM, the screen, and the fonts, not the
  ROM, as now.

## The emulator and the tests

- `niceemu` has no ROM, so `0x4000`–`0x7FFF` is RAM there, and a write
  always goes through. The monitor's probe of step 1 finds it open
  every time, and the loader works there as it does on the board. The
  lock's write puts a word back that is there. A
  program's write to the ROM's range differs from the board's already,
  as the ROM is in front of the RAM there ([EMULATOR.md](EMULATOR.md)).
- So `SYS 0` loads the card's BASIC again in `niceemu`, and zeroes the
  staging area, where the board finds the ROM locked. That is a new
  row of EMULATOR.md.
- The tests keep `cat rom_test.bin prog.bin`. The tests' image has
  "keep", so no test of today reads a card at its start, and their
  outputs do not change but for the banner.
- **New tests** in `make -C monitor test`, with an image without
  "keep": a card with a valid
  `BASIC*.ROM`, a test image whose banner differs; one with a bad
  checksum, a bad magic word, a newer interface, an address outside the
  range, addresses that fall, and a file cut short, after each of which
  the bitstream's BASIC runs; three versions on one card, the newest
  taken; the newest broken, and the next taken; the same version on
  both slots; slot 1 only; a file older than the ROM's BASIC, with its
  notice; a file with a larger RAM of BASIC's, with `mon_exit`'s SP
  and `bin_line`'s end after it; and `SYS 0` after a load. With
  "keep", a valid file on the card is not taken. The new entries have
  a test of their own, as those of table 1.6 have.
- **In the RTL**: `tb_nicemon` writes the ROM's halves before and after
  a write by the core to the monitor's half, and checks that a fetch
  from BASIC's half does not lock, the lock across a start and a
  clear, the link's writes, and a read right behind a write.
  `formal/mem.sby` gets the rules of the ROM's writes.
- **A whole load in the RTL.** A testbench with the real ROM and the
  model of a card (`sim/sd_card_model.vhd`) loads a `BASIC*.ROM` from
  a FAT32 image, and checks the banner, and that the ROM is locked
  after the load and not before. `niceemu` sees neither the lock nor a
  fetch that runs ahead.

## The tools

- `make rom` builds `basic/build/basic.rom` beside `build/rom.bin`.
- `load.py --basic FILE` loads an image over the link into the ROM,
  with "keep" set, and starts the core. `make load` passes it on.
- `load.py --monitor --rom FILE`, `run.py`, and `make hwtest` set
  "keep" in a ROM image that they load into the RAM. So the card's
  BASIC does not replace it, the program at `0x8000` stays, and
  `make hwtest` tests the build's BASIC, with the waits that it has.
- `load.py --monitor` has the end of a program's RAM from
  `MONITOR_WORDS` now, the monitor's RAM and BASIC's, and
  `make hwtest` shares it. It takes BASIC's from the header instead,
  of the file of `--rom`, or over the link.
- `make hwtest` checks that the ROM's BASIC half takes a link's write,
  and that the monitor's half does not, then loads a test image with a
  banner of its own, and checks the banner. With a `BASIC*.ROM` on a
  card of the board, it checks the banner after the configuration
  against the file, and without one that is NOT COVERED. It still
  writes nothing to a card. At its end it loads the BASIC it found, so
  that the board is left as it was.
- `sdcard.py put` copies `BASIC-V2.3.2.ROM` to a card, as it copies
  any file.
- The README tells the users how to install a new BASIC on a card, and
  what to do with one that hangs.

## Releases

Each release ships `BASIC-V2.3.2.ROM`, named after its tag, as an
asset, beside the bitstreams, the core files, and `demo.bin`. `V2.3.1`
is the first, with `BASIC-V2.3.1.ROM`, the BASIC of its bitstreams, so
that the card's path is tested on a board before the release. Of the
ways the names could follow, when a release may change BASIC alone, A
is decided ([Decisions](#decisions)):

- **A. One series of tags, as now (decided).** A tag still names
  the nice_cpu tag it pins. BASIC has the version of the tag it was
  built with, and the banner shows both. A release that changes only
  BASIC is a point release, such as `V2.3.2`. It ships `BASIC-V2.3.2.ROM`,
  and the bitstreams and core files of the release before, unchanged,
  which its notes name. `release.py` gets a way to stage such a
  release without the three Vivado builds, with `V2.3.2`, the first
  of them. The interface in the header,
  not the name, says whether a BASIC fits a monitor.
- **B. Two version numbers**, such as `NiceMonMEGA65-V2.3.1-V1.0`, as
  #153 suggests. This is clearer about which part changed, but every
  name of a file, a tag, and a note doubles, and the tags no longer
  follow nice_cpu's alone.
- **C. A repository of its own for BASIC.** Against it: BASIC shares
  `common.nasm`, `monlib.nasm`, and `mon.nasm` with the monitor, and its
  tests need the monitor. The monitor's tests of FAT32 type BASIC's
  statements. A split would need those files in a form both
  repositories pin.

## Not included

- **The monitor from a card.** #153 calls it nice to have, with no use
  yet. It needs a loader in the RTL, or a small loader in the ROM that
  copies itself to the RAM first. The header and the checks here would
  serve it too.
- **A hide bit for each half of the ROM.** It would let a host hide
  BASIC's half alone, or the monitor's. It is a change of the control
  register, so of nice_cpu's link, DEBUG.md, and a nice_cpu release.
- **BOOTP and TFTP at the start.** TFTP is in BASIC now, not in the
  monitor (`basic/basic_net.nasm`), so the monitor would need a client
  of its own. The link covers loads from a host until then.
- **An escape key.** The first design had one: a key that waits in the
  input FIFO at the cold start skips the cards. In `niceemu` a test's
  input waits from the first step, so every test that types would skip
  the loader, and on the boards it is a race with the keyboard's scan.
  Taking the card out does the same, with no code
  ([The cold start](#the-cold-start)).
- **The word of the rows that go on**, which BASIC's screen editor
  needs of `mon_putc` ([BASIC.md](BASIC.md#the-later-stages)). The
  editor comes in a release with a bitstream.

## Decisions

Made on 2026-11-18. A review of the first design against the code,
the same day, replaced the second and the fourth, and added those
from the fifth on.

1. **The names of the releases**: one series of tags, A of
   [Releases](#releases).
2. **What locks the ROM**: a write by the core to the monitor's half,
   which the monitor makes right before BASIC. It needs no register
   and no change of nice_cpu. The first design had the first fetch
   from BASIC's half
   ([Why not the first fetch](#why-not-the-first-fetch)). The other
   way was a bit that the core sets, at an address of its own, of
   nice_cpu's reserved `0xFFFFFF03`–`0F`.
3. **The file's name**: any `BASIC*.ROM`, of which the loader takes the
   one with the highest version in its header
   ([Choosing the file](#choosing-the-file)). Its extension keeps it
   from `LOAD`.
4. **No escape key.** The first design had a key that skips the cards
   ([Not included](#not-included)). The card taken out is the escape.
5. **"keep"**, a flag of the header, for a monitor that runs from RAM
   ([The cold start](#the-cold-start)).
6. **A file older than the ROM's BASIC** is taken, with a notice.
7. **The banner** is BASIC's, with the monitor's version from a new
   entry, 37.
8. **What BASIC's stage 3 needs of the monitor** is in `V2.3.1`: three
   entries for a line of BASIC's own, and the size of BASIC's RAM in
   the header
   ([The monitor for later BASICs](#the-monitor-for-later-basics)).
9. **The milestone** is `V2.3.1`, which needs no change of nice_cpu.
   It has this issue, with the eighth decision, and no more. The other
   issues that it had, BASIC's stages 2 and 3 among them, went to
   `V2.3.2`.

## Open questions

No question of the design is open. Stage 3 settled two details:

1. **The names** of the entries 37 to 40 are `mon_build`, `con_key`,
   `scr_back`, and `fs_complete`.
2. **The size of BASIC's RAM** that the loader takes is 1024 to 8192
   words (`BAS_RAM_MIN` and `BAS_RAM_MAX` of `monitor/common.nasm`).

One is open:

3. **The time of the cold start** with a card, and with an empty slot
   on the R3, which is to be measured.

## Stages

1. **The header.** BASIC's image gets the header, with the flags and
   the size of its RAM, the version, and the checksum, and
   `make rom` writes `basic/build/basic.rom`. The tests' image has
   "keep". Nothing else changes. Written: `tools/basic_rom.py` fills
   in the header after assembly, and checks an image.
2. **The RTL.** The ROM's write port, registered, the lock by a store,
   and the new cases of `mem.vhd`, with its input for the link's
   requests, `tb_nicemon`, `formal/mem.sby`, `synth/rompatch.tcl`,
   `doc/SYSTEM.md`, `doc/DEBUG_LINK.md`, `doc/EMULATOR.md`, and a new
   bitstream with its timing. Written: `mem.vhd`'s `rom_wr_o` tells
   `nicemon` of a write to the ROM, which then takes no request in the
   next cycle, whose port B the write has. The R6 met timing with the
   default flow, +0.146 ns, with 244 RAMB36 as before; the ROM's block
   RAMs are named `mem_even_reg_*` and `mem_odd_reg_*` now, which
   `rompatch.tcl` finds, and `make r6 ROMPATCH=` works.
3. **The monitor.** The loader of [The cold start](#the-cold-start),
   with the lock's write; SP and `bin_line`'s end from the header;
   and table 1.7, with the entries 37 to 40, their stubs in `mon.nasm`
   and `mon.h`, and the banner. The tests in `niceemu`, and the whole
   load in the RTL. Written but for the whole load in the RTL:
   `monitor/monitor_basic.nasm` is the loader, 777 words, which keeps
   no list of the files and lists the folders again for each choice.
   Its reasons are `not a BASIC image`, `for another monitor`,
   `bad header`, `bad address`, `bad line`, `bad checksum`, and
   `card error`. `test/basload.py` and `test/hal17.nasm` are its tests
   in `niceemu`.
4. **The tools.** `load.py --basic`, "keep" in the images that the
   tools load, `make hwtest`, the README, and `basic/README.md`.
5. **The release.** `V2.3.1`, with `BASIC-V2.3.1.ROM` as an asset. A
   point release of BASIC alone in `release.py` and `doc/RELEASE.md`
   comes with `V2.3.2`.
