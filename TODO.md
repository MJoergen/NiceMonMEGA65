# TODO

Work that is planned but not started.

## The Nexys4DDR

The Nexys4DDR build uses the UART and a USB keyboard for input, the UART
for output, and VGA for the screen, and LED0 shows that the core runs (see
[synth/README.md](synth/README.md#the-nexys4ddr)). The board has more that
could become I/O devices of the system, as registers in the I/O page:

- The 16 LEDs, and the two RGB LEDs.
- The eight-digit seven-segment display.
- The five buttons around the D-pad (the CPU RESET button already resets
  the system).
- The 16 switches.

Each needs a place in the address map that does not clash with the
emulator's devices, and a line in the table of `EMULATOR.md`, as the emulator has none of them. The keyboard's LEDs could be set
too, CAPS LOCK's above all, by sending the PS/2 command ED to the keyboard.

## The monitor

The monitor in NICE assembly, a port of QMON, is not written yet; the
decisions it follows are in [monitor/README.md](monitor/README.md). It also
needs a start-up variant in nice_cpu, `start*.nasm` with the origin
`0x8000`, the monitor's stack, and a return instead of a halt.
