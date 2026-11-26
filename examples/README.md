# The examples

Programs in C for the NICE CPU, and three in BASIC, one of them with
machine code. `make examples` at the top builds them to
`examples/build/`. It needs clang with the wasm32 target, `wasm-ld`, and
`llvm-ar` (on Debian and Ubuntu, the `clang`, `lld`, and `llvm`
packages). [doc/PROGRAMMING.md](../doc/PROGRAMMING.md) says how C
reaches the board.

| Program | What it does |
|---|---|
| `primes.bin` | Asks for a limit, counts the primes up to it, and prints how many cycles and instructions that took, until it reads 0. It runs on its own, from address 0, loaded by `tools/nicemon.py load`. |
| `bench.bin`, `bench_win.bin` | nice_cpu's benchmark, which `make hwtest` runs (CONTRIBUTING.md, "The examples"). |
| `weather.bin` | A weather display on the screen, below. It runs under the monitor. |
| `sieve.bas`, `sieve.bin` | A BASIC program that counts primes in BASIC, and then again with a routine of machine code that it loads beside it, and compares the times (BASIC with machine code, below). |
| `weather.bas` | The weather display again, in BASIC, which fetches with `HTTP$` (The weather display in BASIC, below). |
| `chess.bas` | A chess program in BASIC alone, which plays a legal game against a player or against itself (Chess in BASIC, below). |

## The weather display

`weather.bin` shows the weather of a place, the date, and the time on the
screen, and fetches the weather again every 10 minutes. It can stay on
for days, as a display on a desk.

