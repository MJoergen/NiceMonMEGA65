"""The MEGA65's SPI flash through openFPGALoader's spiOverJtag bridge, for
what openFPGALoader does not do: clear the sectors' protection.

The S25FL512S of the MEGA65 has Advanced Sector Protection. Each sector
of 256 KiB has a volatile DYB and a persistent PPB, and the chip refuses
to erase or program a sector if either protects it: it sets E_ERR or
P_ERR in status register 1, and WIP then stays set until Clear Status.
On the MEGA65 the DYBs protect the sectors when a host gets to the flash.
MEGAFLASH clears a sector's DYB before it erases it (unprotect_flash() in
mega65-core's src/utilities/qspicommon.c). openFPGALoader v0.12.0 checks
only the status register's BP bits, so its erase fails with
"timeout: 23" (trabucayre/openFPGALoader#752). unprotect() clears the
DYBs of a range of the flash, so that openFPGALoader can then write it.

The bridge is the bitstream that openFPGALoader loads into the FPGA to
reach its flash, and stays there after openFPGALoader --skip-reset. In
its version 1, the IR holds USER1, and each DR scan is one SPI
transaction: Capture-DR lowers the chip select, each bit shifted is a
clock of the flash with TDI on its MOSI, Update-DR raises the chip
select, and TDO is the flash's MISO, one bit late. The bytes go most
significant bit first. Version 2 bridges of newer openFPGALoaders have a
header in each scan; unprotect() first reads the JEDEC ID, and stops
when the answer is not the S25FL512S's.

The script talks to the FTDI chip's JTAG interface with pyftdi's MPSSE,
on the pins of openFPGALoader's ft2232 cable: TCK, TDI, TDO, and TMS on
ADBUS0 to ADBUS3. pyftdi takes the interface from the kernel's driver as
openFPGALoader does.
"""

import sys
import time

# The cable's MPSSE pins: TCK, TDI, and TMS are outputs, TDO an input,
# TMS high at rest (openFPGALoader's ft2232 cable)
DIRECTION = 0x0B
INITIAL = 0x08
FREQUENCY = 6e6
# The 7-series' USER1 instruction, which selects the bridge's BSCANE2
USER1 = 0x02
IR_LEN = 6

# The S25FL512S's commands, with 4-byte addresses
JEDEC_ID = bytes([0x01, 0x02, 0x20])
RDID = 0x9F
RDSR1 = 0x05
WREN = 0x06
CLSR = 0x30
DYBRD = 0xE0
DYBWR = 0xE1
PPBRD = 0xE2
# Status register 1: write in progress, and the erase and program errors
WIP = 0x01
E_ERR = 0x20
P_ERR = 0x40
# Its uniform sectors, and the DYB and PPB value of an unprotected one
SECTOR_SIZE = 256 << 10
UNPROTECTED = 0xFF
# How long a DYB write may take; the datasheet gives microseconds
WAIT = 1.0

# MPSSE commands: TMS bits, alone or with TDO read; TDI bits and bytes
# out on the falling edge with TDO in on the rising edge, least
# significant bit first; and a flush of what was read
TMS_WRITE = 0x4B
TMS_RW = 0x6B
BITS_RW = 0x3B
BYTES_RW = 0x39
SEND_IMMEDIATE = 0x87


class SpiFlashError(Exception):
    """The flash or the bridge did not answer as expected."""


class Jtag:
    """The JTAG interface of the FTDI chip with that USB serial number,
    with the TAP in Run-Test/Idle between scans."""

    def __init__(self, serial: str):
        try:
            from pyftdi.ftdi import Ftdi
        except ImportError:
            sys.exit("spiflash.py: clearing the protection of the MEGA65's "
                     "flash needs pyftdi; pip install pyftdi")
        self.ftdi = Ftdi()
        self.ftdi.open_mpsse_from_url(f"ftdi://ftdi:2232:{serial}/1",
                                      direction=DIRECTION, initial=INITIAL,
                                      frequency=FREQUENCY)
        # Test-Logic-Reset, then Run-Test/Idle
        self._tms([1, 1, 1, 1, 1, 0])

    def ir(self, value: int) -> None:
        """Shifts an instruction into the IR."""
        self._tms([1, 1, 0, 0])  # Select-DR, Select-IR, Capture, Shift
        self._shift([(value >> i) & 1 for i in range(IR_LEN)])

    def dr(self, bits: list[int]) -> list[int]:
        """Shifts the bits through the DR, the first first, and returns the
        TDO bits."""
        self._tms([1, 0, 0])  # Select-DR, Capture-DR, Shift-DR
        return self._shift(bits)

    def close(self) -> None:
        """Leaves the TAP in Test-Logic-Reset and lets the chip go."""
        self._tms([1, 1, 1, 1, 1])
        self.ftdi.close()

    def _tms(self, bits: list[int]) -> None:
        """Clocks up to 7 TMS bits, with TDI high."""
        value = sum(b << i for i, b in enumerate(bits)) | 0x80
        self.ftdi.write_data(bytes([TMS_WRITE, len(bits) - 1, value]))

    def _shift(self, bits: list[int]) -> list[int]:
        """Shifts the bits through Shift-DR or Shift-IR, into which the
        caller has clocked TMS, and returns the TDO bits. The last bit
        goes with TMS high, to Exit1, and then Update and Run-Test/Idle
        follow."""
        body, last = bits[:-1], bits[-1]
        cmd = bytearray()
        nbytes, nbits = divmod(len(body), 8)
        if nbytes:
            cmd += bytes([BYTES_RW, (nbytes - 1) & 0xFF, (nbytes - 1) >> 8])
            cmd += bytes(sum(body[8 * i + j] << j for j in range(8))
                         for i in range(nbytes))
        if nbits:
            rest = body[8 * nbytes:]
            cmd += bytes([BITS_RW, nbits - 1,
                          sum(b << j for j, b in enumerate(rest))])
        # The last bit with TMS high, to Exit1, then Update and Idle
        cmd += bytes([TMS_RW, 0, 0x01 | (last << 7)])
        cmd += bytes([TMS_WRITE, 1, 0x01])
        cmd += bytes([SEND_IMMEDIATE])
        self.ftdi.write_data(bytes(cmd))
        n = nbytes + (1 if nbits else 0) + 1
        data = self.ftdi.read_data_bytes(n, attempt=100)
        if len(data) != n:
            raise SpiFlashError("the FTDI chip did not answer")
        out = [(data[i] >> j) & 1 for i in range(nbytes) for j in range(8)]
        if nbits:
            out += [(data[nbytes] >> (8 - nbits + j)) & 1
                    for j in range(nbits)]
        out.append(data[-1] >> 7)
        return out


