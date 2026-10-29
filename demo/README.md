# demo

The demo is the program in the ROM of every release, in NICE assembly.
The core boots from it at power-up, so a MEGA65 with no computer on its
debug UART still shows that the core, the keyboard, and the screen work.
It stays until the monitor ([monitor/](../monitor/README.md)) takes its
place in the ROM.

## What it shows

The top two rows are blue bars that every demo has: the name and the
version, and a menu of the demos, which lists the function key of each and
shows the running one in black on white. A function key starts its demo
afresh, and one without a demo does nothing. The keys are F1, F3, F5, and
so on, which the MEGA65 has without SHIFT.

| Key | Demo |
|---|---|
| F1 | The typewriter, which runs at power-up |
| F3 | The key codes |
| F5 | The characters and the colors |
| F7 | The counters |
| F9 | The comet, a game |
| F11 | The board: a self-test, and the Ethernet station's addresses |

The typewriter's top ten rows are the welcome: the two bars, what the
demo is, how to load your own programs through the debug UART, and a third
blue bar with the keys. The 15 rows below it are a typewriter.
What you type on the keyboard, or send to the debug UART, appears at the
blinking cursor:

| Key | What it does |
|---|---|
| A character | Shown at the cursor, which moves on, to the next row after the last column |
| RETURN | The next row. A CR, an LF, and a CR LF are each one new row. |
| INST/DEL, backspace | Deletes the character before the cursor, in its row |
| TAB | The next column that is a multiple of 8 |
| Cursor keys | Move the cursor within the typewriter's rows |
| CTRL-L | Clears the typewriter's rows |

Past the last row, the typewriter's rows scroll up by one, and the welcome
stays. Other control codes and other escape sequences do nothing, and so do
the bytes `0x80` to `0x9F`. The bytes from `0xA0` on are the characters of
ISO 8859-1.

