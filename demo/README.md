# demo

The demo shows that the core, the keyboard, and the screen work, on a
MEGA65 with no computer on its debug UART. It is nice_cpu's demo,
[nice_cpu/demo](https://github.com/MJoergen/nice_cpu/blob/main/demo/README.md),
with the text of the boards in `text.nasm`. The ROM of every release has
the monitor ([monitor/](../monitor/README.md)), which the core boots
from at power-up, and the demo behind it: the monitor's command `x`
copies the demo to `0x8000` and runs it there, as `r` runs a program,
and F12 returns to the monitor. This is for the time being: a BASIC
interpreter will take its place in the ROM.

The demo's source, its documentation, and its tests are in nice_cpu, so a
change to it reaches the boards only with a tag of nice_cpu
([doc/RELEASE.md](../doc/RELEASE.md)). This directory has the board's
text, the join behind the monitor, and the check on a board.

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
  address `02:4E:49:43:45:00`. So a board with the demo in its ROM can
  get its address from its own keyboard, or from a terminal on the debug
  UART, with I and M, and then answers pings and serves remote control
  on TCP port 4510, which the row "Debug link, TCP port" shows, with "a
  host connected" while one is. The counts are the board's frames.
- The demo halts at the end of the input: after a break on the line, as
  when an Ethernet host half-closes its connection. After a break, every
  read of the console returns the end once the bytes before it are read,
  and the line's bytes are dropped until the core is started again or a
  host connects over Ethernet
  ([SYSTEM.md](../doc/SYSTEM.md#address-map)); the keyboard's keys still
  come, but the demo ends as `niceemu` does, rather than read on. The
  link sends `h`, and `run.py`, `hwtest.py`, and the tests in `niceemu`
  end on it. A terminal program that sends a break when it opens the port
  thus stops the demo, and the reset button, or a start from the link,
  starts the monitor again.

## Building and testing

    make -C demo                  # build/demo.bin, and build/rom.bin for the ROM
    make r6                       # the bitstream, with build/rom.bin in its ROM
    make -C demo test             # the join, in niceemu, compared with test.expected

The Makefile builds the demo with nice_cpu's `demo/Makefile`, with
`TEXT=` this directory's `text.nasm`, and its output in `build/`. The
version in the title bar is `git describe --tags --always --dirty` of
this repository, or `VERSION=` on the command line, which
`tools/release.py` sets to the tag; the monitor's banner gets the same.
The demo is assembled from `0x8000` into `build/demo.bin`. `join.py`
then puts the monitor, `monitor/build/monitor.bin`, and the demo into
the ROM's image, `build/rom.bin`: at the monitor's `DEMO`, `0x6000`, the
number of the demo's words, and the words after it, which `x` copies to
`0x8000`. It fails if the monitor reaches `DEMO`, or the demo does not
fit the ROM.

The test builds the demo with the version `V9.9` into
`build/test/demo_test.bin`, joins it behind the monitor's test,
`monitor/build/monitor_test.bin`, into `build/rom_test.bin`, and runs that
in `niceemu` twice. The first input runs the demo with `x` and types a
line, so the screen has the board's text, and the second goes back to
the monitor with F12, and shows its version with `v` and halts it with
`h`. The screens are in `test.expected`. nice_cpu's own test checks the
demos themselves, behind a stand-in for a monitor.
`build/rom_fail.bin` has a demo with a wrong word in the math unit's
test, which shows how a failure of F11 looks.

The ROM's image runs in `niceemu` like any program, at address 0:

    niceemu --screen -i demo/build/test1.txt demo/build/rom_test.bin

`tools/hwtest.py`, and so `make linktest` and `make cosimtest`, run
`build/rom_test.bin` with `x` and a few keys through `run.py`, and
compare its registers and screen with `niceemu`'s, and run F11's
self-test on the board. They hide the ROM, and run the monitor and the
demo from the RAM.

`demo_hw.py` checks the demo where a release runs it, in the ROM of a
programmed board:

    demo/demo_hw.py --port /dev/ttyUSB1

It boots the core from the ROM, types `x` and CR into the monitor over
the UART, compares the demo's welcome and the cursor with `niceemu`'s,
types keys into the demo over the UART, and compares all 2000
words of the screen and the cursor again. It prints the screen, and leaves
the demo running.
