#!/usr/bin/env python3
"""Check the demo in the ROM of a programmed board.

It boots the core from the ROM, as the reset button does, pauses it, and
compares the welcome and the cursor with what niceemu shows. It then types
keys into the demo over the UART, pauses it again, and compares all 2000
words of the screen and the cursor with what niceemu leaves for the same
keys. It writes the keys to demo/build/hw_keys.txt for niceemu. It prints
the screen, and leaves the demo running.

make hwtest hides the ROM and runs its programs from the RAM; this checks
the demo where it runs on a release's board. The bitstream must have
demo/build/demo.bin in its ROM (make demo, then make r6
ROM=demo/build/demo.bin), and niceemu must be built.

Usage: demo/demo_hw.py [--port /dev/ttyUSB1] [--baud 2000000]
"""

import argparse
import os
import re
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "tools"))
from nicelink import CONTROL, HOLD, PAUSE, Link, Serial  # noqa: E402

DEMO = os.path.join(REPO, "demo", "build", "demo.bin")
KEYS_FILE = os.path.join(REPO, "demo", "build", "hw_keys.txt")
EMU = os.path.join(REPO, "nice_cpu", "emulator", "zig-out", "bin", "niceemu")
# Text, a DEL, a TAB, a line that wraps, the cursor keys, and enough lines
# to scroll
KEYS = (b"Hello from the MEGA65!\r\nabc\x7fd\tTAB\r\n"
        + b"0123456789" * 9 + b"\r\n\x1b[A\x1b[A\x1b[CX\r\n"
        + b"".join(b"line %d\r\n" % i for i in range(1, 15)))
SCREEN = 0xFFFF0000
SCR_CTL = 0xFFFFFF80
SCR_X = 0xFFFFFF81
SCR_Y = 0xFFFFFF82

# The number of failed checks, counted by check() and the exit status
fails = 0


def check(name, ok, detail=""):
    global fails
    print(f"[{'PASS' if ok else 'FAIL'}] {name} {detail}", flush=True)
    fails += not ok


def emulator():
    """The screen's words that niceemu leaves for KEYS, and the cursor's
    column and row, R10 and R11."""
    with open(KEYS_FILE, "wb") as f:
        f.write(KEYS)
    out = subprocess.run([EMU, "-i", KEYS_FILE, "-d", f"0x{SCREEN:08X}:2000", DEMO],
                         capture_output=True, text=True, check=True).stdout
    words = [int(w, 16) for line in out.splitlines()
             if re.match(r"^ffff[0-9a-f]{4}:", line)
             for w in line.split(":")[1].split()]
    regs = dict(re.findall(r"(R\d+)\s+([0-9a-f]{8})", out))
    return words, int(regs["R10"], 16), int(regs["R11"], 16)


def pause(link):
    """Pauses the core, with the ROM shown; False when no p came."""
    n = link.pauses
    link.control(PAUSE)
    end = time.monotonic() + 2
    while link.pauses == n and time.monotonic() < end:
        link.poll(end - time.monotonic())
    return link.pauses > n


def show(words):
    for r in range(25):
        row = "".join(chr(w & 0xFF) if 0x20 <= w & 0xFF < 0x7F else " "
                      for w in words[80 * r:80 * r + 80])
        print("|" + row.rstrip())


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", default="/dev/ttyUSB1",
                        help="the serial device of the board's debug UART "
                        "(default /dev/ttyUSB1)")
    parser.add_argument("--baud", type=int, default=2000000)
    args = parser.parse_args()
    for path, how in ((DEMO, "make demo"), (EMU, "make -C nice_cpu/emulator build")):
        if not os.path.exists(path):
            sys.exit(f"demo_hw.py: {path} is missing; run '{how}'")

    want, col, row = emulator()
    link = Link(Serial(args.port, args.baud))
    # Boot from the ROM, as the reset button does
    link.control(HOLD)
    link.control(0)
    time.sleep(0.5)
    c = link.read_word(CONTROL)
    check("running from the ROM", c == 0, f"{c:08X}")
    check("paused", pause(link))
    words = link.read(SCREEN, 2000)
    check("welcome as niceemu", words[:800] == want[:800])
    c = link.read_word(SCR_CTL)
    check("cursor on, blinking", c == 0x60, f"{c:08X}")
    check("cursor at the top of the typewriter",
          (link.read_word(SCR_X), link.read_word(SCR_Y)) == (0, 10))
    link.control(0)
    link.send_console(KEYS)
    time.sleep(1.0)
    check("paused after the keys", pause(link))
    words = link.read(SCREEN, 2000)
    diff = [i for i in range(2000) if words[i] != want[i]]
    check("screen as niceemu, 2000 words", not diff,
          f"{len(diff)} differ, first at {diff[:5]}" if diff else "")
    cur = (link.read_word(SCR_X), link.read_word(SCR_Y))
    check("cursor as niceemu", cur == (col, row), f"{cur} vs {(col, row)}")
    show(words)
    link.control(0)
    time.sleep(0.2)
    check("running again", link.read_word(CONTROL) == 0)
    link.close()
    print("all passed" if not fails else f"{fails} failed")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