The key codes show the bytes that each key sends, as
[The keyboard](../doc/SYSTEM.md#the-keyboard) lists them, which helps when
writing programs that read the keyboard. Each key gets a row, with its
bytes in hex from column 2, and from column 42 as characters, a control
code as `^` and a character: `^[` is ESC, `^C` is RUN/STOP, and `^?` is
DEL. The bytes `0x80` to `0x9F` have no character, and a key shows at
most 12 bytes. A sequence from the debug UART shows as one key, and an
ESC alone shows with the key after it. A function key with a demo starts
that demo, so its bytes show only for a moment, or not at all. Past the
last row, the rows scroll up by one.

The characters and the colors check the font and the video output at a
glance. On the left are the 256 characters of the font, ISO 8859-1, in 16
rows of 16. A row's label is the code of its first character, and the
digits above the columns add to it. The codes below `0x20` and from
`0x80` to `0x9F` are blank, as the font has no glyphs for them
(`font/gen_font_pkg.py`), so they look like `0x20` and `0xA0`. On the right are ramps of seven
colors, red, green, blue, yellow, cyan, magenta, and gray, each with the
16 intensities `0` to `F` of 4-bit color: first as backgrounds, and then as
foregrounds, the digits of the intensities on black. Intensity 0 is black,
so its cell shows nothing. The keys do nothing here, except the function
keys.

The counters show nice_cpu's performance counters, which count while the
core runs. The top part has those since reset: the time as `h:mm:ss.hh`,
the microseconds, the cycles, and the instructions, all 64 bits in
decimal, and the clock in MHz, the cycles divided by the microseconds:
100 on the MEGA65, and 90 on the Nexys4DDR. The bottom part has a sieve of
Eratosthenes on the numbers below 2048, which runs again before each update
of the screen: the runs, the primes it finds, which are 309, and the
instructions, cycles, and microseconds of the last run, with the cycles
per instruction and the instructions per microsecond. On the MEGA65, the
sieve's 30058 instructions take about 79000 cycles, 2.6 per instruction,
and about 38 instructions a microsecond. That is usual for the pipelined
core on code written by hand (nice_cpu's
[bench/README.md](https://github.com/MJoergen/nice_cpu/blob/main/bench/README.md)):
each turn of its loops ends with a taken jump, which costs cycles, the
count reads the sieve from memory, and each prime's square is read from
the math unit. In `niceemu`, each step counts as a cycle and a
microsecond, so the time runs at one
microsecond a step, the clock is 1 MHz, and the sieve has one cycle per
instruction ([EMULATOR.md](../doc/EMULATOR.md)). The keys do nothing here,
except the function keys.

The comet is a small game. The cursor keys steer the comet, `@`, through
a field in a blue frame, and its green tail follows it. Each star, `*`,
scores a point, makes the tail longer by 4, and makes the comet faster, from
a step every 150 ms to one every 50 ms. A new star then comes at a random
free cell. The game ends when the comet hits the frame or its tail, and
then any key starts a new one. The comet waits for the first cursor key,
and a key that would turn it back is ignored. The best score stays until
another demo starts. The game takes one key at each step, so in `niceemu`,
where a microsecond is a step, each key of the input file is one step.

The board runs a self-test of four tests each time that F11 starts it,
and shows PASS or FAIL for each:

| Test | What it checks |
|---|---|
| RAM | The 28672 words from `0xFFFF8000` to `0xFFFFEFFF`, RAM on every board: each is written with its address, and then with its address inverted, and read back |
| Math unit | Signed and unsigned products and quotients of 32 bits, a division by zero, the most negative number divided by −1, and quotients of 64 bits, against known results |
| Timer | 10 interrupts, one every 1000 cycles, which must come within 9500 to 10500 cycles of the start |
| Performance counters | The instructions of a known sequence, and over a loop, at least as many cycles as instructions, some microseconds, and 1 to 255 cycles per microsecond |

A failure shows two words in hex: the address that failed and the word
read there, or for the timer, the interrupts that came and the cycles
that they took. The last line says whether all tests passed.

Below the self-test is the Ethernet station
([The Ethernet station](../doc/SYSTEM.md#the-ethernet-station)), shown
again and again while the demo runs: its IP address in decimal with
dots, its MAC address in hex with colons, and its counts of the good
frames received, the bad or dropped ones, and the frames sent. After
reset the IP address is `0.0.0.0`, which answers nothing, and the MAC
address is `02:4E:49:43:45:00`. So a board with this demo in its ROM can
get its address from its own keyboard, or from a terminal on the debug
UART, and then answers pings and serves the debug link on TCP port 4510.
These keys change the addresses:

| Key | What it does |
|---|---|
| I | Starts typing a new IP address, such as `192.168.1.65` |
| M | Starts typing a new MAC address, such as `02:4E:49:43:45:01` |
| Digits and dots, or hex digits and colons | Typed at the cursor in row 22. Other characters are dropped, and so are those past the 15 or 17 of a full address. |
| DEL, backspace | Deletes the last character |
| RETURN | Writes the address to the station, if it is one, and ends the typing. Otherwise a red message in row 24 says what is wrong, and the typing goes on. |
| CTRL-C, RUN/STOP | Cancels the typing |

An IP address is four numbers from 0 to 255 with dots between them. A MAC
address is six bytes of one or two hex digits with colons between them,
and the first byte must be even, because an odd one is a group address,
which no board has. ESC cannot cancel, as the demo reads it as the start
of a function key. A function key still starts its demo, which also
cancels the typing. Writing an address while a host is connected on the
TCP port, or while a reply goes out, breaks that connection or reply
([SYSTEM.md](../doc/SYSTEM.md#the-ethernet-station)). In `niceemu` the
registers of the station are plain memory, so the demo shows what it
wrote, and the counts stay 0.

## How it works

Every demo reads the keys through `POLL`. It turns the escape sequences of
the cursor keys and the function keys into codes of their own: those of
ANSI terminals and xterm, which the keyboards send (see
[The keyboard](../doc/SYSTEM.md#the-keyboard)), and also `ESC O A` to
`ESC O D` and the VT220's `ESC [ 11 ~` to `ESC [ 14 ~`. It waits for the
rest of a sequence after its ESC, so an ESC alone is dropped, with the
byte after it taken as it is. On a function key with a demo, `POLL` jumps
to the demo, which starts with an empty stack. A new demo is a routine
that sets SP, calls `FRAME` for the two bars, and polls the keys; its
address goes in the tables `FKEYS` and `MENU`. A demo that wants the bytes
themselves puts a routine in `ECHO`, R12, which `POLL` calls with each
byte, as the key codes do. `FRAME` sets `ECHO` to 0.

A write to the ROM is dropped (see [The ROM](../doc/SYSTEM.md#the-rom) in
doc/SYSTEM.md), so the demo keeps most of its state in registers, and its
variables in the RAM below its stack: the counters keep the sieve at
`0xFFFFF000`–`0xFFFFF7FF` and their numbers from `0xFFFFF800`, and the
comet keeps the addresses of its cells and its state at the same
addresses, as only one demo runs at a time. The comet tells what is in a
cell from the screen itself. It writes
only these words, the screen, the cursor's registers, the math unit, and
its stack.

The stack grows down from `0xFFFFFEFF`, where there is no register or
screen, so on the board it is in RAM. The 64K words of RAM repeat through
the address space, and `0xFFFFFEFF` is RAM word `0xFEFF`, far above the
ROM. So are the variables, which are RAM on every board, also on the
Nexys4DDR, whose RAM starts at `0xFFFF2000`.

The self-test's timer interrupt goes through vector `0x41` and a vector
table at `0x7F00`, VBASE `0x7F`, near the end of the ROM. Its only entry,
the word at `0x7F41`, holds the address of the routine, which counts the
interrupts in RAM. The self-test sets VBASE, and leaves the timer stopped
and E clear when it is done, so no other demo has interrupts.

The demo scrolls by copying the rows, not with the display offset, so
that the welcome stays, and so that it runs the same in `niceemu`, where
the screen's registers are memory. It halts at the end of the input: in
`niceemu`, after its input file, and on the board, after a break on the
UART.

## Building and testing

    make -C demo                  # build/demo.bin, for the ROM
    make r6 ROM=demo/build/demo.bin
    make -C demo test             # twelve runs in niceemu, compared with test.expected

The version in the title bar is `git describe --tags --always --dirty`, or
`VERSION=` on the command line, which `tools/release.py` sets to the tag.
The assembler has no include, so the Makefile joins `demo.nasm` and a line
that defines `VERSION`. The test assembles the demo with the version `V9.9`
into `build/demo_test.bin`, and the Makefile writes its twelve inputs,
`build/test1.txt` to `build/test12.txt`, with `printf`: the first edits a
few lines, the second clears them and scrolls, the third has the function
keys, the fourth shows key codes and scrolls them, the fifth goes from
the key codes back to the typewriter, the sixth shows the characters and
the colors, the seventh the counters, with two runs of the sieve, the
eighth plays two games of the comet, the ninth runs the board twice,
the tenth types an IP address that is rejected, the eleventh writes an IP
address and a MAC address and cancels a second one, and the twelfth types
a MAC address that is rejected.
`niceemu` shows no colors, so for the sixth the test also has the words of
two rows of ramps. The twelve screens that `niceemu` prints, and those
words, are in `test.expected`, which was checked by hand. In `niceemu` the
counters count steps, so their numbers are the same in every run.

The demo runs in `niceemu` like any program, at address 0. After `make -C
demo test`, the first input shows the first screen of `test.expected`:

    niceemu --screen -i demo/build/test1.txt demo/build/demo_test.bin

`tools/hwtest.py`, and so `make linktest` and `make cosimtest`, run it with
a few keys through `run.py`, and compare its registers and screen with
`niceemu`'s. They hide the ROM, and run the demo from the RAM.

`demo_hw.py` checks the demo where a release runs it, in the ROM of a
programmed board:

    demo/demo_hw.py --port /dev/ttyUSB1

It boots the core from the ROM, compares the welcome and the cursor with
`niceemu`'s, types keys into the demo over the UART, and compares all 2000
words of the screen and the cursor again. It prints the screen, and leaves
the demo running.
