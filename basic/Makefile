# Builds BASIC's image of the ROM (basic.nasm's header, issue #152), and
# tests BASIC's statements in niceemu.
#
# make          builds build/basic_image.bin, with VERSION in its banner,
#               git describe of the tree by default; the release gives its
#               tag. make build/rom.bin at the top joins it with the
#               monitor's.
# make test     checks the layout of the sources, and runs the ROM of the
#               tests, ../build/rom_test.bin, in niceemu with the inputs
#               below, and compares the output with test/*.expected
# make clean    removes build/
#
# ../rom.mk has the ROM: its two images, assembled apart, their sources,
# VERSION, and FOLDER. This image is the cat of BAS_SOURCES (basic.nasm,
# the files that its header lists, and its copies of the monitor's
# common.nasm, monlib.nasm, and mon.nasm), build/version.nasm, and
# build/basic_folder.nasm, its texts with the folder FOLDER's name. It
# starts at BASIC_BASE, 0x4000, with the two vectors that the monitor
# jumps to. The tests here are those of BASIC's statements, their
# scanner, LOAD's lines, TIME, DIS, NTP, and TFTP; ../monitor/Makefile
# has those of the monitor's code, and builds what these tests share
# with it: hello.bin, the cards' images, and the scripts of
# ../monitor/test.

PYTHON  ?= python3
ROOT     = ..
include $(ROOT)/rom.mk
NICE_CPU = ../nice_cpu
ASM      = $(ROM_ASM)
FMT      = $(PYTHON) $(NICE_CPU)/assembler/nicefmt.py
EMU      = $(NICE_CPU)/emulator/zig-out/bin/niceemu
TOOLS    = $(ROM_TOOLS)
BUILD    = build
ROM_TEST = $(ROOT)/build/rom_test.bin
MON      = $(ROOT)/monitor
MON_TEST = $(MON)/test
FOLDER_TEXTS = ($(call PACKED,E_FS29,no folder $(FOLDER_UC) on the card); \
  $(call PACKED,S_DIROF,Directory of $(FOLDER_UC)))

.PHONY: all test fmt clean

all: $(BUILD)/basic_image.bin

# The image, and that of the tests, with the version V9.9
$(BUILD)/basic_image.bin $(BUILD)/basic_image_test.bin: $(BUILD)/basic_image%.bin: \
    $(BAS_SOURCES) $(BUILD)/version%.nasm $(BUILD)/basic_folder.nasm $(ROM_TOOLS) | $(BUILD)
	@$(CHECK_TEXTS) $(filter-out $(SHARED),$(BAS_SOURCES))
	@cat $(BAS_SOURCES) $(BUILD)/basic_folder.nasm $(BUILD)/version$*.nasm > $(BUILD)/basic$*_all.nasm
	@$(ASM) -o $@ $(BUILD)/basic$*_all.nasm
	@$(CHECK_END) $@ $(ROM_END)

$(BUILD)/version.nasm: FORCE | $(BUILD)
	@$(call WRITE_NEW,$(VERSION_TEXT),$@)

$(BUILD)/version_test.nasm: FORCE | $(BUILD)
	@$(call WRITE_NEW,$(VERSION_TEST),$@)

$(BUILD)/basic_folder.nasm: FORCE | $(BUILD)
	@$(call WRITE_NEW,$(FOLDER_TEXTS),$@)

# What the tests share with the monitor's: hello.bin, which load loads,
# and the card that time writes, super.img of ../monitor/test/fat_image.py
$(MON)/build/hello.bin $(MON)/build/fat/super.img: FORCE
	@$(MAKE) -s --no-print-directory -C $(MON) $(@:$(MON)/%=%)

# The words that u disassembles in test/dis.py, at 0x8000, which never run
$(BUILD)/dis.bin: test/dis.nasm $(TOOLS) | $(BUILD)
	@$(ASM) -o $@ test/dis.nasm

