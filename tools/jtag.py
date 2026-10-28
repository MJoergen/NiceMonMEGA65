"""The board's JTAG cable, found through its serial port, for openFPGALoader.

The MEGA65 and the Nexys4DDR each have an FTDI chip whose one interface
is the debug UART and whose other is JTAG. check_board finds the JTAG
cable of the serial port's board, and stops unless its FPGA is the part
a bitstream was built for, so that with several boards attached a tool
programs the board whose UART it uses. hwtest.py and flash.py use it.
The cable is found through /sys, so this works on Linux only.
"""

import os
import re
import subprocess
import sys
import time

# The name of the tool, for its messages
PROG = os.path.basename(sys.argv[0])

# The openFPGALoader cables to try: ft2232 for the MEGA65's JTAG adapter,
# digilent for the Nexys4DDR. Each answers on its own board only.
CABLES = ["ft2232", "digilent"]


def bit_part(bit: str) -> str:
    """Returns the part a bitstream was built for, as its header names it
    (7a200tfbg484, say): fields of a letter, a 16-bit length, and the text,
    after a fixed preamble of 13 bytes."""
    with open(bit, "rb") as f:
        head = f.read(256)
    i = 13
    while i + 3 <= len(head):
        key = head[i]
        n = int.from_bytes(head[i + 1:i + 3], "big")
        if key == ord("b"):
            return head[i + 3:i + 3 + n].rstrip(b"\0").decode()
        if key not in b"acd":
            break
        i += 3 + n
    sys.exit(f"{PROG}: {bit} has no part in its header")


def usb_serial(port: str) -> str:
    """Returns the serial number of the USB device that a serial port is an
    interface of: the board's FTDI chip, whose other interface is JTAG. It
    reads /sys, so this works on Linux only."""
    tty = os.path.basename(os.path.realpath(port))
    path = os.path.realpath(f"/sys/class/tty/{tty}/device")
    while path != "/":
        if os.path.exists(f"{path}/serial"):
            with open(f"{path}/serial") as f:
                return f.read().strip()
        path = os.path.dirname(path)
    sys.exit(f"{PROG}: no USB serial number found for {port}; is it "
             f"the board's USB serial port? try --port")


def fpga_model(serial: str) -> tuple[str, str]:
    """Reads the IDCODE through the JTAG cable with that serial number and
    returns the cable that answered and the model openFPGALoader names for
    the FPGA (xc7a200, say)."""
    for cable in CABLES:
        r = subprocess.run(["openFPGALoader", "-c", cable, "--ftdi-serial",
                            serial, "--detect"], capture_output=True,
                           text=True, timeout=30)
        m = re.search(r"model\s+(\S+)", r.stdout + r.stderr)
        if m:
            return cable, m.group(1)
    sys.exit(f"{PROG}: no FPGA answers on the JTAG cable {serial}; is "
             f"the board on, and is its JTAG cable connected?")


def stable_port(port: str) -> str:
    """Returns the name in /dev/serial/by-id of the serial port, or the
    port when it has none. openFPGALoader takes the FTDI chip's JTAG
    interface from the kernel's driver, and gives it back when it is done.
    It then becomes a serial port of its own, which may take the UART's
    ttyUSB number, and the UART takes another. The name by id stays."""
    real = os.path.realpath(port)
    by_id = "/dev/serial/by-id"
    for name in sorted(os.listdir(by_id)) if os.path.isdir(by_id) else []:
        if os.path.realpath(f"{by_id}/{name}") == real:
            return f"{by_id}/{name}"
    return port


def check_board(port: str, bit: str) -> tuple[list[str], str]:
    """Stops unless the FPGA on the board of the serial port is the part of
    the bitstream, and returns the openFPGALoader options that select its
    JTAG cable, and the port's name by id (stable_port), which the tool
    uses from then on."""
    part = bit_part(bit)
    serial = usb_serial(port)
    port = stable_port(port)
    cable, model = fpga_model(serial)
    ok = f"xc{part}".startswith(model)
    print(f"[{'PASS' if ok else 'FAIL'}] FPGA {model} on {port} (JTAG "
          f"{serial}), bitstream for {part}", flush=True)
    if not ok:
        sys.exit(f"{PROG}: {bit} is for {part}, but the FPGA on {port} is "
                 f"{model}; give the --bit for this board, or the --port of "
                 f"the board the bitstream is for")
    wait_port(port)
    return ["-c", cable, "--ftdi-serial", serial], port


def wait_port(port: str, timeout: float = 5.0) -> None:
    """Waits until the serial port opens again after openFPGALoader, which
    makes it anew (stable_port); udev gives it its permissions a moment
    later."""
    end = time.monotonic() + timeout
    while True:
        try:
            os.close(os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK))
            return
        except OSError:
            if time.monotonic() >= end:
                return
            time.sleep(0.1)
