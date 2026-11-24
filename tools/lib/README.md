# The tools' libraries

`tools/lib/` holds the modules of the host tools that are not commands
of their own. The
commands in `tools/` import them as a package, as
`from lib.boardlink import ...` and `from lib import cli`, and
`nicemon.py` imports the module of a subcommand only when it runs. The
commands are described in [tools/README.md](../README.md).

| Module | What it does |
|---|---|
| `boardlink.py` | The debug link, which the other tools use: nice_cpu's `debugger/nicelink.py`, over TCP to `niceemu --link` and on the UART, with the board's own links over TCP to its Ethernet port and to `make cosim`. It puts nice_cpu's `debugger/` on the path, so the tools import it first. |
| `cli.py` | The messages, the exit codes, and the `--listen` option that the subcommands share. |
| `load.py` | `nicemon.py load`: loads a `.bin` file into cleared memory and starts it, or with `--hold` leaves the core held in reset. With `--monitor`, it runs a program at `0x8000` under the monitor in the ROM, and with `--bas` it types a BASIC program's text into the ROM's BASIC and runs it. With `--basic`, it puts an image of BASIC into BASIC's part of the ROM. |
| `run.py` | `nicemon.py run`: runs a program on the board and prints what `niceemu` prints, for diffing, also one under the monitor with `--monitor`, and a BASIC program's text with `--bas`. |
| `mon.py` | `nicemon.py mon`: an interactive shell on the link: memory, registers, pause, step, breakpoints, and the console. It is nice_cpu's `debugger/nicedbg.py` with the board's links. |
| `sdcard.py` | `nicemon.py sd`: lists, copies, writes, and deletes the files of the folder `NICE` on the board's SD card, and of the folders inside it by their paths, with no PC slot, makes the folder and those inside it, and formats a card as FAT32. `hwtest.py` reads the card with it. |
| `sdnbd.py` | `nicemon.py nbd`: serves the board's SD card as a block device over NBD, so that Linux mounts it as a folder, all of the card, for the file manager. |
| `flash.py` | `nicemon.py flash`: writes a bitstream into the Nexys4DDR's flash, or a core file into a slot of the MEGA65's, from which the board starts. |
| `tftpd.py` | `nicemon.py tftpd`: a TFTP server for BASIC's `LOAD` and `DIR`, which also lists the files of its folder for a name with `*` or `?`, and with `--write` for its `SAVE` and `BSAVE`. |
| `jtag.py` | The JTAG cable of the board's UART, and the check that the board is the one a bitstream or core file was built for, which `hwtest.py` and `flash.py` use. |
| `spiflash.py` | The MEGA65's flash through openFPGALoader's bridge, which `flash.py` uses to clear the protection of its sectors. It needs pyftdi. |
| `tcppeer.py` | A TCP peer of its own on `niceemu`'s frames, with a script for each port, and for each connection it opens to a port where the board listens, for `tcptest.py`, `weathertest.py`, and `basic/test/web.py`, the test of BASIC's `HTTP$`. |

The old names of the subcommands, `tools/load.py` and the others, are
stubs in `tools/` that call `nicemon.py` until V3.1 removes them
([#159](https://github.com/MJoergen/NiceMonMEGA65/issues/159)).
