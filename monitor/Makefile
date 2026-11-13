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
# (monitor.nasm, the four files that its header lists, monlib.nasm, and
# mon.nasm), build/rom_c.nasm, nice_cpu's lib.nasm and
# muldiv_mpu.nasm, build/version.nasm, which defines the label VERSION
# (monitor.nasm), and build/folder.nasm, the text of the error of a card
# without the folder FOLDER. build/rom_c.nasm is the ROM's C code, ROM_C, which clang
# compiles to one wasm module and nicewasm --ram translates for the ROM
# (INTERNALS.md, "C in the ROM"), so the monitor needs clang with the wasm32
# target, wasm-ld, and llvm-ar for the C library.

PYTHON  ?= python3
CLANG   ?= clang
NICE_CPU = ../nice_cpu
ASM      = $(PYTHON) $(NICE_CPU)/assembler/niceasm.py
FMT      = $(PYTHON) $(NICE_CPU)/assembler/nicefmt.py
NICEBUILD = $(PYTHON) $(NICE_CPU)/translator/nicebuild.py
EMU      = $(NICE_CPU)/emulator/zig-out/bin/niceemu
RUNTIME  = $(NICE_CPU)/runtime
NICEWASM = $(PYTHON) $(NICE_CPU)/translator/nicewasm.py
TOOLS    = $(wildcard $(NICE_CPU)/assembler/*.py) $(wildcard $(NICE_CPU)/translator/*.py)
LIBC     = $(NICE_CPU)/runtime/libc
BUILD    = build
SOURCES  = monitor.nasm monitor_cmd.nasm monitor_dis.nasm monitor_sd.nasm monitor_eth.nasm monlib.nasm mon.nasm
# The ROM's C code, and nice_cpu's runtime library that it is joined with
ROM_C    = fat32.c clock.c
RUNTIME_ROM = $(RUNTIME)/lib.nasm $(RUNTIME)/muldiv_mpu.nasm
# The options of nicebuild.py --ram (nice_cpu's translator README), but
# that every function that is not static is exported, for the monitor's
# assembly, nothing needs a main, and -Oz, which makes the code more than a
# quarter smaller than -O2. The stack is nicebuild's 4096 bytes.
ROM_CFLAGS = --target=wasm32 -mbulk-memory -mtail-call -Oz -ffreestanding -fvisibility=default \
             -nostdlibinc -isystem $(LIBC)/include -nostdlib -Wl,--no-entry \
             -Wl,--export-dynamic -Wl,--allow-undefined -Wl,--stack-first \
             -Wl,--export=__heap_base -Wl,-z,stack-size=4096 -DFOLDER='"$(FOLDER_UC)"'
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo unknown)
# The folder of the card's root directory that holds NiceMon's files
# (fat32.c, README.md, "Files"): NICE, or with make FOLDER=NAME another
# 8.3 name of 1 to 8 letters, digits, _, and -, in either case. It reaches
# the C code as the define FOLDER, and build/folder.nasm as the text of
# error 29. The tests need NICE. A FOLDER of the environment is passed
# over, as a shell may well export one of that common name for something
# else; the name counts on the command line, make FOLDER=NAME, alone.
ifeq ($(origin FOLDER),environment)
FOLDER  := NICE
endif
FOLDER  ?= NICE
FOLDER_UC := $(shell echo '$(FOLDER)' | tr a-z A-Z)
ifneq ($(shell echo '$(FOLDER_UC)' | grep -Ex '[A-Z0-9_-]{1,8}'),$(FOLDER_UC))
$(error FOLDER=$(FOLDER) is not a folder name of 1 to 8 letters, digits, _, and -)
endif
FOLDER_ERROR = E_FS29 .ASCII_L 'no folder $(FOLDER_UC) on the card'
# The words that the ROM's C code writes are in the RAM from WASM_RAM up to
# below WASM_END (monitor.nasm), and ___wasm_ram_end is the word after them.
WASM_RAM = $(shell sed -n 's/^WASM_RAM *\.EQU *\(0x[0-9A-Fa-f]*\).*/\1/p' monitor.nasm)
WASM_END = $(shell sed -n 's/^WASM_END *\.EQU *\(0x[0-9A-Fa-f]*\).*/\1/p' monitor.nasm)
CHECK_RAM = $(PYTHON) -c 'import re, sys; \
  end = int(re.search(r"^___wasm_ram_end +\.EQU +(0x[0-9A-Fa-f]+)", open(sys.argv[1]).read(), re.M)[1], 16); \
  end <= int(sys.argv[2], 16) or sys.exit(f"{sys.argv[1]}: the C code takes the RAM up to {end:08X}, past WASM_END, {sys.argv[2]}")'
# The monitor must end below PROGRAM (monitor.nasm), 0x8000, the end of
# the ROM. niceasm writes the words in the order of their addresses, so
# the last line has the last.
ROM_END  = $(shell sed -n 's/^PROGRAM *\.EQU *\(0x[0-9A-Fa-f]*\).*/\1/p' monitor.nasm)
CHECK_END = $(PYTHON) -c 'import sys; top = int(open(sys.argv[1]).read().split()[-2], 16); \
  end = int(sys.argv[2], 16); top < end or sys.exit(f"{sys.argv[1]} reaches {top:08X}, past the ROM, {end:08X}")'

.PHONY: all test fmt romsize clean FORCE

all: $(BUILD)/monitor.bin

$(BUILD)/monitor.bin: $(SOURCES) $(BUILD)/rom_c.nasm $(RUNTIME_ROM) $(BUILD)/version.nasm \
                      $(BUILD)/folder.nasm $(TOOLS)
	@cat $(SOURCES) $(BUILD)/rom_c.nasm $(RUNTIME_ROM) $(BUILD)/version.nasm \
	  $(BUILD)/folder.nasm > $(BUILD)/monitor_all.nasm
	$(ASM) -o $@ $(BUILD)/monitor_all.nasm
	@$(CHECK_END) $@ $(ROM_END)

# The ROM's C code, and for the test of it, rom, with test/rom.c after
# ROM_C. The C library is built if it is missing.
$(BUILD)/rom_c.wasm: $(ROM_C) $(LIBC)/libc.a Makefile $(BUILD)/folder.nasm | $(BUILD)
	@$(CLANG) $(ROM_CFLAGS) -o $@ $(ROM_C) $(LIBC)/libc.a
$(BUILD)/rom_c_test.wasm: $(ROM_C) test/rom.c $(LIBC)/libc.a Makefile $(BUILD)/folder.nasm | $(BUILD)
	@$(CLANG) $(ROM_CFLAGS) -o $@ $(ROM_C) test/rom.c $(LIBC)/libc.a
$(BUILD)/rom_c.nasm $(BUILD)/rom_c_test.nasm: $(BUILD)/%.nasm: $(BUILD)/%.wasm $(TOOLS) monitor.nasm
	@$(NICEWASM) --ram $(WASM_RAM) -o $@ $<
	@$(CHECK_RAM) $@ $(WASM_END)

$(LIBC)/libc.a:
	@$(MAKE) --no-print-directory -s -C $(LIBC) libc.a

# Written only when the version changes, so that the monitor is not
# assembled again, and a bitstream with it not built again, for nothing.
$(BUILD)/version.nasm: FORCE | $(BUILD)
	@echo "VERSION .ASCII_L '$(VERSION)'" | cmp -s - $@ || \
	  echo "VERSION .ASCII_L '$(VERSION)'" > $@

# Written only when FOLDER changes, as version.nasm is, and the C code is
# compiled again then
$(BUILD)/folder.nasm: FORCE | $(BUILD)
	@echo "$(FOLDER_ERROR)" | cmp -s - $@ || echo "$(FOLDER_ERROR)" > $@

# The test has a version of its own, so that its output does not change
# with every commit.
$(BUILD)/monitor_test.bin: $(SOURCES) $(BUILD)/rom_c.nasm $(RUNTIME_ROM) $(BUILD)/folder.nasm \
                           $(TOOLS) | $(BUILD)
	@(cat $(SOURCES) $(BUILD)/rom_c.nasm $(RUNTIME_ROM) $(BUILD)/folder.nasm; \
	  echo "VERSION .ASCII_L 'V9.9'") \
	  > $(BUILD)/monitor_test_all.nasm
	@$(ASM) -o $@ $(BUILD)/monitor_test_all.nasm
	@$(CHECK_END) $@ $(ROM_END)

# The test of the ROM's C code: the monitor of the tests with test/rom.c in
# its module, and test/rom.nasm after it, which calls its functions by
# their labels, in one image, which runs without monitor_test.bin.
$(BUILD)/rom.bin: $(SOURCES) $(BUILD)/rom_c_test.nasm test/rom.nasm $(RUNTIME_ROM) \
                  $(BUILD)/folder.nasm $(TOOLS) | $(BUILD)
	@(cat $(SOURCES) $(BUILD)/rom_c_test.nasm $(RUNTIME_ROM) $(BUILD)/folder.nasm; \
	  echo "VERSION .ASCII_L 'V9.9'"; \
	  cat test/rom.nasm) > $(BUILD)/rom_all.nasm
	@$(ASM) --symbols $(BUILD)/rom.sym -o $@ $(BUILD)/rom_all.nasm

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
                    $(RUNTIME_ROM) $(TOOLS) | $(BUILD)
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
# poll, the IP settings, and the datagram held, and test/netdhcp.nasm,
# net_dhcp, which test/dhcp.py runs, both built as udp.bin is
$(BUILD)/net.bin $(BUILD)/netdhcp.bin: $(BUILD)/%.bin: $(BUILD)/monitor_test.bin test/%.nasm
	@cat $(BUILD)/monitor_test_all.nasm test/$*.nasm > $(BUILD)/$*_all.nasm
	@$(ASM) -o $(BUILD)/$*_full.bin $(BUILD)/$*_all.nasm
	@grep -v '^0000[0-7]' $(BUILD)/$*_full.bin > $@

# The test of the file entries, test/fs.nasm, at 0x8000, which calls them
# through the stubs of mon.nasm, as hello.nasm does
$(BUILD)/fs.bin: test/fs.nasm mon.nasm $(TOOLS) | $(BUILD)
	@cat test/fs.nasm mon.nasm > $(BUILD)/fs_all.nasm
	@$(ASM) -o $@ $(BUILD)/fs_all.nasm

# The test of the file entries that write, test/fsw.nasm, built as fs.bin
$(BUILD)/fsw.bin: test/fsw.nasm mon.nasm $(TOOLS) | $(BUILD)
	@cat test/fsw.nasm mon.nasm > $(BUILD)/fsw_all.nasm
	@$(ASM) -o $@ $(BUILD)/fsw_all.nasm

# The FAT images of the tests, from test/fat_image.py, with build/hello.bin
# as HELLO.BIN. They need mkfs.fat, sfdisk, and mtools.
FAT_IMAGES = $(addprefix $(BUILD)/fat/,fat32.img super.img fat16.img exfat.img nonice.img \
                                    nicefile.img full.img lfn.img)
$(FAT_IMAGES) &: test/fat_image.py $(BUILD)/hello.bin
	@mkdir -p $(BUILD)/fat
	@$(PYTHON) test/fat_image.py $(BUILD)/hello.bin $(BUILD)/fat

# The words that u disassembles in test/dis.py, at 0x8000, which never run
$(BUILD)/dis.bin: test/dis.nasm $(TOOLS) | $(BUILD)
	@$(ASM) -o $@ test/dis.nasm

$(BUILD)/hello_c.bin: test/hello.c mon.h mon.nasm $(TOOLS) | $(BUILD)
	@$(NICEBUILD) --monitor --asm mon.nasm -I . -o $@ test/hello.c

# The inputs. cmds types each command, with the edits of a line: three DELs
# that take back abc, a CTRL-C that empties junk, and the cursor key ESC [ A
# and the function key ESC O P, which are dropped. D is d, and q is no
# command. r finds no program, nor r 9000, d 8000 0 only moves the next d
# to 8000, and d 0 100 shows 256 words, which scrolls the screen. i shows
# the IP address, 0.0.0.0, and writes 192.168.1.65; four addresses are
# rejected, with too few numbers, one past 255, an empty one, and a
# letter after them; and the last, with blanks around it and a leading
# zero, is written, which the dump of 0xFFFFFFB0 shows. m shows
# the MAC address, 02:4E:49:43:45:00 after niceemu's reset, and writes
# 02:4E:49:43:45:01; five addresses are rejected, with too few bytes, a
# byte of three digits, a group address, a blank inside, and a letter
# after them; and the last, with blanks around it and bytes of one digit
# in lower case, is written, which the dump of 0xFFFFFFB1-B2 shows. baud
# shows the rate, 0 in niceemu, and writes 921600; six rates are
# rejected, one not in the list, a letter after the digits, two numbers,
# and too many digits, baudx and b are no commands; and the last, in upper
# case with blanks around it, is written, which the dump of 0xFFFFFF9F
# shows. h ends each input. dash's printf, the shell of make on Ubuntu, has no \x.
CMDS = ?\rv\rd 0 6\rd\rD 10 1\rq\r\r  c\rabc\177\177\177v\rjunk\003v\r\033[A\033OPv\rr\rr 9000\rd 8000 0\rd 8000\rd 0 100\ri\ri 192.168.1.65\ri 1.2.3\ri 256.0.0.1\ri 1..2.3\ri 1.2.3.4x\ri  010.0.0.1 \rm\rm 02:4E:49:43:45:01\rm 2:4e:49:43:45\rm 2:4e:49:43:45:123\rm 3:0:0:0:0:0\rm 2:4e: 49:43:45:1\rm 2:4e:49:43:45:1x\rm  a:b:c:d:e:f \rbaud\rbaud 921600\rbaud 9600\rbaud 9600x\rbaud 1 2\rbaud 123456789\rbaudx\rb\rBAUD  115200 \rh\r
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
# rom: r runs test/rom.nasm, which traps, twice, then r 0, the cold start,
# which gives the C code its initial values again, and r once more.
ROM  = r\rr\rr 0\rr\rh\r
# sd_write: r runs test/sd.nasm, which writes sector 2, which the image
# shows.
SD_WRITE = r\rh\r
# fat: fat32.img of test/fat_image.py in slot 0 and super.img in slot 1.
# dir mounts slot 0, DIR 1 and dir 0 mount each slot. load frag.bin reads
# the fragmented FRAG.BIN, whose words d shows, the first and the last
# four, and load readme.txt a text file, whose 2 lines are skipped. Then
# a name that is no file, a directory, a long name that is no file, load
# alone, two names, loadx, dirx, dir 2, which has no slot and changes
# nothing, and dir with two numbers, or a slot of 9 digits. load
# HELLO.BIN, r runs it.
FAT  = dir\rDIR 1\rdir 0\rload frag.bin\rd 9000 4\rd 9068 4\rload readme.txt\rload nofile.bin\rload sub\rload toolongname.bin\rload\rload a b\rloadx\rdirx\rdir 2\rdir 1 2\rdir 123456789\rLOAD HELLO.BIN\rr\rh\r
# fatbad: fat16.img in slot 0 and exfat.img in slot 1, which dir rejects
# with the errors of each, and fat1: no card in slot 0 and super.img in
# slot 1, which the first dir mounts
FATBAD = dir\rdir 1\rdir 0\rh\r
FAT1 = dir\rh\r
# fatnone: nonice.img in slot 0, a card without the folder NICE, and
# nicefile.img in slot 1, whose NICE is a file, which dir and load reject
# with error 29, and never fall back to the root's HELLO.BIN
FATNONE = dir\rload hello.bin\rdir 1\rload hello.bin\rh\r
# fatw: a copy of super.img in slot 0 and of full.img in slot 1. l writes
# two words, which save writes to test.bin, an 8.3 name in lower case,
# which dir lists so, and load reads
# back, and d shows. save of 0 words truncates HELLO.BIN, which load then
# finds empty. del deletes test.bin, and a second del finds none. Then
# the arguments that are not: save alone, with a name only, with no
# count, with a fourth word, and with an address of 9 digits, savex, a
# name that is not valid, with a colon, del alone, with two names, and delx, and de 0,
# which is d. On full.img, save of 256 words fills the card with
# FULL.BIN's first 1536 bytes, which dir shows, and is error 30; del
# frees them, and a save of 2 words fits.
FATW = l\r8000 1234ABCD\r8001 5\r\rsave test.bin 8000 2\rdir\rload TEST.BIN\rd 8000 2\rsave hello.bin 8000 0\rload hello.bin\rdel test.bin\rdel test.bin\rsave\rsave x\rsave x 8000\rsave x 8000 1 2\rsave x 123456789 1\rsavex\rSAVE "a:b" 8000 1\rdel\rdel a b\rdelx\rde 0\rdir 1\rsave full.bin 8000 100\rdir\rdel full.bin\rsave full.bin 8000 2\rdir\rh\r
# fatl: lfn.img of test/fat_image.py in slot 0, with long names. dir
# shows them, load reads my prog.bin by its long name in quotes, which r
# runs, then by its 8.3 name, and by its long name in upper case; the
# text files mixed.Bin, lower.txt, and those whose long-name entries
# cross a sector and a cluster, by their names in another case; bad
# sum.txt, whose long-name entry has a wrong checksum, only by its 8.3
# name; a name with no closing quote; caf?.txt, as dir shows café.txt,
# which is no name; λx.txt by its 8.3 name, _X.TXT; and an empty
# name in quotes.
FATL = dir\rload "my prog.bin"\rr\rload MYPROG~1.BIN\rload "MY PROG.BIN"\rload mixed.bin\rload LOWER.TXT\rload "across a sector.txt"\rload "ACROSS A CLUSTER.TXT"\rload "bad sum.txt"\rload badsum~1.txt\rload "my prog.bin\rload caf?.txt\rload _x.txt\rload ""\rh\r
# fatlw: a copy of lfn.img in slot 0. l writes two words, and save writes
# them to new files: mandelbrot.bin, MANDEL~1.BIN, as the MANDEL~1 that
# is there is a .TXT; mandelbrot3.txt, MANDEL~3.TXT after ~1 and ~2;
# Hello.bin, HELLO.BIN with no tail and a long name; lower.bin, LOWER.BIN
# with byte 12's flags and no long name; and "a b.bin", AB~1.BIN. A save
# of MIXED.BIN truncates mixed.Bin, which keeps its name. "a*b" and
# "end." are no names. del deletes mandelbrot1.txt and mandelbrot2.txt,
# whose 4 entries in a row take the 4 of a much longer name of a
# file.bin, and x.bin goes at the end. dir shows them, and load reads
# two back.
FATLW = l\r8000 1234ABCD\r8001 5\r\rsave mandelbrot.bin 8000 2\rsave mandelbrot3.txt 8000 2\rsave Hello.bin 8000 2\rsave lower.bin 8000 2\rsave "a b.bin" 8000 2\rsave MIXED.BIN 8000 1\rsave "a*b" 8000 1\rsave "end." 8000 1\rdel mandelbrot1.txt\rdel "mandelbrot2.txt"\rsave "a much longer name of a file.bin" 8000 2\rsave x.bin 8000 2\rdir\rload "A MUCH LONGER NAME OF A FILE.BIN"\rd 8000 2\rload mandel~1.bin\rh\r

# time: with --step-time, so the clock starts at 0, not set, and counts a
# microsecond a step, and a copy of super.img in slot 0. time shows that
# it is not set, and save writes old.bin with the fixed date. time sets
# 2026-11-11 14:30:01, which time shows, and save writes new.bin with it,
# at 14:30:00 and 100 hundredths. Fifteen times are rejected: 2023-02-29
# and 2100-02-29, as those years have no leap day, 1969 and 2106, before
# and after the years time sets, month 13, November 31, hour 24, minute
# 60, second 60, a year of two digits, a month and a day of one digit, no
# time, a word after it, an hour of three digits, and a time of one
# digit each; timex and ti are no commands. Then the edges that are
# taken: 2000-02-29, 2100-03-01, 2104-02-29, the second past 2^31, the
# last of 2105, and the first of 1970, in upper case with blanks, whose
# year FAT cannot hold, so save writes y1970.bin with the fixed date.
TIME = time\rl\r8000 1\r\rsave old.bin 8000 1\rtime 2026-11-11 14:30:01\rtime\rsave new.bin 8000 1\rtime 2023-02-29 00:00:00\rtime 2100-02-29 00:00:00\rtime 1969-12-31 23:59:59\rtime 2106-01-01 00:00:00\rtime 2026-13-01 00:00:00\rtime 2026-11-31 00:00:00\rtime 2026-11-11 24:00:00\rtime 2026-11-11 23:60:00\rtime 2026-11-11 23:59:60\rtime 26-11-11 00:00:00\rtime 2026-1-1 00:00:00\rtime 2026-11-11\rtime 2026-11-11 01:02:03 x\rtime 2026-11-11 001:02:03\rtime 2026-11-11 1:2:3\rtimex\rti\rtime 2000-02-29 00:00:00\rtime 2100-03-01 00:00:00\rtime 2104-02-29 12:00:00\rtime 2038-01-19 03:14:08\rtime 2105-12-31 23:59:59\rTIME  1970-01-01 00:00:00 \rsave y1970.bin 8000 1\rh\r
# The words of each test that are dumped with the screen: for cmds the
# variables, the cursor's registers, and the IP and MAC addresses, and for the programs the text at
# column 40 of row 4, 80 * 4 + 40 = 360 = 0x168, with its color, and for
# hello the 0x80 after it, the screen's state, in which the return showed
# the cursor that hello hid, the font base, which the return made 0, and
# the row of the glyph of 0x80 that hello drew.
DUMP_cmds    = -d 0xFFFFF000:5 -d 0xFFFFFF80:6 -d 0xFFFFFF9F:1 -d 0xFFFFFFB0:3
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
# For sd_write the results of test/sd.nasm's calls
DUMP_sd_write = -d 0x9100:6
# For fs the results of test/fs.nasm's calls, the entries that fs_readdir
# and fs_readname wrote, the first 45 bytes that fs_read wrote, and the
# names of fs_readname, for fsw the results
# of test/fsw.nasm's, and for fat the numbers of fat_load for load NAME
DUMP_fs       = -d 0x9100:36 -d 0x9180:8 -d 0x9200:45 -d 0x9280:16 -d 0x92A0:11
DUMP_fsw      = -d 0x9100:42
DUMP_fat      = -d 0xFFFFF11A:5
# For rom the number of runs and the results of test/rom.nasm's calls
DUMP_rom      = -d 0x9100:10
# For arp the results of test/arp.nasm's calls, and the cache it copied,
# and for udp the results of test/udp.nasm's, and the bytes and the
# sources that udp_recv wrote
DUMP_arp      = -d 0x9100:37
DUMP_udp      = -d 0x9100:20 -d 0x9180:14
# For net the results of test/net.nasm's calls, the words of net_config,
# and the bytes and the sources that udp_recv wrote
DUMP_net      = -d 0x9100:24 -d 0x9180:8 -d 0x9190:16
MAX_STEPS = 10000000
# The first sector of fat32.img's FAT32 partition (test/fat_image.py), and
# its byte offset, for mtools
FAT32_START = 34816
FAT32_START_BYTES = $(shell echo $$(($(FAT32_START) * 512)))

# Each test runs the monitor with its input and its program, if any, and
# compares the console output, the dumps, and the screen with
# test/NAME.expected. rom runs build/rom.bin in place of the monitor, and
# the address of its trap, which moves with the monitor's code, is shown
# as the label it must be, _rom_trap, from niceasm's symbols. The Halted line and the registers are left out, as
# the steps and the registers change with the code, but for VBASE, bits
# 23-0 of R14, which must be 0, also after hello, which returns with
# VBASE 0x80, and so tests that a program returns to mon_exit.
# test/ring.py checks the ring of the history at the
# sizes of the screen's memory of niceemu and the boards first, and
# test/dis.py the rows of u against nicedis.py and niceasm, and
# test/dhcp.py runs i dhcp against the frames that it builds, and
# test/tftp.py tftp, and test/rtc.py the cold start and time on the words
# of an I2C master that it sets, as a real-time clock. arp and udp run
# with --step-time, as their timeouts
# count, and so does net, and the frames they send are added to their
# output.
test: fmt $(BUILD)/monitor_test.bin $(BUILD)/monitor_8k.bin $(BUILD)/monitor_2k.bin $(BUILD)/hello.bin \
      $(BUILD)/dis.bin $(BUILD)/sd.bin $(BUILD)/arp.bin $(BUILD)/udp.bin $(BUILD)/net.bin \
      $(BUILD)/netdhcp.bin $(BUILD)/rom.bin $(BUILD)/fs.bin $(BUILD)/fsw.bin \
      $(FAT_IMAGES) $(BUILD)/version_test.nasm
	@test '$(FOLDER_UC)' = NICE || { echo "make test needs FOLDER=NICE, not $(FOLDER)"; exit 1; }
	@$(PYTHON) test/ring.py $(EMU) $(BUILD)/monitor_test.bin:32768 \
	  $(BUILD)/monitor_8k.bin:8192 $(BUILD)/monitor_2k.bin:2048
	@$(PYTHON) test/dis.py $(EMU) $(BUILD)/monitor_test.bin $(BUILD)/dis.bin
	@$(PYTHON) test/dhcp.py $(EMU) $(BUILD)/monitor_test.bin $(BUILD)/netdhcp.bin \
	  test/dhcp.expected $(BUILD)/dhcp.out
	@$(PYTHON) test/tftp.py $(EMU) $(BUILD)/monitor_test.bin test/tftp.expected $(BUILD)/tftp.out
	@$(PYTHON) test/rtc.py $(EMU) $(BUILD)/monitor_test.bin
	@$(ROMSIZE)
	@echo 'FFFFFF9E 00020000' > $(BUILD)/ram128k.bin
	@echo 'FFFFFF9E 00010000' > $(BUILD)/ram64k.bin
	@printf '$(LOAD_EMU)' > $(BUILD)/load_emu.txt
	@printf '$(LOAD_64K)' > $(BUILD)/load_64k.txt
	@printf '$(CMDS)' > $(BUILD)/cmds.txt
	@printf '$(RUN)' > $(BUILD)/run.txt
	@printf '$(RESET)' > $(BUILD)/reset.txt
	@printf '$(SCROLL)' > $(BUILD)/scroll.txt
	@printf '$(SD_WRITE)' > $(BUILD)/sd_write.txt
	@printf '$(ROM)' > $(BUILD)/rom.txt
	@printf '$(FAT)' > $(BUILD)/fat.txt
	@printf '$(FATBAD)' > $(BUILD)/fatbad.txt
	@printf '$(FAT1)' > $(BUILD)/fat1.txt
	@printf '$(FATNONE)' > $(BUILD)/fatnone.txt
	@printf '$(FATW)' > $(BUILD)/fatw.txt
	@printf '$(FATL)' > $(BUILD)/fatl.txt
	@printf '$(FATLW)' > $(BUILD)/fatlw.txt
	@printf '$(TIME)' > $(BUILD)/time.txt
	@$(PYTHON) test/sd_image.py $(BUILD)/sd.img
	@$(PYTHON) test/sd_image.py --written $(BUILD)/sd_written.img
	@{ printf '$(LOAD_HEAD)'; head -n 3 $(BUILD)/hello.bin | awk '{ printf "%s\r\n", $$0 }'; \
	  tail -n +4 $(BUILD)/hello.bin; printf '$(LOAD_TAIL)'; } > $(BUILD)/load.txt
	@fail=0; for t in cmds scroll load load_emu load_64k sd_write arp udp net rom fs fsw fat fatw fatl fatlw fatbad fat1 fatnone time \
	           hello reset hello_c; do \
	  opts=; rom=$(BUILD)/monitor_test.bin; \
	  case $$t in \
	    cmds) prog=; input=cmds; dump='$(DUMP_cmds)';; \
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
	    rom) prog=; rom=$(BUILD)/rom.bin; input=rom; dump='$(DUMP_rom)';; \
	    fs) prog=$(BUILD)/fs.bin; input=run; dump='$(DUMP_fs)'; \
	      opts="--sd0 $(BUILD)/fat/fat32.img --sd1 $(BUILD)/fat/super.img";; \
	    fsw) prog=$(BUILD)/fsw.bin; input=run; dump='$(DUMP_fsw)'; \
	      cp $(BUILD)/fat/fat32.img $(BUILD)/fsw0.img; \
	      mattrib -i $(BUILD)/fsw0.img@@$(FAT32_START_BYTES) +r ::NICE/KEEP.TXT; \
	      rm -f $(BUILD)/fsw1.img; cp $(BUILD)/fat/super.img $(BUILD)/fsw1.img; chmod a-w $(BUILD)/fsw1.img; \
	      opts="--sd0 $(BUILD)/fsw0.img --sd1 $(BUILD)/fsw1.img";; \
	    fat) prog=; input=fat; dump='$(DUMP_fat)'; \
	      opts="--sd0 $(BUILD)/fat/fat32.img --sd1 $(BUILD)/fat/super.img";; \
	    fatw) prog=; input=fatw; dump=; \
	      cp $(BUILD)/fat/super.img $(BUILD)/fatw0.img; cp $(BUILD)/fat/full.img $(BUILD)/fatw1.img; \
	      opts="--sd0 $(BUILD)/fatw0.img --sd1 $(BUILD)/fatw1.img";; \
	    fatl) prog=; input=fatl; dump=; opts="--sd0 $(BUILD)/fat/lfn.img";; \
	    fatlw) prog=; input=fatlw; dump=; \
	      cp $(BUILD)/fat/lfn.img $(BUILD)/fatlw0.img; opts="--sd0 $(BUILD)/fatlw0.img";; \
	    fatbad) prog=; input=fatbad; dump=; \
	      opts="--sd0 $(BUILD)/fat/fat16.img --sd1 $(BUILD)/fat/exfat.img";; \
	    fat1) prog=; input=fat1; dump=; opts="--sd1 $(BUILD)/fat/super.img";; \
	    time) prog=; input=time; dump=; cp $(BUILD)/fat/super.img $(BUILD)/time0.img; \
	      opts="--step-time --sd0 $(BUILD)/time0.img";; \
	    fatnone) prog=; input=fatnone; dump=; \
	      opts="--sd0 $(BUILD)/fat/nonice.img --sd1 $(BUILD)/fat/nicefile.img";; \
	    hello) prog=$(BUILD)/hello.bin; input=run; dump='$(DUMP_hello)';; \
	    reset) prog=$(BUILD)/hello.bin; input=reset; dump='$(DUMP_hello)';; \
	    hello_c) prog=$(BUILD)/hello_c.bin; input=run; dump='$(DUMP_hello_c)'; \
	      $(MAKE) --no-print-directory $$prog || exit 1;; \
	  esac; \
	  cat $$rom $$prog > $(BUILD)/$$t.full.bin; \
	  $(EMU) -s -n $(MAX_STEPS) -i $(BUILD)/$$input.txt $$dump $$opts $(BUILD)/$$t.full.bin \
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
	    if [ $$t = fatlw ]; then \
	      $(PYTHON) test/fat_check.py $(BUILD)/fatlw0.img mandelbrot.bin "a b.bin" \
	        "a much longer name of a file.bin" mixed.Bin; fi; } \
	    > $(BUILD)/$$t.out; \
	  if [ $$t = rom ]; then \
	    trap=$$(sed -n 's/^\(........\) _rom_trap$$/\1/p' $(BUILD)/rom.sym | tr a-f A-F); \
	    sed -i "s/ at $$trap/ at _rom_trap/" $(BUILD)/$$t.out; fi; \
	  if cmp -s test/$$t.expected $(BUILD)/$$t.out; then echo "PASS monitor $$t"; \
	  else echo "FAIL monitor $$t"; diff test/$$t.expected $(BUILD)/$$t.out; fail=1; fi; \
	done; exit $$fail

