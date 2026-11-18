# BASIC's image outside the bitstream

The design of issue
[#153](https://github.com/MJoergen/NiceMonMEGA65/issues/153): at the
start, the monitor replaces BASIC's half of the ROM with a file from
the SD card. **This is a draft. Nothing of it is written. The
decisions of 2026-11-18 are in [Decisions](#decisions), and one
question is open.**

- [Goals](#goals)
- [What there is now](#what-there-is-now)
- [The proposal in short](#the-proposal-in-short)
- [The ROM](#the-rom)
- [Why not the control register](#why-not-the-control-register)
- [The image](#the-image)
- [The cold start](#the-cold-start)
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
  9590 words, and BASIC's at `BASIC_BASE`, `0x4000`, 5067 words
  ([monitor/INTERNALS.md](../monitor/INTERNALS.md#the-roms-words)).
- The monitor knows only BASIC's two vectors, `BAS_COLD` at `0x4000`
  and `BAS_WARM` at `0x4002`. BASIC calls the monitor only through the
  entries of the dispatch table, as a program does. Both share the
  layout of the RAM at the top, `STACK`, `BASIC_WORDS`, and `MON_RAM`
  of `monitor/common.nasm`.
- The cold start, `mon_reset`, ends with `JMP BAS_COLD`. `SYS 0` runs
  it too.
- Bit 3 of the link's control register hides the whole ROM, so the RAM
  is at 0. The RAM under the ROM keeps its words while the ROM is
  shown.

## The proposal in short

- BASIC's half of the ROM, `0x4000`–`0x7FFF`, takes the core's writes
  from the FPGA's configuration until BASIC first runs. Then it is
  locked until the FPGA is configured again.
- At that first cold start, the monitor looks for the files
  `BASIC*.ROM` in the folder `NICE` of the cards, and takes the one
  whose header has the highest version. It reads the file once, into
  the program's RAM from `0x8000`, checks it there, and copies it into
  the ROM.
- An invalid file never touches the ROM, and the bitstream's BASIC
  runs.
- To get the bitstream's BASIC back, the FPGA is configured again: a
  power cycle, or a new core from MEGAFLASH.
- No new register, and no change of the control register.

## The ROM

- **A write port.** `src/rom.vhd` gets a write on port B, the data
  bus's port, for the bank of BASIC's half. The block RAM has it
  already, as a true dual-port RAM: no block RAM more. Its contents at
  configuration still come from `build/rom.bin`, so `make r6
  ROMPATCH=` patches them as now.
- **The lock.** A flag, 0 at configuration, that nothing resets: not
  the system's reset, not a start of the core, not a clear. The first
  instruction fetch from `0x4000`–`0x7FFF` by the core sets it. That is
  `JMP BAS_COLD`, after the load. A fetch through a byte window that
  aliases the range sets it too.
- **The core's writes.** While the flag is 0 and the ROM is shown, a
  write by the core to `0x4000`–`0x7FFF` goes to the ROM. Once it is 1,
  the write is dropped, as now. A write to the monitor's half,
  `0x0000`–`0x3FFF`, is always dropped.
- **The link's writes** to `0x4000`–`0x7FFF` with the ROM shown go to
  the ROM, whatever the flag says ([Over the link](#over-the-link)).
  With the ROM hidden, they go to the RAM, as now, so the tools are
  unchanged: they hide the ROM before they load.
- **The RAM under the ROM** is untouched, and reached as now, with the
  ROM hidden.
- **In `src/mem.vhd`**, a write to the ROM's range today is dropped.
  It then reaches the ROM's port B, unless it is to the monitor's half,
  or by the core with the flag set. The path from the RAM has the
  least slack, so the timing is to be checked after the change.

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
| `0x4005` | The interface: in bits 31..16 the version of the RAM's layout at the top, and in bits 15..0 the number of entries of the dispatch table that the image calls |
| `0x4006` | The image's length in words, from `0x4000`, at most 16384 |
| `0x4007` | The checksum: the 32-bit sum of the image's words, starting from `0x4000`, over the length at `0x4006`, this one included, is 0 |
| `0x4008` | The address of the image's version, a packed text, as the banner shows it |
| `0x4009` | The version as a number, which orders the files: the tag's major, minor, and patch numbers in bits 31..24, 23..16, and 15..8, and the commits since the tag, as `git describe` counts them, in bits 7..0, at most 255. `V2.3.2` is `0x02030200`, and the tests' `V9.9` is `0x09090000` |

- **The interface.** The monitor takes an image whose RAM layout version
  is its own, and whose number of dispatch entries is at most its own, 37 now.
  A new entry of the monitor then keeps older images running. A change
  of the layout at the top of the RAM refuses them.
- **The checksum** catches a file cut short, and a file of another
  image. A word that is not in the file counts as 0, as the staging
  area is zeroed first.
- `make rom` writes `basic/build/basic.rom`, and a release names it
  `BASIC-V2.3.2.ROM` after its tag, with the header filled in
  after assembly, as `romsize.py` reads the labels now.

### Choosing the file

- The loader lists the folder of slot 0, then of slot 1, and reads the
  header of each `BASIC*.ROM`: its first ten lines, up to `0x4009`.
- A file whose header has a wrong magic word, an interface that does
  not fit, or an address out of place is passed over, with its reason
  on one line.
- Of the rest, it takes the one with the highest version. Of two with
  the same version, it takes the first: slot 0 before slot 1, and in a
  folder the one that comes first, as `DIR` lists it.
- If that file fails the whole check, it tries the next highest, and
  so on. So a new file that is broken still leaves an older one
  running, and the bitstream's BASIC runs only when no file passes.
- A version below the bitstream's BASIC is taken all the same. The
  user copied it there, and may want an older BASIC back.

## The cold start

`mon_reset` does what it does now, then this, before `JMP BAS_COLD`:

1. **Is the ROM still open?** The monitor writes the complement of the
   last word, `0x7FFF`, reads it back, and writes the word again. If
   the write did not stick, BASIC has run since the configuration, and
   the monitor goes straight to `JMP BAS_COLD`. So `SYS 0`, and a start
   by the link, do not read the card again.
2. Unless a key waits in the input FIFO ([Decisions](#decisions)),
   choose a file ([Choosing the file](#choosing-the-file)). With none,
   the bitstream's BASIC runs.
3. **The read stages** the file in the program's RAM, the staging
   area, 16384 words from `0x8000`, which it zeroes first. Each line's
   address must be in `0x4000`–`0x7FFF`, and above the line's before,
   and its word goes to that address plus `0x4000`. So the ROM is not
   touched yet.
4. **The check** reads the staged header: the magic word, the
   interface, the length, and the sum over the length must fit. If the
   file is not valid, print why on one line, such as
   `BASIC-V2.3.2.ROM on card 0: bad checksum`, zero the staging area,
   and try the next file.
5. **The copy** writes the staged words over the length, and zeroes
   the rest of `0x4000`–`0x7FFF` of the ROM. A loop from the RAM to
   the ROM cannot fail as a card can, so the ROM always ends up with a
   whole, checked BASIC.
6. Zero the staging area, print `BASIC-V2.3.2.ROM from card 0`, and
   the image runs.

- **The staging area** is the program's RAM, which is all zeros at the
  first cold start after a configuration, the only one that loads.
  Step 6 leaves it so, as the configuration did, and as `niceemu`
  starts. A program that a host loads at `0x8000` before that first
  cold start would be lost, but the boards boot at configuration on
  their own, before a host can load one. The RAM is at least 64K
  words, on the Nexys4DDR, so the area always fits below the stack.

- **The banner** shows BASIC's version, from the header, beside the
  monitor's, such as `NiceMon V2.3.1, BASIC V2.3.2`.
- **A new `BASIC*.ROM`** takes effect at the next configuration, a power
  cycle, as the ROM is locked until then.
- **The time.** A file of 5067 words is about 91 KB of text, 180
  sectors, read once. The card reads 2 to 3 MB/s at 25 MHz, and the
  parse of a line is some hundred instructions, so the load should take
  a few tens of milliseconds after the card's Init. The Init can take
  hundreds of milliseconds, and on the R3, whose slot 1 has no card
  detect, an empty slot costs its timeout. This is to be measured. It
  happens once for each configuration.
- **The monitor's words.** The loader shares `bin_line`'s parse of a
  line with a range of its own, and FAT32's open and read. The guess is
  300 to 450 words, of the 6794 free below `0x4000`.

## Over the link

A host can put a BASIC into the ROM over the link, on the UART or over
Ethernet, also after the lock: it holds the core, writes the image to
`0x4000`–`0x7FFF` with the ROM shown, and starts the core. The monitor
finds the ROM locked, and runs that image.

- This is the network load that #153 asks for, with the tools that
  are there now. A load by the board itself, with BOOTP and TFTP, is
  left out ([Not included](#not-included)).
- The tools hide the ROM before every load, so a program loaded at 0
  never reaches the ROM.
- The link's clear zeroes the RAM, the screen, and the fonts, not the
  ROM, as now.

## The emulator and the tests

- `niceemu` has no ROM, so `0x4000`–`0x7FFF` is RAM there, and a write
  always goes through. The monitor's probe of step 1 finds it open
  every time, and the loader works there as it does on the board. A
  program's write to the ROM's range differs from the board's already,
  as the ROM is in front of the RAM there ([EMULATOR.md](EMULATOR.md)).
- The tests keep `cat rom_test.bin prog.bin`. With no card, or no file,
  the bitstream's BASIC runs as now, so their outputs do not change but
  for the banner.
- **New tests** in `make -C monitor test`: a card with a valid
  `BASIC*.ROM`, a test image whose banner differs; one with a bad
  checksum, a bad magic word, a newer interface, an address outside the
  range, addresses that fall, and a file cut short, after each of which
  the bitstream's BASIC runs; three versions on one card, the newest
  taken; the newest broken, and the next taken; the same version on
  both slots; slot 1 only; and `SYS 0` after a load.
- **In the RTL**: `tb_nicemon` writes the ROM's halves before and after
  a fetch from `0x4000`, and checks the lock across a start and a
  clear, and the link's write. `formal/mem.sby` gets the rules of the
  ROM's writes.

## The tools

- `make rom` builds `basic/build/basic.rom` beside `build/rom.bin`.
- `load.py --basic FILE` loads an image over the link into the ROM, and
  starts the core. `make load` passes it on.
- `make hwtest` checks that the ROM's BASIC half takes a link's write,
  and that the monitor's half does not, then loads a test image with a
  banner of its own, and checks the banner. It still writes nothing to
  a card. At its end it loads the BASIC it found, so that the board is
  left as it was.
- `sdcard.py put` copies `BASIC-V2.3.2.ROM` to a card, as it copies
  any file.
- The README tells the users how to install a new BASIC on a card.

## Releases

Each release ships `BASIC-V2.3.2.ROM`, named after its tag, as an
asset, beside the bitstreams, the core files, and `demo.bin`. Of the
ways the names could follow, when a release may change BASIC alone, A
is decided ([Decisions](#decisions)):

- **A. One series of tags, as now (decided).** A tag still names
  the nice_cpu tag it pins. BASIC has the version of the tag it was
  built with, and the banner shows both. A release that changes only
  BASIC is a point release, such as `V2.3.2`. It ships `BASIC-V2.3.2.ROM`,
  and the bitstreams and core files of the release before, unchanged,
  which its notes name. `release.py` gets a way to stage such a
  release without the three Vivado builds. The interface in the header,
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

## Decisions

Made on 2026-11-18:

1. **The names of the releases**: one series of tags, A of
   [Releases](#releases).
2. **What locks the ROM**: the first fetch from BASIC's half, which
   needs no register and no change of nice_cpu. The other way was a bit
   that the core sets, at an address of its own, of nice_cpu's
   reserved `0xFFFFFF03`–`0F`.
3. **The file's name**: any `BASIC*.ROM`, of which the loader takes the
   one with the highest version in its header
   ([Choosing the file](#choosing-the-file)). Its extension keeps it
   from `LOAD`.
4. **An escape**: a key that waits in the input FIFO at the cold start,
   such as one held down at power-on, skips the cards. A `BASIC*.ROM`
   that hangs at its cold start would otherwise leave the board with no
   BASIC until the card is changed. A host can always load another
   image over the link too.

## Open questions

1. **The milestone.** This is a feature, more than a point release:
   V2.4 rather than V2.3.1. It needs no change of nice_cpu, so it could
   stay in V2.3.x.

## Stages

1. **The header.** BASIC's image gets the header, the version, and the checksum, and
   `make rom` writes `basic/build/basic.rom`. Nothing else changes.
2. **The RTL.** The ROM's write port, the lock, and the new cases of
   `mem.vhd`, with `tb_nicemon`, `formal/mem.sby`, `doc/SYSTEM.md`,
   `doc/DEBUG_LINK.md`, `doc/EMULATOR.md`, and a new bitstream with its
   timing.
3. **The loader.** The cold start of [The cold start](#the-cold-start),
   the banner, and the escape, with the tests in `niceemu`.
4. **The tools.** `load.py --basic`, `make hwtest`, the README, and
   `basic/README.md`.
5. **The release.** `BASIC-V2.3.2.ROM` as an asset, and a point release of
   BASIC alone in `release.py` and `doc/RELEASE.md`.
