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
# The monitor must end below DEMO (monitor.nasm), where join.py puts the
# demo and x reads its size, in a ROM of the monitor alone too. niceasm
# writes the words in the order of their addresses, so the last line has
# the last.
DEMO     = $(shell sed -n 's/^DEMO *\.EQU *\(0x[0-9A-Fa-f]*\).*/\1/p' monitor.nasm)
CHECK_END = $(PYTHON) -c 'import sys; top = int(open(sys.argv[1]).read().split()[-2], 16); \
  end = int(sys.argv[2], 16); top < end or sys.exit(f"{sys.argv[1]} reaches {top:08X}, past DEMO, {end:08X}")'

.PHONY: all test fmt clean FORCE

all: $(BUILD)/monitor.bin

$(BUILD)/monitor.bin: $(SOURCES) $(BUILD)/version.nasm $(TOOLS)
	@cat $(SOURCES) $(BUILD)/version.nasm > $(BUILD)/monitor_all.nasm
	$(ASM) -o $@ $(BUILD)/monitor_all.nasm
	@$(CHECK_END) $@ $(DEMO)

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
	@$(CHECK_END) $@ $(DEMO)

# The monitors of the ring test, test/ring.py: the monitor of the tests
# with the size of the screen's memory that the display offset of a board
# would give it, 8192 words on the Nexys4DDR and 2048, which has no room
# for the history, in place of the bits that niceemu keeps, all of them.
# cmp fails the build if sed changed nothing.
MASK_8k = 0x1FFF
MASK_2k = 0x7FF
$(BUILD)/monitor_8k.bin $(BUILD)/monitor_2k.bin: $(BUILD)/monitor_%.bin: $(BUILD)/monitor_test.bin
	@sed 's/^\( *\)AND  *R1, @SCR_OFFS, SCR_MAX$$/\1MOVE    R1, $(MASK_$*)/' \
	  $(BUILD)/monitor_test_all.nasm > $(BUILD)/monitor_$*_all.nasm
	@! cmp -s $(BUILD)/monitor_test_all.nasm $(BUILD)/monitor_$*_all.nasm
	@$(ASM) -o $@ $(BUILD)/monitor_$*_all.nasm

# The programs of the tests, at 0x8000: hello.nasm with the runtime's
# start-up code for a program under a monitor, and hello.c through
# nicebuild, which needs clang.
$(BUILD)/hello.bin: test/hello.nasm monlib.nasm mon.nasm $(RUNTIME)/start_mon.nasm \
                    $(RUNTIME)/lib.nasm $(RUNTIME)/muldiv_mpu.nasm $(TOOLS) | $(BUILD)
	@cat $(RUNTIME)/start_mon.nasm test/hello.nasm monlib.nasm mon.nasm $(RUNTIME)/lib.nasm \
	  $(RUNTIME)/muldiv_mpu.nasm > $(BUILD)/hello_all.nasm
	@$(ASM) -o $@ $(BUILD)/hello_all.nasm

# The test of the sector routines, test/sd.nasm, which calls them by their
# labels, so it is assembled after the monitor's sources, and only its words,
# from 0x8000, are kept: the monitor's are those of monitor_test.bin. The
# addresses below 0x8000 start with 0000 and a digit of 0 to 7.
$(BUILD)/sd.bin: $(BUILD)/monitor_test.bin test/sd.nasm
	@cat $(BUILD)/monitor_test_all.nasm test/sd.nasm > $(BUILD)/sd_all.nasm
	@$(ASM) -o $(BUILD)/sd_full.bin $(BUILD)/sd_all.nasm
	@grep -v '^0000[0-7]' $(BUILD)/sd_full.bin > $@

# The test of the ARP cache, test/arp.nasm, which calls arp_resolve by its
# label, built as sd.bin is
$(BUILD)/arp.bin: $(BUILD)/monitor_test.bin test/arp.nasm
	@cat $(BUILD)/monitor_test_all.nasm test/arp.nasm > $(BUILD)/arp_all.nasm
	@$(ASM) -o $(BUILD)/arp_full.bin $(BUILD)/arp_all.nasm
	@grep -v '^0000[0-7]' $(BUILD)/arp_full.bin > $@

# The words that u disassembles in test/dis.py, at 0x8000, which never run
$(BUILD)/dis.bin: test/dis.nasm $(TOOLS) | $(BUILD)
	@$(ASM) -o $@ test/dis.nasm

$(BUILD)/hello_c.bin: test/hello.c mon.h mon.nasm $(TOOLS) | $(BUILD)
	@$(NICEBUILD) --monitor --asm mon.nasm -I . -o $@ test/hello.c

