# synth

The Vivado builds, in non-project mode, one directory per board. The MEGA65
is the main board; the Nexys4DDR also builds, with VGA only, a smaller
screen memory, and its LEDs, display, buttons, and switches.

| Path | Board | FPGA |
|---|---|---|
| [r3/](r3/) | MEGA65 R3 and R3A | XC7A200T (`xc7a200tfbg484-2`) |
| [r6/](r6/) | MEGA65 R6 | XC7A200T (`xc7a200tfbg484-2`) |
| [nexys4ddr/](nexys4ddr/) | Digilent Nexys4DDR (Nexys A7-100T) | XC7A100T (`xc7a100tcsg324-1`) |

Every board's top level has `src/system.vhd`, the NiceMon system and the
text display of its screen, with the UART's pins. [common/](common/) holds
the rest that every board shares, as all have a 100 MHz clock and a 7-series
FPGA: the clock and reset (`clk_rst.vhd`, an MMCM that makes the system
clock and the 50 MHz clock of the Ethernet PHY), and the video clocks (`video_clk.vhd`, a second MMCM that makes the
108 MHz pixel clock and the 540 MHz clock of the HDMI serializers).
[Makefile.inc](Makefile.inc) is the build; each board's `Makefile` gives it
the part, the board's sources, and its constraints.

## Building

To build, with Vivado installed in `/opt/Xilinx/2025.1/Vivado` (or set
`VIVADO_DIR`):

    make -C synth/r6

or `make r6` in the top directory, and likewise for `r3` and `nexys4ddr`.
The bitstream is `synth/r6/build/top.bit`, with timing and utilization
reports next to it. Its core waits, held, for a host on the debug link.
With

    make -C synth/r6 ROM=/path/to/monitor.bin

