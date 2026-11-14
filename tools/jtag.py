"""The board's JTAG cable, found through its serial port, for openFPGALoader.

The MEGA65 and the Nexys4DDR each have an FTDI chip whose one interface
is the debug UART and whose other is JTAG. check_board finds the JTAG
cable of the serial port's board, and stops unless its FPGA is the part
a bitstream or core file was built for, so that with several boards
attached a tool programs the board whose UART it uses. hwtest.py and
flash.py use it.
The cable is found through /sys, so this works on Linux only.

The MEGA65 R3 and R6 have the same part, so check_board also tells them
apart by their flash chips (#125): the R3 and R3A have a 32 MiB
S25FL256S, and the R4, R5, and R6 a 64 MiB S25FL512S. openFPGALoader
names the chip when it reads the flash through its bridge, a bitstream
that it loads into the FPGA in place of what the FPGA runs. The
bitstream names its board by its UserID, "M65" and the revision
(synth/r3/r3.xdc), or else by its path.
"""

import os
import re
import subprocess
import sys
import tempfile
import time

# The name of the tool, for its messages
PROG = os.path.basename(sys.argv[0])

# The openFPGALoader cables to try: ft2232 for the MEGA65's JTAG adapter,
# digilent for the Nexys4DDR. Each answers on its own board only.
CABLES = ["ft2232", "digilent"]

# The MEGA65 boards by the UserID in a bitstream's header
USERIDS = {0x4D363503: "r3", 0x4D363506: "r6"}
# The MEGA65 boards by their flash chips, as openFPGALoader names them,
# with the board revisions that have each chip
FLASH_BOARDS = {"S25FL256S": ("r3", "an R3 or R3A"),
                "S25FL512S": ("r6", "an R4, R5, or R6")}


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


def bit_board(bit: str) -> str | None:
    """Returns the MEGA65 board a bitstream is for, r3 or r6: by the
    UserID in its header, or else by its path (synth/r3/ or
    nicemon-TAG-r3.bit, say). None if neither tells."""
    with open(bit, "rb") as f:
        m = re.search(rb"UserID=(?:0X)?([0-9A-F]{8})", f.read(256))
    if m and int(m.group(1), 16) in USERIDS:
        return USERIDS[int(m.group(1), 16)]
    path = os.path.abspath(bit)
    m2 = (re.search(r"/synth/(r3|r6)/", path)
          or re.search(r"-(r3|r6)\.bit$", path))
    return m2.group(1) if m2 else None


def flash_chip(text: str) -> str | None:
    """The flash chip that openFPGALoader names in its output when it
    reaches the flash through its bridge, S25FL512S, say."""
    m = re.search(r"Detected:\s+\S+\s+(\S+)", text)
    return m.group(1) if m else None


def read_flash_chip(loader: list[str], part: str) -> str | None:
    """Loads openFPGALoader's bridge for the part into the FPGA through
    the cable of the loader options, and returns the flash chip it finds,
    or None. The bridge stays in the FPGA."""
    with tempfile.TemporaryDirectory() as tmp:
        r = subprocess.run(["openFPGALoader"] + loader + [
            "--fpga-part", f"xc{part}", "--dump-flash", "--skip-reset",
            "--offset", "0", "--file-size", "1",
            os.path.join(tmp, "dump.bin")],
            capture_output=True, text=True, timeout=60)
    return flash_chip(r.stdout + r.stderr)


def check_flash(port: str, loader: list[str], part: str, bit: str) -> None:
    """Stops unless the flash chip on the MEGA65 of the serial port is that
    of the board the bitstream is for (bit_board). Replaces what the FPGA
    runs with openFPGALoader's bridge."""
    board = bit_board(bit)
    if board is None:
        print(f"[NOTE] neither the header nor the path of {bit} names an "
              f"R3 or R6, so the board revision is not checked", flush=True)
        return
    chip = read_flash_chip(loader, part)
    wait_port(port)
    if chip not in FLASH_BOARDS:
        sys.exit(f"{PROG}: openFPGALoader names no known flash chip on "
                 f"the MEGA65 of {port} ({chip}), so its revision is not "
                 f"known; give --no-board-check to program it anyway")
    has, which = FLASH_BOARDS[chip]
    ok = has == board
    print(f"[{'PASS' if ok else 'FAIL'}] flash {chip} on {port}: "
          f"{which}, {os.path.basename(bit)} for the {board.upper()}",
          flush=True)
    if not ok:
        sys.exit(f"{PROG}: {bit} is for the {board.upper()}, but the board "
                 f"on {port} has an {chip}: {which}; give the bitstream "
                 f"of this board, or --no-board-check if its flash is not "
                 f"the usual one")


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


def check_board(port: str, bit: str,
                board_check: bool = True) -> tuple[list[str], str, str]:
    """Stops unless the FPGA on the board of the serial port is the part of
    the bitstream, and, on a MEGA65 unless board_check is False, unless
    its flash chip is that of the bitstream's board (check_flash). Returns
    what check_part returns."""
    part = bit_part(bit)
    loader, port, model = check_part(port, part, bit)
    if board_check and model.startswith("xc7a200"):
        check_flash(port, loader, part, bit)
    return loader, port, model


def check_part(port: str, part: str,
               file: str) -> tuple[list[str], str, str]:
    """Stops unless the FPGA on the board of the serial port is the part
    that file was built for, and returns the openFPGALoader options that
    select its JTAG cable, the port's name by id (stable_port), which the
    tool uses from then on, and the model of the FPGA, xc7a100 on the
    Nexys4DDR and xc7a200 on the MEGA65."""
    serial = usb_serial(port)
    port = stable_port(port)
    cable, model = fpga_model(serial)
    ok = f"xc{part}".startswith(model)
    print(f"[{'PASS' if ok else 'FAIL'}] FPGA {model} on {port} (JTAG "
          f"{serial}), {os.path.basename(file)} for {part}", flush=True)
    if not ok:
        sys.exit(f"{PROG}: {file} is for {part}, but the FPGA on {port} is "
                 f"{model}; give the file for this board, or the --port of "
                 f"the board the file is for")
    wait_port(port)
    return ["-c", cable, "--ftdi-serial", serial], port, model


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
