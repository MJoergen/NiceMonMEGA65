# The builds' history

How the builds' timing and size got where they are, from the records
that [README.md](README.md#build-times-and-size) kept as the design grew.
The numbers that are true now are in the README. Setup and hold are the
worst slacks of `build/timing.rpt`, in ns. A negative setup slack misses
the clock.

## The releases

`make bump` builds the R6 without a ROM and records the result in
`verified.json`, which the badge shows. These are its records, in the
default flow at 100 MHz:

| Release | Date | Setup | Hold |
|---|---|---|---|
| RC06 | 2026-10-27 | 0.376 | 0.054 |
| V1.0 | 2026-10-27 | 0.376 | 0.054 |
| V1.1 | 2026-10-29 | 0.086 | 0.012 |
| V1.2 | 2026-10-31 | 0.328 | 0.056 |
| V1.3 | 2026-11-03 | 0.138 | 0.021 |
| V1.4 | 2026-11-04 | 0.138 | 0.021 |
| V1.5 | 2026-11-05 | 0.063 | 0.032 |
| V1.6 | 2026-11-06 | 0.138 | 0.076 |
| V1.7 | 2026-11-06 | 0.019 | 0.044 |
| V1.9 | 2026-11-08 | 0.062 | 0.042 |

From V1.9 on, `verified.json` has the Nexys4DDR too, at 90 MHz: it
missed by 0.27 ns in the default flow and met by 0.033 ns with
`FLOW=timing`. V1.8 has no release here: nice_cpu V1.8 left the R6 short
of 100 MHz in both flows, by 0.210 ns in the default flow and 0.135 ns
with `FLOW=timing`, on a path from the RAM into WRITE's register file
(nice_cpu#141). nice_cpu V1.9 fixed it.

## The builds after each change

Most of these are builds of the pipelined core without a ROM. A ROM adds
32 block RAMs on each board, which moves the placement, so from #71 on
the R6's builds are with the ROM, as the release ships it. A dash is a
board that was not built then.

| Date | Change | R6 | Nexys4DDR |
|---|---|---|---|
| 2026-10-29 | nice_cpu V1.1, debug link 5, with the Ethernet station | 0.086 / 0.012 | 0.289 / 0.029, with stage 1 of the debugger |
| 2026-10-30 | Stage 1 of the on-board debugger, the overlay and the toggle | 0.114 / 0.042 | – |
| 2026-10-30 | Stage 3, the debugger drives the link | 0.080 / 0.038 | 0.339 / 0.031 |
| 2026-10-30 | Stage 5, the page of memory | 0.232 / 0.053 | 0.111 / 0.017 |
| 2026-10-30 | Stage 6, the breakpoints | 0.169 / 0.032 | 0.139 / 0.022 |
| 2026-10-30 | Stage 7, the Nexys4DDR's buttons and display | 0.330 / 0.063 | 0.159 / 0.034 |
| 2026-10-30 | Stage 8, the decode of row 27 | 0.410 / 0.047 | 0.187 / 0.019 |
| 2026-10-31 | Stage 9, the debugger on the link's side port | 0.328 / 0.056 | 0.166 / 0.025 |
| 2026-11-02 | The MEGA65's RAM of 128K words (#68) | 0.177 / 0.031 | 0.053 / 0.030 |
| 2026-11-02 | The Nexys4DDR's memories kept in block RAM (#70) | the same | 0.020 / 0.007 |
| 2026-11-03 | nice_cpu V1.3, debug link 6, and the hold-back over Ethernet (#69) | 0.042 / 0.057 | 0.047 / 0.025 |
| 2026-11-05 | The fonts of nice_cpu V1.6 (#71), with the ROM | −0.124 in the default flow; 0.128 / 0.031 with `FLOW=timing` | 0.054 / 0.025 |
| 2026-11-06 | The settings page (#75), with the ROM and `FLOW=timing` | −0.198 placed with `ExtraTimingOpt`; 0.015 with `AltSpreadLogic_high` | – |
| 2026-11-07 | The port for Ethernet frames (#82), with the ROM and `FLOW=timing` | 0.086 / 0.058 | – |
| 2026-11-09 | nice_cpu V2.0, debug link 7, with the ROM | −0.993 in the default flow; 0.075 with `FLOW=timing` | – |
| 2026-11-09 | The wait and the hidden state on the link (#93, #98), and the strip's wait, with the ROM and `FLOW=timing` | 0.047 | – |
| 2026-11-09 | The byte windows (#90), with the ROM and `FLOW=timing`: −0.258 with the byte or halfword taken from the RAM's word on the way to the core; 0.032 with it a cycle later | 0.032 / 0.031 | – |

The R3's first record is from a build at nice_cpu V1.0, with debug link
4 and the Ethernet station: 0.109 ns and 0.061 ns.

The sizes, from the same builds:

- **Stage 3.** The debugger takes 730 LUTs and 1051 flip-flops, 293 and
  286 of them in its host of the link (`dbg_host`), and half a block
  RAM, for the table of its strip's cells. The R6 has 139.5 block RAMs,
  and the Nexys4DDR 92.5, until #68.
- **Stage 8.** The decode takes about 530 LUTs. Its table of decimal
  digits is kept out of a block RAM with `rom_style`.
- **Stage 9.** The debugger takes 1878 LUTs and 1885 flip-flops, 170 and
  119 of them in its adapter to the side port (`dbg_host`), which
  replaced the host of the link. The link itself takes 977 and 1118.
- **#68.** The R6 has 235.5 block RAMs and 18712 LUTs. The Nexys4DDR,
  whose RAM stays 64K words, has 110.5 block RAMs and 28964 LUTs.
- **#70.** The Nexys4DDR has 123 block RAMs and 17878 LUTs.
- **V1.3.** The R6 has 19905 LUTs, and the Nexys4DDR 19068.
- **#71.** The R6 has 241.5 block RAMs, and the Nexys4DDR 127 and 19951
  LUTs.
- **#82.** The R6 has 245 block RAMs and 22549 LUTs. The station's buffer
  of a frame received is a RAMB18.

## What the builds taught

- **Vivado may put a memory into LUTs though block RAM is free.** After
  #68, Vivado 2025.1 put the Nexys4DDR's screen of `mem.vhd`, its font,
  and the UART's FIFO into LUTs, 8192 of them for the screen alone, in
  every flow (#70). `ram_style` and `rom_style` attributes on the three
  keep them in block RAM, as on the MEGA65.
- **The worst path is most often from the RAM into WRITE.** The core's
  WRITE stage takes the data bus's read data into its register file.
  The farther a block RAM of the RAM is placed, the less slack that path
  has. That is the path of V1.3, #71, #75, #82, V1.8, and V1.9. The
  Nexys4DDR's worst path at V1.3 was from DBUS to the timer instead.
- **A read of the fonts takes a cycle more than one of the RAM** (#71),
  so that the fonts' word is not on that path, and the stalls of the
  data bus stay single registers.
- **The R6 places with `AltSpreadLogic_high` in the timing flow.** With
  #75, `ExtraTimingOpt` missed 100 MHz by 0.198 ns on the path from the
  RAM into WRITE, and `AltSpreadLogic_high` met it by 0.015 ns. It is
  the `PLACE_TIMING` of `synth/r6/Makefile` since then.
- **With the ROM, the R6 sometimes needs `FLOW=timing`.** Since #71,
  the ROM's 32 block RAMs push the RAM's farther, and some builds with
  the ROM missed in the default flow and met with `FLOW=timing`. So
  `make release` tries the default flow first, then `FLOW=timing`.
- **Placement moves the slack more than the logic does.** Stage 8 added
  530 LUTs and gained 0.08 ns on the R6. The rows of a split by module
  move too: in the builds with the TCP server, about 700 LUTs moved
  from the core's rows to the rest of `nicemon`, as Vivado optimizes
  across the modules' boundaries.

## The utilization at V1.1

The R6's pipelined column is from the build of the V1.1 bump, and the
Nexys4DDR's from one at nice_cpu V1.0, both with the Ethernet station and
without a ROM, in LUTs and flip-flops. The multi-cycle columns are
older, from builds that had a command line in place of the link,
counted in the rest, and neither the Nexys4DDR's devices nor the
microsecond counter.

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

The R3's pipelined build then took 15774 LUTs and 11166 flip-flops,
11.8 % and 4.2 % of the FPGA.

The Nexys4DDR's multi-cycle core had 4071 flip-flops, more than the
pipelined core's 3027, because `FLOW=timing` retimes
(`synth_design -retiming`): it moves registers backwards and adds copies
of the core's register file and state. With `FLOW=default` that build
had 3202 flip-flops, but missed 90 MHz by 0.37 ns; with the retiming it
met it by 0.19 ns.

The build times then, without a ROM, in minutes and seconds:

| Build | Synthesis | Placement | Routing | Bitstream | Total |
|---|---|---|---|---|---|
| R6, pipelined | 3:06 | 0:42 | 1:19 | 0:34 | 6:05 |
| R6, `NICE=multi` | 1:29 | 0:28 | 1:06 | 0:32 | 3:55 |
| Nexys4DDR, pipelined | 3:06 | 0:55 | 1:03 | 0:29 | 5:49 |
| Nexys4DDR, `NICE=multi` | 1:53 | 0:31 | 1:15 | 0:28 | 4:18 |
| R3, pipelined | 3:10 | 0:46 | 1:10 | 0:36 | 6:05 |
