#!/usr/bin/env python3
"""Write a board's flash, from which the board starts: a bitstream into the
Nexys4DDR's, or a core file into a slot of the MEGA65's.

Usage:
    tools/flash.py --port DEVICE [--baud 230400]
                   [--bit synth/nexys4ddr/build/top.bit] [--erase]
    tools/flash.py --port DEVICE [--baud 230400]
                   --cor synth/r6/build/NiceMonMEGA65-r6.cor --slot N
                   [--no-board-check]

    The Nexys4DDR's FPGA loads the bitstream from the board's quad SPI
    flash at power on, and when PROG is pressed, if jumper JP1 (MODE) is
    on QSPI. The bitstream is built for that
    (synth/nexys4ddr/nexys4ddr.xdc). With the monitor in its ROM (make
    nexys4ddr), or a release's nicemon-TAG-nexys4ddr.bit, the
    board then shows the monitor when it is switched on, as a MEGA65 does with a core in
    its flash.

    --erase erases the whole flash instead, and the FPGA then stays empty
    at power on until it is programmed over JTAG. It is for the Nexys4DDR
    only.

    --cor writes a MEGA65 core file (make cor) into slot N of the MEGA65's
    flash, 1 to 7, or 1 to 3 in an R3's flash of 32 MiB, which
    spiflash.py checks, as MEGAFLASH does, but over the JTAG cable, with no key
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
    started from the flash, and warns if it has no ROM, as the screen then
    stays empty. It needs Linux, as hwtest.py does, and for the MEGA65
    pyftdi.

    A bitstream must be for the Nexys4DDR's part. A core file must have
    the header of coretool, for a board revision with the MEGA65's part,
    and fit in a slot. The R3 and R6 have the same part, so the script
    also stops unless the flash chip, which openFPGALoader names, is that
    of the core file's revision: an S25FL256S of 32 MiB on the R3 and
    R3A, and an S25FL512S of 64 MiB on the R4, R5, and R6
    (tools/jtag.py). --no-board-check skips that, for a board whose flash
    is not the usual one. It also reads the header of the core in slot 0
    and stops unless it is for the core file's revision. It shows what
    the slot held before.

    The MEGA65's flash protects each sector with its DYB bit, which
    openFPGALoader does not clear, so its erase fails. Between the reads
    and the write, the script clears the DYBs of the sectors it writes
    through openFPGALoader's bridge, with pyftdi (tools/spiflash.py), as
    MEGAFLASH does. The bridge stays in the FPGA from the first read to
    the write.

    The MEGA65 then does not start the slot on its own: slot 0's core may
    start another slot at power on, and an IPROG through JTAG leaves the
    FPGA empty. So the script loads the slot's bitstream, which follows
    the core file's header, into the FPGA over JTAG, and reads the
    control register over the link. Hold No Scroll at power on to start
    the slot from the flash.

Exit status:
    0 if the flash was written, verified, and the board started from it
    (for the MEGA65, the slot's bitstream over JTAG), or the flash was
    erased; else 1.
"""

import argparse
import os
import struct
import subprocess
import sys
import tempfile
import time

from jtag import FLASH_BOARDS, bit_part, check_board, check_part, \
    flash_chip, wait_port
from boardlink import DEFAULT_BAUD, CONTROL, Link, LinkError, Serial
from spiflash import SpiFlashError, unprotect

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
# The flash chip of each board revision (tools/jtag.py)
CHIPS = {0x03: "S25FL256S", 0x04: "S25FL512S", 0x05: "S25FL512S",
         0x06: "S25FL512S"}


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


def dump(loader: list[str], offset: int,
         size: int) -> tuple[bytes, str | None]:
    """Reads size bytes of the flash from offset through the bridge, and
    returns them and the flash chip that openFPGALoader names. The
    loader options may skip loading the bridge, and the bridge stays in
    the FPGA afterwards (--skip-reset), for spiflash.py."""
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "dump.bin")
        r = subprocess.run(loader + ["--dump-flash", "--skip-reset",
                                     "--offset", hex(offset),
                                     "--file-size", str(size), out],
                           capture_output=True, text=True)
        if r.returncode != 0 or not os.path.exists(out):
            sys.exit(f"{r.stdout}{r.stderr}flash.py: openFPGALoader could "
                     f"not read the flash")
        with open(out, "rb") as f:
            return f.read(), flash_chip(r.stdout + r.stderr)


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


