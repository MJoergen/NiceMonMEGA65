# demo

The demo is the program in the ROM of every release, in NICE assembly.
The core boots from it at power-up, so a MEGA65 with no computer on its
debug UART still shows that the core, the keyboard, and the screen work.
It stays until the monitor ([monitor/](../monitor/README.md)) takes its
place in the ROM.

## What it shows

The top ten rows are the welcome: the name and the version in a blue bar,
what the demo is, how to load your own programs through the debug UART, and
a second blue bar with the keys. The 15 rows below it are a typewriter.
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

## How it works

A write to the ROM is dropped (see [The ROM](../doc/SYSTEM.md#the-rom) in
doc/SYSTEM.md), so the demo keeps its state in registers. It writes only the
screen, the cursor's registers, and its stack.

The stack grows down from `0xFFFFFEFF`, where there is no register or
screen, so on the board it is in RAM. The 64K words of RAM repeat through
the address space, and `0xFFFFFEFF` is RAM word `0xFEFF`, far above the
ROM.

The demo scrolls by copying the rows, not with the display offset, so
that the welcome stays, and so that it runs the same in `niceemu`, where
the screen's registers are memory. It halts at the end of the input: in
`niceemu`, after its input file, and on the board, after a break on the
UART.

## Building and testing

    make -C demo                  # build/demo.bin, for the ROM
    make r6 ROM=demo/build/demo.bin
    make -C demo test             # two runs in niceemu, compared with test.expected

The version in the title bar is `git describe --tags --always --dirty`, or
`VERSION=` on the command line, which `tools/release.py` sets to the tag.
The assembler has no include, so the Makefile joins `demo.nasm` and a line
that defines `VERSION`. The test assembles the demo with the version `V9.9`
into `build/demo_test.bin`, and the Makefile writes its two inputs,
`build/test1.txt` and `build/test2.txt`, with `printf`: the first edits a
few lines, and the second clears them and scrolls. The two screens that
`niceemu` prints for them are in `test.expected`, which was checked by
hand.

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
