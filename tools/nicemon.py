#!/usr/bin/env python3
"""The monitor for the NICE core on the MEGA65, on the host.

It talks to the board through the debug link (PROTOCOL.md, tools/nicelink.py)
and gives a command prompt to load programs, run, pause, and step them, look
at and change the memory and the registers, disassemble, set breakpoints and
watchpoints, and read the trace of the last steps. While the program runs,
the terminal is its console: what is typed goes to it, and what it prints
shows. Ctrl-C pauses it and gives the prompt back.

Usage: tools/nicemon.py [--port /dev/ttyUSB1] [--baud 2000000] [--wait X]
                        [-c "COMMAND; COMMAND; ..."] [FILE.bin]

With a FILE, it is loaded first. -c runs the commands, separated by ';', and
exits, so that the monitor can be scripted. --wait 1000 suits the
simulation of "make -C sim cosim", which is far slower than the board. Type "help" at the prompt for the
commands. Addresses and words are hex, with or without 0x; counts are
decimal. Only the Python standard library is used.
"""

import argparse
import cmd
import os
import shlex
import sys
import select
import termios
import time
from typing import Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import nicelink as nl                                    # noqa: E402
from nicedis import disassemble                          # noqa: E402

KINDS = {"exec": nl.EXEC, "read": nl.READ, "write": nl.WRITE,
         "rw": nl.READ | nl.WRITE}
SCREEN_WIDTH = 80
SCREEN_HEIGHT = 25
CTRL_C = b"\x03"


def hexnum(text: str) -> int:
    """A hex number, with or without 0x"""
    return int(text[2:] if text[:2].lower() == "0x" else text, 16) & 0xFFFFFFFF


def count(text: str) -> int:
    return int(text, 0)


