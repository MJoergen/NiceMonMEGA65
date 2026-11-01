# The SD cards: a proposed design

This is the design note for storage on the SD cards. Nothing of it is
written yet. Its end is `SAVE`, `LOAD`, and `DIR` in the BASIC of #54, and
on the way it gives the monitor of #24 a way to load and save programs. The
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

These come from M2M's `MEGA65-R6.xdc` and mega65-core's `mega65r3.xdc`,
which names the slots. Slot 0 is the one mega65-core gives priority to, and
the one a user takes out and puts into a PC, so it is the default. The
Nexys4DDR's slot also has `SD_RESET`, which must be low to power the card;
its pins are in Digilent's master XDC. The polarity of card detect on each
board is to be checked on the board.

## The layers

1. **The controller in the RTL** does all of the SD protocol: the start-up
   of the card, the bus width, the CRCs, and the timeouts. A program sees a
   512-byte buffer and the commands "read sector N" and "write sector N".
2. **The registers** are specified in nice_cpu's `doc/SYSTEM.md`, as the
   timer and the math unit are, and `niceemu` implements them on an image
   file. So the emulator needs no model of the SD protocol.
3. **The ROM** has the sector routines in `monlib.nasm`, and FAT32 with a
   small file API in the dispatch table, which the monitor's commands use.
4. **BASIC** calls the file API.

## The registers

Proposed for nice_cpu's `doc/SYSTEM.md` as a new section, in nice_cpu
issue MJoergen/nice_cpu#107. They take 16 of the words that nice_cpu reserves for I/O.

| Address | Name | A data read returns | A write |
|---|---|---|---|
| `0xFFFFFFA0` | `SD_CSR` | the status below | starts the command in bits 3..0 |
| `0xFFFFFFA1` | `SD_LBA` | the sector number | sets the sector number |
| `0xFFFFFFA2` | `SD_CURSOR` | the cursor, 0 to 127 | sets the cursor to bits 6..0 |
| `0xFFFFFFA3` | `SD_DATA` | the buffer's word at the cursor, and the cursor moves on | writes the buffer's word at the cursor, and the cursor moves on |
| `0xFFFFFFA4` | `SD_ERROR` | the error of the last command, 0 for none | is ignored |
| `0xFFFFFFA5` | `SD_SELECT` | the selected slot | selects the slot in bit 0 |
| `0xFFFFFFA6` | `SD_SIZE` | the card's size in sectors, 0 before a reset | is ignored |
| `0xFFFFFFA7` | `SD_SLOTS` | the number of slots, 0 to 2 | is ignored |
| `0xFFFFFFA8`–`0xFFFFFFAF` | | 0 | is ignored |

The commands, in bits 3..0 of a write to `SD_CSR`:

| Command | What it does |
|---|---|
| 0 | Reset: start the selected card up, read its size, and clear "changed" |
| 1 | Read the sector `SD_LBA` into the buffer |
| 2 | Write the buffer to the sector `SD_LBA` |

The status, from a read of `SD_CSR`:

| Bit | Meaning |
|---|---|
| 0 | Busy: a command runs. A write to any register but `SD_CURSOR` and `SD_DATA` is ignored while it is 1. |
| 1 | Error: the last command failed, and `SD_ERROR` says why |
| 2 | Present: a card is in the selected slot |
| 3 | Ready: the selected card is started up |
| 4 | Changed: a card has been put into the selected slot since the last reset |
| 5 | Write-protected: the card's switch is set |
| 9..8 | The card's type: 0 none, 1 SDSC, 2 SDHC or SDXC |

The errors: 1 no card, 2 not ready, 3 timeout, 4 CRC, 5 the card reported
an error, 6 write-protected, 7 sector out of range, and 8 the start-up
failed.

The rules:

