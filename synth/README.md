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
108 MHz pixel clock and the 540 MHz clock of the HDMI serializers).
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
screen is on its VGA connector, and LED0 is on while the core runs, or
while the program sets it. A USB
keyboard in the USB HID port types into the console too: the board's PIC24
turns it into PS/2, which `src/kbd_ps2.vhd` receives and
`src/kbd_ps2_ascii.vhd` turns into ASCII. The receiver only listens, so
the keyboard's LEDs are not set. The board's 16 LEDs, two RGB LEDs,
seven-segment display, five buttons, and 16 switches are registers in
`0xFFFFFF90`–`96` (see the main README, "The Nexys4DDR's devices").
`src/seg7.vhd` scans the display, and `src/rgb_pwm.vhd` dims the RGB LEDs
with 16 levels; both drive registered outputs in the IOBs. The CPU RESET
button resets the system. The board differs from the MEGA65 in
three ways:

- Its FPGA has 135 block RAMs of 36 Kbit, where the MEGA65's has 365. The
  RAM and the ROM are the same as on the MEGA65, and take 96 of them, but
  the screen is 8K words, not 32K, so that it and its copy in `text.vhd`
  take 16, not 64. With the font and the UART's FIFO, that is 116.5 with
  the ROM. 8K words are still more than three screens of 80×25 for
  scrolling.
- Its FPGA is speed grade -1, where the MEGA65's is -2, so the system clock
  is 90 MHz, not 100 MHz; at 100 MHz the pipelined core misses timing by a
  few tenths of a nanosecond or less, as placement varies. The UART runs at 115200 baud as on the MEGA65.
- Its VGA output has 4 bits per color, from resistors, and there is no
  HDMI. The screen's colors have 4 bits per color, so they show
  as on the MEGA65.

## Building

To build, with Vivado installed in `/opt/Xilinx/2025.1/Vivado` (or set
`VIVADO_DIR`):

    make -C synth/r6

or `make r6` in the top directory, and likewise for `r3` and `nexys4ddr`.
The bitstream is `synth/r6/build/top.bit`, with timing and utilization
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
| R6, pipelined | 3:14 | 0:39 | 2:45 | 0:50 | 7:54 |
| R6, `NICE=multi` | 1:29 | 0:28 | 1:06 | 0:32 | 3:55 |
| Nexys4DDR, pipelined | 6:46 | 3:46 | 2:53 | 0:52 | 14:17 |
| Nexys4DDR, `NICE=multi` | 1:53 | 0:31 | 1:15 | 0:28 | 4:18 |
| R3, pipelined | 3:11 | 0:36 | 1:08 | 0:35 | 5:49 |

The Nexys4DDR builds with `FLOW=timing`. The last Nexys4DDR pipelined
build ran while the machine was busy with other work, so its times are much
longer than the earlier 5:24. The times vary from build to build: one R6 pipelined build spent 9:36 in synthesis, with the same result,
and took 12:49 in all.

The utilization is from `build/utilization.rpt`, and the split by module
from `report_utilization -hierarchical` on `build/top.dcp`. These are the
numbers without `ROM=`, in LUTs and flip-flops. The pipelined columns are
from the builds of 2026-10-23 at nice_cpu 4cd869e, and the multi-cycle
columns are from the build at cb95968. The two pipelined totals are from
the builds with the Nexys4DDR's devices (below); the rows above them are
from before, so they do not add up to the totals:

| Part of the design | R6, pipelined | R6, multi | Nexys4DDR, pipelined | Nexys4DDR, multi |
|---|---|---|---|---|
| The core (`nice_core`) | 7353 / 3009 | 4605 / 1050 | 7358 / 2952 | 4636 / 4071 |
| The math unit (`mpu`) | 2164 / 874 | 2172 / 874 | 2176 / 874 | 2166 / 874 |
| The fetch statistics (`fetch_stats`) | 730 / 1329 | 44 / 99 | 731 / 1329 | 44 / 99 |
| The rest: the CLI, UART, RAM, counters, timer, and glue | 683 / 1118 | 795 / 1156 | 699 / 1092 | 740 / 1119 |
| The text display (`text.vhd`) | 123 / 180 | 123 / 180 | 121 / 156 | 121 / 156 |
| The keyboard | 592 / 577 | 596 / 585 | 106 / 48 | – |
| The HDMI output | 575 / 1207 | 574 / 1207 | – | – |
| Total | 12272 / 8330 | 8909 / 5151 | 11167 / 6651 | 7707 / 6319 |
| Total, of the FPGA | 9.2 % / 3.1 % | 6.7 % / 1.9 % | 17.6 % / 5.2 % | 12.2 % / 5.0 % |

