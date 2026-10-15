# Simulation of NiceMonMEGA65 with GHDL.
#
# make test   assembles the test programs, analyses the NICE core from the
#             nice_cpu submodule, the sources in ../src, and the testbenches,
#             and runs them:
#             tb_hello    the core alone. The console output must equal
#                         hello.expected.
#             tb_nicemon  the whole system, driven through its UART and
#                         its keyboard input. It also runs reserved.nasm
#                         of the emulator's tests.
#             tb_kbd      the keyboard driver and its ASCII mapping.
#             tb_text     the text display: one frame of 1280x1024, every
#                         pixel checked.
#             It also checks that GHDL can synthesise the system, the
#             keyboard, and the text display (through text_synth.vhd, in
#             the boards' mode).
# make clean  removes build/.

GHDL   ?= ghdl
PYTHON ?= python3
NICE    = ../nice_cpu
ASM     = $(PYTHON) $(NICE)/assembler/niceasm.py
BUILD   = build
# GHDL runs in $(BUILD), so paths given to it start with ../.
GHDLFLAGS = --std=08 --workdir=.

NICE_SOURCES = $(NICE)/hdl/src/trace_pkg.vhd $(NICE)/hdl/src/multicycle.vhd $(NICE)/hdl/src/mpu.vhd \
               $(NICE)/hdl/src/perf.vhd $(NICE)/hdl/sim/wb_mem.vhd
SRC_SOURCES  = ../src/uart_serdes.vhd ../src/line_buffer.vhd ../src/cmd.vhd ../src/ram.vhd ../src/nicemon.vhd \
               ../src/kbd_m65.vhd ../src/kbd_ascii.vhd \
               ../src/video/video_pkg.vhd ../src/video/font_pkg.vhd ../src/video/pix.vhd ../src/video/scr_ram.vhd ../src/video/text.vhd
SOURCES      = $(SRC_SOURCES) text_synth.vhd tb_hello.vhd tb_nicemon.vhd tb_kbd.vhd tb_text.vhd

.PHONY: test analyse synth clean

test: analyse synth $(BUILD)/hello.bin $(BUILD)/echo.bin $(BUILD)/fifo.bin $(BUILD)/devices.bin $(BUILD)/emu.bin $(BUILD)/reserved.bin $(BUILD)/eof.bin
	@(cd $(BUILD) && $(GHDL) --elab-run $(GHDLFLAGS) tb_hello \
	  -gG_BIN_FILE=hello.bin -gG_OUT_FILE=hello.out > tb_hello.log 2>&1) || \
	  (echo "FAIL tb_hello"; cat $(BUILD)/tb_hello.log; exit 1)
	@if cmp -s hello.expected $(BUILD)/hello.out; then echo "PASS tb_hello"; \
	else echo "FAIL tb_hello"; diff hello.expected $(BUILD)/hello.out; exit 1; fi
	@(cd $(BUILD) && $(GHDL) --elab-run $(GHDLFLAGS) tb_nicemon \
	  -gG_HELLO_FILE=hello.bin -gG_ECHO_FILE=echo.bin -gG_FIFO_FILE=fifo.bin -gG_DEVICES_FILE=devices.bin -gG_EMU_FILE=emu.bin -gG_RESERVED_FILE=reserved.bin -gG_EOF_FILE=eof.bin > tb_nicemon.log 2>&1) && \
	  echo "PASS tb_nicemon" || (echo "FAIL tb_nicemon"; cat $(BUILD)/tb_nicemon.log; exit 1)
	@(cd $(BUILD) && $(GHDL) --elab-run $(GHDLFLAGS) tb_kbd > tb_kbd.log 2>&1) && \
	  echo "PASS tb_kbd" || (echo "FAIL tb_kbd"; cat $(BUILD)/tb_kbd.log; exit 1)
	@(cd $(BUILD) && $(GHDL) --elab-run $(GHDLFLAGS) tb_text > tb_text.log 2>&1) && \
	  echo "PASS tb_text" || (echo "FAIL tb_text"; cat $(BUILD)/tb_text.log; exit 1)

# Checks that GHDL can synthesise the system and the keyboard, as nice_cpu
# does for its core, and the text display.
synth: analyse
	@for e in nicemon kbd_m65 kbd_ascii; do \
	  (cd $(BUILD) && $(GHDL) --synth $(GHDLFLAGS) -gG_CLOCK_HZ=50000000 $$e > $${e}_synth.vhd 2> $${e}_synth.log) && \
	  echo "PASS synth $$e" || (echo "FAIL synth $$e"; cat $(BUILD)/$${e}_synth.log; exit 1) || exit 1; \
	done
	@(cd $(BUILD) && $(GHDL) --synth $(GHDLFLAGS) text_synth > text_synth.vhd 2> text_synth.log) && \
	  echo "PASS synth text" || (echo "FAIL synth text"; cat $(BUILD)/text_synth.log; exit 1)

analyse: | $(BUILD)
	@cd $(BUILD) && $(GHDL) -a $(GHDLFLAGS) $(addprefix ../,$(NICE_SOURCES) $(SOURCES))

$(BUILD)/hello.bin: $(NICE)/doc/intro/examples/hello.nasm | $(BUILD)
	@$(ASM) -o $@ $<

$(BUILD)/echo.bin: echo.nasm | $(BUILD)
	@$(ASM) -o $@ $<

$(BUILD)/fifo.bin: fifo.nasm | $(BUILD)
	@$(ASM) -o $@ $<

$(BUILD)/emu.bin: emu.nasm | $(BUILD)
	@$(ASM) -o $@ $<

$(BUILD)/reserved.bin: $(NICE)/emulator/test/reserved.nasm | $(BUILD)
	@$(ASM) -o $@ $<

$(BUILD)/eof.bin: eof.nasm | $(BUILD)
	@$(ASM) -o $@ $<

$(BUILD)/devices.bin: devices.nasm | $(BUILD)
	@$(ASM) -o $@ $<

$(BUILD):
	@mkdir -p $@

clean:
	rm -rf $(BUILD)
