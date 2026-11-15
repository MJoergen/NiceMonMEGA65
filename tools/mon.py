#!/usr/bin/env python3
"""An interactive shell on the debug link of nice_cpu/doc/DEBUG.md.

This is nice_cpu's debugger, debugger/nicedbg.py, on the board's links:
it reads and writes memory, loads a .bin file, starts, holds, pauses,
steps, and goes on, sets the breakpoints, shows and sets the registers,
and disassembles, with one short command each. "help" lists them, one
on a line, "help CMD" describes one in full, and nice_cpu's
debugger/README.md describes them all.

The board adds its links, --eth and --cosim, to nicedbg's --tcp and
--port, with --baud at the rate of the board's UART after reset, and a
loader that refuses a word that the board has no memory at, as
tools/load.py does. A FILE is checked before the link opens, and loaded
at the start, with the processor held. In its console, the Enter key is
RETURN, CR, as on the board's keyboard, which runs the monitor's line.

Usage: tools/mon.py (--eth HOST[:PORT] | --port DEVICE [--baud 230400]
                    | --tcp [HOST:]PORT | --cosim PORT) [--symbols FILE] [FILE.bin]

Only the Python standard library is used, so this runs on Linux and macOS.
"""

import inspect
import os
import re
import sys
import termios

from boardlink import Link, add_arguments, open_link
from load import load_words, read_bin
# After boardlink, which puts nice_cpu's debugger/ on the path
import nicedbg


# What help says of each of nicedbg's commands, on the command's line. A
# command that nice_cpu adds has the first clause of its own description
# there until it has a line here. nice_cpu#190 asks for this help in
# nicedbg itself, and the table goes with it.
HELP = {
    "help": "lists the commands, or describes one in full",
    "status": "shows the state of the processor, the ROM, and the link",
    "regs": "shows R0 to R15",
    "r": "reads N words of memory from ADDR",
    "w": "writes words of memory from ADDR",
    "set": "writes a register of a paused processor",
    "pc": "shows the PC of a paused processor, or sets it",
    "ctl": "reads the control register, or writes it",
    "load": "loads a .bin file, and leaves the processor held",
    "run": "starts the program at 0 again",
    "hold": "holds the processor in reset",
    "go": "goes on from a pause, or starts a held processor",
    "pause": "pauses the running processor",
    "step": "runs N steps of a paused processor",
    "d": "disassembles N instructions from ADDR",
    "symbols": "reads the labels of a .sym file",
    "b": "sets a breakpoint at ADDR, or lists them",
    "bd": "disables breakpoint N, or all of them",
    "wp": "sets a watchpoint at ADDR, or lists them",
    "wpd": "disables watchpoint N, or all of them",
    "nmi": "raises an NMI with the vector VEC",
    "send": "sends text to the program",
    "eof": "ends the program's input",
    "console": "passes your keys to the program, until Ctrl-]",
    "quit": "leaves the shell, and the processor as it is",
}


# nice_cpu's debugger, by a name of its own, as main() puts the board's
# in place of nicedbg.Debugger
NiceDebugger = nicedbg.Debugger


def commands() -> list[str]:
    """The debugger's commands, in the order of nicedbg.py, without EOF,
    the Ctrl-D that quits."""
    return [name[3:] for name in vars(NiceDebugger)
            if name.startswith("do_") and name != "do_EOF"]


class Debugger(NiceDebugger):
    """nice_cpu's debugger, with a line for each command in its help, and
    the board's Enter key in its console."""

    def do_help(self, arg: str) -> None:
        """help [CMD]: lists the commands, one on a line, or describes one
        in full, also by its short name."""
        name = nicedbg.ALIASES.get(arg.strip(), arg.strip())
        if name:
            method = getattr(self, f"do_{name}", None)
            doc = inspect.getdoc(method) if method else None
            if doc:
                print(doc)
            else:
                super().do_help(name)   # which says that it knows none
            return
        # A description is "usage: text", and the usage has the short name
        rows = []
        for name in commands():
            doc = " ".join((inspect.getdoc(getattr(self, f"do_{name}"))
                            or name).split())
            usage, _, text = doc.partition(": ")
            rows.append((usage, HELP.get(name)
                         or re.split(r"[.:](?:\s|$)", text)[0]))
        width = max(len(usage) for usage, _ in rows)
        for usage, text in rows:
            print(f"{usage:{width}}  {text}")
        print("Numbers are hex. 'help CMD' says more about a command.")

    def do_console(self, arg: str) -> None:
        """console (c): passes the terminal through to the program, the keys
        to its input and its output to the screen, until Ctrl-]. Enter is
        RETURN, CR, as on the board's keyboard, which runs the monitor's
        line. Keys that its input buffer has no room for wait until the
        program reads."""
        fd = sys.stdin.fileno()
        if not os.isatty(fd):
            super().do_console(arg)     # which says that it needs one
            return
        # A terminal makes the Enter key's CR an LF, which the monitor's
        # line passes over, and nicedbg's console keeps that mode of the
        # terminal as it finds it (nice_cpu#189). So it is off while the
        # console runs.
        old = termios.tcgetattr(fd)
        new = termios.tcgetattr(fd)
        new[0] &= ~(termios.ICRNL | termios.INLCR | termios.IGNCR)
        termios.tcsetattr(fd, termios.TCSANOW, new)
        try:
            super().do_console(arg)
        finally:
            termios.tcsetattr(fd, termios.TCSANOW, old)


def load(link: Link, path: str) -> int:
    """Loads the .bin file at path, with the checks of the board's memory,
    and returns its number of words."""
    words = read_bin(path)
    load_words(link, words)
    return len(words)


def main() -> None:
    # nicedbg.main() makes its debugger by this name, and has no hook
    # for another class (nice_cpu#189)
    setattr(nicedbg, "Debugger", Debugger)
    nicedbg.main(add_link_arguments=add_arguments, open_link=open_link,
                 load=load, check_file=read_bin)


if __name__ == "__main__":
    main()
