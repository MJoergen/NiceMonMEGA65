#!/usr/bin/env python3
"""An interactive shell on the debug link of nice_cpu/doc/DEBUG.md.

This is nice_cpu's debugger, debugger/nicedbg.py, on the board's links:
it reads and writes memory, loads a .bin file, starts, holds, pauses,
steps, and goes on, sets the breakpoints, shows and sets the registers,
and disassembles, with one short command each. "help" lists them, and
nice_cpu's debugger/README.md describes them.

The board adds its links, --eth and --cosim, to nicedbg's --tcp and
--port, with --baud at the rate of the board's UART after reset, and a
loader that refuses a word that the board has no memory at, as
tools/load.py does. A FILE is checked before the link opens, and loaded
at the start, with the processor held.

Usage: tools/mon.py (--eth HOST[:PORT] | --port DEVICE [--baud 230400]
                    | --tcp [HOST:]PORT | --cosim PORT) [--symbols FILE] [FILE.bin]

Only the Python standard library is used, so this runs on Linux and macOS.
"""

from boardlink import Link, add_arguments, open_link
from load import load_words, read_bin
# After boardlink, which puts nice_cpu's debugger/ on the path
import nicedbg


def load(link: Link, path: str) -> int:
    """Loads the .bin file at path, with the checks of the board's memory,
    and returns its number of words."""
    words = read_bin(path)
    load_words(link, words)
    return len(words)


def main() -> None:
    nicedbg.main(add_link_arguments=add_arguments, open_link=open_link,
                 load=load, check_file=read_bin)


if __name__ == "__main__":
    main()
