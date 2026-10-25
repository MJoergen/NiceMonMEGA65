# The Vivado build, in non-project mode, shared by the boards. A board's
# Makefile sets PART, BOARD_SRC, and BOARD_XDC, and includes this file;
# BOARD_SRC has the board's own sources, with top.vhd last. It may set FLOW
# too.
#
# make                builds build/top.bit, whose core waits, held, for
#                     the debug link
# make ROM=file.bin   builds it with the ROM: the core boots from file.bin,
#                     the monitor, at reset (G_ROM_FILE of top.vhd)
# make NICE=multi     builds it with nice_cpu's multi-cycle core instead of
#                     the pipelined one, which is the default (core.mk)
# make FLOW=timing    builds it with directives for timing (below)
# make clean          removes the build
#
# FLOW = default, the default, runs every step with Vivado's default
# directives, with which the MEGA65 meets 100 MHz. FLOW = timing runs every
# step with a directive for timing, and phys_opt_design again after routing,
# as the Nexys4DDR does: in nice_cpu issue 34 that gained its slower part
# about 0.5 ns.

VIVADO_DIR ?= /opt/Xilinx/2025.1/Vivado
FLOW       ?= default

ifeq ($(FLOW),timing)
SYNTH_OPTS = -directive PerformanceOptimized -retiming
OPT_OPTS   = -directive Explore
PLACE_OPTS = -directive ExtraTimingOpt
PHYS_OPTS  = -directive AggressiveExplore
ROUTE_OPTS = -directive AggressiveExplore
else ifeq ($(FLOW),default)
SYNTH_OPTS =
OPT_OPTS   =
PLACE_OPTS =
PHYS_OPTS  =
ROUTE_OPTS =
else
$(error FLOW must be timing or default)
endif

TOP = top

ROM ?=
ifneq ($(ROM),)
ROM_ABS  = $(abspath $(ROM))
GENERICS = -generic G_ROM_FILE=$(ROM_ABS)
endif

NICE_HDL = ../../nice_cpu/hdl/src
REPO     = ../..
include ../../core.mk
SRC  = $(NICE_SOURCES)
SRC += ../../src/uart_serdes.vhd
SRC += ../../src/rx_fifo.vhd
SRC += ../../src/ram.vhd
SRC += ../../src/rom.vhd
SRC += ../../src/board_io.vhd
SRC += ../../src/scr_regs.vhd
SRC += ../../src/devices.vhd
SRC += ../../src/nicemon.vhd
SRC += ../../src/video/video_pkg.vhd
SRC += ../../src/video/font_pkg.vhd
SRC += ../../src/video/pix.vhd
SRC += ../../src/video/scr_ram.vhd
SRC += ../../src/video/text.vhd
SRC += ../../src/system.vhd
SRC += ../common/clk_rst.vhd
SRC += ../common/video_clk.vhd
SRC += $(BOARD_SRC)

XDC = $(BOARD_XDC)

# Batch mode exits nonzero on an error in the script, where Tcl mode drops to
# a prompt that reads EOF and exits 0. The old bitstream is removed first, so
# that a failed build leaves none behind.
build/$(TOP).bit: build/$(TOP).tcl $(SRC) $(XDC) $(ROM_ABS)
	rm -f $@
	bash -c "source $(VIVADO_DIR)/settings64.sh ; vivado -mode batch -source $< -log build/vivado.log -journal build/vivado.jou"

# The script is remade when the Makefiles or the ROM, NICE, or FLOW option
# change. synth_design ignores VHDL assertions without -assert, such as the
# check in src/rom.vhd for a word beyond the ROM.
build/$(TOP).tcl: $(MAKEFILE_LIST) build/rom.conf
	echo "# A tcl script for Vivado, made by make" > $@
	echo "read_vhdl -vhdl2008 { $(SRC) }" >> $@
	echo "read_xdc { $(XDC) }" >> $@
	echo "set_property PART $(PART) [current_project]" >> $@
	echo "synth_design -top $(TOP) -assert $(GENERICS) $(SYNTH_OPTS)" >> $@
	echo "opt_design $(OPT_OPTS)" >> $@
	echo "place_design $(PLACE_OPTS)" >> $@
	echo "phys_opt_design $(PHYS_OPTS)" >> $@
	echo "route_design $(ROUTE_OPTS)" >> $@
	$(if $(filter timing,$(FLOW)),echo "phys_opt_design $(PHYS_OPTS)" >> $@)
	echo "report_timing_summary -file build/timing.rpt" >> $@
	echo "report_utilization -file build/utilization.rpt" >> $@
	echo "write_checkpoint -force build/$(TOP).dcp" >> $@
	echo "write_bitstream -force build/$(TOP).bit" >> $@
	echo "exit" >> $@

# The ROM, NICE, and FLOW options, written only when they change, so that
# the script is not remade for nothing.
build/rom.conf: FORCE | build
	@echo "$(ROM_ABS) $(NICE) $(FLOW)" | cmp -s - $@ || echo "$(ROM_ABS) $(NICE) $(FLOW)" > $@

build:
	mkdir -p build

.PHONY: clean FORCE
FORCE:

clean:
	rm -rf build .Xil clockInfo.txt
