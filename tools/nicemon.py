#!/usr/bin/env python3
"""One front end for the board's host tools, with a subcommand for each.

    tools/nicemon.py load  (link) [--no-run] [--monitor [--rom FILE] | --basic] FILE
    tools/nicemon.py run   (link) [-i FILE] [-d ADDR:N]... [-s] ... FILE
    tools/nicemon.py mon   (link) [--symbols FILE] [FILE]
    tools/nicemon.py sd    (link) [--slot N] ... (ls | get | put | del | mkdir | format)
    tools/nicemon.py nbd   (link) [--slot N] [--read-only] [--hold] [--listen ...]
    tools/nicemon.py flash --port DEVICE (--bit FILE [--erase] | --cor FILE --slot N)
    tools/nicemon.py tftpd [--dir DIR] [--addr ADDR] [--port PORT] ...

(link) is one of --eth HOST[:PORT], --port DEVICE [--baud N], --tcp
[HOST:]PORT, and --cosim PORT, the link's options of boardlink.py, which
go after the subcommand. "nicemon.py SUBCOMMAND --help" lists a
subcommand's options, and tools/README.md describes each.

Each subcommand is a module of tools/, which stays a library that the
others import: load.py, run.py, mon.py, sdcard.py, sdnbd.py, flash.py,
and tftpd.py. A module gives its options to the parser that this front
end builds, with add_options(parser), and runs on the parsed options,
with command(parser, args); mon.py passes its arguments on to nice_cpu's
debugger/nicedbg.py, which parses them itself. A module is imported only
when its subcommand runs, so that flash's pyftdi, through spiflash.py,
is needed only there, and the others run on Linux and macOS with the
Python standard library alone.

The old names, tools/load.py and the others, call this with their
subcommand, for one release (issue #156). The name is nice_cpu's, as
nicedbg, nicelink, and nicebin are, and is also the project's and that
of src/nicemon.vhd.
"""

import argparse
import importlib
import sys
from typing import NamedTuple, Sequence

PROG = "nicemon.py"


class Subcommand(NamedTuple):
    module: str                         # the module of tools/ that runs it
    help: str                           # its line in nicemon.py --help


SUBCOMMANDS = {
    "load": Subcommand("load", "load a .bin file into the board, and start "
                       "it"),
    "run": Subcommand("run", "run a program on the board as niceemu runs "
                      "it"),
    "mon": Subcommand("mon", "an interactive shell on the debug link"),
    "sd": Subcommand("sdcard", "list, copy, write, and delete the files of "
                     "the SD card"),
    "nbd": Subcommand("sdnbd", "serve the SD card over NBD, for a mount on "
                      "the host"),
    "flash": Subcommand("flash", "write a board's flash, from which it "
                        "starts"),
    "tftpd": Subcommand("tftpd", "a TFTP server for BASIC's LOAD and DIR"),
}


def top_parser() -> argparse.ArgumentParser:
    """The parser of nicemon.py with no subcommand, for its help and its
    errors."""
    width = max(len(name) for name in SUBCOMMANDS)
    lines = [f"  {name:{width}}  {sub.help}"
             for name, sub in SUBCOMMANDS.items()]
    parser = argparse.ArgumentParser(
        prog=PROG, usage=f"{PROG} [-h] SUBCOMMAND [OPTIONS ...]",
        description=(__doc__ or "").splitlines()[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="subcommands:\n" + "\n".join(lines) + "\n\n"
        f"'{PROG} SUBCOMMAND --help' lists a subcommand's options.")
    parser.add_argument("subcommand", metavar="SUBCOMMAND",
                        choices=SUBCOMMANDS)
    return parser


def main(argv: Sequence[str] | None = None) -> None:
    """Runs the subcommand that argv, sys.argv[1:] by default, starts with."""
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or argv[0] not in SUBCOMMANDS:
        # Help, or an error with the usage, exit status 2
        top_parser().parse_args(argv)
        return
    name, rest = argv[0], argv[1:]
    module = importlib.import_module(SUBCOMMANDS[name].module)
    if name == "mon":
        module.main(rest)
        return
    parser_class = getattr(module, "PARSER", argparse.ArgumentParser)
    parser = parser_class(prog=f"{PROG} {name}",
                          description=module.DESCRIPTION)
    module.add_options(parser)
    module.command(parser, parser.parse_args(rest))


if __name__ == "__main__":
    main()
