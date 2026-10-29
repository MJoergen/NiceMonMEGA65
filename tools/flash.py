#!/usr/bin/env python3
"""Write a bitstream into the Nexys4DDR's flash, or a core file into a slot
of the MEGA65's, from which the board starts.

Usage:
    tools/flash.py --port DEVICE [--baud 2000000]
                   [--bit synth/nexys4ddr/build/top.bit] [--erase]
    tools/flash.py --port DEVICE [--baud 2000000]
                   --cor synth/r6/build/NiceMonMEGA65-r6.cor --slot N

    The Nexys4DDR's FPGA loads the bitstream from the board's quad SPI
    flash at power on, and when PROG is pressed, if jumper JP1 (MODE) is
    on QSPI. The bitstream is built for that
    (synth/nexys4ddr/nexys4ddr.xdc). With the demo in its ROM (make demo,
    then make nexys4ddr ROM=demo/build/demo.bin), or a release's
    nicemon-TAG-nexys4ddr.bit, the board then shows the demo when it is
    switched on, as a MEGA65 does with a core in its flash.

    --erase erases the whole flash instead, and the FPGA then stays empty
    at power on until it is programmed over JTAG. It is for the Nexys4DDR
    only.

    --cor writes a MEGA65 core file (make cor) into slot N of the MEGA65's
    flash, 1 to 7, as MEGAFLASH does, but over the JTAG cable, with no key
    held at power on. Slot 0 holds the MEGA65's own core, which the board
    starts at power on and which MEGAFLASH runs in, so the script refuses
    it.

How:
    It finds the JTAG cable on the same USB device as the serial port, and
    stops unless the FPGA is the part the file was built for (as hwtest.py
    does, tools/jtag.py). openFPGALoader writes the flash through a bridge
    that it loads into the FPGA over JTAG, reads it back to verify it, and
    then makes the FPGA load itself from the flash. The script last reads
    the control register over the link, whose answer says that the board
    started from the flash. It needs Linux, as hwtest.py does.

    A bitstream must be for the Nexys4DDR's part. A core file must have
    the header of coretool, for a board revision with the MEGA65's part,
    and fit in a slot. The R3 and R6 have the same part, so the script
    also reads the header of the core in slot 0 and stops unless it is for
    the core file's revision. It shows what the slot held before.

    The MEGA65's FPGA loads slot 0 when openFPGALoader is done, and that
    core may start another slot on its own. If the link does not answer,
    the script writes the slot's address to the reconfiguration registers
    at $FFD36C8 through the MEGA65 core's serial monitor, on the same
    UART, as m65 -Z N does, and the FPGA loads the slot.

Exit status:
    0 if the flash was written, verified, and the board started from it,
    or the flash was erased; else 1.
"""

import argparse
import os
import struct
import subprocess
import sys
import tempfile
import time

from jtag import bit_part, check_board, check_part, wait_port
from nicelink import CONTROL, Link, LinkError, Serial

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# The Nexys4DDR's part, which openFPGALoader needs for its bridge, as the
# IDCODE does not tell the package
PART = "7a100tcsg324"
# How long the board's serial port may take to come back after
# openFPGALoader; the FPGA loads itself from the flash in a fraction of a
# second, as the bitstream is compressed and read 4 bits at a time at
# 33 MHz.
BOOT_WAIT = 10.0

# The MEGA65's part, and its slots of 8 MiB (coretool's MEGA65target)
MEGA65_PART = "7a200tfbg484"
SLOT_SIZE = 8 << 20
SLOTS = 8
# coretool's header: the magic, the name, the version, the board
# revision's name, and its code, then the core's length at 0x80
HEADER_SIZE = 4096
CORE_MAGIC = b"MEGA65BITSTREAM0"
HEADER = struct.Struct("<16s32s32s32sB")
# The board revisions of the MEGA65's part, by coretool's code
REVISIONS = {0x03: "mega65r3", 0x04: "mega65r4", 0x05: "mega65r5",
             0x06: "mega65r6"}
# How long slot 0's core may take to start another slot on its own, and
# the slot to load once the script has written the reconfiguration
# registers
MEGA65_WAIT = 8.0


def header(data: bytes) -> tuple[str, str, int, str] | None:
    """The name, version, revision code, and revision name of a core
    file's header, or None if data is not one."""
    if len(data) < HEADER.size or not data.startswith(CORE_MAGIC):
        return None
    _, name, version, rev, code = HEADER.unpack_from(data)
    return (name.rstrip(b"\0").decode("ascii", "replace"),
            version.rstrip(b"\0").decode("ascii", "replace"), code,
            rev.rstrip(b"\0").decode("ascii", "replace"))


