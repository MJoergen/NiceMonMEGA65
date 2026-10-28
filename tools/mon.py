#!/usr/bin/env python3
"""An interactive shell on the debug link of nice_cpu/doc/DEBUG.md.

It reads and writes memory, loads a .bin file, starts, holds, pauses,
steps, and goes on, sets the breakpoints, and shows the registers, with
one short command each. "help" lists them. Numbers are hex, with or without
0x. An empty line repeats a step.

The program's console output and the link's notices are shown as they
arrive, above the prompt. "send TEXT" sends console bytes to the program,
and "console" passes the terminal through to it, until Ctrl-] returns to
the prompt.

Usage: tools/mon.py [--port /dev/ttyUSB1] [--baud 2000000] [--tcp PORT]
                    [--cosim PORT] [FILE.bin]

A FILE is loaded at the start, with the core held. --port, --tcp, and
--cosim pick the link, as for tools/load.py. Only the Python standard
library is used, so this runs on Linux and macOS.
"""

import argparse
import cmd
import codecs
import os
import select
import sys
import termios
import threading

try:
    import readline
except ImportError:
    readline = None

from load import load_words, read_bin
from nicelink import (BRK_ADDR, BRK_COUNT, BRK_EN, CONTROL, FREE, HALT_REASON,
                      HALTED, HOLD, PAUSE, RAM, REGS, STOP, VERSION, Link,
                      LinkError, add_arguments, open_link)

# The halt reasons of DEBUG.md §6
REASONS = {
    1: "HALT",
    2: "reserved control instruction",
    3: "INT inside an interrupt routine",
    4: "RTI outside an interrupt routine",
    5: "step limit",
}

# The commands' short names
ALIASES = {
    "s": "step",
    "g": "go",
    "c": "console",
    "q": "quit",
    "exit": "quit",
}

# Ctrl-], which ends the console
CONSOLE_END = 0x1D

# The steps that a step command prints one by one, and the words a line of
# a read shows
STEP_LINES = 16
LINE_WORDS = 8


def number(text: str) -> int:
    """A hex number, with or without 0x."""
    try:
        value = int(text, 16)
    except ValueError:
        raise ValueError(f"'{text}' is not a hex number") from None
    if not 0 <= value <= 0xFFFFFFFF:
        raise ValueError(f"'{text}' does not fit in 32 bits")
    return value


