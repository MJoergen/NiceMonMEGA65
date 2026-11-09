# Documentation

The reference documents for NiceMonMEGA65. The [README](../README.md) in
the root is for users of the core files, and
[CONTRIBUTING.md](../CONTRIBUTING.md) is for those who change this
repository.

- [SYSTEM.md](SYSTEM.md) has the address map, the debug link and the words
  used for it, such as hold, pause, and step, the screen and the font, the
  keyboard, the ROM, the Nexys4DDR's devices, the UART's baud rate, the
  Ethernet station with the link over TCP and the port for frames, and the
  SD card slots.
- [PROGRAMMING.md](PROGRAMMING.md) has how to write and build programs, in
  NICE assembly and in C, the C library, and how a program uses the screen
  and the keyboard.
- [EMULATOR.md](EMULATOR.md) has the known differences between the board
  and the emulator, `niceemu`.
- [DEBUGGER.md](DEBUGGER.md) is the design note of the on-board debugger,
  mon.py's functions with the MEGA65's own keyboard and screen, of which
  stages 1 to 10 are written.
- [SDCARD.md](SDCARD.md) is the design of the storage on the SD cards,
  from the registers to BASIC's `SAVE` and `LOAD`. The controller, the
  slots, and the ROM's reading and writing of FAT32 cards are written;
  BASIC is not yet.
- [BASIC_SURVEY.md](BASIC_SURVEY.md) is the survey of the BASIC dialects
  behind the interpreter planned for the ROM.
- [CODING_STYLE.md](CODING_STYLE.md) is the style that the VHDL follows.
- [RELEASE.md](RELEASE.md) describes how a release is made.
- [RELEASE_NOTES.md](RELEASE_NOTES.md) lists the changes in each release,
  newest first.