def describe(data: bytes) -> str:
    """What a slot's first bytes say it holds."""
    h = header(data)
    if h:
        return f"{h[0]} {h[1]} ({h[3]})"
    if data.count(0xFF) == len(data):
        return "nothing"
    return "no core header"


def dump(loader: list[str], offset: int, size: int) -> bytes:
    """Reads size bytes of the flash from offset through the bridge."""
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "dump.bin")
        r = subprocess.run(loader + ["--dump-flash", "--offset", hex(offset),
                                     "--file-size", str(size), out],
                           capture_output=True, text=True)
        if r.returncode != 0 or not os.path.exists(out):
            sys.exit(f"{r.stdout}{r.stderr}flash.py: openFPGALoader could "
                     f"not read the flash")
        with open(out, "rb") as f:
            return f.read()


def control(port: str, baud: int, wait: float) -> int | None:
    """The control register over the link, or None if the link does not
    answer within wait seconds."""
    end = time.monotonic() + wait
    while True:
        link = Link(Serial(port, baud))
        try:
            return link.read_word(CONTROL)
        except LinkError:
            if time.monotonic() >= end:
                return None
        finally:
            link.close()


def started(value: int) -> str:
    """What the control register says about the system that answered."""
    # Bit 3 is the hidden ROM, and bit 0 the hold: a bitstream without a
    # ROM holds the core, and one with a ROM runs it (hwtest.py's
    # test_boot).
    return (f"control {value:08X}: "
            f"{'held, no ROM' if value & 9 == 9 else 'running the ROM'}")


def zap(port: str, baud: int, slot: int) -> None:
    """Makes the MEGA65 core load a slot, as m65 -Z does: the slot's
    address, shifted right by 8, into $FFD36C8 to $FFD36CB through the
    serial monitor, then $42 into $FFD36CF. The monitor takes one
    character at a time, so they go slowly; the first return ends what
    the link sent before."""
    addr = slot * SLOT_SIZE
    lines = ["", f"sffd36c8 {(addr >> 8) & 0xFF:x} {(addr >> 16) & 0xFF:x} "
             f"{(addr >> 24) & 0xFF:x} 0", "sffd36cf 42"]
    uart = Serial(port, baud)
    try:
        for line in lines:
            for c in (line + "\r").encode("ascii"):
                uart.write(bytes([c]))
                time.sleep(0.002)
            time.sleep(0.1)
    finally:
        uart.close()


def flash_cor(args: argparse.Namespace) -> None:
    """Writes the core file into its slot of the MEGA65's flash."""
    if not 0 < args.slot < SLOTS:
        sys.exit(f"flash.py: give --slot 1 to {SLOTS - 1}; slot 0 holds the "
                 f"MEGA65's own core")
    if not os.path.exists(args.cor):
        sys.exit(f"flash.py: {args.cor} is missing; run 'make cor', or give "
                 f"--cor")
    with open(args.cor, "rb") as f:
        data = f.read()
    cor = header(data)
    if cor is None:
        sys.exit(f"flash.py: {args.cor} is not a core file of coretool")
    name, version, code, rev = cor
    if code not in REVISIONS:
        sys.exit(f"flash.py: {args.cor} is for {rev} (code {code:02X}), "
                 f"not a MEGA65 with the part {MEGA65_PART}")
    if len(data) > SLOT_SIZE:
        sys.exit(f"flash.py: {args.cor} has {len(data)} bytes, more than "
                 f"a slot's {SLOT_SIZE}")
    cable, port = check_part(args.port, MEGA65_PART, args.cor)
    loader = ["openFPGALoader"] + cable + ["--fpga-part", f"xc{MEGA65_PART}"]

    factory = header(dump(loader, 0, HEADER_SIZE))
    if factory is None:
        print("[WARN] slot 0 has no core header, so the board's revision is "
              "not known", flush=True)
    elif factory[2] != code:
        sys.exit(f"[FAIL] slot 0 holds a core for {factory[3]}, and "
                 f"{args.cor} is for {rev}; give the core file of this "
                 f"board")
    else:
        print(f"[PASS] slot 0 holds {factory[0]} {factory[1]} for {rev}",
              flush=True)
    offset = args.slot * SLOT_SIZE
    print(f"slot {args.slot} held "
          f"{describe(dump(loader, offset, HEADER_SIZE))}", flush=True)

    r = subprocess.run(loader + ["--write-flash", "--verify", "--file-type",
                                 "bin", "--offset", hex(offset), args.cor])
    if r.returncode != 0:
        sys.exit("flash.py: openFPGALoader failed")
    print(f"[PASS] {name} {version} written into slot {args.slot} and "
          f"verified", flush=True)

    # The FPGA now loads slot 0, which may start a slot on its own; if it
    # does not start the system, the monitor of slot 0's core loads it.
    wait_port(port, BOOT_WAIT)
    value = control(port, args.baud, MEGA65_WAIT)
    if value is None:
        zap(port, args.baud, args.slot)
        value = control(port, args.baud, BOOT_WAIT)
    if value is None:
        sys.exit(f"[FAIL] the link does not answer: the board did not start "
                 f"slot {args.slot}; switch it off and on, and hold No "
                 f"Scroll to choose the slot")
    print(f"[PASS] the board started slot {args.slot}, {started(value)}",
          flush=True)