# The table of the monitor's words in INTERNALS.md, "The ROM's words",
# which make test checks against monitor_test.bin, and make romsize
# writes. Its sources are those of monitor_test.bin, with the version of
# the tests in a file of its own.
ROMSIZE = $(PYTHON) ../tools/romsize.py monitor --bin $(BUILD)/monitor_test.bin \
            $(addprefix --c ,$(ROM_C)) --doc INTERNALS.md $(SOURCES) $(BUILD)/rom_c.nasm \
            $(RUNTIME_ROM) $(BUILD)/folder.nasm $(BUILD)/version_test.nasm

$(BUILD)/version_test.nasm: | $(BUILD)
	@echo "VERSION .ASCII_L 'V9.9'" > $@

romsize: $(BUILD)/monitor_test.bin $(BUILD)/version_test.nasm
	@$(ROMSIZE) --write

# The layout of the sources, as nice_cpu's nicefmt checks it
fmt:
	@$(FMT) $(SOURCES) test/hello.nasm test/dis.nasm test/sd.nasm test/arp.nasm test/rom.nasm \
	  test/fs.nasm test/fsw.nasm test/udp.nasm test/net.nasm test/netdhcp.nasm

$(BUILD):
	@mkdir -p $@

clean:
	rm -rf $(BUILD)
