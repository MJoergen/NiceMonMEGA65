# BASIC

- [The statements](#the-statements)
- [Numbers](#numbers)
- [Programs](#programs)
- [How listings look](#how-listings-look)
- [Errors in a program](#errors-in-a-program)
- [Strings](#strings)
- [The screen and the time](#the-screen-and-the-time)
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
BASIC keeps and runs (Programs below), stage 5 (issue #116) the
strings (Strings below), and stage 8 (issue #119) the structure:
`ON`, the functions and procedures of `DEF FN` and `DEF PROC`, with
`LOCAL`, `DO` and `LOOP`, and the block `IF` (Programs below).

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
or `DUMP A + 4, 2`, or a string, which is a string expression of up
to 80 characters (Strings below), such as `LOAD "HELLO.BIN"` or
`LOAD N$ + ".BIN"`. A string that the line ends without its closing
quote ends with the line. A number for an address, a count, or a word
must fit a signed word, -2147483648 to 2147483647, and is rounded
toward zero, so `SYS 0xFFFF0000` and `SYS -65536` are the same, and
`SYS 4294901760` is an `Illegal quantity`. An address from
`0x80000000` up is a negative number.

A line that is no statement prints `Syntax error` and the lines of
`HELP` of its statement, or `Syntax error; HELP lists the statements`
when it starts with no keyword. A keyword where a variable's name
goes is named, as in `Syntax error; TI is a keyword in 10` for `10 TI =
5` or `10 FOR TI = 1 TO 2`: a name that is a keyword cannot be a
variable. The other errors print their message,
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
one line too. A key typed into a line of 254 characters does nothing.
The blanks before a line's number, and all but one after it, do not
count, so the indent of `LIST` (How listings look below) takes no room.
`LIST` may show a line with more, as it writes `?` as `PRINT` and adds
blanks: RETURN on such a line is `Line too long`, and the line stays
as it was stored. A shorter line is `Line too long` as well when it
has too many tokens. BASIC keeps a line as tokens, 160 words of them
at most: a word for each keyword, name, operator, and whole number
up to 16777215, two to five for another number, and one for each
character of a string or of `REM`'s text. So a line of short tokens
with no blanks, such as `A=1+1+1+1`, is too long from 154 characters.
When a line grows into a row that holds other text,
that row and those below it move down. At `INPUT` the answer starts
after the prompt. There is no INST key and no quote mode.

RETURN takes what the screen shows, so the row that a line starts on
must not hold text from before. After `READY.`, after `INPUT`'s
prompt, and after `AUTO`'s number, BASIC blanks the rest of the row,
so what a program, a `POKE`, or an older line left there is no part
of the line. Only after a line that was stored does the next row keep
its text: it is the next line of a listing, and RETURN enters it
again.

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
of the screen, 27 rows at a time. On the MEGA65 Page Up and Page Down
are CTRL and MEGA with CRSR↑ and CRSR↓. CRSR↑ at the top row scrolls
back one row (issue #173). While the rows are shown, CRSR↑ goes one row
further back, and CRSR↓ one row forward, up to the screen again, with
the cursor where it was. Any other key shows the screen again, and goes
on to the line. The history has 381 rows on
the MEGA65 and 74 on the Nexys4DDR. `CLS` leaves it, as `clear` in a
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
| `DUMP [A] [, N]` | Shows `N` words from `A`, 4 to a row with the row's address first, all in hex. Without `A`, the words after the last shown; without `N`, 32 words. The address and the words have colors of their own (How listings look below). |
| `DIS [A] [, N]` | Disassembles `N` instructions from `A`, a row each: the address, the instruction's 1 to 4 words, and its text, all in hex (The disassembler below). Without `A`, the instructions after the last shown; without `N`, 20. The address, the numbers, and the registers have colors of their own (How listings look below). |
| `CLS` | Clears the screen. |
| `VER` | The versions of the monitor and of BASIC, and of the dispatch table: `NiceMon V2.5.1, BASIC V2.5.1, dispatch table 1.8`. |
| `IP ["A.B.C.D"]` | Shows the Ethernet station's IP address, `IP address 192.168.1.65`, or writes it first: four decimal numbers of 0 to 255 with dots between them, such as `IP "192.168.1.65"`. Anything else is no address, and `IP` says so and writes nothing. It sets the address with `net_set`, with no mask, no gateway, and no DNS server, and writes `0xFFFFFFB0`, `NET_IP` ([SYSTEM.md](../doc/SYSTEM.md#the-ethernet-station)), when the address is another, so a host connected over TCP loses its connection; the same address again changes nothing there. In `niceemu` it is a register that keeps what is written. |
| `DHCP` | Gets the IP address from the network's DHCP server and writes it, as `IP` does, then shows it, with the mask, the gateway, the DNS server, the DHCP server, and the NTP server, if it gives one, a line each ([The network](../monitor/README.md#the-network)). Without an answer, it prints `No answer from a DHCP server` after about 8 seconds, and leaves the address as it was. |
| `MAC ["MAC"]` | Shows the station's MAC address, `MAC address 02:4E:49:43:45:06`, or writes it first: six bytes of one or two hex digits, in either case, with colons between them, such as `MAC "02:4E:49:43:45:01"`. The first byte must be even, as an odd one makes a group address. Anything else, an empty string too, is no address, and `MAC` says so and writes nothing. It writes `0xFFFFFFB1` and `B2`, so a host connected over TCP loses its connection. Each kind of board has its own after reset: `02:4E:49:43:45:03` on the R3, `02:4E:49:43:45:06` on the R6, and `02:4E:49:43:45:0A` on the Nexys4DDR. Two boards of the same kind on one network need different MAC addresses. In `niceemu` they are registers too, `02:4E:49:43:45:00` after reset. |
| `TIME ["YYYY-MM-DD HH:MM:SS"]` | Shows the clock of the time of day, `2026-11-11 14:30:00`, or sets it first to the date and the time given, two digits for each part but the year, in the years 1970 to 2105, such as `TIME "2026-11-11 14:30:00"`. The clock keeps local time, as the MEGA65's real-time clock does, and knows no time zones. After a reset of the system it is not set. The cold start sets it from the MEGA65's real-time clock, unless the real-time clock lost its time ([SYSTEM.md](../doc/SYSTEM.md#the-i2c-bus)), and leaves a clock that is set already. On the MEGA65, `TIME` with a date and a time in the years 2000 to 2099 sets the real-time clock too, so that later starts, and the MEGA65's other cores, have the time. Until the clock is set, as on the Nexys4DDR, which has no real-time clock, `TIME` prints `Clock not set`; a program, a host, `TIME`, or `NTP` sets it. A start of a program keeps it. Anything else is no time, and `TIME` says so and sets nothing. A clock that a program set past 2106-02-07 shows as `Clock past 2106`. In `niceemu` the clock is the host's time in UTC from the start. |
| `NTP ["SERVER"] [, "+HH:MM"]` | Sets the clock from a time server on the network, and on the MEGA65 the real-time clock too, as `TIME` with a date does, and shows the time it set, the server, and how far the clock was off, such as `Clock set 2026-11-14 12:30:05 from 192.168.1.1, was 7 s behind`. SERVER is a name, such as `"pool.ntp.org"`, or an IP address. Without it, or with `""`, the server is the NTP server that `DHCP` got, or else `pool.ntp.org`. A time server gives UTC, and the clock keeps local time, so the offset is local time less UTC, `"+HH:MM"` or `"-HH:MM"` from `-12:00` to `+14:00`, such as `NTP "", "+01:00"` for Central European Time and `"+02:00"` for its summer time; without it the clock is set to UTC. It needs an IP address, and for a name a DNS server, from `DHCP`. Its errors are a line each: no IP address, no answer to ARP from the server or the gateway, no DNS server, no such name, an error of the DNS server, no answer from the DNS server or the time server after 3 tries of 2 seconds, a server that refused, and an answer that is not to be trusted ([The network](../monitor/README.md#the-network)). |
| `BAUD [RATE]` | Shows the UART's baud rate, `Baud rate 230400`, or writes it first: 115200, 230400, 460800, 921600, 1000000, 1500000, or 2000000, such as `BAUD 921600`. Anything else is no rate, and `BAUD` says so and writes nothing. It writes `0xFFFFFF9F` ([DEBUG_LINK.md](../doc/DEBUG_LINK.md#the-baud-rate)), as the on-board debugger's settings page does. The UART takes the new rate once it has sent nothing for 1 ms, so the answer and `READY.` still come at the old rate, and a terminal on the UART then changes to the new one; only a reset brings back 230400. Over Ethernet the rate does not matter. In `niceemu` the word is memory, which reads 0 after a clear. |
| `LOAD` | Enters words into the RAM from lines of `ADDR WORD` in hex, as a `.bin` file has them (Loading without a host below), up to an empty line, and prints the words written and the lines skipped: `Words loaded: 600, 00008000 to 00008257`. A `LOAD` that writes a word below `HIMEM` (Programs below) may write over BASIC's program and its variables, so it ends with a `NEW`, and at `READY.`, also in a program. One that writes above `HIMEM` alone keeps them, and the line goes on, so that a program may load a routine of machine code there and call it with `SYS` (Machine code beside a program below). One that writes no word ends the line. |
| `DIR [SLOT]` | Lists the folder `NICE` of the SD card's FAT32 file system ([Files](../monitor/README.md#files)): `Directory of NICE in slot 0`, with the slot of the card mounted, then a row for each file, its name in 24 columns, the long name where it has one or else the 8.3 name, and its size in decimal, and for each directory, its name and `<DIR>`, then `Files: 25, directories: 1`. A name of 24 characters or more has a row of its own, and the size is on the next. With `SLOT`, it mounts the card in it first, and a slot that the board does not have is `File error 27`; without, it lists the card mounted, which the first `DIR` or `LOAD` after reset mounts. `LOAD`, `SAVE`, `BSAVE`, `DELETE`, and `RUN` of a file take a `SLOT` too, as their last argument, a number, and mount it the same way. The slot stays mounted for the statements after it, also when its card fails, until another `SLOT` or a reset. It reads the folder through a handle, as a program does, so after a program that left both handles open it is `File error 23`, as `LOAD` and `SAVE` are; `DIR 0` mounts again, which closes them. An error is shown with its number and meaning: `File error 18, FAT16, which is not supported`. |
| `DIR "PATH"` | Lists a folder inside `NICE` by its path, such as `DIR "GAMES"` or `DIR "GAMES/OLD"`, as `DIR` lists `NICE`, with the path in its first row: `Directory of NICE/GAMES in slot 0`. A leading `/` is `NICE` itself, and a `/` at the end is taken, as TAB puts one after a directory. A string that is an IP address, with `:PORT` or not, or that has a pattern after it, is a TFTP server's (`DIR "IP"` below), so a folder whose name is an IP address, such as `10.0.0.1`, cannot be listed. A folder that is not there is `File error 21`, and a file is `File error 22`. |
| `LOAD "NAME.BIN" [, SLOT]` | Loads the `.bin` file `NAME.BIN` of the card's folder `NICE` as `LOAD` loads lines, and prints the same summary, so a program copied to the card on a PC loads with no host. Unlike the lines typed, an empty line is passed over, the end of the file ends the load, and a skipped line is counted from the first line of the file. A line with a byte that is not printable ASCII, a control code other than TAB, CR, or LF, DEL, or a byte from `0x80`, is skipped, as `niceemu` rejects it, so that no byte is dropped from the middle of a number. An error in the middle of the file, such as `File error 26, the FAT is damaged`, comes after the summary of the lines before it, whose words are in the RAM. The name is the long name or the 8.3 name, in either case, such as `LOAD "my prog.bin"`. Any other name is a BASIC program, `LOAD "NAME"` below. |
| `LOAD "NAME" [, SLOT]` | Loads the BASIC program `NAME.BAS` of the card's folder `NICE`, or `NAME` when it has a dot, such as `LOAD "CHESS"` or `LOAD "game.txt"`. It reads the lines as if they were typed, after a `NEW` at the first, so a program written on a PC loads too: CR LF, LF, and CR end a line, a TAB is a blank, the keywords are in either case, and a line of blanks is passed over. The blanks before a line's number, and all but one after it, as `SAVE` writes the indent of `LIST`, do not count toward its 254 characters. The first line that cannot be stored ends the load, with its error and the line itself, and the lines before it stay: `Line without a number`; `Line too long`, of more than 254 characters, or with more tokens than the 160 words of a line; `A byte that is no character`, a control code or a byte from `0x80`; and the tokenizer's `Syntax error`. A file that is not there, or that has no line, keeps the program, as the `NEW` comes only with the first line stored. It ends at `READY.`, also in a program. |
| `SAVE "NAME" [, SLOT]` | Writes the program to the file `NAME.BAS` of the card's folder `NICE`, or `NAME` when it has a dot, as the text that `LIST` shows, with its indent but no colors, each line ended by LF, so that `LOAD "NAME"` reads it back and an editor on a PC opens it. The text of a line may be longer than the line typed, as `LIST` adds blanks and writes `?` as `PRINT`; `LOAD` takes 254 characters. It makes the file, or truncates it, as `BSAVE` does, and prints nothing. When the card fills up, it prints error 30. CTRL-C stops it, and the file keeps the lines before. `SAVE "NAME", "IP"` writes it to a TFTP server instead, below. |
| `BSAVE "NAME", A, N [, SLOT]` | Writes `N` words from `A` to the file `NAME` of the card's folder `NICE` as a `.bin` file, a line of `ADDR WORD` in hex for each, and prints `Words saved: 600, 00008000 to 00008257`. A name with no extension gets `.BIN`: `BSAVE "PROG", 0x8000, 600` writes `PROG.BIN`. It makes the file, or truncates it when it is there, and `LOAD` reads it back. When the card fills up, the file keeps what fitted, and `BSAVE` prints error 30. It was `SAVE "NAME", A, N` before V2.4, which is now a `Syntax error`. |
| `DELETE "NAME" [, SLOT]` | Deletes the file `NAME` of the card's folder `NICE`, its long name or its 8.3 name, as for `LOAD`, with its long-name entries, if it has them, and prints `Deleted NAME`. |
| `LOAD "NAME", "IP"` | Loads the `.bin` file `NAME.BIN`, or the BASIC program `NAME.BAS`, from the TFTP server at the IP address `IP`, such as `LOAD "HELLO.BIN", "192.168.1.10"`, as `LOAD` loads one from the card, and prints the same summary for a `.bin` file ([The network](../monitor/README.md#the-network)). `"IP:PORT"` sends the request to `PORT` instead of 69. It needs an IP address, from `IP` or `DHCP`. Without an answer, it prints `No answer from the TFTP server` after about 5 seconds; an error of the server is shown with its code and its message: `TFTP error 1, File not found`. A file that is not there keeps the program, as from the card. |
| `SAVE "NAME", "IP"`, `BSAVE "NAME", A, N, "IP"` | Writes the program's text, or the words, as to the card, to the file `NAME.BAS`, or `NAME.BIN`, of the TFTP server at `IP`, such as `SAVE "CHESS", "192.168.1.10"`, with `"IP:PORT"` as for `LOAD` ([The network](../monitor/README.md#the-network)). `BSAVE` prints the same summary as to the card. The server must take writes, as `tools/nicemon.py tftpd --write` does; without `--write` it answers `TFTP error 2, Writing is not allowed: tftpd --write allows it`. It needs an IP address, from `IP` or `DHCP`. Without an answer, it prints `No answer from the TFTP server` after about 5 seconds, and an error of the server ends it with its code and its message. CTRL-C stops `SAVE`, and sends the server an ERROR, so that it drops the file. `tools/nicemon.py tftpd` writes a file only when all of it came, so a write that fails leaves the file that was there. |
| `DIR "IP" [, "PAT"]` | Lists the files of the server `tools/nicemon.py tftpd` at `IP`, an IP address, with `:PORT` or not, whose names match the pattern `PAT`, with `*` and `?`, such as `DIR "192.168.1.10", "*.BIN"`, a line each with the name and the size; without `PAT`, all of them. A byte of a name that is not printable ASCII is left out, and a line shows its first 77 characters. Another server answers with an error. |
| `PRINT [X] [; X] [, X]`, `? ...` | Prints its items, numbers and strings in quotes, such as `PRINT "A ="; A, B`. `;` joins two items, and `,` goes to the next column of 8. `TAB(N)` goes to column `N`, unless the cursor is past it, and `SPC(N)` prints `N` blanks, for an `N` of 0 to 255. Items with nothing between them are joined too. A line ends with CR LF, but for a `;` or a `,` at its end, which leaves the cursor there; `READY.` then starts a row of its own. `?` is `PRINT`. |
| `[LET] V = X` | Sets the variable `V` to the number `X`, such as `LET TOTAL = TOTAL + 1` or `TOTAL = TOTAL + 1`. |
| `POKE A, X` | Writes the word `X` to the address `A`, such as `POKE 0x9000, -1`. `PEEK(A)` reads it (Numbers below). |
| `HALT` | Halts the core, which the reset button, or a host over the link, starts again. The tests end with it. |
| `HELP` | Lists the statements, and the keys of the history. |

The `NAME` of `LOAD`, `RUN`, `SAVE`, `BSAVE`, and `DELETE` on the card
may be a path of the folders inside `NICE`, such as
`LOAD "GAMES/CHESS"` or `DELETE "GAMES/OLD/PONG.BIN"`, as
[Files](../monitor/README.md#files) has it (issue #168). The `.BAS` or
`.BIN` that they add goes on its last part, when that part has no dot:
`SAVE "V2.0/PROG"` writes `PROG.BAS` in the folder `V2.0`. A name with
nothing after its last `/`, such as `SAVE "GAMES/"`, and an empty name
get none, and are `File error 20, not a valid name`. TAB completes
a path a folder at a time, with a `/` after a directory. The ROM makes
no folder: one is made on a PC, or with `make sdcard CMD="mkdir GAMES"`.

The debugger has pause, step, and inspect, so BASIC adds only `LOAD`
with no name, which loads a program with no host's tools and no
storage, and `DIS`, which reads code with no host. `DIR` and `LOAD` read
programs from a card's FAT32 file system, and `SAVE`, `BSAVE`, and
`DELETE` write it. `TIME` shows the clock, which the dates of the files come from.
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
- **The operators**, from the one that binds most: `^`, the power;
  the signs `-` and `+`; `*`, `/`, `DIV`, and `MOD`; `+` and `-`; `<<`
  and `>>`; the comparisons `=`, `<>`, `<`, `>`, `<=`, and `>=`; `NOT`;
  `AND`; and `OR` and `XOR`. Those of one level group to the left, and
  parentheses group as they do in arithmetic. So `-2^2` is -4, and
  `2^3^2` is 64. `/` divides as doubles do, so `PRINT 1/3` prints
  `0.333333333333333`.
- **`^`** multiplies when the power is a whole number, so `10^2` is
  100 and `(-2)^3` is -8. A negative number to a power that is not
  whole is an `Illegal quantity`, and `0^0` is 1.
- **The word operators**, `DIV`, `MOD`, `AND`, `OR`, `XOR`, `NOT`,
  `<<`, and `>>`, take their operands rounded toward zero, and each
  must fit a signed word, or it is an `Illegal quantity`. `DIV` and
  `MOD` divide toward zero, and `MOD` has the sign of its left
  operand. `>>` shifts 0 in, and a shift by 32 or more gives 0.
- **A comparison** gives -1 when it holds, and 0 when not, so `NOT`,
  `AND`, and `OR` join comparisons, as in `A > 0 AND A < 10`.
- **The functions** are `ABS(X)`, `SGN(X)`, -1, 0, or 1, `INT(X)`,
  rounded down, so `INT(-2.5)` is -3, `SQR(X)`, the square root, and
  `PEEK(A)`, the word at the address `A`, as a signed word. Then the
  FPU's: `SIN(X)`, `COS(X)`, and `TAN(X)` of `X` in radians, up to
  about 1.6 million, 2^20 times π/2; `ASIN(X)` and `ACOS(X)` of `X`
  from -1 to 1, and `ATAN(X)`; `LOG(X)`, the natural logarithm, and
  `LOG2(X)` and `LOG10(X)`; and `EXP(X)`, e to the power `X`. Each is
  within 1 unit of the last place of the double, and gives the same
  bits on the board as in `niceemu`. `PI` is π, with no parentheses.
- **`RND(X)`** is a random number from 0 to below 1, with 32 random
  bits. `RND` of a positive `X` gives the next number. A negative `X`
  starts the numbers again from `X`, so `RND(-1)` and the numbers after
  it are the same each time, and `RND(0)` starts them from the cycle
  counter, so they differ from run to run. After a cold start they are
  the same each time.
- **A variable** has a name of up to 16 letters and digits, the first
  a letter, every one significant, in either case, so `Total` and
  `TOTAL` are one variable. A keyword is no name, but a name may start
  with one, as `TOTAL` starts with `TO`. A name that starts with `FN`
  or `PROC` and goes on, such as `FNORD` or `PROCESS`, is a function's
  or a procedure's, and no variable (Programs below). A `$` after a
  name makes a string's name (Strings below), and a `%` a whole
  number's (below). An
  assignment, `INPUT`, `GET`, and `RCURSOR` make the variable in a line typed,
  and a line of a program makes each of its names. A variable that
  none of them set is an `Undefined variable`. A variable is its
  double and its name, 4 to 7 words, after the program's lines (Programs
  below). When the variables and the arrays reach the frames below
  `HIMEM`, a variable more is `Out of memory`. `CLR` and `RUN` clear
  them, and `NEW` drops them.
- **A whole number's name** ends with `%`, such as `COUNT%`, and
  `A%(` is an array of whole numbers. `A`, `A%`, and `A$` are three
  variables. A number stored in one is cut toward zero, so `A% = 2.7`
  sets 2 and `A% = -1.5` sets -1, the way `POKE` cuts its value. A
  number below -2147483648 or above 2147483647 is an `Illegal
  quantity`. Each element of an array of whole numbers takes one word,
  where an element of numbers takes two, so `DIM F%(8191)` takes half
  the room of `DIM F(8191)`. A `%` variable takes the room of any
  other. The arithmetic is the same for all numbers, so `A% / 2` is
  1.5 when `A%` is 3. A `FOR` of a `%` variable cuts each value too:
  `FOR I% = 1 TO 2 STEP 0.5` never ends, as `I%` stays 1. A function's
  or a procedure's name has no `%`, but their parameters may.
- **`PRINT`** shows a number as C's `%.15G` does: its first 15
  significant digits, with the trailing zeros dropped, in fixed
  notation while the number is from 1E-4 to below 1E15, with a 0
  before the point, and else in E notation, with a sign and at least
  two digits in the exponent. So `1/3` is `0.333333333333333`, `0.1 +
  0.2` is `0.3`, `1E15` is `1E+15`, and `0.00001` is `1E-05`. A
  negative number has its `-`, -0 is `0`, and no blank comes before or
  after a number.

An expression's errors are `Division by zero`, of `/`, `DIV`, and
`MOD`, `LOG(0)`, and 0 to a negative power; `Overflow`, a result too
large for a double, such as `EXP(710)`; `Illegal quantity`, a number
that a function does not take, such as `SQR(-1)`, `LOG(-1)`,
`ASIN(2)`, `SIN(1E7)`, or a word operator's operand that does not
fit; and `Formula too complex`, more than 16 values that wait for
the FPU, more than 16 strings that wait, or parentheses and signs
nested too deep for the stack. A
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
keeps the variables, but `CONT` cannot go on after it. From a PC,
`tools/nicemon.py load --eth 192.168.1.65 --bas prog.bas` types a
program's text into BASIC and runs it, with no card
([tools/](../tools/README.md#running-a-basic-program)).

| Statement | What it does |
|---|---|
| `RUN [N]` | Runs the program, from line `N` or from its first, after a `CLR`. |
| `RUN "NAME" [, "IP"]`, `RUN "NAME", SLOT` | Loads `NAME` as `LOAD "NAME"` does, from the card, the one in `SLOT`, or from the TFTP server at `IP`, and runs it: a BASIC program as `RUN` runs it, and a `.bin` file as `SYS 0x8000` calls it, so `RUN "CHESS.BIN"` starts nice_chess. A program may load and run the next this way. A file that is not there, or that has no line, runs nothing and keeps the program. |
| `LIST [N] [- [M]]` | Lists the lines from `N` to `M`: `LIST 100`, `LIST 100-200`, `LIST -200`, and `LIST 100-`. The keywords are in upper case, with a blank between two tokens, but before `)`, `,`, `;`, and `:`, after `(` and a sign, and between a function or an array and its `(`. A constant is shown as `PRINT` shows it, and a hex one in hex. The lines in a loop or a block are indented, and the parts of a line have colors (How listings look below). CTRL-C stops it. |
| `LISTO N` | Sets how `LIST` shows the lines, `N` 0 to 3: 1 indents them, 2 colors them, and 3, the default, does both. 0 shows them plain. Any other `N` is an `Illegal quantity`. |
| `NEW` | Deletes the program and its variables and arrays. |
| `DELETE N [- M]` | Deletes the lines from `N` to `M`, as `LIST` takes them: `DELETE 100`, `DELETE 100-200`, `DELETE -200`, and `DELETE 100-`. `DELETE` with a string deletes a file instead (Files above). |
| `RENUMBER [N] [, S]` | Numbers the lines from `N`, by `S`, 10 and 10 when not given, and changes the line numbers after `GOTO`, `GOSUB`, `RUN`, `THEN`, `ELSE`, `RESTORE`, `TRAP`, and `RESUME`, and those of `ON`'s lists, with them. A number of no line is kept. When the last line would be past 65535, or `S` is 0, it is an `Illegal quantity`, and nothing changes. |
| `AUTO [N] [, S]` | Types the number of each line before it: `N` first, then that of the line stored last plus `S`, 10 and 10 when not given. A line with nothing after its number ends `AUTO` and deletes no line, and so does CTRL-C, an empty line, a statement typed with no number, and an error. |
| `CLR` | Clears the variables, drops the arrays, and ends the loops and subroutines. |
| `GOTO N` | Goes on at line `N`. |
| `GOSUB N`, `RETURN` | Goes on at line `N`, and after the `GOSUB` at `RETURN`. |
| `IF X THEN S [ELSE T]` | Runs the statements `S` when `X` is not 0, else `T`. A line number after `THEN` or `ELSE` is a `GOTO`, and `IF X GOTO N` is one too. `ELSE` belongs to the last `IF` before it that has none, and the statements after `S` and `T` are theirs, up to the end of the line. |
| `IF X THEN`, `ELSE`, `ENDIF` | A block over lines: an `IF` whose `THEN` ends its line runs the lines after it when `X` is not 0, up to an `ELSE` at the start of a line, and else the lines after that `ELSE`, up to an `ENDIF` at the start of a line. `ELSE` may be left out, and blocks nest. A block with no `ENDIF` is `Missing ENDIF`. |
| `DO [WHILE X]`, `LOOP [UNTIL X]`, `EXIT` | Runs the statements between `DO` and `LOOP` again, while `X` is not 0 after `WHILE`, or until it is after `UNTIL`, which either may have, or until `EXIT`, which goes on after the `LOOP` of the latest `DO`. With no `WHILE` or `UNTIL` it loops until an `EXIT`. A `DO` whose `WHILE` fails at once goes on after its `LOOP`, and `Missing LOOP` when there is none. `EXIT` in a `FOR` loop in a `DO` leaves both. |
| `FOR V = X TO Y [STEP Z]`, `NEXT [V] [, W]` | Runs the statements up to `NEXT` with `V` from `X` to `Y`, by `Z` or by 1. The body runs once at least, as in Microsoft's BASIC. `NEXT` with no name ends the last loop, and `NEXT I, J` two. A `FOR` of a variable that has a loop ends that loop and those after it. |
| `END`, `STOP` | Ends the program. `STOP` prints `Break in 20`, and `END` nothing. |
| `CONT` | Goes on after `STOP`, `END`, and the break key, unless the program was edited or an error came since: then it is `Can't continue`. |
| `REM TEXT` | A remark, the rest of the line, which `LIST` shows as it was typed. |
| `INPUT ["P";] V [, W$]` | Prints `? `, or `P` and `? `, and reads a number into `V` and a string into `W$`, with commas between them. A string is the text up to a comma or the end, without the blanks around it, or one in quotes, which may have commas. A line that has no number where one goes, a number in quotes, or text after a closing quote, is `Redo from start`, and `INPUT` asks again, as it does for a number too large, or one past a whole number's range for a name with `%`. An error in the subscripts of an array's element, such as a `Bad subscript`, is an error as in any statement, after the line is typed. Too few ask for the rest with `?? `, and too many print `Extra ignored`. A number may have a sign; an expression is not taken. CTRL-C is the break key. |
| `GET V`, `GET V$` | Sets `V` to the code of the next key typed, or 0 when there is none, and `V$` to the key, or `""`. It does not wait. |
| `DIM A(N) [, B(N, M)]` | Makes the array `A` of `N + 1` elements, `A(0)` to `A(N)`, and `B` of `N + 1` rows of `M + 1`, each element 0. `DIM A$(N)` makes an array of strings, each element `""`, and `DIM A%(N)` one of whole numbers, a word each. `A` and `A(` are two names. An array that no `DIM` made is `Undefined array`, a subscript outside or one too many or too few `Bad subscript`, and a second `DIM` `Redimensioned array`. |
| `ON X GOTO N, M`, `ON X GOSUB N, M` | Goes to the line of the X-th number, as `GOTO` and `GOSUB` do: `ON 2 GOTO 100, 200` goes to 200. `X` is rounded toward zero. An `X` of 0 or past the list goes on after the statement, and below 0 it is an `Illegal quantity`. A `GOSUB` comes back after the statement. |
| `DEF FNA(X, Y$) = E` | Defines the function `FNA` of the parameters `X` and `Y$`, with the value of the expression `E`, which `FNA(1, "S")` gives, `E` with `X` 1 and `Y$` `"S"`. `DEF FNP = 3.14` has no parameters, and `FNP` calls it. `DEF FNA$(X) = ...` gives a string. The parameters are variables of numbers or strings, which have their own values again after the call, and the other variables are the program's. A name that starts with `FN` is a function's, and a call finds its `DEF` anywhere in the program; with none it is an `Undefined function`, with another count of arguments a `Syntax error`, and with an argument of the other kind a `Type mismatch`. A `DEF` that runs does nothing, as `REM`. |
| `DEF FNA(X)`, `= E` | A function over lines: with no `=` after its parameters, a call runs the statements after them up to a statement `= E`, whose `E` is its value, as `IF N < 2 THEN = 1`. A function calls itself about 30 deep, as its calls have 512 words of the processor's stack, past which it is `Formula too complex`. A `DEF` that runs does nothing, so a program that reaches one runs on into the function's lines: they go after the program's `END`. The program's end in one is `FN without =`, and `=` with no function running is `= without FN`. |
| `DEF PROCA(X, Y$)`, `ENDPROC` | Defines the procedure `PROCA`, a statement, which `PROCA(1, "S")` calls: it runs the statements after the parameters up to `ENDPROC`, which goes on after the call. Its parameters are as a function's, and it calls itself as deep as the frames have room, 73 deep with one parameter. A procedure's lines go after the program's `END` too, as a `DEF` that runs does nothing. With no `DEF` it is an `Undefined procedure`, and `ENDPROC` with no procedure running is `ENDPROC without PROC`. |
| `LOCAL X, Y$` | In a procedure or a function, keeps the values of `X` and `Y$`, and sets them to 0 and an empty string, until the `ENDPROC` or `=`. It comes before the loops of the procedure, whose `NEXT` or `LOOP` it would hide. With no procedure or function running it is `LOCAL without PROC`. |
| `HIMEM = A` | Sets the top of BASIC's memory, and does a `CLR`. `A` is from the end of the variables plus 512 words up to the default, as below; outside them it is `Out of memory`. `HIMEM` in an expression reads it, such as `PRINT HIMEM`. |

CTRL-C is the break key. A program polls it every 64 statements, and
stops with `Break in 20`, after which `CONT` goes on. `GOTO` and
`GOSUB` take a line number, which keeps the address of its line once
it is found, and is no expression. A loop and a subroutine take a
frame each, 8 and 3 words, a `DO` 8, and a procedure 4 and 3 for each
parameter, of the 512 words below `HIMEM`, so a `GOSUB` that never
returns is `Out of memory` after 170 of them. The errors of the
programs are `Undefined line`, `NEXT without FOR`, `RETURN without
GOSUB`, `LOOP without DO`, `EXIT without DO`, `Missing LOOP`, `Missing
ENDIF`, `ENDPROC without PROC`, `= without FN`, `FN without =`, `LOCAL
without PROC`, `Can't continue`, `Undefined array`, `Bad subscript`,
and `Redimensioned array`. A program can catch them with `TRAP` (Errors
in a program below).

The program's lines start at `0x8000`, a word for each token and
constant, and the variables follow them, then the arrays, each element
a double, and the frames. `HIMEM` is the top of them, by default the
top of the RAM less the room of BASIC's RAM and its stack, so that a
routine that `SYS` calls may live above a lower `HIMEM`, as in BBC
BASIC. `HIMEM = A` takes an `A` from the end of the variables plus the
frames' 512 words up to that default, 123904 (`0x1E400`) on the
MEGA65's 128K words of RAM, and 58368 (`0xE400`) on the Nexys4DDR's
64K. An `A` outside them, a negative one too, is `Out of memory`, and
`HIMEM` stays. The arrays do not count, as its `CLR` frees them, so a
`HIMEM` may go below them. A lower `HIMEM` may be raised again, but not
above the default. An empty program writes
no word at `0x8000`, so after `NEW` a `.bin` program there stays as it
was.

### Machine code beside a program

A BASIC program may load a routine of machine code and call it, for
what BASIC is too slow for, or for what only the hardware does. The
routine lives above a lower `HIMEM`, where BASIC never writes:

```
10 HIMEM = 0x1C000
20 LOAD "FAST.BIN"
30 SYS 0x1C000
40 PRINT "BACK"
```

`HIMEM = 0x1C000` comes first, as it clears the variables. It leaves
the 9K words from `0x1C000` up to `0x1E3FF` to the routine on the
MEGA65; on the Nexys4DDR, `HIMEM = 0xC000` leaves `0xC000` to
`0xE3FF`. The routine is assembled for its place, with `.ORG 0x1C000`,
and not for `0x8000`, where BASIC's program starts:

```
                .ORG    0x1C000
                MOVE    R1, 42          ; the status that SYS prints
                RET
```

`LOAD` of a `.bin` file in a program goes on with the next statement
only when every word it wrote is at `HIMEM` or above. A word below
`HIMEM` may be over the program or its variables, so the `LOAD` ends
with `NEW`, and at `READY.`. A file that writes no word ends the
program too. A word from `0x1E400` up is the stack's, and is skipped
(Loading without a host below).

`SYS` calls the routine on BASIC's stack, and prints `Returned` and the
status in R1 when it returns with `RET`; the program then goes on.
`mon_exit` goes back to `READY.` instead, and stops the program. The
routine may call the monitor's entries ([monitor/README.md](../monitor/README.md#the-dispatch-table)),
and keeps away from the RAM below `HIMEM`, which is BASIC's. It stays
loaded until something writes over it, so a program that runs again
can test for it with `PEEK` before it loads it.
[examples/README.md](../examples/README.md#basic-with-machine-code)
has a whole example, `sieve.bas`, which compares the two.

## How listings look

`LIST` indents the lines inside a loop or a block, one blank for each
level, and right-aligns the line numbers, so that the indents line up:

```
  5 FOR I = 1 TO 2
 10  IF I = 1 THEN
 20   PRINT "ONE"
 30  ELSE
 40   PRINT "TWO"
 50  ENDIF
 60 NEXT
100 DEF PROCA(X)
110  PRINT X
120 ENDPROC
```

These open a level: `FOR`, `DO`, an `IF` whose `THEN` ends its line,
and the `DEF` of a procedure or of a function over lines. These close
one: `NEXT`, and one more for each name after the first in `NEXT J, I`,
`LOOP`, `ENDIF`, `ENDPROC`, and an `=` that starts a line, which ends a
function over lines. An `ELSE` that starts a line is one level out. A
line that closes a level before it opens one is one level out, so
`NEXT` lines up with its `FOR`. A loop on one line, such as `FOR I = 1
TO 3: PRINT I: NEXT`, changes nothing. The indent is at most 16 blanks,
and a program that jumps out of a loop, with two `NEXT`s for one `FOR`,
may show some lines a level too far out, but never less than none.

The indent is only for the eye. BASIC drops the blanks before a line's
number and after it when the line is entered, so a listed line that is
changed and entered again, or a program that `SAVE` wrote with its
indent and `LOAD` reads back, is stored as before.

On the screen, `LIST` shows the parts of a line in colors of their own:
line numbers in gray, names of variables, functions, and procedures in
light blue, numbers in light green, strings and `DATA` in yellow, and
`REM` in cyan. The keywords and the rest are in the color of
`FOREGROUND`. A color that is the background's is shown in the color of
`FOREGROUND` instead, so that nothing disappears. `DUMP` and `DIS` show
their addresses in gray and their numbers in light green, and `DIS` its
registers in light blue; `HELP` shows the names in its statements in
light blue and the strings in yellow. After a listing, and after
CTRL-C or an error in one, the colors are those of `FOREGROUND` and
`BACKGROUND` again. Only the screen has the colors: a host on the line,
and a file of `SAVE`, get the text alone.

`LISTO N` turns the two off and on: 1 indents, 2 colors, 3, the
default, does both, and 0 neither. A cold start sets 3, and `NEW` keeps
it.

## Errors in a program

An error stops a program, unless the program has a `TRAP`. Then the
error goes on at a line of the program instead, the handler, which can
look at the error, and go back with `RESUME`. The names are those of
BASIC 65, the MEGA65's own BASIC.

| Statement | What it does |
|---|---|
| `TRAP N` | From now on, an error while the program runs goes on at line `N`, and does not stop the program. `TRAP` alone turns this off. |
| `RESUME` | In the handler: runs the statement of the error again, such as after the handler fixed its cause. |
| `RESUME NEXT` | In the handler: goes on at the statement after the one of the error. After an error in an `IF`, that is the next line. |
| `RESUME N` | In the handler: goes on at line `N`. A line `N` that is not there is an error in the handler. |
| `ER`, `EL` | The number of the last error, and the number of its line. Both are numbers in an expression with no parentheses, as `TI` is. Before any error, `ER` is 0 and `EL` is -1, and after an error in a line typed `EL` is -1. |
| `ERR$(N)` | The message of the error number `N`: `ERR$(20)` is `Division by zero`, and `ERR$(0)` is `""`. A number of no error is an `Illegal quantity`. |

A program that asks again when the input is wrong:

```
10 TRAP 100
20 INPUT "DIVIDE BY"; D
30 PRINT 100 / D
40 END
100 PRINT ERR$(ER); " in "; EL
110 RESUME 20
```

The handler keeps the loops, the subroutines, and the procedures that
were running, so a `RESUME` goes back into them. What the statement of
the error had started is dropped, such as the subroutine of a `GOSUB`
to a line that is not there.

An error in the handler, before its `RESUME`, stops the program with
its message, so a handler that fails does not run again and again. A
`TRAP` in the handler ends the handler too, so a handler may go on with
`GOTO` instead of `RESUME`, when the program runs a `TRAP` again.
`RESUME` with no error to go back to is `Can't resume`.

An error in a function over lines, `DEF FNA(X)` above, cannot go back
into the function. `RESUME` runs the statement again that called the
function, and `RESUME NEXT` goes on after that statement. `EL` is
still the line in the function.

Only a running program goes to its `TRAP`: an error in a line typed
prints its message. `RUN`, `CLR`, `NEW`, an edit of the program, and an
error that stops the program turn the `TRAP` off. CTRL-C is no error:
it stops a program with a `TRAP` too, and `CONT` goes on.

### Failures of the files and the network

A statement of the card or the network that fails, such as `LOAD` of a
file that is not there, or `DIR` of a TFTP server that does not answer,
is an error too. Without a `TRAP` it stops the program, and prints the
line that tells what failed, such as `File error 21, no such file in
20`. In a line typed it prints the same line, without the line number.
With a `TRAP` the program goes to the handler, and these tell what
failed, as BASIC 65's disk status does:

| Function | What it gives |
|---|---|
| `DS` | The number of the last failure, or 0 before the first. |
| `DS$` | The line of the last failure, such as `File error 21, no such file`, or `""` before the first. It keeps 87 characters at most. |

`ER` is one of four errors, by the kind of failure:

| `ER` | Message | When |
|---:|---|---|
| 4 | `File not found` | The file is not on the card (`DS` 21), the TFTP server has no such file (`DS` 64, `TFTP error 1`), or the web server has no such page (`DS` 69, `HTTP status 404`). |
| 5 | `Device not present` | No card in the slot, no such slot, no IP address, no DNS server, or no answer to ARP, from the DHCP server, the DNS server, the time server, or the TFTP server. |
| 112 | `File error` | Any other failure of the card or a file, with `DS` below 40. |
| 113 | `Network error` | Any other failure of the network. |

`DS` is the number of the error that the monitor gives: 1 to 8 are the
SD card's, 16 to 32 the files', and 40 to 57 the network's. BASIC's own
are 60 to 62 for `NTP`, 63 and 64 for TFTP, no answer and an error of
the server, 65 for a TFTP server that is no `IP[:PORT]`, and 66 for an
offset of `NTP` that is no `+HH:MM` or `-HH:MM`, and 67 to 69 for
`HTTP$` ([HTTP](#http)).

A program that tries a second server when the first does not answer:

```
10 TRAP 100
20 LOAD "GAME.BIN", "192.168.1.10"
30 END
100 IF ER <> 5 THEN PRINT DS$: END
110 TRAP: LOAD "GAME.BIN", "192.168.1.11"
```

A `TRAP` takes a failure of `LOAD` and `RUN` of a program's text that
comes before the `NEW`, at the file's first line with a number, such
as no card, a file that is not there, a TFTP server that does not
answer, or a first line without a number, and the program stays whole.
From the `NEW` on, the load replaces the program, so a `TRAP` does not
take its errors, such as a `Line without a number` after it. A
`LOAD` of a `.bin` file that wrote a word below `HIMEM` before it
failed ends the program too, with `NEW`.

The numbers are those of BASIC 65 for the errors that BASIC 65 has,
and from 100 on for the others:

| `ER` | Message | `ER` | Message |
|---:|---|---:|---|
| 4 | `File not found` | 32 | `Missing LOOP` |
| 5 | `Device not present` | 33 | `LOOP without DO` |
| 10 | `NEXT without FOR` | 100 | `Undefined variable` |
| 11 | `Syntax error` | 101 | `Undefined array` |
| 12 | `RETURN without GOSUB` | 102 | `Undefined procedure` |
| 13 | `Out of data` | 103 | `= without FN` |
| 14 | `Illegal quantity` | 104 | `FN without =` |
| 15 | `Overflow` | 105 | `ENDPROC without PROC` |
| 16 | `Out of memory` | 106 | `LOCAL without PROC` |
| 17 | `Undefined line` | 107 | `EXIT without DO` |
| 18 | `Bad subscript` | 108 | `Missing ENDIF` |
| 19 | `Redimensioned array` | 109 | `Line too long` |
| 20 | `Division by zero` | 110 | `Line without a number` |
| 22 | `Type mismatch` | 111 | `A byte that is no character` |
| 23 | `String too long` | 112 | `File error` |
| 25 | `Formula too complex` | 113 | `Network error` |
| 26 | `Can't continue` | | |
| 27 | `Undefined function` | | |
| 31 | `Can't resume` | | |

`Syntax error; HELP lists the statements` is 11 too. 109 to 111 come
from `LOAD` of a program's text alone, which is no running program. `TRAP`, `RESUME`, `ER`, `EL`, `ERR$`, `DS`, and
`DS$` are keywords, so `ER`, `EL`, and `DS` are no names of
variables.

## Strings

A string has 0 to 255 characters, bytes from 0 to 255, such as
`"HELLO"`. A name with `$` after it, `A$`, is a string variable, and
`A$(I)` an element of an array of strings, so `A`, `A$`, `A(`, and
`A$(` are four names. `A$ = "X"` and `LET A$ = "X"` assign one, and
`PRINT` prints one as it is.

`+` joins two strings, and `=`, `<>`, `<`, `<=`, `>`, and `>=` compare
them, byte by byte, a string before a longer one that it starts, and
give -1 or 0, as with numbers, so `IF A$ = "Y" AND N > 0 THEN ...`
works. A comparison of strings starts with a string, not with a `(`.
A string where a number goes, or a number where a string goes, is a
`Type mismatch`, longer than 255 characters `String too long`.

| Function | What it gives |
|---|---|
| `LEN(A$)` | The number of characters of `A$`. |
| `ASC(A$)` | The code of the first character of `A$`. `ASC("")` is an `Illegal quantity`. |
| `VAL(A$)` | The number at the start of `A$`, after blanks, as `INPUT` reads it, such as `VAL("0x1F")` and `VAL("-3E2X")`, or 0 when there is none. |
| `INSTR(A$, B$ [, N])` | The position of the first `B$` in `A$`, from 1, or 0 when there is none, looked for from position `N` or 1. An empty `B$` is found at `N`. |
| `CHR$(N)` | The character of code `N`, from 0 to 255. `CHR$(0x80)` to `CHR$(0x99)` print blocks and arrows, which the editor gives no key for: ▀ at `0x80`, ▄ at `0x84`, █ at `0x88`, ▌ at `0x8C`, and ← ↑ → ↓ at `0x90` to `0x93` ([SYSTEM.md](../doc/SYSTEM.md#the-font) has them all). |
| `STR$(X)` | The number `X` as `PRINT` shows it, such as `0.333333333333333`. |
| `HEX$(X)` | The word `X` as 8 hex digits in upper case, such as `000000FF`. |
| `LEFT$(A$, N)`, `RIGHT$(A$, N)` | The first and the last `N` characters of `A$`, or all of them when it has fewer. |
| `MID$(A$, N [, M])` | `M` characters of `A$` from position `N`, from 1, or all of them from `N` on. A position past the end gives `""`. |
| `URL$(A$)` | `A$` encoded for the path of a URL, such as `URL$("New York")`, `New%20York` ([HTTP](#http)). |
| `HTTP$(H$, P$)` | The page at `http://H$P$`, from a web server ([HTTP](#http)). |
| `TIME$` | The clock's date and time, as `YYYY-MM-DD HH:MM:SS`, or `""` when it is not set. `TIME$ = A$` sets the clock, as `TIME` does, and a string that it does not take is an `Illegal quantity`. |

A position below 1 and a negative count are an `Illegal quantity`.

| Statement | What it does |
|---|---|
| `DATA 1, "A,B", TEXT` | Items that `READ` reads: numbers, strings in quotes, and strings without, without the blanks around them, with commas between them, up to the end of the line or a `:`. `LIST` shows them as they were typed. A `DATA` that runs does nothing. |
| `READ V, W$` | Reads the next items of the `DATA` of the program into `V` and `W$`, in the order of the lines. A string read into a number, also one in quotes such as `"7"`, is a `Syntax error`, and past the last item it is `Out of data`. |
| `RESTORE [N]` | Makes `READ` read from the first `DATA` again, or from that of line `N` on. `RUN` and `CLR` do so too. |

The characters of a string are one to a word, as on the screen. A
string in quotes stays in its line, and `LEFT$`, `MID$`, and `RIGHT$`
point into their string, but a new string, of `+`, `CHR$`, `STR$`,
`HEX$`, `TIME$`, `URL$`, `HTTP$`, `INPUT`, `READ`, and `GET`, takes a block of the heap
below the frames: its characters and 2 words. An assignment that
replaces a string leaves its old block unused. When a new block does
not fit above the arrays, BASIC moves the blocks in use up over those
that are not, once, and the rest is `Out of memory`. So a program
never runs out of room for strings while its strings in use fit.
`CLR`, `RUN`, `NEW`, and `HIMEM` drop the strings, and an edit keeps
them, as it keeps the variables.

### HTTP

`HTTP$(H$, P$)` fetches the page at `http://H$P$` from a web server,
and gives its text, the body of the answer:

```
10 IF PEEK(0xFFFFFFB0) = 0 THEN DHCP
20 PRINT HTTP$("wttr.in", "/" + URL$("New York") + "?format=3")
```

- `H$` is the server: a name, such as `"wttr.in"`, or an IP address,
  with `:PORT` after it or not, 80 when not. A name needs a DNS server,
  as `NTP` does, so `DHCP` or `IP` first.
- `P$` is the path, with its query, and goes as it is. It starts with
  a `/`, or it is an `Illegal quantity`. `URL$` encodes a part of it,
  such as a name with blanks.
- The request is `GET` with HTTP/1.0, with the headers `Host`,
  `User-Agent: NiceMon-BASIC/` and the version, and `Connection:
  close`. There is no HTTPS.
- The text is decoded from UTF-8 to the characters of the screen: ISO
  8859-1 as it is, the arrows ← to ↙ and the blocks ▀ to ▏ as the codes
  `0x90` to `0x99` and `0x80` to `0x8F` of their glyphs
  ([SYSTEM.md](../doc/SYSTEM.md#the-font)), and a `?` for anything
  else. A line end at the end of the text is dropped, and those inside
  it stay.
- The text has 255 characters at most, or it is `String too long`.
- `HTTP$` waits 20 seconds for the whole answer at most, and CTRL-C
  stops it. A name that needs a lookup, and the server's address, may
  take up to 12 seconds more, which CTRL-C does not stop.

A failure is an error, with `DS` and `DS$`
([Failures](#failures-of-the-files-and-the-network)), so a `TRAP`
takes it:

| `DS` | `DS$` | When |
|---:|---|---|
| 53 | `The server refused the connection` | Nothing listens on the port. |
| 55 | `No answer from the server` | No answer within 20 seconds. |
| 67 | `Not an HTTP server` | The answer is not HTTP. |
| 68 | `The answer of the server was cut short` | The server closed before the end of the headers, or of `Content-Length`. |
| 69 | `HTTP status 404, No such page` | A status other than 200, with the `Location` of a redirect, or the first line of the text. 404 is `ER` 4, `File not found`, and the others are 113. |

Many servers answer plain HTTP with a redirect to `https://`, which
`DS$` then shows. A program that runs on an older core, whose character
ROM has no blocks and arrows, reads `PEEK(0xFFFE3000)`, which is 0
there, and draws them in the font RAM.

`URL$(A$)` encodes `A$` for a path: a letter, a digit, and `-._~` stay,
a character from 128 on becomes the two bytes of its UTF-8, each as
`%XX`, and any other character `%XX`, so a blank is `%20`, and `ü` is
`%C3%BC`.

## The screen and the time

These statements change the colors and the cursor, and wait. Their
names are those of BASIC 65, the MEGA65's own BASIC.

| Statement | What it does |
|---|---|
| `FOREGROUND N` | Sets the color of the characters that are printed from now on, `N` one of the 16 colors below. |
| `FOREGROUND R, G, B` | The same, with the color given as its red, green, and blue, each 0 to 15, so that any of 4096 colors is possible: `FOREGROUND 15, 8, 0` is orange. |
| `BACKGROUND N`, `BACKGROUND R, G, B` | Sets the background of the characters that are printed from now on, as `FOREGROUND` does. |
| `CURSOR ON`, `CURSOR OFF` | Shows the cursor, or hides it. |
| `CURSOR C, R [, S]` | Moves the cursor to column `C` and row `R`, both from 0, so that the next `PRINT` prints there. `CURSOR ON, C, R` and `CURSOR OFF, C, R` show or hide it too. A column past 79 is 79, and a row past 27 is 27. `S` is the cursor's style: 0 solid, 1 blinking, and 2 and 3 the same, but small. |
| `RCURSOR C, R` | Sets the variables `C` and `R` to the cursor's column and row. |
| `SLEEP S` | Waits `S` seconds, such as `SLEEP 0.5`. CTRL-C stops it, and `CONT` goes on after it. |

A color's number, or the number past 15 of a part, or a negative
column or row, is an `Illegal quantity`. The colors stay after a
program ends, and `CLS` clears the screen in them. `READY.` shows the
cursor again, blinking, as a program may have hidden it.

The 16 colors are those of BASIC 65, with their red, green, and blue:

| N | Color | R, G, B | N | Color | R, G, B |
|---:|---|---|---:|---|---|
| 0 | black | 0, 0, 0 | 8 | orange | 15, 6, 0 |
| 1 | white | 15, 15, 15 | 9 | brown | 10, 4, 0 |
| 2 | red | 15, 0, 0 | 10 | light red | 15, 7, 7 |
| 3 | cyan | 0, 15, 15 | 11 | dark gray | 5, 5, 5 |
| 4 | purple | 15, 0, 15 | 12 | gray | 8, 8, 8 |
| 5 | green | 0, 15, 0 | 13 | light green | 9, 15, 9 |
| 6 | blue | 0, 0, 15 | 14 | light blue | 9, 9, 15 |
| 7 | yellow | 15, 15, 0 | 15 | light gray | 11, 11, 11 |

`TI` is the time since the board started, in microseconds, a number
in an expression with no parentheses, as `PI` is. It is real time on
the board and in `niceemu`, and it cannot be set. So a program times
itself with it:

```
10 T = TI
20 FOR I = 1 TO 1000: NEXT
30 PRINT (TI - T) / 1000; " ms"
```

`TI` and `OFF` are keywords, so they are no names of variables.
`TIME$` is the time of day (Strings above).

## The disassembler

`DIS` shows each instruction as nice_cpu's `assembler/nicedis.py` and
`nicemon.py mon` do, so the three disassemblers agree, but for the
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
  each back to the same word. nicedis.py and `nicemon.py mon`, and the
  debugger's decode of row 30, show the plain instructions.
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
outside a program's RAM, `0x8000` to `0x1E3FF` on the MEGA65 and to
`0xE3FF` on the Nexys4DDR ([Programs](../monitor/README.md#programs)), is skipped: the RAM repeats through the address space, so a
larger address could reach the ROM, the variables, or the stack. The
1K words above that range, up to `0x1E7FF` or `0xE7FF`, are the
stack's, which `LOAD` and `SYS` run on, so a load leaves them, as
`HIMEM` does. A second line for an address writes its
word over the first's, where `niceemu` rejects the file. In `niceemu`,
where `0xFFFFFF9E` reads 0, the program's RAM goes up to the screen,
`0xFFFEFFFF`. Its font RAM at `0xFFFE0000`–`0xFFFE1FFF` keeps
only bits 15..0 of a word, and its character ROM at
`0xFFFE2000`–`0xFFFE3FFF` drops one, so a program there does not read
back as loaded. At the end `LOAD` prints the number of words written, with
the lowest and the highest address, and the number of lines skipped,
with the first of them and the last address that a line may have:

    Words loaded: 601, 00008000 to 00009000
    Lines skipped: 4, first line 2; ADDR WORD in hex, ADDR 00008000 to 0001E3FF

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
`tools/nicemon.py load --eth 192.168.1.65 --monitor prog.bin` ([Remote control](../monitor/README.md#remote-control))
is faster, as it writes the words into the memory.

## Building

`make -C basic` builds BASIC's image, `build/basic_image.bin`, and
`make rom` at the top joins it with the monitor's into the ROM,
`build/rom.bin` ([rom.mk](../rom.mk)). Both write the image as a file
for a card too, `build/basic.rom`
([doc/BASIC_ROM.md](../doc/BASIC_ROM.md), #153). The image is the cat of
`basic.nasm`, `basic_expr.nasm`, `basic_prog.nasm`, `basic_cmd.nasm`,
`basic_net.nasm`, `basic_time.nasm`, `basic_dis.nasm`,
`basic_edit.nasm`, `basic_str.nasm`, and `basic_struct.nasm`, BASIC's copies of the monitor's `common.nasm`,
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
4. **The functions.** `test/functions.py` writes the bits of `X`, and
   of `Y`, with `POKE`, computes `A = SIN(X)` or `A = X^Y`, and reads
   `A`'s two words with `PEEK`, for 431 cases from a fixed seed: each
   function, of numbers in the range it takes, and `^` of positive
   numbers, of negative ones to whole powers, and whole powers, which
   are exact. Each must be within 1 ulp of Python's, as nice_cpu's
   FPU is within 1 ulp of the exact value. `PI` must be Python's
   `math.pi`, and `RND` the numbers of a model of its generator, bit
   for bit, after the cold start and after a negative argument.
5. **NTP.** `test/ntp.py` types `NTP` and `DHCP` with `--step-time`,
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
6. **TFTP.** `test/tftp.py` runs `LOAD` and `DIR` from a TFTP server
   the same way, against `test/tftp.expected`. It covers a file of two
   blocks among packets of other hosts and ports, lost packets, an
   ERROR, an ERROR after the first block, whose summary comes first,
   files of 512 and 0 bytes, a listing, with names that have bytes
   that are not printable ASCII, which are dropped, and a line of more
   than 77 characters, a port given as `"IP:PORT"`,
   a BASIC program's text, listed and run, one with a line without a
   number, bad arguments, and no answer to ARP. The writes of `SAVE`
   and `BSAVE` (issue #155) send files of 0, 512, and 1024 bytes, the
   last with a lost DATA and ACKs of another port and of the block
   before, and get an ERROR after the first block, an ERROR to the
   WRQ, as a server without `--write` sends it, and no answer; and
   CTRL-C ends a `SAVE` with an ERROR to the server. A `DIR` that
   fails after a `LOAD` of a word below `HIMEM` keeps the program. A
   program's `TRAP` takes an ERROR 1, File not found, with a message
   of 116 characters, of which `DS$` keeps 87.
7. **HTTP.** `test/web.py` runs `HTTP$` and `URL$` against the web
   server of `tools/lib/tcppeer.py`, which answers each path with an
   answer of its own, in real time, not with `--step-time`. A program
   typed before its `RUN` fetches them, as keys typed while `HTTP$`
   waits would go to the keys typed ahead. It covers a body with
   UTF-8, the arrows, and the blocks, `Content-Length`, also one with
   no digits, line ends inside the body and at its end, a body of 255 characters and two
   longer, the statuses 404, 301 with a `Location`, and 500, answers
   that are not HTTP or are cut short, bytes that are no UTF-8, an
   empty body, a refused port, a name with no DNS server, and a path
   and a port that are an `Illegal quantity`, each through a `TRAP`,
   and the request that the server got. Its 18 connections, more than
   the 4 handles of TCP, show that each frees its handle.
8. **The benchmarks.** `test/bench.py` types Rugg/Feldman's
   benchmarks 1 to 8, the sieve, and `str.bas`, which fills the heap
   with strings until it is swept, in `bench/`, and checks their
   output. Their steps, which it prints, are those of the instruction
   counter, read by `PEEK` before and after `RUN`, less those of an
   empty program. `make -C basic bench` prints them as the rows of the
   table in [doc/BASIC.md](../doc/BASIC.md#the-benchmarks).

`make -C basic ecma55`, or `make ecma55` at the top, runs the ECMA-55
conformance suite, NBS SP 500-70, apart from `make test`, as it needs
the network once. `test/ecma55.py` fetches bas55 2.0's 208 programs
into `build/ecma55` the first time, and checks the tarball's SHA-256.
It types each program after a `NEW`, runs it, and writes one line of
`build/ecma55.out` for it: `same`, when the output is bas55's but for
blanks and the digits of numbers, `differs`, `failed`, when it printed
its own `TEST FAILED`, `error:` and BASIC's error, `refused:` and a
line that BASIC did not take, or `noend`, when it waits for `INPUT`,
with `; bas55 stops` after it when bas55 reports an error. It compares
the lines with `test/ecma55.expected`, and prints those that changed.
8. **The runs.** The ROM runs once for each test below, with its
   keystrokes from an input file that ends with `HALT`, so that the run
   halts. Each run's console output, a few memory words, and the screen
   are compared with `test/NAME.expected`:

| Test | What runs | What it checks |
|---|---|---|
| `cmds` | The ROM alone | Every statement, its bad arguments, keywords in either case, numbers that do not fit, and the edits of a line. |
| `basic` | The ROM alone, with no card and no IP address | The scanner of a statement: keywords glued to a letter or a digit, which are names, the HELP lines of each statement's Syntax error, numbers at the limits of a signed word, `0x` without digits, which is no number, a name in a number's place, strings without a closing quote, too few or too many arguments, and four statements that fail with no card or no IP address, whose tokens `trap` dumps. |
| `expr` | The ROM alone | The numbers: the operators and their order, the word operators, the comparisons, the functions, the constants, `PRINT`'s format and its items, the variables, `LET`, the colons, the errors, the depth of an expression, `PEEK` and `POKE`, a statement with expressions, a `LOAD` that writes no word, a broken table of variables, and `Out of memory`. |
| `funcs` | The ROM alone | The functions: their values, in either case, `PI`, the order of `^` and the signs, `RND`'s range and its numbers again after a negative argument, names that start with a function's, `LIST` of each function and of the keywords after them, and the errors of an argument a function does not take, `LOG(0)`, an overflow, and a function without its parentheses. |
| `prog` | The ROM alone, with `test/prog.bas` typed | The lines: their entry, edits, and deletion, the numbers at the limits, `LIST` and its blanks, `RUN`, `NEW`, the variables an edit keeps, the tokens in memory, `FOR` with steps, nested, and once, `GOSUB` in loops, `IF` with `ELSE`, nested, `STOP`, `END`, `CONT`, and the errors in a program, with its line's number. |
| `edit` | The ROM alone | The screen editor: a character that `POKE` left on the row of the next line, after `READY.`, `INPUT`'s prompt, and `AUTO`'s number, which is no part of the line; `READY.` after a program whose output filled a row, which is a line of its own; a listed line changed and entered again, a line that grows into the row below, `INPUT`'s answer after its prompt, DEL in the middle and at the prompt, a line of two rows entered from its first row, CTRL-C, and the cursor key down at the last row. The screen at the end is compared too. |
| `long` | The ROM alone | The editor's limit: a listed line of 254 characters, right-aligned in 255 columns, changed at its last character and entered again, and one of 255, which is `Line too long` and stays as it was. |
| `listo` | The ROM alone, with `test/listo.bas` typed | `LISTO` 0 to 3 and its errors; the indent of `FOR`, `NEXT J, I`, `DO`, `LOOP`, block `IF`s with `ELSE`, `DEF PROC`, `ENDPROC`, and a `FN` over lines with its `=`, from the start and from a line in the middle; a `FOR` with two `NEXT`s; and the colors of `LIST`, `DUMP`, `DIS`, and `HELP`, read back from the screen's words, with `LEN`, `HEX$`, and `SIN` as keywords, not names, with a background of a syntax color, and with the colors off; and an answer of `INPUT` that keeps the blanks after its number. |
| `lines` | The ROM alone | `DELETE` of a range, a line, and up to a line, `RENUMBER` with the jumps forward and back, a target that is no line, the overflow and a step of 0, and `AUTO`, ended by a number alone and by CTRL-C. |
| `redo` | The ROM alone | The check at entry: a line of two rows that the tokenizer refuses is shown again after `READY.`, with the cursor at the error, as the input ends there and no key waits; it runs until the step limit. |
| `keys` | The ROM alone | `INPUT` with too few, too many, and bad numbers, a prompt, and CTRL-C; `GET`; the break key in a loop, in `CONT`, and in `LIST`; and the keys typed ahead, of which the ring keeps 31. |
| `struct` | The ROM alone, with `test/struct.bas` typed | `DEF FN` with no, one, and two parameters, of a string, calling others and defined after its call, with its parameters kept; `ON ... GOTO` and `ON ... GOSUB` with each line, 0, past the list, a fraction, and after `THEN`; their errors and those of a `DEF`, `CLR` and an edit before a call, `LIST`, and `RENUMBER` of `ON`'s lists; `DO` and `LOOP` with `WHILE` and `UNTIL` at either end, on one line and over lines, nested, with `FOR` inside, `EXIT`, a `GOTO` back to a `DO`, and a `RETURN` out of one; block `IF`s nested, with and without `ELSE`, a number like `THEN`'s token before one, and their errors, `LIST`, and `RENUMBER`. |
| `proc` | The ROM alone, with `test/proc.bas` typed | `PROC` with parameters of numbers and strings and `LOCAL`s, the program's variables of their names kept; `FN` over lines calling itself, with `LOCAL`s and a `FOR` loop, and one on one line with `IF` and `ELSE`; `FN`s in expressions with numbers and strings pending; a `PROC` calling itself, `ENDPROC` in an `IF`, and a `GOSUB` in a `PROC`; strings that frames keep over sweeps of a small heap; the errors of `ENDPROC`, `=`, and `LOCAL`, of the calls, and of a `FN` with no `=`, after which `CONT` cannot go on; `ENDPROC` and `=` in a subroutine; and a `FN` 30 and 31 deep. |
| `str` | The ROM, with `--step-time` and `test/str.bas` typed | The strings: variables, `+`, each function and the edges of its arguments, the comparisons, alone and in `IF`, the errors, arrays of strings, `IP` with a string expression, `TIME$`, `GET`, `READ`, `DATA`, and `RESTORE`, with a quoted comma and empty items, `LIST` of their tokens, `INPUT` of strings, and a program that fills a small heap until it is swept, again and again. |
| `mach` | The ROM, with `--step-time` and `test/mach.bas` typed | `TI`; `FOREGROUND` and `BACKGROUND` by number and by red, green, and blue, read back from the screen's words; `CURSOR` to a place, its limits, `ON`, `OFF`, and the styles; `RCURSOR`; their errors and `LIST`; and `SLEEP`, timed with `TI`, broken by CTRL-C and gone on with `CONT`. |
| `trap` | The ROM alone, with `test/trap.bas` typed | `ER`, `EL`, and `ERR$` before any error; each error that a program can come to, trapped once, with its number, its line, and its message, and `RESUME NEXT` after it: after `THEN`, a block `IF`, and a `DO`, in a `FOR` loop, which goes on, in a subroutine, whose `GOSUB` to no line is dropped, in a `FN` over lines, after which its caller goes on with its parameter set again, and in a `PROC`; `RESUME` after a fix, `RESUME N`, `ERR$` of 0 to 113, an error in the handler, `TRAP` alone, `RENUMBER` and `LIST` of the lines; `DS` and `DS$` before any failure, the failures with no card and no IP address, of a server and an offset that are not, and of a slot that is not, trapped, with the dump of the program's tokens, with the 0 after each string, which `BSAVE` leaves as they were, a failure with no `TRAP`, and `LOAD` and `RUN` of a program's text with no card, trapped; the `Bad subscript` of `INPUT`'s element, trapped, and a `RESUME` to no line in the handler, which stops the program; a handler that goes on with `GOTO` and a `TRAP`, and CTRL-C, which a `TRAP` does not take. |
| `int` | The ROM alone, with `test/int.bas` typed | The names with `%`: a value cut toward zero, the largest and smallest word, and a value past them; `%` in a function's and a procedure's name; arrays with `%` of one and two dimensions, and their errors; `INPUT`, with a value past a word and a subscript outside, `GET`, `FOR`, `RCURSOR`, `READ`, `LOCAL`, and the parameters into them; `A`, `A%`, and `A$` side by side, `LIST`, and the layout of an array with `%` in memory. |
| `kw` | The ROM alone, with `test/kw.bas` typed | A keyword where a variable's name goes, named in its `Syntax error`, at the start of a statement, in a direct line and in a program, and in `FOR`, `NEXT`'s list, `READ`, `INPUT`, `DIM`, `GET`, `LET`, `RCURSOR`, a `DEF`'s parameters, and `LOCAL`; a number, a `+`, and an item of `DATA` that does not fit, which name none; and one trapped, as error 11. |
| `arr` | The ROM alone, with `test/arr.bas` typed | `DIM`, the elements, their errors, `LET`, `INPUT`, and `GET` of an element, `INPUT` of an element outside, `CLR` and an edit with arrays, `HIMEM` read and set, too low and too high, and below the arrays, which its `CLR` frees, the layout of an array in memory, and `LOAD` below and above `HIMEM`, in a line and in a program. |
| `load` | The ROM, with 128K words of RAM, as on the MEGA65 | `LOAD` with the monitor's `build/hello.bin` pasted: CR LF and LF line ends, tabs, blank lines, skipped lines, a line too long, blanks after a line's 76 characters, a DEL that takes back the key after them, an address given twice, and CTRL-C. Then `SYS 0x8000` runs it. |
| `load_64k` | The ROM, with 64K words, as on the Nexys4DDR | `LOAD` at the end of that RAM. |
| `load_emu` | The ROM, with `0xFFFFFF9E` reading 0, as in `niceemu` | `LOAD` up to the screen. |
| `files` | The ROM, with `--step-time` and a copy of the card without partitions, with the files of `test/files_card.py`, and `test/files.in` typed | `SAVE "NAME"` and `LOAD "NAME"` of a program with each kind of token, and `RUN "NAME"`; a file written on a PC, with CR LF, lower case, a TAB, and lines of blanks; the lines that end a load: one without a number, one with too many tokens, one too long, and one with a byte from `0x80`, with the lines before them kept; a file that is not there, to `LOAD` and to `RUN`, which keep the program; a name with a dot, an empty program, `RUN "HELLO.BIN"`, a `SLOT` with no card, one that the board does not have, and slot 0 again for `LOAD`, `SAVE`, `BSAVE`, and `DELETE`, a program that runs the next, and the failures of issue #158: `BSAVE` to a slot with no card, and `LOAD` and `DELETE` of a file that is not there, trapped, a failure with no `TRAP`, `LOAD` and `RUN` of a program's text that is not there, trapped, with the program kept, a `LOAD` whose first line that is not blank has no number, trapped too, and a `LOAD` that fails after the file's first line with a number, which a `TRAP` does not take; and a program with an indent saved and loaded again, with a line of 257 characters in the file. Its output ends with `fsck.fat` on the card, and the files that it wrote, as `od -c` shows them. |
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
| `basic.nasm` | The vectors, the header, the main loop, the scanner, the keywords, the messages, and the help | 2516 | 1528 |
| `basic_expr.nasm` | The numbers: the tokenizer, the expressions, the functions, the variables, the errors, `PRINT`, `LET`, and `POKE` | 1914 | 39 |
| `basic_prog.nasm` | The programs: the lines, `LIST`, `RUN`, the jumps, the loops, the break key, `INPUT`, `GET`, the arrays, and `HIMEM` | 2382 | 52 |
| `basic_cmd.nasm` | The routines of the statements that were the commands | 1855 | 300 |
| `basic_net.nasm` | `DHCP`, `NTP`, TFTP, `HTTP$`, and `URL$` | 2045 | 222 |
| `basic_time.nasm` | `TIME`, and the clock's side of `NTP` | 289 | 44 |
| `basic_dis.nasm` | The disassembler of `DIS` | 948 | 79 |
| `basic_edit.nasm` | The screen editor | 1281 | 0 |
| `basic_str.nasm` | The strings: the heap, its sweep, the functions of strings, `DATA`, `READ`, and `TIME$` | 1609 | 11 |
| `basic_struct.nasm` | The structure: `ON ... GOTO`, `ON ... GOSUB`, `DEF FN`, `DEF PROC`, `LOCAL`, `DO`, `LOOP`, `EXIT`, and the block `IF` | 1204 | 45 |
| `basic_mach.nasm` | The machine: `TI`, `SLEEP`, `FOREGROUND`, `BACKGROUND`, `CURSOR`, and `RCURSOR` | 290 | 0 |
| `basic_trap.nasm` | The errors in a program: `TRAP`, `RESUME`, `ER`, `EL`, and `ERR$`, and the failures, with `DS` and `DS$` | 697 | 20 |
| `common.nasm` | What the monitor and BASIC share: texts, IP addresses, and dates | 237 | 5 |
| `monlib.nasm` | The routines that programs join | 274 | 0 |
| `mon.nasm` | The stubs of the entries | 92 | 0 |
| `build/basic_folder.nasm` | The texts with the folder's name: `DIR`'s, and the error of a card without it | 14 | 14 |
| `build/version_test.nasm` | The version in the banner, the tests' `V9.9` | 2 | 2 |
| In all | | 17649 | 2361 |
<!-- /romsize basic -->
