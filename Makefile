# The top-level Makefile. It runs the Makefiles of the subdirectories.
# "make" lists the targets.

# The core: pipeline (the default) or multi, for test, r3, r6, and nexys4ddr (core.mk)
NICE   ?= pipeline
export NICE
PYTHON ?= python3
PORT   ?=
ETH    ?=
ARGS   ?=
# The line of load, run, and mon: the Ethernet port with ETH=IP, or the
# serial device PORT; ARGS may pick --tcp or --cosim instead
LINK    = $(if $(ETH),--eth $(ETH)) $(if $(PORT),--port $(PORT))
EMU     = nice_cpu/emulator/zig-out/bin/niceemu

.PHONY: help test formal lint diagrams examples demo r3 r6 nexys4ddr cor bump release load run mon flash hwtest linktest cosim cosimtest clean

# Every target but these needs the nice_cpu submodule
ifeq ($(wildcard nice_cpu/hdl/src/nice_pkg.vhd),)
ifneq ($(filter-out help lint clean,$(or $(MAKECMDGOALS),help)),)
$(error nice_cpu is not checked out; run "git submodule update --init")
endif
endif

help:
	@echo "Targets:"
	@echo "  make test       run the GHDL simulation tests (needs GHDL), and the demo's"
	@echo "                  test in niceemu"
	@echo "  make [-j4] formal"
	@echo "                  run the formal checks (needs Yosys, its GHDL plugin,"
	@echo "                  SymbiYosys, and Yices)"
	@echo "  make lint       check the VHDL against doc/CODING_STYLE.md (needs vsg)"
	@echo "  make diagrams   render the block diagrams, src/*.tex and src/eth/*.tex, to PNG"
	@echo "                  (needs pdflatex and pdftoppm)"
	@echo "  make examples   build the C examples to examples/build/*.bin (needs clang)"
	@echo "  make demo       build the ROM's demo to demo/build/demo.bin, for a"
	@echo "                  board's target with ROM=demo/build/demo.bin"
	@echo "  make r3 [ROM=prog.bin]"
	@echo "                  build the bitstream for the MEGA65 R3 (needs Vivado)"
	@echo "  make r6 [ROM=prog.bin]"
	@echo "                  build the bitstream for the MEGA65 R6; with ROM, the"
	@echo "                  core boots from the .bin file at reset"
	@echo "  make nexys4ddr [ROM=prog.bin]"
	@echo "                  build the bitstream for the Digilent Nexys4DDR"
	@echo "  make cor [ROM=prog.bin]"
	@echo "                  build the MEGA65 core files, synth/r3/build/NiceMonMEGA65-r3.cor"
	@echo "                  and synth/r6/build/NiceMonMEGA65-r6.cor, for MEGAFLASH"
	@echo "                  (needs Vivado and coretool, from mega65-tools)"
	@echo "  make bump TAG=V1.0 [ARGS=--push]"
	@echo "                  move nice_cpu to the tag, build the R6 bitstream, and commit"
	@echo "                  badge-mega65.json and verified.json (needs Vivado)"
	@echo "  make release TAG=V1.0[.1] (PORT=/dev/ttyUSB1 | ARGS=--publish)"
	@echo "                  build, test, and stage a release in build/release (V1.0.1"
	@echo "                  keeps nice_cpu at V1.0); with"
	@echo "                  --publish, tag it and create the GitHub Release (doc/RELEASE.md)"
	@echo "  make load FILE=prog.bin (ETH=IP | PORT=/dev/ttyUSB1) [ARGS=--no-run]"
	@echo "                  load a program into the board (MEGA65 or Nexys4DDR) and"
	@echo "                  start it"
	@echo "  make run FILE=prog.bin (ETH=IP | PORT=/dev/ttyUSB1) [ARGS='-i in.txt -d 0x100:16 -s --timeout 5']"
	@echo "                  run a program on the board, and print what niceemu prints"
	@echo "  make mon [FILE=prog.bin] (ETH=IP | PORT=/dev/ttyUSB1)"
	@echo "                  an interactive shell on the debug link: read and write"
	@echo "                  memory, pause, step, breakpoints, and the console"
	@echo "  make hwtest PORT=/dev/ttyUSB1 [BIT=synth/r6/build/top.bit] [ETH=IP]"
	@echo "                  check that the FPGA on PORT's board is the part BIT was"
	@echo "                  built for, program it with BIT, and run the tests (needs"
	@echo "                  openFPGALoader); for the Nexys4DDR, give"
	@echo "                  BIT=synth/nexys4ddr/build/top.bit; ETH=IP also tests the"
	@echo "                  Ethernet station, which gets that address"
	@echo "  make flash PORT=/dev/ttyUSB1 [BIT=synth/nexys4ddr/build/top.bit] [ARGS=--erase]"
	@echo "                  write BIT into the Nexys4DDR's flash, from which the board"
	@echo "                  starts with jumper JP1 on QSPI (needs openFPGALoader)"
	@echo "  make flash PORT=/dev/ttyUSB1 COR=synth/r6/build/NiceMonMEGA65-r6.cor SLOT=1"
	@echo "                  write the core file COR into slot SLOT, 1 to 7, of the"
	@echo "                  MEGA65's flash over JTAG, with no key held at power on,"
	@echo "                  and start it"
	@echo "  make linktest   compare run.py on niceemu --link with niceemu, and check"
	@echo "                  mon.py's commands, without a board"
	@echo "  make cosim [COSIM_PORT=4000] [ROM=prog.bin]"
	@echo "                  run the system in GHDL with its debug UART on a TCP port,"
	@echo "                  for the tools' --cosim PORT, until it is stopped"
	@echo "  make cosimtest  compare run.py on the simulated system with niceemu,"
	@echo "                  without a board (minutes)"
	@echo "  FLOW=default|timing  with a board's target picks Vivado's directives"
	@echo "                  (synth/Makefile.inc)"
	@echo "  NICE=pipeline|multi  with test, cosim, or a board's target picks nice_cpu's"
	@echo "                  pipelined core (the default) or its multi-cycle core"
	@echo "  make clean      remove the build output"