The weather comes from [wttr.in](https://wttr.in), a free weather service,
over plain HTTP, on the board's Ethernet port. The date and the time come
from the board's clock, which BASIC's `NTP` sets. The clock keeps
local time, so `NTP "", "+01:00"` sets it to Central European Time.
On the MEGA65 the clock keeps running when the power is off. On the
Nexys4DDR, set it after each reset. Without it, the screen shows
`--:--:--` and says so.

### Running it

1. Copy `weather.bin` to the folder `NICE` of the SD card. Each release
   has the file, and `make examples` builds it as
   `examples/build/weather.bin`.
2. Write the settings file `WEATHER.CFG` (below) into the same folder,
   or leave it out and type the place at the start.
3. On the board, at BASIC's `READY.`, type `LOAD "WEATHER.BIN"` and
   then `SYS 0x8000`.

The board needs a network with a DHCP server, the service that hands out
IP addresses, as most home routers have. When the board has no IP
address yet, the program asks for one by itself, as BASIC's `DHCP`
does, and so it does when the board has an address but no DNS server,
the service that turns the name `wttr.in` into an address.

The program needs the core of V2.6 or later, whose font has the blocks
of the clock and the arrows of the wind. On an older core it says so,
and returns.

| Key | What it does |
|---|---|
| R | Fetches the weather now |
| Q | Returns to the monitor |

### The settings file

`WEATHER.CFG` is a text file with one setting a line. A `#` starts a
comment. For example:

    # The weather of Copenhagen, in degrees Celsius
    place Copenhagen
    units m

| Setting | What it is |
|---|---|
| `place NAME` | The place, such as `Copenhagen`, `New York`, or an airport's code, such as `CPH`. Without it, wttr.in guesses the place from the address that the request comes from. |
| `units m` or `units u` | Metric units (°C), or those of the USA (°F, and the wind in mph). Without it, wttr.in chooses the temperature's unit by the place. The wind is in m/s, unless the units are `u`. |
| `server NAME[:PORT]` | Another server than `wttr.in`, with port 80 unless one is given. It must answer as wttr.in does (below). |

A line that the program does not understand is shown in red at the
start, and the other lines still count. The program reads the first
1024 bytes of the file. When the file is longer, it says so in red, and
only the whole lines in those bytes count.

### What the screen shows

The top row shows the server and the board's IP address. Under the large
clock and the date are the place, the weather, the temperature, the
wind, and the humidity. The arrow of the wind points the way the wind
blows. The green line says how old the weather is.

When a fetch fails, a red line says why, such as `Error -47, no answer
from the DNS server`, and when the next try is, a minute later. The
last weather stays on the screen until then. The numbers are the
monitor's error codes ([doc/PROGRAMMING.md](../doc/PROGRAMMING.md#the-monitors-error-codes)).
An answer of the server that is not the weather is shown too, such as
`HTTP status 500 location not found` for a place that wttr.in does not
know.

### When wttr.in changes

wttr.in is a service run by one person, and it may be slow or down at
times. The program needs plain HTTP, as the board has no encryption
(HTTPS). If wttr.in ever sends the program to HTTPS, the red line
shows `HTTP status 301` and the new address. Then a small proxy on a
computer of the local network can fetch the weather over HTTPS, and
answer the board over plain HTTP, with the `server` setting pointing to
it. The proxy gets the request

    GET /PLACE?format=%l|%C|%t|%w|%h HTTP/1.0

with `&m` or `&u` after the format when the settings have `units`, and
`&M` for the wind in m/s unless they have `units u`, and answers with one line of five fields, separated by `|`, as wttr.in
does:

    Copenhagen|Partly cloudy|+7°C|↙4m/s|87%

### Building and testing it

`weather.c` is the program: the screen, the keys, the fetch, and the
settings. `weather_parse.c` is the text: the settings, the request, and
the answer, which `make -C examples test` checks on the host with the
answers in `test/`. `make weathertest` at the top runs that, and then
the whole program in the emulator against a server of the test
(CONTRIBUTING.md, "The examples").

## BASIC with machine code

`sieve.bas` is a BASIC program that calls a routine of machine code,
`sieve.bin`, for the part where BASIC is slow. Both count the primes
with the sieve of Eratosthenes, as BYTE's benchmark does, and the
program prints how long each took:

    Words loaded: 42, 0000C000 to 0000C029
    BASIC:
    1899 PRIMES IN 13135 MS
    MACHINE CODE:
    Returned 00000000
    1899 PRIMES IN 154 MS
    MACHINE CODE IS 84 TIMES AS FAST

Those times are from `niceemu`'s test, which counts a microsecond for
each instruction, so the ratio is that of the instructions. The boards
run both faster, the MEGA65 at 100 MHz and the Nexys4DDR at 90 MHz:

| | BASIC | Machine code | Machine code is |
|---|---:|---:|---:|
| MEGA65 R6, V2.4.1 | 393 ms | 4 ms | 83 times as fast |
| Nexys4DDR, V2.5 | 437 ms | 5 ms | 84 times as fast |
| `niceemu`, a microsecond an instruction | 13135 ms | 154 ms | 84 times as fast |

The routine's time is whole milliseconds, so its ratio on a board is
rough.

### Running it

1. Copy `sieve.bas` and `sieve.bin` to the folder `NICE` of the SD card.
   The examples' zip of each release has both, and `make examples`
   builds them in `examples/build/`.
2. On the board, at BASIC's `READY.`, type `RUN "SIEVE"`.

`make load FILE=examples/sieve.bas ETH=IP ARGS=--bas` types the program
from the PC instead (tools/README.md), but it still loads `SIEVE.BIN`
from the card.

### How it works

BASIC keeps its program, its variables, and its arrays below `HIMEM`,
and never writes above it. Line 30, `HIMEM = 0xC000`, makes room above
`0xC000`, and comes first, as it clears the variables. Line 40 loads
`SIEVE.BIN`, which `sieve.nasm` assembles for `0xC000` with `.ORG`.
All of its words are at `HIMEM` or above, so the `LOAD` leaves the
program alone, and it goes on with the next line. A `.bin` file built
for `0x8000`, where BASIC's program starts, would end it instead
([basic/README.md](../basic/README.md#machine-code-beside-a-program)).

The routine and BASIC share two words: the program `POKE`s the size to
`0xC000`, calls `SYS 0xC002`, and reads the count with
`PEEK(0xC001)`. The routine keeps its flags, a word each, from `0xC100`
up to `0xE3FF`, below the stack's room, so the same file runs on both
the MEGA65 and the Nexys4DDR. It returns with `RET`, which `SYS`
reports with `Returned 00000000`, and keeps the registers R7 to R13,
which BASIC uses.

`make -C examples test` runs the program in `niceemu` with a card that
holds both files, and compares what it prints with
`test/sieve.expected`.

## The weather display in BASIC

`weather.bas` is the weather display of `weather.bin` rewritten in
BASIC: the screen, the keys, the fetch, and the text of the answer. It
needs a BASIC with `HTTP$`, that of V2.6 or later
([basic/README.md](../basic/README.md#http)).

### Running it

1. Copy `weather.bas` to the folder `NICE` of the SD card. The
   examples' zip of each release has it, and `make examples` copies it
   to `examples/build/`.
2. On the board, at BASIC's `READY.`, type `LOAD "WEATHER"`.
3. Change the settings in lines 90 to 110, if needed, and type `RUN`.

The settings are lines of the program, not a file, as BASIC cannot
read a file's text:

    90 PLACE$ = "Copenhagen"
    100 SERVER$ = "wttr.in": PORT = 80
    110 UNITS$ = "m"

`PLACE$ = ""` lets wttr.in guess the place, and `UNITS$` is `"m"`,
`"u"`, or `""`, as `units` in `WEATHER.CFG`. A character from `0x80`,
such as `CHR$(252)`, ü, goes to the server in UTF-8. `SAVE "WEATHER"`
keeps the changes on the card.

The screen is that of `weather.bin`, but for the texts of the errors,
which are BASIC's `DS$`, such as `The server refused the connection`.
R fetches now, and Q goes back to BASIC. CTRL-C stops the program too.

### How it works

`PROCFETCH` builds the path with `URL$`, and fetches it with `HTTP$`:

    P$ = "/" + URL$(PLACE$) + "?format=%l|%C|%t|%w|%h"
    ...
    IF FAILED = 0 THEN B$ = HTTP$(H$, P$)

Before it, `TRAP` points to a handler, which sets `FAILED`, keeps
`DS$` as the text of the error, or `ERR$(ER)` for an error of BASIC,
such as `String too long`, and goes on with `RESUME NEXT`. When the
board has no IP address, the program types `DHCP` first, and so it
does when `HTTP$` finds no DNS server, `DS` 46, and then fetches
again. `DHCP` prints its lines from row 20, which the program then
clears. `HTTP$` has
decoded the text from UTF-8 already, with the wind's arrows as the
codes of their glyphs, so `FNPARSE` only splits the first line at its
`|`s with `INSTR`, into the five fields.

The program writes the screen with `POKE`, a word for each character
with its color. The clock's blocks and the wind's arrows are the
character ROM's, at `0x80`–`0x99`.

The clock stops while a fetch waits, for a second or so, where
`weather.bin` fetches while it runs.

`make weathertest` runs it in `niceemu` against the same server of the
test as `weather.bin`, with the same answers, and checks its screen
and its requests (CONTRIBUTING.md, "The examples").

## Chess in BASIC

`chess.bas` plays chess, and is written in BASIC alone. It is a very
simple version of [nice_chess](https://github.com/MJoergen/nice_chess),
the chess program in C, `CHESS.BIN`: it keeps the negamax search with a
time limit for each move, and a simple evaluation, and leaves out the
rest, such as the opening book, the transposition table, the levels,
and the remote play. It knows all the rules of a move: castling, en
passant, and the promotions to each piece.

### Running it

1. Copy `chess.bas` to the folder `NICE` of the SD card. The examples'
   zip of each release has it, and `make examples` copies it to
   `examples/build/`.
2. On the board, at BASIC's `READY.`, type `RUN "CHESS"`. `RUN
   "CHESS.BIN"` starts nice_chess instead.
3. Answer `W` to play white, `B` to play black, or `N` to watch the
   program play itself.

`make load FILE=examples/chess.bas ETH=IP ARGS=--bas` types the program
from the PC instead (tools/README.md).

A move is typed as its two squares, such as `e2e4`, in either case, and
a promotion with its piece after them, `e7e8q`, or `n`, `b`, or `r`;
with none it is a queen. Castling is the king's move, `e1g1`. A move
that is not legal is asked for again. The board is shown after each
move, white at the bottom, with white's pieces in upper case and
black's in lower case. The game ends at a checkmate, a stalemate, the
fifty-move rule, or when only the kings are left, or a king and one
bishop or knight against a king. There is no draw by repetition.

The program thinks 10 seconds on a move. Line 30 sets that, and line
40 the deepest search, in plies, which a test may lower:

    30 THINKSECONDS = 10: REM THE SECONDS THAT THE COMPUTER THINKS ON A MOVE
    40 MAXDEPTH = 30: REM THE DEEPEST SEARCH, IN PLIES, BEFORE THE CAPTURES

While it thinks, it prints a line for each depth that it has searched,
with the score in centipawns for the side to move, the best move, the
nodes, and the seconds so far:

    DEPTH 2, SCORE 15, b8c6, NODES 412, 3.2 S

### How it works

The program uses BASIC's structured statements: the main loop is a
`DO` and `LOOP`, each part of it a procedure, such as `PROCSHOWBOARD`,
`PROCHUMANMOVE`, and `PROCCOMPUTERMOVE`, and the tests are functions,
such as `FNATTACKED(SQUARE, BY)` and `FNEVALUATE`. The names say what
they hold, such as `BOARD%`, `SIDE`, and `CASTLING`. Most procedures
keep their own variables with `LOCAL`. Those that the search calls
most often, such as `PROCGENERATE` and `FNATTACKED`, use the program's
variables instead, as `LOCAL` takes time.

The board is 10 by 12 squares, `BOARD%(119)`, with a border of 7s
around the 8 by 8, so that a knight's jump or a slide off the board
finds a 7 and stops. A piece is 1 to 6, pawn to king, positive for
white and negative for black. The squares of each side's pieces are
kept in a list, `PIECELIST%`, so that the moves are generated from 16
squares and not from 64. A move is a number: its square from, plus 128
times its square to, plus 16384 times its piece of promotion.

The moves are generated as a piece moves, without regard to its king,
and the search makes each move and drops it when its own king is then
in check. That test is the whole attack on the king only after a move
of the king, en passant, or a move out of check; else it only looks
along the line from the king through the square that the piece left,
for a pin.

The search is negamax with alpha-beta, by iterative deepening: depth 1,
then 2, and so on, until half the time is gone, as the next depth would
not end in time. A depth that the time stops is dropped, but for a
better move than the last depth's that it has found already. Each node
tries the captures first, the most valuable victim first, and at depth
0 a quiescence search goes on with the captures alone. A position with
no legal move is a mate or a stalemate. The search is `PROCSEARCH`,
which calls itself for each move. It keeps the state of each ply, such
as `ALPHA%(PLY)` and `BETA%(PLY)`, in arrays and not in parameters, as
a ply takes 12 of BASIC's 512 words of frames as it is, for the
procedure and its `DO` loop. So the quiescence search stops at ply 32,
`MAXPLY`, where the frames still have room.

The evaluation is Tomasz Michniewski's "simplified evaluation
function": the material, 100 for a pawn, 320 for a knight, 330 for a
bishop, 500 for a rook, and 900 for a queen, and a bonus for each piece
by its square. The king has two tables, one for the middle game and one
for the end game, which are mixed by the material left. The score is
kept up to date as each move is made and taken back.

BASIC is slow for this: a generation of the moves takes some 700
statements, so the program searches a few hundred nodes a second on the
MEGA65, and 2 or 3 moves deep in its 10 seconds. It plays a legal game,
but a weak one, and it may not find the mate in a won end game before
the fifty-move rule.

`make -C examples test` types the program into BASIC in `niceemu`, sets
its time to 2 seconds with line 30, which `--step-time` makes 2
million steps, plays three moves of white against it, one of them
typed wrong first, and compares what it prints with
`test/chess.expected`.
