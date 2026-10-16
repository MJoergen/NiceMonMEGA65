# The top-level Makefile. It runs the Makefiles of the subdirectories.
# "make" lists the targets.

PYTHON ?= python3
PORT   ?= /dev/ttyUSB1

.PHONY: help test formal lint examples r3 r6 load run hwtest clean

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
	@echo "  make load FILE=prog.bin [PORT=/dev/ttyUSB1]"
	@echo "                  load a program into the MEGA65 and start it"
	@echo "  make run FILE=prog.bin [PORT=/dev/ttyUSB1]"
	@echo "                  run a program on the MEGA65, and print what niceemu prints"
	@echo "  make hwtest [BIT=synth/r6/build/top.bit] [PORT=/dev/ttyUSB1]"
	@echo "                  program the MEGA65 and test it (needs m65)"
	@echo "  make clean      remove the build output"

test:
	$(MAKE) -C sim test

# The formal checks of formal/: each task of each .sby file must pass, as
# a target of its own, so that "make -j4 formal" runs them side by side. The
# work directories go in formal/build.
SBY ?= sby
FORMAL_TASKS = cli-prove cli-cover rx_fifo-prove rx_fifo-cover nicemon-run nicemon-cli nicemon-cover

formal: $(addprefix formal-,$(FORMAL_TASKS))

formal-%:
	@mkdir -p formal/build
	@job=$(word 1,$(subst -, ,$*)); task=$(word 2,$(subst -, ,$*)); \
	cd formal && $(SBY) -f --prefix build/$$job $$job.sby $$task > build/$${job}_$$task.log 2>&1; \
	if [ $$? -eq 0 ]; then echo "PASS formal $$job $$task"; else echo "FAIL formal $$job $$task"; \
	  grep -aE "Assert failed|Unreached|ERROR|summary: +(failed|counterexample|unreached)" \
	    build/$${job}_$$task.log; exit 1; fi

# The VHDL of this repository, but not the nice_cpu submodule, which has its
# own, nor the third-party files that keep their own style (CODING_STYLE.md):
# synth/r3/max10.vhd and synth/common/hdmi/.
VSG         ?= vsg
VHDL_SOURCES = $(filter-out synth/r3/max10.vhd,$(wildcard src/*.vhd src/video/*.vhd sim/*.vhd formal/*.vhd \
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
	rm -rf formal/build
	$(MAKE) -C sim clean
	$(MAKE) -C examples clean
	$(MAKE) -C synth/r3 clean
	$(MAKE) -C synth/r6 clean
