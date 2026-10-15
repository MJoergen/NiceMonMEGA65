# synth

The Vivado builds, in non-project mode, one directory per board. Both boards
have an XC7A200T (`xc7a200tfbg484-2`), a 100 MHz clock, and the debug UART
on the same pins. They differ in the reset button:

| Path | Board | Reset |
|---|---|---|
| [r3/](r3/) | MEGA65 R3 and R3A | The reset button, read by the MAX10 FPGA and sent to the FPGA over a serial link. |
| [r6/](r6/) | MEGA65 R6 | The reset button, wired to the FPGA. |

[common/](common/) holds what the boards share: the clock and reset (an MMCM
makes the 50 MHz system clock), the UART synchroniser, the keyboard (on the
same three pins on both boards; the MAX10 of the R3 is not involved), and the constraints
for timing and configuration. The pins come from MiSTer2MEGA65.

To build, with Vivado installed in `/opt/Xilinx/2025.1/Vivado` (or set
`VIVADO_DIR`):

    make -C synth/r6

The bitstream is `synth/r6/build/top.bit`, with timing and utilisation
reports next to it.

The user LED is on while the core runs.

`r3/max10.vhd` drives the link to the MAX10. It is copied unchanged from
[MandelbrotMEGA65](https://github.com/MJoergen/MandelbrotMEGA65)
(`src/max10/max10.vhd`, commit a3fafd4), which took it from the
[MEGA65 core](https://github.com/MEGA65/mega65-core) by Paul
Gardner-Stephen, via C64MEGA65. It is GPL v3, unlike the rest of this
repository.