# The inputs. cmds types each command, with the edits of a line: three DELs
# that take back abc, a CTRL-C that empties junk, and the cursor key ESC [ A
# and the function key ESC O P, which are dropped. D is d, and q is no
# command. x finds no demo in the ROM, r no program, nor r 9000, d 8000 0 only moves
# the next d to 8000, and d 0 100 shows 256 words, which scrolls the
# screen. i shows the IP address, 0.0.0.0, and writes 192.168.1.65; four
# addresses are rejected, with too few numbers, one past 255, an empty
# one, and a letter after them; and the last, with blanks around it and
# a leading zero, is written, which the dump of 0xFFFFFFB0 shows. m shows
# the MAC address, 02:4E:49:43:45:00 after niceemu's reset, and writes
# 02:4E:49:43:45:01; five addresses are rejected, with too few bytes, a
# byte of three digits, a group address, a blank inside, and a letter
# after them; and the last, with blanks around it and bytes of one digit
# in lower case, is written, which the dump of 0xFFFFFFB1-B2 shows. h ends
# each input. dash's printf, the shell of make on Ubuntu, has no \x.
CMDS = ?\rv\rd 0 6\rd\rD 10 1\rq\r\r  c\rabc\177\177\177v\rjunk\003v\r\033[A\033OPv\rx\rr\rr 9000\rd 8000 0\rd 8000\rd 0 100\ri\ri 192.168.1.65\ri 1.2.3\ri 256.0.0.1\ri 1..2.3\ri 1.2.3.4x\ri  010.0.0.1 \rm\rm 02:4E:49:43:45:01\rm 2:4e:49:43:45\rm 2:4e:49:43:45:123\rm 3:0:0:0:0:0\rm 2:4e: 49:43:45:1\rm 2:4e:49:43:45:1x\rm  a:b:c:d:e:f \rh\r
RUN  = r\rh\r
# reset: r 0, the cold start, which shows the banner again and leaves the
# RAM from 0x8000 alone, so that r then runs hello.
RESET = r 0\rr\rh\r
# scroll: Page Up and Page Down with no history, which do nothing; d 8000
# 700, the zeros of the empty RAM, 448 rows, which fill the history of 384
# rows and go round its ring; two Page Ups and a Page Down, which turn the
# ring and show 24 rows back; and v, which shows the screen again.
SCROLL = \033[5~\033[6~d 8000 700\r\033[5~\033[5~\033[6~v\rh\r
# load: l with lines typed and pasted. The l line ends with CR LF, as a
# terminal may end it, which is no empty line. The first line is typed
# with edits: a DEL that takes back 2, the cursor key ESC [ A, which is
# dropped, so it writes 134 at 9000. The RAM has 0x20000 words, as on the
# MEGA65, which build/ram128k.bin writes to 0xFFFFFF9E, so 1EFFF takes a
# word and 1F000, the alias of the monitor's variables, does not. A line
# with TABs for blanks writes 7 at 9002, a line of blanks only is passed
# over, and a second line for 9002 writes 8 over the 7. Six lines are
# skipped: zz, an address in the ROM, one of the monitor's variables, a
# third number, 1F000, and a line of 78 characters, 9003, 66 blanks, and
# 12345678, which is longer than the 76 of a line, so it writes nothing,
# not 123456. Then build/hello.bin,
# its first 3 lines ended by CR LF and the rest by LF, and CR, an empty
# line, ends the load. A second l is ended by CTRL-C in the middle of a
# line, which writes nothing. r runs hello, and d shows 9000 to 9003.
BLANKS66  = $(shell printf '%66s' '')
LOAD_HEAD = l\r\n9000 12\177\033[A34\rzz\r100 5\rFFFFF000 1\r9001 5 6\r1EFFF 9\r1F000 1\r\t9002\t7 \r   \r9002 8\r9003$(BLANKS66)12345678\r
LOAD_TAIL = \rl\r9001 7\003r\rd 9000 4\rd 1EFFF 1\rh\r
# load_emu: l where 0xFFFFFF9E reads 0, as in niceemu, so a program's RAM
# goes up to the screen: 10000 and FFFEFFFF take words, and FFFF0000 does
# not.
LOAD_EMU = l\r10000 7\rFFFEFFFF 8\rFFFF0000 1\r\rd 10000 1\rh\r
# load_64k: l with 0x10000 words of RAM, as on the Nexys4DDR, which
# build/ram64k.bin writes to 0xFFFFFF9E: EFFF takes a word, and F000, the
# monitor's variables, and 1EFFF, past the RAM, do not.
LOAD_64K = l\rEFFF 1\rF000 2\r1EFFF 3\r\rd EFFF 1\rh\r
# sd: the image of test/sd_image.py in slot 0 and none in slot 1. sd 1
# shows the bytes 0 to 255 twice, SD 3 the last sector, and sd 4, after the
# last, is error 7. sd 1 0 is error 1, no card, and so is sd 0, which reads
# in slot 1, the last; sd 0 0 goes back to slot 0, with the 55 AA of sector
# 0. sd 2 0 has no slot 2, and sd alone, sd 1 2 3, sd 1x, and a sector of 9
# digits are no arguments; sdx is no command.
SD   = sd 1\rSD 3\rsd 4\rsd 1 0\rsd 0\rsd 0 0\rsd 2 0\rsd\rsd 1 2 3\rsd 1x\rsd 123456789\rsdx\rh\r
# sd_write: r runs test/sd.nasm, which writes sector 2, and sd 2 shows it.
SD_WRITE = r\rsd 2\rh\r

# The words of each test that are dumped with the screen: for cmds the
# variables, the cursor's registers, and the IP and MAC addresses, and for the programs the text at
# column 40 of row 4, 80 * 4 + 40 = 360 = 0x168, with its color, and for
# hello the 0x80 after it, the screen's state, in which the return showed
# the cursor that hello hid, the font base, which the return made 0, and
# the row of the glyph of 0x80 that hello drew.
DUMP_cmds    = -d 0xFFFFF000:5 -d 0xFFFFFF80:6 -d 0xFFFFFFB0:3
# For scroll the variables and the screen's registers, and the last four
# digits of the address that starts a row of the history (the words 4 to
# 7 of the row): the rows of 869C and 8698 that Page Up turned to slots 0
# and 1, the row of 86A0 in slot 383, the first of the four rows that v
# and h added at the bottom of the ring, and the oldest, of 80B0, in slot
# 379.
DUMP_scroll  = -d 0xFFFFF000:11 -d 0xFFFFFF80:6 -d 0xFFFF7FB4:4 -d 0xFFFF7F64:4 \
               -d 0xFFFF0804:4 -d 0xFFFF0944:4
DUMP_hello   = -d 0xFFFF0168:13 -d 0xFFFFFF80:1 -d 0xFFFFFF86:1 -d 0xFFFE1000:1
DUMP_load    = -d 0xFFFFF000:15
DUMP_load_emu = -d 0xFFFFF00E:1 -d 0xFFFEFFFF:1
DUMP_load_64k = -d 0xFFFFF00E:1
DUMP_hello_c = -d 0xFFFF0168:12
# For sd the controller's registers, SD_CSR to SD_SLOTS, and for sd_write
# the results of test/sd.nasm's calls
DUMP_sd       = -d 0xFFFFFFA0:7
DUMP_sd_write = -d 0x9100:6
# For arp the results of test/arp.nasm's calls, and the cache it copied
DUMP_arp      = -d 0x9100:37
MAX_STEPS = 10000000

# Each test runs the monitor with its input and its program, if any, and
# compares the console output, the dumps, and the screen with
# test/NAME.expected. The Halted line and the registers are left out, as
# the steps and the registers change with the code, but for VBASE, bits
# 23-0 of R14, which must be 0, also after hello, which returns with
# VBASE 0x80, and so tests that a program returns to mon_exit. hello_c
# is skipped without clang. test/ring.py checks the ring of the history at the
# sizes of the screen's memory of niceemu and the boards first, and
# test/dis.py the rows of u against nicedis.py and niceasm, and
# test/dhcp.py runs i dhcp against the frames that it builds. arp runs
# with --step-time, as its timeouts count, and the frames it sends are
# added to its output.
test: fmt $(BUILD)/monitor_test.bin $(BUILD)/monitor_8k.bin $(BUILD)/monitor_2k.bin $(BUILD)/hello.bin \
      $(BUILD)/dis.bin $(BUILD)/sd.bin $(BUILD)/arp.bin
	@$(PYTHON) test/ring.py $(EMU) $(BUILD)/monitor_test.bin:32768 \
	  $(BUILD)/monitor_8k.bin:8192 $(BUILD)/monitor_2k.bin:2048
	@$(PYTHON) test/dis.py $(EMU) $(BUILD)/monitor_test.bin $(BUILD)/dis.bin
	@$(PYTHON) test/dhcp.py $(EMU) $(BUILD)/monitor_test.bin test/dhcp.expected $(BUILD)/dhcp.out
	@echo 'FFFFFF9E 00020000' > $(BUILD)/ram128k.bin
	@echo 'FFFFFF9E 00010000' > $(BUILD)/ram64k.bin
	@printf '$(LOAD_EMU)' > $(BUILD)/load_emu.txt
	@printf '$(LOAD_64K)' > $(BUILD)/load_64k.txt
	@printf '$(CMDS)' > $(BUILD)/cmds.txt
	@printf '$(RUN)' > $(BUILD)/run.txt
	@printf '$(RESET)' > $(BUILD)/reset.txt
	@printf '$(SCROLL)' > $(BUILD)/scroll.txt
	@printf '$(SD)' > $(BUILD)/sd.txt
	@printf '$(SD_WRITE)' > $(BUILD)/sd_write.txt
	@$(PYTHON) test/sd_image.py $(BUILD)/sd.img
	@$(PYTHON) test/sd_image.py --written $(BUILD)/sd_written.img
	@{ printf '$(LOAD_HEAD)'; head -n 3 $(BUILD)/hello.bin | awk '{ printf "%s\r\n", $$0 }'; \
	  tail -n +4 $(BUILD)/hello.bin; printf '$(LOAD_TAIL)'; } > $(BUILD)/load.txt
	@fail=0; for t in cmds scroll load load_emu load_64k sd sd_write arp hello reset hello_c; do \
	  opts=; \
	  case $$t in \
	    cmds) prog=; input=cmds; dump='$(DUMP_cmds)';; \
	    scroll) prog=; input=scroll; dump='$(DUMP_scroll)';; \
	    load) prog=$(BUILD)/ram128k.bin; input=load; dump='$(DUMP_load)';; \
	    load_emu) prog=; input=load_emu; dump='$(DUMP_load_emu)';; \
	    load_64k) prog=$(BUILD)/ram64k.bin; input=load_64k; dump='$(DUMP_load_64k)';; \
	    sd) prog=; input=sd; dump='$(DUMP_sd)'; opts="--sd0 $(BUILD)/sd.img";; \
	    sd_write) prog=$(BUILD)/sd.bin; input=sd_write; dump='$(DUMP_sd_write)'; \
	      cp $(BUILD)/sd.img $(BUILD)/sd_write.img; opts="--sd0 $(BUILD)/sd_write.img";; \
	    arp) prog=$(BUILD)/arp.bin; input=run; dump='$(DUMP_arp)'; \
	      opts="--step-time --eth-in test/arp.eth --eth-out $(BUILD)/arp.eth.out";; \
	    hello) prog=$(BUILD)/hello.bin; input=run; dump='$(DUMP_hello)';; \
	    reset) prog=$(BUILD)/hello.bin; input=reset; dump='$(DUMP_hello)';; \
	    hello_c) prog=$(BUILD)/hello_c.bin; input=run; dump='$(DUMP_hello_c)'; \
	      if ! command -v $(CLANG) > /dev/null; then echo "SKIP monitor $$t: no $(CLANG)"; continue; fi; \
	      $(MAKE) --no-print-directory $$prog || exit 1;; \
	  esac; \
	  cat $(BUILD)/monitor_test.bin $$prog > $(BUILD)/$$t.full.bin; \
	  $(EMU) -s -n $(MAX_STEPS) -i $(BUILD)/$$input.txt $$dump $$opts $(BUILD)/$$t.full.bin \
	    > $(BUILD)/$$t.raw; status=$$?; \
	  { sed -e '/^Halted (HALT)/,/^R12 /d' $(BUILD)/$$t.raw; \
	    sed -n 's/.* R14 ..\(......\) .*/VBASE at the halt \1/p' $(BUILD)/$$t.raw; \
	    echo "exit $$status"; \
	    if [ $$t = sd_write ]; then cmp $(BUILD)/sd_written.img $(BUILD)/sd_write.img 2>&1 \
	      && echo "The image as test/sd_image.py --written makes it"; fi; \
	    if [ $$t = arp ]; then echo "Frames sent:"; cat $(BUILD)/arp.eth.out; fi; } \
	    > $(BUILD)/$$t.out; \
	  if cmp -s test/$$t.expected $(BUILD)/$$t.out; then echo "PASS monitor $$t"; \
	  else echo "FAIL monitor $$t"; diff test/$$t.expected $(BUILD)/$$t.out; fail=1; fi; \
	done; exit $$fail

# The layout of the sources, as nice_cpu's nicefmt checks it
fmt:
	@$(FMT) $(SOURCES) test/hello.nasm test/dis.nasm test/sd.nasm test/arp.nasm

$(BUILD):
	@mkdir -p $@

clean:
	rm -rf $(BUILD)
