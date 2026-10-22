---
paths:
  - "synth/**"
---

# The Vivado builds

- Vivado 2025.1 is at `/opt/Xilinx/2025.1/Vivado` (`VIVADO_DIR` in
  `synth/Makefile.inc`); it is not on PATH. A build is `make r6`, `make r3`,
  or `make nexys4ddr` in the top directory, with `ROM=file.bin` for a ROM
  and `NICE=multi` for the multi-cycle core. `FLOW=timing` uses the
  directives for timing; the Nexys4DDR's Makefile sets it, and the MEGA65
  builds use Vivado's defaults. Each board's bitstream is `build/top.bit`
  in its directory whichever core is built, so build one core at a time.
- After a build, check `build/timing.rpt` for WNS. The pipelined core meets
  100 MHz on the MEGA65 by a few tenths of a nanosecond, and 90 MHz on the
  Nexys4DDR's -1 part; a nice_cpu change can take that margin away. The
  worst paths are usually in nice_cpu's WRITE and FETCH stages, so a fix
  belongs there, not here.
- `synth/README.md` records the build times, the utilisation, and the slack
  of each board; update it with a build that changes them.
- A dual-clock memory must be an entity of its own (`src/video/scr_ram.vhd`
  is the model); grep `build/vivado.log` for `Synth 8-6849` after changing
  one.
- Every registered pin has `IOB TRUE` in the board's XDC, with a plain
  register in front of the pin and no logic between them. A register that
  also feeds internal logic is replicated with a warning; drive the logic
  from the source signal instead.
- `synth/r3/max10.vhd` and `synth/mega65/hdmi/` are third-party copies
  (MandelbrotMEGA65 has the originals): leave them unchanged and unlinted.
- Vivado rewrites `tight_setup_hold_pins.txt` and `.Xil/` in the board's
  directory; `.gitignore` lists them, and they should not be committed.
