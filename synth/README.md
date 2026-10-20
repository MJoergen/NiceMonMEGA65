# synth

The Vivado builds, in non-project mode, one directory per board. Both boards
have an XC7A200T (`xc7a200tfbg484-2`), a 100 MHz clock, and the debug UART
on the same pins. They differ in the reset button:

| Path | Board | Reset |
|---|---|---|
| [r3/](r3/) | MEGA65 R3 and R3A | The reset button, read by the MAX10 FPGA and sent to the FPGA over a serial link. |
| [r6/](r6/) | MEGA65 R6 | The reset button, wired to the FPGA. |

[common/](common/) holds what the boards share: the clock and reset (an MMCM
makes the 66.7 MHz system clock), the UART synchroniser, the keyboard (on the
same three pins on both boards; the MAX10 of the R3 is not involved), the
video output, and the constraints for timing and configuration. The pins
come from MiSTer2MEGA65, and those of the video from MandelbrotMEGA65.

The screen is shown on the VGA connector, through the video DAC, and on the
HDMI connector, at 1280×1024 and 60 Hz (see the main README). A second MMCM
(`common/video_clk.vhd`) makes the 108 MHz pixel clock and the 540 MHz clock
of the HDMI serialisers. The boards differ in the pins around the video,
which their `top.vhd` drive: the R6 has a power save input on the DAC, and
its HDMI level shifter is a PTN3363, where the R3 has a TPD12S016.

To build, with Vivado installed in `/opt/Xilinx/2025.1/Vivado` (or set
`VIVADO_DIR`):

    make -C synth/r6

The bitstream is `synth/r6/build/top.bit`, with timing and utilisation
reports next to it. Its core waits for the command line. With

    make -C synth/r6 ROM=/path/to/monitor.bin

the core boots at reset from a ROM of 32K words at address 0 with the words
of the `.bin` file (`src/rom.vhd`, through `G_ROM_FILE` of `top.vhd`), as
the main README describes under "The ROM". Vivado reads the file during
synthesis, so the bitstream is rebuilt when it changes. `make r6
ROM=monitor.bin` in the top directory does the same with a path relative
to it.

The user LED is on while the core runs.

`r3/max10.vhd` drives the link to the MAX10. It is copied unchanged from
[MandelbrotMEGA65](https://github.com/MJoergen/MandelbrotMEGA65)
(`src/max10/max10.vhd`, commit a3fafd4), which took it from the
[MEGA65 core](https://github.com/MEGA65/mega65-core) by Paul
Gardner-Stephen, via C64MEGA65. It is GPL v3, unlike the rest of this
repository.

`common/hdmi/` is the HDMI output of MandelbrotMEGA65 (`src/hdmi/`, commit
a3fafd4), copied unchanged: The Tyto Project by Adam Barnes, via C64MEGA65,
LGPL v3. `common/mega65.vhd` drives it, the video DAC, and the clocks as
MandelbrotMEGA65's `mega65.vhd` does.
