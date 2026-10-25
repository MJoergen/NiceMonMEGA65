# Simulation of NiceMonMEGA65 with GHDL.
#
# make test   assembles the test programs, analyzes the NICE core from the
#             nice_cpu submodule, the sources in ../src, and the testbenches,
#             and runs them:
#             tb_hello    the core alone. The console output must equal
#                         hello.expected.
#             tb_nicemon  the whole system, driven through its UART, as a
#                         host on the debug link would drive it, and
#                         its keyboard input, with rom.nasm as its ROM. It
#                         also runs reserved.nasm of the emulator's tests.
#             tb_kbd      the keyboard driver and its ASCII mapping.
#             tb_ps2      the PS/2 keyboard receiver and its ASCII mapping.
#             tb_ps2_nicemon  the PS/2 keyboard into the system, as the
#                         Nexys4DDR has it, with fifo.nasm and switch.nasm.
#             tb_text     the text display: one frame of 1280x1024, every
#                         pixel checked.
#             tb_board_io the Nexys4DDR's display and RGB LED drivers.
#             It also checks that GHDL can synthesize the system, the
#             keyboards, the text display (through text_synth.vhd, in
#             the boards' mode, with 15 and 13 screen address bits), and system.vhd as the Nexys4DDR has it, and the display and RGB LED drivers.
#             With -j these all run side by side, and the test takes as
#             long as tb_text alone. Each one is also a target: make
#             tb_kbd runs just that one.
# make cosim  runs the system with its debug UART on a TCP port of
#             127.0.0.1, cosim/tb_cosim.vhd, until it is stopped, for the
#             tools: tools/run.py --cosim N. It prints "cosim: port N".
#             COSIM_PORT=N picks the port, any free one by default, and
#             ROM=f.bin gives the system a ROM.
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

SRC_SOURCES  = ../src/uart_serdes.vhd ../src/rx_fifo.vhd ../src/ram.vhd ../src/rom.vhd \
               ../src/board_io.vhd ../src/scr_regs.vhd ../src/nicemon.vhd \
               ../src/kbd_m65.vhd ../src/kbd_ascii.vhd ../src/kbd_ps2.vhd ../src/kbd_ps2_ascii.vhd ../src/seg7.vhd ../src/rgb_pwm.vhd \
               ../src/video/video_pkg.vhd ../src/video/font_pkg.vhd ../src/video/pix.vhd ../src/video/scr_ram.vhd ../src/video/text.vhd \
               ../src/system.vhd
SOURCES      = $(SRC_SOURCES) text_synth.vhd tb_hello.vhd tb_nicemon.vhd tb_kbd.vhd tb_ps2.vhd tb_ps2_nicemon.vhd tb_text.vhd tb_board_io.vhd

.PHONY: test cosim check-steps analyze synth clean tb_hello tb_nicemon tb_kbd tb_ps2 tb_ps2_nicemon tb_text tb_board_io \
        synth-nicemon synth-nicemon-norom synth-kbd_m65 synth-kbd_ascii synth-kbd_ps2 \
        synth-kbd_ps2_ascii synth-text \
        synth-system synth-seg7 synth-rgb_pwm

# Each testbench and each synthesis check is a target of its own, so that
# "make -j test" runs them side by side. They share the work library of
# $(BUILD), which "analyze" writes first and they only read.
test: synth tb_hello tb_nicemon tb_kbd tb_ps2 tb_ps2_nicemon tb_text tb_board_io check-steps

