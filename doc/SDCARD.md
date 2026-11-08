# The SD cards: the design

This is the design note for storage on the SD cards. The lower half is
written: the registers and the emulator's images (MJoergen/nice_cpu#107),
the controller in SPI mode (#55), and the boards' slots and `make hwtest`
(#56), in V1.5. The registers are now specified by nice_cpu's
`doc/SYSTEM.md` §5, and the boards' slots by "The SD card slots" in
[SYSTEM.md](SYSTEM.md); where this note differs from them, they are right.
The ROM's sector routines and its `sd` command (#57) are written too, in
V1.7.1, and [monitor/README.md](../monitor/README.md) describes them,
and so is FAT32's reading, with `dir` and `load` (#58), in V1.9, in C,
and its writing, with `save` and `del` (#59), in V1.9.1. BASIC and the
host tools are not written yet. Its end is `SAVE`,
`LOAD`, and `DIR` in the BASIC of #54, and on the way it gives the monitor of #24 a way to load and save programs. The
tracking issue is #62, and its subtasks are listed at the end.

## Contents

- [Goals](#goals)
- [The cards on the boards](#the-cards-on-the-boards)
- [The layers](#the-layers)
- [The registers](#the-registers)
- [The emulator](#the-emulator)
- [The controller in the RTL](#the-controller-in-the-rtl)
- [The file system](#the-file-system)
- [The ROM](#the-rom)
- [BASIC](#basic)
- [Testing](#testing)
- [Not included](#not-included)
- [Open questions](#open-questions)
- [Subtasks](#subtasks)

## Goals

- A program that uses the SD card runs on the board as `niceemu` runs it,
  with an image file in place of the card.
- The board reads and writes the FAT32 cards that MEGA65 users already
  have, and does not damage what is on them.
- The monitor loads a program from the card to `0x8000`, and saves one.
- BASIC saves and loads its programs as text that a PC can read and edit.

## The cards on the boards

| Board | Slot 0 | Slot 1 |
|---|---|---|
| MEGA65 R3 and R6 | The microSD slot at the back | The full-size SD slot underneath, which holds the MEGA65's system files |
| Nexys4DDR | The microSD slot | none |

Every slot has the 4-bit SD bus (CLK, CMD, and DAT0–DAT3) and card detect.
On the R3 there are limits to both, below. The first stage of the
controller uses the bus in SPI mode.
The MEGA65's full-size slot also has write protect. The pins are the same on
the R3 and the R6:

| Signal | Slot 0 (microSD) | Slot 1 (internal SD) |
|---|---|---|
| CLK | G2 | B17 |
| CMD | J2 | B16 |
| DAT0 | H2 | B18 |
| DAT1 | H3 | C18 |
| DAT2 | J1 | C19 |
| DAT3 | K2 | B15 |
| CD | K1 | D17 |
| WP | | C17 |

These come from the schematics, TE0765-03 for the R3 and TE0765-06 for
the R6, and from mega65-core's `mega65r3.xdc`, which names the slots. Slot
0 is the one mega65-core gives priority to, and the one a user takes out and
puts into a PC, so it is the default. Every line has a 12.1 kΩ pull-up, and
card detect is low when a card is in, as M2M reads it. The Nexys4DDR's slot
also has `SD_RESET`, which must be low to power the card; its pins are in
Digilent's master XDC (#56).

Two limits of the R3, which the R6 does not have (#56 has the details):

- **Slot 0 runs in SPI mode, or 1-bit SD mode.** Its DAT2, DAT1, CMD, and
  DAT0 also go to the TCK, TMS, TDO, and TDI of the MAX10 system
  controller, through 0 Ω resistors, for a microSD debug breakout. In 4-bit
  mode DAT2 would clock the MAX10's JTAG port, which could then drive TDO
  onto CMD. In SPI mode and 1-bit mode DAT1 and DAT2 stay high on their
  pull-ups. Revision -04 of the board removed the MAX10 and the resistors,
  so the R6 can run both slots in 4-bit mode, from stage 2 of the
  controller.
- **Slot 1 has no card detect.** The common pin of the tray socket's
  switches is not connected to GND, so CD and WP always read 1. M2M says
  that the R3A fixes it, and revision -04 has the fix. One core file serves
  the R3 and the R3A, so the R3's build ignores CD and WP on slot 1, and a
  missing card shows as a failed Init.

## The layers

1. **The controller in the RTL** does all of the SD protocol: the start-up
   of the card, the bus width, the CRCs, and the timeouts. A program sees a
   512-byte buffer and the commands "read sector N" and "write sector N".
2. **The registers** are specified in nice_cpu's `doc/SYSTEM.md`, as the
   timer and the math unit are, and `niceemu` implements them on an image
   file. So the emulator needs no model of the SD protocol.
3. **The ROM** has the sector routines and FAT32 with a small file API,
   which the monitor's commands use. The file API is in the dispatch
   table; the sector routines are not.
4. **BASIC** calls the file API.

## The registers

Specified in nice_cpu's `doc/SYSTEM.md` §5, from nice_cpu issue
MJoergen/nice_cpu#107 and its review, which is the authoritative text; this
section keeps the design with its reasons. They take 16 of the words that
nice_cpu reserves for I/O.

| Address | Name | A data read returns | A write |
|---|---|---|---|
| `0xFFFFFFA0` | `SD_CSR` | the status below | starts the command in bits 3..0 |
| `0xFFFFFFA1` | `SD_LBA` | the sector number | sets the sector number |
| `0xFFFFFFA2` | `SD_CHUNK` | the chunk, 0 to 15 | sets the chunk to bits 3..0 |
| `0xFFFFFFA3` | `SD_ERROR` | the error of the last command, 0 for none | is ignored |
| `0xFFFFFFA4` | `SD_SELECT` | the selected slot, 0 or 1 | selects the slot in bit 0 |
| `0xFFFFFFA5` | `SD_LAST` | the number of the card's last sector, valid while "ready" is 1 | is ignored |
| `0xFFFFFFA6` | `SD_SLOTS` | the number of slots of the system, 0 to 2 | is ignored |
| `0xFFFFFFA7` | | 0 | is ignored |
| `0xFFFFFFA8`–`0xFFFFFFAF` | `SD_BUF0`–`SD_BUF7` | word 8·c + k of the buffer, where c is `SD_CHUNK` and k is 0 to 7 | writes that word |

The commands, in bits 3..0 of a write to `SD_CSR`:

| Command | Name | What it does |
|---|---|---|
| 0 | Init | Start the card in the selected slot up, read its size, and clear "changed" |
| 1 | Read | Read the sector `SD_LBA` into the buffer |
| 2 | Write | Write the buffer to the sector `SD_LBA` |
| 3–15 | | Ignored |

The status, from a read of `SD_CSR`:

| Bit | Meaning |
|---|---|
| 0 | Busy: a command runs |
| 1 | Error: the last command failed, and `SD_ERROR` says why |
| 2 | Present: a card is in the selected slot |
| 3 | Ready: the card in the selected slot has been started up by Init |
| 4 | Changed: a card has been put into the selected slot since the last Init of it |
| 5 | Write-protected: the card's switch is set |
| 9..8 | The card's type: 0 none, 1 SDSC, 2 SDHC or SDXC |
| others | 0 |

The errors: 1 no card, 2 not ready, 3 timeout, 4 CRC, 5 the card reported an
error, 6 write-protected, 7 sector out of range, and 8 Init failed.

**The buffer.** It is 128 words, and each word holds 4 bytes, little-endian:
byte 4n of the sector is bits 7..0 of word n. A program sees it 8 words at a
time, through `SD_BUF0`–`SD_BUF7`, and `SD_CHUNK` chooses which 8. FAT is
little-endian, so:
- a 32-byte directory entry is exactly one chunk: entry n of a directory
  sector is chunk n, with the file's size in `SD_BUF7`;
- entry i of a sector of the FAT is chunk i / 8, word `SD_BUF0` + i mod 8;
- for code from the wasm translator, a word is one little-endian `i32`
  (WASM.md).

**No side effects on a read.** Reading any of the 16 words changes nothing,
and a write does only what the table says, so the debug link and the on-board
debugger read and write them as the core does, with no rule of their own
(DEBUG.md §3). A host reads a sector with 16 writes of `SD_CHUNK` and 16 `R`
requests of 8 words at `SD_BUF0`, and writes one likewise. The step undo of
DEBUG.md §7.2 needs nothing from the controller, as no read moves anything.

**The rules.**

- A program waits for busy to be 0 before it starts a command, and after
  one. In the emulator a command is done at once, and on a board it takes
  from about a millisecond for a Read to hundreds for an Init, so a program
  that waits runs the same on both.
- While busy is 1, the buffer is not defined, and a write to `SD_CSR`,
  `SD_LBA`, `SD_SELECT`, or `SD_BUF0`–`SD_BUF7` is ignored. `SD_CHUNK` can
  be written at any time. No command changes `SD_CHUNK`.
- Every command ends: the controller has a timeout for each step, so busy
  does not stay 1.
- `SD_LBA` is always a sector number. The controller turns it into a byte
  address for an SDSC card. A Read or Write of a sector after `SD_LAST`
  fails with error 7.
- `SD_LAST` is the last sector's number, not the count, so that a card of 2
  TB, 2³² sectors, fits.
- A change of `SD_SELECT` takes effect at once. The status then shows the
  other slot, and "ready" is 0 until an Init of it, as the slots may share
  one controller.
- `SD_SLOTS` is the number of slots that the system has, fixed when it is
  built, whether or not a card is in them. An empty slot counts. Selecting a
  slot at or above `SD_SLOTS` shows no card, and every command fails with
  error 1.
- A slot whose card detect does not work shows "present" as 1 at all times,
  "write-protected" as 0, and "changed" only after reset. A command on it
  with no card fails with error 3 or 8. nice_cpu's SYSTEM.md §5 would say
  which boards have such a slot.
- The controller runs while the processor is held, paused, or halted, and
  only reset stops it. So a host can read and write the card while the
  processor is paused. A host that does so while a program is paused
  restores what it changed before the program goes on: `SD_CHUNK`, `SD_LBA`,
  `SD_SELECT`, and the buffer, which it can read first, as reads have no
  side effects.
- Reset, which a start of the processor gives the devices (DEBUG.md §6),
  lets a Write that has begun finish, so that no sector on the card is torn,
  and abandons any other command. Then the controller is idle, with slot 0
  selected, `SD_CHUNK` and `SD_LBA` 0, "ready" 0, and "changed" set if a
  card is present. The buffer's contents are not defined. Busy may read 1
  after reset for as long as the Write takes, so a program waits for busy
  before its first command, as before any other.
- An interrupt or NMI routine does not use the card. `SD_CHUNK`, `SD_LBA`,
  `SD_SELECT`, the buffer, and a running command are shared with the program
  it interrupts.

The registers derive from QNICE-FPGA's at `0xFF20`, which QNICE's monitor
and M2M use. Three other designs were rejected:
- A data port whose cursor moves on every access, as QNICE has. A read with
  a side effect needs a rule of its own for the debug link and the on-board
  debugger, and a memory page shown over it would eat the program's buffer.
- A buffer mapped as 128 words. It needs 128 words of I/O space, and a board
  has 64 left at `0xFFFFFFA0`–`0xFFFFFFDF`.
- A DMA engine that copies the sector to memory. It would be a third master
  on the data bus, which the core and the link already share.

## The emulator

`niceemu --sd0 FILE --sd1 FILE` gives a slot an image file. The emulator
refuses to start with an image whose size is not a multiple of 512 bytes.
The emulator always has 2 slots, as the MEGA65 does, so `SD_SLOTS` is 2 with
any images or none, and `--sd1` alone puts a card in slot 1 and leaves slot
0 empty. A card is present when its image is given, its type is SDHC, and it
is write-protected when the file cannot be written. A command is done before
the next instruction, and a Write goes to the file at once. "Changed" is set
at the start, so a program does the Init that it does on a board. The
emulator's window has no way to take a card out.

Without an image, a program sees what it sees on a MEGA65 with both slots
empty: `SD_SLOTS` = 2, "present" 0, and error 1 on every command. The words
`0xFFFFFFA0`–`0xFFFFFFAF` are always the registers, where they were
ordinary memory, as the other reserved words are, before #107.

## The controller in the RTL

The controller comes in two stages. Stage 1 (#55) is SPI mode on every
slot, and is written. Stage 2 (#63) adds 4-bit SD mode, and is optional.

- **SPI first**, because it is proven on these pins: M2M runs QNICE-FPGA's
  `sdcard.vhd` in SPI mode on both slots of the R3 and the R6. Its lines go
  one way each, DAT3 as chip select, CMD as data in, and DAT0 as data out,
  so there is no tri-state, and DAT1 and DAT2 are never driven, as the R3's
  back slot needs. At 25 MHz it gives 2–3 MB/s, enough for BASIC and the
  monitor.
- **SD mode may never replace it on the MEGA65.** A card in SPI mode returns
  to SD mode only after a power cycle, and the MEGA65's cards are always
  powered. The MEGA65's own core and the M2M cores probably use SPI, so a
  MEGA65 that switches to this core from the core menu may hand it cards in
  SPI mode. #63 starts with a test of that on a board, and stage 2 keeps SPI
  as a fall-back if it is so. The Nexys4DDR can cycle its card's power with
  `SD_RESET`.
- The registers and the buffer in block RAM are a module of nice_cpu's
  `hdl/src`, as the review of MJoergen/nice_cpu#107 proposed, apart from
  the protocol engine, behind a small interface (start, read or write, the
  sector, a stream of bytes, done, and an error). nice_cpu's `hdl/sim` gets
  an engine over an image file, so that its tests diff programs that use
  the card against niceemu. `src/sd/sd.vhd` here has the choice of slot and
  the real engines. Stage 1 has an SPI engine, from QNICE's `sdcard.vhd` rewritten to `doc/CODING_STYLE.md`.
  Stage 2 adds an SD-mode engine, from
  [MJoergen/SDCard](https://github.com/MJoergen/SDCard), which reads a
  card's CID and CSD on the MEGA65, and whose write path is not finished
  (5efe006).
- CRCs are on in both modes, with CMD59 in SPI mode, so that error 4 means
  the same in both.
- Generics per slot: the bus width (1 for SPI, and for SD mode on the R3's
  back slot; 4 for SD mode elsewhere), whether card detect and write
  protect are used, and a power pin.
- The card's clock is 400 kHz for the start-up, then 25 MHz, the default
  speed, from the system clock. High speed is not needed.
- The two slots share the controller. The choice of slot is a multiplexer
  in front of the pins, and the slot that is not selected has its clock
  stopped. Card detect and write protect are read for both slots at all
  times.
- The pins are registered with `IOB TRUE` in each board's XDC; in stage 2,
  the output enables of the tri-state CMD and DAT lines too.
- A VHDL model of a card, `sim/sd_card_model.vhd`, answers the commands
  that the controller sends and reads and writes an image file: SPI mode in
  stage 1, and SD mode in both bus widths in stage 2. GHDL in CI cannot use
  the Verilog models in the SDCard repository. The model also gives `make
  cosim` a card.
- `G_FORMAL` checks: busy falls within the timeout, no command starts
  while busy, and a reset during a Write lets it finish.

## The file system

FAT32 only, in the first FAT32 partition of an MBR, or on a card with no
partition table, as `mkfs.fat` makes an image. Every MEGA65's internal card
is FAT32, and so is any SDHC card as it is sold. SDXC cards come with exFAT
and must be formatted. FAT12 and FAT16 are rejected with a message.

- **Names** are 8.3, stored in upper case and matched in either case. Long
  names are skipped when reading, so a file shows its 8.3 name. They are
  never written. Deleting a file also deletes its long-name entries, so
  that `fsck.fat` finds no orphans.
- **Directories**: in FAT32 the root directory is a cluster chain like any
  other, so a current directory is one cluster number, and `cd` costs
  little. NiceMon works in its folder of the root, `NICE` unless the
  monitor's build sets another (#91), as a card may be shared by several
  cores on the MEGA65, each with a root folder of its own. A card without
  it is refused, with no fallback to the root, and the ROM never creates
  it, so writing (#59) happens only in a folder that the user made.
- **Writing**, in an order that a reset at any point leaves no worse than
  lost clusters, which `fsck.fat` frees. A file opened to write gets its
  directory entry at once, empty, with no clusters; an existing file is
  truncated so, the entry first and then its clusters freed. The file's
  clusters are taken as its data reaches them, each marked as the end of
  the chain in both copies of the FAT before the one before it is linked
  to it, and its data written; only the close puts the first cluster and
  the size into the entry. A deletion marks the long-name entries, then
  the entry, then frees the clusters. A new cluster is searched from
  FSInfo's next-free hint, as the FAT of a 32 GB card has about four
  million entries, and a deletion moves the hint back to the clusters it
  freed. Before the first change of the FAT after a mount, FSInfo's free
  count is set to unknown, `0xFFFFFFFF`, which every FAT driver accepts,
  and `fsck.fat` reports as uninitialized. A new file has the date
  2026-01-01, as the boards have no clock of the time of day yet
  (MJoergen/nice_cpu#122). A folder that is full grows by a cluster of
  zeros, written before it is linked, up to 65536 entries.
- **Safety**: the ROM writes only inside the partition, never the MBR or
  the boot sector, and refuses a card whose FAT32 boot sector does not
  check.
- **Caches**: one sector of the FAT and one per open file, in the ROM's
  variables at `0xFFFFF000`. Two files open at once, a read and a write,
  are enough for BASIC and the monitor. "Changed" in the status drops the
  caches and the mount. The FAT's cache and the directory's are
  write-through. A file's sector is written when it is full and at the
  close, so that a program that writes a line at a time, as BASIC's
  `SAVE` does, does not write each sector many times; after the close,
  the card holds what the caches hold, and `sd_read` reads what FAT32
  wrote.
- **Open files**: a file open to write may not be opened again, and a
  file open at all may not be truncated or deleted. A read-only file is
  neither written nor deleted, and no directory is deleted.

## The ROM

The rule of #24 is that the dispatch table gets an entry only when a
program cannot do without it, as for state that the monitor keeps. So:

- **The sector routines** are the ROM's own, with no entries in the table.
  No program needs the card a sector at a time: a program loads and saves
  files, through the file API below. The registers are the same on every
  board and in the emulator, so a program that wants sectors anyway, such
  as a disk editor, drives them itself. It then changes the selected slot,
  the buffer, and the card behind FAT32's back, and calls `fs_mount`
  before it uses the file API again, which drops the caches. Entries for
  the sectors would be kept for ever, by the table's rule, for programs
  that do not need them. The routines are in the C ABI, so that FAT32 can
  be in assembly or C, poll busy, and return 0 or the negative of
  `SD_ERROR`, as the file API does:

| Routine | Arguments | Result |
|---|---|---|
| `sd_init` | R1 the slot | 0, or an error |
| `sd_read` | R1 the sector, R2 a buffer of 128 words | 0, or an error |
| `sd_write` | R1 the sector, R2 a buffer of 128 words | 0, or an error |

  - **The slot** is an argument of `sd_init` only, which selects the slot
    and starts its card up. `sd_read` and `sd_write` use the slot of the
    last `sd_init`. The controller has one "ready" for both slots, so a
    change of slot costs an Init, up to hundreds of milliseconds; a slot
    argument to every call would hide that cost, or would need a rule for
    when to repeat the Init. `fs_mount` calls `sd_init`, which drops the
    mount and the caches.
  - **The buffer** is in RAM, 128 words of 4 bytes each, little-endian, as
    the controller's buffer is: byte 4n of the sector is bits 7..0 of word
    n. The routines copy it through `SD_CHUNK` and `SD_BUF0`–`SD_BUF7`, so
    no sector is left in the controller's buffer, which FAT32 uses too.
    The packing keeps FAT's 32-bit fields whole and costs a quarter of the
    words of one byte per word.
  - The card's size is `SD_LAST`, which FAT32 reads after an `sd_init`;
    it is no result, as a card of 1 TB or more has a last
    sector at or above 2³¹, which would read as an error.
- **FAT32** goes in the ROM, as the monitor's own commands need it. Its
  state, the mounted card and the caches, is state that the monitor keeps,
  so the file API gets entries in the table, from 9 on, in the C ABI, with
  a negative result for an error. The table became 1.1 with the first
  five (#58), and 1.2 with `fs_write` and `fs_delete` (#59):

| Entry | Arguments | Result |
|---|---|---|
| `fs_mount` | R1 the slot | 0, or an error |
| `fs_open` | R1 the name, one character per word up to a 0 word; R2 the mode: 0 read, 1 write (create or truncate), 2 the directory | a handle |
| `fs_read` | R1 the handle, R2 the buffer, R3 the number of bytes | the bytes read, one per word; 0 at the end |
| `fs_write` | R1 the handle, R2 the buffer, R3 the number of bytes, one per word | the bytes written, fewer when the card is full |
| `fs_close` | R1 the handle | 0, or an error |
| `fs_readdir` | R1 the handle of a directory, R2 a buffer of 4 words | 1 with the 8.3 name, the size, and the attributes in the buffer, or 0 at the end |
| `fs_delete` | R1 the name | 0, or an error |

  A file is opened on the slot of the last `fs_mount`. The first `fs_open`
  after reset mounts slot 0, or slot 1 when slot 0 has no card and the
  board has a slot 1.
- **The monitor's commands**: `sd` dumps a sector, for the bring-up;
  `dir`; `load NAME` reads a program in the `.bin` text format, address and
  word pairs, which is what the tools build, so a program goes to the card
  by a copy on a PC; `save NAME ADDR N` writes N words from ADDR in the same
  format; and `del NAME`.

## BASIC

`SAVE "NAME"` writes the program as the text that `LIST` gives, with `.BAS`
added when the name has no extension. `LOAD "NAME"` reads the file as lines
typed in, after a `NEW`. `DIR` lists the directory. The text format is the
one that a host pastes into the console, so a program moves between a PC,
the console, and the card in one format, as #54 wants. There are no device
numbers and no Commodore DOS, as #54 says.

## Testing

- **niceemu**: the monitor's tests run on images made with `mkfs.fat`,
  `sfdisk`, and `mcopy`. After a test writes, `fsck.fat -n` checks the image
  and `mdir` and `mtype` check what is on it. This tests the FAT32 code
  against a reference, and needs no board.
- **GHDL**: `tb_sd` runs `sd.vhd` against the card model, through every
  command and error. `tb_nicemon` reads and writes a sector through the
  core. `make formal` runs the checks in `sd.vhd`.
- **Cosim**: `make cosim` with an image in the card model, so that
  `cosimtest` can run the monitor's commands on the RTL.
- **The board**: `make hwtest` reads sector 0 of each card that is present
  and checks its `55AA`, and reads the FAT32 boot sector. It never writes,
  as the card is the user's. A slot with no card is NOT COVERED.

## Not included

- exFAT, FAT12, FAT16, and writing long names.
- High speed and UHS.
- Interrupts from the controller: the ROM polls.
- C programs' files. The C library calls nothing in the ROM (#24), and a C
  buffer packs 4 bytes in a word. C gets its own `fopen` later, if a
  program needs one.

## Open questions

1. **The language of the FAT32 code**: settled on 2026-11-06, C through
   the wasm translator, in the ROM with `nicewasm --ram`
   (MJoergen/nice_cpu#138, #86). This decides nothing for BASIC, #54's
   second question.
2. **Writes to the MEGA65's internal card**, which holds its system files:
   settled by #91, only in NiceMon's folder, `/NICE`, on either card, as
   reading is.
3. **One controller or two**: settled by #55, one with a multiplexer. Two
   would keep both cards started up, and cost twice the logic for a gain
   only when a program copies between the cards.
4. **Host tools**: a host could read and write the board's card over the
   link while the core is paused, through these registers, and run a FAT
   library on the host, so that a file goes to the card with no PC slot.

## Subtasks

The spec comes first. After it, the RTL and the ROM go in parallel, as the
ROM is developed in niceemu and needs no board.

| Issue | What |
|---|---|
| MJoergen/nice_cpu#107 | Done: the registers in nice_cpu's SYSTEM.md, and `niceemu --sd0/--sd1` |
| #55 | Done in V1.5: the controller in the RTL, stage 1: SPI mode, the card model, `tb_sd`, and the formal checks |
| #63 | In V1.9.1: the controller, stage 2: 4-bit SD mode, optional, after a test whether a card leaves SPI mode |
| #56 | Done in V1.5: the pins on the R3, R6, and Nexys4DDR, and the read-only check in `make hwtest` |
| #57 | Done in V1.7.1: the sector routines in the ROM, and the monitor's `sd` command |
| #58 | Done in V1.9: FAT32 reading, `dir`, and `load` |
| #91 | Done in V1.9: the folder `NICE`, set at build time |
| #59 | Done in V1.9.1: FAT32 writing, `save`, and `del` |
| #60 | BASIC's `SAVE`, `LOAD`, and `DIR` |
| #61 | In V1.9.1: host tools for files on the board's card, over the link |
