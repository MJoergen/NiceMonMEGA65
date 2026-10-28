# Builds the demo of the ROM, demo.nasm, into build/demo.bin, for
# make r6 ROM=demo/build/demo.bin and the release (tools/release.py).
#
# make          builds build/demo.bin, with VERSION in its title bar, git
#               describe of the tree by default; the release gives its tag
# make test     runs the demo in niceemu nine times, with the inputs below,
#               and compares the nine screens with test.expected
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
# with a TAB past the last column. The third has the function keys: the
# VT220's F1 and xterm's F1 start the typewriter afresh, F2, F8, and
# SHIFT-F6, which have no demo, do nothing, ESC ESC [ A is the cursor up,
# ESC Q is Q, and a sequence that is no key does nothing. The fourth
# starts the key codes, F3, and types a letter, CR, a control code, DEL, a
# cursor key, F10, which has no demo, a cursor key with parameters, a byte
# of ISO 8859-1 and one of 0x80 to 0x9F, an ESC alone, a sequence longer
# than the 12 bytes shown, and nine letters: 20 keys, which scroll by
# four rows. The fifth goes from the key codes back to the typewriter,
# which shows no bytes. The sixth starts the characters and colors, F5,
# where letters and F2 do nothing. niceemu shows neither the colors nor
# the characters from 0xA0 on, so the test also has the words of two of
# its rows: the red backgrounds, row 5, and the gray foregrounds, row 20,
# from column 44. The seventh starts the counters, F7, where a letter
# runs the sieve again. niceemu counts each step as a cycle and a
# microsecond, so all the numbers are the same in every run. The eighth
# plays the comet, F9, which takes a key at each tick, so . is a tick
# without a key. The comet waits for the right key, catches the star at
# row 4, column 67, and turns right, down, and left into its tail. A key
# starts a new game, in which the comet goes left, ignores the right key,
# which would turn it back, and hits the frame. The ninth runs the
# self-test, F11, twice, so that the second run starts with what the first
# left. dash's printf, the shell of make on Ubuntu, has no \x.
TEST1 = Hello, world!\nabc\177\177X\tY\r\n$(shell printf '0123456789%.0s' 1 2 3 4 5 6 7 8)abcde\n\
\033[A\033[A\033[DQ\033[C\033[BR\n\033x\033[1;5Cy\200\351z\n
TEST3 = one\033[11~two\n\033OPthree\033OQ\033[19~\033[17;2~ F\n\033\033[Ax\033Q\033[99~
TEST4 = \033ORa\r\003\177\033[A\033[21~\033[1;5C\351\200\033x\033[1;2;3;4;5;6;7;8~bcdefghij
TEST5 = \033ORab\033OPback
TEST6 = \033[15~abc\033OQ
DUMP6 = -d 0xFFFF01BC:36 -d 0xFFFF066C:36
TEST7 = \033[18~x
dots  = $(shell printf '.%.0s' $$(seq $(1)))
TEST8 = \033[20~.\033[C$(call dots,27)\033[A$(call dots,8)\033[C\033[B\033[D.\033[D..\033[C$(call dots,35)

test: $(BUILD)/demo_test.bin
	@printf '$(TEST1)' > $(BUILD)/test1.txt
	@{ printf 'junk\014\177'; for i in $$(seq 16); do printf 'line %d\n' $$i; done; \
	  printf 'first\tA\t\t\t\t\t\t\t\t\t\tB'; } > $(BUILD)/test2.txt
	@printf '$(TEST3)' > $(BUILD)/test3.txt
	@printf '$(TEST4)' > $(BUILD)/test4.txt
	@printf '$(TEST5)' > $(BUILD)/test5.txt
	@printf '$(TEST6)' > $(BUILD)/test6.txt
	@printf '$(TEST7)' > $(BUILD)/test7.txt
	@printf '$(TEST8)' > $(BUILD)/test8.txt
	@printf '\033[23~\033[23~' > $(BUILD)/test9.txt
	@for t in 1 2 3 4 5 6 7 8 9; do \
	  dump=; [ $$t = 6 ] && dump='$(DUMP6)'; \
	  $(EMU) -s -i $(BUILD)/test$$t.txt $$dump $(BUILD)/demo_test.bin > $(BUILD)/test$$t.out || \
	    { echo "FAIL demo: niceemu exits with $$? on input $$t"; exit 1; }; \
	  sed -n -e '/^ffff/p' -e '/^Screen:/,$$p' $(BUILD)/test$$t.out; \
	done > $(BUILD)/test.screen; \
	if cmp -s test.expected $(BUILD)/test.screen; then echo "PASS demo"; \
	else echo "FAIL demo"; diff test.expected $(BUILD)/test.screen; exit 1; fi

$(BUILD):
	@mkdir -p $@

clean:
	rm -rf $(BUILD)
