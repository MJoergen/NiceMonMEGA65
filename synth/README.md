# synth

The Vivado builds, in non-project mode, one directory per board. The MEGA65
is the main board; the Nexys4DDR also builds, with fewer devices.

| Path | Board | FPGA |
|---|---|---|
| [r3/](r3/) | MEGA65 R3 and R3A | XC7A200T (`xc7a200tfbg484-2`) |
| [r6/](r6/) | MEGA65 R6 | XC7A200T (`xc7a200tfbg484-2`) |
| [nexys4ddr/](nexys4ddr/) | Digilent Nexys4DDR (Nexys A7-100T) | XC7A100T (`xc7a100tcsg324-1`) |

Every board's top level has `src/system.vhd`, the NiceMon system and the
text display of its screen, with the UART's pins. [common/](common/) holds
the rest that every board shares, as all have a 100 MHz clock and a 7-series
FPGA: the clock and reset (`clk_rst.vhd`, an MMCM that makes the system
clock), and the video clocks (`video_clk.vhd`, a second MMCM that makes the
108 MHz pixel clock and the 540 MHz clock of the HDMI serialisers).
[Makefile.inc](Makefile.inc) is the build; each board's `Makefile` gives it
the part, the board's sources, and its constraints.

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
HDMI connector, at 1280×1024 and 60 Hz (see the main README). The boards
differ in the pins around the video, which their `top.vhd` drive: the R6
has a power save input on the DAC, and its HDMI level shifter is a PTN3363,
where the R3 has a TPD12S016.

## The Nexys4DDR

`nexys4ddr/top.vhd` is the whole top level, and `nexys4ddr.xdc` has its
pins, from Digilent's master XDC. The console is the board's USB-UART, the
screen is on its VGA connector, and LED0 is on while the core runs. There
is no keyboard, and the board's other LEDs, its buttons, its switches, and
its seven-segment display are not used yet (see [TODO.md](../TODO.md)). The
CPU RESET button resets the system. The board differs from the MEGA65 in
three ways:

- Its FPGA has 135 block RAMs of 36 Kbit, where the MEGA65's has 365. The
  RAM and the ROM are the same as on the MEGA65, and take 96 of them, but
  the screen is 8K words, not 32K, so that it and its copy in `text.vhd`
  take 14, not 56. With the font and the UART's FIFO, that is 114.5 with
  the ROM. 8K words are still more than three screens of 80×25 for
  scrolling.
- Its FPGA is speed grade -1, where the MEGA65's is -2, so the system clock
  is 90 MHz, not 100 MHz; at 100 MHz the pipelined core misses timing by a
  few tenths of a nanosecond or less, as placement varies. The UART runs at 115200 baud as on the MEGA65.
- Its VGA output has 4 bits per colour, from resistors, and there is no
  HDMI. The screen's colours have 3 bits or fewer per colour, so they show
  as on the MEGA65.

## Building

To build, with Vivado installed in `/opt/Xilinx/2025.1/Vivado` (or set
`VIVADO_DIR`):

    make -C synth/r6

or `make r6` in the top directory, and likewise for `r3` and `nexys4ddr`.
The bitstream is `synth/r6/build/top.bit`, with timing and utilisation
reports next to it. Its core waits for the command line. With

    make -C synth/r6 ROM=/path/to/monitor.bin

the core boots at reset from a ROM of 32K words at address 0 with the words
of the `.bin` file (`src/rom.vhd`, through `G_ROM_FILE` of `top.vhd`), as
the main README describes under "The ROM". Vivado reads the file during
synthesis, so the bitstream is rebuilt when it changes. `make r6
ROM=monitor.bin` in the top directory does the same with a path relative
to it.

The user LED is on while the core runs. The Nexys4DDR is programmed with
`openFPGALoader -b nexys_a7_100 synth/nexys4ddr/build/top.bit`, or with
Vivado's hardware manager. With a MEGA65 also attached, openFPGALoader
takes the first cable it finds, which may be the MEGA65's. Add
`--ftdi-serial` with the Nexys4DDR's serial number, which
`openFPGALoader --scan-usb` lists, or use `make hwtest`, which checks the
FPGA first.

