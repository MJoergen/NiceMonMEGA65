# The Vivado build, in non-project mode, shared by the boards. A board's
# Makefile sets PART, BOARD_SRC, and BOARD_XDC, and includes this file;
# BOARD_SRC has the board's own sources, with top.vhd last. It may set FLOW
# too.
#
# make                builds build/top.bit, whose core waits, held, for
#                     the debug link
# make ROM=file.bin   builds it with the ROM: the core boots from file.bin
#                     at reset (G_ROM_FILE of top.vhd)
# make NICE=multi     builds it with nice_cpu's multi-cycle core instead of
#                     the pipelined one, which is the default (core.mk)
# make FLOW=timing    builds it with directives for timing (below)
# make clean          removes the build
#
# FLOW = default, the default, runs every step with Vivado's default
# directives, with which the MEGA65 meets 100 MHz. FLOW = timing runs every
# step with a directive for timing, and phys_opt_design again after routing,
# as synth/nexys4ddr/Makefile does: in nice_cpu issue 34 that gained its slower part
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
SRC += ../../src/mem.vhd
SRC += ../../src/nicemon.vhd
SRC += ../../src/video/video_pkg.vhd
SRC += ../../src/video/font_pkg.vhd
SRC += ../../src/video/pix.vhd
SRC += ../../src/video/scr_ram.vhd
SRC += ../../src/video/text.vhd
SRC += ../../src/eth/eth_pkg.vhd
SRC += ../../src/eth/rmii_rx.vhd
SRC += ../../src/eth/rx_fcs.vhd
SRC += ../../src/eth/eth_ram.vhd
SRC += ../../src/eth/eth_rx_fifo.vhd
SRC += ../../src/eth/eth_arp.vhd
SRC += ../../src/eth/eth_icmp.vhd
SRC += ../../src/eth/eth_tcp_rx.vhd
SRC += ../../src/eth/eth_tcp_tx.vhd
SRC += ../../src/eth/eth_tcp_timer.vhd
SRC += ../../src/eth/eth_tcp_buf.vhd
SRC += ../../src/eth/eth_tcp_pick.vhd
SRC += ../../src/eth/eth_tcp.vhd
SRC += ../../src/eth/eth_tx_fifo.vhd
SRC += ../../src/eth/eth_arb.vhd
SRC += ../../src/eth/rmii_tx.vhd
SRC += ../../src/eth/eth.vhd
SRC += ../../src/dbg/dbg.vhd
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

# The worst path into the core and the worst out of it, from the register
# of one side to the register of the other, to build/core_in.rpt and
# build/core_out.rpt: the in-system slack that nice_cpu's budget for the
# core's ports (make -C hdl timing) compares with. The core's cells are
# found by name, for the design is flat; tools/bump.py reads the reports.
# The catch keeps a failure here from stopping the build.
define CORE_REPORTS_TCL
if {[catch {
   set core [get_cells -hier -filter {IS_SEQUENTIAL && NAME =~ *i_nicemon/i_core/i_core/*}]
   set rest [get_cells -hier -filter {IS_SEQUENTIAL && NAME !~ *i_nicemon/i_core/i_core/*}]
   report_timing -from $$rest -to $$core -max_paths 1 -file build/core_in.rpt
   report_timing -from $$core -to $$rest -max_paths 1 -file build/core_out.rpt
} msg]} { puts "core reports failed: $$msg" }
endef
export CORE_REPORTS_TCL
CORE_REPORTS = $$CORE_REPORTS_TCL

# The worst paths into the TCP server (src/eth/eth_tcp.vhd), within it,
# and out of it, five of each, to build/tcp_paths.rpt (issue 49), so that
# its headroom can be read after any build. The catch, as above.
define TCP_REPORTS_TCL
if {[catch {
   set tcp  [get_cells -hier -filter {IS_SEQUENTIAL && NAME =~ *i_eth/i_eth_tcp/*}]
   set rest [get_cells -hier -filter {IS_SEQUENTIAL && NAME !~ *i_eth/i_eth_tcp/*}]
   report_timing -from $$rest -to $$tcp -max_paths 5 -nworst 1 -path_type summary -file build/tcp_paths.rpt
   report_timing -from $$tcp -to $$tcp -max_paths 5 -nworst 1 -path_type summary -file build/tcp_paths.rpt -append
   report_timing -from $$tcp -to $$rest -max_paths 5 -nworst 1 -path_type summary -file build/tcp_paths.rpt -append
} msg]} { puts "TCP reports failed: $$msg" }
endef
export TCP_REPORTS_TCL
TCP_REPORTS = $$TCP_REPORTS_TCL

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
	echo "$(CORE_REPORTS)" >> $@
	echo "$(TCP_REPORTS)" >> $@
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

# The core file of a MEGA65 board, for a slot of its flash, which MEGAFLASH
# writes (hold No Scroll at power on), so that the board starts the system
# without a JTAG cable. The board's Makefile sets COR_TARGET, coretool's
# name for the board revision: mega65r3 or mega65r6, for the core file of
# one revision must not go on the other. coretool is the Python script
# src/tools/coretool of mega65-tools (https://github.com/MEGA65/mega65-tools);
# set CORETOOL if it is not on the PATH. MEGAFLASH shows COR_NAME and
# COR_VERSION, at most 31 characters each; the version is the commit, and
# tools/release.py gives the tag.
ifneq ($(COR_TARGET),)
CORETOOL    ?= coretool
COR_NAME    ?= NiceMon
COR_VERSION ?= $(shell git describe --always --dirty 2>/dev/null)
COR          = build/NiceMonMEGA65-$(subst mega65,,$(COR_TARGET)).cor

.PHONY: cor
cor: $(COR)

$(COR): build/$(TOP).bit
	$(CORETOOL) --quiet --force --build $@ --bit $< --target $(COR_TARGET) \
	   --bit-name "$(COR_NAME)" --bit-version "$(COR_VERSION)"
endif
