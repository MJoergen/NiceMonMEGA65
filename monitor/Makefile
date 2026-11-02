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
# and the function key ESC O P, which are dropped. D is d, and q is no
# command. x finds no demo in the ROM, r no program, d 8000 0 only moves
# the next d to 8000, and d 0 100 shows 256 words, which scrolls the
# screen. i shows the IP address, 0.0.0.0, and writes 192.168.1.65; four
# addresses are rejected, with too few numbers, one past 255, an empty
# one, and a letter after them; and the last, with blanks around it and
# a leading zero, is written, which the dump of 0xFFFFFF9A shows. h ends each input. dash's printf, the
# shell of make on Ubuntu, has no \x.
CMDS = ?\rv\rd 0 6\rd\rD 10 1\rq\r\r  c\rabc\177\177\177v\rjunk\003v\r\033[A\033OPv\rx\rr\rd 8000 0\rd 8000\rd 0 100\ri\ri 192.168.1.65\ri 1.2.3\ri 256.0.0.1\ri 1..2.3\ri 1.2.3.4x\ri  010.0.0.1 \rh\r
RUN  = r\rh\r
# scroll: Page Up and Page Down with no history, which do nothing; d 8000
# 700, the zeros of the empty RAM, 448 rows, which fill the history of 384
# rows and go round its ring; two Page Ups and a Page Down, which turn the
# ring and show 24 rows back; and v, which shows the screen again.
SCROLL = \033[5~\033[6~d 8000 700\r\033[5~\033[5~\033[6~v\rh\r
# load: l with lines typed and pasted. The first is typed with edits: a
# DEL that takes back 2, the cursor key ESC [ A, which is dropped, so it
# writes 134 at 9000. Four lines are skipped: zz, an address in the ROM,
# one of the monitor's variables, and a third number. Then build/hello.bin,
# its first 3 lines ended by CR LF and the rest by LF, and CR, an empty
# line, ends the load. A second l is ended by CTRL-C in the middle of a
# line, which writes nothing. r runs hello, and d shows 9000 and 9001.
LOAD_HEAD = l\r9000 12\177\033[A34\rzz\r100 5\rFFFFF000 1\r9001 5 6\r
LOAD_TAIL = \rl\r9001 7\003r\rd 9000 2\rh\r

# The words of each test that are dumped with the screen: for cmds the
# variables, the cursor's registers, and the IP address, and for the programs the text at
# column 40 of row 4, 80 * 4 + 40 = 360 = 0x168, with its color.
DUMP_cmds    = -d 0xFFFFF000:5 -d 0xFFFFFF80:6 -d 0xFFFFFF9A:1
# For scroll the variables and the screen's registers, and the last four
# digits of the address that starts a row of the history (the words 4 to
# 7 of the row): the rows of 869C and 8698 that Page Up turned to slots 0
# and 1, the row of 86A0 in slot 383, the first of the four rows that v
# and h added at the bottom of the ring, and the oldest, of 80B0, in slot
# 379.
DUMP_scroll  = -d 0xFFFFF000:11 -d 0xFFFFFF80:6 -d 0xFFFF7FB4:4 -d 0xFFFF7F64:4 \
               -d 0xFFFF0804:4 -d 0xFFFF0944:4
DUMP_hello   = -d 0xFFFF0168:12
DUMP_load    = -d 0xFFFFF000:14
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
	@printf '$(SCROLL)' > $(BUILD)/scroll.txt
	@{ printf '$(LOAD_HEAD)'; head -n 3 $(BUILD)/hello.bin | awk '{ printf "%s\r\n", $$0 }'; \
	  tail -n +4 $(BUILD)/hello.bin; printf '$(LOAD_TAIL)'; } > $(BUILD)/load.txt
	@fail=0; for t in cmds scroll load hello hello_c; do \
	  case $$t in \
	    cmds) prog=; input=cmds; dump='$(DUMP_cmds)';; \
	    scroll) prog=; input=scroll; dump='$(DUMP_scroll)';; \
	    load) prog=; input=load; dump='$(DUMP_load)';; \
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
