# TODO

Work that is planned but not started.

## The Nexys4DDR

The keyboard's LEDs, CAPS LOCK's above all, are not set. They could be a
register at `0xFFFFFF97`, with bit 0 for scroll lock, bit 1 for num lock, and
bit 2 for caps lock, sent by the PS/2 command `ED`. That needs a transmitter
in `src/kbd_ps2.vhd`, which only listens now, and an acknowledge from the
keyboard (`FA`), which the receiver must not pass on as a key. The LEDs,
the display, the buttons, and the switches are done (README, "The Nexys4DDR's
devices").

## The monitor

The monitor in NICE assembly, a port of QMON, is not written yet; the
decisions it follows are in [monitor/README.md](monitor/README.md). It also
needs a start-up variant in nice_cpu, `start*.nasm` with the origin
`0x8000`, the monitor's stack, and a return instead of a halt.
