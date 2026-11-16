#!/usr/bin/env python3
"""Check the monitor's clock from a real-time clock at the cold start, and
TIME's write of one, in niceemu.

Usage: test/rtc.py NICEEMU MONITOR.bin

niceemu has no I2C master: the master's words at 0xFFFFFF97 to 9D are
memory there. So a .bin file behind the monitor's sets them before the
start: the status to 1, a master that is present and never busy, and the
data to the registers 0 to 15 of the R6's RV-3032-C7. To the monitor
every transaction then ends at once with no error, and its clock_rtc reads
those registers at the cold start as the chip's. niceemu runs with
--step-time, so the clock starts at 0, not set, and counts a microsecond
a step.

For each row of CASES the monitor starts on the registers of the row,
and TIME must show the row's date and time, or that the clock is not
set: dates and times that the chip can hold, with the bits that are no
digits set; the chip's two flags that say that it lost its time; no
master; a digit over 9 in each register, which made the year 2100 or
2105 once; and numbers that are no date or time.

Then TIME with a date and a time is typed. Without a master it must
leave the master's words alone. With one, in the years 2000 to 2099, the
command left is the write of the chip's status, the last of the two, and
in another year the read of the cold start. A cold start with the clock
set, by TIME and SYS 0, must leave it as it is, and not take the chip's.

The R3's ISL12020M is read only when the R6's chip does not answer,
which memory cannot do. So the second part runs niceemu --link, with
nice_cpu's debugger/nicelink.py, and --no-cycle-counter, so that the
clock's words are memory too, which the monitor writes and the script
reads. A watchpoint stops the core after each write of the master's
command, and the script answers it as the chip of the case would, the
RV-3032-C7, the ISL12020M, or none, and goes on. For each row of LINKED
the monitor starts with a chip of those registers, and must make those
transactions and set the clock's seconds and microseconds so, or leave
them at 0; the ISL12020M's 24-hour and 12-hour modes, its RTCF, a digit
over 9, and no chip at all among them. For each row of TYPED, TIME is
typed, and the transactions that it makes, with their data, must be
those that the row gives, which the script computes from the date and
the time.

Exits with status 1 when a check fails. Only the Python standard library
is used, with nicelink.py.
"""

import calendar
import os
import re
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                                "nice_cpu", "debugger"))
from nicelink import HOLD, PAUSE, RAM, WCH_WRITE, Link, Tcp, wait_boot  # noqa: E402

I2C_CMD = 0xFFFFFF97
I2C_STATUS = 0xFFFFFF98
I2C_DATA = 0xFFFFFF99
PRESENT = 1
STEPS = 2_000_000
NOT_SET = "Clock not set"
READ = 0x000E00D1           # the cold start's read: 14 bytes from register 0
WRITE = 0x00010D51          # time's last write: 1 byte to register 0x0D


def regs(hundredths: int = 0x25, sec: int = 0x56, minute: int = 0x34,
         hour: int = 0x12, wday: int = 3, date: int = 0x11,
         month: int = 0x11, year: int = 0x26,
         status: int = 0) -> list[int]:
    """The four words of the master's data with the RV-3032-C7's registers
    0 to 15, byte 0 in bits 7..0 of the first: by default 2026-11-11
    12:34:56.25, a Wednesday, and a status with no flags."""
    return [hundredths | sec << 8 | minute << 16 | hour << 24,
            wday | date << 8 | month << 16 | year << 24, 0, status << 8]


