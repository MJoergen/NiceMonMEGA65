# The ROM, for the top Makefile, monitor/Makefile, and basic/Makefile,
# which set ROOT to this directory, as seen from where they run, and
# PYTHON.
#
# The ROM is two images, assembled apart (issue #152): the monitor's at
# 0, which monitor/Makefile builds into monitor/build/monitor_image.bin,
# and BASIC's at BASIC_BASE, 0x3000 (monitor/common.nasm), which
# basic/Makefile builds into basic/build/basic_image.bin. build/rom.bin
# joins them, and is the ROM of the boards and the tools. The tests take
# build/rom_test.bin, which joins the images of the tests,
# monitor_image_test.bin and basic_image_test.bin, with the version V9.9,
# so that their output does not change with every commit. BASIC's image
# has a header after its vectors, which tools/basic_rom.py fills in after
# assembly (issue #153), and make rom writes it as a file for a card too,
# basic/build/basic.rom. Neither image
# has a label of the other: BASIC calls the monitor through the entries
# of the dispatch table alone, their .EQUs in mon.nasm, as a program does,
# and the monitor jumps to BASIC through its two vectors alone, BAS_COLD
# and BAS_WARM of common.nasm.
#
# The assembler has no include, so each image is the cat of its sources,
# MON_SOURCES or BAS_SOURCES, with its copies of the files that both
# share, SHARED, then its build/version.nasm, which defines VERSION, the
# string of the banner, and the folder FOLDER's name: the monitor's
# build/folder.nasm, its 8.3 name, and BASIC's build/basic_folder.nasm,
# its texts.

ROM_ASM  = $(PYTHON) $(ROOT)/nice_cpu/assembler/niceasm.py
ROM_TOOLS = $(wildcard $(ROOT)/nice_cpu/assembler/*.py)
# Fills in and checks the header of BASIC's image (issue #153)
BAS_ROM_TOOL = $(ROOT)/tools/basic_rom.py
BAS_ROM  = $(PYTHON) $(BAS_ROM_TOOL)
SHARED   = $(addprefix $(ROOT)/monitor/,common.nasm monlib.nasm mon.nasm)
MON_SOURCES = $(addprefix $(ROOT)/monitor/,monitor.nasm monitor_sd.nasm monitor_fat.nasm \
                monitor_eth.nasm monitor_tcp.nasm monitor_clock.nasm monitor_basic.nasm) $(SHARED)
BAS_SOURCES = $(addprefix $(ROOT)/basic/,basic.nasm basic_expr.nasm basic_prog.nasm basic_cmd.nasm basic_net.nasm \
                basic_time.nasm basic_dis.nasm basic_edit.nasm basic_str.nasm basic_struct.nasm basic_mach.nasm \
                basic_trap.nasm) $(SHARED)

VERSION ?= $(shell git -C $(ROOT) describe --tags --always --dirty 2>/dev/null || echo unknown)
# The folder of the card's root directory that holds NiceMon's files
# (monitor_fat.nasm, monitor/README.md, "Files"): NICE, or with make
# FOLDER=NAME another 8.3 name of 1 to 8 letters, digits, _, and -, in
# either case. A FOLDER of the environment is passed over, as a shell may
# well export one of that common name for something else; the name counts
# on the command line, make FOLDER=NAME, alone, which make passes on to
# the Makefiles that it runs.
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
# The version of the release, and that of the tests
VERSION_TEXT = $(call PACKED,VERSION,$(VERSION))
VERSION_TEST = $(call PACKED,VERSION,V9.9)
# $(1) is written to the file $(2) only when it changes, so that an image,
# and a bitstream with it, is not built again for nothing
WRITE_NEW = $(1) | cmp -s - $(2) || $(1) > $(2)

# Each packed text of the ROM must end with a 0 byte (monitor/test/texts.py)
CHECK_TEXTS = $(PYTHON) $(ROOT)/monitor/test/texts.py
# An image must end below $(2): the monitor below BASIC_BASE, and BASIC
# below PROGRAM, 0x8000, the end of the ROM (common.nasm). niceasm writes
# the words in the order of their addresses, so the last line has the
# last.
EQU_OF   = $(shell sed -n 's/^$(1) *\.EQU *\(0x[0-9A-Fa-f]*\).*/\1/p' $(ROOT)/monitor/common.nasm)
BAS_BASE = $(call EQU_OF,BASIC_BASE)
ROM_END  = $(call EQU_OF,PROGRAM)
CHECK_END = $(PYTHON) -c 'import sys; top = int(open(sys.argv[1]).read().split()[-2], 16); \
  end = int(sys.argv[2], 16); top < end or sys.exit(f"{sys.argv[1]} reaches {top:08X}, past its end, {end:08X}")'

# The ROM, and that of the tests: each image from its Makefile, then the
# two joined, written only when they change. The default goal stays the
# includer's: an empty .DEFAULT_GOAL makes it the next target.
ROM_GOAL := $(.DEFAULT_GOAL)
$(ROOT)/build/rom.bin $(ROOT)/build/rom_test.bin: $(ROOT)/build/rom%.bin: FORCE
	@$(MAKE) -s --no-print-directory -C $(ROOT)/monitor build/monitor_image$*.bin
	@$(MAKE) -s --no-print-directory -C $(ROOT)/basic build/basic_image$*.bin $(if $*,,build/basic.rom)
	@mkdir -p $(ROOT)/build
	@cat $(ROOT)/monitor/build/monitor_image$*.bin $(ROOT)/basic/build/basic_image$*.bin > $@.new
	@if cmp -s $@.new $@; then rm $@.new; else mv $@.new $@; fi

.PHONY: FORCE
.DEFAULT_GOAL := $(ROM_GOAL)