class Monitor(cmd.Cmd):
    """The shell. A thread shows what arrives while the prompt waits, and
    the lock keeps it off the link while a command runs."""

    def __init__(self, link: Link) -> None:
        super().__init__()
        self.link = link
        self.prompt = "mon> "
        # Reentrant, as an empty line runs the step again inside onecmd
        self.lock = threading.RLock()
        self.at_prompt = False
        self.watcher: threading.Thread | None = None
        self.stopping = threading.Event()
        self.next_read = 0
        self.last = ""
        # The notices already shown
        self.seen = self._counts()

    # What arrives

    def _counts(self) -> tuple[int, int, int, int, int, int]:
        link = self.link
        return (link.pauses, len(link.breaks), len(link.halts), link.boots,
                link.overflows, link.bad)

    def _pc(self) -> str:
        try:
            return f"PC={self.link.read_word(REGS + 15):08x}"
        except LinkError:
            return "PC unknown"

    def pending(self, line_open: bool = False) -> bytes:
        """The console bytes that have arrived, and a line for each notice
        that has, on a line of its own. line_open is whether the output
        shown last ended inside a line. The lock is held."""
        data = self.link.take_console()
        pauses, breaks, halts, boots, overflows, bad = self.seen
        link = self.link
        lines = []
        lines += ["boot"] * (link.boots - boots)
        lines += ["input overflow"] * (link.overflows - overflows)
        lines += ["bad packet dropped"] * (link.bad - bad)
        for why in link.halts[halts:]:
            lines.append(f"halted: {REASONS.get(why, why)}, {self._pc()}")
        for n in link.breaks[breaks:]:
            lines.append(f"breakpoint {n}, {self._pc()}")
        if link.pauses - pauses > len(link.breaks) - breaks:
            lines.append(f"paused, {self._pc()}")
        self.seen = self._counts()
        for line in lines:
            if data[-1:] not in (b"", b"\n") or (not data and line_open):
                data += b"\n"
            data += f"[{line}]\n".encode()
        return data

    def show(self, data: bytes) -> None:
        """Shows what arrived on lines of its own, and the prompt again,
        with what was typed, if it waits."""
        if not data:
            return
        out = sys.stdout
        if self.at_prompt:
            out.write("\r\x1b[K")
        out.flush()
        out.buffer.write(data if data.endswith(b"\n") else data + b"\n")
        out.buffer.flush()
        if self.at_prompt:
            typed = readline.get_line_buffer() if readline else ""
            out.write(self.prompt + typed)
        out.flush()

    def watch(self) -> None:
        """The thread that shows what arrives between commands, until
        stop(). The descriptor is taken on each turn, as the one of --tcp
        and --cosim changes after "eof". A command may still close it
        before the select, which then fails or sees another descriptor of
        the same number; the poll, with the lock held, finds out."""
        while not self.stopping.is_set():
            with self.lock:
                fd = self.link.fileno()
            try:
                select.select([fd], [], [], 0.05)
            except (OSError, ValueError):
                pass
            with self.lock:
                try:
                    self.link.poll(0)
                    data = self.pending()
                except (LinkError, OSError) as e:
                    data = f"[{e}]\n".encode()
            self.show(data)

    def stop(self) -> None:
        """Ends the watcher, so the link can be closed."""
        self.stopping.set()
        if self.watcher is not None:
            self.watcher.join()

    # The loop

    def preloop(self) -> None:
        if self.watcher is None:
            self.watcher = threading.Thread(target=self.watch, daemon=True)
            self.watcher.start()
        self.at_prompt = True

    def precmd(self, line: str) -> str:
        self.at_prompt = False
        words = line.split(maxsplit=1)
        if words and words[0] in ALIASES:
            words[0] = ALIASES[words[0]]
            line = " ".join(words)
        return line

    def onecmd(self, line: str) -> bool:
        with self.lock:
            try:
                stop = super().onecmd(line)
            except (LinkError, ValueError) as e:
                print(f"error: {e}")
                stop = False
            except SystemExit as e:
                # The fail() of load.py, for a bad file
                print(e.code)
                stop = False
            except KeyboardInterrupt:
                print("^C")
                stop = False
            self.show(self.pending())
        return stop

    def postcmd(self, stop: bool, line: str) -> bool:
        self.at_prompt = True
        return stop

    def emptyline(self) -> bool:
        if self.last.split()[:1] == ["step"]:
            return self.onecmd(self.last)
        return False

    def default(self, line: str) -> None:
        print(f"unknown command '{line.split()[0]}'; 'help' lists them")

    def parseline(self, line: str):
        command, arg, line = super().parseline(line)
        if line:
            self.last = line
        return command, arg, line

    # Helpers

    def _rom_bit(self) -> int:
        """Bit 3 of the control register, which every write keeps."""
        return self.link.read_word(CONTROL) & RAM

    def _wait_notice(self, pauses: int, halts: int) -> None:
        """Waits for the p, x, or h that a pause request brings, after
        pauses and halts of them."""
        wait = 2 * self.link.transport.answer_wait(0)
        while self.link.pauses == pauses and len(self.link.halts) == halts:
            if not self.link.poll(wait):
                print("no pause yet; 'status' shows when it takes effect")
                return

    def _regs(self) -> None:
        regs = self.link.read(REGS, 16)
        for row in range(4):
            print(" ".join(f"R{i:<2} {regs[i]:08x}"
                           for i in range(4 * row, 4 * row + 4)))

    # The commands

    def do_status(self, arg: str) -> None:
        """status: the state of the core, the ROM, and the link."""
        link = self.link
        ctl = link.read_word(CONTROL)
        version = link.read_word(VERSION)
        if ctl & HALTED:
            why = link.read_word(HALT_REASON)
            state = f"halted: {REASONS.get(why, why)}"
            # A hold after a halt keeps bit 1 and the reason.
            if ctl & HOLD:
                state = f"held, after a halt: {REASONS.get(why, why)}"
        elif ctl & HOLD:
            state = "held"
        elif ctl & PAUSE:
            stop = link.read_word(STOP) if version >= 4 else 0
            state = f"at breakpoint {stop & 0xFF}" if stop & 0x100 \
                else "paused"
        else:
            state = "running"
        rom = "hidden" if ctl & RAM else "shown"
        print(f"{state}, ROM {rom}, control {ctl:08x}, link version "
              f"{version}, input free {link.read_word(FREE)}")
        if ctl & (HALTED | PAUSE):
            print(self._pc())

    def do_regs(self, arg: str) -> None:
        """regs: R0 to R15, which are defined while the core is paused, and
        after a halt."""
        self._regs()

    def do_r(self, arg: str) -> None:
        """r [ADDR [N]]: reads N words from ADDR, 16 by default. Without
        ADDR, it goes on after the last read."""
        args = arg.split()
        addr = number(args[0]) if args else self.next_read
        n = number(args[1]) if len(args) > 1 else 16
        words = self.link.read(addr, n)
        for i in range(0, n, LINE_WORDS):
            line = words[i:i + LINE_WORDS]
            print(f"{(addr + i) & 0xFFFFFFFF:08x}: " +
                  " ".join(f"{w:08x}" for w in line))
        self.next_read = (addr + n) & 0xFFFFFFFF

    def do_w(self, arg: str) -> None:
        """w ADDR WORD...: writes the words from ADDR. The control register
        has the commands hold, go, pause, step, and ctl."""
        args = [number(a) for a in arg.split()]
        if len(args) < 2:
            raise ValueError("give an address and at least one word")
        addr, words = args[0], args[1:]
        if addr <= CONTROL <= addr + len(words) - 1:
            raise ValueError("use ctl to write the control register")
        self.link.write(addr, words)

    def do_ctl(self, arg: str) -> None:
        """ctl [VALUE]: reads the control register, or writes it."""
        if arg.strip():
            self.link.control(number(arg.strip()))
        print(f"control {self.link.read_word(CONTROL):08x}")

    def do_load(self, arg: str) -> None:
        """load FILE: holds the core, hides the ROM, clears the memory,
        disables the breakpoints, and loads the .bin file. 'go' starts
        it."""
        if not arg.strip():
            raise ValueError("give the .bin file")
        words = read_bin(arg.strip())
        load_words(self.link, words)
        print(f"loaded {len(words)} words; the core is held in reset")

    def do_run(self, arg: str) -> None:
        """run: starts the program at 0 again, from a hold, a halt, a pause,
        or while it runs. The memory is not loaded again."""
        rom = self._rom_bit()
        self.link.control(HOLD | rom)
        self.link.control(rom)

    def do_hold(self, arg: str) -> None:
        """hold: holds the core in reset. A hold of a paused core keeps
        R0-R15, and a hold of a running one leaves them undefined."""
        self.link.control(HOLD | self._rom_bit())

    def do_go(self, arg: str) -> None:
        """go (g): goes on from a pause, or starts a held core at 0."""
        self.link.control(self._rom_bit())

    def do_pause(self, arg: str) -> None:
        """pause: pauses the running core, and shows where."""
        rom = self._rom_bit()
        # The notice may come while control() waits for its answer.
        pauses, halts = self.link.pauses, len(self.link.halts)
        self.link.control(PAUSE | rom)
        self._wait_notice(pauses, halts)

    def do_step(self, arg: str) -> None:
        """step (s) [N]: runs N steps of a paused core, 1 by default, and
        shows the PC after each, up to 16. It stops at a breakpoint and
        at a halt. An empty line steps again."""
        link = self.link
        n = number(arg.strip()) if arg.strip() else 1
        ctl = link.read_word(CONTROL)
        if not ctl & PAUSE:
            raise ValueError("the core is not paused; 'pause' first")
        for i in range(n):
            breaks = len(link.breaks)
            why = link.step(PAUSE | (ctl & RAM))
            # The step prints what it ends in, not the notice watcher.
            self.show(link.take_console())
            self.seen = self._counts()
            if why is not None:
                print(f"halted: {REASONS.get(why, why)}, {self._pc()}")
                return
            if len(link.breaks) > breaks:
                print(f"breakpoint {link.breaks[-1]}, {self._pc()}")
                return
            if n <= STEP_LINES or i == n - 1:
                print(self._pc())

    def do_b(self, arg: str) -> None:
        """b [ADDR]: sets a breakpoint at ADDR in a free slot, or, without
        ADDR, lists them."""
        link = self.link
        count = link.read_word(BRK_COUNT)
        if count == 0:
            raise ValueError("this system has no breakpoints")
        en = link.read_word(BRK_EN)
        addrs = link.read(BRK_ADDR, count)
        if not arg.strip():
            for i in range(count):
                if en >> i & 1:
                    print(f"{i}: {addrs[i]:08x}")
            if not en:
                print(f"no breakpoints; {count} free")
            return
        addr = number(arg.strip())
        free = [i for i in range(count) if not en >> i & 1]
        if not free:
            raise ValueError(f"all {count} breakpoints are set; 'bd' one")
        link.write(BRK_ADDR + free[0], [addr])
        link.write(BRK_EN, [en | 1 << free[0]])
        print(f"{free[0]}: {addr:08x}")

    def do_bd(self, arg: str) -> None:
        """bd N|all: disables breakpoint N, or all of them."""
        if arg.strip() == "all":
            self.link.write(BRK_EN, [0])
            return
        if not arg.strip():
            raise ValueError("give the breakpoint's number, or all")
        en = self.link.read_word(BRK_EN)
        self.link.write(BRK_EN, [en & ~(1 << number(arg.strip()))])

    def do_send(self, arg: str) -> None:
        r"""send TEXT: sends the text to the program, with escapes such as
        \n, \r, and \x1b."""
        text = codecs.decode(arg, "unicode_escape")
        self.link.send_console(text.encode("latin-1"))

    def do_eof(self, arg: str) -> None:
        """eof: ends the program's input, as the end of a file does."""
        self.link.end_input()

    def do_console(self, arg: str) -> None:
        """console (c): passes the terminal through to the program, the keys
        to its input and its output to the screen, until Ctrl-]."""
        fd = sys.stdin.fileno()
        old = termios.tcgetattr(fd)
        new = termios.tcgetattr(fd)
        new[0] &= ~termios.IXON
        new[3] &= ~(termios.ICANON | termios.ECHO | termios.ISIG |
                    termios.IEXTEN)
        new[6][termios.VMIN] = 1
        new[6][termios.VTIME] = 0
        print("console; Ctrl-] returns to the prompt")
        link = self.link
        line_open = False
        try:
            termios.tcsetattr(fd, termios.TCSANOW, new)
            while True:
                data = self.pending(line_open)
                if data:
                    sys.stdout.buffer.write(data)
                    sys.stdout.buffer.flush()
                    line_open = not data.endswith(b"\n")
                ready, _, _ = select.select([fd, link.fileno()], [], [], 0.1)
                if link.fileno() in ready:
                    link.poll(0)
                if fd in ready:
                    keys = os.read(fd, 1024)
                    end = keys.find(bytes([CONSOLE_END]))
                    if end >= 0:
                        link.send_console(keys[:end])
                        break
                    link.send_console(keys)
        finally:
            termios.tcsetattr(fd, termios.TCSANOW, old)
            if line_open:
                print()

    def do_quit(self, arg: str) -> bool:
        """quit (q): leaves the core as it is, and quits."""
        return True

    def do_EOF(self, arg: str) -> bool:
        """Ctrl-D quits."""
        print()
        return True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    add_arguments(parser)
    parser.add_argument("file", nargs="?",
                        help="a .bin file to load, with the core held: one "
                        "'address word' hex pair per line")
    args = parser.parse_args()

    link = open_link(args)
    mon = Monitor(link)
    mon.onecmd(f"load {args.file}" if args.file else "status")
    mon.intro = "'help' lists the commands, and 'q' quits."
    while True:
        try:
            mon.cmdloop()
            break
        except KeyboardInterrupt:
            print("^C")
            mon.intro = None
    mon.stop()
    link.close()


if __name__ == "__main__":
    main()