check-steps: $(addprefix $(BUILD)/,hello.bin emu.bin reserved.bin)
	@if [ ! -x $(EMU) ]; then echo "SKIP check-steps: $(EMU) is not built"; exit 0; fi; \
	for p in hello:$(STEPS_HELLO) emu:$(STEPS_EMU) reserved:$(STEPS_RESERVED); do \
	  n=$${p%%:*}; want=$${p##*:}; \
	  got=$$($(EMU) $(BUILD)/$$n.bin </dev/null | sed -n 's/.* after \([0-9]*\) steps.*/\1/p'); \
	  [ "$$got" = "$$want" ] || { echo "FAIL check-steps: niceemu runs $$n in $$got steps, STEPS_$$n is $$want"; exit 1; }; \
	done; echo "PASS check-steps"

# The steps niceemu counts for the programs whose instruction counter
# tb_nicemon checks. They are kept here, so that the tests run without
# niceemu, and "make check-steps" compares them with a niceemu that is
# built, as CI builds it.
STEPS_HELLO    = 56
STEPS_EMU      = 12
STEPS_RESERVED = 6
EMU            = $(NICE_DIR)/emulator/zig-out/bin/niceemu

BINS = hello rom echo fifo devices emu count reserved eof counters break

tb_hello: analyze $(BUILD)/hello.bin
	@(cd $(BUILD) && $(GHDL) --elab-run $(GHDLFLAGS) tb_hello \
	  -gG_BIN_FILE=hello.bin -gG_OUT_FILE=hello.out > tb_hello.log 2>&1) || \
	  (echo "FAIL tb_hello"; cat $(BUILD)/tb_hello.log; exit 1)
	@if cmp -s hello.expected $(BUILD)/hello.out; then echo "PASS tb_hello"; \
	else echo "FAIL tb_hello"; diff hello.expected $(BUILD)/hello.out; exit 1; fi

tb_nicemon: analyze $(addprefix $(BUILD)/,$(addsuffix .bin,$(BINS)))
	@(cd $(BUILD) && $(GHDL) --elab-run $(GHDLFLAGS) tb_nicemon \
	  -gG_HELLO_FILE=hello.bin -gG_ROM_FILE=rom.bin -gG_ECHO_FILE=echo.bin -gG_FIFO_FILE=fifo.bin -gG_DEVICES_FILE=devices.bin -gG_EMU_FILE=emu.bin -gG_COUNT_FILE=count.bin -gG_RESERVED_FILE=reserved.bin -gG_EOF_FILE=eof.bin -gG_COUNTERS_FILE=counters.bin -gG_BREAK_FILE=break.bin -gG_NICE=$(NICE) \
	  -gG_HELLO_STEPS=$(STEPS_HELLO) -gG_EMU_STEPS=$(STEPS_EMU) -gG_RESERVED_STEPS=$(STEPS_RESERVED) > tb_nicemon.log 2>&1) && \
	  echo "PASS tb_nicemon" || (echo "FAIL tb_nicemon"; cat $(BUILD)/tb_nicemon.log; exit 1)

# The core is held from reset and never boots from a ROM there, so its data
# address is undefined until its first access, and the memory warns of it
# in every cycle before; --ieee-asserts=disable keeps that out of the log.
tb_ps2_nicemon: analyze $(BUILD)/fifo.bin $(BUILD)/switch.bin
	@(cd $(BUILD) && $(GHDL) --elab-run $(GHDLFLAGS) tb_ps2_nicemon \
	  -gG_FIFO_FILE=fifo.bin -gG_SWITCH_FILE=switch.bin --ieee-asserts=disable > tb_ps2_nicemon.log 2>&1) && \
	  echo "PASS tb_ps2_nicemon" || (echo "FAIL tb_ps2_nicemon"; cat $(BUILD)/tb_ps2_nicemon.log; exit 1)

tb_kbd tb_ps2 tb_text tb_board_io: analyze
	@(cd $(BUILD) && $(GHDL) --elab-run $(GHDLFLAGS) $@ > $@.log 2>&1) && \
	  echo "PASS $@" || (echo "FAIL $@"; cat $(BUILD)/$@.log; exit 1)

# Checks that GHDL can synthesize the system, with rom.bin as its ROM and
# without a ROM, and the keyboards, as nice_cpu does for its core, the text
# display, and system.vhd with the screen of the Nexys4DDR.
synth: synth-nicemon synth-nicemon-norom synth-kbd_m65 synth-kbd_ascii synth-kbd_ps2 synth-kbd_ps2_ascii \
       synth-text synth-system synth-seg7 synth-rgb_pwm

synth-nicemon: analyze $(BUILD)/rom.bin
	@(cd $(BUILD) && $(GHDL) --synth $(GHDLFLAGS) -gG_CLOCK_HZ=50000000 -gG_ROM_FILE=rom.bin nicemon > nicemon_synth.vhd 2> nicemon_synth.log) && \
	  echo "PASS synth nicemon" || (echo "FAIL synth nicemon"; cat $(BUILD)/nicemon_synth.log; exit 1)

synth-nicemon-norom: analyze
	@(cd $(BUILD) && $(GHDL) --synth $(GHDLFLAGS) -gG_CLOCK_HZ=50000000 nicemon > nicemon_norom_synth.vhd 2> nicemon_norom_synth.log) && \
	  echo "PASS synth nicemon without a ROM" || (echo "FAIL synth nicemon without a ROM"; cat $(BUILD)/nicemon_norom_synth.log; exit 1)

synth-kbd_m65 synth-kbd_ascii synth-kbd_ps2: synth-%: analyze
	@(cd $(BUILD) && $(GHDL) --synth $(GHDLFLAGS) -gG_CLOCK_HZ=50000000 $* > $*_synth.vhd 2> $*_synth.log) && \
	  echo "PASS synth $*" || (echo "FAIL synth $*"; cat $(BUILD)/$*_synth.log; exit 1)

synth-seg7: analyze
	@(cd $(BUILD) && $(GHDL) --synth $(GHDLFLAGS) -gG_CLOCK_HZ=90000000 seg7 > seg7_synth.vhd 2> seg7_synth.log) && \
	  echo "PASS synth seg7" || (echo "FAIL synth seg7"; cat $(BUILD)/seg7_synth.log; exit 1)

synth-rgb_pwm: analyze
	@(cd $(BUILD) && $(GHDL) --synth $(GHDLFLAGS) rgb_pwm > rgb_pwm_synth.vhd 2> rgb_pwm_synth.log) && \
	  echo "PASS synth rgb_pwm" || (echo "FAIL synth rgb_pwm"; cat $(BUILD)/rgb_pwm_synth.log; exit 1)

synth-kbd_ps2_ascii: analyze
	@(cd $(BUILD) && $(GHDL) --synth $(GHDLFLAGS) kbd_ps2_ascii > kbd_ps2_ascii_synth.vhd 2> kbd_ps2_ascii_synth.log) && \
	  echo "PASS synth kbd_ps2_ascii" || (echo "FAIL synth kbd_ps2_ascii"; cat $(BUILD)/kbd_ps2_ascii_synth.log; exit 1)

synth-text: analyze
	@for b in 15 13; do \
	  (cd $(BUILD) && $(GHDL) --synth $(GHDLFLAGS) -gG_SCR_ADDR_BITS=$$b text_synth > text_synth_$$b.vhd 2> text_synth_$$b.log) && \
	    echo "PASS synth text ($$b screen address bits)" || \
	    (echo "FAIL synth text ($$b screen address bits)"; cat $(BUILD)/text_synth_$$b.log; exit 1) || exit 1; \
	done

synth-system: analyze
	@(cd $(BUILD) && $(GHDL) --synth $(GHDLFLAGS) -gG_CLOCK_HZ=90000000 -gG_SCR_ADDR_BITS=13 -gG_BOARD_IO=true system > system_synth.vhd 2> system_synth.log) && \
	  echo "PASS synth system" || (echo "FAIL synth system"; cat $(BUILD)/system_synth.log; exit 1)

COSIM_PORT ?= 0

cosim: analyze
	@gcc -shared -fPIC -Wall -o $(BUILD)/libcosim.so cosim/cosim.c
	@cd $(BUILD) && $(GHDL) -a $(GHDLFLAGS) ../../cosim/tb_cosim.vhd && \
	  $(GHDL) --elab-run $(GHDLFLAGS) tb_cosim -gG_PORT=$(COSIM_PORT) $(if $(ROM),-gG_ROM_FILE=$(abspath $(ROM)))

analyze: | $(BUILD)
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

$(BUILD)/count.bin: count.nasm $(ASM_PY) | $(BUILD)
	@$(ASM) -o $@ $<

$(BUILD)/reserved.bin: $(NICE_DIR)/emulator/test/reserved.nasm $(ASM_PY) | $(BUILD)
	@$(ASM) -o $@ $<

$(BUILD)/eof.bin: eof.nasm $(ASM_PY) | $(BUILD)
	@$(ASM) -o $@ $<

$(BUILD)/devices.bin: devices.nasm $(ASM_PY) | $(BUILD)
	@$(ASM) -o $@ $<

$(BUILD)/counters.bin: counters.nasm $(ASM_PY) | $(BUILD)
	@$(ASM) -o $@ $<

$(BUILD)/break.bin: break.nasm $(ASM_PY) | $(BUILD)
	@$(ASM) -o $@ $<

$(BUILD)/switch.bin: switch.nasm $(ASM_PY) | $(BUILD)
	@$(ASM) -o $@ $<

$(BUILD):
	@mkdir -p $@

clean:
	rm -rf build