# The inputs, each a line of BASIC's statements (doc/BASIC.md, issue
# #112). cmds types each statement, and its bad arguments, with the edits
# of a line: three DELs that take back abc, a CTRL-C that empties junk,
# and the cursor key ESC [ A and the function key ESC O P, which are
# dropped. An empty line and one of blanks run nothing and print no
# READY. DUMP is dump, in either case, q is no statement, and loadx no
# LOAD. sys finds no program at 0x8000, nor at 0x9000, dump 0x8000, 0
# only moves the next dump to 0x8000, and dump 0, 256 shows 256 words,
# which scrolls the screen. ip shows the IP address, 0.0.0.0, and writes
# 192.168.1.65; four addresses are rejected, with too few numbers, one
# past 255, an empty one, and a letter after them; and the last, with
# blanks around it and a leading zero, is written, which the dump of
# 0xFFFFFFB0 shows. mac shows the MAC address, 02:4E:49:43:45:00 after
# niceemu's reset, and writes 02:4E:49:43:45:01; five addresses are
# rejected, with too few bytes, a byte of three digits, a group address,
# a blank inside, and a letter after them; and the last, with blanks
# around it and bytes of one digit in lower case, is written, which the
# dump of 0xFFFFFFB1-B2 shows. baud shows the rate, 0 in niceemu, and
# writes 921600; 9600 is not in the list, and the last, in upper case
# with blanks around it, is written, which the dump of 0xFFFFFF9F shows.
# Then the lines that are no statements, each a Syntax error with the
# lines of HELP of its statement: an address without its quotes, sys
# alone, 0x without digits, a number with a letter after it, dump with a
# comma and no count, two numbers without a comma, a word after ver, and
# a string after load's that is no IP address. A number of 33 bits, in
# decimal and in hex, is an Illegal quantity. LOAD takes a .BIN name
# only, and SAVE no TFTP server, which needs no card; a keyword in mixed
# case, the closing quote left out, and dump , 2, which goes on from
# the last. halt ends each input. dash's printf, the shell of make on
# Ubuntu, has no \x.
CMDS = help\rver\rdump 0, 6\rdump\rDUMP 0x10, 1\rq\rloadx\r\r  cls\rabc\177\177\177ver\rjunk\003ver\r\033[A\033OPver\rsys 0x8000\rsys 0x9000\rdump 0x8000, 0\rdump 0x8000\rdump 0, 256\rip\rip "192.168.1.65"\rip "1.2.3"\rip "256.0.0.1"\rip "1..2.3"\rip "1.2.3.4x"\rip "  010.0.0.1 "\rmac\rmac "02:4E:49:43:45:01"\rmac "2:4e:49:43:45"\rmac "2:4e:49:43:45:123"\rmac "3:0:0:0:0:0"\rmac "2:4e: 49:43:45:1"\rmac "2:4e:49:43:45:1x"\rmac "  a:b:c:d:e:f "\rbaud\rbaud 921600\rbaud 9600\rBAUD  115200 \rip 1.2.3.4\rsys\rsys 0x\rdump 12ab\rdump 1,\rbaud 1 2\rver x\rload "a.bin" "1.2.3.4"\rdump 4294967296\rdump 0x100000000\rload "x.txt"\rload "x"\rsave "x", "1.2.3.4"\rHeLp x\rload "x.bin\rdump , 2\rhalt\r
# basic: the scanner of a line, with no card and no IP address, so that
# the statements that need them stop at once. A keyword in mixed case and
# with blanks around it runs; a comma, a character of 0xE9, or another
# word after it, or a letter, a digit, or an _ glued to it, makes it no
# statement, or a Syntax error with its lines of HELP, which each
# statement shows. Numbers: in decimal and hex, with 0X, leading zeros,
# and the 76 characters of a full line; 0xFFFFFFFF, the largest, and 33
# bits, which are an Illegal quantity, also with a letter after them;
# and the numbers that are not. 0x without digits is no number, and the
# scan goes on at its 0, so dump 0x, 1, dis 0x, 1, baud 0x, and
# dir 0x"1.2.3.4" are a Syntax error, and dir 99999999999"1.2.3.4" an
# Illegal quantity (issue #151, S1 and S2). save "x", "y", 99999999999
# is a Syntax error at its second comma, before its number (S3), and
# mac "" is no MAC address, as ip "" is no IP address (S5). Strings: an empty one, a name glued to load, a server
# without a comma, or with no closing quote, and the arguments that are
# too few or too many for each statement. The dumps of the line after
# five statements show the 0 at each closing quote, those of a statement
# that failed too, and the .BIN that save adds to a name without a dot,
# last in a line of 76 characters. ip "1.2.3.4, with no closing quote,
# writes the IP address, which the dump of 0xFFFFFFB0 shows.
BLANKS30 = $(shell printf '%30s' '')
BLANKS62 = $(shell printf '%62s' '')
ZEROS72  = $(shell printf '%072d' 32768)
BASIC = vEr\r   ver   \rver,\rver\351\r\351ver\rsys0x8000\rdumpx\rdum\rdis1\ri\rsys_\r"ver"\r9 ver\rsave x\rdelete x\rdhcp x\rmac x\rtime x\rntp x\rdis x\rcls x\rhalt x\rdir x\rsys 32768\rsys $(ZEROS72)\rSYS 0X8000\rsys 0x08000\rsys 4294967295\rsys 0xFFFFFFFF\rsys 0x0000000ffffffff\rsys 4294967296\rsys 0x100000000\rsys 99999999999x\rsys 0x8000x\rsys 0x0x8000\rsys 1e3\rsys 32768.\rsys -1\rsys "x"\rsys 0xg\rsys 0x8000,\rdump 0x8000, 0\rdump 0x, 1\rdump 0x , 2\rdump 0x 1\rdump 1, 4294967296\rdump 1, 0x\rdis 0x8000, 1\rdis 0x, 1\rdis ,1\rdis 0x8000,\rbaud 0x\rbaud 0x 1\rbaud 4294967296\rbaud 1,\rbaud 0x1C200\rload ""\rload ".bin"\rload"a.BiN"\rload "a.bin",\rload "a.bin" ,"1.2.3.4"\rload "a.bin", "1.2.3.4" x\rload "a.bin", "bad"\rload x\rload "a.bin", "1.2.3.4\rLOAD  \r\rsave "x", "y" z\rsave "x" "y"\rsave "x",\rsave "x", 1\rsave "x", 0x, 1\rsave "x", 1, 99999999999\rsave "x", "y", 99999999999\rsave "abc\rsave "a.b", 0x8000, 1\rdelete "x"\rdelete "x", "y"\rdelete ""\rdir\rdir 0x\rdir 0x"1.2.3.4"\rdir 99999999999"1.2.3.4"\rdir 99999999999\rdir "1.2.3.4", "*.bin"\rdir "bad"\rdir "1.2.3.4",\rdir 1,\rdir 1 "x"\rdir 5\rip ""\rip "1.2.3.4" x\rmac ""\rmac "02:4E:49:43:45:00" x\rtime "bad"\rtime "1" x\rntp "1.2.3.4" x\rntp "1.2.3.4",\rntp "", "bad"\rntp ""\rntp "1.2.3.4", "+01:00"\r$(BLANKS30)save "abc",1,2\rdump 0xFFFFE85E, 16\r$(BLANKS30)load "x" "y"\rdump 0xFFFFE85E, 16\r$(BLANKS30)save "x", "1.2.3.4"\rdump 0xFFFFE85E, 20\r$(BLANKS30)save "a.b", 1, 2\rdump 0xFFFFE85E, 16\r$(BLANKS30)dir "1.2.3.4", "*"\rdump 0xFFFFE85E, 20\r$(BLANKS62)save "abc",1,2\rdump 0xFFFFE87E, 16\rip "1.2.3.4\rhalt\r
# load: LOAD with lines typed and pasted. The LOAD line ends with CR LF,
# as a terminal may end it, which is no empty line. The first line is typed
# with edits: a DEL that takes back 2, the cursor key ESC [ A, which is
# dropped, so it writes 134 at 9000. The RAM has 0x20000 words, as on the
# MEGA65, which build/ram128k.bin writes to 0xFFFFFF9E, so 1E7FF takes a
# word and 1E800, the alias of the variables, BASIC's first, does not. A line
# with TABs for blanks writes 7 at 9002, a line of blanks only is passed
# over, and a second line for 9002 writes 8 over the 7. Six lines are
# skipped: zz, an address in the ROM, one of the monitor's variables, a
# third number, 1E800, and a line of 78 characters, 9003, 66 blanks, and
# 12345678, which is longer than the 76 of a line, so it writes nothing,
# not 123456. Pasted lines after it: one of 100 blanks, which is passed
# over; 1E7FF A and 90 blanks, which writes A over the 9, as the blanks
# after the 76 characters are dropped; and 9001, 71 blanks, 3, and z,
# whose z past the 76 is taken back by a DEL, so it writes 3 at 9001.
# Then build/hello.bin,
# its first 3 lines ended by CR LF and the rest by LF, and CR, an empty
# line, ends the load. A second LOAD is ended by CTRL-C in the middle of
# a line, which writes nothing. sys 0x8000 runs hello, and dump shows
# 9000 to 9003.
BLANKS66  = $(shell printf '%66s' '')
BLANKS71  = $(shell printf '%71s' '')
BLANKS90  = $(shell printf '%90s' '')
BLANKS100 = $(shell printf '%100s' '')
LOAD_HEAD = load\r\n9000 12\177\033[A34\rzz\r100 5\rFFFFF000 1\r9001 5 6\r1E7FF 9\r1E800 1\r\t9002\t7 \r   \r9002 8\r9003$(BLANKS66)12345678\r$(BLANKS100)\r1E7FF A$(BLANKS90)\r9001$(BLANKS71)3z\177\r
LOAD_TAIL = \rload\r9001 7\003sys 0x8000\rdump 0x9000, 4\rdump 0x1E7FF, 1\rhalt\r
# load_emu: LOAD where 0xFFFFFF9E reads 0, as in niceemu, so a program's RAM
# goes up to the screen: 10000 and FFFEFFFF take words, and FFFF0000 does
# not.
LOAD_EMU = load\r10000 7\rFFFEFFFF 8\rFFFF0000 1\r\rdump 0x10000, 1\rhalt\r
# load_64k: LOAD with 0x10000 words of RAM, as on the Nexys4DDR, which
# build/ram64k.bin writes to 0xFFFFFF9E: E7FF takes a word, and E800, the
# variables, BASIC's first, and 1EFFF, past the RAM, do not.
LOAD_64K = load\rE7FF 1\rE800 2\r1EFFF 3\r\rdump 0xE7FF, 1\rhalt\r
# time: with --step-time, so the clock starts at 0, not set, and counts a
# microsecond a step, and a copy of super.img in slot 0, each date and
# time in quotes. time shows that
# it is not set, and save writes old.bin with the fixed date. time sets
# 2026-11-11 14:30:01, which time shows, and save writes new.bin with it,
# at 14:30:00 and 100 hundredths. Fifteen times are rejected: 2023-02-29
# and 2100-02-29, as those years have no leap day, 1969 and 2106, before
# and after the years time sets, month 13, November 31, hour 24, minute
# 60, second 60, a year of two digits, a month and a day of one digit, no
# time, a word after it, an hour of three digits, and a time of one
# digit each; timex and ti are no statements. Then the edges that are
# taken: 2000-02-29, 2100-03-01, 2104-02-29, the second past 2^31, and
# the last of 2105. A date and a time with blanks around them in the
# quotes is taken; month 0, day 0, a letter for a digit, and the wrong
# separators are not, and time shows the clock that they left alone. Then
# 2024-02-29, the last day of 2024, a leap year, 2100-02-28, the last of
# 2099, and an empty string, which shows the clock. Last the first of
# 1970, in upper case with blanks, whose year FAT cannot hold, so save
# writes y1970.bin with the fixed date.
TIME = time\rload\r8000 1\r\rsave "old.bin", 0x8000, 1\rtime "2026-11-11 14:30:01"\rtime\rsave "new.bin", 0x8000, 1\rtime "2023-02-29 00:00:00"\rtime "2100-02-29 00:00:00"\rtime "1969-12-31 23:59:59"\rtime "2106-01-01 00:00:00"\rtime "2026-13-01 00:00:00"\rtime "2026-11-31 00:00:00"\rtime "2026-11-11 24:00:00"\rtime "2026-11-11 23:60:00"\rtime "2026-11-11 23:59:60"\rtime "26-11-11 00:00:00"\rtime "2026-1-1 00:00:00"\rtime "2026-11-11"\rtime "2026-11-11 01:02:03 x"\rtime "2026-11-11 001:02:03"\rtime "2026-11-11 1:2:3"\rtimex\rti\rtime "2000-02-29 00:00:00"\rtime "2100-03-01 00:00:00"\rtime "2104-02-29 12:00:00"\rtime "2038-01-19 03:14:08"\rtime "2105-12-31 23:59:59"\rtime "  2026-11-11 14:30:01  "\rtime "2026-00-10 00:00:00"\rtime "2026-11-00 00:00:00"\rtime "2O26-11-11 00:00:00"\rtime "2026/11/11 00:00:00"\rtime "2026-11-11T00:00:00"\rtime "2026-11-11 00.00.00"\rtime\rtime "2024-02-29 00:00:00"\rtime "2024-12-31 23:59:59"\rtime "2100-02-28 23:59:59"\rtime "2099-12-31 23:59:59"\rtime ""\rTIME  "1970-01-01 00:00:00" \rsave "y1970.bin", 0x8000, 1\rhalt\r
# The words of each test that are dumped with the screen: for cmds the
# variables, the cursor's registers, and the IP and MAC addresses
DUMP_cmds    = -d 0xFFFFF000:4 -d 0xFFFFE800:2 -d 0xFFFFFF80:6 -d 0xFFFFFF9F:1 -d 0xFFFFFFB0:3
DUMP_basic   = -d 0xFFFFF000:4 -d 0xFFFFE800:2 -d 0xFFFFFFB0:1
DUMP_load    = -d 0xFFFFF000:4 -d 0xFFFFF005:6 -d 0xFFFFE800:5
DUMP_load_emu = -d 0xFFFFE812:1 -d 0xFFFEFFFF:1
DUMP_load_64k = -d 0xFFFFE812:1
MAX_STEPS = 10000000

# Each test runs the ROM with its input, and compares the console output,
# the dumps, and the screen with test/NAME.expected. The Halted line and
# the registers are left out, as the steps and the registers change with
# the code, but for VBASE, bits 23-0 of R14, which must be 0. test/dis.py
# checks the rows of DIS against nicedis.py and niceasm first,
# test/ntp.py NTP, with DHCP and DNS before it, and test/tftp.py TFTP's
# LOAD and DIR. time writes to a copy of super.img, and runs with
# --step-time, so that the dates it writes are fixed; its output has what
# the card holds that the image did not (fat_tool.py diff, the dates
# masked) and the order of its sector writes, from a second run with -t
# (fat_tool.py order).
test: fmt $(ROM_TEST) $(BUILD)/dis.bin $(MON)/build/hello.bin $(MON)/build/fat/super.img
	@test '$(FOLDER_UC)' = NICE || { echo "make test needs FOLDER=NICE, not $(FOLDER)"; exit 1; }
	@$(PYTHON) test/dis.py $(EMU) $(ROM_TEST) $(BUILD)/dis.bin
	@$(PYTHON) test/ntp.py $(EMU) $(ROM_TEST) test/ntp.expected $(BUILD)/ntp.out
	@$(PYTHON) test/tftp.py $(EMU) $(ROM_TEST) test/tftp.expected $(BUILD)/tftp.out
	@echo 'FFFFFF9E 00020000' > $(BUILD)/ram128k.bin
	@echo 'FFFFFF9E 00010000' > $(BUILD)/ram64k.bin
	@printf '$(LOAD_EMU)' > $(BUILD)/load_emu.txt
	@printf '$(LOAD_64K)' > $(BUILD)/load_64k.txt
	@printf '$(CMDS)' > $(BUILD)/cmds.txt
	@printf '$(BASIC)' > $(BUILD)/basic.txt
	@printf '$(TIME)' > $(BUILD)/time.txt
	@{ printf '$(LOAD_HEAD)'; head -n 3 $(MON)/build/hello.bin | awk '{ printf "%s\r\n", $$0 }'; \
	  tail -n +4 $(MON)/build/hello.bin; printf '$(LOAD_TAIL)'; } > $(BUILD)/load.txt
	@fail=0; \
	for t in cmds basic load load_emu load_64k time; do \
	  opts=; sd=; base0=; \
	  case $$t in \
	    cmds) prog=; dump='$(DUMP_cmds)';; \
	    basic) prog=; dump='$(DUMP_basic)';; \
	    load) prog=$(BUILD)/ram128k.bin; dump='$(DUMP_load)';; \
	    load_emu) prog=; dump='$(DUMP_load_emu)';; \
	    load_64k) prog=$(BUILD)/ram64k.bin; dump='$(DUMP_load_64k)';; \
	    time) prog=; dump=; base0=$(MON)/build/fat/super.img; opts=--step-time;; \
	  esac; \
	  card() { if [ -n "$$base0" ]; then \
	    cp --sparse=always $$base0 $(BUILD)/$${t}0.img; sd="--sd0 $(BUILD)/$${t}0.img"; fi; }; \
	  card; \
	  cat $(ROM_TEST) $$prog > $(BUILD)/$$t.full.bin; \
	  $(EMU) -s -n $(MAX_STEPS) -i $(BUILD)/$$t.txt $$dump $$opts $$sd $(BUILD)/$$t.full.bin \
	    > $(BUILD)/$$t.raw; status=$$?; \
	  { sed -e '/^Halted (HALT)/,/^R12 /d' $(BUILD)/$$t.raw; \
	    sed -n 's/.* R14 ..\(......\) .*/VBASE at the halt \1/p' $(BUILD)/$$t.raw; \
	    echo "exit $$status"; \
	    if [ $$t = time ]; then \
	      $(PYTHON) $(MON_TEST)/fat_check.py $(BUILD)/time0.img; \
	      echo "Dates in NICE:"; mdir -i $(BUILD)/time0.img ::NICE | grep -E '^(old|new|y1970) '; \
	      $(PYTHON) $(MON_TEST)/fat_tool.py diff --mask-times $$base0 $(BUILD)/time0.img; \
	      card; \
	      $(EMU) -t -n $(MAX_STEPS) -i $(BUILD)/$$t.txt $$opts $$sd $(BUILD)/$$t.full.bin | \
	        $(PYTHON) $(MON_TEST)/fat_tool.py order --sd0 $$base0; fi; } \
	    > $(BUILD)/$$t.out; \
	  if cmp -s test/$$t.expected $(BUILD)/$$t.out; then echo "PASS basic $$t"; \
	  else echo "FAIL basic $$t"; diff test/$$t.expected $(BUILD)/$$t.out; fail=1; fi; \
	done; exit $$fail

# The layout of the sources, as nice_cpu's nicefmt checks it
fmt:
	@$(FMT) $(filter-out $(SHARED),$(BAS_SOURCES)) test/dis.nasm

$(BUILD):
	@mkdir -p $@

clean:
	rm -rf $(BUILD)
