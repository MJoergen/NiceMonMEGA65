# BASIC

- [The statements](#the-statements)
- [Numbers](#numbers)
- [Programs](#programs)
- [The disassembler](#the-disassembler)
- [Loading without a host](#loading-without-a-host)
- [Building](#building)
- [Testing](#testing)
- [Its words](#its-words)

The BASIC of the ROM, whose `READY.` the boards show at power-up. Its
design, with the stages to come, is in [doc/BASIC.md](../doc/BASIC.md),
and the monitor that it runs on, with the files, the network, and the
programs at `0x8000`, in [monitor/README.md](../monitor/README.md).

BASIC is an image of its own in the ROM, at `0x3000`, assembled apart
from the monitor's at `0x0000` (#152). It calls the monitor through the
entries of the dispatch table alone, as a program at `0x8000` does, so
everything that BASIC does, a program can do too. The monitor knows of
BASIC only its two vectors, at `0x3000`, the cold start, and `0x3002`,
the warm start, after a program. BASIC's own state is in 2K words of
its own at `0xFFFFE800`, below the monitor's, and the stack starts
below them. BASIC's programs, their variables, and their arrays are in
the program's RAM, from `0x8000` (Programs below).

## The statements

The ROM's user interface is BASIC (issue #54,
[doc/BASIC.md](../doc/BASIC.md)). Stage 1 (issue #112) is the shell:
the monitor's commands as statements. Stage 2 (issue #113) adds the
numbers: expressions, variables, `PRINT`, `LET`, `POKE`, and `PEEK`.
Stage 3 (issue #114) adds the programs: lines with numbers, which
BASIC keeps and runs (Programs below).

At the cold start the ROM clears the screen, prints its banner,
`NiceMon` and the version, then `HELP lists the statements` and
`READY.`, on the screen and on the line. It reads a line from the
console: the keyboard and the line, which the hardware merges, with
the screen editor below. CTRL-C empties the line, and the function
keys, the other control codes, and the bytes `0x80` to `0x9F` do
nothing. Keys typed while a program runs wait for the next line,
`INPUT`, or `GET`, up to 31 of them, and those after are lost. RETURN
runs the line, and BASIC prints `READY.` after it. A line of blanks only runs nothing and gets no
`READY.`. A break on the UART, or a host's half-close over Ethernet,
ends the line's input and not the keyboard's, and the next host to
connect over Ethernet can type again
([SYSTEM.md](../doc/SYSTEM.md#io-registers), `0xFFFFFF00`).

A line has one statement or more, with colons between them, such as
`A = 5: PRINT A * 2`. A statement is a keyword, in either case, and its
arguments, with commas between them, or an assignment. A keyword is a
whole name: `LOADX` is no `LOAD`, but a variable. An argument is a
number, which is an expression (Numbers below), such as `SYS 0x8000`
or `DUMP A + 4, 2`, or a string in quotes, such as
`LOAD "HELLO.BIN"`. A string that the line ends without its closing
quote ends with the line. A number for an address, a count, or a word
must fit a signed word, -2147483648 to 2147483647, and is rounded
toward zero, so `SYS 0xFFFF0000` and `SYS -65536` are the same, and
`SYS 4294901760` is an `Illegal quantity`. An address from
`0x80000000` up is a negative number.

A line that is no statement prints `Syntax error` and the lines of
`HELP` of its statement, or `Syntax error; HELP lists the statements`
when it starts with no keyword. The other errors print their message,
such as `Division by zero`, and the statements after it do not run.
The line is read from the left, and the first error decides:
`SAVE "X", "Y", 1/0` is a `Syntax error`, as `SAVE` with an IP address
takes nothing after it, but `SYS 1/0` is a `Division by zero`. `0x`
without digits is no number.

The screen editor works as the C64's (issue #118). The cursor keys
move the cursor over the whole screen, and HOME moves it to the top
left. The cursor key down at the last row scrolls the screen. A key
inserts its character at the cursor, and DEL and backspace delete the
character before it, and close the gap. RETURN takes the line that the
cursor is in, wherever the cursor is in it, so a line that `LIST`
showed can be changed and entered again: the cursor up to it, the
change, and RETURN. A line goes on into the rows below it, up to four,
and takes up to 254 characters; a line that `PRINT` or `LIST` wraps is
one line too. When a line grows into a row that holds other text, that
row and those below it move down. At `INPUT` the answer starts after
the prompt. There is no INST key and no quote mode.

A line that the tokenizer refuses, such as `10 PRINT 1 @ 2`, is not
stored. After the error and `READY.`, the line is shown again with the
cursor at the error, so that it can be fixed and entered with RETURN.
This happens only when no key waits: the lines that a host pastes come
one after the other, and the next would land in this one, so they get
the error alone. The errors that only running a line finds are shown
when it runs.

A terminal on the line sees what is typed at the end of a line, as
before. After a move of the cursor, or a RETURN on a line that was on
the screen already, it gets the whole line again, after a CR, as BASIC
takes it.

Page Up and Page Down scroll back through the rows that left the top
of the screen, 24 rows at a time. On the MEGA65 Page Up and Page Down
are CTRL and MEGA with CRSR↑ and CRSR↓. Any other key shows the
screen again, and goes on to the line. The history has 384 rows on
the MEGA65 and 77 on the Nexys4DDR. `CLS` leaves it, as `clear` in a
terminal does, and the cold start empties it. `niceemu` has no display
offset, so there the history is kept but not shown.

TAB completes the name of a file of the card's folder `NICE`, as Bash
does, in the word before the cursor when it is not the keyword itself
(issue #137). A name not yet in quotes gets its opening quote. When one
file matches, the rest of its name follows, then the closing quote and
a blank. When several match, the word goes on to the start that they
all share, and a TAB that adds nothing lists them and shows the line
again. Names match in either case, and the word takes the case of the
card's name. Directories, names outside ASCII, and a name that does not
fit the line are left out. With no match, no card, or a card that
fails, TAB does nothing.

| Statement | What it does |
|---|---|
| `SYS A` | Calls the program at `A` ([Programs](../monitor/README.md#programs)), and prints its status when it returns: `Returned 0000002A`. The variables stay, so a program that wrote over them leaves them broken. A word of 0 at `A` is no program, and `SYS` says so: `No program at 00008000`. `SYS 0` runs entry 0 of the dispatch table, the cold start, so it restarts BASIC and leaves the RAM from `0x8000` alone. |
| `DUMP [A] [, N]` | Shows `N` words from `A`, 4 to a row with the row's address first, all in hex. Without `A`, the words after the last shown; without `N`, 32 words. |
| `DIS [A] [, N]` | Disassembles `N` instructions from `A`, a row each: the address, the instruction's 1 to 4 words, and its text, all in hex (The disassembler below). Without `A`, the instructions after the last shown; without `N`, 20. |
| `CLS` | Clears the screen. |
| `VER` | The versions of the monitor and of BASIC, and of the dispatch table: `NiceMon V2.4, BASIC V2.4, dispatch table 1.8`. |
| `IP ["A.B.C.D"]` | Shows the Ethernet station's IP address, `IP address 192.168.1.65`, or writes it first: four decimal numbers of 0 to 255 with dots between them, such as `IP "192.168.1.65"`. Anything else is no address, and `IP` says so and writes nothing. It sets the address with `net_set`, with no mask, no gateway, and no DNS server, and writes `0xFFFFFFB0`, `NET_IP` ([SYSTEM.md](../doc/SYSTEM.md#the-ethernet-station)), when the address is another, so a host connected over TCP loses its connection; the same address again changes nothing there. In `niceemu` it is a register that keeps what is written. |
| `DHCP` | Gets the IP address from the network's DHCP server and writes it, as `IP` does, then shows it, with the mask, the gateway, the DNS server, the DHCP server, and the NTP server, if it gives one, a line each ([The network](../monitor/README.md#the-network)). Without an answer, it prints `No answer from a DHCP server` after about 8 seconds, and leaves the address as it was. |
| `MAC ["MAC"]` | Shows the station's MAC address, `MAC address 02:4E:49:43:45:06`, or writes it first: six bytes of one or two hex digits, in either case, with colons between them, such as `MAC "02:4E:49:43:45:01"`. The first byte must be even, as an odd one makes a group address. Anything else, an empty string too, is no address, and `MAC` says so and writes nothing. It writes `0xFFFFFFB1` and `B2`, so a host connected over TCP loses its connection. Each kind of board has its own after reset: `02:4E:49:43:45:03` on the R3, `02:4E:49:43:45:06` on the R6, and `02:4E:49:43:45:0A` on the Nexys4DDR. Two boards of the same kind on one network need different MAC addresses. In `niceemu` they are registers too, `02:4E:49:43:45:00` after reset. |
| `TIME ["YYYY-MM-DD HH:MM:SS"]` | Shows the clock of the time of day, `2026-11-11 14:30:00`, or sets it first to the date and the time given, two digits for each part but the year, in the years 1970 to 2105, such as `TIME "2026-11-11 14:30:00"`. The clock keeps local time, as the MEGA65's real-time clock does, and knows no time zones. After a reset of the system it is not set. The cold start sets it from the MEGA65's real-time clock, unless the real-time clock lost its time ([SYSTEM.md](../doc/SYSTEM.md#the-i2c-bus)), and leaves a clock that is set already. On the MEGA65, `TIME` with a date and a time in the years 2000 to 2099 sets the real-time clock too, so that later starts, and the MEGA65's other cores, have the time. Until the clock is set, as on the Nexys4DDR, which has no real-time clock, `TIME` prints `Clock not set`; a program, a host, `TIME`, or `NTP` sets it. A start of a program keeps it. Anything else is no time, and `TIME` says so and sets nothing. A clock that a program set past 2106-02-07 shows as `Clock past 2106`. In `niceemu` the clock is the host's time in UTC from the start. |
| `NTP ["SERVER"] [, "+HH:MM"]` | Sets the clock from a time server on the network, and on the MEGA65 the real-time clock too, as `TIME` with a date does, and shows the time it set, the server, and how far the clock was off, such as `Clock set 2026-11-14 12:30:05 from 192.168.1.1, was 7 s behind`. SERVER is a name, such as `"pool.ntp.org"`, or an IP address. Without it, or with `""`, the server is the NTP server that `DHCP` got, or else `pool.ntp.org`. A time server gives UTC, and the clock keeps local time, so the offset is local time less UTC, `"+HH:MM"` or `"-HH:MM"` from `-12:00` to `+14:00`, such as `NTP "", "+01:00"` for Central European Time and `"+02:00"` for its summer time; without it the clock is set to UTC. It needs an IP address, and for a name a DNS server, from `DHCP`. Its errors are a line each: no IP address, no answer to ARP from the server or the gateway, no DNS server, no such name, an error of the DNS server, no answer from the DNS server or the time server after 3 tries of 2 seconds, a server that refused, and an answer that is not to be trusted ([The network](../monitor/README.md#the-network)). |
| `BAUD [RATE]` | Shows the UART's baud rate, `Baud rate 230400`, or writes it first: 115200, 230400, 460800, 921600, 1000000, 1500000, or 2000000, such as `BAUD 921600`. Anything else is no rate, and `BAUD` says so and writes nothing. It writes `0xFFFFFF9F` ([DEBUG_LINK.md](../doc/DEBUG_LINK.md#the-baud-rate)), as the on-board debugger's settings page does. The UART takes the new rate once it has sent nothing for 1 ms, so the answer and `READY.` still come at the old rate, and a terminal on the UART then changes to the new one; only a reset brings back 230400. Over Ethernet the rate does not matter. In `niceemu` the word is memory, which reads 0 after a clear. |
| `LOAD` | Enters words into the RAM from lines of `ADDR WORD` in hex, as a `.bin` file has them (Loading without a host below), up to an empty line, and prints the words written and the lines skipped: `Words loaded: 600, 00008000 to 00008257`. A `LOAD` that writes a word below `HIMEM` (Programs below) may write over BASIC's program and its variables, so it ends with a `NEW`, and at `READY.`, also in a program. One that writes above `HIMEM` alone keeps them, and the line goes on. One that writes no word ends the line. |
| `DIR [SLOT]` | Lists the folder `NICE` of the SD card's FAT32 file system ([Files](../monitor/README.md#files)): `Directory of NICE`, then a row for each file, its name in 24 columns, the long name where it has one or else the 8.3 name, and its size in decimal, and for each directory, its name and `<DIR>`, then `Files: 25, directories: 1`. A name of 24 characters or more has a row of its own, and the size is on the next. With `SLOT`, it mounts the card in it first, and a slot that the board does not have is `File error 27`; without, it lists the card mounted, which the first `DIR` or `LOAD` after reset mounts. It reads the folder through a handle, as a program does, so after a program that left both handles open it is `File error 23`, as `LOAD` and `SAVE` are; `DIR 0` mounts again, which closes them. An error is shown with its number and meaning: `File error 18, FAT16, which is not supported`. |
| `LOAD "NAME.BIN"` | Loads the `.bin` file `NAME.BIN` of the card's folder `NICE` as `LOAD` loads lines, and prints the same summary, so a program copied to the card on a PC loads with no host. Unlike the lines typed, an empty line is passed over, the end of the file ends the load, and a skipped line is counted from the first line of the file. A line with a byte that is not printable ASCII, a control code other than TAB, CR, or LF, DEL, or a byte from `0x80`, is skipped, as `niceemu` rejects it, so that no byte is dropped from the middle of a number. An error in the middle of the file, such as `File error 26, the FAT is damaged`, comes after the summary of the lines before it, whose words are in the RAM. The name is the long name or the 8.3 name, in either case, such as `LOAD "my prog.bin"`. Any other name is a BASIC program, `LOAD "NAME"` below. |
| `LOAD "NAME"` | Loads the BASIC program `NAME.BAS` of the card's folder `NICE`, or `NAME` when it has a dot, such as `LOAD "CHESS"` or `LOAD "game.txt"`. It reads the lines as if they were typed, after a `NEW` at the first, so a program written on a PC loads too: CR LF, LF, and CR end a line, a TAB is a blank, the keywords are in either case, and a line of blanks is passed over. The first line that cannot be stored ends the load, with its error and the line itself, and the lines before it stay: `Line without a number`; `Line too long`, of more than 254 characters, or with more tokens than the 160 words of a line; `A byte that is no character`, a control code or a byte from `0x80`; and the tokenizer's `Syntax error`. A file that is not there keeps the program. It ends at `READY.`, also in a program. |
| `SAVE "NAME"` | Writes the program to the file `NAME.BAS` of the card's folder `NICE`, or `NAME` when it has a dot, as the text that `LIST` shows, each line ended by LF, so that `LOAD "NAME"` reads it back and an editor on a PC opens it. The text of a line may be longer than the line typed, as `LIST` adds blanks and writes `?` as `PRINT`; `LOAD` takes 254 characters. It makes the file, or truncates it, as `SAVE` of words does, and prints nothing. When the card fills up, it prints error 30. CTRL-C stops it, and the file keeps the lines before. |
| `SAVE "NAME", A, N` | Writes `N` words from `A` to the file `NAME` of the card's folder `NICE` as a `.bin` file, a line of `ADDR WORD` in hex for each, and prints `Words saved: 600, 00008000 to 00008257`. A name with no extension gets `.BIN`: `SAVE "PROG", 0x8000, 600` writes `PROG.BIN`. It makes the file, or truncates it when it is there, and `LOAD` reads it back. When the card fills up, the file keeps what fitted, and `SAVE` prints error 30. SAVE writes only to the card: `SAVE "NAME", "IP"` says so. |
| `DELETE "NAME"` | Deletes the file `NAME` of the card's folder `NICE`, its long name or its 8.3 name, as for `LOAD`, with its long-name entries, if it has them, and prints `Deleted NAME`. |
| `LOAD "NAME", "IP"` | Loads the `.bin` file `NAME.BIN`, or the BASIC program `NAME.BAS`, from the TFTP server at the IP address `IP`, such as `LOAD "HELLO.BIN", "192.168.1.10"`, as `LOAD` loads one from the card, and prints the same summary for a `.bin` file ([The network](../monitor/README.md#the-network)). `"IP:PORT"` sends the request to `PORT` instead of 69. It needs an IP address, from `IP` or `DHCP`. Without an answer, it prints `No answer from the TFTP server` after about 5 seconds; an error of the server is shown with its code and its message: `TFTP error 1, File not found`. |
| `DIR "IP" [, "PAT"]` | Lists the files of the server `tools/tftpd.py` at `IP` whose names match the pattern `PAT`, with `*` and `?`, such as `DIR "192.168.1.10", "*.BIN"`, a line each with the name and the size; without `PAT`, all of them. A byte of a name that is not printable ASCII is left out, and a line shows its first 77 characters. Another server answers with an error. |
| `PRINT [X] [; X] [, X]`, `? ...` | Prints its items, numbers and strings in quotes, such as `PRINT "A ="; A, B`. `;` joins two items, and `,` goes to the next column of 8. `TAB(N)` goes to column `N`, unless the cursor is past it, and `SPC(N)` prints `N` blanks, for an `N` of 0 to 255. Items with nothing between them are joined too. A line ends with CR LF, but for a `;` or a `,` at its end, which leaves the cursor there; `READY.` then starts a row of its own. `?` is `PRINT`. |
| `[LET] V = X` | Sets the variable `V` to the number `X`, such as `LET TOTAL = TOTAL + 1` or `TOTAL = TOTAL + 1`. |
| `POKE A, X` | Writes the word `X` to the address `A`, such as `POKE 0x9000, -1`. `PEEK(A)` reads it (Numbers below). |
| `HALT` | Halts the core, which the reset button, or a host over the link, starts again. The tests end with it. |
| `HELP` | Lists the statements, and the keys of the history. |

The debugger has pause, step, and inspect, so BASIC adds only `LOAD`
with no name, which loads a program with no host's tools and no
storage, and `DIS`, which reads code with no host. `DIR` and `LOAD` read
programs from a card's FAT32 file system, and `SAVE` and `DELETE` write
it. `TIME` shows the clock, which the dates of the files come from.
`DHCP` gives a board on a network an address with no host, and `LOAD`
with a server loads a program from a server on it.

## Numbers

A number is a double, IEEE 754 binary64, on nice_cpu's FPU, and BASIC
has no other kind ([doc/BASIC.md](../doc/BASIC.md#numbers)). A double
holds every whole number up to 2^53, so an address and a word are
exact.

- **Constants** are decimal, such as `5`, `-0.25`, `.5`, `5.`, and
  `1E3`, `1.5E-3`, or `2e+10`, or hex after `0x`, such as `0x1F`,
  which is a signed word, so `0xFFFFFFFF` is -1. A decimal constant
  keeps 16 significant digits, and the 17th rounds the 16th. A letter,
  a digit, or a point right after a constant is a `Syntax error`, and
  one too large for a double an `Overflow`. A constant too small for
  one is 0.
- **The operators**, from the one that binds most: the signs `-` and
  `+`; `*`, `/`, `DIV`, and `MOD`; `+` and `-`; `<<` and `>>`; the
  comparisons `=`, `<>`, `<`, `>`, `<=`, and `>=`; `NOT`; `AND`; and
  `OR` and `XOR`. Those of one level group to the left, and
  parentheses group as they do in arithmetic. `/` divides as doubles
  do, so `PRINT 1/3` prints `0.333333333333333`.
- **The word operators**, `DIV`, `MOD`, `AND`, `OR`, `XOR`, `NOT`,
  `<<`, and `>>`, take their operands rounded toward zero, and each
  must fit a signed word, or it is an `Illegal quantity`. `DIV` and
  `MOD` divide toward zero, and `MOD` has the sign of its left
  operand. `>>` shifts 0 in, and a shift by 32 or more gives 0.
- **A comparison** gives -1 when it holds, and 0 when not, so `NOT`,
  `AND`, and `OR` join comparisons, as in `A > 0 AND A < 10`.
- **The functions** are `ABS(X)`, `SGN(X)`, -1, 0, or 1, `INT(X)`,
  rounded down, so `INT(-2.5)` is -3, `SQR(X)`, the square root, and
  `PEEK(A)`, the word at the address `A`, as a signed word.
- **A variable** has a name of up to 16 letters and digits, the first
  a letter, every one significant, in either case, so `Total` and
  `TOTAL` are one variable. A keyword is no name, but a name may start
  with one, as `TOTAL` starts with `TO`. A `%` or a `$` after a name
  is a `Syntax error`, as strings and whole numbers come later. An
  assignment, `INPUT`, and `GET` make the variable in a line typed,
  and a line of a program makes each of its names. A variable that
  none of them set is an `Undefined variable`. A variable is its
  double and its name, 4 to 7 words, after the program's lines (Programs
  below). When the variables and the arrays reach the frames below
  `HIMEM`, a variable more is `Out of memory`. `CLR` and `RUN` clear
  them, and `NEW` drops them.
- **`PRINT`** shows a number as C's `%.15G` does: its first 15
  significant digits, with the trailing zeros dropped, in fixed
  notation while the number is from 1E-4 to below 1E15, with a 0
  before the point, and else in E notation, with a sign and at least
  two digits in the exponent. So `1/3` is `0.333333333333333`, `0.1 +
  0.2` is `0.3`, `1E15` is `1E+15`, and `0.00001` is `1E-05`. A
  negative number has its `-`, -0 is `0`, and no blank comes before or
  after a number.

An expression's errors are `Division by zero`, of `/`, `DIV`, and
`MOD`; `Overflow`, a result too large for a double; `Illegal
quantity`, such as `SQR(-1)` or a word operator's operand that does
not fit; and `Formula too complex`, more than 16 values that wait for
the FPU, or parentheses and signs nested too deep for the stack. A
program never sees an infinity or a NaN.

## Programs

A line that starts with a number, 0 to 65535, is kept as a line of the
program, in the order of the numbers, and replaces the line of that
number; a number alone deletes its line. `LIST` shows the lines, and
`RUN` runs them, from the first. The line is tokenized as it is
entered, so a `Syntax error` of a constant or a name comes then, with
no line kept, and the other errors when the line runs, as `Syntax
error in 20`, with the number of the line, after which the program
stops. A program pasted into the line is entered line by line. An edit
keeps the variables, but `CONT` cannot go on after it.

| Statement | What it does |
|---|---|
| `RUN [N]` | Runs the program, from line `N` or from its first, after a `CLR`. |
| `RUN "NAME" [, "IP"]` | Loads `NAME` as `LOAD "NAME"` does, from the card or from the TFTP server at `IP`, and runs it: a BASIC program as `RUN` runs it, and a `.bin` file as `SYS 0x8000` calls it, so `RUN "CHESS.BIN"` starts nice_chess. A program may load and run the next this way. A file that is not there, or that has no line, runs nothing. |
| `LIST [N] [- [M]]` | Lists the lines from `N` to `M`: `LIST 100`, `LIST 100-200`, `LIST -200`, and `LIST 100-`. The keywords are in upper case, with a blank between two tokens, but before `)`, `,`, `;`, and `:`, after `(` and a sign, and between a function or an array and its `(`. A constant is shown as `PRINT` shows it, and a hex one in hex. CTRL-C stops it. |
| `NEW` | Deletes the program and its variables and arrays. |
| `DELETE N [- M]` | Deletes the lines from `N` to `M`, as `LIST` takes them: `DELETE 100`, `DELETE 100-200`, `DELETE -200`, and `DELETE 100-`. `DELETE` with a string deletes a file instead (Files above). |
| `RENUMBER [N] [, S]` | Numbers the lines from `N`, by `S`, 10 and 10 when not given, and changes the line numbers after `GOTO`, `GOSUB`, `RUN`, `THEN`, and `ELSE` with them. A number of no line is kept. When the last line would be past 65535, or `S` is 0, it is an `Illegal quantity`, and nothing changes. |
| `AUTO [N] [, S]` | Types the number of each line before it: `N` first, then that of the line stored last plus `S`, 10 and 10 when not given. A line with nothing after its number ends `AUTO` and deletes no line, and so does CTRL-C, an empty line, a statement typed with no number, and an error. |
| `CLR` | Clears the variables, drops the arrays, and ends the loops and subroutines. |
| `GOTO N` | Goes on at line `N`. |
| `GOSUB N`, `RETURN` | Goes on at line `N`, and after the `GOSUB` at `RETURN`. |
| `IF X THEN S [ELSE T]` | Runs the statements `S` when `X` is not 0, else `T`. A line number after `THEN` or `ELSE` is a `GOTO`, and `IF X GOTO N` is one too. `ELSE` belongs to the last `IF` before it that has none, and the statements after `S` and `T` are theirs, up to the end of the line. |
| `FOR V = X TO Y [STEP Z]`, `NEXT [V] [, W]` | Runs the statements up to `NEXT` with `V` from `X` to `Y`, by `Z` or by 1. The body runs once at least, as in Microsoft's BASIC. `NEXT` with no name ends the last loop, and `NEXT I, J` two. A `FOR` of a variable that has a loop ends that loop and those after it. |
| `END`, `STOP` | Ends the program. `STOP` prints `Break in 20`, and `END` nothing. |
| `CONT` | Goes on after `STOP`, `END`, and the break key, unless the program was edited or an error came since: then it is `Can't continue`. |
| `REM TEXT` | A remark, the rest of the line, which `LIST` shows as it was typed. |
| `INPUT ["P";] V [, W]` | Prints `? `, or `P` and `? `, and reads numbers into `V` and `W`, with commas between them. A line that is not numbers is `Redo from start`, and `INPUT` asks again. Too few ask for the rest with `?? `, and too many print `Extra ignored`. A number may have a sign; an expression is not taken. CTRL-C is the break key. |
| `GET V` | Sets `V` to the code of the next key typed, or 0 when there is none. It does not wait. |
| `DIM A(N) [, B(N, M)]` | Makes the array `A` of `N + 1` elements, `A(0)` to `A(N)`, and `B` of `N + 1` rows of `M + 1`, each element 0. `A` and `A(` are two names. An array that no `DIM` made is `Undefined array`, a subscript outside or one too many or too few `Bad subscript`, and a second `DIM` `Redimensioned array`. |
| `HIMEM = A` | Sets the top of BASIC's memory, and does a `CLR`. `HIMEM` in an expression reads it, such as `PRINT HIMEM`. |

CTRL-C is the break key. A program polls it every 64 statements, and
stops with `Break in 20`, after which `CONT` goes on. `GOTO` and
`GOSUB` take a line number, which keeps the address of its line once
it is found, and is no expression. A loop and a subroutine take a
frame each, 8 and 3 words, of the 512 words below `HIMEM`, so a
`GOSUB` that never returns is `Out of memory` after 170 of them. The
errors of the programs are `Undefined line`, `NEXT without FOR`,
`RETURN without GOSUB`, `Can't continue`, `Undefined array`, `Bad
subscript`, and `Redimensioned array`.

The program's lines start at `0x8000`, a word for each token and
constant, and the variables follow them, then the arrays, each element
a double, and the frames. `HIMEM` is the top of them, by default the
top of the RAM less the room of BASIC's RAM and its stack, so that a
routine that `SYS` calls may live above a lower `HIMEM`, as in BBC
BASIC. A `HIMEM` below the end of the arrays and the frames' room, or
above the top of the RAM, is `Out of memory`. An empty program writes
no word at `0x8000`, so after `NEW` a `.bin` program there stays as it
was.

## The disassembler

`DIS` shows each instruction as nice_cpu's `assembler/nicedis.py` and
`mon.py` do, so the three disassemblers agree, but for the
pseudo-instructions below, which only `DIS` shows:

    DIS 0x8000, 5
    00008000 0077580f 00000002 0003d800 00008123  CALL 0x8123
    00008004 0003f680                             RET
    00008005 022000b0 00000020                    CMP R1, 0x20
    00008007 3003d800 00008000                    ?Z JMP 0x8000
    00008009 3c400007                             ?Z INT 7

- The text has the condition, the mnemonic with `[C]` and `[M]`, the
  SHIFT aliases, such as `SHL` and `ROR`, and the operands in the syntax
  of [nice_cpu's ISA.md §10.2](https://github.com/MJoergen/nice_cpu/blob/main/doc/ISA.md#102-operands). Constants are in lower-case hex without
  leading zeros, and INT's vector is in decimal.
- A reserved control word, and an instruction with a field that its
  mnemonic does not use and that is not R0, are a `.DAT` of their words,
  with what they would do as a comment, as nicedis.py writes them:
  `.DAT 0x00000001 ; MOVE R0, R0 (s1: R1)`.
- `ADD @--R13, n, R15` followed by `MOVE R15, target`, where `n` is the
  number of words of the `MOVE`, is one row, `CALL target`, and
  `MOVE R15, @R13++` is `RET`: pseudo-instructions of [ISA.md §10.1](https://github.com/MJoergen/nice_cpu/blob/main/doc/ISA.md#101-statements),
  which `niceasm` assembles back to the same words. A condition applies
  to both instructions of a `CALL`, so the two must have the same one,
  as in `?Z CALL 0x8123`. A pair with two conditions, an `ADD` with a
  modifier, an `n` that is not the length of the `MOVE`, or a `MOVE`
  with a modifier, is two rows.
- The other pseudo-instructions of §10.1 are one instruction each, and
  are shown in its place. Some words match two of them, and the first
  that matches, in this order, is shown:

  | Words | Shown as |
  |---|---|
  | `MOVE R0, R0`, the word 0, also of empty RAM | `NOP`, not `CLR R0` |
  | `MOVE R15, @R13++` | `RET`, not `POP R15` or `JMP @R13++` |
  | `ADD @--R13, n, R15` and `MOVE R15, target` | `CALL target`, whose `MOVE` is no `JMP` |
  | `MOVE R15, target` | `JMP target`, so `MOVE R15, R0` is `JMP R0`, not `CLR R15` |
  | `MOVE @--R13, x` | `PUSH x`, so `MOVE @--R13, R0` is `PUSH R0` |
  | `MOVE x, @R13++` | `POP x` |
  | `MOVE x, R0` | `CLR x` |
  | `MOVE[M] R0, a` | `TST a` |
  | `SUB[M] R0, a, b` | `CMP a, b` |

  As with `CALL` and `RET`, a condition is shown, as in `?Z JMP 0x8000`,
  and any other modifier makes the plain instruction: `MOVE[C] R15, R1`
  and `SUB[CM] R0, R1, R2` stay as they are, and so do `MOVE[M]` and
  `SUB[M]` with a dest that is not R0. A field that the `MOVE` does not
  use and that is not R0 makes a `.DAT`, as before. `niceasm` assembles
  each back to the same word. nicedis.py and `mon.py`, and the
  debugger's decode of row 27, show the plain instructions.
- An instruction of 4 words, with constants in all three fields, has a
  text longer than the 34 columns left, and goes on in the next row of
  the screen.

## Loading without a host

`LOAD` with no name loads a program that is typed on the keyboard, or pasted into a
terminal on the line, with no tools on the host and no storage. It reads
lines of `ADDR WORD`, two hex numbers of 1 to 8 digits with blanks or
tabs between them, which is what a `.bin` file has ([nice_cpu's ISA.md
§10.4](https://github.com/MJoergen/nice_cpu/blob/main/doc/ISA.md#104-object-format)), and writes each word. CR, LF, and CR LF end a line, the `LOAD`
line itself too. An empty line ends the load, and so does CTRL-C, which
drops the line it is in; a line of blanks only is passed over, as
`niceemu` passes it. DEL and backspace delete, and the cursor and
function keys do nothing. A line keeps 76 characters: blanks after them
are dropped, as `niceemu` ignores them, and anything else after them
skips the line. A line with anything else, or one with an address
outside a program's RAM, `0x8000` to `0x1E7FF` on the MEGA65 and to
`0xE7FF` on the Nexys4DDR ([Programs](../monitor/README.md#programs)), is skipped: the RAM repeats through the address space, so a
larger address could reach the ROM, the variables, or the stack. The top of that range is the stack itself, which `SYS` uses, so a
program's words stay below it. A second line for an address writes its
word over the first's, where `niceemu` rejects the file. In `niceemu`,
where `0xFFFFFF9E` reads 0, the program's RAM goes up to the screen,
`0xFFFEFFFF`. Its font RAM at `0xFFFE0000`–`0xFFFE1FFF` keeps
only bits 15..0 of a word, and its character ROM at
`0xFFFE2000`–`0xFFFE3FFF` drops one, so a program there does not read
back as loaded. At the end `LOAD` prints the number of words written, with
the lowest and the highest address, and the number of lines skipped,
with the first of them and the last address that a line may have:

    Words loaded: 601, 00008000 to 00009000
    Lines skipped: 4, first line 2; ADDR WORD in hex, ADDR 00008000 to 0001E7FF

The lines are shown in one row of the screen, which each line clears,
and not on the line, so the screen does not scroll, and a paste over the
UART at 2 Mbaud keeps up: a line takes about 1400 instructions, and
arrives in about 90 µs. On the R6, 20600 lines pasted at full speed, in
LF lines and in CR LF lines, were all written, with no byte lost.

Over Ethernet, a paste into a plain client, such as
`nc 192.168.1.65 4510`, keeps up too. The station takes the host's
bytes at 100 Mbit/s, faster than `LOAD` reads them, but a byte that finds
the core's input FIFO of 2048 bytes full waits up to 50 ms for room,
and TCP holds the host back meanwhile. A byte is lost, with the link's
`o`, only when the program reads nothing for 50 ms. On the R6, 20600
lines pasted at full speed over TCP, in LF lines and in CR LF lines,
and through `nc`, were all written, with no byte lost, in about 0.7 s.
`load.py --eth 192.168.1.65 --monitor prog.bin` ([Remote control](../monitor/README.md#remote-control))
is faster, as it writes the words into the memory.

## Building

`make -C basic` builds BASIC's image, `build/basic_image.bin`, and
`make rom` at the top joins it with the monitor's into the ROM,
`build/rom.bin` ([rom.mk](../rom.mk)). Both write the image as a file
for a card too, `build/basic.rom`
([doc/BASIC_ROM.md](../doc/BASIC_ROM.md), #153). The image is the cat of
`basic.nasm`, `basic_expr.nasm`, `basic_cmd.nasm`, `basic_net.nasm`,
`basic_time.nasm`,
and `basic_dis.nasm`, BASIC's copies of the monitor's `common.nasm`,
`monlib.nasm`, and `mon.nasm`, the version, and the texts with the
card's folder. `basic.nasm`'s header says what each file has, and
"Its words" below has the words of each.

The image starts with its header, after the two vectors: a magic word,
the interface, the length, a checksum, the address of the version
text, the version as a number, the flags, and the words of BASIC's
RAM ([doc/BASIC_ROM.md](../doc/BASIC_ROM.md#the-image)). The assembler
writes `build/basic_asm.bin`, with 0 for the length, the checksum, the
version as a number, and the flags, and `../tools/basic_rom.py fill`
fills them in. The tests' image has the flag "keep", and the version
`V9.9`, `0x09090000`. `tools/basic_rom.py check FILE` checks an image,
and prints its header. It takes the file's lines as the monitor takes
them from a card, so a file that passes is not refused there for its
lines: each is an address and a word of 1 to 8 hex digits, with
blanks or TABs around them, in at most 76 characters, and the
header's 12 words, `0x3000` to `0x300B`, each have a line, also one
that is 0. After the header, a word with no line is 0. Only the
monitor knows whether the image's interface is its own.

To try a build on the board, copy `build/basic.rom` to a card's folder
as a `BASIC*.ROM` file, which the monitor loads when the board is
switched on ([README.md](../README.md#a-new-basic)), or put it into the
ROM at once with `make load FILE=basic/build/basic.rom ETH=IP
ARGS=--basic` ([tools/README.md](../tools/README.md#loading-basic-into-the-rom)).

## Testing

`make -C basic test` runs the tests of BASIC's statements in `niceemu`,
with no board, on the ROM of the tests, `../build/rom_test.bin`, which
has the version `V9.9`. The tests of the monitor's code are those of
`make -C monitor test` ([monitor/INTERNALS.md](../monitor/INTERNALS.md#the-tests)),
which builds what these share with them: `hello.bin`, the cards'
images, and the scripts of `monitor/test`. The test needs `FOLDER=NICE`,
the default. It runs these steps in order:

1. **The layout.** nice_cpu's `nicefmt` checks the sources and
   `test/dis.nasm`.
2. **The disassembler.** `test/dis.py` runs `DIS` over `test/dis.nasm`,
   which has every opcode, operand mode, condition, and modifier, the
   control instructions, the reserved words, and each pseudo-instruction
   with its near-misses. It compares each row with the text of
   `nicedis.py`, rewritten by the rules of "The disassembler" above,
   for a pseudo-instruction. It assembles each row again
   and compares the words.
3. **The numbers.** `test/print_numbers.py` types `?` with 515
   numbers: 510 from a fixed seed, constants of 1 to 20 significant
   digits, with a point, an exponent, or neither, from 1E-300 to
   1E300; `+`, `-`, `*`, and `/` of two of them, with signs; the word
   operators on signed words; the comparisons; and the functions. Five
   more are fixed, those whose last digit was wrong while the FPU's
   `DIGITS` rounded twice
   ([nice_cpu#200](https://github.com/MJoergen/nice_cpu/issues/200)).
   What `PRINT` shows must be Python's double of the number, as
   `%.15G` writes it, digit for digit.
4. **NTP.** `test/ntp.py` types `NTP` and `DHCP` with `--step-time`,
   and learns the frames of each run as the monitor's `test/dns.py`
   does, with the frames of DHCP and DNS of the monitor's
   `test/dhcp.py` and `test/dns.py`. DHCP gives the DNS server and an
   NTP server in option 42. It covers no IP address, DHCP's server, a
   server by name and by address, an offset east and west, a time of
   era 1, datagrams that are passed over, a kiss-o'-death, a leap
   indicator of 3, a stratum of 16, a time before 1970, no answer, an
   answer to the second send, no such name, and offsets that are not.
   It covers the edges of the eras too: the last second of era 0
   before 1970, and the last second of era 1 that the clock takes, and
   the next; the largest offsets east and west, and a clock 0 s off.
   It compares the output and the frames sent with `test/ntp.expected`,
   with a query's port as `pp` and its transmit timestamp as `tt`. It
   runs on an I2C master that is present and never busy, as the
   monitor's `test/rtc.py` has it, and checks that `NTP` writes the
   real-time clock: the master's last command is the cold start's read
   while no time is set, and the write of the chip's status after the
   times of the run.
5. **TFTP.** `test/tftp.py` runs `LOAD` and `DIR` from a TFTP server
   the same way, against `test/tftp.expected`. It covers a file of two
   blocks among packets of other hosts and ports, lost packets, an
   ERROR, an ERROR after the first block, whose summary comes first,
   files of 512 and 0 bytes, a listing, with names that have bytes
   that are not printable ASCII, which are dropped, and a line of more
   than 77 characters, a port given as `"IP:PORT"`,
   a BASIC program's text, listed and run, one with a line without a
   number, bad arguments, and no answer to ARP.
6. **The benchmarks.** `test/bench.py` types Rugg/Feldman's
   benchmarks 1 to 7 and the sieve, in `bench/`, and checks their
   output. Their steps, which it prints, are those of the instruction
   counter, read by `PEEK` before and after `RUN`, less those of an
   empty program. `make -C basic bench` prints them as the rows of the
   table in [doc/BASIC.md](../doc/BASIC.md#the-benchmarks).
7. **The runs.** The ROM runs once for each test below, with its
   keystrokes from an input file that ends with `HALT`, so that the run
   halts. Each run's console output, a few memory words, and the screen
   are compared with `test/NAME.expected`:

| Test | What runs | What it checks |
|---|---|---|
| `cmds` | The ROM alone | Every statement, its bad arguments, keywords in either case, numbers that do not fit, and the edits of a line. |
| `basic` | The ROM alone, with no card and no IP address | The scanner of a statement: keywords glued to a letter or a digit, which are names, the HELP lines of each statement's Syntax error, numbers at the limits of a signed word, `0x` without digits, which is no number, a name in a number's place, strings without a closing quote, too few or too many arguments, and the tokens of a line, with the 0 after each string, which `SAVE` leaves as they were. |
| `expr` | The ROM alone | The numbers: the operators and their order, the word operators, the comparisons, the functions, the constants, `PRINT`'s format and its items, the variables, `LET`, the colons, the errors, the depth of an expression, `PEEK` and `POKE`, a statement with expressions, a `LOAD` that writes no word, a broken table of variables, and `Out of memory`. |
| `prog` | The ROM alone, with `test/prog.bas` typed | The lines: their entry, edits, and deletion, the numbers at the limits, `LIST` and its blanks, `RUN`, `NEW`, the variables an edit keeps, the tokens in memory, `FOR` with steps, nested, and once, `GOSUB` in loops, `IF` with `ELSE`, nested, `STOP`, `END`, `CONT`, and the errors in a program, with its line's number. |
| `edit` | The ROM alone | The screen editor: a listed line changed and entered again, a line that grows into the row below, `INPUT`'s answer after its prompt, DEL in the middle and at the prompt, a line of two rows entered from its first row, CTRL-C, and the cursor key down at the last row. The screen at the end is compared too. |
| `lines` | The ROM alone | `DELETE` of a range, a line, and up to a line, `RENUMBER` with the jumps forward and back, a target that is no line, the overflow and a step of 0, and `AUTO`, ended by a number alone and by CTRL-C. |
| `redo` | The ROM alone | The check at entry: a line of two rows that the tokenizer refuses is shown again after `READY.`, with the cursor at the error, as the input ends there and no key waits; it runs until the step limit. |
| `keys` | The ROM alone | `INPUT` with too few, too many, and bad numbers, a prompt, and CTRL-C; `GET`; the break key in a loop, in `CONT`, and in `LIST`; and the keys typed ahead, of which the ring keeps 31. |
| `arr` | The ROM alone, with `test/arr.bas` typed | `DIM`, the elements, their errors, `LET`, `INPUT`, and `GET` of an element, `CLR` and an edit with arrays, `HIMEM` read and set, too low and too high, the layout of an array in memory, and `LOAD` below and above `HIMEM`, in a line and in a program. |
| `load` | The ROM, with 128K words of RAM, as on the MEGA65 | `LOAD` with the monitor's `build/hello.bin` pasted: CR LF and LF line ends, tabs, blank lines, skipped lines, a line too long, blanks after a line's 76 characters, a DEL that takes back the key after them, an address given twice, and CTRL-C. Then `SYS 0x8000` runs it. |
| `load_64k` | The ROM, with 64K words, as on the Nexys4DDR | `LOAD` at the end of that RAM. |
| `load_emu` | The ROM, with `0xFFFFFF9E` reading 0, as in `niceemu` | `LOAD` up to the screen. |
| `files` | The ROM, with `--step-time` and a copy of the card without partitions, with the files of `test/files_card.py`, and `test/files.in` typed | `SAVE "NAME"` and `LOAD "NAME"` of a program with each kind of token, and `RUN "NAME"`; a file written on a PC, with CR LF, lower case, a TAB, and lines of blanks; the lines that end a load: one without a number, one with too many tokens, one too long, and one with a byte from `0x80`, with the lines before them kept; a file that is not there, which keeps the program; a name with a dot, an empty program, `RUN "HELLO.BIN"`, and a program that runs the next. Its output ends with `fsck.fat` on the card, and the files that it wrote, as `od -c` shows them. |
| `time` | The ROM, with `--step-time` and a copy of the card without partitions | `TIME` not set, set, and shown; dates that are not, such as leap days of years without one, fields of one digit, month 0, day 0, letters, wrong separators, and 2106, and the clock left alone after them; the edges that are, 2000-02-29, 2100-03-01, 2104-02-29, 2^31 seconds, 2105-12-31, the last day of a leap year, and blanks in the quotes; and the dates of `SAVE`, from the clock and while it is not set or before 1980, which `mdir` shows. |

`time` runs with `--step-time`, so that the clock starts at 0, not
set, and counts the same each time, and the files that it writes while
the clock is not set have the fixed date, 2026-01-01 at 00:00:00. It
writes to a fresh copy of the monitor's `super.img`, and its output ends
with what the card holds that the image did not, from the monitor's
`test/fat_tool.py diff`, with the times as `**`, as the clock's seconds
count steps, and the order of the sector writes, from a second run with
`-t` and `test/fat_tool.py order`.

The comments above each input in the Makefile say what each keystroke
tests. The expected files were checked by hand: after a change that
alters an expected output, check the new output the same way before you
copy it from `build/` to `test/`. `cmds` shows the addresses of the
dispatch table, which change with the monitor's code.

## Its words

BASIC's image is at `0x3000`–`0x7FFF`, 20480 words, of which the
table of the ROM in [monitor/INTERNALS.md](../monitor/INTERNALS.md#the-roms-words)
has those in use and those free. These are its words, by the source
they come from, in the order that the Makefile joins them. The column
"Text" counts the words of the texts, which are part of "Words", packed
four characters a word with `.ASCII_B`. `common.nasm`, `monlib.nasm`,
and `mon.nasm` are BASIC's copies of the monitor's files, and the
version is that of the tests, `V9.9`. `make -C monitor test` checks the
table, and `make romsize` writes it again.

<!-- romsize basic -->
| Source | What it is | Words | Text |
|---|---|---:|---:|
| `basic.nasm` | The vectors, the header, the main loop, the scanner, the keywords, the messages, and the help | 1485 | 904 |
| `basic_expr.nasm` | The numbers: the tokenizer, the expressions, the variables, the errors, `PRINT`, `LET`, and `POKE` | 1556 | 39 |
| `basic_prog.nasm` | The programs: the lines, `LIST`, `RUN`, the jumps, the loops, the break key, `INPUT`, `GET`, the arrays, and `HIMEM` | 1851 | 46 |
| `basic_cmd.nasm` | The routines of the statements that were the commands | 1839 | 294 |
| `basic_net.nasm` | `DHCP`, `NTP`, and TFTP | 917 | 150 |
| `basic_time.nasm` | `TIME`, and the clock's side of `NTP` | 275 | 44 |
| `basic_dis.nasm` | The disassembler of `DIS` | 871 | 79 |
| `basic_edit.nasm` | The screen editor | 1104 | 0 |
| `common.nasm` | What the monitor and BASIC share: texts, IP addresses, and dates | 237 | 5 |
| `monlib.nasm` | The routines that programs join | 274 | 0 |
| `mon.nasm` | The stubs of the entries | 92 | 0 |
| `build/basic_folder.nasm` | The texts with the folder's name: `DIR`'s, and the error of a card without it | 14 | 14 |
| `build/version_test.nasm` | The version in the banner, the tests' `V9.9` | 2 | 2 |
| In all | | 10517 | 1577 |
<!-- /romsize basic -->
