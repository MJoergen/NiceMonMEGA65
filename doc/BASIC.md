# The BASIC interpreter

The design of the BASIC interpreter in the ROM, issue
[#54](https://github.com/MJoergen/NiceMonMEGA65/issues/54), and the
stages of the work. **Stage 1, the shell, is written (#112), and so
are stage 2, the numbers (#113), and stage 3, the programs (#114);
the rest is not.**
[BASIC_SURVEY.md](BASIC_SURVEY.md) is the survey behind it. #54 lists
the features and what is left out, and this note does not repeat the
list. It has the rest: the decisions, the limits of the target, the
ROM's main loop, the numbers, the memory, the internals, the room in
the ROM, the order of the work, with the issue of each stage, and
what the stages need of the monitor.

- [Decisions](#decisions)
- [What it runs on](#what-it-runs-on)
- [The main loop](#the-main-loop)
- [The language](#the-language)
- [The memory](#the-memory)
- [Inside](#inside)
- [Assembly](#assembly)
- [Tests](#tests)
- [Stages](#stages)
- [What the stages need of the monitor](#what-the-stages-need-of-the-monitor)
- [The ROM's room](#the-roms-room)
- [Releases](#releases)
- [Open questions](#open-questions)

## Decisions

Made on 2026-11-11, but for the first two, which are of 2026-11-12,
the names of the statements, which are of 2026-11-15, NICE
assembly from stage 2 on and the decisions of stage 2, which are of
2026-11-16, and the last four, which are of 2026-11-18.
They replace the 32-bit float in software, and the number that is an
integer until a fraction appears, of the day before
([Numbers](#numbers) has why). The first, the third, and the fourth
settle the three open questions of #54.

- **One kind of number**, the IEEE 754 binary64 value, a double.
  BASIC has no integers of its own, and no second precision.
- **The numbers are the FPU's**, the floating-point unit of
  [nice_cpu#161](https://github.com/MJoergen/nice_cpu/issues/161),
  which nice_cpu `V2.2` has. The ROM has no float routines, and no
  fallback in software ([The FPU](#the-fpu)).
- **BASIC is the ROM's main loop.** It replaces `monitor_cmd.nasm`
  whole: the monitor's commands become statements. The dispatch table,
  the HAL, and the programs at `0x8000` stay as they are.
- **NICE assembly from stage 2 on.** Stage 1, the shell, was written
  in C, in `basic.c`. The first step of stage 2 ported it to
  assembly, #115, and every stage after it is written in assembly,
  as C would fill the ROM at stage 3
  ([The ROM's room](#the-roms-room)).
- **Graphics, sprites, and sound** come much later, with hardware of
  their own. They are not in this design.
- **The first stage** is only what keeps the board as usable as it is:
  `LOAD` and `SYS`, so that a program such as nice_chess still loads
  and runs, and the monitor's other commands under new names.
- **`DUMP` and `DIS` stay**: the monitor's `d` and `u`, with the
  disassembler, are statements for good.
- **The names of the statements** are those of
  [The main loop](#the-main-loop). `LOAD` picks the kind of file by
  its name, with no `BLOAD`, and a TFTP server is the second argument
  of `LOAD`, `RUN`, and `DIR`, with no `TFTP`. The top of BASIC's
  memory is `HIMEM`.
- **Stage 2's numbers** are those of [Numbers](#numbers): `PRINT`
  with the FPU's 15 digits, `DIV` and `MOD` on words, no `A%`, and
  names of up to 16 characters, packed.
- **The stages 2 and 3 go to `V2.3.2`**, a release of BASIC alone.
  Stage 1 was in `V2.2.1`, and `V2.3.1` comes between, with BASIC's
  image on a card
  ([#153](https://github.com/MJoergen/NiceMonMEGA65/issues/153)),
  after which a new BASIC needs no bitstream
  ([Releases](#releases)).
- **What stage 3 needs of the monitor is in `V2.3.1`**: three entries
  for a line input of BASIC's own, and the size of BASIC's RAM in the
  header of its image
  ([What the stages need of the monitor](#what-the-stages-need-of-the-monitor)).
- **Stage 2 tokenizes the line** that it runs, in the format of
  [Lines and tokens](#lines-and-tokens), so that stage 3 adds the
  stored lines and `LIST`, and no second evaluator. So the token of a
  constant keeps its digits (open question 6). A variable that was
  never assigned is an error, `Undefined variable`, and `DIV` or `MOD`
  by 0 is `Division by zero`, as `/` is.
- **Stage 3's programs** are those of [Programs](#programs): a `FOR`
  loop runs its body at least once, as in V2, an edit of the program
  keeps the variables, an array is made by `DIM` alone, and `GET A`
  gives the code of a key, or 0, with no wait. The variables follow
  the program, and a name's token holds its offset from their start
  ([The memory](#the-memory)).

## What it runs on

Measured on 2026-11-11, at commit 9f92b1a, before the ROM was split
into the monitor's image and BASIC's (#152). The numbers of today, for
every source, are in
[monitor/INTERNALS.md](../monitor/INTERNALS.md#the-roms-words) and
[basic/README.md](../basic/README.md#its-words), and
[The ROM's room](#the-roms-room) has those of the split.

| What | Words |
|---|---:|
| The ROM, `0x0000`–`0x7FFF` | 32768 |
| The monitor, all its sources | 19313 |
| The monitor's `monitor_cmd.nasm`, which BASIC replaces, with 2469 words of text | 4070 |
| The monitor's `fat32.c` | 9435 |
| The monitor's `monitor_eth.nasm` | 1856 |
| The monitor's `clock.c` | 1176 |
| The monitor's `monitor_dis.nasm`, the disassembler of `u` | 1079 |
| The demo, which left the ROM in V2.1 (#129) | 4978 |
| Free without the demo | 13455 |
| The RAM of the ROM's C code, `0xFFFFF400`–`0xFFFFFEFF` | 2816 |
| The part of that RAM used by `fat32.c` and `clock.c`, with the C stack of 1024 | 1953 |
| A program's RAM on the MEGA65, `0x8000`–`0x1EFFF` | 92K |
| A program's RAM on the Nexys4DDR, `0x8000`–`0xEFFF` | 28K |

These facts bound the design:

- **C had no floats in the ROM.** nice_cpu's float library keeps words
  of its own in the image, which is ROM here, so `nicebuild.py --ram`
  refuses a program that uses floats. The library is also 6578 words,
  for `float` and `double`. So the ROM's C code had no `double`, and
  the library is no fallback for the FPU.
- **C costs 6 to 8 words a line**, which is why BASIC is assembly
  from stage 2 on. `fat32.c` was 9435 words from 1162 lines of code,
  8.1 a line, and `clock.c` 1176 from 197, 6.0, both at `-Oz`.
- **C's constants cost RAM too.** With `--ram`, every data segment was
  copied to the RAM at the cold start, the strings and the tables
  among them. 863 words were free there.
- **One wasm module.** A program has one (WASM.md), so the shell's
  `basic.c` joined `fat32.c` and `clock.c` in `ROM_C`, and shared
  their memory and their C stack of 4096 bytes, until #148, #115,
  and #149 took the clock, the shell, and FAT32 out of it, which left
  the ROM with no C. There was no `malloc`, and no `setjmp`.
- **The texts of the ROM are four characters a word.** The monitor had
  3250 words of `.ASCII_L` text. #131 packed them with `.ASCII_B`, and
  the monitor reads them through the byte window, which reaches the
  ROM: they are 868 words now, with the 0 words that end some.
- **A word of the memory has 32 bits**, and a double holds every whole
  number up to 2^53. So a screen word with its colors, an IP address,
  and an address in a byte window survive a double, and so does the
  microsecond counter, with its 64 bits, for 285 years. A 32-bit
  float holds whole numbers up to 2^24 only, and they would not
  survive it.
- **The FPU is there.** nice_cpu `V2.2` has it, in the emulator and
  in `fpu.vhd`, and every board has it since #136.
- **A console read takes its byte.** Nothing tells that a byte waits
  without taking it, until the console's interrupt of nice_cpu V2.1
  (#104). From a file, as in the tests, a read never finds "no byte":
  it gives the next byte of the file. And in `niceemu --window`, two
  reads that find no byte within 1000 steps put the emulator to sleep
  (nice_cpu's DEVICES.md §1.6).
- **The MEGA65's keyboard has no key for insert or clear.** INST/DEL
  gives DEL with SHIFT too, and CLR/HOME gives Home with SHIFT too
  ([SYSTEM.md](SYSTEM.md#the-keyboard)).

## The main loop

The cold start prints the banner, the free words, and `READY.`, and
reads a line. Stage 1 prints `HELP lists the statements` where the
free words are to go, as it has no variables yet. A line that starts with a number is stored, from stage 3
on. Any other line runs at once. `mon_exit` comes back to `READY.`.

The monitor's commands become these statements
([Decisions](#decisions)). A name is a string in quotes, and
a number is decimal, or hex with `0x`, where the monitor took bare
hex.

| Monitor | BASIC |
|---|---|
| `r [ADDR]` | `SYS addr` |
| `r 0` | `SYS 0`, the cold start, entry 0 of the table |
| `load NAME` | `LOAD "NAME.BIN"` |
| `l` | `LOAD` with no name: the lines of a `.bin` file from the console |
| `tftp IP NAME` | `LOAD "NAME", "IP"`, or `"IP:PORT"` |
| `tftp IP [PAT]` | `DIR "IP" [, "PAT"]` |
| `dir [SLOT]` | `DIR [slot]` |
| `save NAME ADDR N` | `SAVE "NAME", addr, n` |
| `del NAME` | `DELETE "NAME"`, as BASIC 65 has it beside `DELETE` of lines |
| `i [A.B.C.D]` | `IP ["A.B.C.D"]` |
| `i dhcp` | `DHCP` |
| `m [MAC]` | `MAC ["02:4E:49:43:45:01"]` |
| `time [D T]` | `TIME ["2026-11-11 14:30:00"]` |
| `time ntp [S] [Z]` | `NTP ["SERVER"] [, "+HH:MM"]`, `""` for the server of DHCP |
| `baud [RATE]` | `BAUD [rate]` |
| `d [ADDR] [N]` | `DUMP [addr] [, n]` |
| `u [ADDR] [N]` | `DIS [addr] [, n]` |
| `c` | `CLS` |
| `v` | `VER` |
| `?` | `HELP`, as `?` is `PRINT` |
| `h` | `HALT`, which the tests end with |
| `x` | None: the demo left the ROM in V2.1, and `x` with it (#129) |

- **`SYS addr`** calls the address as `r` does: R1 the entry of
  `mon_putc`, R2 and R3 0, and E 0 (nice_cpu's ABI.md, "Programs under
  a monitor"). When the routine returns, BASIC restores what `mon_exit`
  restores, clears the FPU's stack and its flags, as the routine may
  use the FPU, and goes on with the next statement. In direct mode it
  prints the status, `Returned 0000002A`, as today. A program that
  ends through `exit` or `mon_exit` lands at `READY.`.
- **`LOAD` picks by the name.** A name that ends in `.BIN` is a file of
  address and word pairs, loaded as `load` loads it. Any other name is
  a BASIC program as text, with `.BAS` added when it has no extension
  (#60), from stage 4 on. So `LOAD "CHESS"` looks for `CHESS.BAS`, and
  before stage 4 it is an error that asks for a `.BIN` name. There is
  no `BLOAD`: BASIC 65's loads bytes at an address that it is given,
  and a `.bin` file has its addresses in it.
- **`SAVE` picks by its arguments.** `SAVE "NAME", addr, n` writes
  words as a `.bin` file, with `.BIN` added when the name has no
  extension, so that `LOAD` reads it back. `SAVE "NAME"` writes the
  program as text, with `.BAS` added, from stage 4 on.
- **A TFTP server is the second argument**, a string, of `LOAD`, of
  `RUN` from stage 4, and of `DIR`, whose number is a slot. There is
  no `TFTP` statement. `SAVE "NAME", "IP"` is an error, as TFTP here
  only reads.
- **A `.bin` file and BASIC share the RAM.** BASIC has its variables
  there from stage 2 on, and its program from stage 3 on, so a `.bin`
  word below the top of BASIC's memory means `NEW` first. A program
  at `0x8000` is started before a variable is made. A routine for a
  BASIC program to call is loaded above that top, which `HIMEM`
  holds, as BBC BASIC has it: `PRINT HIMEM` reads it, and
  `HIMEM = 0x9000` lowers it, where the C64 has `POKE 55` and `56`.
- **nice_chess** is then `LOAD "CHESS.BIN"` and `SYS 0x8000`, where it
  was `load CHESS.BIN` and `r`. `RUN "CHESS.BIN"` does both, from
  stage 4.

## The language

#54 has the list. This section has what the decisions add to it, and
where the list needs a change.

### Numbers

A program sees one kind of number, and inside there is one kind too:
a double, IEEE 754 binary64, on the FPU ([The FPU](#the-fpu)).

- `5`, `0x1F`, `5.0`, `.5`, and `1E3` are all doubles. A double holds
  every whole number up to 2^53, so a word of the memory, a count, and
  an address are exact.
- `+`, `-`, `*`, and `/` are the FPU's, each rounded once. So
  `PRINT 1/3` does not print 0, `6/2` is 3, and a large product is a
  number like any other, with 53 bits of it kept.
- `AND`, `OR`, `XOR`, `NOT`, `<<`, `>>`, `DIV`, and `MOD` work on
  words, each one command of the FPU. An operand is truncated to a
  signed 32-bit word, and one that does not fit is an error. The
  result is a signed word, but for `DIV` of -2^31 by -1, which is
  2^31. `DIV` and `MOD` divide toward zero, and `MOD` has the sign of
  its left operand. `>>` shifts 0 in.
- A comparison gives -1 or 0.
- The operators, from the one that binds most: `^`, the signs `-` and
  `+`, then `*`, `/`, `DIV`, and `MOD`, then `+` and `-`, then `<<`
  and `>>`, the comparisons, `NOT`, `AND`, and last `OR` and `XOR`.
  That is V2's order, with each new operator beside its like.
- A variable is two words, the double. Nothing says what it holds, as
  it holds one kind. There is no `A%`, and a `%` in a name is an
  error, so that it can come with `DIM` if arrays of whole numbers
  need it ([Open questions](#open-questions)). `A$` is a string.
- `ABS`, `SGN`, `INT`, and `SQR` are the FPU's arithmetic, and `INT`
  rounds down. `SIN`, `COS`, `TAN`, `ATN`, `LOG`, `EXP`, and `^` are
  its functions. `^` multiplies when the exponent is whole, so `10^2`
  is 100 and `(-2)^3` is -8.
- A program never sees an infinity or a NaN: a division by zero, an
  overflow, and a function of an argument that it does not take are
  errors. A result too small for a double goes to 0 by steps, with no
  error.
- `PRINT` shows a number with the FPU's `DIGITS 15`, its trailing
  zeros dropped, as C's `%.15G` does: in fixed notation while the
  exponent is -4 to 14, with a 0 before the point, and in E notation
  else, with a sign and at least two digits in the exponent. So
  `1/3` is `0.333333333333333`, `0.1 + 0.2` is `0.3`, `1E15` is
  `1E+15`, and `0.00001` is `1E-05`. `DIGITS` rounds twice, the
  scaled number to a double and that to a whole number, so its last
  digit differs from that of `%.15G` where the digits after it are
  near a 5: 5 of the 510 numbers of stage 2's test (measured
  2026-11-18). BASIC keeps this until `DIGITS` rounds once
  ([nice_cpu#200](https://github.com/MJoergen/nice_cpu/issues/200)). A negative number has its `-`,
  and no blank comes before or after a number. A `,` in `PRINT` goes
  to the next column of 8.
- A constant is read as at most 16 digits in BCD and an exponent,
  `FROMBCD` and `SCALE10`. Digits after the 16th round the 16th.
- `LIST` and `SAVE` write a constant so that a program saved and
  loaded is the same program. How is open
  ([Open questions](#open-questions)).
- An address from `0x80000000` on is a negative number: `0xFFFF0000`
  prints as -65536. `HEX$` shows the word. `PEEK` gives a signed word
  too, and a number above 2^31 - 1 is no address: `POKE 0xFFFFFF00, 0`
  writes the word, and `POKE 4294967040, 0` is an error.

Why one kind, where the note of 2026-11-11 had an integer until a
fraction appears: that was for a 32-bit float, which holds whole
numbers up to 2^24 only, so that `POKE a, PEEK(a) OR 1` would lose
bits with no integers beside it. A double loses none. A variable was
two words with the word that said which it held, and is two words as
a double. So the integers bought only speed, against a float in
software. They cost a second path in every operator, an `Overflow`
that turned an integer into a float, and a `/` that was an error
until the floats came. On the FPU an add takes a few cycles, by the
estimate of nice_cpu#161, and in stage 2 an operator with a variable
after it takes 43 steps in `niceemu` ([Stages](#stages)).

What it costs: BASIC's numbers wait for the FPU
([Releases](#releases)). A number that is computed and printed does
not read back as the same number, which takes 17 digits. And an array
of whole numbers has two words for each.

### Names and keywords

- A name is letters and digits, up to 16 of them, every one
  significant, in either case, and a keyword is a whole name:
  `TOTAL` is a variable, though it
  starts with `TO`. So `FORI=1TO10` of V2 needs its blanks here.
- A name that starts with `PROC` or `FN` and goes on is a procedure or
  a function, as in BBC BASIC, so no variable starts with them.

### Programs

Stage 3's language, decided on 2026-11-18. V2 is the model where
these do not say otherwise.

- **A line number** is 0 to 65535. A line with a number is stored,
  or replaces the line of that number, and a bare number deletes its
  line. A line that the tokenizer refuses is not stored, and its
  error is shown at once. The other errors come when the line runs:
  the check of a whole line at its entry, of #54, comes with the
  editor, stage 7.
- **An edit keeps the variables.** Their table moves with the end of
  the program and keeps its values. The frames and `CONT` are
  dropped, as they hold the addresses of lines. `RUN` and `CLR` clear
  the values, and `NEW` the names too.
- **`GOTO` and `GOSUB` take a line number**, as in V2, and not an
  expression, so that a target is found once and kept. A line that is
  not there is `Undefined line`.
- **`IF` on one line**: `IF c THEN 100`, `IF c GOTO 100`, and `IF c
  THEN` with statements, each with an `ELSE` and a line number or
  statements after it. A false condition goes on after the `ELSE` of
  its `IF`, counting the `IF`s between, or at the next line.
- **A `FOR` loop runs its body at least once**, as in V2 and BBC
  BASIC: `NEXT` adds the step and compares, so `FOR` searches for
  nothing. `FOR I = 5 TO 1` runs once, where ECMA-55 runs it no time.
  A `FOR` of a variable that has a frame drops that frame and those
  above it. `NEXT` with no name takes the latest loop, and `NEXT I, J`
  ends two.
- **An array is made by `DIM` alone.** An array that no `DIM` made is
  `Undefined array`, where V2 makes one of 11 elements, so a V2
  listing may need a `DIM` more. An array has one or two dimensions,
  from 0: `DIM A(10)` has 11 elements, and `DIM B(3, 4)` 20. `A` and
  `A(` are two names, as in V2. An index outside is `Bad subscript`,
  and a second `DIM` of an array is `Redimensioned array`.
- **`GET A`** gives the code of the next key typed ahead, or 0 when
  there is none, and does not wait, as the C64's `GET` does not.
  Stage 5 adds `GET A$`.
- **`INPUT`** prints `? `, or a prompt in quotes first, and reads
  numbers, with commas between them. A line that is no number is
  `Redo from start`, and the line is read again. Too few numbers ask
  for the rest with `?? `, and too many print `Extra ignored`. CTRL-C
  there is a break.
- **`STOP` and the break key** print `Break in 20`, and `END` nothing.
  `CONT` goes on after either, and after `END`, unless the program was
  edited or an error came since: then it is `Can't continue`.
- **An error in a program** prints its message and the line's number,
  `Syntax error in 20`, as in V2, and the frames are dropped.
- **`HIMEM = n`** does a `CLR`, as the frames are below it. It is
  `Out of memory` below the end of the arrays and the frames' room,
  and above the RAM.

### What changed in the list of #54

The review of 2026-11-11 changed the list of #54 in these places:

- **`/`** was "on the math unit", beside a `PRINT 1/3` that is not to
  print 0. [Numbers](#numbers) settles it.
- **`ON ... GOTO` and `ON ... GOSUB`** were left out, as defeating
  `RENUMBER` and the resolved targets. They do not when their targets
  are numbers in the line, as they always are in V2. Only `GOTO` of
  an expression does. They are cheap, and a V2 habit, so stage 8 has
  them.
- **`TIME`** was the microsecond counter, and is now the monitor's
  command for the clock of the time of day. The counter is `TI`, and
  the clock `TIME$`, set by assignment, when strings are there.
- **`WAIT`** was the wait for a time, and is V2's wait on a memory
  word, and a NICE instruction. The wait for a time is `SLEEP`, as
  BASIC 65 has it.
- **`DIR`** was under what is not included, and #60 has it.
- **Storage** was "when #24 has storage". #24 is closed, and the file
  entries 9 to 15 and 20 are in the ROM.
- **Graphics, sprites, and sound** were "not included", and are
  "later, with their hardware".
- **The prototype** of "How" is gone. What it was to measure is
  measured in the stages: the words of a C line and the steps of an
  operation at stage 2.

The review of 2026-11-12, of nice_cpu#161, changed it again:

- **Integers first** and **one type for fractions** are one entry:
  the double of [Numbers](#numbers).
- **"No 64-bit doubles"**, under what is not included, is reversed.
  There is still one type, with no `!` and `#`.
- **`TI`** is the whole microsecond counter, of 64 bits, which a
  double holds for 285 years.
- **The temporaries of an expression** are on the FPU's stack, and
  only the strings are in the region of the frames.

## The memory

BASIC's own variables are 2K words of their own at `0xFFFFE800`–`EFFF`,
below the monitor's at `0xFFFFF000`, which BASIC reaches through the
entries alone (#152). Its workspace is the program's RAM:

| From | What | Grows |
|---|---|---|
| `0x8000` | The program: its lines, tokenized | Up, at an edit |
| after it | The names, the variables, and the arrays | Up, as a program makes them |
| | Free | |
| below the frames | The strings | Down |
| below the top | The frames of `FOR`, `GOSUB`, `PROC`, and `LOCAL`, a region of a fixed size | Within it |
| the top | The stack of the processor, of BASIC and of a routine that `SYS` calls, down from `0xFFFFE800` | Down |

- The top is the size of the RAM, from `0xFFFFFF9E`, less the
  variables and room for the stack: about 90K words on the
  MEGA65 and 26K on the Nexys4DDR. In `niceemu`, where the word reads
  0, BASIC takes the MEGA65's size.
- The variables are 6K words, `MON_VARS` and `BASIC_WORDS`: the
  monitor's 4K and BASIC's 2K, of which its stage 3 uses 1585, and leaves 463
  (measured 2026-11-18). BASIC's state,
  its line buffers, and the keys typed ahead go there. Its 4K would
  leave no room for the stack above the RAM that nice_cpu's demo tests
  on the Nexys4DDR, up to `0xDFFF` (nice_cpu#195), so it grows after
  that is fixed, and a program at `0x8000` then gets that much less.
  The pointer to the end of the names and the variables is one of
  BASIC's own words there.
- The monitor has the size of BASIC's RAM too, in SP at `mon_reset`
  and at `mon_exit`, and in `bin_line`'s end of a program's RAM. So
  `V2.3.1` puts the size in a word of the header of BASIC's image,
  which the monitor takes it from, and a later BASIC grows its RAM
  with no new bitstream
  ([What the stages need of the monitor](#stage-3-the-size-of-basics-ram)).
- A variable is its double, then its name: the name's length, then its
  characters packed four to a word, as `.ASCII_B` packs them, in at most
  4 words. A name is found by its length first. The token of a name
  holds the variable's offset from the start of the table, so the double
  is read with no step over the name. In stage 2 a variable is made by
  an assignment alone, `V =` at the start of a statement or after `LET`,
  so that a line that only names one, or a typo, does not write over a
  program at `0x8000`. A name with no variable is an `Undefined
  variable` when it runs. A variable that was never assigned has
  `0xFFFFFFFF` in the high word of its double, a NaN, which no variable
  holds otherwise, as a program never sees one. Stage 3 keeps the
  format.
- From stage 3 on, the table starts at the end of the program, and the
  token of a name holds the variable's offset from the table's start,
  where stage 2 has it from `0x8000`, its start with no program. So an
  edit moves the table, and the arrays after it, with no change to a
  token. A name in a stored line gets its entry, never assigned, when
  the line is entered, as the line keeps its offset. A direct line
  makes a variable by an assignment, as in stage 2, and by `INPUT` and
  `GET`, and an array's entry by `DIM`. `CLR` sets
  every entry to never assigned, and drops the arrays and the frames.
  The names stay until `NEW`, as the lines refer to them.
- An array's entry has the offset of its data from the table's end in
  the low word of the double, `0xFFFFFFFF` in its high word until
  `DIM`, as a variable never assigned has, and `0x100` in its length,
  which marks the name as an array's. Its data, after the table, is
  its two sizes, the second 0 for one dimension, and its doubles, row
  by row. A new variable moves the data up, with no change to an
  offset. So `CLR` drops the arrays by setting a pointer and the
  entries' high words.
- The program's end is a pointer in BASIC's own RAM, and an empty
  program writes no word at `0x8000`. So the `NEW` of a `.bin` file's
  load leaves the file's words as they are. A `LOAD` of a `.bin` file
  that writes a word below `HIMEM` may write over the program and its
  variables, so it ends with a `NEW`, and at `READY.`, also in a
  running program. Its counts have the lowest address written. A load
  that writes above `HIMEM` alone keeps them, and the line or the
  program goes on, and one that writes no word ends the line.
- A routine that `SYS` calls keeps the variables, whether it
  returns or ends through `mon_exit`, as a routine above `HIMEM`
  must. So a program at `0x8000` that `SYS` starts may leave the
  table broken, and the walk of the table stops at its end pointer
  and at a length above 16, and is never lost in it.

## Inside

### Lines and tokens

A line is tokenized when it is entered, one token or operand per word,
as #54 says:

- A line is its length in words, its number, its tokens, and a 0. With
  the length, a search for a line steps from line to line.
- A token has its kind in the top byte: a keyword or an operator with
  its number, a small whole number in the token itself, a number that
  fits a signed word in the word after it, any other number as a
  double in the two words after it, a string with its length and its
  characters after it, one per word, a name with the offset of its
  variable, and a line number. The three kinds of constant are
  for the room of a line, and the first two are pushed in one access.
  A constant with a fraction or an exponent, or too large for a word,
  keeps its digits beside the double: up to 16 in BCD and their
  exponent, as `DIGITS` gives them and `FROMBCD` and `SCALE10` take
  them. So `LIST` writes digits that read back as the same double, and
  a constant in hex keeps a kind of its own, for `LIST` to write it in
  hex.
- A line number after `GOTO`, `GOSUB`, `THEN`, `ELSE`, `RESTORE`,
  `TRAP`, and `RUN` is a token of its own, with a word after it for the
  address of the line, 0 until the first jump finds it. An edit of the
  program clears those words in one pass. `RENUMBER` changes the tokens.
- A name is looked up when the line is entered, not when it runs, so
  a variable in a running program is an offset. `LIST` writes the name
  from the table. A name that no line uses any more stays in the table
  until `NEW`.
- `LIST` writes the keywords in upper case and a blank between tokens,
  but before `)`, `,`, `;`, and `:`, after `(` and a sign, and between
  a function or an array and its `(`, so the blanks of a line as typed
  are not kept. A minus is a sign when the token before it ends no
  operand.
- A stored line is the tokens of stage 2, at most the 160 words of
  `V_TOK`. The tokenizer writes only `V_TOK`, and a line is stored
  after the whole of it is tokenized, so a line that fails leaves the
  program as it was. That settles S4 of #151, as stage 2 reads a
  string from its token and no longer writes a 0 into the line.

### Frames

`FOR`, `GOSUB`, `PROC`, and `LOCAL` push frames on one stack of
BASIC's own, each with a tag. A `FOR` frame has the variable, the
limit, the step, and the address of the loop's body, so `NEXT` does not
search. A `GOSUB` frame has the address of the token after it. The
region of the frames is 512 words below `HIMEM`, where a `FOR` frame
takes 8 and a `GOSUB` frame 3, and a frame with no room is
`Out of memory`. A `NEXT` with no `FOR` frame is `NEXT without FOR`,
and a `RETURN` with no `GOSUB` frame is `RETURN without GOSUB`. The
numbers of an expression are on the FPU's stack
([The FPU](#the-fpu)). Its other temporaries, the strings, are on the
stack of the frames, above them, and are gone at the end of the
statement. So an error drops them all by resetting one pointer and
clearing the FPU's stack. `PROC` recursion is on the
frames, not on the processor's stack, as the loop of statements does
not recurse.

### Errors

An error leaves the evaluator from any depth. One routine does it:
it clears the FPU's stack and its flags, and goes back to the main
loop, which sets SP again. With no `TRAP`, the loop prints the
message, in full text, and the line, drops the frames, and prints
`READY.`. With one, the frames
stay, for `RESUME`.

The messages of stage 2 are `Syntax error`, `Illegal quantity`,
`Division by zero`, `Overflow`, `Formula too complex`, `Undefined
variable`, and `Out of memory`. A string where a number goes is a
`Syntax error` until stage 5 has strings. Stage 3 adds
`Undefined line`, `Undefined array`, `Bad subscript`,
`Redimensioned array`, `NEXT without FOR`, `RETURN without GOSUB`,
and `Can't continue` ([Programs](#programs)).

The depth of an expression is counted, and too deep is an error,
since nothing notices when the processor's stack runs out. The FPU's
stack-fault flag does not replace the count: it sees the operands
that pend, and nested parentheses pend nothing.

### The break key and keys typed ahead

RUN/STOP is CTRL-C, a byte of the console. A running program polls
the console, and a poll takes its byte:

- A byte that is not CTRL-C goes into a ring of 32 words, which keeps
  31 keys typed ahead, and which `GET`, `INPUT`, and the line read first. When the ring is full, the byte
  is dropped, as on the C64.
- The monitor's `con_getline`, entry 32, reads the console itself, so
  the keys of the ring would not reach it, at `INPUT` or at `READY.`.
  So from stage 3 on BASIC reads its line with a routine of its own,
  the ring first and then the console, on three entries that `V2.3.1`
  adds for it: `con_key`, a byte of the console, `scr_back`, the
  scrollback, and `fs_complete`, TAB
  ([What the stages need of the monitor](#stage-3-the-keys-typed-ahead)).
- The poll is one read every 64 statements, which is more than 1000
  steps apart, so `niceemu --window` does not take the program for a
  wait loop and sleep. It is `con_key` without a wait, which keeps
  the network going, as BASIC's wait for a line does.
- In the tests, the input is a file, and a poll takes the next byte of
  it. So a test program that runs long ends with `HALT` itself, and
  not with keys after `RUN`.
- Later, the console's interrupt (#104) can replace the poll, and the
  RESTORE key's NMI (#110) can stop a machine program.

### The FPU

The numbers are on the floating-point unit of
[nice_cpu#161](https://github.com/MJoergen/nice_cpu/issues/161): a
stack of 16 doubles, registers that push a value and read the top, a
command register, sticky flags, and a register that compares the two
top values. nice_cpu's DEVICES.md §11 has its registers and its
commands, and this section has what BASIC does with them. The ROM
has no float routines.

- **Its stack is the stack of an expression.** The evaluator meets
  the operands and the operators in the order that the stack takes
  them: a variable or a constant is pushed, an operator is one
  command, and no value between them leaves the FPU.
  `A = B + C * SIN(D)` is 13 accesses, each one `MOVE`. Every
  operator and function of stage 2 is one command: `NEG`, `ADD`,
  `SUB`, `MUL`, `DIV`, `ABS`, `SIGN`, `FLOOR`, `SQRT`, `CMP n`, and
  the words' `AND`, `OR`, `XOR`, `NOT`, `SHL`, `SHR`, `IDIV`, and
  `MOD`.
- **A value leaves the stack** for a store and for `PRINT`, and as a
  word for an index and an address, through `FPU_X_W`, after bit 21
  of the status says that it fits. A comparison stays on the stack,
  as `CMP n` pushes -1 or 0.
- **The stack is empty between statements.** So an error clears it
  with one command, and a routine that `SYS` calls may use the FPU.
  A call of a `FN` moves the numbers that pend to its frame, and back
  at the return.
- **The errors are the sticky flags.** BASIC reads them once for each
  expression, before it uses the result: invalid is
  `Illegal quantity`, and division by zero and overflow are errors of
  their own. The stack-fault flag, when more than 16 values pend, is
  `Formula too complex`.
- **`RND`** is BASIC's own: a generator on words, and its word scaled
  to below 1.
- **The digits** of `PRINT`, `INPUT`, `VAL`, `STR$`, and the constants
  are the FPU's decimal commands, `DIGITS 15`, `FROMBCD`, and
  `SCALE10`, which give the digits of a number and take them.
- **niceemu computes with the host's doubles**, and the steps of each
  function are part of nice_cpu's specification, so a program prints
  the same digits in `niceemu` and on the board.
- **No interrupt routine of the ROM uses the FPU**, as BASIC has
  values on its stack through a whole statement.

Each need of BASIC that nice_cpu#161 had open is settled in `V2.2`:
a read of the status waits for the command before it, every result
that is not finite sets a flag, bit 21 of the status says that the
top fits a word, a routine keeps 8 values of the stack across a call,
and the arithmetic and the decimal commands came before the
functions.

### The screen editor

The Commodore editor of #54, in assembly, in place of the monitor's
`con_getline`, entry 32:

- The cursor keys move over the screen, and RETURN takes the logical
  line, up to two rows, 160 characters, from the screen.
- A word of 25 bits says which rows go on from the row above.
  `mon_putc` shifts it when the screen scrolls. That changes the
  monitor, and `V2.3.1` does not have it, so the editor comes in a
  release with a bitstream
  ([What the stages need of the monitor](#the-later-stages)).
- The keys come through `con_key`, the history through `scr_back`,
  and TAB through `fs_complete`, as the line of stage 3 has them.
- Typing inserts, and DEL deletes to the left and closes the gap, so
  the editor needs no INST key and has no quote mode.
- The cursor keys up and down scroll the history today, before the
  first key of a line. The editor takes them, and the history keeps
  Page Up and Page Down.
- A line is checked when it is entered, and the cursor is put at the
  error, as #54 says.
- A host on the line sees what the screen is given, but not the
  cursor's moves. A host pastes lines and reads `LIST`, which needs
  neither.

## Assembly

BASIC is NICE assembly from stage 2 on ([Decisions](#decisions)):

- Stage 2 started with the port of `basic.c`, the shell of stage 1,
  to `basic.nasm` (#115). The tests of stage 1 stayed as they were,
  with a test of the scanner, `basic`, written before the port, and
  the port passes them with the same output.
- The scanner is driven by tables. Each keyword in `OPS` has the
  offset of its program after it, a string of ops, each a byte: the
  kind of the item, a number, a string, a comma, or the end, and what
  follows when it is not there. A statement's routine gets the values
  in R1-R3, from the slots of `V_ARGS`. A new statement is a keyword,
  a program, which may share the ops of another, and a halfword in
  `ACTS`; a new kind of item, such as an expression, is a routine in
  `KINDS`.
- The scanner's routines take and return their values in registers,
  as each one's comment says, and the statements' routines may use
  every register, as the main loop starts again after each. BASIC
  calls the monitor through the entries of the dispatch table alone,
  as a program does (#152): it is an image of its own at `0x4000`,
  assembled apart from the monitor's, so it has none of the monitor's
  labels.
- The table of keywords, the ops, and the messages are packed with
  `.ASCII_B`, and read through the byte window, a quarter of the ROM.
- The workspace is words, and its formats are those of
  [Inside](#inside). BASIC's own state is in its own RAM at
  `0xFFFFE800` ([The memory](#the-memory)).

A new ROM needs no bitstream to be tried on a board: the tools load a
monitor at 0 with the ROM hidden, as `make hwtest` does, and
`make r6 ROMPATCH=f.bin` patches a ROM into the last bitstream in
about a minute (#122).

## Tests

- `make -C basic test`, as now: the keys of each test in a file, and
  the output compared with an expected file that was checked by hand
  ([basic/README.md](../basic/README.md#testing)).
- Programs in `basic/test/`, a `.bas` file and its output,
  typed in as lines, and loaded from an image.
- The benchmarks, from stage 3: the sieve, and Rugg/Feldman 1 to 7,
  as they are written, with `/`. Stage 6 adds 8, which has `^`,
  `LOG`, and `SIN`. Their steps in `niceemu` and their seconds on the
  R6 are written down at each stage, so that the four mechanisms of
  the survey are measured ([The benchmarks](#the-benchmarks)).
- The arithmetic has its tests in nice_cpu, with the FPU. BASIC's
  tests have its numbers as text: what `PRINT` shows, and that a
  constant comes back from `LIST`, against Python's doubles on the
  host.
- The programs of the ECMA-55 conformance suite that the language can
  run (NBS SP 500-70), once the functions and `DATA` are there.
- `make hwtest`: a program typed on the board's line, run, and listed,
  and a file saved and loaded on a card that the test may write.

### The benchmarks

The programs are in `basic/bench/`, and `make -C basic test` runs them
and checks their output (`basic/test/bench.py`). A run's steps are
those of the instruction counter, which `PEEK(0xFFFFFF42)` reads in a
direct line before `RUN` and in one after it, less the same for an
empty program, so each program is as it is written. `make -C basic
bench` prints the rows of steps. Stage 3, in `niceemu` (measured
2026-11-18):

| Program | Steps |
|---|---:|
| Rugg/Feldman 1, an empty `FOR` loop of 1000 | 95930 |
| 2, `K = K + 1` and `IF` | 281497 |
| 3, and `A = K / K * K + K - K` | 583437 |
| 4, `A = K / 2 * 3 + 4 - 5` | 555437 |
| 5, and a `GOSUB` | 722293 |
| 6, and a `FOR` loop of 5 | 1396266 |
| 7, and an array's element in it | 2242057 |
| The sieve of 8191, 1899 primes | 13682849 |

So a statement takes about 100 to 300 steps: `FOR` and `NEXT` about
95, `K = K + 1` with its `IF` about 280, and the array's element about
170. The seconds on the R6 come with `make hwtest`.

## Stages

Each is a commit that builds and passes the tests, and has a line in
the table of [The ROM's room](#the-roms-room) with its measured words.
Each has an issue, under #54.

1. **The shell**, #112. `basic.c` in `ROM_C`, since #115 `basic.nasm`:
   `READY.`, a scanner of keywords, numbers, and strings, and the
   statements of [The main loop](#the-main-loop), each on the routine that the
   monitor's command has today. No expressions, no variables, and no
   program yet. The main loop, the table of commands, and their
   parsing leave `monitor_cmd.nasm`. What follows it: `load.py
   --monitor` types `SYS 0x8000`, and `hwtest.py`,
   `cosimtest.py`, `sdtest.py`, `tftptest.py`, the monitor's tests,
   the READMEs, `doc/PROGRAMMING.md`, and nice_chess's README take the
   new names. Done when nice_chess loads from a card and over TFTP and
   plays, and every test passes.
2. **Numbers**, #113. Expressions on the FPU with the operators of
   [Numbers](#numbers), numbers with a fraction or an exponent,
   `ABS`, `SGN`, `INT`, and `SQR`, variables with long names, `LET`,
   `PRINT` and `?` with `;`, `,`, `TAB`, and `SPC`, and its format of
   a number, `PEEK`, `POKE`, `:`, and the statements of stage 1 with
   expressions for their numbers. The errors. Still direct mode only,
   but the line is tokenized as a stored line will be.
   Its first step is the port of `basic.c` to assembly, #115, which
   is done, and the rest is written in assembly. It needs nothing new
   of the monitor. It measured 1383 words
   ([The ROM's room](#the-roms-room)), and in `niceemu` `A = B` takes
   67 steps, an operator with a variable after it 43, with a small
   constant 37, and a pair of parentheses 24, so `A = B + C` is about
   110 (measured 2026-11-18).
3. **Programs**, #114. The lines, `LIST`, `NEW`, `CLR`, `RUN`, `END`,
   `STOP`, `CONT`, `GOTO`, `GOSUB`, `IF` on one line, `FOR`, `REM`,
   `INPUT` of numbers, `GET`, `DIM`, the break key, `HIMEM`, and the
   benchmarks, with the language of [Programs](#programs). A program
   pasted into the line runs, and `LIST` gets it back. Its line is read
   by a routine of BASIC's own, on the entries that `V2.3.1` adds for
   it. This is the first BASIC worth a release. It is written, mostly
   in `basic/basic_prog.nasm`, and measured 2545 words
   ([The ROM's room](#the-roms-room)); its benchmarks' steps are in
   [The benchmarks](#the-benchmarks) (measured 2026-11-18).
4. **Files**, #60: `SAVE "NAME"`, `LOAD "NAME"`, and `RUN "NAME"`,
   from the card and from TFTP.
5. **Strings**, #116. `$` variables and arrays, the heap with back
   pointers and its one sweep, the functions of #54 and `HEX$`,
   `INPUT` of strings, `DATA`, `READ`, `RESTORE`, and `TIME$`.
6. **Functions**, #117. `SIN`, `COS`, `TAN`, `ATN`, `LOG`, `EXP`, and
   `^`, each a command of the FPU, and `RND`. It is small, and it
   needs the FPU's functions, which may come after its arithmetic.
7. **The screen editor**, #118, and `AUTO`, `RENUMBER`, and `DELETE`
   of lines. It depends on stage 3 only, and those who use the board
   on its own need it most, so it may come right after stage 3.
8. **Structure**, #119. `IF`, `ELSE`, and `ENDIF` over lines, `DO` and
   `LOOP` with `WHILE`, `UNTIL`, and `EXIT`, `PROC` and `FN` with
   parameters, `LOCAL`, and recursion, and `ON ... GOTO`. Their
   targets are found once and kept, as a `GOTO`'s line is.
9. **Errors**, #120. `TRAP`, `RESUME`, `ER`, `EL`, and `ERR$`.
10. **The machine**, #121. `TI`, `SLEEP`, the colors, the cursor, and
    the display offset.
11. Later, in no order: the console's interrupt for the break key
    (#104) and RESTORE (#110); statements for the network, after
    #111; virtual screens, `FIND`, and `CHANGE`; and graphics,
    sprites, and sound, with their hardware.

## What the stages need of the monitor

With [#153](https://github.com/MJoergen/NiceMonMEGA65/issues/153),
BASIC's image comes from a card, and a release of BASIC alone has no
new bitstream ([BASIC_ROM.md](BASIC_ROM.md)). The monitor is then the
one of the last bitstream. So what a stage needs of the monitor must
be there before the stage is written, or the stage waits for a
release with a bitstream. The stages 2 and 3 were checked against the
monitor on 2026-11-18, for `V2.3.1`, the release with #153. Stage 2
needs nothing new, and stage 3 has two gaps, which `V2.3.1` closes:
the entries 38 to 40, and the size of BASIC's RAM in its header, are
written.

### Stage 2

- **The FPU** is reached by BASIC itself. The monitor writes it in
  two places only, the `CLEAR` of `mon_reset` and that of
  `mon_restore`, which `mon_exit` calls, and it has no interrupt
  routine. So the values on the FPU's stack stay across `mon_putc`
  and every other entry, which the later BASICs rely on.
- **The math unit** is used by the monitor's entries, in the clock,
  FAT32, and `monlib.nasm`. So BASIC keeps no operand in it across a
  call of an entry.
- **`PRINT`** has `mon_putc`, and `scr_getxy` for the column. `PEEK`
  and `POKE` are BASIC's own.
- **BASIC's own RAM** has 854 of its 2048 words free, which should do
  for the stages 2 and 3.

### Stage 3: the keys typed ahead

The ring of
[The break key and keys typed ahead](#the-break-key-and-keys-typed-ahead)
is BASIC's, and the monitor's `con_getline`, entry 32, reads the
console itself (`getline_wait` of `monitor/monitor.nasm`). So the keys
that the break poll took would be lost at `INPUT` and at `READY.`.
BASIC cannot read the line itself either: the scrollback's keys and
TAB's completion are routines of the monitor with no entries,
`hist_up`, `hist_down`, `hist_leave`, and `complete`.

`V2.3.1` adds three entries over those routines, in table 1.7, after
entry 37, the monitor's version text (#153):

| Entry | What it gives | Its routine today |
|---|---|---|
| `con_key` | A byte of the console, with a wait or without, and the network kept going meanwhile | `getline_wait` |
| `scr_back` | The scrollback: some rows back or forward, or the screen again | `hist_up`, `hist_down`, and `hist_leave` |
| `fs_complete` | TAB's completion of a file's name, on a line of the caller's | `complete` |

BASIC then reads its line with a routine of its own, the ring first,
and `con_getline` stays for the programs. The break poll is `con_key`
without a wait, so a long `RUN` keeps the network going too, as
BASIC's wait for a line does today. The names of the entries are not
final.

### Stage 3: the size of BASIC's RAM

Before `V2.3.1`, the monitor had the size of BASIC's own RAM in three
places: `MOVE SP, STACK` in `mon_reset` and in `mon_exit`, and
`VARS_WORDS` in `bin_line`, for the end of a program's RAM. That RAM is to grow from
2K words to 4K ([The memory](#the-memory)). The monitor's pushes at
`mon_exit` would then land in it, and `bin_line` would write a file's
words there. So the growth would change the monitor, and need a
bitstream.

`V2.3.1` puts the words of BASIC's own RAM in a word of the header of
BASIC's image ([BASIC_ROM.md](BASIC_ROM.md#the-image)). The monitor
takes SP and the end of a program's RAM from it, 1024 to 8192 words, and the header's
version of the RAM's layout then covers the monitor's own RAM alone,
from `0xFFFFF000`. `load.py --monitor` takes BASIC's from the word
too, and has the monitor's as `MON_VARS`.

The rest of stage 3 is BASIC's own. `HIMEM` works with `bin_line` as
it is: its counts have the lowest address written, so BASIC knows
after a load whether a word went below the top.

### The later stages

These were looked at, and not checked as the stages 2 and 3 were:

- **Stage 7, the editor**, changes the monitor as it is designed:
  `mon_putc` shifts the word of the rows that go on
  ([The screen editor](#the-screen-editor)). `V2.3.1` does not have
  that (decided on 2026-11-18), so the editor comes in a release with
  a bitstream. It uses the three entries above too.
- **The stages 4 to 6 and 8 to 10** show nothing that they need of
  the monitor.
- **The console's interrupt (#104) and RESTORE's NMI (#110)**, of
  stage 11, change the FPGA, so they need a bitstream in any case.

## The ROM's room

The words of each stage are guesses, and the measured words replace
them as the stages are written. The guesses in assembly share the
middle of the guess for the whole list, 10500 words, by the guesses
in C that the note had before 2026-11-16:

| Stage | Words, guessed | In all |
|---|---:|---:|
| 1. The shell in C, less the main loop it replaces, measured | 961 | 961 |
| 2. The port of the shell, measured | -1325 | -364 |
| 2. Numbers, measured | 1383 | 1019 |
| 3. Programs, measured | 2545 | 3564 |
| 4. Files | 400 | 3964 |
| 5. Strings | 1900 | 5864 |
| 6. Functions | 200 | 6064 |
| 7. The editor and its statements | 2000 | 8064 |
| 8. Structure | 1400 | 9464 |
| 9. Errors | 400 | 9864 |
| 10. The machine | 700 | 10564 |

Stage 1 was `basic.c`, 1510 words, and `basic.nasm`, 624, of which 431
were its packed texts, the help among them, less 1032 words that left
`monitor_cmd.nasm` and 141 that left the other files.
The port of stage 1 to assembly (#115) made `basic.nasm` 821 words, of
which 440 are its texts, the help, the keywords, and the ops among them.
With `basic.c` it was 2134. The C code's start and its initial values
are 8 words shorter, and the clock 4, without the stubs, so the monitor
went from 22611 words to 21286, 1325 fewer (measured 2026-11-16).

The ROM had 13455 words free without the demo, which left it in V2.1
(#129). #111, the network for programs, leaves 9757 of them, #131,
the texts packed, 11876, and `time ntp` (#127) 10952 (measured
2026-11-14), TAB's completion of names (#137) 10167, and the shell
of stage 1 (#112) 9206 (both measured 2026-11-15), the clock in
assembly (#148) 10157, the shell in assembly (#115) 11482, and FAT32
in assembly, with the C code's support out of the ROM and an
immediate 0 read from R0 (#149), 18903 (all measured 2026-11-16). In
C, at 7 words a line, the stages 2 and 3 alone were guessed at 8800
words, so C would have filled the ROM at stage 3. That is why BASIC is
assembly from stage 2 on.

Since #152 the ROM is two images, and BASIC's is `0x4000`–`0x7FFF`,
16384 words. Stage 1 fills 5067 of them, with its own copies of
`common.nasm`, `monlib.nasm`, and `mon.nasm`, 593 words, and leaves
11317 free; the monitor's image is 9542 words, with 6842 free below
`0x4000` (measured 2026-11-18). Stage 2 fills 1383 words more, 6450,
and leaves 9934 free (measured 2026-11-18). Stage 3 fills 2545 words
more, 9026, where 2100 were guessed, and leaves 7358 free (measured
2026-11-18). The list after stage 3 is guessed at 7000 words in the
table above, which fits, with little to spare.
The split is one constant, `BASIC_BASE` of `monitor/common.nasm`: at
`0x3000`, BASIC would have 20480 words, and the monitor 2746 free.

In assembly, the whole list is guessed at 9000 to 12000 words, which
fits what is free:

- The guess is from Microsoft's 9 KB for the 6502, and a list about
  twice as long, less the 1000 words of float routines that
  nice_cpu#161 estimates the FPU to save.
- **What gave room**: FAT32 in assembly (#149), 7421 words with the
  C code's support. BASIC's keywords and messages are packed from the
  start.
- **Not a larger ROM.** A second ROM would fit the MEGA65's block RAM
  but not the Nexys4DDR's, and the core's timing margin is small.

## Releases

A tag names the nice_cpu tag it pins ([RELEASE.md](RELEASE.md)), so
the stages have no version of their own: each ships in the release
that is open when it is done.

- **Every stage from 2 on needs the FPU**, which nice_cpu `V2.2` has,
  in `niceemu` and in `fpu.vhd`, and every board has since #136.
- **Stage 1 was in `V2.2.1`**, #112, with the port of the shell,
  #115.
- **`V2.3.1` has no stage.** It has BASIC's image on a card (#153),
  and what stage 3 needs of the monitor
  ([What the stages need of the monitor](#what-the-stages-need-of-the-monitor)),
  so that the stages after it need no bitstream.
- **The stages 2 and 3, #113 and #114, go to `V2.3.2`**, with #54,
  #60, and #62 (decided on 2026-11-18). Neither changes the monitor,
  so it can be a release of BASIC alone: `BASIC-V2.3.2.ROM` for the
  card, with the bitstreams and the core files of `V2.3.1`. Stage 4,
  which ends #60, comes with them, or in a release after. The stages
  from 5 on have no milestone yet.
- **A stage that changes the monitor waits for a release with a
  bitstream.** Stage 7, the editor, is the first.
- **#111 and BASIC share the ROM.** #111 is in V2.1, and
  [The ROM's room](#the-roms-room) has its words.

## Open questions

1. ~~**The digits of `PRINT`**.~~ Settled on 2026-11-16: the FPU's
   15, as `%.15G` writes them ([Numbers](#numbers)).
2. ~~**The names** of the statements of
   [The main loop](#the-main-loop).~~ Settled on 2026-11-15
   ([Decisions](#decisions)): `LOAD` by the name, TFTP as its second
   argument, and `HIMEM`. The names of stage 10 come with it.
3. **The editor's place**: stage 7, or right after stage 3. Either
   way it changes `mon_putc`, so it comes in a release with a
   bitstream
   ([What the stages need of the monitor](#the-later-stages)).
4. **`PROC` and `FN`** as BBC BASIC writes them, which takes names
   that start with them from the variables, or `SUB` and `FUNCTION`.
5. **Reserved names.** A keyword of a later stage, `SPRITE` or
   `SOUND`, breaks a saved program that has a variable of that name.
   The names could be refused as variables from stage 3 on.
6. ~~**The digits of a constant**, so that `LIST` gives the program
   back.~~ Settled on 2026-11-18: the token of a constant keeps its
   digits beside the double ([Lines and tokens](#lines-and-tokens)), as
   stage 2 tokenizes ([Decisions](#decisions)).
7. **`A%`**: not in stage 2, where `%` in a name is an error. It may
   come with `DIM`, as one word of storage for a whole number, pushed
   and read through the FPU's view of a word. An array of flags is
   then half as large, which counts in the Nexys4DDR's 26K words.
8. ~~**When the stages start.**~~ Settled: the FPU was there in
   nice_cpu `V2.2` before stage 2 started.
