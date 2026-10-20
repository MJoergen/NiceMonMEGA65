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
  take 16. That is still more than three screens of 80×25 for scrolling.
- Its FPGA is speed grade -1, where the MEGA65's is -2, so the system clock
  is 75 MHz, not 100 MHz; at 80 MHz the pipelined core misses timing by
  0.2 ns. The UART runs at 115200 baud as on the MEGA65.
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