test:
	$(MAKE) -C sim test
	$(MAKE) -C demo test

# The formal checks of formal/: each task of each .sby file must pass, as
# a target of its own, so that "make -j4 formal" runs them side by side. Each
# task has a work directory of its own in formal/build, for a recent SymbiYosys
# keeps a status database in each one.
SBY ?= sby
FORMAL_TASKS = rx_fifo-prove rx_fifo-cover board_io-prove board_io-none board_io-cover \
               scr_regs-prove scr_regs-cover devices-prove devices-cover \
               mem-prove mem-model mem-cover \
               nicemon-run nicemon-link nicemon-cover \
               nicemon-rom nicemon-rom_cover \
               eth_tcp_timer-prove eth_tcp_timer-cover \
               eth_tcp_buf-prove eth_tcp_buf-model eth_tcp_buf-cover \
               eth_tcp_pick-prove eth_tcp_pick-cover \
               eth_tcp_rx-prove eth_tcp_rx-cover eth_tcp_tx-prove eth_tcp_tx-cover \
               rx_fcs-prove rx_fcs-cover

formal: $(addprefix formal-,$(FORMAL_TASKS))

formal-%:
	@mkdir -p formal/build
	@job=$(word 1,$(subst -, ,$*)); task=$(word 2,$(subst -, ,$*)); \
	cd formal && $(SBY) -f -d build/$${job}_$$task $$job.sby $$task > build/$${job}_$$task.log 2>&1; \
	if [ $$? -eq 0 ]; then echo "PASS formal $$job $$task"; else echo "FAIL formal $$job $$task"; \
	  grep -aE "Assert failed|Unreached|ERROR|DONE \((FAIL|UNKNOWN|ERROR)|summary: +(failed|counterexample|unreached)" \
	    build/$${job}_$$task.log || tail -n 5 build/$${job}_$$task.log; exit 1; fi

