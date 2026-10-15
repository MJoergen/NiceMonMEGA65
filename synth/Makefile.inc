# The Vivado build, in non-project mode, shared by the boards. A board's
# Makefile sets BOARD_SRC and BOARD_XDC, and includes this file.
#
# make        builds build/top.bit
# make clean  removes the build

VIVADO_DIR ?= /opt/Xilinx/2025.1/Vivado

PART = xc7a200tfbg484-2
TOP  = top

NICE = ../../nice_cpu
SRC  = $(NICE)/hdl/src/trace_pkg.vhd
SRC += $(NICE)/hdl/src/multicycle.vhd
SRC += $(NICE)/hdl/src/mpu.vhd
SRC += $(NICE)/hdl/src/perf.vhd
SRC += $(NICE)/hdl/src/timer.vhd
SRC += ../../src/uart_serdes.vhd
SRC += ../../src/line_buffer.vhd
SRC += ../../src/cmd.vhd
SRC += ../../src/ram.vhd
SRC += ../../src/nicemon.vhd
SRC += ../../src/kbd_m65.vhd
SRC += ../../src/kbd_ascii.vhd
SRC += ../common/clk_rst.vhd
SRC += ../../src/video/video_pkg.vhd
SRC += ../../src/video/font_pkg.vhd
SRC += ../../src/video/pix.vhd
SRC += ../../src/video/scr_ram.vhd
SRC += ../../src/video/text.vhd
SRC += ../common/hdmi/types_pkg.vhd
SRC += ../common/hdmi/sync_reg.vhd
SRC += ../common/hdmi/hdmi_tx_encoder.vhd
SRC += ../common/hdmi/vga_to_hdmi.vhd
SRC += ../common/hdmi/serialiser_10to1_selectio.vhd
SRC += ../common/video_clk.vhd
SRC += ../common/mega65.vhd
SRC += $(BOARD_SRC)

XDC = ../common/common.xdc $(BOARD_XDC)

build/$(TOP).bit: build/$(TOP).tcl $(SRC) $(XDC)
	bash -c "source $(VIVADO_DIR)/settings64.sh ; vivado -mode tcl -source $< -log build/vivado.log -journal build/vivado.jou"

build/$(TOP).tcl: Makefile ../Makefile.inc
	mkdir -p build
	echo "# A tcl script for Vivado, made by make" > $@
	echo "read_vhdl -vhdl2008 { $(SRC) }" >> $@
	echo "read_xdc { $(XDC) }" >> $@
	echo "set_property PART $(PART) [current_project]" >> $@
	echo "synth_design -top $(TOP)" >> $@
	echo "opt_design" >> $@
	echo "place_design" >> $@
	echo "phys_opt_design" >> $@
	echo "route_design" >> $@
	echo "report_timing_summary -file build/timing.rpt" >> $@
	echo "report_utilization -file build/utilization.rpt" >> $@
	echo "write_checkpoint -force build/$(TOP).dcp" >> $@
	echo "write_bitstream -force build/$(TOP).bit" >> $@
	echo "exit" >> $@

.PHONY: clean
clean:
	rm -rf build .Xil clockInfo.txt
