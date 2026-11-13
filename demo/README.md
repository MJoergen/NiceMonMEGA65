# demo

The demo shows that the core, the keyboard, and the screen work, on a
MEGA65 with no computer on its debug UART. It is nice_cpu's demo,
[nice_cpu/demo](https://github.com/MJoergen/nice_cpu/blob/main/demo/README.md),
with the text of the boards in `text.nasm`. It is a program at `0x8000`,
`demo.bin`, which each release has as a file of its own. It is not in
the ROM (#129). To run it on its own:

1. Copy `demo.bin` into the folder `NICE` of an SD card.
2. Put the card in the board, and type `load demo.bin` and then `r` in
   the monitor ([monitor/](../monitor/README.md)).
3. F12 returns to the monitor.

`tftp IP demo.bin` loads it from a TFTP server instead, and
`tools/load.py --monitor demo.bin` from a PC.

The demo's source, its documentation, and its tests are in nice_cpu, so a
change to it reaches the boards only with a tag of nice_cpu
([doc/RELEASE.md](../doc/RELEASE.md)). This directory has the board's
text, and the test under the monitor.

## On the boards

nice_cpu's
[README](https://github.com/MJoergen/nice_cpu/blob/main/demo/README.md)
has what each demo shows and how it works. On the boards:

- The keys are those of the MEGA65's keyboard, or of the Nexys4DDR's
  PS/2 keyboard ([The keyboard](../doc/SYSTEM.md#the-keyboard)). F1, F3,
  F5, and so on need no SHIFT on the MEGA65. F12, SHIFT and F11 on the
  MEGA65, goes back to the monitor, which clears the screen and prints
  `Returned 00000000`.
- The counters count the core's cycles at 100 MHz on the MEGA65, and at
  90 MHz on the Nexys4DDR, and the time is real.
- F11's self-test runs on the core, and the network station below it is
  the board's, at `0xFFFFFFB0` ([nice_cpu's SYSTEM.md §6](https://github.com/MJoergen/nice_cpu/blob/main/doc/SYSTEM.md#6-network-station), and
  [The Ethernet station](../doc/SYSTEM.md#the-ethernet-station)). Its IP
  address is `0.0.0.0` after reset, which answers nothing, and its MAC
  address `02:4E:49:43:45:03` on the R3, `02:4E:49:43:45:06` on the R6,
  and `02:4E:49:43:45:0A` on the Nexys4DDR. So a board with the demo in its ROM can
  get its address from its own keyboard, or from a terminal on the debug
  UART, with I and M, and then answers pings and serves remote control
  on TCP port 4510, which the row "Debug link, TCP port" shows, with "a
  host connected" while one is. The counts are the board's frames.
- The demo halts at the end of the input: after a break on the line, as
  when an Ethernet host half-closes its connection. After a break, every
  read of the console returns the end once the bytes before it are read,
  and the line's bytes are dropped until the core is started again or a
  host connects over Ethernet
  ([SYSTEM.md](../doc/SYSTEM.md#io-registers)); the keyboard's keys still
  come, but the demo ends as `niceemu` does, rather than read on. The
  link sends `h`, and `run.py`, `hwtest.py`, and the tests in `niceemu`
  end on it. A terminal program that sends a break when it opens the port
  thus stops the demo, and the reset button, or a start from the link,
  starts the monitor again.

## Building and testing

    make -C demo                  # build/demo.bin
    make -C demo test             # under the monitor, in niceemu, compared with test.expected

The Makefile builds the demo with nice_cpu's `demo/Makefile`, with
`TEXT=` this directory's `text.nasm`, and its output in `build/`. The
version in the title bar is `git describe --tags --always --dirty` of
this repository, or `VERSION=` on the command line, which
`tools/release.py` sets to the tag. The demo is assembled from `0x8000`
into `build/demo.bin`.

The test builds the demo with the version `V9.9` into
`build/test/demo_test.bin`, puts it after the monitor's test,
`monitor/build/monitor_test.bin`, into `build/test/monitor_demo.bin`, and
runs that in `niceemu` twice. The first input runs the demo with `r` and
types a line, so the screen has the board's text, and the second goes
back to the monitor with F12, and shows its version with `v` and halts
it with `h`. The screens are in `test.expected`. nice_cpu's own test
checks the demos themselves, behind a stand-in for a monitor.

The two run in `niceemu` like any program, from address 0:

    niceemu --screen -i demo/build/test1.txt demo/build/test/monitor_demo.bin

`tools/hwtest.py`, and so `make linktest` and `make cosimtest`, run
`build/test/monitor_demo.bin` with `r` and a few keys through `run.py`,
and compare its registers and screen with `niceemu`'s, and run F11's
self-test on the board.

## Its words

The demo's parts, in the order of the source, each from the label that
starts it. It is nice_cpu's `demo/demo.nasm`, with this directory's
`text.nasm` and `build/version.nasm` joined after it. The column "Text"
counts the words of the `.ASCII_L` strings, one character a word, which
are part of "Words". `make -C demo test` checks the table, and `make
romsize` writes it (`tools/romsize.py`).

<!-- romsize demo -->
| Source | What it is | Words | Text |
|---|---|---:|---:|
| `demo.nasm`, from `0x8000` | The entry, the vector of the timer's interrupt at `0x8041`, and the unused words before it | 66 | 0 |
| `demo.nasm`, `TYPEW` | F1, the typewriter, with `CELL`, `FILL`, and `PRINT`, which the other demos call too | 216 | 0 |
| `demo.nasm`, `KCODES` | F3, the key codes | 118 | 0 |
| `demo.nasm`, `CHARS` | F5, the characters and the colors | 101 | 0 |
| `demo.nasm`, `COUNTS` | F7, the counters and the prime sieve, with `DEC64`, which F9 and F11 call too | 409 | 0 |
| `demo.nasm`, `GAME` | F9, the comet | 333 | 0 |
| `demo.nasm`, `BOARD` | F11, the self-tests and the network's addresses | 812 | 0 |
| `demo.nasm`, `MONITOR` | F12, the return to the monitor | 24 | 0 |
| `demo.nasm`, `POLL` | The keys and their escape sequences, the frame of the screen, and the scroll | 216 | 0 |
| `demo.nasm`, `FKEYS` | The function keys, the menu, the title bar, and the welcome | 186 | 114 |
| `demo.nasm`, `K_TEXTS` | The texts of F3 | 273 | 257 |
| `demo.nasm`, `C_TEXTS` | The texts and the colors of F5 | 230 | 196 |
| `demo.nasm`, `P_TEXTS` | The texts of F7 | 298 | 240 |
| `demo.nasm`, `G_TEXTS` | The texts and the steps of F9, and the shifts of F11's MAC address | 113 | 96 |
| `demo.nasm`, `S_TEXTS` | The texts of F11 | 953 | 910 |
| `demo.nasm`, `MATH` | The script of F11's test of the math unit | 97 | 0 |
| `demo/text.nasm` | The board's texts: the name, the welcome, the keys, and the note on the clock | 571 | 571 |
| `build/version.nasm` | The version in the title bar, the tests' `V9.9` | 5 | 5 |
| In all | | 5021 | 2389 |

The code is 2295 words, and the texts and tables 2726. They are at `0x8000`–`0x939C`, in 4960 lines of `demo.bin`, one for each word but the unused ones, which the assembler skips.
<!-- /romsize demo -->

The demo changes only with a tag of nice_cpu, but its version and
`text.nasm` are this repository's.
