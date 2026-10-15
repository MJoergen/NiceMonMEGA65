#!/usr/bin/env python3
"""Load a .bin file into the MEGA65 through the command line interpreter.

The core is held in reset, the ROM with the monitor, if the bitstream has
one, is hidden, so that the RAM is at 0, and the memory is cleared to 0, as
the emulator's is at the start. Then each word of the file is written with
a W command, and the core is started unless --no-run is given. The ROM
stays hidden until the reset button is pressed, which boots the monitor
again.

Usage: tools/load.py [--port /dev/ttyUSB1] [--baud 115200] [--no-run] FILE.bin

--port names the serial device of the MEGA65's debug UART, /dev/ttyUSB1 by
default. Only the Python standard library is used, so this runs on Linux
and macOS. tools/run.py and tools/hwtest.py use the functions here.
"""

import argparse
import os
import sys
import termios
import time
from typing import NoReturn

CONTROL = 0xFFFFFFF0
# Control bits: hold the core in reset, clear the memory first, and hide the
# ROM, so that the RAM is at 0.
HOLD = 1
CLEAR = 4
RAM = 8
# What the command line prints when the core halts
HALT_MESSAGE = b"\r\nHALT\r\n"


def fail(message: str) -> NoReturn:
    """Exits with the message, after the name of the running script."""
    sys.exit(f"{os.path.basename(sys.argv[0])}: {message}")


def open_port(name: str, baud: int) -> int:
    fd = os.open(name, os.O_RDWR | os.O_NOCTTY)
    attr = termios.tcgetattr(fd)
    speed = getattr(termios, f"B{baud}")
    # Raw 8-N-1, no flow control.
    attr[0] = 0                                                # iflag
    attr[1] = 0                                                # oflag
    attr[2] = termios.CS8 | termios.CREAD | termios.CLOCAL     # cflag
    attr[3] = 0                                                # lflag
    attr[4] = speed                                            # ispeed
    attr[5] = speed                                            # ospeed
    attr[6][termios.VMIN] = 0
    attr[6][termios.VTIME] = 1                                 # 0.1 s
    termios.tcsetattr(fd, termios.TCSANOW, attr)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def drain(fd: int, quiet: float = 0.5) -> bytes:
    """Reads until nothing has arrived for quiet seconds."""
    buf = b""
    end = time.monotonic() + quiet
    while time.monotonic() < end:
        data = os.read(fd, 4096)
        if data:
            buf += data
            end = time.monotonic() + quiet
    return buf


def read_until(fd: int, tail: bytes, timeout: float = 2.0) -> bytes:
    buf = b""
    end = time.monotonic() + timeout
    while not buf.endswith(tail) and time.monotonic() < end:
        buf += os.read(fd, 1)
    return buf


def command(fd: int, line: str, timeout: float = 2.0) -> str:
    """Sends one command line, ended with CR alone, and returns the answer.
    Input that arrived before, such as a halt message, is dropped."""
    termios.tcflush(fd, termios.TCIFLUSH)
    os.write(fd, line.encode("ascii") + b"\r")
    answer = b""
    end = time.monotonic() + timeout
    while not answer.endswith(b"\r\n"):
        if time.monotonic() > end:
            fail(f"no answer to '{line}', got {answer!r}")
        answer += os.read(fd, 64)
    return answer.decode("ascii", errors="replace").strip()


def write(fd: int, addr: int, data: int) -> None:
    line = f"W {addr:08X} {data:08X}"
    answer = command(fd, line)
    if answer != "OK":
        fail(f"'{line}' answered '{answer}'")


def read_bin(path: str) -> list[tuple[int, int]]:
    """The words of a .bin file, as (address, word)."""
    words: list[tuple[int, int]] = []
    with open(path) as f:
        for line in f:
            if line.strip():
                a, d = line.split()
                words.append((int(a, 16), int(d, 16)))
    return words


def pipelined(fd: int, lines: list[str], chunk: int = 64) -> list[str]:
    """Sends command lines in chunks, without waiting for each answer, for
    speed, and returns the answers in order."""
    answers: list[str] = []
    for i in range(0, len(lines), chunk):
        part = lines[i:i + chunk]
        os.write(fd, b"".join(f"{line}\r".encode("ascii") for line in part))
        got = b""
        end = time.monotonic() + 5
        while got.count(b"\r\n") < len(part) and time.monotonic() < end:
            got += os.read(fd, 4096)
        got_lines = got.decode("ascii", errors="replace").split("\r\n")[:-1]
        if len(got_lines) != len(part):
            fail(f"{len(got_lines)} answers to {len(part)} commands from "
                 f"'{part[0]}': {got[-200:]!r}")
        answers += got_lines
    return answers


def read_words(fd: int, addrs: list[int]) -> list[int]:
    """Reads the words at addrs with R commands, in order."""
    termios.tcflush(fd, termios.TCIFLUSH)
    answers = pipelined(fd, [f"R {a:08X}" for a in addrs])
    try:
        return [int(a, 16) for a in answers]
    except ValueError:
        fail(f"R commands answered {answers!r}")


def load_words(fd: int, words: list[tuple[int, int]]) -> None:
    """Holds the core, hides the ROM, clears the memory, and writes the
    words."""
    write(fd, CONTROL, HOLD | CLEAR | RAM)
    answers = pipelined(fd, [f"W {a:08X} {d:08X}" for a, d in words])
    for (addr, _), answer in zip(words, answers):
        if answer != "OK":
            fail(f"writing the word at {addr:08X} answered '{answer}'")


def start(fd: int) -> None:
    """Starts the core, with the ROM hidden. The program may print as soon as
    it starts, so this reads only up to the OK."""
    termios.tcflush(fd, termios.TCIFLUSH)
    os.write(fd, f"W {CONTROL:08X} {RAM:08X}\r".encode())
    if not read_until(fd, b"OK\r\n").endswith(b"OK\r\n"):
        fail("the core did not start")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", default="/dev/ttyUSB1")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--no-run", action="store_true",
                        help="leave the core held in reset after loading")
    parser.add_argument("file")
    args = parser.parse_args()

    words = read_bin(args.file)
    fd = open_port(args.port, args.baud)
    load_words(fd, words)
    print(f"load.py: loaded {len(words)} words from {args.file}")
    if not args.no_run:
        start(fd)
        print("load.py: started the core")
    os.close(fd)


if __name__ == "__main__":
    main()
