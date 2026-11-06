# Builds the demo of the ROM, nice_cpu's demo (nice_cpu/demo), with the
# board's text, text.nasm, into build/demo.bin, a program under the
# monitor at 0x8000, and joins it behind the monitor into build/rom.bin,
# the boards' ROM by default and the release's (tools/release.py), in
# which the monitor's x runs it. For the time being: issue #65.
#
# make          builds build/demo.bin and build/rom.bin, with VERSION in
#               the demo's title bar and the monitor's banner, git
#               describe of the tree by default; the release gives its tag
# make test     runs the ROM of the tests in niceemu, with x and a few
#               keys, and with F12 and the monitor's v and h after them,
#               and compares the screens with test.expected
# make clean    removes build/
#
# The demo itself, its source and its tests, are nice_cpu's: a change to
# it reaches the boards only with a tag of nice_cpu. Its Makefile joins
# TEXT after demo.nasm, and writes into BUILD, here build/ and
# build/test/. join.py puts the demo in the ROM's image at the monitor's
# DEMO.

PYTHON  ?= python3
NICE_CPU = ../nice_cpu
EMU      = $(NICE_CPU)/emulator/zig-out/bin/niceemu
MONITOR  = ../monitor
DEMO     = $(NICE_CPU)/demo
BUILD    = build
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo unknown)
TEXT     = $(abspath text.nasm)

# The demo's Makefile, with the board's text, into a directory here
DEMO_MAKE = $(MAKE) -s --no-print-directory -C $(DEMO) TEXT='$(TEXT)'

.PHONY: all test clean FORCE

all: $(BUILD)/rom.bin

# The demo, with the version, built by its Makefile, which writes it only
# when it changes, so that a bitstream with it is not built again for
# nothing
$(BUILD)/demo.bin: FORCE | $(BUILD)
	@$(DEMO_MAKE) BUILD='$(abspath $(BUILD))' VERSION='$(VERSION)' '$(abspath $@)'

# The same with the version of the tests, V9.9, so that their screens do
# not change with every commit, and with a wrong word in the math unit's
# test, which the self-test then shows as failed
$(BUILD)/test/demo_test.bin: FORCE | $(BUILD)
	@$(DEMO_MAKE) BUILD='$(abspath $(BUILD)/test)' VERSION=V9.9 '$(abspath $(BUILD)/test/demo.bin)'
	@cmp -s $(BUILD)/test/demo.bin $@ || cp $(BUILD)/test/demo.bin $@

$(BUILD)/test/demo_fail.bin: $(BUILD)/test/demo_test.bin
	@sed 's/^\( *\.DAT *2, M_SMULH, \)-1$$/\1-2/' $(BUILD)/test/demo_all.nasm \
	  > $(BUILD)/test/demo_fail_all.nasm
	@! cmp -s $(BUILD)/test/demo_all.nasm $(BUILD)/test/demo_fail_all.nasm
	@$(PYTHON) $(NICE_CPU)/assembler/niceasm.py -o $@ $(BUILD)/test/demo_fail_all.nasm

# The monitor, with the same version, and the monitor of the tests, built
# by the monitor's Makefile, once each, also under make -j
$(MONITOR)/build/monitor.bin: FORCE
	@$(MAKE) -s --no-print-directory -C $(MONITOR) VERSION='$(VERSION)' build/monitor.bin

$(MONITOR)/build/monitor_test.bin: FORCE
	@$(MAKE) -s --no-print-directory -C $(MONITOR) build/monitor_test.bin

# The monitor and the demo behind it. Written only when it changes, so
# that a bitstream with it is not built again for nothing.
$(BUILD)/rom.bin: $(MONITOR)/build/monitor.bin $(BUILD)/demo.bin join.py
	@$(PYTHON) join.py $(MONITOR)/build/monitor.bin $(BUILD)/demo.bin -o $@.new
	@cmp -s $@.new $@ && rm $@.new || { mv $@.new $@; echo "join.py -> $@"; }

# The ROMs of the tests, which make hwtest loads at 0 too
$(BUILD)/rom_%.bin: $(MONITOR)/build/monitor_test.bin $(BUILD)/test/demo_%.bin join.py
	@$(PYTHON) join.py $(MONITOR)/build/monitor_test.bin $(BUILD)/test/demo_$*.bin -o $@

# nice_cpu's own test runs the demo, behind its stand-in for a monitor.
# This one checks the join, with two inputs. In the first, the monitor's
# x runs the demo, which shows the board's text and the version V9.9,
# and takes what is typed, and halts at the end of the input. In the
# second, F12 returns to the monitor, which clears the screen and says
# that the demo returned 0, and v shows the monitor's version, and h
# halts.
TEST1 = x\rHello, NiceMonMEGA65!
TEST2 = x\rabc\033[24~v\rh\r

test: $(BUILD)/rom_test.bin
	@printf '$(TEST1)' > $(BUILD)/test1.txt
	@printf '$(TEST2)' > $(BUILD)/test2.txt
	@for t in 1 2; do \
	  $(EMU) -s --step-time -i $(BUILD)/test$$t.txt $(BUILD)/rom_test.bin > $(BUILD)/test$$t.out || \
	    { echo "FAIL demo: niceemu exits with $$? on input $$t"; exit 1; }; \
	  sed -n '/^Screen:/,$$p' $(BUILD)/test$$t.out; \
	done > $(BUILD)/test.screen; \
	if cmp -s test.expected $(BUILD)/test.screen; then echo "PASS demo"; \
	else echo "FAIL demo"; diff test.expected $(BUILD)/test.screen; exit 1; fi

$(BUILD):
	@mkdir -p $@

clean:
	rm -rf $(BUILD)
