# Simulation of NiceMonMEGA65 with GHDL.
#
# make test   assembles the test program, analyses the NICE core from the
#             nice_cpu submodule and the testbench, and runs the testbench.
#             The console output must equal the expected output.
# make clean  removes build/.

GHDL   ?= ghdl
PYTHON ?= python3
NICE    = ../nice_cpu
ASM     = $(PYTHON) $(NICE)/assembler/niceasm.py
BUILD   = build
# GHDL runs in $(BUILD), so paths given to it start with ../.
GHDLFLAGS = --std=08 --workdir=.

NICE_SOURCES = $(NICE)/hdl/src/trace_pkg.vhd $(NICE)/hdl/src/multicycle.vhd $(NICE)/hdl/sim/wb_mem.vhd
SOURCES      = tb_hello.vhd

.PHONY: test analyse clean

test: analyse $(BUILD)/hello.bin
	@(cd $(BUILD) && $(GHDL) --elab-run $(GHDLFLAGS) tb_hello \
	  -gG_BIN_FILE=hello.bin -gG_OUT_FILE=hello.out > tb_hello.log 2>&1) || \
	  (echo "FAIL tb_hello"; cat $(BUILD)/tb_hello.log; exit 1)
	@if cmp -s hello.expected $(BUILD)/hello.out; then echo "PASS tb_hello"; \
	else echo "FAIL tb_hello"; diff hello.expected $(BUILD)/hello.out; exit 1; fi

analyse: | $(BUILD)
	@cd $(BUILD) && $(GHDL) -a $(GHDLFLAGS) $(addprefix ../,$(NICE_SOURCES) $(SOURCES))

$(BUILD)/hello.bin: $(NICE)/doc/intro/examples/hello.asm | $(BUILD)
	@$(ASM) -o $@ $<

$(BUILD):
	@mkdir -p $@

clean:
	rm -rf $(BUILD)