- The buffer is 128 words, and each word holds 4 bytes, little-endian: byte
  4n of the sector is bits 7..0 of word n. FAT is little-endian, so a sector
  of the FAT is 128 words with entry *i* at word *i*, and a 32-byte
  directory entry is 8 words, with the file's size in the last of them.
- The cursor wraps from 127 to 0. A read command does not move it, so a
  program sets it to 0 and reads 128 words.
- `SD_LBA` is always a sector number. The controller turns it into a byte
  address for an SDSC card.
- Every command ends: the controller has a timeout for each step, so busy
  never stays 1.
- A program waits for busy to be 0. In the emulator a command is done at
  once, and on the board it takes from about a millisecond for a read to
  hundreds for a reset, so a program that polls runs the same on both.
- A change of `SD_SELECT` takes effect at once. The status then shows the
  other slot, and "ready" is 0 until a reset, as the cards share one
  controller.
- A read by the debug link returns the same word as a read by the core,
  but does not move the cursor, as a link read of the console takes no
  byte. A link write acts as a core write, so a host can fill the buffer.
- Reset makes the controller idle, with slot 0 selected, the cursor at 0,
  and "changed" set if a card is present.

The registers are a 32-bit version of QNICE-FPGA's at `0xFF20`, which
QNICE's monitor and M2M use. Two other designs were rejected. A buffer
mapped as 128 words would make the cursor unnecessary, but needs 128 words
of I/O space, and only 93 are free. A DMA engine that copies the sector to
memory would be a third master on the data bus, which the core and the link
already share.

## The emulator

`niceemu --sd0 FILE --sd1 FILE` gives each slot an image file, whose size
is a multiple of 512 bytes. `SD_SLOTS` is the number of images given. A
card is present when its image is given, its type is SDHC, and it is
write-protected when the file cannot be written. A command is done before
the next instruction, and a write goes to the file at once. "Changed" is
set at the start, so a program does the reset that it does on the board.
The window has no hot swap.

Without `--sd0`, the words `0xFFFFFFA0`–`0xFFFFFFAF` read as the registers
of a system with no slots, so a program sees `SD_SLOTS` = 0 and no card.
That changes them from ordinary memory, which nice_cpu's SYSTEM.md §5 says
the reserved words are in the emulator today.

## The controller in the RTL

