# TODO

Work that is planned but not started.

## The Nexys4DDR

The Nexys4DDR build uses the UART for input and output and VGA for the
screen, and LED0 shows that the core runs (see
[synth/README.md](synth/README.md#the-nexys4ddr)). The board has more that
could become I/O devices of the system, as registers in the I/O page:

- The 16 LEDs, and the two RGB LEDs.
- The eight-digit seven-segment display.
- The five buttons around the D-pad (the CPU RESET button already resets
  the system).
- The 16 switches.

Each needs a place in the address map that does not clash with the
emulator's devices, and a line in the README's "Compared with the emulator"
table, as the emulator has none of them. The board's keyboard input (USB,
seen by the FPGA as PS/2) is left out on purpose: the UART is the console.