def warn_no_rom(value: int, build: str) -> None:
    """Warns that a board without a ROM shows nothing when it starts."""
    if value & 9 == 9:
        print(f"[WARN] the bitstream has no ROM, so the core waits, held, "
              f"for the link, and the screen stays empty at power on; "
              f"'make {build}' builds it with the monitor", flush=True)


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
    cable, port, _ = check_part(args.port, MEGA65_PART, args.cor)
    loader = ["openFPGALoader"] + cable + ["--fpga-part", f"xc{MEGA65_PART}"]

    # The first dump loads the bridge; it stays in the FPGA until the
    # write resets it
    slot0, chip = dump(loader, 0, HEADER_SIZE)
    loader.append("--skip-load-bridge")
    if args.no_board_check:
        print("[NOTE] the flash chip is not checked", flush=True)
    elif chip != CHIPS[code]:
        has = f"an {chip}: {FLASH_BOARDS[chip][1]}" \
            if chip in FLASH_BOARDS else f"no known flash chip ({chip})"
        sys.exit(f"[FAIL] {args.cor} is for {rev}, which has an "
                 f"{CHIPS[code]}, but the board has {has}; give the core "
                 f"file of this board, or --no-board-check if its flash is "
                 f"not the usual one")
    else:
        print(f"[PASS] flash {chip}, as {rev} has", flush=True)
    factory = header(slot0)
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
          f"{describe(dump(loader, offset, HEADER_SIZE)[0])}", flush=True)

    # The flash's sectors are protected by their DYBs, which openFPGALoader
    # does not clear (spiflash.py)
    try:
        cleared = unprotect(cable[cable.index("--ftdi-serial") + 1], offset,
                            len(data))
    except SpiFlashError as e:
        sys.exit(f"[FAIL] {e}")
    print(f"[PASS] slot {args.slot} unprotected ({cleared} of its sectors "
          f"had their DYB set)", flush=True)

    r = subprocess.run(loader + ["--write-flash", "--skip-reset", "--verify",
                                 "--file-type", "bin", "--offset", hex(offset),
                                 args.cor])
    if r.returncode != 0:
        sys.exit("flash.py: openFPGALoader failed")
    print(f"[PASS] {name} {version} written into slot {args.slot} and "
          f"verified", flush=True)

    # Slot 0's core may start another slot on its own at power on, and an
    # IPROG through JTAG leaves the FPGA empty, so the script loads the
    # bitstream of the slot, which follows the core file's header, into
    # the FPGA over JTAG.
    with tempfile.TemporaryDirectory() as tmp:
        bit = os.path.join(tmp, "slot.bit")
        with open(bit, "wb") as f:
            f.write(data[HEADER_SIZE:])
        r = subprocess.run(["openFPGALoader"] + cable + [bit])
    if r.returncode != 0:
        sys.exit("flash.py: openFPGALoader could not load the slot's "
                 "bitstream")
    wait_port(port, BOOT_WAIT)
    value = control(port, args.baud, BOOT_WAIT)
    if value is None:
        sys.exit(f"[FAIL] the link does not answer: the bitstream of slot "
                 f"{args.slot} does not start the system")
    print(f"[PASS] the bitstream of slot {args.slot} runs, {started(value)}; "
          f"hold No Scroll at power on to start the slot", flush=True)
    warn_no_rom(value, "cor")


def flash_bit(args: argparse.Namespace) -> None:
    """Writes the bitstream into the Nexys4DDR's flash, or erases it."""
    if not os.path.exists(args.bit):
        sys.exit(f"flash.py: {args.bit} is missing; run 'make nexys4ddr', "
                 f"or give --bit")
    if bit_part(args.bit) != PART:
        sys.exit(f"flash.py: {args.bit} is for {bit_part(args.bit)}, not the "
                 f"Nexys4DDR's {PART}; a MEGA65 takes a core file with "
                 f"--cor")
    cable, port, _ = check_board(args.port, args.bit)
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
    warn_no_rom(value, "nexys4ddr")


DEFAULT_BIT = f"{REPO}/synth/nexys4ddr/build/top.bit"


def main() -> None:
    parser = argparse.ArgumentParser(
        description=" ".join(__doc__.split("\n\n")[0].split()))
    parser.add_argument("--port", required=True, metavar="DEVICE",
                        help="the serial device of the board's debug UART, "
                        "such as /dev/ttyUSB1")
    parser.add_argument("--baud", type=int, default=DEFAULT_BAUD,
                        help="the UART's baud rate (default %(default)s)")
    parser.add_argument("--bit", default=DEFAULT_BIT,
                        help="Nexys4DDR: the bitstream to write (default "
                        f"{os.path.relpath(DEFAULT_BIT, REPO)} in the "
                        "repository)")
    parser.add_argument("--erase", action="store_true",
                        help="Nexys4DDR: erase the flash instead of "
                        "writing it")
    parser.add_argument("--cor",
                        help="MEGA65: a core file to write into --slot "
                        "instead")
    parser.add_argument("--slot", type=int,
                        help="MEGA65: the slot of the flash, 1 to 7")
    parser.add_argument("--no-board-check", action="store_true",
                        help="MEGA65: do not check that the flash chip is "
                        "that of the core file's revision")
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
