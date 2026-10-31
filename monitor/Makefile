# Builds the monitor, the program of the ROM (README.md), into
# build/monitor.bin, for make r6 ROM=monitor/build/monitor.bin, and tests
# it in niceemu.
#
# make          builds build/monitor.bin, with VERSION in its banner, git
#               describe of the tree by default
# make test     checks the layout of the sources, and runs the monitor in
#               niceemu with the inputs below, alone and with the programs
#               of test/ at 0x8000, and compares the output with
#               test/*.expected
# make clean    removes build/
#
# The assembler has no include, so the monitor is the cat of monitor.nasm,
# monlib.nasm, mon.nasm, and build/version.nasm, which defines the label
# VERSION (monitor.nasm).

PYTHON  ?= python3
CLANG   ?= clang
NICE_CPU = ../nice_cpu
ASM      = $(PYTHON) $(NICE_CPU)/assembler/niceasm.py
FMT      = $(PYTHON) $(NICE_CPU)/assembler/nicefmt.py
NICEBUILD = $(PYTHON) $(NICE_CPU)/translator/nicebuild.py
EMU      = $(NICE_CPU)/emulator/zig-out/bin/niceemu
RUNTIME  = $(NICE_CPU)/runtime
TOOLS    = $(wildcard $(NICE_CPU)/assembler/*.py) $(wildcard $(NICE_CPU)/translator/*.py)
BUILD    = build
SOURCES  = monitor.nasm monlib.nasm mon.nasm
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo unknown)

.PHONY: all test fmt clean FORCE

all: $(BUILD)/monitor.bin

$(BUILD)/monitor.bin: $(SOURCES) $(BUILD)/version.nasm $(TOOLS)
	@cat $(SOURCES) $(BUILD)/version.nasm > $(BUILD)/monitor_all.nasm
	$(ASM) -o $@ $(BUILD)/monitor_all.nasm

# Written only when the version changes, so that the monitor is not
# assembled again, and a bitstream with it not built again, for nothing.
$(BUILD)/version.nasm: FORCE | $(BUILD)
	@echo "VERSION .ASCII_L '$(VERSION)'" | cmp -s - $@ || \
	  echo "VERSION .ASCII_L '$(VERSION)'" > $@

# The test has a version of its own, so that its output does not change
# with every commit.
$(BUILD)/monitor_test.bin: $(SOURCES) $(TOOLS) | $(BUILD)
	@(cat $(SOURCES); echo "VERSION .ASCII_L 'V9.9'") > $(BUILD)/monitor_test_all.nasm
	@$(ASM) -o $@ $(BUILD)/monitor_test_all.nasm

# The programs of the tests, at 0x8000: hello.nasm with the runtime's
# start-up code for a program under a monitor, and hello.c through
# nicebuild, which needs clang.
$(BUILD)/hello.bin: test/hello.nasm monlib.nasm mon.nasm $(TOOLS) | $(BUILD)
	@cat $(RUNTIME)/start_mon.nasm test/hello.nasm monlib.nasm mon.nasm $(RUNTIME)/lib.nasm \
	  > $(BUILD)/hello_all.nasm
	@$(ASM) -o $@ $(BUILD)/hello_all.nasm

$(BUILD)/hello_c.bin: test/hello.c mon.h mon.nasm $(TOOLS) | $(BUILD)
	@$(NICEBUILD) --monitor --asm mon.nasm -I . -o $@ test/hello.c

# The inputs. cmds types each command, with the edits of a line: three DELs
# that take back abc, a CTRL-C that empties junk, and the cursor key ESC [ A
# and the function key ESC O P, which are dropped. D is d. r finds no
# program, d 8000 0 only moves the next d to 8000, and d 0 100 shows 256
# words, which scrolls the screen. h ends each input. dash's printf, the
# shell of make on Ubuntu, has no \x.
CMDS = ?\rv\rd 0 6\rd\rD 10 1\rx\r\r  c\rabc\177\177\177v\rjunk\003v\r\033[A\033OPv\rr\rd 8000 0\rd 8000\rd 0 100\rh\r
RUN  = r\rh\r
# The words of each test that are dumped with the screen: for cmds the
# variables and the cursor's registers, and for the programs the text at
# column 40 of row 4, 80 * 4 + 40 = 360 = 0x168, with its color.
DUMP_cmds    = -d 0xFFFFF000:5 -d 0xFFFFFF80:6
DUMP_hello   = -d 0xFFFF0168:12
DUMP_hello_c = -d 0xFFFF0168:12
MAX_STEPS = 10000000

# Each test runs the monitor with its input and its program, if any, and
# compares the console output, the dumps, and the screen with
# test/NAME.expected. The Halted line and the registers are left out, as
# the steps and the registers change with the code. hello_c is skipped
# without clang.
test: fmt $(BUILD)/monitor_test.bin $(BUILD)/hello.bin
	@printf '$(CMDS)' > $(BUILD)/cmds.txt
	@printf '$(RUN)' > $(BUILD)/run.txt
	@fail=0; for t in cmds hello hello_c; do \
	  case $$t in \
	    cmds) prog=; input=cmds; dump='$(DUMP_cmds)';; \
	    hello) prog=$(BUILD)/hello.bin; input=run; dump='$(DUMP_hello)';; \
	    hello_c) prog=$(BUILD)/hello_c.bin; input=run; dump='$(DUMP_hello_c)'; \
	      if ! command -v $(CLANG) > /dev/null; then echo "SKIP monitor $$t: no $(CLANG)"; continue; fi; \
	      $(MAKE) --no-print-directory $$prog || exit 1;; \
	  esac; \
	  cat $(BUILD)/monitor_test.bin $$prog > $(BUILD)/$$t.full.bin; \
	  $(EMU) -s -n $(MAX_STEPS) -i $(BUILD)/$$input.txt $$dump $(BUILD)/$$t.full.bin \
	    > $(BUILD)/$$t.raw; status=$$?; \
	  { sed -e '/^Halted (HALT)/,/^R12 /d' $(BUILD)/$$t.raw; echo "exit $$status"; } \
	    > $(BUILD)/$$t.out; \
	  if cmp -s test/$$t.expected $(BUILD)/$$t.out; then echo "PASS monitor $$t"; \
	  else echo "FAIL monitor $$t"; diff test/$$t.expected $(BUILD)/$$t.out; fail=1; fi; \
	done; exit $$fail

# The layout of the sources, as nice_cpu's nicefmt checks it
fmt:
	@$(FMT) $(SOURCES) test/hello.nasm

$(BUILD):
	@mkdir -p $@

clean:
	rm -rf $(BUILD)