GOOD = "2026-11-11 12:34:56"
# The name of each case, the master's status, its data, and what time shows
CASES = [
    ("a date and a time", PRESENT, regs(), GOOD),
    ("the bits that are no digits set", PRESENT,
     regs(sec=0xD6, minute=0xB4, hour=0xD2, date=0xD1, month=0xF1), GOOD),
    ("the first second that the chip holds", PRESENT,
     regs(0, 0, 0, 0, 6, 1, 1, 0), "2000-01-01 00:00:00"),
    ("the last second but one", PRESENT,
     regs(0x90, 0x58, 0x59, 0x23, 4, 0x31, 0x12, 0x99),
     "2099-12-31 23:59:58"),
    ("a leap day", PRESENT, regs(date=0x29, month=0x02, year=0x24),
     "2024-02-29 12:34:56"),
    ("VLF, the chip lost its time", PRESENT, regs(status=1), NOT_SET),
    ("PORF, the chip lost its time", PRESENT, regs(status=2), NOT_SET),
    ("no master", 0, regs(), NOT_SET),
    ("year 0A", PRESENT, regs(year=0x0A), NOT_SET),
    ("year A5", PRESENT, regs(year=0xA5), NOT_SET),
    ("year FF", PRESENT, regs(year=0xFF), NOT_SET),
    ("hundredths 0A", PRESENT, regs(hundredths=0x0A), NOT_SET),
    ("hundredths A0", PRESENT, regs(hundredths=0xA0), NOT_SET),
    ("seconds 5A", PRESENT, regs(sec=0x5A), NOT_SET),
    ("seconds 60", PRESENT, regs(sec=0x60), NOT_SET),
    ("minutes 3A", PRESENT, regs(minute=0x3A), NOT_SET),
    ("minutes 60", PRESENT, regs(minute=0x60), NOT_SET),
    ("hours 1A", PRESENT, regs(hour=0x1A), NOT_SET),
    ("hours 24", PRESENT, regs(hour=0x24), NOT_SET),
    ("date 00", PRESENT, regs(date=0x00), NOT_SET),
    ("date 1A", PRESENT, regs(date=0x1A), NOT_SET),
    ("date 31 of November", PRESENT, regs(date=0x31), NOT_SET),
    ("February 29 of 2026", PRESENT, regs(date=0x29, month=0x02), NOT_SET),
    ("month 00", PRESENT, regs(month=0x00), NOT_SET),
    ("month 0A", PRESENT, regs(month=0x0A), NOT_SET),
    ("month 13", PRESENT, regs(month=0x13), NOT_SET),
]

failed = False


def check(name: str, ok: bool, detail: str = "") -> None:
    global failed
    print(f"[{'PASS' if ok else 'FAIL'}] {name}"
          + (f": {detail}" if not ok else ""))
    failed = failed or not ok


def run(emu: str, monitor: str, status: int, data: list[int], keys: str,
        tmp: str) -> tuple[list[str], list[int]]:
    """Starts the monitor on a master of that status and data, and types
    the keys. The rows of the console output, the last the line being
    typed, and the master's command, status, and first word of data at
    the end, which is niceemu's step limit, as the monitor waits for a
    key."""
    with open(monitor) as f:
        words = f.read()
    words += f"{I2C_STATUS:08X} {status:08X}\n"
    words += "".join(f"{I2C_DATA + i:08X} {w:08X}\n"
                     for i, w in enumerate(data))
    with open(f"{tmp}/rtc.bin", "w") as f:
        f.write(words)
    with open(f"{tmp}/keys.txt", "w", newline="") as f:
        f.write(keys)
    out = subprocess.run(
        [emu, "-s", "-n", str(STEPS), "--step-time", "-i", f"{tmp}/keys.txt",
         "-d", f"0x{I2C_CMD:08X}:3", f"{tmp}/rtc.bin"],
        capture_output=True, text=True, errors="replace").stdout
    text, _, dump = out.partition("Stopped at the step limit")
    rows = text.replace("\r", "").split("\n")
    mem = [int(w, 16) for line in dump.split("\n")
           if line.startswith(f"{I2C_CMD:08x}:") for w in line.split()[1:]]
    return rows, mem


def after(rows: list[str], command: str) -> str:
    """The row that the monitor printed after the last statement typed so."""
    prompts = [i for i, row in enumerate(rows) if row == command]
    return rows[prompts[-1] + 1] if prompts else "no " + command


# The linked part: the chips' addresses, the clock's words, and the
# commands of the transactions
RV3032 = 0x51
ISL12020M = 0x6F
CLOCK_USEC = 0xFFFFFF46
CLOCK_SEC_LO = 0xFFFFFF47
CLOCK_SEC_HI = 0xFFFFFF48
CLOCK_STATUS = 0xFFFFFF49
NACK = 4
RV_READ = 0x000E00D1        # 14 bytes from register 0 of the RV-3032-C7
ISL_READ = 0x000800EF       # 8 bytes from register 0 of the ISL12020M
LINK_WAIT = 10.0            # the seconds that a run of the core may take