# The VHDL of this repository, but not the nice_cpu submodule, which has its
# own, nor the third-party files that keep their own style
# (doc/CODING_STYLE.md): synth/r3/max10.vhd and synth/mega65/hdmi/.
VSG         ?= vsg
VHDL_SOURCES = $(filter-out synth/r3/max10.vhd,$(wildcard src/*.vhd src/core/*.vhd src/video/*.vhd src/dbg/*.vhd src/eth/*.vhd sim/*.vhd sim/cosim/*.vhd formal/*.vhd \
                                                          synth/common/*.vhd synth/mega65/*.vhd synth/r3/*.vhd synth/r6/*.vhd \
                                                          synth/nexys4ddr/*.vhd))

lint:
	$(VSG) -c vsg.yml -of syntastic -f $(VHDL_SOURCES)

# The block diagrams of src/README.md and src/eth/README.md, as nice_cpu
# renders its own: each .tex to a .png beside it
DIAGRAMS = src/system src/eth/eth

diagrams: $(addsuffix .png,$(DIAGRAMS))

%.png: %.tex
	pdflatex -interaction=nonstopmode -halt-on-error -output-directory=$(dir $@) $<
	pdftoppm -r 150 -png -singlefile $*.pdf $*
	rm -f $*.pdf $*.aux $*.log

examples:
	$(MAKE) -C examples

demo:
	$(MAKE) -C demo

# The ROM's path is made absolute here, for the board's Makefile runs in
# its own directory.
r3:
	$(MAKE) -C synth/r3 ROM=$(if $(ROM),$(abspath $(ROM)))

r6:
	$(MAKE) -C synth/r6 ROM=$(if $(ROM),$(abspath $(ROM)))

nexys4ddr:
	$(MAKE) -C synth/nexys4ddr ROM=$(if $(ROM),$(abspath $(ROM)))

# The core files of the MEGA65 boards, from their bitstreams (synth/Makefile.inc)
cor:
	$(MAKE) -C synth/r3 cor ROM=$(if $(ROM),$(abspath $(ROM)))
	$(MAKE) -C synth/r6 cor ROM=$(if $(ROM),$(abspath $(ROM)))

# nice_cpu's badge of timing met on the MEGA65 (tools/bump.py)
bump:
	@test -n "$(TAG)" || (echo "Give the nice_cpu tag with TAG=V1.0"; exit 1)
	$(PYTHON) tools/bump.py $(ARGS) $(TAG)

# A release after a bump: staged first, then published (doc/RELEASE.md)
release:
	@test -n "$(TAG)" || (echo "Give the tag with TAG=V1.0, or TAG=V1.0.1 to keep nice_cpu"; exit 1)
	$(PYTHON) tools/release.py $(if $(PORT),--port $(PORT)) $(ARGS) $(TAG)

load:
	@test -n "$(FILE)" || (echo "Give the program with FILE=prog.bin"; exit 1)
	$(PYTHON) tools/load.py $(LINK) $(ARGS) $(FILE)

run:
	@test -n "$(FILE)" || (echo "Give the program with FILE=prog.bin"; exit 1)
	$(PYTHON) tools/run.py $(LINK) $(ARGS) $(FILE)

mon:
	$(PYTHON) tools/mon.py $(LINK) $(ARGS) $(FILE)

# The flash of the Nexys4DDR, or with COR and SLOT a slot of the MEGA65's
# (tools/flash.py); BIT on the command line overrides the default.
flash:
	@test -n "$(PORT)" || (echo "Give the board's serial port with PORT=/dev/ttyUSB1"; exit 1)
	$(PYTHON) tools/flash.py --port $(PORT) $(if $(COR),--cor $(COR) $(if $(SLOT),--slot $(SLOT)),--bit $(if $(filter command line,$(origin BIT)),$(BIT),synth/nexys4ddr/build/top.bit)) $(ARGS)

BIT ?= synth/r6/build/top.bit

# hwtest compares the board with niceemu, so niceemu is rebuilt when its
# sources are newer than the binary.
$(EMU): $(shell find nice_cpu/emulator/src nice_cpu/emulator/build.zig -type f 2>/dev/null)
	$(MAKE) -C nice_cpu/emulator build

# ETH=IP tests the Ethernet station too, giving the board that address.
hwtest: examples $(EMU)
	@test -n "$(PORT)" || (echo "Give the board's serial port with PORT=/dev/ttyUSB1"; exit 1)
	$(PYTHON) tools/hwtest.py --port $(PORT) --bit $(BIT) $(if $(ETH),--eth $(ETH))

# The comparison of hwtest on niceemu --link, which needs no board; it
# runs the benchmark only when make examples has built it.
linktest: $(EMU)
	$(PYTHON) tools/linktest.py

# The system in GHDL, its debug UART on a TCP port of 127.0.0.1, for the
# tools' --cosim (sim/Makefile)
cosim:
	$(MAKE) -C sim cosim

# The comparison of hwtest on the simulated system, which needs no board
cosimtest: $(EMU)
	$(PYTHON) tools/cosimtest.py

clean:
	rm -rf formal/build build/release
	$(MAKE) -C sim clean
	$(MAKE) -C examples clean
	$(MAKE) -C synth/r3 clean
	$(MAKE) -C synth/r6 clean
	$(MAKE) -C synth/nexys4ddr clean
