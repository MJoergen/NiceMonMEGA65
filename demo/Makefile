# Builds the demo of the ROM, demo.nasm, into build/demo.bin, for
# make r6 ROM=demo/build/demo.bin and the release (tools/release.py).
#
# make          builds build/demo.bin, with VERSION in its title bar, git
#               describe of the tree by default; the release gives its tag
# make test     runs the demo in niceemu twice, with the inputs below, and
#               compares the two screens with test.expected
# make clean    removes build/
#
# The assembler has no include, so build/version.nasm, which defines the
# label VERSION, is joined to demo.nasm.

PYTHON  ?= python3
NICE_CPU = ../nice_cpu
ASM      = $(PYTHON) $(NICE_CPU)/assembler/niceasm.py
ASM_PY   = $(wildcard $(NICE_CPU)/assembler/*.py)
EMU      = $(NICE_CPU)/emulator/zig-out/bin/niceemu
BUILD    = build
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo unknown)

.PHONY: all test clean FORCE

all: $(BUILD)/demo.bin

$(BUILD)/demo.bin: demo.nasm $(BUILD)/version.nasm $(ASM_PY)
	@cat demo.nasm $(BUILD)/version.nasm > $(BUILD)/demo_all.nasm
	$(ASM) -o $@ $(BUILD)/demo_all.nasm

# Written only when the version changes, so that the demo is not
# assembled again, and a bitstream with it not built again, for nothing.
$(BUILD)/version.nasm: FORCE | $(BUILD)
	@echo "VERSION .ASCII_L '$(VERSION)'" | cmp -s - $@ || \
	  echo "VERSION .ASCII_L '$(VERSION)'" > $@

# The test has a version of its own, so that its screen does not change
# with every commit.
$(BUILD)/demo_test.bin: demo.nasm $(ASM_PY) | $(BUILD)
	@(cat demo.nasm; echo "VERSION .ASCII_L 'V9.9'") > $(BUILD)/demo_test_all.nasm
	@$(ASM) -o $@ $(BUILD)/demo_test_all.nasm

# The first input edits: a DEL, a TAB, a CR LF, the cursor keys, a
# line longer than 80 characters, an ESC without [, a sequence with
# parameters, a byte of 0x80 to 0x9F, which is dropped, and one of
# ISO 8859-1, which niceemu shows as a blank. The second clears what it
# typed, deletes at the first column, and scrolls by three rows, the last
# with a TAB past the last column. dash's printf, the shell of make on
# Ubuntu, has no \x.
TEST1 = Hello, world!\nabc\177\177X\tY\r\n$(shell printf '0123456789%.0s' 1 2 3 4 5 6 7 8)abcde\n\
\033[A\033[A\033[DQ\033[C\033[BR\n\033x\033[1;5Cy\200\351z\n

test: $(BUILD)/demo_test.bin
	@printf '$(TEST1)' > $(BUILD)/test1.txt
	@{ printf 'junk\014\177'; for i in $$(seq 16); do printf 'line %d\n' $$i; done; \
	  printf 'first\tA\t\t\t\t\t\t\t\t\t\tB'; } > $(BUILD)/test2.txt
	@for t in 1 2; do \
	  $(EMU) -s -i $(BUILD)/test$$t.txt $(BUILD)/demo_test.bin > $(BUILD)/test$$t.out || \
	    { echo "FAIL demo: niceemu exits with $$? on input $$t"; exit 1; }; \
	  sed -n '/^Screen:/,$$p' $(BUILD)/test$$t.out; \
	done > $(BUILD)/test.screen; \
	if cmp -s test.expected $(BUILD)/test.screen; then echo "PASS demo"; \
	else echo "FAIL demo"; diff test.expected $(BUILD)/test.screen; exit 1; fi

$(BUILD):
	@mkdir -p $@

clean:
	rm -rf $(BUILD)
