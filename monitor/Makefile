# Builds the monitor, the program of the ROM (README.md), into
# build/monitor.bin, the boards' ROM (make r6), and tests it in niceemu.
#
# make          builds build/monitor.bin, with VERSION in its banner, git
#               describe of the tree by default; the release gives its tag
# make test     checks the layout of the sources, and runs the monitor in
#               niceemu with the inputs below, alone and with the programs
#               of test/ at 0x8000, and compares the output with
#               test/*.expected
# make clean    removes build/
#
# The assembler has no include, so the monitor is the cat of SOURCES
# (monitor.nasm, the files that its header lists, monlib.nasm, and
# mon.nasm), build/version.nasm, which defines the label VERSION
# (monitor.nasm), and build/folder.nasm, the folder FOLDER's 8.3 name and
# texts. The monitor is assembly only, so it needs Python alone. The
# tests' programs in C, hello_c.bin and tcp_c.bin, need clang with the
# wasm32 target, wasm-ld, and llvm-ar, through nicebuild.

PYTHON  ?= python3
NICE_CPU = ../nice_cpu
ASM      = $(PYTHON) $(NICE_CPU)/assembler/niceasm.py
FMT      = $(PYTHON) $(NICE_CPU)/assembler/nicefmt.py
NICEBUILD = $(PYTHON) $(NICE_CPU)/translator/nicebuild.py
EMU      = $(NICE_CPU)/emulator/zig-out/bin/niceemu
RUNTIME  = $(NICE_CPU)/runtime
TOOLS    = $(wildcard $(NICE_CPU)/assembler/*.py) $(wildcard $(NICE_CPU)/translator/*.py)
BUILD    = build
SOURCES  = monitor.nasm monitor_cmd.nasm basic.nasm basic_net.nasm basic_time.nasm monitor_dis.nasm monitor_sd.nasm monitor_fat.nasm monitor_eth.nasm monitor_tcp.nasm \
           monitor_clock.nasm common.nasm monlib.nasm mon.nasm
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo unknown)
# The folder of the card's root directory that holds NiceMon's files
# (monitor_fat.nasm, README.md, "Files"): NICE, or with make FOLDER=NAME
# another 8.3 name of 1 to 8 letters, digits, _, and -, in either case. It
# reaches build/folder.nasm as FOLDER_N, its 8.3 name padded with blanks,
# and in the texts of DIR, S_DIROF, and of error 29. The tests need NICE.
# A FOLDER of the environment is passed over, as a shell may well export
# one of that common name for something else; the name counts on the
# command line, make FOLDER=NAME, alone.
ifeq ($(origin FOLDER),environment)
FOLDER  := NICE
endif
FOLDER  ?= NICE
FOLDER_UC := $(shell echo '$(FOLDER)' | tr a-z A-Z)
ifneq ($(shell echo '$(FOLDER_UC)' | grep -Ex '[A-Z0-9_-]{1,8}'),$(FOLDER_UC))
$(error FOLDER=$(FOLDER) is not a folder name of 1 to 8 letters, digits, _, and -)
endif
# A packed text of the ROM, the label $(1) and the text $(2), and a 0 word
# after it, which ends the text when its length is a multiple of 4
# (monitor.nasm). The text must not hold a '.
PACKED = printf "%s .ASCII_B '%s'\n                .DAT    0\n" '$(1)' '$(2)'
FOLDER_ERROR = ($(call PACKED,E_FS29,no folder $(FOLDER_UC) on the card); \
  $(call PACKED,S_DIROF,Directory of $(FOLDER_UC)); \
  printf "FOLDER_N .ASCII_B '%-11s'\n" '$(FOLDER_UC)')
# Each packed text of the ROM must end with a 0 byte (test/texts.py)
CHECK_TEXTS = $(PYTHON) test/texts.py $(filter-out monlib.nasm mon.nasm,$(SOURCES))
# BASIC reaches the monitor through the entries alone (test/sides.py, #152)
CHECK_SIDES = $(PYTHON) test/sides.py
# The monitor must end below PROGRAM (common.nasm), 0x8000, the end of
# the ROM. niceasm writes the words in the order of their addresses, so
# the last line has the last.
ROM_END  = $(shell sed -n 's/^PROGRAM *\.EQU *\(0x[0-9A-Fa-f]*\).*/\1/p' common.nasm)
CHECK_END = $(PYTHON) -c 'import sys; top = int(open(sys.argv[1]).read().split()[-2], 16); \
  end = int(sys.argv[2], 16); top < end or sys.exit(f"{sys.argv[1]} reaches {top:08X}, past the ROM, {end:08X}")'

.PHONY: all test fmt romsize clean FORCE

all: $(BUILD)/monitor.bin

$(BUILD)/monitor.bin: $(SOURCES) $(BUILD)/version.nasm $(BUILD)/folder.nasm $(TOOLS)
	@$(CHECK_TEXTS)
	@$(CHECK_SIDES)
	@cat $(SOURCES) $(BUILD)/version.nasm $(BUILD)/folder.nasm > $(BUILD)/monitor_all.nasm
	$(ASM) -o $@ $(BUILD)/monitor_all.nasm
	@$(CHECK_END) $@ $(ROM_END)

# Written only when the version changes, so that the monitor is not
# assembled again, and a bitstream with it not built again, for nothing.
$(BUILD)/version.nasm: FORCE | $(BUILD)
	@$(call PACKED,VERSION,$(VERSION)) | cmp -s - $@ || \
	  $(call PACKED,VERSION,$(VERSION)) > $@

# Written only when FOLDER changes, as version.nasm is
$(BUILD)/folder.nasm: FORCE | $(BUILD)
	@$(FOLDER_ERROR) | cmp -s - $@ || $(FOLDER_ERROR) > $@

# The test has a version of its own, so that its output does not change
# with every commit.
$(BUILD)/monitor_test.bin: $(SOURCES) $(BUILD)/folder.nasm $(TOOLS) | $(BUILD)
	@$(CHECK_TEXTS)
	@$(CHECK_SIDES)
	@(cat $(SOURCES) $(BUILD)/folder.nasm; $(call PACKED,VERSION,V9.9)) \
	  > $(BUILD)/monitor_test_all.nasm
	@$(ASM) -o $@ $(BUILD)/monitor_test_all.nasm
	@$(CHECK_END) $@ $(ROM_END)

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

# The test of the UDP entries, test/udp.nasm, built as arp.bin is, so that
# it reaches the monitor's variables by name
$(BUILD)/udp.bin: $(BUILD)/monitor_test.bin test/udp.nasm
	@cat $(BUILD)/monitor_test_all.nasm test/udp.nasm > $(BUILD)/udp_all.nasm
	@$(ASM) -o $(BUILD)/udp_full.bin $(BUILD)/udp_all.nasm
	@grep -v '^0000[0-7]' $(BUILD)/udp_full.bin > $@

# The tests of the network's entries of issue #111: test/net.nasm, the
# poll, the IP settings, and the datagram held, test/netdhcp.nasm,
# net_dhcp, which test/dhcp.py runs, test/dns.nasm, dns_lookup, which
# test/dns.py runs, and test/lease.nasm, the lease's renewal, which
# test/lease.py runs, all built as udp.bin is
$(BUILD)/net.bin $(BUILD)/netdhcp.bin $(BUILD)/dns.bin $(BUILD)/lease.bin $(BUILD)/tcp.bin $(BUILD)/tcpt.bin: $(BUILD)/%.bin: $(BUILD)/monitor_test.bin test/%.nasm
	@cat $(BUILD)/monitor_test_all.nasm test/$*.nasm > $(BUILD)/$*_all.nasm
	@$(ASM) -o $(BUILD)/$*_full.bin $(BUILD)/$*_all.nasm
	@grep -v '^0000[0-7]' $(BUILD)/$*_full.bin > $@

# The test of the file entries, test/fs.nasm, at 0x8000, which calls them
# through the stubs of mon.nasm, as hello.nasm does
$(BUILD)/fs.bin: test/fs.nasm mon.nasm $(TOOLS) | $(BUILD)
	@cat test/fs.nasm mon.nasm > $(BUILD)/fs_all.nasm
	@$(ASM) -o $@ $(BUILD)/fs_all.nasm

# The test of the entries of table 1.6, test/hal16.nasm, built as fs.bin
$(BUILD)/hal16.bin: test/hal16.nasm mon.nasm $(TOOLS) | $(BUILD)
	@cat test/hal16.nasm mon.nasm > $(BUILD)/hal16_all.nasm
	@$(ASM) -o $@ $(BUILD)/hal16_all.nasm

# The board's test of TCP's clients, test/tcphw.nasm, which
# tools/hwtest.py runs, built as fs.bin
$(BUILD)/tcphw.bin: test/tcphw.nasm mon.nasm $(TOOLS) | $(BUILD)
	@cat test/tcphw.nasm mon.nasm > $(BUILD)/tcphw_all.nasm
	@$(ASM) -o $@ $(BUILD)/tcphw_all.nasm

# The test of the file entries that write, test/fsw.nasm, built as fs.bin
$(BUILD)/fsw.bin: test/fsw.nasm mon.nasm $(TOOLS) | $(BUILD)
	@cat test/fsw.nasm mon.nasm > $(BUILD)/fsw_all.nasm
	@$(ASM) -o $@ $(BUILD)/fsw_all.nasm

# The FAT images of the tests, from test/fat_image.py, with build/hello.bin
# as HELLO.BIN. They need mkfs.fat, sfdisk, and mtools. The second list
# is the images of the suites of test/fat_runs.py, made from the first.
FAT_IMAGES = $(addprefix $(BUILD)/fat/,fat32.img super.img fat16.img exfat.img nonice.img \
                                    nicefile.img full.img lfn.img \
               lines.img tab1.img chains.img lfnx.img rows.img bigdir.img \
               spc8.img spc64.img fat1.img i_total.img i_last.img i_wrap.img i_ff.img i_nosig.img \
               i_bpb0.img i_bpbff.img i_top.img \
               $(addprefix m_,$(addsuffix .img,fat12 fat16 fat12p nopart zero p83 pb nosig \
                 jump bps spc0 spc3 rsvd0 nfats0 fatsz0 fatszbig nodata fat16sz rootent \
                 c4084 c4085 c65524 c65525 root1 roottop nicecl fatwrap baddir)))
$(FAT_IMAGES) &: test/fat_image.py test/fat_tool.py $(BUILD)/hello.bin
	@mkdir -p $(BUILD)/fat
	@$(PYTHON) test/fat_image.py $(BUILD)/hello.bin $(BUILD)/fat

# The words that u disassembles in test/dis.py, at 0x8000, which never run
$(BUILD)/dis.bin: test/dis.nasm $(TOOLS) | $(BUILD)
	@$(ASM) -o $@ test/dis.nasm

# The test of the FPU at a program's end, test/fpu.nasm, at 0x8000
$(BUILD)/fpu.bin: test/fpu.nasm $(TOOLS) | $(BUILD)
	@$(ASM) -o $@ test/fpu.nasm

$(BUILD)/hello_c.bin: test/hello.c mon.h mon.nasm $(TOOLS) | $(BUILD)
	@$(NICEBUILD) --monitor --asm mon.nasm -I . -o $@ test/hello.c

# The test of TCP's entries from C, which tools/tcptest.py runs, with the
# stubs of mon_c.nasm for the pointers of C
$(BUILD)/tcp_c.bin: test/tcp_c.c mon.h mon.nasm mon_c.nasm $(TOOLS) | $(BUILD)
	@$(NICEBUILD) --monitor --asm mon.nasm --asm mon_c.nasm -I . -o $@ test/tcp_c.c

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
RUN  = sys 0x8000\rhalt\r
# hal16: sys 0x8000 runs test/hal16.nasm, whose con_getline reads the
# line after it: 12, a DEL, 345678x9, of which the 9 does not fit, and a
# TAB, which completes nothing with no card.
HAL16 = sys 0x8000\r12\177345678x9\t\rhalt\r
# reset: sys 0, the cold start, which shows the banner again and leaves
# the RAM from 0x8000 alone, so that sys 0x8000 then runs hello.
RESET = sys 0\rsys 0x8000\rhalt\r
# scroll: Page Up and Page Down with no history, which do nothing; dump
# 0x8000, 0x700, the zeros of the empty RAM, 448 rows, which fill the
# history of 384 rows and go round its ring; two Page Ups and a Page
# Down, which turn the ring and show 24 rows back; and ver, which shows
# the screen again.
SCROLL = \033[5~\033[6~dump 0x8000, 0x700\r\033[5~\033[5~\033[6~ver\rhalt\r
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
# fpu: sys 0x8000 runs test/fpu.nasm three times, which leaves values
# and flags on the FPU, and returns, leaves through mon_exit, and returns,
# then sys 0x8100, which leaves them too and jumps to 0, the cold start,
# and sys 0x8000 once more, which leaves through mon_exit (issue #141).
# Each run leaves the chunky mode selected too (issue #144).
FPU  = sys 0x8000\rsys 0x8000\rsys 0x8000\rsys 0x8100\rsys 0x8000\rhalt\r
# sd_write: sys 0x8000 runs test/sd.nasm, which writes sector 2, which
# the image shows.
SD_WRITE = sys 0x8000\rhalt\r
# fat: fat32.img of test/fat_image.py in slot 0 and super.img in slot 1.
# dir mounts slot 0, DIR 1 and dir 0 mount each slot. load "frag.bin"
# reads the fragmented FRAG.BIN, whose words dump shows, the first and
# the last four. Then names that are no file: nofile.bin, sub.bin beside
# the folder SUB, and a long name; readme.txt, which LOAD does not take,
# load with no quotes, with two names and no comma, dirx, dir 2, which
# has no slot and changes nothing, dir with two numbers, and a slot of 33
# bits.
# load "HELLO.BIN", in upper case, and sys runs it.
FAT  = dir\rDIR 1\rdir 0\rload "frag.bin"\rdump 0x9000, 4\rdump 0x9068, 4\rload "nofile.bin"\rload "sub.bin"\rload "toolongname.bin"\rload "readme.txt"\rload frag.bin\rload "a.bin" "b.bin"\rdirx\rdir 2\rdir 1 2\rdir 0x123456789\rLOAD "HELLO.BIN"\rsys 0x8000\rhalt\r
# fatbad: fat16.img in slot 0 and exfat.img in slot 1, which dir rejects
# with the errors of each, and fat1: no card in slot 0 and super.img in
# slot 1, which the first dir mounts
FATBAD = dir\rdir 1\rdir 0\rhalt\r
FAT1 = dir\rhalt\r
# fatnone: nonice.img in slot 0, a card without the folder NICE, and
# nicefile.img in slot 1, whose NICE is a file, which dir and load reject
# with error 29, and never fall back to the root's HELLO.BIN
FATNONE = dir\rload "hello.bin"\rdir 1\rload "hello.bin"\rhalt\r
# fatw: a copy of super.img in slot 0 and of full.img in slot 1. load
# writes two words, which save writes to test, an 8.3 name in lower case
# without an extension, which gets .BIN, which dir lists so, and load
# reads back, and dump shows. save of 0 words truncates HELLO.BIN, which
# load then finds empty. delete deletes test.bin, and a second delete
# finds none. Then the arguments that are not: save alone, with a name
# only, with no count, with a fourth number, and with a count of 33
# bits, savex, a name that is not valid, with a colon, delete alone, with
# two names, and deletex. On full.img, save of 256 words fills the card
# with FULL.BIN's first 1536 bytes, which dir shows, and is error 30;
# delete frees them, and a save of 2 words fits.
FATW = load\r8000 1234ABCD\r8001 5\r\rsave "test", 0x8000, 2\rdir\rload "TEST.BIN"\rdump 0x8000, 2\rsave "hello.bin", 0x8000, 0\rload "hello.bin"\rdelete "test.bin"\rdelete "test.bin"\rsave\rsave "x"\rsave "x", 0x8000\rsave "x", 0x8000, 1, 2\rsave "x", 0x8000, 0x100000000\rsavex\rSAVE "a:b", 0x8000, 1\rdelete\rdelete "a" "b"\rdeletex\rdir 1\rsave "full.bin", 0x8000, 256\rdir\rdelete "full.bin"\rsave "full.bin", 0x8000, 2\rdir\rhalt\r
# fatl: lfn.img of test/fat_image.py in slot 0, with long names. dir
# shows them, load reads my prog.bin by its long name, which sys runs,
# then by its 8.3 name, and by its long name in upper case; the text
# files mixed.Bin, lower.bin, and those whose long-name entries cross a
# sector and a cluster, by their names in another case; bad sum.bin,
# whose long-name entry has a wrong checksum, only by its 8.3 name; a
# name with no closing quote, which the line ends; caf?.bin, as dir
# shows café.bin, which reaches it (issue #151, B5); λx.bin by its 8.3
# name, _X.BIN; and *.bin, which is no file, as a name has no patterns
# and a ? matches only a character outside ASCII.
FATL = dir\rload "my prog.bin"\rsys 0x8000\rload "MYPROG~1.BIN"\rload "MY PROG.BIN"\rload "mixed.bin"\rload "LOWER.BIN"\rload "across a sector.bin"\rload "ACROSS A CLUSTER.BIN"\rload "bad sum.bin"\rload "badsum~1.bin"\rload "my prog.bin\rload "caf?.bin"\rload "_x.bin"\rload "*.bin"\rhalt\r
# tab: lfn.img in slot 0, and TAB (issue #137). my is "my prog.bin",
# with an opening quote, and in quotes with BS; mand is "mandelbrot, a
# second TAB lists the two, and 1 is one; pad2 lists four at once, and
# pad21 is "PAD21.TXT" in its case; ACROSS is "across a , which lists
# two. Nothing: in the statement, with no match, for caf?.bin, which is
# left out, after a directory's . , for n, whose name does not fit the
# line, and with no card in slot 1. ^C ends a line.
TAB = load my\t\rload "my\t\rload mand\t\t1\t\rload pad2\t1\t\rlo\t\003load x\t\003load caf\t\003load ACROSS\t\t\003load .\t\003load n\t\003dir 1\rload my\t\003halt\r
# fatlw: a copy of lfn.img in slot 0. load writes two words, and save
# writes them to new files: mandelbrot.bin, MANDEL~1.BIN, as the
# MANDEL~1 that is there is a .TXT; mandelbrot3.txt, MANDEL~3.TXT after
# ~1 and ~2; Hello.bin, HELLO.BIN with no tail and a long name;
# lower2.bin, LOWER2.BIN with byte 12's flags and no long name; and
# "a b.bin", AB~1.BIN. A save of MIXED.BIN truncates mixed.Bin, which
# keeps its name. "a*b" and "end." are no names. delete deletes
# mandelbrot1.txt and mandelbrot2.txt, whose 4 entries in a row take the
# 4 of a much longer name of a file.bin, and x.bin goes at the end. dir
# shows them, and load reads two back.
FATLW = load\r8000 1234ABCD\r8001 5\r\rsave "mandelbrot.bin", 0x8000, 2\rsave "mandelbrot3.txt", 0x8000, 2\rsave "Hello.bin", 0x8000, 2\rsave "lower2.bin", 0x8000, 2\rsave "a b.bin", 0x8000, 2\rsave "MIXED.BIN", 0x8000, 1\rsave "a*b", 0x8000, 1\rsave "end.", 0x8000, 1\rdelete "mandelbrot1.txt"\rdelete "mandelbrot2.txt"\rsave "a much longer name of a file.bin", 0x8000, 2\rsave "x.bin", 0x8000, 2\rdir\rload "A MUCH LONGER NAME OF A FILE.BIN"\rdump 0x8000, 2\rload "mandel~1.bin"\rhalt\r

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
# clock: with --no-cycle-counter, so that the clock's words are memory,
# which build/clock.bin sets: "set", 999999 microseconds, and the seconds
# of 2026-11-14 12:34:57, which time shows. save writes a.bin at
# 12:34:56 and 199 hundredths, the most. time sets 2099-12-31 23:59:58,
# and b.bin gets 0 hundredths; 1980-01-01 00:00:01, the first second
# that FAT holds, and c.bin gets 100; 1979-12-31 23:59:59, and d.bin
# gets the fixed date. 2106 is not taken. The clock's words are dumped:
# the last seconds written, with 0 above them, 0 microseconds, and "set".
# clockpast: the same with 2^32 seconds, so time shows that the clock is
# past 2106, and save writes p.bin with the fixed date.
CLOCK = time\rload\r8000 1\r\rsave "a.bin", 0x8000, 1\rtime "2099-12-31 23:59:58"\rsave "b.bin", 0x8000, 1\rtime "1980-01-01 00:00:01"\rsave "c.bin", 0x8000, 1\rtime "1979-12-31 23:59:59"\rsave "d.bin", 0x8000, 1\rtime "2106-01-01 00:00:00"\rhalt\r
CLOCKPAST = time\rload\r8000 1\r\rsave "p.bin", 0x8000, 1\rhalt\r
CLOCK_WORDS = FFFFFF46 000F423F\nFFFFFF47 6AF85571\nFFFFFF48 00000000\nFFFFFF49 00000001\n
CLOCKPAST_WORDS = FFFFFF46 00000000\nFFFFFF47 00000000\nFFFFFF48 00000001\nFFFFFF49 00000001\n
DUMP_clock    = -d 0xFFFFFF46:4
# The words of each test that are dumped with the screen: for cmds the
# variables, the cursor's registers, and the IP and MAC addresses, and
# for the programs the text at column 40 of row 5, below the banner,
# READY., and the SYS line, 80 * 5 + 40 = 440 = 0x1B8, with its color, and for
# hello the 0x80 after it, the screen's state, in which the return showed
# the cursor that hello hid, the font base, which the return made 0, and
# the row of the glyph of 0x80 that hello drew.
DUMP_cmds    = -d 0xFFFFF000:4 -d 0xFFFFE800:2 -d 0xFFFFFF80:6 -d 0xFFFFFF9F:1 -d 0xFFFFFFB0:3
DUMP_basic   = -d 0xFFFFF000:4 -d 0xFFFFE800:2 -d 0xFFFFFFB0:1
# For scroll the variables and the screen's registers, and the last four
# digits of the address that starts a row of the history (the words 4 to
# 7 of the row): the rows of 86A0 and 869C that Page Up turned to slots 0
# and 1, the row of 86A4 in slot 383, the first of the five rows that
# ver and halt added at the bottom of the ring, and the oldest, of 80B8,
# in slot 378.
DUMP_scroll  = -d 0xFFFFF000:4 -d 0xFFFFF005:6 -d 0xFFFFFF80:6 -d 0xFFFF7FB4:4 -d 0xFFFF7F64:4 \
               -d 0xFFFF0804:4 -d 0xFFFF0994:4
DUMP_hello   = -d 0xFFFF01B8:13 -d 0xFFFFFF80:1 -d 0xFFFFFF86:1 -d 0xFFFE1000:1
DUMP_load    = -d 0xFFFFF000:4 -d 0xFFFFF005:6 -d 0xFFFFE800:5
DUMP_load_emu = -d 0xFFFFE812:1 -d 0xFFFEFFFF:1
DUMP_load_64k = -d 0xFFFFE812:1
DUMP_hello_c = -d 0xFFFF01B8:12
# For sd_write the results of test/sd.nasm's calls
DUMP_sd_write = -d 0x9100:6
# For fs the results of test/fs.nasm's calls, the entries that fs_readdir
# and fs_readname wrote, the first 45 bytes that fs_read wrote, and the
# names of fs_readname, for fsw the results
# of test/fsw.nasm's, and for fat the numbers of fat_load for load NAME
DUMP_fs       = -d 0x9100:36 -d 0x9180:8 -d 0x9200:45 -d 0x9280:16 -d 0x92A0:11
DUMP_fsw      = -d 0x9100:42
# For hal16 the results of test/hal16.nasm's calls, the line of
# con_getline, the counts of bin_line, the servers of net_servers, and the
# words that bin_line wrote
DUMP_hal16    = -d 0x9100:16 -d 0x9180:9 -d 0x9190:7 -d 0x9198:2 -d 0x9200:2
DUMP_fat      = -d 0xFFFFE80C:5
# For fpu the number of test/fpu.nasm's runs, the FPU's status and the
# screen's mode word at the start of each run, and both at the halt
DUMP_fpu      = -d 0x9100:5 -d 0x9111:4 -d 0xFFFFFF8D:1 -d 0xFFFFFF87:1
# For arp the results of test/arp.nasm's calls, and the cache it copied,
# and for udp the results of test/udp.nasm's, and the bytes and the
# sources that udp_recv wrote
DUMP_arp      = -d 0x9100:37
DUMP_udp      = -d 0x9100:20 -d 0x9180:14
# For net the results of test/net.nasm's calls, the words of net_config,
# and the bytes and the sources that udp_recv wrote
DUMP_net      = -d 0x9100:24 -d 0x9180:8 -d 0x9190:16
MAX_STEPS = 10000000
# The suites of test/fat_runs.py, each of several runs on the cards of
# test/fat_image.py, compared with test/SUITE.expected: make test
# FAT_SUITES=fatapi runs one
FAT_SUITES = fatstate fatload fattab fatdrop fatchain fatlfn fatmount fatgeo fatinfo \
             fatfull fatrows fatapi
# The first sector of fat32.img's FAT32 partition (test/fat_image.py), and
# its byte offset, for mtools
FAT32_START = 34816
FAT32_START_BYTES = $(shell echo $$(($(FAT32_START) * 512)))

# Each test runs the monitor with its input and its program, if any, and
# compares the console output, the dumps, and the screen with
# test/NAME.expected. The Halted line and the registers are left out, as
# the steps and the registers change with the code, but for VBASE, bits
# 23-0 of R14, which must be 0, also after hello, which returns with
# VBASE 0x80, and so tests that a program returns to mon_exit.
# test/ring.py checks the ring of the history at the
# sizes of the screen's memory of niceemu and the boards first, and
# test/dis.py the rows of u against nicedis.py and niceasm, and
# test/dhcp.py runs i dhcp against the frames that it builds, and so
# does test/dns.py for dns_lookup, and test/ntp.py for time ntp, with
# i dhcp and DNS before it, and test/lease.py for the lease's
# renewal, and test/bgdhcp.py the DHCP exchange in the background,
# and
# test/tftp.py tftp, and test/rtc.py the cold start and time on the words
# of an I2C master that it sets, as a real-time clock, and on the chips
# that it answers for over niceemu --link, and test/fat_runs.py the
# suites of FAT_SUITES. arp and udp run
# with --step-time, as their timeouts
# count, and so does net, and the frames they send are added to their
# output. A test that writes to a card has the card's image in base0 or
# base1, which cards copies for each run; it runs with --step-time, so
# that the dates it writes are fixed, but for clock and clockpast, which
# set the clock themselves, and its output has what the card holds that
# the image did not (test/fat_tool.py diff, the dates masked for time)
# and the order of its sector writes, from a second run with -t
# (test/fat_tool.py order).
test: fmt $(BUILD)/monitor_test.bin $(BUILD)/monitor_8k.bin $(BUILD)/monitor_2k.bin $(BUILD)/hello.bin \
      $(BUILD)/dis.bin $(BUILD)/sd.bin $(BUILD)/arp.bin $(BUILD)/udp.bin $(BUILD)/net.bin \
      $(BUILD)/netdhcp.bin $(BUILD)/dns.bin $(BUILD)/lease.bin $(BUILD)/fpu.bin $(BUILD)/fs.bin $(BUILD)/fsw.bin \
      $(BUILD)/hal16.bin $(FAT_IMAGES) $(BUILD)/version_test.nasm
	@test '$(FOLDER_UC)' = NICE || { echo "make test needs FOLDER=NICE, not $(FOLDER)"; exit 1; }
	@$(PYTHON) test/ring.py $(EMU) $(BUILD)/monitor_test.bin:32768 \
	  $(BUILD)/monitor_8k.bin:8192 $(BUILD)/monitor_2k.bin:2048
	@$(PYTHON) test/dis.py $(EMU) $(BUILD)/monitor_test.bin $(BUILD)/dis.bin
	@$(PYTHON) test/dhcp.py $(EMU) $(BUILD)/monitor_test.bin $(BUILD)/netdhcp.bin \
	  test/dhcp.expected $(BUILD)/dhcp.out
	@$(PYTHON) test/dns.py $(EMU) $(BUILD)/monitor_test.bin $(BUILD)/dns.bin \
	  test/dns.expected $(BUILD)/dns.out
	@$(PYTHON) test/ntp.py $(EMU) $(BUILD)/monitor_test.bin test/ntp.expected $(BUILD)/ntp.out
	@$(PYTHON) test/lease.py $(EMU) $(BUILD)/monitor_test.bin $(BUILD)/lease.bin
	@$(PYTHON) test/bgdhcp.py $(EMU) $(BUILD)/monitor_test.bin
	@$(PYTHON) test/tftp.py $(EMU) $(BUILD)/monitor_test.bin test/tftp.expected $(BUILD)/tftp.out
	@$(PYTHON) test/rtc.py $(EMU) $(BUILD)/monitor_test.bin
	@$(PYTHON) test/fat_runs.py $(EMU) $(BUILD)/monitor_test.bin $(BUILD) $(FAT_SUITES)
	@$(ROMSIZE)
	@echo 'FFFFFF9E 00020000' > $(BUILD)/ram128k.bin
	@echo 'FFFFFF9E 00010000' > $(BUILD)/ram64k.bin
	@printf '$(LOAD_EMU)' > $(BUILD)/load_emu.txt
	@printf '$(LOAD_64K)' > $(BUILD)/load_64k.txt
	@printf '$(CMDS)' > $(BUILD)/cmds.txt
	@printf '$(BASIC)' > $(BUILD)/basic.txt
	@printf '$(RUN)' > $(BUILD)/run.txt
	@printf '$(HAL16)' > $(BUILD)/hal16.txt
	@printf '$(RESET)' > $(BUILD)/reset.txt
	@printf '$(SCROLL)' > $(BUILD)/scroll.txt
	@printf '$(SD_WRITE)' > $(BUILD)/sd_write.txt
	@printf '$(FPU)' > $(BUILD)/fpu.txt
	@printf '$(FAT)' > $(BUILD)/fat.txt
	@printf '$(FATBAD)' > $(BUILD)/fatbad.txt
	@printf '$(FAT1)' > $(BUILD)/fat1.txt
	@printf '$(FATNONE)' > $(BUILD)/fatnone.txt
	@printf '$(FATW)' > $(BUILD)/fatw.txt
	@printf '$(FATL)' > $(BUILD)/fatl.txt
	@printf '$(TAB)' > $(BUILD)/tab.txt
	@printf '$(FATLW)' > $(BUILD)/fatlw.txt
	@printf '$(TIME)' > $(BUILD)/time.txt
	@printf '$(CLOCK)' > $(BUILD)/clock.txt
	@printf '$(CLOCKPAST)' > $(BUILD)/clockpast.txt
	@printf '$(CLOCK_WORDS)' > $(BUILD)/clock.bin
	@printf '$(CLOCKPAST_WORDS)' > $(BUILD)/clockpast.bin
	@$(PYTHON) test/sd_image.py $(BUILD)/sd.img
	@$(PYTHON) test/sd_image.py --written $(BUILD)/sd_written.img
	@{ printf '$(LOAD_HEAD)'; head -n 3 $(BUILD)/hello.bin | awk '{ printf "%s\r\n", $$0 }'; \
	  tail -n +4 $(BUILD)/hello.bin; printf '$(LOAD_TAIL)'; } > $(BUILD)/load.txt
	@fail=0; \
	cards() { sd=; \
	  if [ -n "$$base0" ]; then cp --sparse=always $$base0 $(BUILD)/$${t}0.img; sd="--sd0 $(BUILD)/$${t}0.img"; fi; \
	  if [ -n "$$base1" ]; then rm -f $(BUILD)/$${t}1.img; cp --sparse=always $$base1 $(BUILD)/$${t}1.img; \
	    if [ -n "$$ro1" ]; then chmod a-w $(BUILD)/$${t}1.img; fi; sd="$$sd --sd1 $(BUILD)/$${t}1.img"; fi; }; \
	for t in cmds basic scroll load load_emu load_64k sd_write arp udp net fpu fs fsw hal16 fat fatw fatl tab fatlw fatbad fat1 fatnone time \
	           clock clockpast \
	           hello reset hello_c; do \
	  opts=; rom=$(BUILD)/monitor_test.bin; base0=; base1=; ro1=; mask=; \
	  case $$t in \
	    cmds) prog=; input=cmds; dump='$(DUMP_cmds)';; \
	    basic) prog=; input=basic; dump='$(DUMP_basic)';; \
	    scroll) prog=; input=scroll; dump='$(DUMP_scroll)';; \
	    load) prog=$(BUILD)/ram128k.bin; input=load; dump='$(DUMP_load)';; \
	    load_emu) prog=; input=load_emu; dump='$(DUMP_load_emu)';; \
	    load_64k) prog=$(BUILD)/ram64k.bin; input=load_64k; dump='$(DUMP_load_64k)';; \
	    sd_write) prog=$(BUILD)/sd.bin; input=sd_write; dump='$(DUMP_sd_write)'; \
	      cp $(BUILD)/sd.img $(BUILD)/sd_write.img; opts="--sd0 $(BUILD)/sd_write.img";; \
	    arp) prog=$(BUILD)/arp.bin; input=run; dump='$(DUMP_arp)'; \
	      opts="--step-time --eth-in test/arp.eth --eth-out $(BUILD)/arp.eth.out";; \
	    udp) prog=$(BUILD)/udp.bin; input=run; dump='$(DUMP_udp)'; \
	      opts="--step-time --eth-in test/udp.eth --eth-out $(BUILD)/udp.eth.out";; \
	    net) prog=$(BUILD)/net.bin; input=run; dump='$(DUMP_net)'; \
	      opts="--step-time --eth-in test/net.eth --eth-out $(BUILD)/net.eth.out";; \
	    fpu) prog=$(BUILD)/fpu.bin; input=fpu; dump='$(DUMP_fpu)';; \
	    fs) prog=$(BUILD)/fs.bin; input=run; dump='$(DUMP_fs)'; \
	      opts="--sd0 $(BUILD)/fat/fat32.img --sd1 $(BUILD)/fat/super.img";; \
	    fsw) prog=$(BUILD)/fsw.bin; input=run; dump='$(DUMP_fsw)'; \
	      cp $(BUILD)/fat/fat32.img $(BUILD)/fsw0.base; \
	      mattrib -i $(BUILD)/fsw0.base@@$(FAT32_START_BYTES) +r ::NICE/KEEP.TXT; \
	      base0=$(BUILD)/fsw0.base; base1=$(BUILD)/fat/super.img; ro1=1; opts=--step-time;; \
	    hal16) prog=$(BUILD)/hal16.bin; input=hal16; dump='$(DUMP_hal16)'; opts=--step-time;; \
	    fat) prog=; input=fat; dump='$(DUMP_fat)'; \
	      opts="--sd0 $(BUILD)/fat/fat32.img --sd1 $(BUILD)/fat/super.img";; \
	    fatw) prog=; input=fatw; dump=; \
	      base0=$(BUILD)/fat/super.img; base1=$(BUILD)/fat/full.img; opts=--step-time;; \
	    fatl) prog=; input=fatl; dump=; opts="--sd0 $(BUILD)/fat/lfn.img";; \
	    tab) prog=; input=tab; dump=; opts="--sd0 $(BUILD)/fat/lfn.img";; \
	    fatlw) prog=; input=fatlw; dump=; base0=$(BUILD)/fat/lfn.img; opts=--step-time;; \
	    fatbad) prog=; input=fatbad; dump=; \
	      opts="--sd0 $(BUILD)/fat/fat16.img --sd1 $(BUILD)/fat/exfat.img";; \
	    fat1) prog=; input=fat1; dump=; opts="--sd1 $(BUILD)/fat/super.img";; \
	    time) prog=; input=time; dump=; base0=$(BUILD)/fat/super.img; mask=--mask-times; \
	      opts=--step-time;; \
	    clock|clockpast) prog=$(BUILD)/$$t.bin; input=$$t; dump='$(DUMP_clock)'; \
	      base0=$(BUILD)/fat/super.img; opts=--no-cycle-counter;; \
	    fatnone) prog=; input=fatnone; dump=; \
	      opts="--sd0 $(BUILD)/fat/nonice.img --sd1 $(BUILD)/fat/nicefile.img";; \
	    hello) prog=$(BUILD)/hello.bin; input=run; dump='$(DUMP_hello)';; \
	    reset) prog=$(BUILD)/hello.bin; input=reset; dump='$(DUMP_hello)';; \
	    hello_c) prog=$(BUILD)/hello_c.bin; input=run; dump='$(DUMP_hello_c)'; \
	      $(MAKE) --no-print-directory $$prog || exit 1;; \
	  esac; \
	  cards; \
	  cat $$rom $$prog > $(BUILD)/$$t.full.bin; \
	  $(EMU) -s -n $(MAX_STEPS) -i $(BUILD)/$$input.txt $$dump $$opts $$sd $(BUILD)/$$t.full.bin \
	    > $(BUILD)/$$t.raw; status=$$?; \
	  { sed -e '/^Halted (HALT)/,/^R12 /d' $(BUILD)/$$t.raw; \
	    sed -n 's/.* R14 ..\(......\) .*/VBASE at the halt \1/p' $(BUILD)/$$t.raw; \
	    echo "exit $$status"; \
	    if [ $$t = sd_write ]; then cmp $(BUILD)/sd_written.img $(BUILD)/sd_write.img 2>&1 \
	      && echo "The image as test/sd_image.py --written makes it"; fi; \
	    if [ $$t = arp ] || [ $$t = udp ] || [ $$t = net ]; then \
	      echo "Frames sent:"; cat $(BUILD)/$$t.eth.out; fi; \
	    if [ $$t = fsw ]; then \
	      $(PYTHON) test/fat_check.py $(BUILD)/fsw0.img --start $(FAT32_START) NEW.TXT HELLO.BIN DROP.TXT; \
	      cmp $(BUILD)/fat/super.img $(BUILD)/fsw1.img && echo "Slot 1's card as it was"; fi; \
	    if [ $$t = fatw ]; then \
	      $(PYTHON) test/fat_check.py $(BUILD)/fatw0.img HELLO.BIN; \
	      $(PYTHON) test/fat_check.py $(BUILD)/fatw1.img FULL.BIN; fi; \
	    if [ $$t = time ]; then \
	      $(PYTHON) test/fat_check.py $(BUILD)/time0.img; \
	      echo "Dates in NICE:"; mdir -i $(BUILD)/time0.img ::NICE | grep -E '^(old|new|y1970) '; fi; \
	    if [ $$t = clock ] || [ $$t = clockpast ]; then \
	      $(PYTHON) test/fat_check.py $(BUILD)/$${t}0.img --stamps A.BIN B.BIN C.BIN D.BIN P.BIN; fi; \
	    if [ $$t = fatlw ]; then \
	      $(PYTHON) test/fat_check.py $(BUILD)/fatlw0.img mandelbrot.bin "a b.bin" \
	        "a much longer name of a file.bin" mixed.Bin; fi; \
	    if [ -n "$$base0" ]; then $(PYTHON) test/fat_tool.py diff $$mask $$base0 $(BUILD)/$${t}0.img; fi; \
	    if [ -n "$$base1" ] && [ -z "$$ro1" ]; then \
	      $(PYTHON) test/fat_tool.py diff $$mask $$base1 $(BUILD)/$${t}1.img; fi; \
	    if [ -n "$$base0$$base1" ]; then cards; \
	      $(EMU) -t -n $(MAX_STEPS) -i $(BUILD)/$$input.txt $$opts $$sd $(BUILD)/$$t.full.bin | \
	        $(PYTHON) test/fat_tool.py order $${base0:+--sd0 $$base0} $${base1:+--sd1 $$base1}; fi; } \
	    > $(BUILD)/$$t.out; \
	  if cmp -s test/$$t.expected $(BUILD)/$$t.out; then echo "PASS monitor $$t"; \
	  else echo "FAIL monitor $$t"; diff test/$$t.expected $(BUILD)/$$t.out; fail=1; fi; \
	done; exit $$fail

