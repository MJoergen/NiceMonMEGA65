# Compared with the emulator

The goal is a MEGA65 that runs NICE programs as `niceemu`, the emulator in
`nice_cpu/emulator`, runs them. **It is close, but not there yet.** The
core and nice_cpu's devices behave as in the emulator, and so does the
address map, apart from the size of the memory and the registers at
`0xFFFFFF80`–`9F`, where the emulator has memory. The debug link reads back
what the emulator prints after a halt.
`tools/run.py` runs a program on the board and prints what `niceemu` prints
for it, so the two can be compared (see
[Comparing with the emulator](README.md#comparing-with-the-emulator)). The main
difference is the memory: 64K words, not 2³².

nice_cpu's [SYSTEM.md §5](nice_cpu/doc/SYSTEM.md#5-systems-built-on-the-fpga-core)
lists what a board built on the FPGA core may do differently from the
emulator: the reserved words, the screen, the console input, the input FIFO,
the ROM, and the aliasing. The rows below that it covers are marked
"(SYSTEM.md §5)".

| Feature | Emulator | MEGA65 | Same? |
|---|---|---|---|
| Instruction set | ISA.md | nice_cpu's `pipeline.vhd` (or `multicycle.vhd` with `NICE=multi`), which nice_cpu's tests compare with the emulator | Yes |
| Console output, `0xFFFFFF00` | stdout | UART | Yes, but a write stalls the core while the previous byte is still going out, about 8.7k cycles at 115200 baud |
| Console input, `0xFFFFFF00` (SYSTEM.md §5) | stdin, with bit 8 set; `0x200` at the end. A read waits for the next byte | UART and the keyboard, with bit 8 set, through a 2048-byte FIFO; `0x200` after a UART break. A read returns 0 while no byte has arrived | Yes, but UART bytes beyond 2048 unread ones are lost, with the link's `o` notice, where `run.py` paces its input so that none is, and a program that waits for input in a loop runs more steps. Input that arrives while the core is held or has halted is dropped, as by `niceemu --link` |
| Math unit, `0xFFFFFF20`–`3F` | Computed on read | nice_cpu's `mpu.vhd`, which stalls the read until the result is ready | Yes |
| Performance counters, `0xFFFFFF40`–`4F` | One cycle and one microsecond per step, from the start | nice_cpu's `perf.vhd`, counting clock cycles and microseconds at 100 MHz (90 MHz on the Nexys4DDR), from the start of the core until it halts. A read of a low word by the link takes the snapshot, as one by the core does | Instructions yes; cycles and microseconds count real time, and stop at a halt. `niceemu --link` takes no snapshot at a read by the link ([nice_cpu#41](https://github.com/MJoergen/nice_cpu/issues/41)) |
| Timer, `0xFFFFFF10`–`1F` | Raises IRQ every P steps | nice_cpu's `timer.vhd`, raising IRQ every P clock cycles at 100 MHz (90 MHz on the Nexys4DDR) while the core runs | Yes, but the period counts real clocks, so the interrupts come at other steps |
| Fetch statistics, `0xFFFFFF50`–`7F` | Read 0, and a write is ignored | nice_cpu's `fetch_stats.vhd` (MICROARCH.md §8.1), which counts what FETCH and DECODE of the pipelined core do; with `NICE=multi` only `FS_CYCLES` and `FS_HIST[0]`, the cycles with no word in the buffer, count, `FS_CTRL` reads its run bit, and the other words read 0. A start clears them, and they count each clock while the core runs, until `FS_CTRL` is written 0 | Yes, but they count only on the board |
| Instruction fetches from `0xFFFFFF00`–`FF` | Read 0 | Read 0 | Yes |
| Memory (SYSTEM.md §5) | All 2³² words, 0 at the start | 64K words, repeated through the address space, so the words of `0xFFFFFF02`–`FF` that are not registers are the RAM words `0x0000FF02`–`FFFF`, and `0xFFFF8000`–`FEFF` the words `0x8000`–`FEFF` (`0xFFFF2000`–`FEFF` the words `0x2000`–`FEFF` on the Nexys4DDR); the stack at `0xFFFFFF00` lands in the top. `load.py` and `run.py` hide the ROM, if the bitstream has one, and clear the RAM to 0 before they load | No: a program, its data, and its stack must fit in 64K words |
| Screen, `0xFFFF0000`–`07CF` (SYSTEM.md §5) | 80×25 words of memory, printed by `--screen` | 32768 words of memory of their own (8192 on the Nexys4DDR), which the link reads in full, though `load.py` loads only the 8192 that both boards have; the first 2000 are shown on VGA and HDMI (VGA only on the Nexys4DDR), unless the display offset is set | Yes |
| Read counter, `0xFFFFFF01` | Counts the data reads since the last write, and a start keeps it | The same. The link reads it as 0 and does not write it (DEBUG.md §3), as does `niceemu --link` | Yes, but `run.py -d` shows 0 there |
| The rest of `0xFFFFFF02`–`FF` (SYSTEM.md §5) | Ordinary memory for data | Memory, in the top 256 words of the RAM, at `0xFFFFFF02`–`0F` and `A0`–`FF`. `10`–`7F` are the devices of the rows above, `80`–`8F` the screen's registers, and `90`–`9F` the board's devices. The link reads its debug registers at `E0`–`FF`, where the core has memory | Yes, but for `80`–`9F` |
| The Nexys4DDR's devices, `0xFFFFFF90`–`9F` | Ordinary memory | LEDs, RGB LEDs, seven-segment display, buttons, and switches on the Nexys4DDR (README, "The Nexys4DDR's devices"); on the MEGA65 they read 0 and take no write | No: the emulator has none of them, so a program that reads the buttons or switches reads data there, and one that waits for a button may never end |
| Interrupts | From the timer, `--irq`, and `--nmi` | From the timer, on IRQ | Yes, for the timer's |
| After a halt | Prints why, the steps, and the registers, and exits with a status | The link sends its `h` notice after the program's last byte. The halt reason at `0xFFFFFFF1` says why, the instruction counter the steps, `0xFFFFFFE0`–`EF` hold R0–R15, and the link reads memory. `run.py` prints them as the emulator does, with its exit status | Yes, but there is no `Pending:` line, as the link cannot read whether a timer request is pending |
| `--dump`, `--screen`, `--input` | Options | The same options of `run.py` | Yes, but `-d` shows other values for the cycle counter, the timer's COUNT, and the fetch statistics, as they count real clocks, and at `0xFFFFFF80`–`9F` it shows the registers, where the emulator has memory. It reads at most 65536 words |
| `--max-steps` | Stops after N steps, prints the registers, exits with 3; there is no limit without it | `--timeout SEC` of `run.py` stops after SEC seconds: it holds the core, prints the dumps, and exits with 3, but prints no registers, as a hold leaves them undefined (see [Comparing with the emulator](README.md#comparing-with-the-emulator)) | No |
| `-2004` | Puts the screen at `0x400`, for `--screen` | `run.py -2004 -s` prints the screen from `0x400`, which is plain RAM; the display shows `0xFFFF0000` | Yes |
| `--no-cycle-counter` | Option | Accepted by `run.py` and ignored | Yes |
| `--symbols` | Names where a halt other than `HALT` happened, a wasm trap, and where the step limit stopped the program | The same option of `run.py`, from R15, R1, and R2 after a halt; at the time limit there are no registers, so no location | Yes, but for the time limit |
| `--trace`, `--irq`, `--nmi` | Options | Not available | No |
| `--color`, `--invert-fg`, `--no-timer-irq` | Options | Not available | No |
| `-h` | Prints the usage | `run.py` prints its own | Yes |

So a program that fits in 64K words prints the same under `run.py`, which
paces its input. Typed by hand, its input must not fall more than 2048
bytes behind. The C example `examples/primes.c`
is one, except for the cycles that it prints.
