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
reports next to it. Built in `synth/r6`, it has no ROM, and its core
waits, held, for a host on the debug link. `make r6` in the top directory
builds the monitor and the demo first and puts them in the ROM,
`demo/build/rom.bin`, unless `ROM=` gives another
file, or none when empty. The monitor has C code, so that needs clang
too ([monitor/](../monitor/INTERNALS.md#building-and-testing)). With

    make -C synth/r6 ROM=/path/to/monitor.bin

the core boots at reset from a ROM of 32K words at address 0 with the words
of the `.bin` file (`src/rom.vhd`, through `G_ROM_FILE` of `top.vhd`), as
[PROGRAMMING.md](../doc/PROGRAMMING.md#programs-in-the-rom) describes. Vivado reads the file during
synthesis, so the bitstream is rebuilt when it changes, and a word
beyond the ROM fails the build. `make r6
ROM=monitor.bin` in the top directory does the same with a path relative
to it.

`FLOW=default`, the default, runs every step of Vivado with its default
directives, with which the MEGA65 met 100 MHz until nice_cpu V2.0; now
it misses, and the MEGA65 needs `FLOW=timing` (see [Timing](#timing)).
`FLOW=timing` runs them
with directives for timing: `synth_design -directive
PerformanceOptimized -retiming`, `opt_design -directive Explore`,
`place_design -directive ExtraTimingOpt`, or the `PLACE_TIMING` of the
board's Makefile, `AltSpreadLogic_high` on the R6, and `AggressiveExplore`
for `phys_opt_design` and `route_design`, with `phys_opt_design` again
after routing ([Makefile.inc](Makefile.inc)). The Nexys4DDR's Makefile
sets `FLOW=timing`, as its slower part needs it (see [Timing](#timing)).

Every registered pin carries `IOB TRUE` in the board's XDC, with a plain
register in front of the pin and no logic between them, so that Vivado
packs the register into the I/O tile. A register that also feeds internal
logic is replicated with a warning; the logic is driven from the source
signal instead.

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

`make flash COR=synth/r6/build/NiceMonMEGA65-r6.cor SLOT=1` writes the
core file into slot 1 over the JTAG cable instead, with no key held at
power on. It takes slots 1 to 7, as slot 0 holds the MEGA65's own core.
It checks the FPGA first, as `make hwtest` does, and stops unless the core
in slot 0 is for the core file's revision. It shows what the slot held,
and clears the protection of the slot's sectors, which openFPGALoader
leaves set, with pyftdi (`pip install pyftdi`). It then writes and
verifies the flash, and loads the slot's bitstream into the FPGA over
JTAG, so the system runs at once. Hold No Scroll at power on to start
the slot from the flash, as slot 0's core may start another slot on its
own.

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
power on and when PROG is pressed. A bitstream with the monitor in its
ROM then shows the monitor, with no USB cable. `make flash PORT=/dev/ttyUSB1 ARGS=--erase` erases
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
pins, from Digilent's master XDC. `nexys4ddr_synth.xdc` keeps two of
nice_cpu's memories in block RAM (see [Block RAM](#block-ram)). The
console is the board's USB-UART, the screen is on its VGA connector, and
LED0 is on while the core runs, or while the program sets it. A USB
keyboard in the USB HID port types into the console too: the board's
PIC24 turns it into PS/2, which
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
  take 16, not 64. With the fonts, the debugger's overlay, the UART's
  FIFO, and the Ethernet station's 2.5, that is 127 of 135 with the
  ROM. 8K words are still more than three screens of 80×25 for
  scrolling.
- Its FPGA is speed grade -1, where the MEGA65's is -2, so the system clock
  is 90 MHz, not 100 MHz; at 100 MHz the pipelined core misses timing by a
  few tenths of a nanosecond or less, as placement varies. The UART runs
  at 230400 baud after reset, as on the MEGA65.
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

The other third-party files are `src/uart_serdes.vhd`, from
[cmod-s7](https://github.com/MJoergen/cmod-s7), MIT, with fixes to its
receiver and break detection; `src/video/pix.vhd`, the pixel coordinates,
and `src/video/video_pkg.vhd`, the video modes, from MandelbrotMEGA65,
MIT; and `src/video/font_pkg.vhd`, the
[Spleen](https://github.com/fcambus/spleen) 16×32 font, BSD 2-Clause
(`font/LICENSE.spleen`), which `font/gen_font_pkg.py` makes.

## Build times and size

These are the builds of 2026-11-09, at nice_cpu V2.0 with the wait and
the hidden state on the debug link, each with the ROM of the
monitor and the demo, as `make release` builds them. The history of
these numbers, and what the builds before taught, is in
[HISTORY.md](HISTORY.md).

A build takes ten to twenty minutes on an Intel Core i9-10850K (10
cores, 20 threads) with Vivado 2025.1, and the R6 with `FLOW=timing`
an hour, most of it in routing. These are the times, in minutes and
seconds, on a machine busy with other work, at a load of about 12, but
for the R6's default flow, at about 5:

| Build | Synthesis | Placement | Routing | Bitstream | Total |
|---|---|---|---|---|---|
| R6, pipelined, default flow | 3:35 | 1:41 | 2:30 | 0:39 | 9:11 |
| R6, pipelined, `FLOW=timing` | 5:43 | 6:54 | 45:16 | 0:51 | 59:22 |
| R6, `NICE=multi` | 4:46 | 2:07 | 2:49 | 0:54 | 11:41 |
| R3, pipelined, default flow | 5:25 | 3:06 | 4:24 | 0:50 | 14:53 |
| R3, pipelined, `FLOW=timing` | 5:25 | 8:52 | 5:19 | 0:52 | 21:05 |
| Nexys4DDR, pipelined | 4:31 | 4:46 | 6:22 | 0:49 | 17:12 |
| Nexys4DDR, `NICE=multi` | 3:25 | 2:03 | 1:59 | 0:46 | 8:50 |

Placement includes `phys_opt_design` before routing, and routing the
one after it. The total is that of `make`, with the steps of Vivado
between them.

### Utilization

The utilization is from `build/utilization.rpt`, and the split by module
from `report_utilization -hierarchical` on `build/top.dcp`, in LUTs and
flip-flops:

| Part of the design | R6, pipelined | R6, multi | Nexys4DDR, pipelined | Nexys4DDR, multi |
|---|---|---|---|---|
| The core (`nice_core`) | 8616 / 3544 | 4881 / 1203 | 8519 / 3340 | 4970 / 1047 |
| The debug link (`debug_link`) | 2540 / 1456 | 2623 / 1285 | 2570 / 1456 | 2644 / 1285 |
| The devices (`devices.vhd`): the math unit, the counters, the fetch statistics, the timer, the SD card controller, the network station's registers, and the port for Ethernet frames | 4971 / 3768 | 4269 / 2857 | 5012 / 3743 | 6669 / 3005 |
| The Ethernet station (`eth/eth.vhd`) | 2766 / 2732 | 2763 / 2732 | 2770 / 2755 | 3248 / 2865 |
| Of which the TCP server (`eth/eth_tcp.vhd`) | 1904 / 1897 | 1902 / 1897 | 1632 / 1920 | 1633 / 1920 |
| The on-board debugger (`dbg/dbg.vhd`) | 3028 / 2853 | 3026 / 2838 | 3072 / 2942 | 3282 / 2959 |
| The text display (`text.vhd`) | 136 / 202 | 139 / 202 | 138 / 178 | 142 / 178 |
| The keyboard | 720 / 592 | 720 / 592 | 236 / 89 | 235 / 89 |
| The HDMI output | 600 / 1207 | 600 / 1207 | – | – |
| The rest: the UART, the memory's buses, the board's and the screen's registers, and glue | 719 / 552 | 746 / 530 | 733 / 637 | 629 / 631 |
| Total | 24096 / 16914 | 19767 / 13446 | 23050 / 15140 | 21819 / 12059 |
| Total, of the FPGA | 18.0 % / 6.3 % | 14.8 % / 5.0 % | 36.4 % / 11.9 % | 34.4 % / 9.5 % |

The pipelined columns are from the builds of 2026-11-10, with `FLOW=timing`,
which have the 4 watchpoints of the debug link (issue #99) and the clock
of the time of day (issue #97); the others are older. The watchpoints
take about 900 to 1000 LUTs of the core. The
R3's pipelined build with `FLOW=timing` takes 23484 LUTs and 16435
flip-flops, 17.6 % and 6.1 % of the FPGA.

The pipelined core is 6.4 % of the LUTs of the R6's FPGA, and 13.4 % of
the Nexys4DDR's. The multi-cycle core has about two thirds of its LUTs,
3.6 % and 7.8 %, and a third of its flip-flops. The Nexys4DDR's
multi-cycle column is from before issue #103 put five memories into
block RAM (see [Block RAM](#block-ram)), so its devices still have about
2400 LUTs of those memories. Vivado optimizes
across the boundaries of the modules, so the rows move from build to
build more than the logic does; the totals are what count.

The math unit and the settings page of the debugger (`dbg/dbg_set.vhd`)
have the 6 DSPs of the design. The pipelined core uses no block RAM, and
the multi-cycle core one RAMB18, which Vivado infers for `src2_count`,
the register of the shift count.

### Timing

These are the worst setup and hold slacks, in ns:

| Build | Clock | Setup | Hold |
|---|---|---|---|
| R6, pipelined, default flow | 100 MHz | **−0.526**, 324 endpoints | 0.069 |
| R6, pipelined, `FLOW=timing` | 100 MHz | 0.008 | 0.070 |
| R6, `NICE=multi` | 100 MHz | 0.187 | 0.075 |
| R3, pipelined, default flow | 100 MHz | **−0.073**, 2 endpoints | 0.035 |
| R3, pipelined, `FLOW=timing` | 100 MHz | 0.126 | 0.041 |
| Nexys4DDR, pipelined, `FLOW=timing` | 90 MHz | 0.140 | 0.039 |
| Nexys4DDR, `NICE=multi`, `FLOW=timing` | 90 MHz | 0.186 | 0.019 |

So the pipelined core meets its clock on every board with `FLOW=timing`
only, and the R6 and the Nexys4DDR with little to spare. On the MEGA65,
`make release` tries the default flow first, then `FLOW=timing`. The R6's worst paths
are in the core's WRITE stage in the default flow, from its
micro-operation to its value, and in the timing flow from the read
data of the ROM, the RAM, or a device into WRITE's register file. With
the watchpoints and the clock, the R6 missed by 0.404 ns while
`devices.vhd` picked its read data with a chain of multiplexers; it
picks it with one AND-OR now, as `nicemon.vhd` does. Before that,
the R6 without the watchpoints missed by 0.112 ns, and without the
clock met by 0.031 ns, so the clock's word in that chain cost more
than the watchpoints. The R3's worst paths in the
default flow are from the MAX10's inputs (`max10.vhd`), and the
Nexys4DDR's from WRITE into its register file. `verified.json` records
the build of the latest release's bump, and the badge shows it.

Every build writes the five worst paths into the TCP server, within it,
and out of it to `build/tcp_paths.rpt`. Their worst slack is 1.639 ns on
the R6 and 1.994 ns on the Nexys4DDR.

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
| The RAM (`i_ram`), 128K words on the MEGA65 and 64K on the Nexys4DDR | 128 | 64 |
| The ROM (`i_rom`), 32K words, with a ROM only | 32 | 32 |
| The screen (`i_scr` in `mem.vhd`), 32K or 8K words | 32 | 8 |
| Its copy in `text.vhd` (`scr_ram.vhd`) | 32 | 8 |
| The fonts in `text.vhd` (`font.vhd`): the font RAM, 8K words of 16 bits, and the character ROM, one dual-port ROM | 8 | 8 |
| The debugger's overlay in `text.vhd` (`scr_ram.vhd`), 4K words | 4 | 4 |
| The UART's input FIFO (`rx_fifo.vhd`), one RAMB18 | 0.5 | 0.5 |
| The FIFO of received Ethernet frames (`eth/eth_ram.vhd`), 2K bytes, one RAMB18 | 0.5 | 0.5 |
| The FIFO of Ethernet frames to send (`eth/eth_ram.vhd`), 2K bytes, one RAMB18 | 0.5 | 0.5 |
| The copy of a ping in `eth/eth_icmp.vhd`, 2K bytes, one RAMB18 | 0.5 | 0.5 |
| The TCP server's buffers of received and sent bytes (`eth/eth_ram.vhd` in `eth/eth_tcp_buf.vhd`), 2K bytes each, one RAMB18 each | 1 | 1 |
| The station's buffer of a frame for the port for Ethernet frames (`eth/eth_frames.vhd`), 512 words, one RAMB18 | 0.5 | 0.5 |
| The port for Ethernet frames (nice_cpu's `eth_regs.vhd`): the queue of frames received, 2K words, and the send buffer, 512 words | 3 | 3 |
| The SD card controller's buffer (nice_cpu's `sd_regs.vhd`), four RAMB18 | 2 | 2 |
| The debugger's page (`mem_ram` in `dbg/dbg.vhd`), 256 words, one RAMB18 | 0.5 | 0.5 |
| Total without the ROM, pipelined | 213 of 365 | 101 of 135 |
| Total with the ROM, pipelined | 245 | 133 |

The copy of the screen keeps all 32 bits, as the display reads the
character and both 12-bit colors, so it takes as many block RAMs as the
screen. The multi-cycle core adds half of one more, its RAMB18, on the
MEGA65. The table of `kbd_ps2_ascii.vhd` is in LUTs, 58 of them, though
Vivado's preliminary report of ROMs shows it in block RAM.

On the Nexys4DDR, Vivado makes distributed RAM of a memory that has no
`ram_style` or `rom_style` attribute, though block RAMs are free: it did
with the screen of `mem.vhd`, its font, and the UART's FIFO (issue #70),
and with the five memories of the last four rows above, about 2500 LUTs, of which the port's queue of frames alone took 352 RAM64M (issue
#103). The local memories have the attribute. The two in nice_cpu's
`eth_regs.vhd` and `sd_regs.vhd` get `RAM_STYLE` from
`nexys4ddr/nexys4ddr_synth.xdc`, which only synthesis reads, as its
cells' names change in synthesis. That left 2 of the 135 free and gained
the Nexys4DDR 0.009 ns of setup slack; its worst path into the core now
starts at the SD card controller's buffer, with 0.176 ns to spare.
