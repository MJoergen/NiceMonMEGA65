# The top-level Makefile. It runs the Makefiles of the subdirectories.
# "make" lists the targets.

PYTHON ?= python3
PORT   ?= /dev/ttyUSB1

.PHONY: help test lint examples r3 r6 mon load run hwtest cosim clean

help:
	@echo "Targets:"
	@echo "  make test       run the GHDL simulation tests (needs GHDL), and the"
	@echo "                  disassembler's test"
	@echo "  make lint       check the VHDL against CODING_STYLE.md (needs vsg)"
	@echo "  make examples   build the C examples to examples/build/*.bin (needs clang)"
	@echo "  make r3 [ROM=prog.bin]"
	@echo "                  build the bitstream for the MEGA65 R3 (needs Vivado)"
	@echo "  make r6 [ROM=prog.bin]"
	@echo "                  build the bitstream for the MEGA65 R6; with ROM, the"
	@echo "                  core boots from the .bin file at reset"
	@echo "  make mon [FILE=prog.bin] [PORT=/dev/ttyUSB1]"
	@echo "                  start the monitor, tools/nicemon.py, on the MEGA65"
	@echo "  make load FILE=prog.bin [PORT=/dev/ttyUSB1]"
	@echo "                  load a program into the MEGA65 and start it"
	@echo "  make run FILE=prog.bin [PORT=/dev/ttyUSB1]"
	@echo "                  run a program on the MEGA65, and print what niceemu prints"
	@echo "  make hwtest [BIT=synth/r6/build/top.bit] [PORT=/dev/ttyUSB1]"
	@echo "                  program the MEGA65 and test it (needs m65)"
	@echo "  make cosim [ROM=prog.bin]"
	@echo "                  run the system in GHDL on sim/build/nicemon.pty, for"
	@echo "                  the tools with --port sim/build/nicemon.pty --wait 1000"
	@echo "  make clean      remove the build output"

test:
	$(MAKE) -C sim test
	$(PYTHON) tools/test_nicedis.py

# The VHDL of this repository, but not the nice_cpu submodule, which has its
# own, nor the third-party files that keep their own style (CODING_STYLE.md):
# synth/r3/max10.vhd and synth/common/hdmi/.
VSG         ?= vsg
VHDL_SOURCES = $(filter-out synth/r3/max10.vhd,$(wildcard src/*.vhd src/video/*.vhd sim/*.vhd sim/cosim/*.vhd \
                                                          synth/common/*.vhd synth/r3/*.vhd synth/r6/*.vhd))

lint:
	$(VSG) -c vsg.yml -of syntastic -f $(VHDL_SOURCES)

examples:
	$(MAKE) -C examples

# The ROM's path is made absolute here, for the board's Makefile runs in
# its own directory.
r3:
	$(MAKE) -C synth/r3 ROM=$(if $(ROM),$(abspath $(ROM)))

r6:
	$(MAKE) -C synth/r6 ROM=$(if $(ROM),$(abspath $(ROM)))

mon:
	$(PYTHON) tools/nicemon.py --port $(PORT) $(FILE)

cosim:
	$(MAKE) -C sim cosim ROM=$(if $(ROM),$(abspath $(ROM)))

load:
	@test -n "$(FILE)" || (echo "Give the program with FILE=prog.bin"; exit 1)
	$(PYTHON) tools/load.py --port $(PORT) $(FILE)

run:
	@test -n "$(FILE)" || (echo "Give the program with FILE=prog.bin"; exit 1)
	$(PYTHON) tools/run.py --port $(PORT) $(FILE)

BIT ?= synth/r6/build/top.bit

hwtest: examples
	$(PYTHON) tools/hwtest.py --port $(PORT) --bit $(BIT)

clean:
	$(MAKE) -C sim clean
	$(MAKE) -C examples clean
	$(MAKE) -C synth/r3 clean
	$(MAKE) -C synth/r6 clean
