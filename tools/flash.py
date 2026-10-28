#!/usr/bin/env python3
"""Write a bitstream into the Nexys4DDR's flash, from which the board starts.

Usage:
    tools/flash.py [--port /dev/ttyUSB1] [--baud 2000000]
                   [--bit synth/nexys4ddr/build/top.bit] [--erase]

    The FPGA loads the bitstream from the board's quad SPI flash at power
    on, and when PROG is pressed, if jumper JP1 (MODE) is on QSPI. The
    bitstream is built for that (synth/nexys4ddr/nexys4ddr.xdc). With the
    demo in its ROM (make demo, then make nexys4ddr ROM=demo/build/demo.bin),
    or the release's nicemon-V1.0-nexys4ddr.bit, the board then shows the
    demo when it is switched on, as a MEGA65 does with a core in its flash.

    --erase erases the whole flash instead, and the FPGA then stays empty
    at power on until it is programmed over JTAG.

How:
    It finds the JTAG cable on the same USB device as the serial port, and
    stops unless the FPGA is the part the bitstream was built for (as
    hwtest.py does, tools/jtag.py), and unless that part is the
    Nexys4DDR's. A MEGA65 takes a .cor file in MEGAFLASH instead
    (synth/README.md). openFPGALoader writes the flash through a bridge
    that it loads into the FPGA over JTAG, reads it back to verify it, and
    then makes the FPGA load itself from the flash. The script last reads
    the control register over the link, whose answer says that the board
    started from the flash, and names JP1 when none comes. It needs Linux,
    as hwtest.py does.

Exit status:
    0 if the flash was written, verified, and the board started from it,
    or the flash was erased; else 1.
"""

import argparse
import os
import subprocess
import sys
import time

from jtag import bit_part, check_board, wait_port
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


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", default="/dev/ttyUSB1",
                        help="the serial device of the board's debug UART "
                        "(default %(default)s)")
    parser.add_argument("--baud", type=int, default=2000000,
                        help="the UART's baud rate (default %(default)s)")
    parser.add_argument("--bit", default=f"{REPO}/synth/nexys4ddr/build/top.bit",
                        help="the bitstream to write (default %(default)s)")
    parser.add_argument("--erase", action="store_true",
                        help="erase the flash instead of writing it")
    args = parser.parse_args()

    if not sys.platform.startswith("linux"):
        sys.exit("flash.py: finding the JTAG cable needs Linux; write the "
                 "flash with openFPGALoader -b nexys_a7_100 -f BIT")
    if not os.path.exists(args.bit):
        sys.exit(f"flash.py: {args.bit} is missing; run 'make nexys4ddr', "
                 f"or give --bit")
    if bit_part(args.bit) != PART:
        sys.exit(f"flash.py: {args.bit} is for {bit_part(args.bit)}, not the "
                 f"Nexys4DDR's {PART}; a MEGA65 takes a .cor file in "
                 f"MEGAFLASH")
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
    link = Link(Serial(port, args.baud))
    try:
        control = link.read_word(CONTROL)
    except LinkError:
        sys.exit("[FAIL] the link does not answer: the board did not start "
                 "from the flash; set jumper JP1 (MODE) to QSPI, and press "
                 "PROG")
    finally:
        link.close()
    # Bit 3 is the hidden ROM, and bit 0 the hold: a bitstream without a
    # ROM holds the core, and one with a ROM runs it (hwtest.py's
    # test_boot).
    print(f"[PASS] the board started from the flash, control "
          f"{control:08X}: "
          f"{'held, no ROM' if control & 9 == 9 else 'running the ROM'}",
          flush=True)


if __name__ == "__main__":
    main()