def bcd(n: int) -> int:
    return n // 10 << 4 | n % 10


def isl(sec: int = 0x56, minute: int = 0x34, hour: int = 0x92, date: int = 0x11,
        month: int = 0x11, year: int = 0x26, wday: int = 3, status: int = 0) -> list[int]:
    """The ISL12020M's registers 0 to 15: by default 2026-11-11 12:34:56,
    a Wednesday, in 24-hour mode, bit 7 of the hours, and a status with
    no flags."""
    return [sec, minute, hour, date, month, year, wday, status] + [0] * 8


def rv(hundredths: int = 0x25, sec: int = 0x56, minute: int = 0x34, hour: int = 0x12,
       wday: int = 3, date: int = 0x11, month: int = 0x11, year: int = 0x26,
       status: int = 0) -> list[int]:
    """The RV-3032-C7's registers 0 to 15, as regs() has them."""
    return [hundredths, sec, minute, hour, wday, date, month, year] + [0] * 5 + [status, 0, 0]


def at(text: str, usec: int = 0) -> tuple[int, int, int]:
    """The clock's words for a date and a time: its seconds since 1970, low
    and high, and its microseconds."""
    sec = calendar.timegm(time.strptime(text, "%Y-%m-%d %H:%M:%S"))
    return sec, 0, usec


UNSET = (0, 0, 0)
# The name of each case, the chip, its registers, the transactions of the
# cold start, and the clock's words that it leaves
LINKED = [
    ("RV-3032-C7, with its hundredths", RV3032, rv(), [RV_READ],
     at("2026-11-11 12:34:56", 250000)),
    ("RV-3032-C7, VLF", RV3032, rv(status=1), [RV_READ], UNSET),
    ("ISL12020M, 24-hour mode", ISL12020M, isl(), [RV_READ, ISL_READ],
     at("2026-11-11 12:34:56")),
    ("ISL12020M, 24-hour mode, 23 h", ISL12020M, isl(hour=0xA3), [RV_READ, ISL_READ],
     at("2026-11-11 23:34:56")),
    ("ISL12020M, the bits that are no digits set", ISL12020M,
     isl(sec=0xD6, minute=0xB4, date=0xD1, month=0xF1), [RV_READ, ISL_READ],
     at("2026-11-11 12:34:56")),
    ("ISL12020M, 12 AM is 0 h", ISL12020M, isl(hour=0x12), [RV_READ, ISL_READ],
     at("2026-11-11 00:34:56")),
    ("ISL12020M, 1 AM", ISL12020M, isl(hour=0x01), [RV_READ, ISL_READ],
     at("2026-11-11 01:34:56")),
    ("ISL12020M, 11 AM", ISL12020M, isl(hour=0x11), [RV_READ, ISL_READ],
     at("2026-11-11 11:34:56")),
    ("ISL12020M, 12 PM is 12 h", ISL12020M, isl(hour=0x32), [RV_READ, ISL_READ],
     at("2026-11-11 12:34:56")),
    ("ISL12020M, 1 PM", ISL12020M, isl(hour=0x21), [RV_READ, ISL_READ],
     at("2026-11-11 13:34:56")),
    ("ISL12020M, 11 PM", ISL12020M, isl(hour=0x31), [RV_READ, ISL_READ],
     at("2026-11-11 23:34:56")),
    ("ISL12020M, hour 0 of 12-hour mode", ISL12020M, isl(hour=0x00),
     [RV_READ, ISL_READ], UNSET),
    ("ISL12020M, hour 13 of 12-hour mode", ISL12020M, isl(hour=0x13),
     [RV_READ, ISL_READ], UNSET),
    ("ISL12020M, hour 1A of 12-hour mode", ISL12020M, isl(hour=0x1A),
     [RV_READ, ISL_READ], UNSET),
    ("ISL12020M, hour 24 of 24-hour mode", ISL12020M, isl(hour=0xA4),
     [RV_READ, ISL_READ], UNSET),
    ("ISL12020M, RTCF", ISL12020M, isl(status=1), [RV_READ, ISL_READ], UNSET),
    ("ISL12020M, seconds 5A", ISL12020M, isl(sec=0x5A), [RV_READ, ISL_READ], UNSET),
    ("ISL12020M, year A0", ISL12020M, isl(year=0xA0), [RV_READ, ISL_READ], UNSET),
    ("ISL12020M, February 29 of 2024", ISL12020M, isl(date=0x29, month=0x02, year=0x24),
     [RV_READ, ISL_READ], at("2024-02-29 12:34:56")),
    ("no chip that answers", 0, isl(), [RV_READ, ISL_READ], UNSET),
]


