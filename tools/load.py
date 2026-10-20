#!/usr/bin/env python3
"""Load a .bin file into the MEGA65 through the debug link.

The core is held in reset, the ROM with the monitor, if the bitstream has
one, is hidden, so that the RAM is at 0, and the memory is cleared to 0, as
the emulator's is at the start. Then the words of the file are written,
and the core is started unless --no-run is given. The ROM stays hidden
until the reset button is pressed.

Usage: tools/load.py [--port /dev/ttyUSB1] [--baud 2000000] [--wait X]
                     [--no-run] FILE.bin

--port names the serial device of the MEGA65's debug UART, /dev/ttyUSB1 by
default. --wait 1000 suits the simulation of "make -C sim cosim". The link
is in tools/nicelink.py, and tools/nicemon.py is the monitor that does this
and more. Only the Python standard library is used, so this runs on Linux
and macOS.
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import nicelink as nl                                    # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", default=nl.PORT)
    parser.add_argument("--baud", type=int, default=nl.BAUD)
    parser.add_argument("--wait", type=float, default=1.0)
    parser.add_argument("--no-run", action="store_true",
                        help="leave the core held in reset after loading")
    parser.add_argument("file")
    args = parser.parse_args()

    image = nl.read_bin(args.file)
    link = nl.Link.open(args.port, args.baud, args.wait)
    try:
        link.sync()
        link.load(image)
        print(f"load.py: loaded {len(image)} words from {args.file}")
        if not args.no_run:
            link.start()
            print("load.py: started the core")
    except nl.LinkError as e:
        nl.fail(str(e))
    link.close()


if __name__ == "__main__":
    main()