class Monitor(cmd.Cmd):
    intro = 'NICE monitor. Type "help" for the commands.'
    prompt = "nice> "

    def __init__(self, link: nl.Link):
        super().__init__()
        self.link = link
        self.next_d: Optional[int] = None
        self.next_m: Optional[int] = None
        self.image: Optional[str] = None

    # -- Helpers -------------------------------------------------------------

    def emptyline(self) -> bool:
        return False

    def onecmd(self, line: str) -> bool:
        try:
            return super().onecmd(line)
        except (ValueError, IndexError) as e:
            print(f"error: {e}")
        except nl.LinkError as e:
            print(f"link: {e}")
        return False

    def show_output(self) -> None:
        data = self.link.console()
        if data:
            sys.stdout.buffer.write(data)
            sys.stdout.flush()

    def where(self) -> None:
        """Prints the next instruction."""
        pc = self.link.read1(nl.REGS + 15)
        self.disasm(pc, 1)
        self.next_d = pc

    def report(self, reason: int) -> None:
        self.show_output()
        print(f"\n[{nl.stop_text(reason)}]")
        if reason & 0x80:
            regs = self.link.regs()
            print(f"PC={regs[15]:08x}")
        else:
            self.where()

    def disasm(self, addr: int, n: int) -> int:
        words = self.link.read(addr, 4 * n + 3)
        i = 0
        for _ in range(n):
            text, k = disassemble(words[i:i + 4])
            raw = " ".join(f"{w:08x}" for w in words[i:i + k])
            print(f"{(addr + i) & 0xFFFFFFFF:08x}  {raw:<35} {text}")
            i += k
        return (addr + i) & 0xFFFFFFFF

    def run_console(self) -> None:
        """Is the console of the running program until it stops, or Ctrl-C
        pauses it."""
        link = self.link
        interactive = sys.stdin.isatty()
        old = termios.tcgetattr(0) if interactive else None
        if old is not None:
            # A key at a time, without echo, and Ctrl-C as a byte. The rest
            # stays, so Enter is a LF, as in the emulator, and a LF prints
            # as a new line.
            new = termios.tcgetattr(0)
            new[3] &= ~(termios.ICANON | termios.ECHO | termios.ISIG)
            new[6][termios.VMIN] = 1
            new[6][termios.VTIME] = 0
            termios.tcsetattr(0, termios.TCSANOW, new)
        reason = None
        try:
            while reason is None:
                self.show_output()
                if link.stops:
                    reason = link.stops.pop(0)
                    break
                if interactive:
                    r, _, _ = select.select([0, link.fd], [], [], 1.0)
                    if 0 in r:
                        data = os.read(0, 256)
                        if CTRL_C in data:
                            link.send_console(data[:data.index(CTRL_C)])
                            link.pause()
                            reason = link.wait_stop(2.0 * link.wait)
                            break
                        link.send_console(data)
                    if link.fd in r:
                        link.pump(0)
                else:
                    link.pump(1.0)
        finally:
            if old is not None:
                termios.tcsetattr(0, termios.TCSADRAIN, old)
        if reason is not None:
            self.report(reason)

    # -- Commands ------------------------------------------------------------

    def do_load(self, arg: str) -> None:
        """load FILE.bin
        Holds the core, clears the memory, hides the ROM, and writes the
        program. The core stays held; "run" starts it."""
        path = shlex.split(arg)[0]
        image = nl.read_bin(path)
        t = time.monotonic()
        self.link.load(image)
        self.image = path
        print(f"loaded {len(image)} words in {time.monotonic() - t:.2f} s")

    def do_run(self, arg: str) -> None:
        """run [FILE.bin]
        Starts the program from address 0, after loading FILE if given, and
        is its console until it stops. Ctrl-C pauses it."""
        if arg.strip():
            self.do_load(arg)
        else:
            self.link.hold()
        self.link.start()
        self.run_console()

    def do_start(self, arg: str) -> None:
        """start
        Starts the held core paused, before its first instruction, so that
        breakpoints can be set and the program stepped from the start."""
        self.link.start(paused=True)
        reason = self.link.wait_stop(2.0 * self.link.wait)
        if reason is None:
            print("the core did not stop")
            return
        self.report(reason)

    def do_reset(self, arg: str) -> None:
        """reset
        Holds the core in reset. "run" or "start" starts it again."""
        self.link.hold()

    def do_go(self, arg: str) -> None:
        """go
        Lets the paused core go on, and is its console until it stops."""
        if self.link.control() & nl.HOLD:
            self.link.start()
        else:
            self.link.go()
        self.run_console()

    do_c = do_go

    def do_pause(self, arg: str) -> None:
        """pause
        Pauses the running core."""
        self.link.pause()
        reason = self.link.wait_stop(2.0 * self.link.wait)
        if reason is None:
            print("the core did not stop: it is held, or halted")
        else:
            self.report(reason)

    def do_step(self, arg: str) -> None:
        """step [N]
        Runs N steps, 1 by default, and shows the next instruction. An
        interrupt entry is a step too."""
        n = count(arg) if arg.strip() else 1
        self.link.step(n)
        reason = self.link.wait_stop(5.0 * self.link.wait)
        if reason is None:
            print("still running; \"pause\" stops it")
        else:
            self.report(reason)

    do_s = do_step

    def do_regs(self, arg: str) -> None:
        """regs
        Prints R0-R15 and the flags of R14, and whether the core runs."""
        regs = self.link.regs()
        for row in range(4):
            print("  ".join(f"R{i:<2} {regs[i]:08x}" for i in range(4 * row, 4 * row + 4)))
        sr = regs[14]
        flags = "".join(f if sr >> (24 + i) & 1 else "-" for i, f in enumerate("1XCZNVEI"))
        ctl = self.link.control()
        state = ("held" if ctl & nl.HOLD else "halted" if ctl & nl.HALTED else
                 "paused" if ctl & nl.PAUSED else "running")
        print(f"flags {flags[::-1]}  {state}")

    do_r = do_regs

    def do_set(self, arg: str) -> None:
        """set ADDR WORD...
        Writes the words from ADDR upwards."""
        args = arg.split()
        self.link.write(hexnum(args[0]), [hexnum(a) for a in args[1:]])

    def do_m(self, arg: str) -> None:
        """m [ADDR] [N]
        Prints N words, 64 by default, from ADDR, with their low bytes as
        text. Without ADDR it goes on after the last m."""
        args = arg.split()
        addr = hexnum(args[0]) if args else (self.next_m or 0)
        n = count(args[1]) if len(args) > 1 else 64
        words = self.link.read(addr, n)
        for i in range(0, n, 8):
            row = words[i:i + 8]
            text = "".join(chr(w & 0xFF) if 0x20 <= w & 0xFF < 0x7F else "." for w in row)
            print(f"{(addr + i) & 0xFFFFFFFF:08x}: " +
                  " ".join(f"{w:08x}" for w in row) + "  " + text)
        self.next_m = (addr + n) & 0xFFFFFFFF

    def do_d(self, arg: str) -> None:
        """d [ADDR] [N]
        Disassembles N instructions, 16 by default, from ADDR, or from the
        next instruction of the core, or after the last d."""
        args = arg.split()
        if args:
            addr = hexnum(args[0])
        elif self.next_d is not None:
            addr = self.next_d
        else:
            addr = self.link.read1(nl.REGS + 15)
        n = count(args[1]) if len(args) > 1 else 16
        self.next_d = self.disasm(addr, n)

    def do_b(self, arg: str) -> None:
        """b [ADDR [exec|read|write|rw]]
        Sets a breakpoint, exec by default, or a watchpoint, in the first
        free one of the four, or lists them without ADDR."""
        args = arg.split()
        bps = self.link.breakpoints()
        if not args:
            for k, (addr, kind) in enumerate(bps):
                if kind:
                    names = [n for n, v in KINDS.items() if v & kind and n != "rw"]
                    print(f"{k}: {addr:08x} {','.join(names)}")
            return
        kind = KINDS[args[1]] if len(args) > 1 else nl.EXEC
        free = [k for k, (_, kd) in enumerate(bps) if kd == 0]
        if not free:
            print("all four are in use; \"bd K\" frees one")
            return
        self.link.set_breakpoint(free[0], hexnum(args[0]), kind)
        print(f"{free[0]}: {hexnum(args[0]):08x}")

    def do_bd(self, arg: str) -> None:
        """bd [K]
        Deletes breakpoint K, or all of them."""
        ks = [count(arg)] if arg.strip() else range(4)
        for k in ks:
            self.link.set_breakpoint(k, 0, 0)

    def do_trace(self, arg: str) -> None:
        """trace [N]
        Disassembles the last N steps, 20 by default, oldest first. The core
        must be paused or halted, or the steps move while they are read."""
        n = count(arg) if arg.strip() else 20
        for addr, iw, flags in self.link.trace(n):
            if flags & 1:
                kind = "NMI" if flags & 2 else "IRQ"
                print(f"{addr:08x}  {kind} vector {flags >> 8 & 0xFF:02x}")
                continue
            # The constant words are read back from the memory.
            words = [iw] + self.link.read(addr + 1, 3)
            text, _ = disassemble(words)
            note = "  (skipped)" if flags & 4 else ""
            print(f"{addr:08x}  {iw:08x}  {text}{note}")

    def do_screen(self, arg: str) -> None:
        """screen
        Prints the 80x25 characters of the screen."""
        words = self.link.read(nl.SCREEN, SCREEN_WIDTH * SCREEN_HEIGHT)
        for y in range(SCREEN_HEIGHT):
            row = words[y * SCREEN_WIDTH:(y + 1) * SCREEN_WIDTH]
            print("|" + "".join(chr(w & 0xFF) if 0x20 <= w & 0xFF < 0x7F else " "
                                for w in row).rstrip())

    def do_info(self, arg: str) -> None:
        """info
        Prints what the board says about itself."""
        info = self.link.read1(nl.INFO)
        print(f"protocol {info & 0xFF}, {info >> 8 & 0xF} breakpoints, "
              f"trace of {1 << (info >> 12 & 0xF)} steps, "
              f"RAM of {1 << (info >> 16 & 0x1F)} words")
        ctl = self.link.control()
        print("ROM hidden" if ctl & nl.RAM else "ROM shown")

    def do_quit(self, arg: str) -> bool:
        """quit
        Leaves the monitor. The core goes on as it is."""
        return True

    do_q = do_quit
    do_EOF = do_quit


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", default=nl.PORT)
    parser.add_argument("--baud", type=int, default=nl.BAUD)
    parser.add_argument("--wait", type=float, default=1.0,
                        help="wait this many times longer for answers, "
                             "such as 1000 for the simulation")
    parser.add_argument("-c", "--commands", help="run the commands and exit")
    parser.add_argument("file", nargs="?", help="a .bin file to load first")
    args = parser.parse_args()

    link = nl.Link.open(args.port, args.baud, args.wait)
    try:
        link.sync()
    except nl.LinkError as e:
        nl.fail(f"{e}; is the bitstream with the debug link on the board?")
    mon = Monitor(link)
    if args.file:
        mon.onecmd(f"load {args.file}")
    if args.commands:
        for c in args.commands.split(";"):
            if c.strip():
                print(f"{mon.prompt}{c.strip()}")
                mon.onecmd(c.strip())
        return
    try:
        mon.cmdloop()
    except KeyboardInterrupt:
        print()


if __name__ == "__main__":
    main()