`r3/max10.vhd` drives the link to the MAX10. It is copied unchanged from
[MandelbrotMEGA65](https://github.com/MJoergen/MandelbrotMEGA65)
(`src/max10/max10.vhd`, commit a3fafd4), which took it from the
[MEGA65 core](https://github.com/MEGA65/mega65-core) by Paul
Gardner-Stephen, via C64MEGA65. It is GPL v3, unlike the rest of this
repository.

`mega65/hdmi/` is the HDMI output of MandelbrotMEGA65 (`src/hdmi/`, commit
a3fafd4), copied unchanged: The Tyto Project by Adam Barnes, via C64MEGA65,
LGPL v3. `mega65/mega65.vhd` drives it, the video DAC, and the clocks as
MandelbrotMEGA65's `mega65.vhd` does.

## Build times and size

A build takes four to eight minutes on an Intel Core i9-10850K (10 cores,
20 threads) with Vivado 2025.1. These are the times of the last builds, in
minutes and seconds, without `ROM=`:

| Build | Synthesis | Placement | Routing | Bitstream | Total |
|---|---|---|---|---|---|
| R6, pipelined | 2:14 | 0:40 | 1:09 | 0:33 | 4:52 |
| R6, `NICE=multi` | 1:28 | 0:34 | 0:59 | 0:33 | 3:54 |
| Nexys4DDR, pipelined | 2:03 | 0:35 | 0:44 | 0:32 | 4:06 |
| Nexys4DDR, `NICE=multi` | 1:09 | 0:32 | 5:31 | 0:28 | 7:49 |

The R3 takes the same as the R6. The Nexys4DDR builds with `FLOW=timing`.
Its routing time varies most: an earlier pipelined build routed in 1:32,
and the time with `NICE=multi` is from one build only.

The utilisation is from `build/utilization.rpt`, and the split by module
from `report_utilization -hierarchical` on `build/top.dcp`. These are the
numbers without `ROM=`, at commit 671172e, in LUTs and flip-flops:

| Part of the design | R6, pipelined | R6, multi | Nexys4DDR, pipelined | Nexys4DDR, multi |
|---|---|---|---|---|
| The core (`nice_core`) | 6985 / 3002 | 4581 / 1044 | 7071 / 2943 | 4562 / 985 |
| The math unit (`mpu`) | 2178 / 874 | 2167 / 874 | 2112 / 874 | 2200 / 876 |
| The rest: the CLI, UART, RAM, counters, timer, and glue | 761 / 1123 | 767 / 1123 | 736 / 1107 | 709 / 1109 |
| The text display (`text.vhd`) | 105 / 153 | 105 / 153 | 103 / 144 | 99 / 144 |
| The keyboard | 596 / 585 | 596 / 585 | – | – |
| The HDMI output | 522 / 1199 | 522 / 1199 | – | – |
| Total | 11147 / 6936 | 8738 / 4978 | 10022 / 5068 | 7570 / 3114 |
| Total, of the FPGA | 8.3 % / 2.6 % | 6.5 % / 1.9 % | 15.8 % / 4.0 % | 11.9 % / 2.5 % |

The pipelined core is about 5 % of the LUTs of the R6's FPGA, and 11 % of
the Nexys4DDR's. The multi-cycle core has two thirds of its LUTs and a third
of its flip-flops: 3.4 % and 7.2 %. Both keep their registers in
flip-flops, and use no DSP. The pipelined core uses no block RAM. The
multi-cycle core uses one RAMB18, which Vivado infers for `src2_count`,
the register of the shift count. The math unit has the 4 DSPs of the design. Both cores meet the
clock: the R6 by 0.24 ns (pipelined) and 0.26 ns (multi) at 100 MHz, the
Nexys4DDR by 0.17 ns and 0.16 ns at 90 MHz. The R3 is within about 2 % of
the R6.

The block RAMs, of 36 Kbit, are these:

| Memory | MEGA65 | Nexys4DDR |
|---|---|---|
| The RAM (`i_ram`), 64K words | 64 | 64 |
| The ROM (`i_rom`), 32K words, with `ROM=` only | 32 | 32 |
| The screen (`i_scr` in `nicemon.vhd`), 32K or 8K words | 32 | 8 |
| Its copy in `text.vhd` (`scr_ram.vhd`) | 24 | 6 |
| The font in `text.vhd` | 4 | 4 |
| The UART's input FIFO (`rx_fifo.vhd`), one RAMB18 | 0.5 | 0.5 |
| Total without the ROM, pipelined | 124.5 of 365 | 82.5 of 135 |
| Total with the ROM, pipelined | 156.5 | 114.5 |

The copy of the screen keeps only the 24 bits that the display reads (bits
7–0, the character, and 31–16, the colours), so Vivado leaves out the rest,
and it takes three quarters of the screen's block RAMs. The multi-cycle
core adds half of one more, its RAMB18.