# The table of the monitor's words in INTERNALS.md, "The ROM's words",
# which make test checks against monitor_test.bin, and make romsize
# writes. Its sources are those of monitor_test.bin, with the version of
# the tests in a file of its own.
ROMSIZE = $(PYTHON) ../tools/romsize.py monitor --bin $(BUILD)/monitor_test.bin \
            --doc INTERNALS.md $(SOURCES) $(BUILD)/folder.nasm $(BUILD)/version_test.nasm

$(BUILD)/version_test.nasm: Makefile | $(BUILD)
	@$(call PACKED,VERSION,V9.9) > $@

romsize: $(BUILD)/monitor_test.bin $(BUILD)/version_test.nasm
	@$(ROMSIZE) --write

# The layout of the sources, as nice_cpu's nicefmt checks it
fmt:
	@$(FMT) $(SOURCES) test/hello.nasm test/dis.nasm test/sd.nasm test/arp.nasm test/fpu.nasm \
	  test/fs.nasm test/fsw.nasm test/hal16.nasm test/udp.nasm test/net.nasm test/netdhcp.nasm \
	  test/dns.nasm test/lease.nasm test/tcp.nasm test/tcpt.nasm test/tcphw.nasm mon_c.nasm

$(BUILD):
	@mkdir -p $@

clean:
	rm -rf $(BUILD)
