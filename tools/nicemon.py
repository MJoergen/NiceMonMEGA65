#!/usr/bin/env python3
"""One front end for the board's host tools, with a subcommand for each.

    tools/nicemon.py load  (link) [--hold] [(--monitor | --bas) [--rom FILE] | --basic] FILE
    tools/nicemon.py run   (link) [--input FILE] [--dump ADDR:N]... [--screen] ... FILE
    tools/nicemon.py mon   (link) [--symbols FILE] [FILE]
    tools/nicemon.py sd    (link) [--slot N] ... (ls | get | put | del | mkdir | format)
    tools/nicemon.py nbd   (link) [--slot N] [--read-only] [--hold] [--listen ...]
    tools/nicemon.py flash --port DEVICE (--bit FILE [--erase] | --cor FILE --flash-slot N)
    tools/nicemon.py tftpd [--dir DIR] [--listen [ADDR:]PORT] [--retry-wait SEC] ...

(link) is one of --eth HOST[:PORT], --port DEVICE [--baud N], --tcp
[HOST:]PORT, and --cosim PORT, the link's options of boardlink.py, which
go after the subcommand. "nicemon.py SUBCOMMAND --help" lists a
subcommand's options, and tools/README.md describes each.

Each subcommand is a module of tools/lib/, a library that the others
import too: load.py, run.py, mon.py, sdcard.py, sdnbd.py, flash.py, and
tftpd.py (issue #166). A module gives its options to the parser that this front
end builds, with add_options(parser), and runs on the parsed options,
with command(parser, args); mon.py gives nice_cpu's debugger/nicedbg.py
its options and runs it on the parsed ones. A module is imported only
when its subcommand runs, so that flash's pyftdi, through spiflash.py,
is needed only there, and the others run on Linux and macOS with the
Python standard library alone.

The old names, tools/load.py and the others, call old_name() with their
subcommand, for one release (issue #156). It takes the options that
#156 renamed by their old names too, with a warning that names the new
one: load's --no-run, which is --hold, run's -i, -d, -s, and -2004,
which are --input, --dump, --screen, and --ide2004, flash's --slot,
which is --flash-slot, and tftpd's --addr and --port, which are
--listen [ADDR:]PORT, and --timeout, which is --retry-wait. The name is
nice_cpu's, as nicedbg, nicelink, and nicebin are, and is also the
project's and that of src/nicemon.vhd.

The subcommands look like one command: their errors, warnings, and
progress go to stderr after "nicemon.py SUBCOMMAND: ", and stdout carries
only the console and the data, with one set of exit codes, 1 for an
error, 2 for one of the command line, 130 after Ctrl-C, and 141 when
stdout closes early (cli.py). "nicemon.py help SUBCOMMAND" is
"nicemon.py SUBCOMMAND --help", and "nicemon.py --version" prints the
tags of this repository and of nice_cpu, from git describe.
"""

import argparse
import importlib
import os
import subprocess
import sys
from typing import NamedTuple, Sequence

from lib import cli
from lib.cli import PROG

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class Subcommand(NamedTuple):
    module: str                         # the module of tools/lib/ that runs it
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


# The options that #156 renamed, which the old names still take: the new
# name, and whether the option takes a value
RENAMED = {
    "load": {"--no-run": ("--hold", False)},
    "run": {"-i": ("--input", True), "-d": ("--dump", True),
            "-s": ("--screen", False), "-2004": ("--ide2004", False)},
    "flash": {"--slot": ("--flash-slot", True)},
    "tftpd": {"--timeout": ("--retry-wait", True),
              "--addr": ("--listen", True), "--port": ("--listen", True)},
}