- `src/sd/sd.vhd`: the registers, the buffer in block RAM, and the choice
  of slot. `src/sd/sd_ctrl.vhd`, `sd_cmd.vhd`, and `sd_dat.vhd`: the 4-bit
  SD mode, from [MJoergen/SDCard](https://github.com/MJoergen/SDCard),
  which reads a card's CID and CSD on the MEGA65, and whose write path is
  not finished (5efe006). They are rewritten to `doc/CODING_STYLE.md`. QNICE-FPGA's
  `sdcard.vhd`, in SPI mode, is the fallback.
- The card's clock is 400 kHz for the start-up, then 25 MHz, the default
  speed, from the system clock. High speed is not needed: a sector takes
  about 40 µs at 25 MHz on 4 bits.
- The two slots share the controller. The choice of slot is a multiplexer
  in front of the pins, and the slot that is not selected has its clock
  stopped. Card detect and write protect are read for both slots at all
  times.
- The pins are registered with `IOB TRUE`, the tri-state DAT and CMD lines
  included, in each board's XDC.
- A VHDL model of a card, `sim/sd_card_model.vhd`, answers the commands
  that the controller sends and reads and writes an image file. GHDL in CI
  cannot use the Verilog models in the SDCard repository. The model also
  gives `make cosim` a card.
- `G_FORMAL` checks in `sd.vhd`: busy falls within the timeout, the cursor
  stays in range, and no command starts while busy.

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
  little. The first stage has the root only.
- **Writing**, in an order that a reset at any point leaves no worse than a
  lost cluster: the data, then both copies of the FAT, then the directory
  entry. A new cluster is searched from FSInfo's next-free hint, as the FAT
  of a 32 GB card has about four million entries. FSInfo's free count is
  set to unknown, `0xFFFFFFFF`, which every FAT driver accepts.
- **Safety**: the ROM writes only inside the partition, never the MBR or
  the boot sector, and refuses a card whose FAT32 boot sector does not
  check.
- **Caches**: one sector of the FAT and one per open file, in the ROM's
  variables at `0xFFFFF000`. Two files open at once, a read and a write,
  are enough for BASIC and the monitor. "Changed" in the status drops the
  caches and the mount.

## The ROM

The rule of #24 is that the dispatch table gets an entry only when a
program cannot do without it. So:

- **The sector routines** go in `monlib.nasm`, with no entry: `sd_reset`,
  `sd_read`, and `sd_write`, which poll busy and return the error. The
  registers are the same on every board and in the emulator, so a program
  can reach them itself.
- **FAT32** goes in the ROM, as the monitor's own commands need it. Its
  state, the mounted card and the caches, is state that the monitor keeps,
  so the file API gets entries in the table, in the C ABI, with a negative
  result for an error:

| Entry | Arguments | Result |
|---|---|---|
| `fs_mount` | R1 the slot | 0, or an error |
| `fs_open` | R1 the name, one character per word up to a 0 word; R2 the mode: 0 read, 1 write (create or truncate), 2 the directory | a handle |
| `fs_read` | R1 the handle, R2 the buffer, R3 the number of bytes | the bytes read, one per word; 0 at the end |
| `fs_write` | R1 the handle, R2 the buffer, R3 the number of bytes | the bytes written |
| `fs_close` | R1 the handle | 0, or an error |
| `fs_readdir` | R1 the handle of a directory, R2 a buffer of 4 words | 1 with the 8.3 name, the size, and the attributes in the buffer, or 0 at the end |
| `fs_delete` | R1 the name | 0, or an error |

  A file is opened on the slot of the last `fs_mount`. The first `fs_open`
  after a reset mounts slot 0, or slot 1 when slot 0 has no card.
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
- SPI mode, unless the 4-bit controller cannot be finished.
- High speed and UHS.
- Interrupts from the controller: the ROM polls.
- C programs' files. The C library calls nothing in the ROM (#24), and a C
  buffer packs 4 bytes in a word. C gets its own `fopen` later, if a
  program needs one.

## Open questions

1. **The language of the FAT32 code**: NICE assembly, as the monitor is,
   with QNICE-FPGA's `fat32_library.asm` (BSD-3-Clause) as the guide to its
   structure, or C through the wasm translator. This is #54's second
   question, and one answer serves both.
2. **Writes to the MEGA65's internal card**, which holds its system files:
   allowed as to the microSD, or only in a directory of NiceMon's own, such
   as `/NICE`.
3. **One controller or two**: one with a multiplexer is proposed. Two would
   keep both cards started up, and cost twice the logic for a gain only
   when a program copies between the cards.
4. **Host tools**: a host could read and write the board's card over the
   link while the core is paused, through these registers, and run a FAT
   library on the host, so that a file goes to the card with no PC slot.

## Subtasks

The spec comes first. After it, the RTL and the ROM go in parallel, as the
ROM is developed in niceemu and needs no board.

| Issue | What |
|---|---|
| MJoergen/nice_cpu#107 | The registers in nice_cpu's SYSTEM.md, and `niceemu --sd0/--sd1` |
| #55 | The controller in the RTL, the card model, `tb_sd`, and the formal checks |
| #56 | The pins on the R3, R6, and Nexys4DDR, and the read-only check in `make hwtest` |
| #57 | The sector routines in `monlib.nasm`, and the monitor's `sd` command |
| #58 | FAT32 reading, `dir`, and `load` |
| #59 | FAT32 writing, `save`, and `del` |
| #60 | BASIC's `SAVE`, `LOAD`, and `DIR` |
| #61 | Later: host tools for files on the board's card, over the link |
