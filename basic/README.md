# BASIC

The BASIC of the ROM, whose `READY.` the boards show at power-up. Its
statements are in [monitor/README.md](../monitor/README.md), and its
design, with the stages to come, in [doc/BASIC.md](../doc/BASIC.md).

BASIC is an image of its own in the ROM, at `0x4000`, assembled apart
from the monitor's at `0x0000` (#152). It calls the monitor through the
entries of the dispatch table alone, as a program at `0x8000` does, so
everything that BASIC does, a program can do too. The monitor knows of
BASIC only its two vectors, at `0x4000`, the cold start, and `0x4002`,
the warm start, after a program. BASIC's variables are its own 2K words
at `0xFFFFE800`, below the monitor's, and the stack starts below them.

## Building

`make -C basic` builds BASIC's image, `build/basic_image.bin`, and
`make rom` at the top joins it with the monitor's into the ROM,
`build/rom.bin` ([rom.mk](../rom.mk)). The image is the cat of
`basic.nasm`, `basic_cmd.nasm`, `basic_net.nasm`, `basic_time.nasm`,
and `basic_dis.nasm`, BASIC's copies of the monitor's `common.nasm`,
`monlib.nasm`, and `mon.nasm`, the version, and the texts with the
card's folder. `basic.nasm`'s header says what each file has, and
[monitor/INTERNALS.md](../monitor/INTERNALS.md#the-roms-words) has the
words of each.

## Testing

`make -C basic test` runs the tests of BASIC's statements in `niceemu`,
with no board, on the ROM of the tests, `../build/rom_test.bin`, which
has the version `V9.9`. The tests of the monitor's code are those of
`make -C monitor test` ([monitor/INTERNALS.md](../monitor/INTERNALS.md#the-tests)),
which builds what these share with them: `hello.bin`, the cards'
images, and the scripts of `monitor/test`. The test needs `FOLDER=NICE`,
the default. It runs these steps in order:

1. **The layout.** nice_cpu's `nicefmt` checks the sources and
   `test/dis.nasm`.
2. **The disassembler.** `test/dis.py` runs `DIS` over `test/dis.nasm`,
   which has every opcode, operand mode, condition, and modifier, the
   control instructions, the reserved words, and each pseudo-instruction
   with its near-misses. It compares each row with the text of
   `nicedis.py`, rewritten by the rules of monitor/README.md, "The
   disassembler", for a pseudo-instruction. It assembles each row again
   and compares the words.
3. **NTP.** `test/ntp.py` types `NTP` and `DHCP` with `--step-time`,
   and learns the frames of each run as the monitor's `test/dns.py`
   does, with the frames of DHCP and DNS of the monitor's
   `test/dhcp.py` and `test/dns.py`. DHCP gives the DNS server and an
   NTP server in option 42. It covers no IP address, DHCP's server, a
   server by name and by address, an offset east and west, a time of
   era 1, datagrams that are passed over, a kiss-o'-death, a leap
   indicator of 3, a stratum of 16, a time before 1970, no answer, an
   answer to the second send, no such name, and offsets that are not.
   It covers the edges of the eras too: the last second of era 0
   before 1970, and the last second of era 1 that the clock takes, and
   the next; the largest offsets east and west, and a clock 0 s off.
   It compares the output and the frames sent with `test/ntp.expected`,
   with a query's port as `pp` and its transmit timestamp as `tt`. It
   runs on an I2C master that is present and never busy, as the
   monitor's `test/rtc.py` has it, and checks that `NTP` writes the
   real-time clock: the master's last command is the cold start's read
   while no time is set, and the write of the chip's status after the
   times of the run.
4. **TFTP.** `test/tftp.py` runs `LOAD` and `DIR` from a TFTP server
   the same way, against `test/tftp.expected`. It covers a file of two
   blocks among packets of other hosts and ports, lost packets, an
   ERROR, an ERROR after the first block, whose summary comes first,
   files of 512 and 0 bytes, a listing, a port given as `"IP:PORT"`,
   bad arguments, and no answer to ARP.
5. **The runs.** The ROM runs once for each test below, with its
   keystrokes from an input file that ends with `HALT`, so that the run
   halts. Each run's console output, a few memory words, and the screen
   are compared with `test/NAME.expected`:

| Test | What runs | What it checks |
|---|---|---|
| `cmds` | The ROM alone | Every statement, its bad arguments, keywords in either case, numbers that do not fit, and the edits of a line. |
| `basic` | The ROM alone, with no card and no IP address | The scanner of a line: keywords glued to a letter or a digit, the HELP lines of each statement's Syntax error, numbers at their limits, `0x` without digits and a number that fails before a string, which are no numbers, strings without a closing quote, too few or too many arguments, and the 0s and the `.BIN` that the scanner writes into the line. |
| `load` | The ROM, with 128K words of RAM, as on the MEGA65 | `LOAD` with the monitor's `build/hello.bin` pasted: CR LF and LF line ends, tabs, blank lines, skipped lines, a line too long, blanks after a line's 76 characters, a DEL that takes back the key after them, an address given twice, and CTRL-C. Then `SYS 0x8000` runs it. |
| `load_64k` | The ROM, with 64K words, as on the Nexys4DDR | `LOAD` at the end of that RAM. |
| `load_emu` | The ROM, with `0xFFFFFF9E` reading 0, as in `niceemu` | `LOAD` up to the screen. |
| `time` | The ROM, with `--step-time` and a copy of the card without partitions | `TIME` not set, set, and shown; dates that are not, such as leap days of years without one, fields of one digit, month 0, day 0, letters, wrong separators, and 2106, and the clock left alone after them; the edges that are, 2000-02-29, 2100-03-01, 2104-02-29, 2^31 seconds, 2105-12-31, the last day of a leap year, and blanks in the quotes; and the dates of `SAVE`, from the clock and while it is not set or before 1980, which `mdir` shows. |

`time` runs with `--step-time`, so that the clock starts at 0, not
set, and counts the same each time, and the files that it writes while
the clock is not set have the fixed date, 2026-01-01 at 00:00:00. It
writes to a fresh copy of the monitor's `super.img`, and its output ends
with what the card holds that the image did not, from the monitor's
`test/fat_tool.py diff`, with the times as `**`, as the clock's seconds
count steps, and the order of the sector writes, from a second run with
`-t` and `test/fat_tool.py order`.

The comments above each input in the Makefile say what each keystroke
tests. The expected files were checked by hand: after a change that
alters an expected output, check the new output the same way before you
copy it from `build/` to `test/`. `cmds` shows the addresses of the
dispatch table, which change with the monitor's code.
