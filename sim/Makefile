# Simulation of NiceMonMEGA65 with GHDL.
#
# make test   assembles the test programs, analyses the NICE core from the
#             nice_cpu submodule, the sources in ../src, and the testbenches,
#             and runs them:
#             tb_hello    the core alone. The console output must equal
#                         hello.expected.
#             tb_nicemon  the whole system, driven through its UART and
#                         its keyboard input, with rom.nasm as its ROM. It
#                         also runs reserved.nasm of the emulator's tests.
#             tb_kbd      the keyboard driver and its ASCII mapping.
#             tb_ps2      the PS/2 keyboard receiver and its ASCII mapping.
#             tb_text     the text display: one frame of 1280x1024, every
#                         pixel checked.
#             It also checks that GHDL can synthesise the system, the
#             keyboards, the text display (through text_synth.vhd, in
#             the boards' mode), and system.vhd as the Nexys4DDR has it.
#             With -j these all run side by side, and the test takes as
#             long as tb_text alone. Each one is also a target: make
#             tb_kbd runs just that one.
# make clean  removes build/.
#
# NICE=pipeline (the default) or NICE=multi picks the core, and the files
# are built in build/$(NICE).

GHDL   ?= ghdl
PYTHON ?= python3
NICE_DIR = ../nice_cpu
ASM     = $(PYTHON) $(NICE_DIR)/assembler/niceasm.py
ASM_PY  = $(wildcard $(NICE_DIR)/assembler/*.py)
BUILD   = build/$(NICE)
# GHDL runs in $(BUILD), so paths given to it start with ../../.
GHDLFLAGS = --std=08 --workdir=.

# NICE_SOURCES, the core and what it needs from nice_cpu, as NICE selects
NICE_HDL = $(NICE_DIR)/hdl/src
REPO     = ..
include ../core.mk
NICE_SIM = $(NICE_DIR)/hdl/sim/wb_mem.vhd

SRC_SOURCES  = ../src/uart_serdes.vhd ../src/line_buffer.vhd ../src/cmd.vhd ../src/rx_fifo.vhd ../src/ram.vhd ../src/rom.vhd \
               ../src/nicemon.vhd \
               ../src/kbd_m65.vhd ../src/kbd_ascii.vhd ../src/kbd_ps2.vhd ../src/kbd_ps2_ascii.vhd \
               ../src/video/video_pkg.vhd ../src/video/font_pkg.vhd ../src/video/pix.vhd ../src/video/scr_ram.vhd ../src/video/text.vhd \
               ../src/system.vhd
SOURCES      = $(SRC_SOURCES) text_synth.vhd tb_hello.vhd tb_nicemon.vhd tb_kbd.vhd tb_ps2.vhd tb_text.vhd

.PHONY: test analyse synth clean tb_hello tb_nicemon tb_kbd tb_ps2 tb_text \
        synth-nicemon synth-nicemon-norom synth-kbd_m65 synth-kbd_ascii synth-kbd_ps2 \
        synth-kbd_ps2_ascii synth-text \
        synth-system

# Each testbench and each synthesis check is a target of its own, so that
# "make -j test" runs them side by side. They share the work library of
# $(BUILD), which "analyse" writes first and they only read.
test: synth tb_hello tb_nicemon tb_kbd tb_ps2 tb_text

BINS = hello rom echo fifo devices emu reserved eof

tb_hello: analyse $(BUILD)/hello.bin
	@(cd $(BUILD) && $(GHDL) --elab-run $(GHDLFLAGS) tb_hello \
	  -gG_BIN_FILE=hello.bin -gG_OUT_FILE=hello.out > tb_hello.log 2>&1) || \
	  (echo "FAIL tb_hello"; cat $(BUILD)/tb_hello.log; exit 1)
	@if cmp -s hello.expected $(BUILD)/hello.out; then echo "PASS tb_hello"; \
	else echo "FAIL tb_hello"; diff hello.expected $(BUILD)/hello.out; exit 1; fi

tb_nicemon: analyse $(addprefix $(BUILD)/,$(addsuffix .bin,$(BINS)))
	@(cd $(BUILD) && $(GHDL) --elab-run $(GHDLFLAGS) tb_nicemon \
	  -gG_HELLO_FILE=hello.bin -gG_ROM_FILE=rom.bin -gG_ECHO_FILE=echo.bin -gG_FIFO_FILE=fifo.bin -gG_DEVICES_FILE=devices.bin -gG_EMU_FILE=emu.bin -gG_RESERVED_FILE=reserved.bin -gG_EOF_FILE=eof.bin > tb_nicemon.log 2>&1) && \
	  echo "PASS tb_nicemon" || (echo "FAIL tb_nicemon"; cat $(BUILD)/tb_nicemon.log; exit 1)

tb_kbd tb_ps2 tb_text: analyse
	@(cd $(BUILD) && $(GHDL) --elab-run $(GHDLFLAGS) $@ > $@.log 2>&1) && \
	  echo "PASS $@" || (echo "FAIL $@"; cat $(BUILD)/$@.log; exit 1)

# Checks that GHDL can synthesise the system, with rom.bin as its ROM and
# without a ROM, and the keyboards, as nice_cpu does for its core, the text
# display, and system.vhd with the screen of the Nexys4DDR.
synth: synth-nicemon synth-nicemon-norom synth-kbd_m65 synth-kbd_ascii synth-kbd_ps2 synth-kbd_ps2_ascii \
       synth-text synth-system

synth-nicemon: analyse $(BUILD)/rom.bin
	@(cd $(BUILD) && $(GHDL) --synth $(GHDLFLAGS) -gG_CLOCK_HZ=50000000 -gG_ROM_FILE=rom.bin nicemon > nicemon_synth.vhd 2> nicemon_synth.log) && \
	  echo "PASS synth nicemon" || (echo "FAIL synth nicemon"; cat $(BUILD)/nicemon_synth.log; exit 1)

synth-nicemon-norom: analyse
	@(cd $(BUILD) && $(GHDL) --synth $(GHDLFLAGS) -gG_CLOCK_HZ=50000000 nicemon > nicemon_norom_synth.vhd 2> nicemon_norom_synth.log) && \
	  echo "PASS synth nicemon without a ROM" || (echo "FAIL synth nicemon without a ROM"; cat $(BUILD)/nicemon_norom_synth.log; exit 1)

synth-kbd_m65 synth-kbd_ascii synth-kbd_ps2: synth-%: analyse
	@(cd $(BUILD) && $(GHDL) --synth $(GHDLFLAGS) -gG_CLOCK_HZ=50000000 $* > $*_synth.vhd 2> $*_synth.log) && \
	  echo "PASS synth $*" || (echo "FAIL synth $*"; cat $(BUILD)/$*_synth.log; exit 1)

synth-kbd_ps2_ascii: analyse
	@(cd $(BUILD) && $(GHDL) --synth $(GHDLFLAGS) kbd_ps2_ascii > kbd_ps2_ascii_synth.vhd 2> kbd_ps2_ascii_synth.log) && \
	  echo "PASS synth kbd_ps2_ascii" || (echo "FAIL synth kbd_ps2_ascii"; cat $(BUILD)/kbd_ps2_ascii_synth.log; exit 1)

synth-text: analyse
	@(cd $(BUILD) && $(GHDL) --synth $(GHDLFLAGS) text_synth > text_synth.vhd 2> text_synth.log) && \
	  echo "PASS synth text" || (echo "FAIL synth text"; cat $(BUILD)/text_synth.log; exit 1)

synth-system: analyse
	@(cd $(BUILD) && $(GHDL) --synth $(GHDLFLAGS) -gG_CLOCK_HZ=80000000 -gG_SCR_ADDR_BITS=13 system > system_synth.vhd 2> system_synth.log) && \
	  echo "PASS synth system" || (echo "FAIL synth system"; cat $(BUILD)/system_synth.log; exit 1)

analyse: | $(BUILD)
	@cd $(BUILD) && $(GHDL) -a $(GHDLFLAGS) $(addprefix ../../,$(NICE_SOURCES) $(NICE_SIM) $(SOURCES))

$(BUILD)/hello.bin: $(NICE_DIR)/doc/intro/examples/hello.nasm $(ASM_PY) | $(BUILD)
	@$(ASM) -o $@ $<

$(BUILD)/rom.bin: rom.nasm $(ASM_PY) | $(BUILD)
	@$(ASM) -o $@ $<

$(BUILD)/echo.bin: echo.nasm $(ASM_PY) | $(BUILD)
	@$(ASM) -o $@ $<

$(BUILD)/fifo.bin: fifo.nasm $(ASM_PY) | $(BUILD)
	@$(ASM) -o $@ $<

$(BUILD)/emu.bin: emu.nasm $(ASM_PY) | $(BUILD)
	@$(ASM) -o $@ $<

$(BUILD)/reserved.bin: $(NICE_DIR)/emulator/test/reserved.nasm $(ASM_PY) | $(BUILD)
	@$(ASM) -o $@ $<

$(BUILD)/eof.bin: eof.nasm $(ASM_PY) | $(BUILD)
	@$(ASM) -o $@ $<

$(BUILD)/devices.bin: devices.nasm $(ASM_PY) | $(BUILD)
	@$(ASM) -o $@ $<

$(BUILD):
	@mkdir -p $@

clean:
	rm -rf build
