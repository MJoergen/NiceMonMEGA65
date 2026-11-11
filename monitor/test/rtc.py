#!/usr/bin/env python3
"""Check the monitor's clock from a real-time clock at the cold start, and
time's write of one, in niceemu.

Usage: test/rtc.py NICEEMU MONITOR.bin

niceemu has no I2C master: the master's words at 0xFFFFFF97 to 9D are
memory there. So a .bin file behind the monitor's sets them before the
start: the status to 1, a master that is present and never busy, and the
data to the registers 0 to 15 of the R6's RV-3032-C7. To clock.c every
transaction then ends at once with no error, and its clock_rtc reads
those registers at the cold start as the chip's. niceemu runs with
--step-time, so the clock starts at 0, not set, and counts a microsecond
a step.

For each row of CASES the monitor starts on the registers of the row,
and time must show the row's date and time, or that the clock is not
set: dates and times that the chip can hold, with the bits that are no
digits set; the chip's two flags that say that it lost its time; no
master; a digit over 9 in each register, which made the year 2100 or
2105 once; and numbers that are no date or time.

Then time with a date and a time is typed. Without a master it must
leave the master's words alone. With one, in the years 2000 to 2099, the
command left is the write of the chip's status, the last of the two, and
in another year the read of the cold start.

The R3's ISL12020M is read only when the R6's chip does not answer,
which memory cannot do, so its part of clock_rtc is not run here. Exits
with status 1 when a check fails. Only the Python standard library is
used.
"""

import subprocess
import sys
import tempfile

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
    """The row that the monitor printed after the last command typed so."""
    prompts = [i for i, row in enumerate(rows) if row == "> " + command]
    return rows[prompts[-1] + 1] if prompts else "no " + command


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(__doc__.split("\n\n")[1])
    emu, monitor = sys.argv[1:]
    with tempfile.TemporaryDirectory() as tmp:
        for name, status, data, want in CASES:
            rows, mem = run(emu, monitor, status, data, "time\r", tmp)
            got = after(rows, "time")
            check(f"cold start, {name}: {want}", got == want, f"got {got}")
        typed = "time 2027-03-04 05:06:07"
        rows, mem = run(emu, monitor, 0, regs(), typed + "\r", tmp)
        check("time typed without a master: the clock set, and the "
              "master's command left at 0",
              after(rows, typed) == typed[5:] and mem[:2] == [0, 0],
              f"got {after(rows, typed)}, {mem}")
        rows, mem = run(emu, monitor, PRESENT, regs(), typed + "\r", tmp)
        check("time typed with a master: the clock set, and the chip's "
              "status written last",
              after(rows, typed) == typed[5:] and mem[:2] == [WRITE, PRESENT],
              f"got {after(rows, typed)}, {mem}")
        typed = "time 2100-03-01 00:00:00"
        rows, mem = run(emu, monitor, PRESENT, regs(), typed + "\r", tmp)
        check("time typed with a master, in 2100: the clock set, and the "
              "chip not written",
              after(rows, typed) == typed[5:] and mem[:2] == [READ, PRESENT],
              f"got {after(rows, typed)}, {mem}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
