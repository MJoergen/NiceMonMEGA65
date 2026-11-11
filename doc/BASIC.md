# The BASIC interpreter

The design of the BASIC interpreter in the ROM, issue
[#54](https://github.com/MJoergen/NiceMonMEGA65/issues/54), and the
stages of the work. **Nothing of it is written yet.**
[BASIC_SURVEY.md](BASIC_SURVEY.md) is the survey behind it. #54 lists
the features and what is left out, and this note does not repeat the
list. It has the rest: the decisions, the limits of the target, the
ROM's main loop, the numbers, the memory, the internals, the room in
the ROM, and the order of the work, with the issue of each stage.

- [Decisions](#decisions)
- [What it runs on](#what-it-runs-on)
- [The main loop](#the-main-loop)
- [The language](#the-language)
- [The memory](#the-memory)
- [Inside](#inside)
- [C, and assembly](#c-and-assembly)
- [Tests](#tests)
- [Stages](#stages)
- [The ROM's room](#the-roms-room)
- [Releases](#releases)
- [Open questions](#open-questions)

## Decisions

Made on 2026-11-11. The first three settle the three open questions
of #54.

- **A 32-bit float**, IEEE 754 binary32, in software first. Later the
  math unit may do part of it, which is a change of nice_cpu. So the
  float routines sit behind a few entries, and give the bits that
  hardware would give ([Floats](#floats)).
- **BASIC is the ROM's main loop.** It replaces `monitor_cmd.nasm`
  whole: the monitor's commands become statements. The dispatch table,
  the HAL, and the programs at `0x8000` stay as they are.
- **C first**, in the ROM's C code beside `fat32.c`, and NICE assembly
  later, for speed and for size. The ROM's room decides when
  ([The ROM's room](#the-roms-room)).
- **Graphics, sprites, and sound** come much later, with hardware of
  their own. They are not in this design.
- **The first stage** is only what keeps the board as usable as it is:
  `LOAD` and `SYS`, so that a program such as nice_chess still loads
  and runs, and the monitor's other commands under new names.
- **A number is an integer until a fraction appears**
  ([Numbers](#numbers)), not a type by its suffix alone.
- **The port to assembly is at the end of stage 4**
  ([The ROM's room](#the-roms-room)).
- **`DUMP` and `DIS` stay**: the monitor's `d` and `u`, with the
  disassembler, are statements for good.
- **V2.0.1 has no BASIC.** The stages are in the milestone V2.0.2,
  with #54, #60, and #62 ([Releases](#releases)).

## What it runs on

Measured on 2026-11-11, at commit 9f92b1a:

| What | Words |
|---|---:|
| The ROM, `0x0000`–`0x7FFF` | 32768 |
| The monitor today | 19313 |
| Of it: `monitor_cmd.nasm`, which BASIC replaces, 2469 of them text | 4070 |
| Of it: `fat32.c` | 9435 |
| Of it: `monitor_eth.nasm` | 1856 |
| Of it: `clock.c` | 1176 |
| Of it: `monitor_dis.nasm`, the disassembler of `u` | 1079 |
| The demo, at `0x6000` | 4978 |
| Free below the demo | 5263 |
| Free once the demo is gone | 13455 |
| The RAM of the ROM's C code, `0xFFFFF400`–`0xFFFFFEFF` | 2816 |
| Of it: used by `fat32.c` and `clock.c`, with the C stack of 1024 | 1953 |
| A program's RAM on the MEGA65, `0x8000`–`0x1EFFF` | 92K |
| A program's RAM on the Nexys4DDR, `0x8000`–`0xEFFF` | 28K |

These facts bound the design:

- **C has no floats in the ROM.** nice_cpu's float library keeps words
  of its own in the image, which is ROM here, so `nicebuild.py --ram`
  refuses a program that uses floats. The library is also 6578 words,
  for `float` and `double`. So the floats of BASIC are routines of its
  own.
- **C costs 6 to 8 words a line.** `fat32.c` is 9435 words from 1162
  lines of code, 8.1 a line, and `clock.c` 1176 from 197, 6.0, both at
  `-Oz`.
- **C's constants cost RAM too.** With `--ram`, every data segment is
  copied to the RAM at the cold start, the strings and the tables
  among them. 863 words are free there.
- **One wasm module.** A program has one (WASM.md), so BASIC's C joins
  `fat32.c` and `clock.c` in `ROM_C`, and shares their memory and their
  C stack of 4096 bytes. There is no `malloc`, and no `setjmp`.
- **The texts of the ROM are one character per word.** The monitor has
  3250 words of `.ASCII_L` text. Packed four to a word with `.ASCII_B`
  and read through the byte window, which reaches the ROM, they would
  be 812.
- **A float holds whole numbers up to 2^24 only.** A word of the
  memory has 32 bits: the microsecond counter, a screen word with its
  colors, an IP address, and an address in a byte window do not
  survive a float.
- **A console read takes its byte.** Nothing tells that a byte waits
  without taking it, until the console's interrupt of nice_cpu V2.1
  (#104). From a file, as in the tests, a read never finds "no byte":
  it gives the next byte of the file. And in `niceemu --window`, two
  reads that find no byte within 1000 steps put the emulator to sleep
  (nice_cpu's SYSTEM.md §1.6).
- **The MEGA65's keyboard has no key for insert or clear.** INST/DEL
  gives DEL with SHIFT too, and CLR/HOME gives Home with SHIFT too
  ([SYSTEM.md](SYSTEM.md#the-keyboard)).

## The main loop

The cold start prints the banner, the free words, and `READY.`, and
reads a line. A line that starts with a number is stored, from stage 3
on. Any other line runs at once. `mon_exit`, and a trap of the C code,
come back to `READY.`.

The monitor's commands become these statements. `DUMP` and `DIS` are
decided, and the other names are a proposal
([Open questions](#open-questions)). A name is a string in quotes, and
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
| `baud [RATE]` | `BAUD [rate]` |
| `d [ADDR] [N]` | `DUMP addr [, n]` |
| `u [ADDR] [N]` | `DIS addr [, n]` |
| `c` | `CLS` |
| `v` | `VER` |
| `?` | `HELP`, as `?` is `PRINT` |
| `h` | `HALT`, which the tests end with |
| `x` | `DEMO`, until the demo leaves the ROM at stage 3 |

- **`SYS addr`** calls the address as `r` does: R1 the entry of
  `mon_putc`, R2 and R3 0, and E 0 (nice_cpu's ABI.md, "Programs under
  a monitor"). When the routine returns, BASIC restores what `mon_exit`
  restores, and goes on with the next statement. In direct mode it
  prints the status, `Returned 0000002A`, as today. A program that
  ends through `exit` or `mon_exit` lands at `READY.`.
- **`LOAD` picks by the name.** A name that ends in `.BIN` is a file of
  address and word pairs, loaded as `load` loads it. Any other name is
  a BASIC program as text, with `.BAS` added when it has no extension
  (#60), from stage 4 on.
- **A `.bin` file and BASIC share the RAM.** BASIC has its variables
  there from stage 2 on, and its program from stage 3 on, so a `.bin`
  word below the top of BASIC's memory means `NEW` first. A program
  at `0x8000` is started before a variable is made. A routine for a
  BASIC program to call is loaded above that top, which a statement
  lowers, as `POKE 55` and `56` do on the C64.
- **nice_chess** is then `LOAD "CHESS.BIN"` and `SYS 0x8000`, where it
  is `load CHESS.BIN` and `r`. `RUN "CHESS.BIN"` does both, from
  stage 4.

## The language

#54 has the list. This section has what the decisions add to it, and
where the list needs a change.

### Numbers

A program sees one kind of number. Inside, a number is a signed 32-bit
integer, or a float, and it stays an integer until a fraction appears:

- `5` and `0x1F` are integers, and `5.0`, `.5`, and `1E3` are floats.
- `+`, `-`, and `*` of two integers give an integer. When the result
  does not fit, they give a float, as BBC BASIC does. Until stage 6
  brings the floats, that is the error `Overflow`.
- `/` always gives a float, so `PRINT 1/3` does not print 0. `DIV` and
  `MOD` divide integers. Until stage 6, `/` and a number with a
  fraction are errors.
- `AND`, `OR`, `XOR`, `NOT`, `<<`, and `>>` take integers. A float
  there is truncated, and one that does not fit is an error.
- A comparison gives the integer -1 or 0.
- The operators, from the one that binds most: `^`, the signs `-` and
  `+`, then `*`, `/`, `DIV`, and `MOD`, then `+` and `-`, then `<<`
  and `>>`, the comparisons, `NOT`, `AND`, and last `OR` and `XOR`.
  That is V2's order, with each new operator beside its like.
- A variable with no suffix holds either, so it has a word for the
  value and a word that says which. `A%` holds an integer only, in one
  word, and a float assigned to it is truncated. `A$` is a string.
- `SQR`, `SIN`, `COS`, `TAN`, `ATN`, `LOG`, `EXP`, and `^` give floats.
  `INT` gives an integer when it fits.
- `PRINT` shows a float with up to 7 significant digits, so `1/3` is
  `0.3333333` and `0.1` is `0.1`. `LIST` and `SAVE` write the shortest
  digits, up to 9, that read back as the same float, so that a program
  saved and loaded is the same program.
- An address from `0x80000000` on is a negative number: `0xFFFF0000`
  prints as -65536. `HEX$` shows the word.

Why not floats alone, as V2 has them, or by suffix alone, as #54 first
said:
a float with no suffix cannot hold a word, so `POKE a, PEEK(a) OR 1`
would lose bits. An integer with no suffix makes `X = 1/3` zero, and
every V2 listing with a fraction needs suffixes. A number that is an
integer until it is not gives both, for one more word in a variable and
a test in each operation, which the integer path needs anyway.

### Names and keywords

- A name is letters and digits, every one significant, in either case,
  and a keyword is a whole name: `TOTAL` is a variable, though it
  starts with `TO`. So `FORI=1TO10` of V2 needs its blanks here.
- A name that starts with `PROC` or `FN` and goes on is a procedure or
  a function, as in BBC BASIC, so no variable starts with them.

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
  operation at stage 2, and the floats at stage 6.

## The memory

BASIC's own variables are with the monitor's, in the RAM from
`0xFFFFF000`. Its workspace is the program's RAM, which C reaches as
words with `nice_peek` and `nice_poke`, each one `MOVE`:

| From | What | Grows |
|---|---|---|
| `0x8000` | The program: its lines, tokenized | Up, at an edit |
| after it | The names, the variables, and the arrays | Up, as a program makes them |
| | Free | |
| below the frames | The strings | Down |
| below the top | The frames of `FOR`, `GOSUB`, `PROC`, and `LOCAL`, a region of a fixed size | Within it |
| the top | The stack of the processor, of BASIC and of a routine that `SYS` calls, down from `0xFFFFF000` | Down |

- The top is the size of the RAM, from `0xFFFFFF9E`, less the
  monitor's variables and room for the stack: about 90K words on the
  MEGA65 and 26K on the Nexys4DDR. In `niceemu`, where the word reads
  0, BASIC takes the MEGA65's size.
- The monitor's variables are 4K words today, and the C code has 863
  free. BASIC's own state, its line buffers, and the keys typed ahead
  need more, so `VARS_WORDS` grows, and a program at `0x8000` gets
  that much less.

## Inside

### Lines and tokens

A line is tokenized when it is entered, one token or operand per word,
as #54 says:

- A line is its length in words, its number, its tokens, and a 0. With
  the length, a search for a line steps from line to line.
- A token has its kind in the top byte: a keyword or an operator with
  its number, a small integer in the token itself, an integer or a
  float in the word after it, a string with its length and its
  characters after it, one per word, a name with its index in the
  table of names, and a line number.
- A line number after `GOTO`, `GOSUB`, `THEN`, `RESTORE`, `TRAP`, and
  `RUN` is a token of its own, with a word after it for the address of
  the line, 0 until the first jump finds it. An edit of the program
  clears those words in one pass. `RENUMBER` changes the tokens.
- A name is looked up when the line is entered, not when it runs, so
  a variable in a running program is an index. `LIST` writes the name
  from the table. A name that no line uses any more stays in the table
  until `NEW`.
- `LIST` writes the keywords in upper case and a blank between tokens,
  so the blanks of a line as typed are not kept.

### Frames

`FOR`, `GOSUB`, `PROC`, and `LOCAL` push frames on one stack of
BASIC's own, each with a tag. A `FOR` frame has the variable, the
limit, the step, and the address of the loop's body, so `NEXT` does not
search. The temporaries of an expression are on the same stack, above
the frames, and are gone at the end of the statement, so an error
drops them by resetting one pointer. `PROC` recursion is on the
frames, not on the processor's stack, as the loop of statements does
not recurse.

### Errors

An error must leave the C code from any depth, and C has no `longjmp`
here. One routine in assembly does it, as `mon_trap` does for a trap:
it resets SP and the C stack pointer, the module's one mutable global,
and goes back to the loop of statements. `mon_trap` does not reset the
C stack pointer today, which matters little for a rare trap, and would
matter for errors. With no `TRAP`, the loop prints the message and the
line, drops the frames, and prints `READY.`. With one, the frames
stay, for `RESUME`.

The depth of an expression is counted, and too deep is an error,
since nothing notices when the processor's stack runs out.

### The break key and keys typed ahead

RUN/STOP is CTRL-C, a byte of the console. A running program polls
the console, and a poll takes its byte:

- A byte that is not CTRL-C goes into a ring of keys typed ahead,
  which `GET` and `INPUT` read first. When the ring is full, the byte
  is dropped, as on the C64.
- The poll is one read every 64 statements, which is more than 1000
  steps apart, so `niceemu --window` does not take the program for a
  wait loop and sleep.
- In the tests, the input is a file, and a poll takes the next byte of
  it. So a test program that runs long ends with `HALT` itself, and
  not with keys after `RUN`.
- Later, the console's interrupt (#104) can replace the poll, and the
  RESTORE key's NMI (#110) can stop a machine program.

### Floats

The floats are one file of assembly, `basic_fp.nasm`, from the start,
not C: it is small, it is what the math unit would replace, and its
check is the host, not a C version.

- The entries: add, subtract, multiply, divide, compare, from an
  integer, to an integer, and the square root, each on the bits in a
  word. The multiply and the divide use the math unit's 64-bit
  results.
- They round to nearest, ties to even, as IEEE 754 says, so that a
  math unit with floats, and `niceemu` with the host's, give the same
  bits later. A program never sees an infinity or a NaN: an overflow
  and a division by zero are errors, and an underflow gives 0.
- `SIN`, `COS`, `TAN`, `ATN`, `LOG`, `EXP`, and `^` are polynomials
  built on those entries, so they give the same digits whoever does
  the arithmetic.
- The conversions to and from decimal use 64-bit integers.

### The screen editor

The Commodore editor of #54, in assembly, in place of `getline`:

- The cursor keys move over the screen, and RETURN takes the logical
  line, up to two rows, 160 characters, from the screen.
- A word of 25 bits says which rows go on from the row above.
  `mon_putc` shifts it when the screen scrolls.
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

## C, and assembly

The C code is written so that assembly can take its place a routine
at a time:

- The workspace is words, and its formats are those of
  [Inside](#inside), with nothing of wasm's memory in them. C keeps
  only BASIC's own state in its memory.
- Every routine follows the C ABI, as the calls between `fat32.c` and
  the monitor do, so C calls assembly and assembly calls C by a label.
- The table of keywords and the messages are in assembly, packed with
  `.ASCII_B`, and C reads them through the byte window with
  `nice_peek`. So they take no RAM, and a quarter of the ROM.
- The floats, the editor, and the way out of an error are assembly
  from the start.

The C code then has a second use. The C version of the stages 1 to 4
fits the ROM, so it stays as the reference of the tests: they run it
and the assembly, and compare the output.

A new ROM needs no bitstream to be tried on a board: the tools load a
monitor at 0 with the ROM hidden, as `make hwtest` does, and #108 is
to patch a ROM into a bitstream in about a minute.

## Tests

- `make -C monitor test`, as now: the keys of each test in a file, and
  the output compared with an expected file that was checked by hand.
- Programs in `monitor/test/basic/`, a `.bas` file and its output,
  typed in as lines, and loaded from an image.
- The benchmarks, from stage 3: the sieve, and Rugg/Feldman 1 to 7,
  with `DIV` for `/` until stage 6, which adds 8. Their steps in
  `niceemu` and their seconds on the R6 are written down at each
  stage, so that the four mechanisms of the survey are measured.
- The floats against vectors from a script on the host: Python's
  doubles, rounded to 32 bits with `struct`, give the correctly
  rounded result of `+`, `-`, `*`, `/`, and the square root.
- The programs of the ECMA-55 conformance suite that the language can
  run (NBS SP 500-70), once the floats and `DATA` are there.
- `make hwtest`: a program typed on the board's line, run, and listed,
  and a file saved and loaded on a card that the test may write.

## Stages

Each is a commit that builds and passes the tests, and has a line in
the table of [The ROM's room](#the-roms-room) with its measured words.
Each has an issue, under #54.

1. **The shell**, #112. `basic.c` in `ROM_C`: `READY.`, a scanner of
   keywords, numbers, and strings, and the statements of
   [The main loop](#the-main-loop), each on the routine that the
   monitor's command has today. No expressions, no variables, and no
   program yet. The main loop, the table of commands, and their
   parsing leave `monitor_cmd.nasm`. What follows it: `load.py
   --monitor` types `SYS 0x8000`, and `hwtest.py`, `demo_hw.py`,
   `cosimtest.py`, `sdtest.py`, `tftptest.py`, the monitor's tests,
   the READMEs, `doc/PROGRAMMING.md`, and nice_chess's README take the
   new names. Done when nice_chess loads from a card and over TFTP and
   plays, and every test passes.
2. **Integers**, #113. Expressions with the operators of
   [Numbers](#numbers), `ABS` and `SGN`, variables with long names,
   `LET`, `PRINT` and `?` with `;`, `,`, `TAB`, and `SPC`, `PEEK`,
   `POKE`, `:`, and the statements of stage 1 with expressions for
   their numbers. The errors, with the way out in assembly. Still
   direct mode only. It measures the words of a C line and the steps
   of an operation.
3. **Programs**, #114. The lines, `LIST`, `NEW`, `CLR`, `RUN`, `END`,
   `STOP`, `CONT`, `GOTO`, `GOSUB`, `IF` on one line, `FOR`, `REM`,
   `INPUT` of numbers, `GET`, `DIM`, the break key, the statement that
   lowers the top of the memory, and the benchmarks. A program pasted
   into the line runs, and `LIST` gets it back. The demo leaves the
   ROM, with `DEMO`, `join.py`, and `demo_hw.py`, as #65 planned, and
   is a `.bin` file to load. This is the first BASIC worth a release.
4. **Files**, #60: `SAVE "NAME"`, `LOAD "NAME"`, and `RUN "NAME"`,
   from the card and from TFTP. Then **the port**, #115: the stages 1
   to 4 in assembly, checked against the C code
   ([The ROM's room](#the-roms-room)). The stages from here on are
   written in assembly.
5. **Strings**, #116. `$` variables and arrays, the heap with back
   pointers and its one sweep, the functions of #54 and `HEX$`,
   `INPUT` of strings, `DATA`, `READ`, `RESTORE`, and `TIME$`.
6. **Floats**, #117. `basic_fp.nasm`, the numbers of
   [Numbers](#numbers), `/`, `^`, the functions, `RND`, and the
   formats of `PRINT` and `LIST`.
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
11. Later, in no order: the math unit's floats, after nice_cpu; the
    console's interrupt for the break key (#104) and RESTORE (#110);
    statements for the network, after #111; virtual screens, `FIND`,
    and `CHANGE`; and graphics, sprites, and sound, with their
    hardware.

## The ROM's room

The words of each stage are guesses, from 7 words a line of C, and
the measured words replace them as the stages are written:

| Stage | Words in C, guessed | In all |
|---|---:|---:|
| 1. The shell, less the main loop it replaces | 1000 | 1000 |
| 2. Integers | 3500 | 4500 |
| 3. Programs | 5300 | 9800 |
| 4. Files | 1000 | 10800 |
| 5. Strings | 4900 | 15700 |
| 6. Floats, with the routines in assembly | 3500 | 19200 |
| 7. The editor, in assembly, and its statements | 2000 | 21200 |
| 8. Structure | 3500 | 24700 |
| 9. Errors | 1000 | 25700 |
| 10. The machine | 1800 | 27500 |

While BASIC is C, the routines of the monitor's commands stay in
`monitor_cmd.nasm`, and the ROM has 13455 words free once the demo is
gone. #111, the network for programs, wants 3500 to 4500 of them. So
**the whole list does not fit in C**: C fills the ROM at stage 4 or
5, and the port to assembly is not a matter of speed alone.

**The port is at the end of stage 4**, with the words measured. The
stages 1 to 4 are ported then, and checked against the C code, and
the stages from 5 on are written in assembly once. So the table's
lines from 5 on say what C would have cost, not what is planned.

After the port, with `monitor_cmd.nasm` gone:

| What | Words |
|---|---:|
| The ROM | 32768 |
| What stays: the monitor without `monitor_cmd.nasm`, with `DIS` | 15243 |
| #111, guessed | 3500 to 4500 |
| Left for BASIC, with the statements that replace the commands | 13000 to 14000 |
| BASIC in assembly, the whole list, guessed | 10000 to 13000 |

- The guess for assembly is from Microsoft's 9 KB for the 6502, and a
  list about twice as long. It fits, with little to spare at its top.
- **What else gives room**: the texts that stay, packed, about 600
  words, and FAT32 in assembly, perhaps 5000. BASIC's own keywords and
  messages are packed from the start.
- **Not a larger ROM.** A second ROM would fit the MEGA65's block RAM
  but not the Nexys4DDR's, and the core's timing margin is small.

## Releases

A tag names the nice_cpu tag it pins ([RELEASE.md](RELEASE.md)), so
the stages have no version of their own: each ships in the release
that is open when it is done. No stage needs nice_cpu V2.1.

- **V2.0.1 has no BASIC**, as decided: the shell alone is a `READY.`
  that knows no BASIC, and gives a user new names for what the monitor
  does.
- **The milestone V2.0.2**, a release that keeps nice_cpu at V2.0, has
  #54, #60, and #62, and the stages 1 to 3, #112 to #114. The port and
  the stages from 5 on have no milestone yet.
- **The stages 1 to 3 ship together**, so that the change of the
  commands comes with a BASIC that runs programs. Stage 4, which ends
  #60, comes with them, or in a release after.
- **#111 and BASIC share the ROM.** #111 is in V2.1, and the table of
  [The ROM's room](#the-roms-room) has its words.

## Open questions

1. **The digits of `PRINT`**: 7, as proposed, or the shortest that
   read back, which shows `1/3` as `0.33333334`.
2. **The names** of the statements of [The main loop](#the-main-loop),
   but `DUMP` and `DIS`: `LOAD` by the extension or a `BLOAD` beside
   it, and TFTP as a second argument of `LOAD` or a `TFTP` of its own.
   Stage 1 needs them. The statement that lowers the top of the
   memory, at stage 3, has no name yet, and neither have those of
   stage 10.
3. **The editor's place**: stage 7, or right after stage 3.
4. **`PROC` and `FN`** as BBC BASIC writes them, which takes names
   that start with them from the variables, or `SUB` and `FUNCTION`.
5. **Reserved names.** A keyword of a later stage, `SPRITE` or
   `SOUND`, breaks a saved program that has a variable of that name.
   The names could be refused as variables from stage 3 on.
6. **An exact division.** `6/2` is a float, as written, so `/` is an
   error until stage 6, and the benchmarks use `DIV` until then. Or
   `/` of two integers gives an integer when nothing is left over:
   then `/` works from stage 2, with an error only where a fraction
   would appear, and a large quotient stays exact.