def flash_bit(args: argparse.Namespace) -> None:
    """Writes the bitstream into the Nexys4DDR's flash, or erases it."""
    if not os.path.exists(args.bit):
        sys.exit(f"flash.py: {args.bit} is missing; run 'make nexys4ddr', "
                 f"or give --bit")
    if bit_part(args.bit) != PART:
        sys.exit(f"flash.py: {args.bit} is for {bit_part(args.bit)}, not the "
                 f"Nexys4DDR's {PART}; a MEGA65 takes a core file with "
                 f"--cor")
    cable, port = check_board(args.port, args.bit)
    loader = ["openFPGALoader"] + cable + ["--fpga-part", f"xc{PART}"]

    if args.erase:
        r = subprocess.run(loader + ["--bulk-erase"])
        if r.returncode != 0:
            sys.exit("flash.py: openFPGALoader failed")
        print("[PASS] flash erased; the FPGA stays empty at power on",
              flush=True)
        return

    r = subprocess.run(loader + ["--write-flash", "--verify", args.bit])
    if r.returncode != 0:
        sys.exit("flash.py: openFPGALoader failed")
    print("[PASS] flash written and verified", flush=True)
    # openFPGALoader has made the FPGA load itself from the flash. The
    # board's USB device starts anew when openFPGALoader lets it go, so its
    # b notice comes before the port can be opened. The link answers
    # instead if the FPGA holds the system, and an empty FPGA answers
    # nothing.
    wait_port(port, BOOT_WAIT)
    value = control(port, args.baud, 0)
    if value is None:
        sys.exit("[FAIL] the link does not answer: the board did not start "
                 "from the flash; set jumper JP1 (MODE) to QSPI, and press "
                 "PROG")
    print(f"[PASS] the board started from the flash, {started(value)}",
          flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", required=True, metavar="DEVICE",
                        help="the serial device of the board's debug UART, "
                        "such as /dev/ttyUSB1")
    parser.add_argument("--baud", type=int, default=2000000,
                        help="the UART's baud rate (default %(default)s)")
    parser.add_argument("--bit", default=f"{REPO}/synth/nexys4ddr/build/top.bit",
                        help="the Nexys4DDR's bitstream to write (default "
                        "%(default)s)")
    parser.add_argument("--erase", action="store_true",
                        help="erase the Nexys4DDR's flash instead of "
                        "writing it")
    parser.add_argument("--cor",
                        help="a MEGA65 core file to write into --slot "
                        "instead")
    parser.add_argument("--slot", type=int,
                        help="the slot of the MEGA65's flash, 1 to 7")
    args = parser.parse_args()

    if not sys.platform.startswith("linux"):
        sys.exit("flash.py: finding the JTAG cable needs Linux; write the "
                 "flash with openFPGALoader -b nexys_a7_100 -f BIT")
    if args.cor is not None:
        if args.erase:
            sys.exit("flash.py: --erase is for the Nexys4DDR; the MEGA65's "
                     "flash holds its own core in slot 0")
        if args.slot is None:
            sys.exit("flash.py: give the slot with --slot, 1 to 7")
        flash_cor(args)
    elif args.slot is not None:
        sys.exit("flash.py: --slot goes with --cor")
    else:
        flash_bit(args)


if __name__ == "__main__":
    main()