def writes(chip: int, text: str) -> list[tuple[int, int, int]]:
    """The transactions that TIME "text" makes, each a command and the two
    words of data written, for a chip at that address, or none."""
    t = time.strptime(text, "%Y-%m-%d %H:%M:%S")
    wday = (calendar.timegm(t) // 86400 + 4) % 7
    hms = bcd(t.tm_sec) | bcd(t.tm_min) << 8 | bcd(t.tm_hour) << 16
    dmy = bcd(t.tm_mday) | bcd(t.tm_mon) << 8 | bcd(t.tm_year - 2000) << 16
    rv_write = (0x00070151, hms | wday << 24, dmy)
    if chip == RV3032:
        return [rv_write, (0x00010D51, 0, 0)]
    wrtc = (0x0001086F, 0x41, 0)
    if chip != ISL12020M:
        return [rv_write, wrtc]
    return [rv_write, wrtc,
            (0x0007006F, hms | 0x800000 | (dmy & 0xFF) << 24, dmy >> 8 | wday << 16),
            (0x0001086F, 1, 0)]


# The name of each case, the chip, and the date and the time typed
TYPED = [
    ("RV-3032-C7", RV3032, "2027-03-04 05:06:07"),
    ("RV-3032-C7, a Sunday", RV3032, "2026-11-15 23:59:58"),
    ("ISL12020M", ISL12020M, "2027-03-04 05:06:07"),
    ("ISL12020M, a Saturday", ISL12020M, "2099-12-26 18:00:00"),
    ("no chip that answers", 0, "2000-01-01 00:00:00"),
]


class Chips:
    """The chip at an address, with its 16 registers, as the master's
    transactions read and write them, and the transactions made, each the
    command and the two words of data written."""

    def __init__(self, chip: int, regs: list[int], seen: int) -> None:
        self.chip = chip
        self.regs = list(regs)
        self.done: list[tuple[int, int, int]] = []
        # The watchpoints' stops answered
        self.seen = seen

    def answer(self, link: Link) -> None:
        cmd = link.read_word(I2C_CMD)
        data = link.read(I2C_DATA, 4)
        self.done.append((cmd, data[0], data[1]))
        reg, count = cmd >> 8 & 0xFF, min(cmd >> 16 & 0x1F, 16)
        if cmd & 0x7F != self.chip:
            link.write(I2C_STATUS, [PRESENT | NACK])
            return
        if cmd & 0x80:
            got = bytearray(b"".join(w.to_bytes(4, "little") for w in data))
            for i in range(count):
                got[i] = self.regs[(reg + i) % 16]
            link.write(I2C_DATA, [int.from_bytes(got[i:i + 4], "little")
                                  for i in range(0, 16, 4)])
        else:
            sent = b"".join(w.to_bytes(4, "little") for w in data)
            for i in range(count):
                self.regs[(reg + i) % 16] = sent[i]
        link.write(I2C_STATUS, [PRESENT])


def start_link(emu: str) -> tuple[subprocess.Popen[bytes], Link]:
    """niceemu --link on a free port, with the clock's words as memory,
    and the link to it."""
    proc = subprocess.Popen([emu, "--link", "127.0.0.1:0", "--no-cycle-counter"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    assert proc.stderr is not None
    m = re.search(r"link: port (\d+)", proc.stderr.readline().decode(errors="replace"))
    if not m:
        proc.terminate()
        sys.exit("rtc.py: niceemu --link printed no port")
    link = Link(Tcp(int(m.group(1))))
    wait_boot(link, "niceemu --link")
    return proc, link


def until_ready(link: Link, chips: Chips) -> str:
    """Runs the core, answering the master's transactions, until the
    console has shown READY., and pauses it. The console's text."""
    text = ""
    end = time.monotonic() + LINK_WAIT
    while "READY." not in text and time.monotonic() < end:
        link.poll(0.05)
        text += link.take_console().decode("latin-1")
        if len(link.watches) > chips.seen:
            chips.seen = len(link.watches)
            chips.answer(link)
            link.control(RAM)
    pauses = link.pauses
    link.control(PAUSE | RAM)
    while link.pauses == pauses and time.monotonic() < end:
        link.poll(0.05)
    return text


def linked(emu: str, monitor: str) -> None:
    words: dict[int, int] = {}
    with open(monitor) as f:
        for line in f:
            a, w = line.split()
            words[int(a, 16)] = int(w, 16)
    proc, link = start_link(emu)
    try:
        link.control(HOLD | RAM)
        addrs = sorted(words)
        i = 0
        while i < len(addrs):
            j = i + 1
            while j < len(addrs) and addrs[j] == addrs[j - 1] + 1:
                j += 1
            link.write(addrs[i], [words[a] for a in addrs[i:j]])
            i = j
        link.set_watches([(I2C_CMD, WCH_WRITE)])

        def cold(chip: int, regs: list[int]) -> tuple[Chips, str]:
            link.control(HOLD | RAM)
            link.write(I2C_CMD, [0, PRESENT, 0, 0, 0, 0])
            link.write(CLOCK_USEC, [0, 0, 0, 0])
            chips = Chips(chip, regs, len(link.watches))
            link.take_console()
            link.control(RAM)
            return chips, until_ready(link, chips)

        for name, chip, regs, done, want in LINKED:
            chips, text = cold(chip, regs)
            got = tuple(link.read(CLOCK_USEC, 3))
            got = (got[1], got[2], got[0])
            check(f"linked cold start, {name}",
                  "READY." in text and [c for c, _, _ in chips.done] == done and got == want,
                  f"transactions {[f'{c:08X}' for c, _, _ in chips.done]}, clock {got}")
        for name, chip, typed in TYPED:
            chips, text = cold(chip, isl() if chip == ISL12020M else rv())
            chips.done.clear()
            link.control(RAM)
            link.send_console(f'time "{typed}"\r'.encode())
            until_ready(link, chips)
            sent = writes(chip, typed)
            check(f"linked time typed, {name}: {typed}", chips.done == sent,
                  "got " + " ".join(f"{c:08X}:{lo:08X}:{hi:08X}" for c, lo, hi in chips.done)
                  + ", want " + " ".join(f"{c:08X}:{lo:08X}:{hi:08X}" for c, lo, hi in sent))
    finally:
        link.close()
        proc.terminate()
        proc.wait()


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(__doc__.split("\n\n")[1])
    emu, monitor = sys.argv[1:]
    with tempfile.TemporaryDirectory() as tmp:
        for name, status, data, want in CASES:
            rows, mem = run(emu, monitor, status, data, "time\r", tmp)
            got = after(rows, "time")
            check(f"cold start, {name}: {want}", got == want, f"got {got}")
        typed = 'time "2027-03-04 05:06:07"'
        rows, mem = run(emu, monitor, 0, regs(), typed + "\r", tmp)
        check("time typed without a master: the clock set, and the "
              "master's command left at 0",
              after(rows, typed) == typed[6:-1] and mem[:2] == [0, 0],
              f"got {after(rows, typed)}, {mem}")
        rows, mem = run(emu, monitor, PRESENT, regs(), typed + "\r", tmp)
        check("time typed with a master: the clock set, and the chip's "
              "status written last",
              after(rows, typed) == typed[6:-1] and mem[:2] == [WRITE, PRESENT],
              f"got {after(rows, typed)}, {mem}")
        typed = 'time "2100-03-01 00:00:00"'
        rows, mem = run(emu, monitor, PRESENT, regs(), typed + "\r", tmp)
        check("time typed with a master, in 2100: the clock set, and the "
              "chip not written",
              after(rows, typed) == typed[6:-1] and mem[:2] == [READ, PRESENT],
              f"got {after(rows, typed)}, {mem}")
        typed = 'time "2027-03-04 05:06:07"'
        rows, mem = run(emu, monitor, PRESENT, regs(), typed + "\rsys 0\rtime\r", tmp)
        check("time typed, then the cold start: the clock as it was, not the "
              "chip's", after(rows, "time") == typed[6:-1],
              f"got {after(rows, 'time')}")
    linked(emu, monitor)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
