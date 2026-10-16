# monitor

The monitor is not in NICE assembly on the board, as QMON of
[QNICE-FPGA](https://github.com/sy2002/QNICE-FPGA) is. It is on the host,
in [`tools/nicemon.py`](../tools/nicemon.py), and the board has only the
debug link of [PROTOCOL.md](../PROTOCOL.md) in hardware. This directory
holds only this note, which says why.

- The board answers a few binary requests: read and write memory, and the
  debug registers, which pause, step, and stop the core, and read its trace.
  That is `src/link.vhd` and `src/run_ctl.vhd`. Everything that a person
  sees, such as the prompt, hex dumps, and the disassembler, is Python on
  the host, which is far easier to write and change than assembly in a ROM.
- The link needs nothing of the core: no ROM, no RAM, and no registers of
  the program. So it works after a program has crashed or overwritten its
  memory, and it can read memory while the program runs.
- The core's console shares the UART with the link: the byte `0xFF` starts
  a packet, and `0xFF 0xFF` is a console byte `0xFF`. So the UART does not
  change hands when a program starts or halts.
- Breakpoints, watchpoints, single steps, and a trace of the last 1024 steps
  are in hardware, from the core's report of each step (`retire_o`), which
  QMON could not have.

The ROM at `0x0000`–`0x7FFF` stays, for a program that the core should boot
from at reset. nice_cpu's ISA.md §9 and `runtime/start_mon.nasm` describe
programs at `0x8000` that return to a monitor in the ROM instead of
halting. They need such a monitor, which this repository no longer plans;
programs for the debug link start at 0 and halt.

The cost is that a terminal alone no longer gives a prompt: the monitor
needs the host tool, and Python 3.