class Bridge(Jtag):
    """SPI transactions with the flash through the bridge."""

    def __init__(self, serial: str):
        super().__init__(serial)
        # USER1 stays in the IR for the DR scans to come
        self.ir(USER1)

    def xfer(self, tx: bytes, nread: int = 0) -> bytes:
        """One SPI transaction: sends tx, then reads nread bytes."""
        bits = [(b >> (7 - j)) & 1 for b in tx for j in range(8)]
        if nread:
            # The reply comes one bit late, so one more bit
            bits += [1] * (8 * nread + 1)
        tdo = self.dr(bits)
        start = 8 * len(tx) + 1
        return bytes(sum(tdo[start + 8 * i + j] << (7 - j) for j in range(8))
                     for i in range(nread))

    def status(self) -> int:
        """Status register 1."""
        return self.xfer(bytes([RDSR1]), 1)[0]

    def wait(self) -> int:
        """Waits for WIP to clear, and returns the status register."""
        end = time.monotonic() + WAIT
        while True:
            sr = self.status()
            if not sr & WIP or sr & (E_ERR | P_ERR):
                return sr
            if time.monotonic() >= end:
                raise SpiFlashError(f"the flash stays busy, status "
                                    f"{sr:02X}")


def address(cmd: int, addr: int) -> bytes:
    """A command with a 4-byte address."""
    return bytes([cmd]) + addr.to_bytes(4, "big")


def unprotect(serial: str, offset: int, length: int) -> int:
    """Clears the DYBs of the sectors of offset to offset + length, through
    the bridge that openFPGALoader left in the FPGA. Clears a status
    register that an earlier erase or program left with an error. Raises
    SpiFlashError if the bridge does not reach an S25FL512S, a sector has
    its PPB set, or a DYB stays set. Returns the number of sectors whose
    DYB it cleared."""
    bridge = Bridge(serial)
    try:
        jedec = bridge.xfer(bytes([RDID]), 3)
        if jedec != JEDEC_ID:
            raise SpiFlashError(
                f"the bridge answers the JEDEC ID {jedec.hex(' ')}, not the "
                f"S25FL512S's {JEDEC_ID.hex(' ')}; is openFPGALoader's "
                f"spiOverJtag bridge of version 1 loaded?")
        if bridge.status() & (WIP | E_ERR | P_ERR):
            bridge.xfer(bytes([CLSR]))
            sr = bridge.status()
            if sr & (WIP | E_ERR | P_ERR):
                raise SpiFlashError(f"Clear Status leaves the status "
                                    f"register at {sr:02X}")
        cleared = 0
        first = offset // SECTOR_SIZE
        last = (offset + length - 1) // SECTOR_SIZE
        for sector in range(first, last + 1):
            addr = sector * SECTOR_SIZE
            ppb = bridge.xfer(address(PPBRD, addr), 1)[0]
            if ppb != UNPROTECTED:
                raise SpiFlashError(
                    f"the sector at {addr:08X} has its persistent "
                    f"protection (PPB {ppb:02X}) set, which only an erase "
                    f"of all PPBs clears")
            if bridge.xfer(address(DYBRD, addr), 1)[0] == UNPROTECTED:
                continue
            bridge.xfer(bytes([WREN]))
            bridge.xfer(address(DYBWR, addr) + bytes([UNPROTECTED]))
            sr = bridge.wait()
            dyb = bridge.xfer(address(DYBRD, addr), 1)[0]
            if dyb != UNPROTECTED or sr & (E_ERR | P_ERR):
                raise SpiFlashError(
                    f"the sector at {addr:08X} stays protected (DYB "
                    f"{dyb:02X}, status {sr:02X})")
            cleared += 1
        return cleared
    finally:
        bridge.close()
