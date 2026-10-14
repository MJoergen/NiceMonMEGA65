# NiceMonMEGA65
The NICE CPU with a monitor, on the MEGA65

This project runs the [NICE CPU](https://github.com/MJoergen/nice_cpu) on the
MEGA65 board (R3 and R6), with a monitor like the one in
[QNICE-FPGA](https://github.com/sy2002/QNICE-FPGA) and a command line
interpreter on the UART like the one in
[cmod-s7](https://github.com/MJoergen/cmod-s7).

## Contents

| Path | What it is |
|---|---|
| [nice_cpu/](https://github.com/MJoergen/nice_cpu) | The NICE CPU, its assembler, and its emulator, as a git submodule. |
| [src/](src/README.md) | The synthesisable VHDL, shared by both boards. |
| [sim/](sim/) | The GHDL testbenches. |
| [synth/](synth/README.md) | The Vivado builds for the R3 and R6 boards. |
| [monitor/](monitor/README.md) | The monitor, in NICE assembly. |

## Getting started

Clone with the submodule:

    git clone --recurse-submodules https://github.com/MJoergen/NiceMonMEGA65.git

or, in an existing clone:

    git submodule update --init

## Running the tests

You need GHDL (tested with 4.1.0) and Python 3.

    make -C sim test

The testbench `sim/tb_hello.vhd` runs a "Hello" program on the NICE core
from the submodule, and checks its console output.
