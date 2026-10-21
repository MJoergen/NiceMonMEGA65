# The Vivado build, in non-project mode, shared by the boards. A board's
# Makefile sets PART, BOARD_SRC, and BOARD_XDC, and includes this file;
# BOARD_SRC has the board's own sources, with top.vhd last.
#
# make                builds build/top.bit, whose core waits for the
#                     command line
# make ROM=file.bin   builds it with the ROM: the core boots from file.bin,
#                     the monitor, at reset (G_ROM_FILE of top.vhd)
# make NICE=multi   builds it with nice_cpu's multi-cycle core instead of the
#                     pipelined one, which is the default (core.mk)
# make clean          removes the build
#
# The pipelined core leaves little slack, so every step runs with a
# directive for timing, and phys_opt_design runs again after routing. With
# the default directives the R6 missed 100 MHz by 0.7 ns, and with these it
# meets it by 0.25 ns (nice_cpu issue 34).

VIVADO_DIR ?= /opt/Xilinx/2025.1/Vivado

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
SRC += ../../src/line_buffer.vhd
SRC += ../../src/cmd.vhd
SRC += ../../src/rx_fifo.vhd
SRC += ../../src/ram.vhd
SRC += ../../src/rom.vhd
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

build/$(TOP).bit: build/$(TOP).tcl $(SRC) $(XDC) $(ROM_ABS)
	bash -c "source $(VIVADO_DIR)/settings64.sh ; vivado -mode tcl -source $< -log build/vivado.log -journal build/vivado.jou"

# The script is remade when the Makefiles or the ROM or NICE option change.
build/$(TOP).tcl: $(MAKEFILE_LIST) build/rom.conf
	echo "# A tcl script for Vivado, made by make" > $@
	echo "read_vhdl -vhdl2008 { $(SRC) }" >> $@
	echo "read_xdc { $(XDC) }" >> $@
	echo "set_property PART $(PART) [current_project]" >> $@
	echo "synth_design -top $(TOP) $(GENERICS) -directive PerformanceOptimized -retiming" >> $@
	echo "opt_design -directive Explore" >> $@
	echo "place_design -directive ExtraTimingOpt" >> $@
	echo "phys_opt_design -directive AggressiveExplore" >> $@
	echo "route_design -directive AggressiveExplore" >> $@
	echo "phys_opt_design -directive AggressiveExplore" >> $@
	echo "report_timing_summary -file build/timing.rpt" >> $@
	echo "report_utilization -file build/utilization.rpt" >> $@
	echo "write_checkpoint -force build/$(TOP).dcp" >> $@
	echo "write_bitstream -force build/$(TOP).bit" >> $@
	echo "exit" >> $@

# The ROM and NICE options, written only when it changes, so that the script is not
# remade for nothing.
build/rom.conf: FORCE | build
	@echo "$(ROM_ABS) $(NICE)" | cmp -s - $@ || echo "$(ROM_ABS) $(NICE)" > $@

build:
	mkdir -p build

.PHONY: clean FORCE
FORCE:

clean:
	rm -rf build .Xil clockInfo.txt
