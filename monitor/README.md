# monitor

The monitor in NICE assembly, a port of the QNICE monitor (QMON) from
[QNICE-FPGA](https://github.com/sy2002/QNICE-FPGA), is planned and not
written yet. This directory holds only this note.

When it is written, it will be assembled with `nice_cpu/assembler/niceasm.py`
into a `.bin` file that the memory is loaded with at configuration time, so
that the core boots into it: `src/ram.vhd` takes such a file through
`G_INIT_FILE`, and `G_CPU_RUN_AT_RESET` of `src/nicemon.vhd` lets the core
start at reset instead of waiting for the command line. Neither is wired to
the board builds in `synth/` yet. Until then, programs are loaded through
the command line, as the [main README](../README.md) describes.