The pipelined core is about 5.5 % of the LUTs of the R6's FPGA, and 11.6 % of
the Nexys4DDR's. The multi-cycle core has two thirds of its LUTs, 3.4 % and
7.3 %. On the R6 it has a third of the flip-flops too. On the Nexys4DDR it
has 4071, more than the pipelined core's 2949, where the build at 671172e
had 985. The cause is the retiming of `FLOW=timing` (`synth_design
-retiming`): it moved registers backwards 597 times and added 6791, mostly
copies of the core's register file and state, so the design has twice the
flip-flops (6319 against 3114). The build at 671172e did not retime this
way, and the one at cb95968, which maps `fetch_stats` and the wider device
address, did; the multi-cycle core itself is the same in both. With
`FLOW=default` the build has 3202 flip-flops but misses 90 MHz by 0.37 ns,
so the copies buy timing. With the retiming it meets 90 MHz by 0.19 ns, and
the Nexys4DDR has room for the flip-flops.

The `fetch_stats` of the pipelined core (the fetch statistics in the main
README's address map) has over a thousand flip-flops, and the multi-cycle
core's has few. The pipelined core uses no block RAM. The multi-cycle core
uses one RAMB18, which Vivado infers for `src2_count`, the register of the
shift count. The math unit has the 4 DSPs of the design. All builds meet the
clock, with these worst setup slacks: the R6 0.52 ns (multi) at 100 MHz, the
R3 0.21 ns (pipelined), the Nexys4DDR 0.19 ns (multi) at 90 MHz. The
pipelined builds of 2026-10-23 at nice_cpu 4cd869e have 0.174 ns on the R6
(default flow, 100 MHz) and 0.043 ns on the Nexys4DDR (timing flow, 90 MHz),
with hold slacks of 0.041 ns and 0.030 ns. Their block RAM is 132.5 tiles
on the R6 (36 %) and 84.5 on the Nexys4DDR (63 %), and both use 4 DSPs.
The builds that added the Nexys4DDR's devices at `0xFFFFFF90`–`96` have 0.149 ns
on the R6 and 0.203 ns on the Nexys4DDR, with hold slacks of 0.069 ns and
0.043 ns. The slacks change from build to build with placement, not with the
logic. This nice_cpu update changed no core RTL, only its formal checks and
documentation, so the figures are those of the same logic. The
pipelined core's slacks are from the builds at 929534c, which gates the
core's requests with `core_take`: the R6 0.11 ns and the Nexys4DDR 0.02 ns
(0.23 ns and 0.32 ns before). The R3 (0.22 ns) and the Nexys4DDR (0.05 ns)
were rebuilt after the reset button and the MAX10 pins went into the IOBs;
the Nexys4DDR's worst path is in the core's WRITE stage, which that change
does not touch, so the 0.03 ns it gained over the earlier build is most likely
placement noise.

The block RAMs, of 36 Kbit, are these:

| Memory | MEGA65 | Nexys4DDR |
|---|---|---|
| The RAM (`i_ram`), 64K words | 64 | 64 |
| The ROM (`i_rom`), 32K words, with `ROM=` only | 32 | 32 |
| The screen (`i_scr` in `nicemon.vhd`), 32K or 8K words | 32 | 8 |
| Its copy in `text.vhd` (`scr_ram.vhd`) | 32 | 8 |
| The font in `text.vhd` | 4 | 4 |
| The UART's input FIFO (`rx_fifo.vhd`), one RAMB18 | 0.5 | 0.5 |
| Total without the ROM, pipelined | 132.5 of 365 | 84.5 of 135 |
| Total with the ROM, pipelined | 164.5 | 116.5 |

The copy of the screen keeps all 32 bits, as the display reads the
character and both 12-bit colors, so it takes as many block RAMs as the
screen. The multi-cycle core adds half of one more, its RAMB18.