the core boots at reset from a ROM of 32K words at address 0 with the words
of the `.bin` file (`src/rom.vhd`, through `G_ROM_FILE` of `top.vhd`), as
[SYSTEM.md](../doc/SYSTEM.md#the-rom) describes. Vivado reads the file during
synthesis, so the bitstream is rebuilt when it changes. `make r6
ROM=monitor.bin` in the top directory does the same with a path relative
to it.

`make -C synth/r6 cor`, or `make cor` in the top directory for both
revisions, makes the core file `synth/r6/build/NiceMonMEGA65-r6.cor`
from the bitstream, which it builds first if needed. MEGAFLASH writes a
core file into a slot of the MEGA65's flash (hold No Scroll at power on),
and the board then starts the system without a JTAG cable. MEGAFLASH shows
the name `NiceMon` and the version, the commit (`git describe --always
--dirty`); set `COR_NAME` or `COR_VERSION` to change them. A core file
holds its board revision, so flash the R3's on an R3 and the R6's on an
R6. It needs `coretool`, the Python script `src/tools/coretool` of
[mega65-tools](https://github.com/MEGA65/mega65-tools), on the `PATH` or
in `CORETOOL`.

The user LED is on while the core runs. The Nexys4DDR is programmed with
`openFPGALoader -b nexys_a7_100 synth/nexys4ddr/build/top.bit`, or with
Vivado's hardware manager. With a MEGA65 also attached, openFPGALoader
takes the first cable it finds, which may be the MEGA65's. Add
`--ftdi-serial` with the Nexys4DDR's serial number, which
`openFPGALoader --scan-usb` lists, or use `make hwtest`, which checks the
FPGA first.

The Nexys4DDR may also start the system from its quad SPI flash, as a
MEGA65 starts a core from its own. `make flash PORT=/dev/ttyUSB1`, with
the board's serial port, writes `synth/nexys4ddr/build/top.bit` into the
flash with openFPGALoader, and `BIT=nicemon-TAG-nexys4ddr.bit` writes the
bitstream of a release instead, TAG being its tag, such as `V1.1`.
It checks the FPGA first, as `make hwtest` does, and refuses a MEGA65's
bitstream. It verifies the flash, and waits for the board to start from
it. Set jumper JP1 (MODE) to QSPI, and the FPGA then loads the system at
power on and when PROG is pressed. A bitstream with the demo in its ROM
then shows the demo, with no USB cable. `make flash PORT=/dev/ttyUSB1 ARGS=--erase` erases
the flash. Vivado's hardware manager can write the flash too.

## The MEGA65

The two MEGA65 boards have the debug UART on the same pins. They differ in
the reset button:

| Path | Reset |
|---|---|
| [r3/](r3/) | The reset button, read by the MAX10 FPGA and sent to the FPGA over a serial link. |
| [r6/](r6/) | The reset button, wired to the FPGA. |

[mega65/](mega65/) holds what the MEGA65 boards share: `mega65.vhd`, the
top level apart from a few pins, with the system clock at 100 MHz, the
keyboard (on the same three pins on both boards; the MAX10 of the R3 is not
involved), and the video outputs; `mega65.xdc`, the constraints for timing,
the keyboard, and configuration; and `mega65.mk`, the part and the sources
for the boards' Makefiles. The pins come from MiSTer2MEGA65, and those of
the video from MandelbrotMEGA65.

The screen is shown on the VGA connector, through the video DAC, and on the
HDMI connector, at 1280×1024 and 60 Hz (see
[SYSTEM.md](../doc/SYSTEM.md#the-screen)). The boards differ in the pins
around the video, which each board's `top.vhd` drives: the R6 has a power
save input on the DAC, and its HDMI level shifter is a PTN3363, where the
R3 has a TPD12S016.

## The Nexys4DDR

`nexys4ddr/top.vhd` is the whole top level, and `nexys4ddr.xdc` has its
pins, from Digilent's master XDC. The console is the board's USB-UART, the
screen is on its VGA connector, and LED0 is on while the core runs, or
while the program sets it. A USB keyboard in the USB HID port types into
the console too: the board's PIC24 turns it into PS/2, which
`src/kbd_ps2.vhd` receives and `src/kbd_ps2_ascii.vhd` turns into ASCII.
The receiver only listens, so the keyboard's LEDs are not set. The board's
16 LEDs, two RGB LEDs, seven-segment display, five buttons, and 16 switches
are registers in `0xFFFFFF90`–`96` (see
[SYSTEM.md](../doc/SYSTEM.md#the-nexys4ddrs-devices)). `src/seg7.vhd` scans the
display, and `src/rgb_pwm.vhd` dims the RGB LEDs with 16 levels; both drive
registered outputs in the IOBs. The CPU RESET button resets the system. The
board differs from the MEGA65 in three ways:

- Its FPGA has 135 block RAMs of 36 Kbit, where the MEGA65's has 365. The
  RAM and the ROM are the same as on the MEGA65, and take 96 of them, but
  the screen is 8K words, not 32K, so that it and its copy in `text.vhd`
  take 16, not 64. With the font, the UART's FIFO, and the Ethernet
  station's 2.5, that is 119 with the ROM. 8K words are still more than three screens of 80×25 for
  scrolling.
- Its FPGA is speed grade -1, where the MEGA65's is -2, so the system clock
  is 90 MHz, not 100 MHz; at 100 MHz the pipelined core misses timing by a
  few tenths of a nanosecond or less, as placement varies. The UART runs
  at 2 Mbaud as on the MEGA65.
- Its VGA output has 4 bits per color, from resistors, and there is no
  HDMI. The screen's colors have 4 bits per color, so they show
  as on the MEGA65.

## The Ethernet PHYs

Every board has an Ethernet PHY on RMII, which the Ethernet station
(`src/eth/eth.vhd`, [SYSTEM.md](../doc/SYSTEM.md#the-ethernet-station))
drives:

| Board | PHY | Pins |
|---|---|---|
| MEGA65 R3 and R6 | Microchip KSZ8081RNDCA (U4) | `mega65/mega65.xdc`, the same on both |
| Nexys4DDR | SMSC LAN8720A | `nexys4ddr/nexys4ddr.xdc` |

The FPGA gives the PHY its 50 MHz reference clock, from the MMCM of
`common/clk_rst.vhd` through an ODDR, 2.5 ns early (see
[Timing](#timing)). The PHY's reset, active low, is a register in the IOB,
and holds the PHY as long as the system is held in reset: at least 10 ms
after the clock starts, more than either PHY needs. The PHY then runs
with its reset defaults and negotiates the link on its own. MDC and MDIO
are not connected, as no PHY register is read or written, and neither
is the PHY's interrupt, nor the MEGA65's ETH_LED2. RXD, CRS_DV, and RXER go to
`src/eth/rmii_rx.vhd`, and `src/eth/rmii_tx.vhd` drives TXD and TX_EN;
all are registered in the IOBs. The station works only at 100 Mbit/s.

## Third-party files

`r3/max10.vhd` drives the link to the MAX10. It is copied unchanged from
[MandelbrotMEGA65](https://github.com/MJoergen/MandelbrotMEGA65)
(`src/max10/max10.vhd`, commit a3fafd4), which took it from the
[MEGA65 core](https://github.com/MEGA65/mega65-core) by Paul
Gardner-Stephen, via C64MEGA65. It is GPL v3, unlike the rest of this
repository.

`mega65/hdmi/` is the HDMI output of MandelbrotMEGA65 (`src/hdmi/`, commit
a3fafd4), copied unchanged: the Tyto Project by Adam Barnes, via C64MEGA65,
LGPL v3. `mega65/mega65.vhd` drives it, the video DAC, and the clocks as
MandelbrotMEGA65's `mega65.vhd` does.

## Build times and size

A build takes four to six minutes on an Intel Core i9-10850K (10 cores,
20 threads) with Vivado 2025.1, and much longer on a busy machine. These
are the times of the last builds, in minutes and seconds, without `ROM=`:

| Build | Synthesis | Placement | Routing | Bitstream | Total |
|---|---|---|---|---|---|
| R6, pipelined | 3:06 | 0:42 | 1:19 | 0:34 | 6:05 |
| R6, `NICE=multi` | 1:29 | 0:28 | 1:06 | 0:32 | 3:55 |
| Nexys4DDR, pipelined | 3:06 | 0:55 | 1:03 | 0:29 | 5:49 |
| Nexys4DDR, `NICE=multi` | 1:53 | 0:31 | 1:15 | 0:28 | 4:18 |
| R3, pipelined | 3:10 | 0:46 | 1:10 | 0:36 | 6:05 |

The Nexys4DDR builds with `FLOW=timing`.

### Utilization

The utilization is from `build/utilization.rpt`, and the split by module
from `report_utilization -hierarchical` on `build/top.dcp`. These are the
numbers without `ROM=`, in LUTs and flip-flops. The R6's pipelined column
is from the build of the V1.1 bump, at nice_cpu V1.1, and the Nexys4DDR's
from one at nice_cpu V1.0, both with the Ethernet station. The multi-cycle columns are older, from
builds that had a command line in place of the link, counted in the rest,
and neither the Nexys4DDR's devices nor the microsecond counter:

| Part of the design | R6, pipelined | R6, multi | Nexys4DDR, pipelined | Nexys4DDR, multi |
|---|---|---|---|---|
| The core (`nice_core`) | 6931 / 3032 | 4605 / 1050 | 6844 / 3027 | 4636 / 4071 |
| The math unit (`mpu`) | 2079 / 874 | 2172 / 874 | 2080 / 874 | 2166 / 874 |
| The fetch statistics (`fetch_stats`) | 813 / 1361 | 44 / 99 | 812 / 1361 | 44 / 99 |
| The debug link (`debug_link`) | 875 / 1083 | – | 872 / 1082 | – |
| The Ethernet station (`eth/eth.vhd`) | 2303 / 1866 | – | 2038 / 1791 | – |
| Of which the TCP server (`eth/eth_tcp.vhd`) | 1690 / 1237 | – | 1429 / 1163 | – |
| The rest: the UART, RAM, counters, timer, the Nexys4DDR's devices, and glue | 1652 / 918 | 795 / 1156 | 1836 / 1059 | 740 / 1119 |
| The text display (`text.vhd`) | 117 / 180 | 123 / 180 | 115 / 156 | 121 / 156 |
| The keyboard | 649 / 600 | 596 / 585 | 146 / 48 | – |
| The HDMI output | 599 / 1207 | 574 / 1207 | – | – |
| Total | 16017 / 11121 | 8909 / 5151 | 14743 / 9398 | 7707 / 6319 |
| Total, of the FPGA | 12.0 % / 4.2 % | 6.7 % / 1.9 % | 23.3 % / 7.4 % | 12.2 % / 5.0 % |

The R3 pipelined build takes 15774 LUTs and 11166 flip-flops, 11.8 % and
4.2 % of the FPGA.

Vivado optimizes across the boundaries of the modules, so the rows move
from build to build more than the logic does: in the builds with the TCP
server, about 700 LUTs left the core's rows for the rest of `nicemon`.
The totals are what count.

The pipelined core is about 5.2 % of the LUTs of the R6's FPGA, and 10.8 %
of the Nexys4DDR's. The multi-cycle core has two thirds of its LUTs, 3.4 %
and 7.3 %. On the R6 it has a third of the flip-flops too. On the
Nexys4DDR it has 4071, more than the pipelined core's 3027, because
`FLOW=timing` retimes (`synth_design -retiming`): it moves registers
backwards and adds copies of the core's register file and state, so the
design has twice the flip-flops. With `FLOW=default` the build has 3202
flip-flops but misses 90 MHz by 0.37 ns, so the copies buy timing. With
the retiming it meets 90 MHz by 0.19 ns, and the Nexys4DDR has room for
the flip-flops.

The `fetch_stats` of the pipelined core (the fetch statistics in
[SYSTEM.md](../doc/SYSTEM.md#address-map)'s address map) has over a thousand
flip-flops, and the multi-cycle core's has few. The pipelined core uses no
block RAM. The multi-cycle core uses one RAMB18, which Vivado infers for
`src2_count`, the register of the shift count. The math unit has the 4
DSPs of the design.

### Timing

All builds meet the clock. These are the worst setup and hold slacks:

| Build | Clock | Setup | Hold |
|---|---|---|---|
| R6, pipelined | 100 MHz | 0.086 ns | 0.012 ns |
| R6, `NICE=multi` | 100 MHz | 0.52 ns | – |
| R3, pipelined | 100 MHz | 0.109 ns | 0.061 ns |
| Nexys4DDR, pipelined | 90 MHz | 0.059 ns | 0.015 ns |
| Nexys4DDR, `NICE=multi` | 90 MHz | 0.19 ns | – |

The R6's pipelined row is from the build of the V1.1 bump, at nice_cpu
V1.1, with the debug link of version 5, the one that `verified.json`
records. The R3's and the Nexys4DDR's pipelined rows are from builds at
nice_cpu V1.0, with the debug link of version 4. All three have the
Ethernet station, which answers ARP requests and pings and carries the
link over TCP. The multi-cycle rows are older builds, with fewer link features, and their
hold slacks were not recorded. The slacks change from build to build with
placement more than with the logic. The worst paths are usually in the
core's WRITE and FETCH stages.

The PHY's RXD and CRS_DV are timed against the clock on its pin, with the
output delays of the PHYs' data sheets and 1 ns for the traces. The pin's
clock is 2.5 ns early (`common/clk_rst.vhd`); without that, the
Nexys4DDR misses the setup by 0.07 ns. With it, the inputs have 3.5 ns of
setup and 6.5 ns of hold slack on the MEGA65, and 2.2 ns and 1.4 ns on
the Nexys4DDR. TXD and TX_EN are timed against it too, with the setup and
hold times of the PHYs' data sheets; they have 9.7 ns of setup and 1.0 ns
of hold slack on the R6, and 11.1 ns and 0.4 ns on the Nexys4DDR.

### Block RAM

The block RAMs, of 36 Kbit, are these:

| Memory | MEGA65 | Nexys4DDR |
|---|---|---|
| The RAM (`i_ram`), 64K words | 64 | 64 |
| The ROM (`i_rom`), 32K words, with `ROM=` only | 32 | 32 |
| The screen (`i_scr` in `mem.vhd`), 32K or 8K words | 32 | 8 |
| Its copy in `text.vhd` (`scr_ram.vhd`) | 32 | 8 |
| The font in `text.vhd` | 4 | 4 |
| The UART's input FIFO (`rx_fifo.vhd`), one RAMB18 | 0.5 | 0.5 |
| The FIFO of received Ethernet frames (`eth/eth_ram.vhd`), 2K bytes, one RAMB18 | 0.5 | 0.5 |
| The FIFO of Ethernet frames to send (`eth/eth_ram.vhd`), 2K bytes, one RAMB18 | 0.5 | 0.5 |
| The copy of a ping in `eth/eth_icmp.vhd`, 2K bytes, one RAMB18 | 0.5 | 0.5 |
| The TCP server's buffers of received and sent bytes (`eth/eth_ram.vhd` in `eth/eth_tcp_buf.vhd`), 2K bytes each, one RAMB18 each | 1 | 1 |
| Total without the ROM, pipelined | 135 of 365 | 87 of 135 |
| Total with the ROM, pipelined | 167 | 119 |

The copy of the screen keeps all 32 bits, as the display reads the
character and both 12-bit colors, so it takes as many block RAMs as the
screen. The multi-cycle core adds half of one more, its RAMB18.
