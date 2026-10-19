# The top-level Makefile. It runs the Makefiles of the subdirectories.
# "make" lists the targets.

# The core: pipeline (the default) or multi, for test, r3, and r6 (core.mk)
NICE   ?= pipeline
export NICE
PYTHON ?= python3
PORT   ?= /dev/ttyUSB1

.PHONY: help test lint examples r3 r6 load run hwtest clean

help:
	@echo "Targets:"
	@echo "  make test       run the GHDL simulation tests (needs GHDL)"
	@echo "  make lint       check the VHDL against CODING_STYLE.md (needs vsg)"
	@echo "  make examples   build the C examples to examples/build/*.bin (needs clang)"
	@echo "  make r3 [ROM=monitor.bin]"
	@echo "                  build the bitstream for the MEGA65 R3 (needs Vivado)"
	@echo "  make r6 [ROM=monitor.bin]"
	@echo "                  build the bitstream for the MEGA65 R6; with ROM, the"
	@echo "                  core boots from the .bin file at reset"
	@echo "  make load FILE=prog.bin [PORT=/dev/ttyUSB1]"
	@echo "                  load a program into the MEGA65 and start it"
	@echo "  make run FILE=prog.bin [PORT=/dev/ttyUSB1]"
	@echo "                  run a program on the MEGA65, and print what niceemu prints"
	@echo "  make hwtest [BIT=synth/r6/build/top.bit] [PORT=/dev/ttyUSB1]"
	@echo "                  program the MEGA65 and test it (needs m65)"
	@echo "  NICE=pipeline|multi  with test, r3, or r6 picks nice_cpu's pipelined"
	@echo "                  core (the default) or its multi-cycle core"
	@echo "  make clean      remove the build output"

test:
	$(MAKE) -C sim test

# The VHDL of this repository, but not the nice_cpu submodule, which has its
# own, nor the third-party files that keep their own style (CODING_STYLE.md):
# synth/r3/max10.vhd and synth/common/hdmi/.
VSG         ?= vsg
VHDL_SOURCES = $(filter-out synth/r3/max10.vhd,$(wildcard src/*.vhd src/core/*.vhd src/video/*.vhd sim/*.vhd \
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
