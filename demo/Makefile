# Builds nice_cpu's demo (nice_cpu/demo), with the board's text,
# text.nasm, into build/demo.bin, a program under the monitor at 0x8000,
# which a user copies to the card's folder NICE and starts with the
# monitor's load demo.bin and r (issue #129). The release ships it as an
# asset of its own (tools/release.py).
#
# make          builds build/demo.bin, with VERSION in the demo's title
#               bar, git describe of the tree by default; the release
#               gives its tag
# make test     runs the monitor of the tests and the demo in niceemu,
#               with r and a few keys, and with F12 and the monitor's v
#               and h after them, and compares the screens with
#               test.expected
# make clean    removes build/
#
# The demo itself, its source and its tests, are nice_cpu's: a change to
# it reaches the boards only with a tag of nice_cpu. Its Makefile joins
# TEXT after demo.nasm, and writes into BUILD, here build/ and
# build/test/.

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

.PHONY: all test romsize clean FORCE

all: $(BUILD)/demo.bin

# The demo, with the version, built by its Makefile, which writes it only
# when it changes
$(BUILD)/demo.bin: FORCE | $(BUILD)
	@$(DEMO_MAKE) BUILD='$(abspath $(BUILD))' VERSION='$(VERSION)' '$(abspath $@)'

# The same with the version of the tests, V9.9, so that their screens do
# not change with every commit
$(BUILD)/test/demo_test.bin: FORCE | $(BUILD)
	@$(DEMO_MAKE) BUILD='$(abspath $(BUILD)/test)' VERSION=V9.9 '$(abspath $(BUILD)/test/demo.bin)'
	@cmp -s $(BUILD)/test/demo.bin $@ || cp $(BUILD)/test/demo.bin $@

# The monitor of the tests, built by the monitor's Makefile
$(MONITOR)/build/monitor_test.bin: FORCE
	@$(MAKE) -s --no-print-directory -C $(MONITOR) build/monitor_test.bin

# The monitor of the tests with the demo at 0x8000 after it, which
# niceemu runs from 0, and make hwtest loads at 0 too (.bin files are
# text, so cat joins them)
$(BUILD)/test/monitor_demo.bin: $(MONITOR)/build/monitor_test.bin $(BUILD)/test/demo_test.bin
	@cat $^ > $@

# nice_cpu's own test runs the demo, behind its stand-in for a monitor.
# This one runs it under the monitor, with two inputs. In the first, the
# monitor's r runs the demo, which shows the board's text and the
# version V9.9, and takes what is typed, and halts at the end of the
# input. In the second, F12 returns to the monitor, which clears the
# screen and says that the demo returned 0, and v shows the monitor's
# version, and h halts.
TEST1 = r\rHello, NiceMonMEGA65!
TEST2 = r\rabc\033[24~v\rh\r

test: $(BUILD)/test/monitor_demo.bin
	@printf '$(TEST1)' > $(BUILD)/test1.txt
	@printf '$(TEST2)' > $(BUILD)/test2.txt
	@for t in 1 2; do \
	  $(EMU) -s --step-time -i $(BUILD)/test$$t.txt $(BUILD)/test/monitor_demo.bin > $(BUILD)/test$$t.out || \
	    { echo "FAIL demo: niceemu exits with $$? on input $$t"; exit 1; }; \
	  sed -n '/^Screen:/,$$p' $(BUILD)/test$$t.out; \
	done > $(BUILD)/test.screen; \
	if cmp -s test.expected $(BUILD)/test.screen; then echo "PASS demo"; \
	else echo "FAIL demo"; diff test.expected $(BUILD)/test.screen; exit 1; fi
	@$(ROMSIZE)

# The table of the demo's words in README.md, "Its words", which make
# test checks, and make romsize writes
ROMSIZE  = $(PYTHON) ../tools/romsize.py demo --bin $(BUILD)/test/demo_test.bin \
             --doc README.md $(DEMO)/demo.nasm $(TEXT) $(BUILD)/test/version.nasm

romsize: $(BUILD)/test/demo_test.bin
	@$(ROMSIZE) --write

$(BUILD):
	@mkdir -p $@

clean:
	rm -rf $(BUILD)
