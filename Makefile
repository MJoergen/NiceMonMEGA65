# The top-level Makefile. It runs the Makefiles of the subdirectories.
# "make" lists the targets.

# The core: pipeline (the default) or multi, for test, r3, r6, and nexys4ddr (core.mk)
NICE   ?= pipeline
export NICE
PYTHON ?= python3
PORT   ?= /dev/ttyUSB1
ARGS   ?=
EMU     = nice_cpu/emulator/zig-out/bin/niceemu

.PHONY: help test formal lint examples r3 r6 nexys4ddr load run hwtest clean

# Every target but these needs the nice_cpu submodule
ifeq ($(wildcard nice_cpu/hdl/src/nice_pkg.vhd),)
ifneq ($(filter-out help lint clean,$(or $(MAKECMDGOALS),help)),)
$(error nice_cpu is not checked out; run "git submodule update --init")
endif
endif

help:
	@echo "Targets:"
	@echo "  make test       run the GHDL simulation tests (needs GHDL)"
	@echo "  make [-j4] formal"
	@echo "                  run the formal checks (needs Yosys, its GHDL plugin,"
	@echo "                  SymbiYosys, and Yices)"
	@echo "  make lint       check the VHDL against CODING_STYLE.md (needs vsg)"
	@echo "  make examples   build the C examples to examples/build/*.bin (needs clang)"
	@echo "  make r3 [ROM=monitor.bin]"
	@echo "                  build the bitstream for the MEGA65 R3 (needs Vivado)"
	@echo "  make r6 [ROM=monitor.bin]"
	@echo "                  build the bitstream for the MEGA65 R6; with ROM, the"
	@echo "                  core boots from the .bin file at reset"
	@echo "  make nexys4ddr [ROM=monitor.bin]"
	@echo "                  build the bitstream for the Digilent Nexys4DDR"
	@echo "  make load FILE=prog.bin [PORT=/dev/ttyUSB1] [ARGS=--no-run]"
	@echo "                  load a program into the board (MEGA65 or Nexys4DDR) and"
	@echo "                  start it"
	@echo "  make run FILE=prog.bin [PORT=/dev/ttyUSB1] [ARGS='-i in.txt -d 0:10 -s --timeout 5']"
	@echo "                  run a program on the board, and print what niceemu prints"
	@echo "  make hwtest [BIT=synth/r6/build/top.bit] [PORT=/dev/ttyUSB1]"
	@echo "                  check that the board of PORT has the FPGA of BIT, program"
	@echo "                  it, and test it (needs openFPGALoader); for the Nexys4DDR,"
	@echo "                  give BIT=synth/nexys4ddr/build/top.bit"
	@echo "  FLOW=default|timing  with a board's target picks Vivado's directives"
	@echo "                  (synth/Makefile.inc)"
	@echo "  NICE=pipeline|multi  with test or a board's target picks nice_cpu's"
	@echo "                  pipelined core (the default) or its multi-cycle core"
	@echo "  make clean      remove the build output"

test:
	$(MAKE) -C sim test

# The formal checks of formal/: each task of each .sby file must pass, as
# a target of its own, so that "make -j4 formal" runs them side by side. Each
# task has a work directory of its own in formal/build, for a recent SymbiYosys
# keeps a status database in each one.
SBY ?= sby
FORMAL_TASKS = rx_fifo-prove rx_fifo-cover nicemon-run nicemon-link nicemon-cover

formal: $(addprefix formal-,$(FORMAL_TASKS))

formal-%:
	@mkdir -p formal/build
	@job=$(word 1,$(subst -, ,$*)); task=$(word 2,$(subst -, ,$*)); \
	cd formal && $(SBY) -f -d build/$${job}_$$task $$job.sby $$task > build/$${job}_$$task.log 2>&1; \
	if [ $$? -eq 0 ]; then echo "PASS formal $$job $$task"; else echo "FAIL formal $$job $$task"; \
	  grep -aE "Assert failed|Unreached|ERROR|DONE \((FAIL|UNKNOWN|ERROR)|summary: +(failed|counterexample|unreached)" \
	    build/$${job}_$$task.log || tail -n 5 build/$${job}_$$task.log; exit 1; fi

# The VHDL of this repository, but not the nice_cpu submodule, which has its
# own, nor the third-party files that keep their own style (CODING_STYLE.md):
# synth/r3/max10.vhd and synth/mega65/hdmi/.
VSG         ?= vsg
VHDL_SOURCES = $(filter-out synth/r3/max10.vhd,$(wildcard src/*.vhd src/core/*.vhd src/video/*.vhd sim/*.vhd formal/*.vhd \
                                                          synth/common/*.vhd synth/mega65/*.vhd synth/r3/*.vhd synth/r6/*.vhd \
                                                          synth/nexys4ddr/*.vhd))

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

nexys4ddr:
	$(MAKE) -C synth/nexys4ddr ROM=$(if $(ROM),$(abspath $(ROM)))

load:
	@test -n "$(FILE)" || (echo "Give the program with FILE=prog.bin"; exit 1)
	$(PYTHON) tools/load.py --port $(PORT) $(ARGS) $(FILE)

run:
	@test -n "$(FILE)" || (echo "Give the program with FILE=prog.bin"; exit 1)
	$(PYTHON) tools/run.py --port $(PORT) $(ARGS) $(FILE)

BIT ?= synth/r6/build/top.bit

# hwtest compares the board with niceemu, so niceemu is rebuilt when its
# sources are newer than the binary.
$(EMU): $(shell find nice_cpu/emulator/src nice_cpu/emulator/build.zig -type f 2>/dev/null)
	$(MAKE) -C nice_cpu/emulator build

hwtest: examples $(EMU)
	$(PYTHON) tools/hwtest.py --port $(PORT) --bit $(BIT)

clean:
	rm -rf formal/build
	$(MAKE) -C sim clean
	$(MAKE) -C examples clean
	$(MAKE) -C synth/r3 clean
	$(MAKE) -C synth/r6 clean
	$(MAKE) -C synth/nexys4ddr clean