def old_options(name: str, argv: Sequence[str]) -> list[str]:
    """argv of the old name of subcommand name, with the options that #156
    renamed given their new names, and a warning on stderr for each.
    tftpd's --addr ADDR and --port PORT become one --listen ADDR:PORT."""
    script = f"{SUBCOMMANDS[name].module}.py"
    renamed = RENAMED.get(name, {})
    out: list[str] = []
    listen = {"--addr": "0.0.0.0", "--port": "69"}
    merge = False
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--":
            out += argv[i:]
            break
        old, eq, value = (arg.partition("=") if arg.startswith("--")
                          else (arg, "", ""))
        if old not in renamed:
            out.append(arg)
            i += 1
            continue
        new, takes = renamed[old]
        form = "--listen [ADDR:]PORT" if new == "--listen" else new
        print(f"{script}: warning: {old} is {form} of {PROG} {name}; "
              f"V3.1 removes {script} and {old}", file=sys.stderr)
        if takes and not eq and i + 1 < len(argv):
            value = argv[i + 1]
            i += 1
        i += 1
        if new == "--listen":
            listen[old] = value
            merge = True
        elif takes:
            out += [new, value]
        else:
            out.append(new)
    if merge:
        out[:0] = ["--listen", f"{listen['--addr']}:{listen['--port']}"]
    return out


def old_name(name: str, argv: Sequence[str]) -> None:
    """Runs subcommand name for its old name, tools/load.py and the others,
    with the options that #156 renamed taken by their old names too."""
    main([name, *old_options(name, argv)])


def describe(path: str) -> str:
    """git describe of the checkout at path: its tag, and the commits
    after it, or "unknown" without git."""
    try:
        r = subprocess.run(["git", "-C", path, "describe", "--tags",
                            "--dirty"], capture_output=True, text=True,
                           timeout=10)
    except (OSError, subprocess.SubprocessError):
        return "unknown"
    return r.stdout.strip() if r.returncode == 0 else "unknown"


def version() -> str:
    """What --version prints: the tags of NiceMonMEGA65 and nice_cpu."""
    return (f"{PROG} {describe(REPO)}, nice_cpu "
            f"{describe(os.path.join(REPO, 'nice_cpu'))}")


def top_parser() -> argparse.ArgumentParser:
    """The parser of nicemon.py with no subcommand, for its help, its
    version, and its errors."""
    width = max(len(name) for name in SUBCOMMANDS)
    lines = [f"  {name:{width}}  {sub.help}"
             for name, sub in SUBCOMMANDS.items()]
    parser = argparse.ArgumentParser(
        prog=PROG, usage=f"{PROG} [-h] [--version] SUBCOMMAND [OPTIONS ...]",
        description=(__doc__ or "").splitlines()[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="subcommands:\n" + "\n".join(lines) + "\n\n"
        f"'{PROG} SUBCOMMAND --help' or '{PROG} help SUBCOMMAND' lists a "
        "subcommand's options.")
    parser.add_argument("--version", action="version", version=version(),
                        help="print the tags of this repository and of "
                        "nice_cpu, and exit")
    parser.add_argument("subcommand", metavar="SUBCOMMAND",
                        choices=[*SUBCOMMANDS, "help"])
    return parser


def main(argv: Sequence[str] | None = None) -> None:
    """Runs the subcommand that argv, sys.argv[1:] by default, starts with,
    with the exit codes of cli.py."""
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] == ["help"]:
        argv = argv[1:2] + ["--help"] if argv[1:] else ["--help"]
    if not argv or argv[0] not in SUBCOMMANDS:
        # Help, the version, or an error with the usage, exit status 2
        top_parser().parse_args(argv)
        top_parser().error("give a SUBCOMMAND")
    name, rest = argv[0], argv[1:]
    cli.start(name)
    try:
        run(name, rest)
    except KeyboardInterrupt:
        print(file=sys.stderr)
        cli.note("interrupted")
        sys.exit(cli.EXIT_INTERRUPT)
    except BrokenPipeError:
        # stdout closed early, as by "nicemon.py sd ls | head": exit
        # quietly, and keep Python from writing to the pipe again at exit
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        sys.exit(cli.EXIT_PIPE)


def run(name: str, argv: list[str]) -> None:
    """Imports the module of subcommand name, and runs it on argv."""
    module = importlib.import_module(f"lib.{SUBCOMMANDS[name].module}")
    parser_class = getattr(module, "PARSER", argparse.ArgumentParser)
    parser = parser_class(prog=cli.command, description=module.DESCRIPTION)
    module.add_options(parser)
    module.command(parser, parser.parse_args(argv))


if __name__ == "__main__":
    main()
