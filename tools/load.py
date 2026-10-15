#!/usr/bin/env python3
"""Load a .bin file into the MEGA65 through the command line interpreter.

Each word of the file is written with a W command, and the script waits for
the OK of each. The core is held in reset while the program is loaded, and
started afterwards unless --no-run is given.

Usage: tools/load.py [--port /dev/ttyUSB1] [--baud 115200] [--no-run] FILE.bin

--port names the serial device of the MEGA65's debug UART, /dev/ttyUSB1 by
default. Only the Python standard library is used, so this runs on Linux
and macOS.
"""

import argparse
import os
import sys
import termios
import time

CONTROL = 0xFFFFFFF0


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


def command(fd: int, line: str, timeout: float = 2.0) -> str:
    """Sends one command line, ended with CR alone, and returns the answer."""
    os.write(fd, line.encode("ascii") + b"\r")
    answer = b""
    end = time.monotonic() + timeout
    while not answer.endswith(b"\r\n"):
        if time.monotonic() > end:
            sys.exit(f"load.py: no answer to '{line}', got {answer!r}")
        answer += os.read(fd, 64)
    return answer.decode("ascii").strip()


def write(fd: int, addr: int, data: int) -> None:
    line = f"W {addr:08X} {data:08X}"
    answer = command(fd, line)
    if answer != "OK":
        sys.exit(f"load.py: '{line}' answered '{answer}'")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", default="/dev/ttyUSB1")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--no-run", action="store_true",
                        help="leave the core held in reset after loading")
    parser.add_argument("file")
    args = parser.parse_args()

    words = []
    with open(args.file) as f:
        for line in f:
            if line.strip():
                addr, data = line.split()
                words.append((int(addr, 16), int(data, 16)))

    fd = open_port(args.port, args.baud)
    write(fd, CONTROL, 1)
    for addr, data in words:
        write(fd, addr, data)
    print(f"load.py: loaded {len(words)} words from {args.file}")
    if not args.no_run:
        write(fd, CONTROL, 0)
        print("load.py: started the core")
    os.close(fd)


if __name__ == "__main__":
    main()
