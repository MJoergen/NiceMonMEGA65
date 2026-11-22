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
# starts at BASIC_BASE, 0x3000, with the two vectors that the monitor
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

.PHONY: all test bench ecma55 fmt clean

all: $(BUILD)/basic.rom

# The image, and that of the tests, with the version V9.9. The assembler
# writes build/basic_asm*.bin, and ../tools/basic_rom.py fills in its
# header (issue #153): the length, the version as a number, the flags,
# and the checksum. The tests' image has "keep", so that the monitor of
# the tests, which runs from RAM, keeps it.
BAS_FILL      = --version '$(VERSION)'
BAS_FILL_test = --version V9.9 --keep
$(BUILD)/basic_image.bin $(BUILD)/basic_image_test.bin: $(BUILD)/basic_image%.bin: \
    $(BAS_SOURCES) $(BUILD)/version%.nasm $(BUILD)/basic_folder.nasm $(ROM_TOOLS) \
    $(BAS_ROM_TOOL) | $(BUILD)
	@$(CHECK_TEXTS) $(filter-out $(SHARED),$(BAS_SOURCES))
	@cat $(BAS_SOURCES) $(BUILD)/basic_folder.nasm $(BUILD)/version$*.nasm > $(BUILD)/basic$*_all.nasm
	@$(ASM) -o $(BUILD)/basic_asm$*.bin $(BUILD)/basic$*_all.nasm
	@$(CHECK_END) $(BUILD)/basic_asm$*.bin $(ROM_END)
	@$(BAS_ROM) fill $(BUILD)/basic_asm$*.bin $@ $(BAS_FILL$*)

# The image as a file for a card, BASIC*.ROM, which a release names after
# its tag (doc/BASIC_ROM.md)
$(BUILD)/basic.rom: $(BUILD)/basic_image.bin
	@cp $< $@

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
# the cursor keys up and down, ESC [ A and ESC [ B, which move the
# cursor to READY. and back, so the line is sent again at its RETURN,
# and the function key ESC O P, which is dropped. An empty line and one of blanks run nothing and print no
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
# only, and SAVE and BSAVE a TFTP server that is no IP address, which
# needs no card nor network; a keyword in mixed case, the closing quote
# left out, and dump , 2, which goes on from the last. halt ends each
# input. dash's printf, the shell of make on Ubuntu, has no \x.
CMDS = help\rver\rdump 0, 6\rdump\rDUMP 0x10, 1\rq\rloadx\r\r  cls\rabc\177\177\177ver\rjunk\003ver\r\033[A\033[B\033OPver\rsys 0x8000\rsys 0x9000\rdump 0x8000, 0\rdump 0x8000\rdump 0, 256\rip\rip "192.168.1.65"\rip "1.2.3"\rip "256.0.0.1"\rip "1..2.3"\rip "1.2.3.4x"\rip "  010.0.0.1 "\rmac\rmac "02:4E:49:43:45:01"\rmac "2:4e:49:43:45"\rmac "2:4e:49:43:45:123"\rmac "3:0:0:0:0:0"\rmac "2:4e: 49:43:45:1"\rmac "2:4e:49:43:45:1x"\rmac "  a:b:c:d:e:f "\rbaud\rbaud 921600\rbaud 9600\rBAUD  115200 \rip 1.2.3.4\rsys\rsys 0x\rdump 12ab\rdump 1,\rbaud 1 2\rver x\rload "a.bin" "1.2.3.4"\rdump 4294967296\rdump 0x100000000\rload "x.txt"\rload "x"\rsave "x", "1.2.3"\rbsave "x", 0, 1, "1.2.3:"\rHeLp x\rload "x.bin\rdump , 2\rhalt\r
# basic: the scanner of a statement, with no card and no IP address, so
# that the statements that need them stop at once. A keyword in mixed
# case and with blanks around it runs; a comma, a character of 0xE9, or
# another word after it, or an _ glued to it, makes it no statement, or a
# Syntax error with its lines of HELP, which each statement shows; with a
# letter or a digit glued to it, it is a name, and no statement. Numbers,
# which are expressions that must fit a signed word: in decimal and hex,
# with 0X, leading zeros, and the 76 characters of a full line;
# 0xFFFFFFFF, which is -1, the largest decimal one, 2147483647, and a
# number of 32 bits and more, which are an Illegal quantity; a letter
# after a number; and the numbers that are not. 0x without digits is no
# number, so dump 0x, 1, dis 0x, 1, baud 0x, and dir 0x"1.2.3.4" are a
# Syntax error, as is dir 99999999999"1.2.3.4", with no comma (issue
# #151, S1 and S2). save "x", "y", 99999999999 is a Syntax error at its
# second comma, before its number (S3), and mac "" is no MAC address, as
# ip "" is no IP address (S5). A name in a number's place, x, is an
# Undefined variable. Strings: an empty one, a name glued to load, a
# server without a comma, or with no closing quote, and the arguments
# that are too few or too many for each statement, and four that fail
# with no card or no IP address, whose tokens test/trap.bas dumps.
# dir "bad" is no TFTP server but the path of a folder, which fails with
# no card (issue #168).
# ip "1.2.3.4, with no closing quote, writes the IP address, which the
# dump of 0xFFFFFFB0 shows. Last, 9 ver is no statement but line 9 of a
# program, which list shows.
ZEROS72  = $(shell printf '%072d' 32768)
BASIC = vEr\r   ver   \rver,\rver\351\r\351ver\rsys0x8000\rdumpx\rdum\rdis1\ri\rsys_\r"ver"\rsave x\rdelete x\rdhcp x\rmac x\rtime x\rntp x\rdis x\rcls x\rhalt x\rdir x\rsys 32768\rsys $(ZEROS72)\rSYS 0X8000\rsys 0x08000\rsys 4294967295\rsys 2147483647\rsys 2147483648\rsys 0xFFFFFFFF\rsys 0x0000000ffffffff\rsys 4294967296\rsys 0x100000000\rsys 99999999999x\rsys 0x8000x\rsys 0x0x8000\rsys 1e3x\rsys 32768.\rsys -1\rsys "x"\rsys 0xg\rsys 0x8000,\rdump 0x8000, 0\rdump 0x, 1\rdump 0x , 2\rdump 0x 1\rdump 1, 4294967296\rdump 1, 0x\rdis 0x8000, 1\rdis 0x, 1\rdis ,1\rdis 0x8000,\rbaud 0x\rbaud 0x 1\rbaud 4294967296\rbaud 1,\rbaud 0x1C200\rload ""\rload ".bin"\rload"a.BiN"\rload "a.bin",\rload "a.bin" ,"1.2.3.4"\rload "a.bin", "1.2.3.4" x\rload "a.bin", "bad"\rload x\rload "a.bin", "1.2.3.4\rLOAD  \r\rsave "x", "y" z\rsave "x" "y"\rsave "x",\rsave "x", 1\rbsave "x", 0x, 1\rbsave "x", 1, 99999999999\rsave "x", "y", 99999999999\rbsave "x", 1, 2, "1.2.3.4"\rbsave "x", 1, 2, "y" z\rbsave "x", 1, 2, "y",\rsave "abc\rbsave "a.b", 0x8000, 1\rdelete "x"\rdelete "x", "y"\rdelete ""\rdir\rdir 0x\rdir 0x"1.2.3.4"\rdir 99999999999"1.2.3.4"\rdir 99999999999\rdir "1.2.3.4", "*.bin"\rdir "bad"\rdir "1.2.3.4",\rdir 1,\rdir 1 "x"\rdir 5\rip ""\rip "1.2.3.4" x\rmac ""\rmac "02:4E:49:43:45:00" x\rtime "bad"\rtime "1" x\rntp "1.2.3.4" x\rntp "1.2.3.4",\rntp "", "bad"\rntp ""\rntp "1.2.3.4", "+01:00"\rbsave "abc",1,2\rsave "x", "1.2.3.4"\rbsave "a.b", 1, 2\rdir "1.2.3.4", "*"\rip "1.2.3.4\r9 ver\rlist\rhalt\r
# expr: the numbers of stage 2 (issue #113): the operators and their
# order, the word operators, the comparisons, the functions, the
# constants in hex, with a point, and with an exponent, and PRINT's
# format, with fixed notation from 1E-4 to 1E14 and E notation else, -0
# as 0, the smallest double, half of it, which goes to 0, and the
# largest. PRINT's items: ;, which joins them, a comma,
# to the next column of 8, the CR LF that ; or a comma at the end leaves
# out, before which READY. starts a row of its own, TAB and SPC, and
# their counts of 0 to 255. Variables: names in either case, of 16
# characters, not 17, no % in a function's name, and A$, a string, LET and the assignment without it, a
# keyword that is no name, an undefined one, made by its = alone, and
# colons. The errors: division by zero by /, DIV, and MOD, an overflow
# in a computation and in a constant, the Illegal quantity of SQR, of a
# word operator's operand, and of a shift by -1, and the Syntax errors
# of expressions and constants, and the Type mismatch of a string in an expression. A line of 74 signs is too deep for the processor's stack,
# and 17 operands pending for the FPU's stack, where 16 are not. PEEK
# and POKE, with a value rounded toward zero and an address of 2^32 -
# 256, which is no word. DUMP takes expressions. A LOAD that writes no
# word, here with no card, ends the line, and keeps the variables. After
# a NEW, a table with a length of 99 at its start is cut there. Last, RAM_WORDS is set so that there
# is room for four variables, B, E, F, and G, and H is Out of memory.
EXPR = ? 1+2*3, (1+2)*3, 2*3+1, 10-2-3, 100/10/5\r? -2*3, - 3 + 4, +5, --5, 2*-3\r? 7 DIV 2, -7 DIV 2, 7 MOD -2, -7 MOD 2, 1 << 4, -1 >> 28, 1 << 32\r? 5 AND 3, 5 OR 3, 5 XOR 3, NOT 0, NOT 5 AND 3\r? 1 = 1, 1 <> 1, 1 < 2, 2 <= 1, 3 > 2, 2 >= 3\r? NOT 1 = 2, 1 + 1 = 2 AND 3 < 4, 1 OR 2 XOR 3, 1 << 2 + 1, 2 + 3 < 6\r? ABS(-2.5), SGN(0), SGN(-0.1), INT(2.9), INT(-2.1), SQR(16)\r? 0x1F, 0xFFFFFFFF, 0X7fffffff, 1E3, 1.5E-3, .5, 5., 1e+2\r? 1/3; 2/3; 1E15; 1E14; 123456789012345678; 0.0001; 0.00001; -1E-100\r? -0, 0.1 + 0.2, 4.9E-324, 4.9E-324 / 2, 1.79769313486231E308\r? "A";1;"B", "C"; ""\r? "X";\r? 1,\r? "AB";TAB(5);"C";SPC(3);"D"\r? TAB(0);"E";TAB(1);"F";SPC(0);"G"\r? SPC(256)\r? TAB(-1)\rTotalSum = 5: totalsum = totalsum + 1: ? TOTALSUM\ra1b2c3d4e5f6g7h8 = 16: ? A1B2C3D4E5F6G7H8\ra1b2c3d4e5f6g7h8i = 1\rFNA%% = 1\rA$$ = "X"\rLET B = 2: ? B\rLET 5 = 2\rLET\rC\rPRINTX\rprint = 1\rand = 1\r? D\rD =\r? D\rX=1:Y=X+1:?Y\r: : ? 1 : : ? 2 :\r? 1/0\r? 0/0\r? 5 MOD 0\r? 5 DIV 0\r? 1E308*10\r? SQR(-1)\r? 1E400\r? 2147483648 AND 1\r? 1 << -1\r? (1\r? 1)\r? 1 +\r? 1..2\r? 1.2.3\r? 1E\r? 0x\r? 0x123456789\r? 12ab\r? 1 + "A"\r? 1;2;3;4;5;6 / 0\r?--------------------------------------------------------------------------1\r?1+(2+(3+(4+(5+(6+(7+(8+(9+(1+(2+(3+(4+(5+(6+(7+(8+(9)))))))))))))))))\r?1+(2+(3+(4+(5+(6+(7+(8+(9+(1+(2+(3+(4+(5+(6+(7)))))))))))))))\rPOKE 0x9000, -1: ? PEEK(0x9000), PEEK(0x9000) AND 0xFF\rPOKE 0x9001, 3.9: ? PEEK(0x9001), PEEK(0x9000 + 1)\rPOKE 4294967040, 0\r? PEEK(0xFFFFFF9E)\rDUMP 0x9000 + 0, 1 + 1\rQ = 0x9000: DUMP Q, 2\rA = 1: LOAD "X.BIN": ? A\r? A\rNEW\rPOKE 0x8002, 99: ? B\rB = 7: ? B\rPOKE 0xFFFFFF9E, 0x9E10\rE = 1: F = 2: G = 3\rH = 4\r? B; E; F; G\rhalt\r
# funcs: the functions of stage 6 (issue #117), whose values
# test/functions.py checks bit for bit. Each function, in upper and in
# lower case, and PI. ^ binds more than the signs and groups to the
# left, so -2 ^ 2 is -4 and 2 ^ 3 ^ 2 is 64, and 0 ^ 0 is 1. RND is
# from 0 to below 1, RND of the same negative number gives the same
# numbers after it, and the sum of 1000 is about 500. Names that start
# as LOG2 does, or that end in digits, are variables. LIST of a line
# with each function, and of the keywords after LOG10 in the table,
# which a byte below A ends only before a letter. The errors: the Illegal
# quantity of an argument that a function does not take, SIN of more than
# 2^20 * PI / 2, and a negative number to a fraction; the Division by
# zero of LOG(0) and of 0 ^ -1; the Overflow of EXP and ^; EXP(-1000),
# which is 0; and the Syntax errors of a function without (, PI with
# one, RND alone, ^ without its operand, and a function's name as a
# variable.
FUNCS = ? SIN(0), COS(0), TAN(0), ATAN(1) * 4, PI\r? ASIN(1), ACOS(-1), LOG(EXP(2)), LOG2(1024), LOG10(0.001), EXP(0)\r? log10(100), Log2(0.5), sin(pi), cos(Pi / 3), atan(-1E300)\r? 2 ^ 10, -2 ^ 2, (-2) ^ 3, 2 ^ 3 ^ 2, 2 ^ -1, 2 * 3 ^ 2, 4 ^ 0.5, 0 ^ 0\r? RND(1) >= 0 AND RND(1) < 1, RND(0) < 1, RND(5) >= 0\rA = RND(-7): B = RND(1): C = RND(-7): D = RND(1): ? A = C AND B = D, A <> B\rS = 0: FOR I = 1 TO 1000: S = S + RND(1): NEXT: ? INT(S)\rLOG2X = 3: LOG1 = 4: SIN1 = 5: ? LOG2X + LOG1 + SIN1\r10 A = SIN(PI / 2) + COS(1) * TAN(1) - ATAN(1) ^ 2 + ASIN(0.5) / ACOS(0.5)\r20 B = LOG(2) + LOG2(2) + LOG10(2) - EXP(2) * RND(1) - PI -1 + 2 ^ -A\r30 PRINT TAB(2); SPC(1): IF A THEN 40 ELSE 40\r40 FOR I = 1 TO 2 STEP 1: NEXT\rLIST\rRUN\r? LOG(-1)\r? ASIN(1.5)\r? ACOS(-2)\r? SIN(1E7)\r? TAN(-2E6)\r? (-8) ^ (1 / 3)\r? LOG(0)\r? 0 ^ -1\r? EXP(710)\r? 10 ^ 400\r? EXP(-1000)\r? SIN 1\rA = PI(1)\r? RND\r? 2 ^\rSIN = 1\rLOG10 = 1\rPI = 3\rhalt\r
# prog: the programs of stage 3 (issue #114), test/prog.bas typed line
# by line, each line ended with CR. Lines entered out of order, replaced,
# and deleted, a number glued to its statement, lines 0 and 65535, and
# 65536, which is a Syntax error. An edit keeps the variables, which a
# line's names get unassigned, and RUN clears. LIST of a range, and of
# each kind of token: the constants as they were typed, the strings, one
# without its closing quote, the operators and their blanks, the signs,
# and REM's text as it is. The format of a line in the dump. FOR with a
# negative step, one of 0.5, a loop past its limit that runs once, and
# nested loops, with NEXT J, I, NEXT I that drops J's frame, a FOR that
# drops the frames after its variable's, GOSUB in a loop, and a RETURN
# that drops a loop's frame. IF with THEN and ELSE, nested on one line,
# with line numbers, and with GOTO. STOP, END, and CONT, which an edit
# and an error end. The errors in a program, with the line's number:
# Division by zero, Undefined variable, Undefined line, the Out of memory
# of a GOSUB without end, and a Syntax error, which shows its lines of
# HELP; and the line numbers that are none: an expression, a fraction,
# and a number in hex.
# files: the programs' texts on a card (issue #60), test/files.in typed
# line by line, on a copy of super.img with the files of
# test/files_card.py. A program with each kind of token is saved as
# PROG.BAS, loaded after NEW, listed, and run, and run with RUN "PROG",
# which clears X. PC.BAS, as a PC writes it, loads and runs. BAD.BAS,
# LONG.BAS, WIDE.BAS, and HIGH.BAS each end the load at a line, which is
# shown, with the lines before it kept; NONE.BAS is not there, so LOAD
# and RUN keep the program. SAVE and LOAD of a name with a dot, T.TXT,
# and of an empty program, RUN "HELLO.BIN", which calls it at 0x8000,
# RUN with a number or a word after its name, a program that runs the
# next, SAVE to TFTP, and a CTRL-C that breaks a SAVE, whose file is
# closed, and empty, which LOAD then passes over. The failures of
# issue #158: a program whose TRAP takes BSAVE to slot 1, which has no
# card, Device not present, and LOAD, with slot 0 mounted again, and
# DELETE of a file that is not there, File not found, and whose handler
# prints ER, EL, DS, ERR$(ER), and DS$; LOAD of a file that is not there with no TRAP, which stops the
# program; and LOAD of a program's text that is not there, which a TRAP
# does not take, and which keeps the program. DIR lists the files.
# keys: INPUT, GET, the break key, and the keys typed ahead (issue
# #114). INPUT of two numbers, with too few, which ask for the rest with
# ??, too many, which are Extra ignored, a line that is no number, two
# that the tokenizer refuses or that have no comma between them, each
# Redo from start, signs, and constants in hex and with an exponent.
# INPUT with a prompt, and three that are a Syntax error: a prompt with
# no ;, and a comma with no variable after it. CTRL-C at INPUT is a
# break, after which CONT runs INPUT again. INPUT and GET in direct mode,
# which make their variables, and GET, which takes the next byte, here R.
# A GOTO without end, which the CTRL-C after RUN breaks, and again after
# CONT. A loop, during which the poll takes the bytes after RUN into the
# ring, from which GET takes X and Y, and the line after them comes. A
# CTRL-C breaks LIST. Last, a loop of 3000 statements whose poll takes
# the 36 bytes after RUN, of which the ring keeps 31 and drops 5; GET
# shows those kept, until the input ends, and the program halts itself.
KEYS_ABC = ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789
KEYS = 10 INPUT A, B: PRINT A + B\rRUN\r1, 2\rRUN\r1\r2\rRUN\r1, 2, 3\rRUN\rx\r1..2\r1 2\r3, 4\rRUN\r-1, +2.5\rRUN\r0x10, 1E2\r10 INPUT "SUM"; A: ? A\rRUN\r5\r10 INPUT "A" A\rRUN\r10 INPUT A,\rRUN\r10 INPUT A: ? A\rRUN\r\003CONT\r7\rINPUT Z: ? Z\r8\rINPUT Y, W: ? Y; W\r9,10\rGET Q: ? Q\rR10 GOTO 10\rRUN\r\003CONT\r\003? 1\r10 FOR I = 1 TO 300: NEXT: GET A: GET B: PRINT A; B\rRUN\rXY?1\rLIST\r\003? 2\r10 FOR I = 1 TO 3000: NEXT\r20 GET A: IF A THEN PRINT A;: GOTO 20\r30 HALT\rRUN\r$(KEYS_ABC)
# edit: the screen editor (issue #118). Two lines, LIST, and the cursor
# keys up to the first and right into its text, where AB is inserted;
# RETURN stores it, and RETURN again the next, whose line is unchanged;
# down to an empty row, and RUN. Then 70 Y typed into the first line,
# which grows into a second row, so the rows below move down; LIST and
# RUN. INPUT takes the answer after its prompt: 21; 13 with a DEL left
# of the 3; and 5, two DELs, of which the second is at the prompt and
# does nothing, and 6. A DEL in the middle of PRINT 12345. A line of
# two rows, entered again from its first row with RETURN. CTRL-C, and
# the cursor key down at the last row, which scrolls. Before all that,
# an X that POKE leaves on the row of the next line, at its column 10,
# is no part of PRINT 1, which the row after READY. takes blank; nor is
# one after INPUT's prompt of its answer, nor one after AUTO's number of
# its line, which LIST shows. A program whose 80 characters fill a row
# leaves the cursor at the next row's start, where READY. is a line of
# its own: the word of scr_links, which DUMP shows, is 0.
UP = \033[A
DN = \033[B
RT = \033[C
LT = \033[D
X10 = XXXXXXXXXX
Y10 = YYYYYYYYYY
EDIT = cls\rPOKE 0xFFFF00FA, 88\rPRINT 1\rPOKE 0xFFFF0235, 88: INPUT A: PRINT A\r7\rPOKE 0xFFFF0384, 88: AUTO\rREM\r\rLIST\r10 FOR I = 1 TO 80: PRINT "X";: NEXT\rRUN\rDUMP 0xFFFFF004, 1\rNEW\rcls\r10 PRINT "HELLO"\r20 PRINT "WORLD"\rLIST\r$(UP)$(UP)$(UP)$(RT)$(RT)$(RT)$(RT)$(RT)$(RT)$(RT)$(RT)$(RT)$(RT)AB\r\r$(DN)RUN\r$(UP)$(UP)$(UP)$(UP)$(UP)$(UP)$(UP)$(RT)$(RT)$(RT)$(RT)$(RT)$(RT)$(RT)$(RT)$(RT)$(RT)$(RT)$(RT)$(RT)$(RT)$(RT)$(RT)$(RT)$(Y10)$(Y10)$(Y10)$(Y10)$(Y10)$(Y10)$(Y10)\r$(DN)$(DN)$(DN)$(DN)$(DN)$(DN)LIST\rRUN\rINPUT A: PRINT A * 2\r21\rINPUT B: PRINT B\r13$(LT)\177\rINPUT C: PRINT C\r5\177\1776\rPRINT 12345$(LT)$(LT)\177\rPRINT "$(X10)$(X10)$(X10)$(X10)$(X10)$(X10)$(X10)$(X10)$(X10)"\r$(UP)$(UP)$(UP)$(UP)$(UP)\rjunk\003$(DN)$(DN)$(DN)HALT\r
# lines: DELETE of lines, RENUMBER, and AUTO (issue #118, step 4). A
# program whose GOTO, GOSUB, THEN, and GOTO after : jump forward and
# back, RENUMBER 100, 5 of it, which RUN shows unchanged; DELETE of a
# range, of one line, and of all up to a number; RENUMBER with no
# numbers, 10 and 10; RENUMBER past 65535 and with a step of 0, each an
# Illegal quantity that changes nothing; DELETE with no range, a Syntax
# error, and DELETE 50-10, which deletes nothing. AUTO 200, 20 types 200
# and 220, and the line of 240 alone ends it; AUTO, 10 and 10, ends at
# CTRL-C. A GOTO to a line that is not there keeps its number.
LINES = 10 PRINT "A"\r20 GOTO 40\r30 PRINT "C"\r40 GOSUB 60: IF 1 THEN 70\r50 END\r60 RETURN\r70 PRINT "Z": GOTO 50\rRENUMBER 100, 5\rLIST\rRUN\rDELETE 105-110\rLIST\rDELETE 130\rDELETE -100\rLIST\rRENUMBER\rLIST\rRENUMBER 65535\rRENUMBER 1, 0\rDELETE\rDELETE 50-10\rLIST\rAUTO 200, 20\rPRINT 1\rPRINT 2\r\rLIST\rNEW\rAUTO\rREM X\r\003LIST\r5 GOTO 999\rRENUMBER 1000\rLIST\rHALT\r
# long: the editor's limit of 254 characters. Lines 100 and 1000, each
# 28 times ?1, which LIST writes as PRINT 1, so that line 100 lists with
# 254 characters and line 1000 with 255. LIST 100, the cursor up to the
# end of its text, a DEL, and 2 for the last 1: RETURN stores the line,
# all 254 characters of it. LIST 1000, the cursor up into it, and RETURN:
# a Line too long, which stores nothing, as the last LIST shows.
Q28 = ?1:?1:?1:?1:?1:?1:?1:?1:?1:?1:?1:?1:?1:?1:?1:?1:?1:?1:?1:?1:?1:?1:?1:?1:?1:?1:?1:?1
RT14 = $(RT)$(RT)$(RT)$(RT)$(RT)$(RT)$(RT)$(RT)$(RT)$(RT)$(RT)$(RT)$(RT)$(RT)
LONG = cls\r100 $(Q28)\r1000 $(Q28)\rLIST 100\r$(UP)$(UP)$(RT14)\1772\r$(DN)LIST 1000\r$(UP)$(UP)$(UP)\r$(DN)LIST\rHALT\r
# redo: the check at entry (issue #118, step 3). A line of two rows
# that the tokenizer refuses at its @ is not stored, and after READY. it
# is shown again with the cursor at the @, as no key waits: the input
# ends there, and BASIC waits for a key until the step limit. The dump
# is the cursor's column and row.
REDO = 10 PRINT 1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1 @ 2\r
DUMP_redo = -d 0xFFFFFF81:2
# load: LOAD with lines typed and pasted. The LOAD line ends with CR LF,
# as a terminal may end it, which is no empty line. The first line is typed
# with edits: a DEL that takes back 2, the cursor key ESC [ A, which is
# dropped, so it writes 134 at 9000. The RAM has 0x20000 words, as on the
# MEGA65, which build/ram128k.bin writes to 0xFFFFFF9E, so 1E3FF takes a
# word and 1E400, the stack's room below BASIC's variables, does not. A line
# with TABs for blanks writes 7 at 9002, a line of blanks only is passed
# over, and a second line for 9002 writes 8 over the 7. Six lines are
# skipped: zz, an address in the ROM, one of the monitor's variables, a
# third number, 1E400, and a line of 78 characters, 9003, 66 blanks, and
# 12345678, which is longer than the 76 of a line, so it writes nothing,
# not 123456. Pasted lines after it: one of 100 blanks, which is passed
# over; 1E3FF A and 90 blanks, which writes A over the 9, as the blanks
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
LOAD_HEAD = load\r\n9000 12\177\033[A34\rzz\r100 5\rFFFFF000 1\r9001 5 6\r1E3FF 9\r1E400 1\r\t9002\t7 \r   \r9002 8\r9003$(BLANKS66)12345678\r$(BLANKS100)\r1E3FF A$(BLANKS90)\r9001$(BLANKS71)3z\177\r
LOAD_TAIL = \rload\r9001 7\003sys 0x8000\rdump 0x9000, 4\rdump 0x1E3FF, 1\rhalt\r
# arr: the arrays and HIMEM of stage 3 (issue #114), test/arr.bas typed
# line by line. An array that no DIM made, DIM of one and of two
# dimensions, each element 0, assignments, and the Bad subscripts of an
# index outside, below 0, and of one too many and too few. A second DIM,
# a variable of an array's name, a subscript of 1.5, which is 1, a
# negative size, a size of a variable, LET, INPUT, and GET of an
# element, and INPUT of an element outside, a Bad subscript and no Redo
# from start. A program with an array, which CLR drops and an edit keeps.
# HIMEM, read in expressions and set, which does a CLR, and too low,
# too high, and the arrays that fit below it. The layout of an entry of
# an array, its data, and a variable after it. Last, LOAD of lines above
# HIMEM, which keeps the program, and below, which does NEW, then the
# same in a running program, which goes on, and ends at READY.
# int: the names with % (issue #161), test/int.bas typed line by line.
# A variable with %, beside one of the same name without, rounded toward
# zero, -0.5 to 0, the largest and smallest word, and the Illegal
# quantity of a value past them, and of an overflow; % in a function's
# and a procedure's name, and $ after %, Syntax errors; an array with %
# before DIM; arrays with % of one and of two dimensions, a value
# rounded, -1 from hex, a value past a word, a subscript outside and of
# 1.5, and a second DIM; INPUT, with a value past a word, a Redo from
# start, and then a subscript outside, a Bad subscript after the
# variable before it took its value, GET, FOR with a step of -1.5, and
# RCURSOR into them. A program with % in a function's and a procedure's
# parameters, LOCAL, READ, and three variables of one name, LIST and RUN,
# CLR. Last the layout: an array of doubles and one with %, whose data
# is a word an element.
# kw: a keyword where a variable's name goes (issue #164), test/kw.bas
# typed line by line: the Syntax error that names it, at the start of a
# statement, in a direct line and in a program, and in FOR, NEXT's
# list, READ, INPUT, DIM, GET, LET, RCURSOR, a DEF's parameters, and
# LOCAL, with AND, PRINT, and TIME$ among them; a number, a +, and an
# item of DATA that does not fit, whose Syntax error names none; and
# one trapped, as error 11, whose line LIST shows as it was typed.
# str: the strings of stage 5 (issue #116), test/str.bas typed line by
# line, with --step-time, so that TIME$ is the same in each run. String
# variables, +, and each function, with the edges of their arguments:
# a part of 0 characters, past the end, VAL of a text with no number, of
# hex, and with a blank after its sign, and INSTR of an empty string.
# The comparisons, alone and in IF with AND, NOT of one, and one in ( )
# as a number. A string in ( ) at the start of an expression is a
# number's (, so a Type mismatch. The Type mismatches of a number where
# a string goes and of a string where a number goes, the Undefined
# variable of a string never assigned, the Illegal quantities of the
# functions, and String too long past 255 characters. Arrays of strings,
# empty after DIM. IP with a string expression and with a variable,
# TIME$ set and read, and set to no time, GET of a key, and an edit,
# which keeps a string, and CLR, which drops it. READ of numbers and
# strings from DATA, with a quoted comma, blanks around the items, a
# colon after a DATA, and empty items; RESTORE of a line and of the
# first; a string read into a number, and one in quotes, a Syntax
# error; Out of data; and LIST of each new token. INPUT of strings,
# with blanks around them, one in quotes with a comma, and text after a
# quote and a number in quotes, which are Redo from start. Last, a
# program that fills a heap made small by HIMEM again and again, so
# that the sweep runs, with an array of strings, and with strings that
# grow to 201 characters, joined with parts of themselves.
# struct: the structure of stage 8 that is written (issue #119),
# test/struct.bas typed line by line. DEF FN with a parameter, with none,
# with two, of a string, and one that calls others, one of them defined
# after it, the parameters set again after the call and the other
# variables kept, functions in the arguments of others, in IF, and with
# the operators of strings. ON ... GOTO with each line, 0, and past the
# list, and in a subroutine; ON ... GOSUB, back after the statement; a
# number with a fraction, rounded toward zero; and ON after THEN. Then
# the errors: an Undefined function, too many and too few arguments, a
# string for a number, a string's function where a number goes and a
# number where a string goes, an assignment to a function, ON below 0,
# ON with no line, with a variable for a line, without GOTO, and of a
# line that is not; a comma that is no ON's list, which keeps its
# numbers; DEF without FN; and DEFs that are not right: a string's
# parameter with no argument, a function that calls itself with no end, a number for a
# string, no expression, and a statement after one, of which the line's
# second statement does not run. CLR and an edit, after which a call
# finds its DEF again, LIST of the tokens, and RENUMBER of ON's lists.
# Then DO and LOOP with WHILE and UNTIL at either end, on one line and
# over lines, nested, with FOR inside, EXIT, a GOTO back to a DO, and a
# RETURN out of one; block IFs nested, with and without ELSE, after a
# number like THEN's token; their errors, LIST, and RENUMBER.
# proc: PROC, FN over lines, and LOCAL (issue #119), test/proc.bas typed
# line by line. A PROC with a number's and a string's parameter and
# LOCALs, the program's variables of their names kept; FNs over lines
# that call themselves, with LOCALs and a FOR loop, and one on one line
# with IF and ELSE; FNs in expressions with numbers and strings that
# pend; a PROC that calls itself, ENDPROC in IF, and a GOSUB in a PROC;
# strings that frames keep over sweeps of a heap that HIMEM makes small.
# Then the errors: ENDPROC, =, and LOCAL with no PROC or FN, an
# Undefined procedure and function, too few arguments, and a string for
# a number; a FN with no =, after which CONT cannot go on; ENDPROC in a
# GOSUB of a PROC, and = in a PROC; a PROC and a GOSUB in a FN, and = in
# its GOSUB; and a FN that calls itself 30 deep, and 31.
# mach: the machine of stage 10 (issue #121), test/mach.bas typed line
# by line, with --step-time, so that TI counts a microsecond a step. TI,
# which grows; FOREGROUND and BACKGROUND by BASIC 65's numbers and by red,
# green, and blue, which PEEK reads in the screen's word of a character;
# CURSOR to a column of the row, past the last column and the last row,
# which stop there; and the state of the cursor that CURSOR ON and OFF and
# a style write, which READY. shows and blinks again. RCURSOR, which makes
# its variables in a direct line, to an array's elements too. Then the
# errors: CURSOR with no place, a negative column and row, a style past
# 3, ON without its comma, and no row; colors past 15, below 0, two
# numbers, a string, and none; RCURSOR with one variable and a string's;
# SLEEP below 0, with none, and two; and OFF and TI, which are no
# variables. LIST of the tokens. A program of SLEEP 100, which the CTRL-C
# of MACH_TAIL breaks, and CONT goes on after it. Last a program of
# SLEEPs, timed with TI, of 0, -0, and fractions, whose run takes the
# line after it into the ring of the keys typed ahead, so that it is
# short; it shows the cursor, which the program hid, again.
MACH_TAIL = \003CONT\rNEW\r10 A = TI: SLEEP 0.25: B = TI: PRINT B - A >= 250000, B - A < 251000\r20 A = TI: SLEEP 0: SLEEP -0: B = TI: PRINT B - A < 1000\r30 A = TI: SLEEP 1.5: B = TI: PRINT B - A >= 1.5E6, B - A < 1501000\r40 CURSOR OFF: SLEEP 0.01: PRINT PEEK(-128)\rRUN\r? PEEK(-128)\rHALT\r
# trap: the errors in a program of stage 9 (issue #120), test/trap.bas
# typed line by line. ER, EL, and ERR$ before any error; then a program
# with a TRAP that makes each error that a program can come to once, and
# whose handler prints ER, EL, and ERR$(ER), and goes on with RESUME NEXT:
# after a statement after THEN, the statement after it, and after a
# block IF and DO, those after them; a GOSUB to a line that is not, whose
# frame goes; an error in a FOR loop, which goes on; one in a FN over
# lines, after which the statement after the call runs, its parameter
# set again; and one in a PROC, which goes on in it. RESUME after the
# handler fixed the cause, RESUME N, ERR$ of 0 to 113, an error in the
# handler, which stops the program, and TRAP alone, after which an error
# stops it too. RENUMBER and LIST of TRAP's and RESUME's lines, ER, EL,
# and ERR$. The failures of issue #158, with no card and no IP address:
# DS and DS$ before any, then a program whose TRAP takes a BSAVE and a
# SAVE with no card, a SAVE and a DIR to a TFTP server with no IP
# address, a server that is not, an offset of NTP that is not, and a slot
# that is not, and whose handler prints ER, EL, DS, ERR$(ER), and DS$;
# the dump of its lines, which shows the 0 after each string, and that
# the .BIN that BSAVE adds to a name without a dot leaves the tokens
# after it; a failure with no TRAP, which stops the program with DS$ and
# the line; and LOAD of a program's text, which a TRAP does not take,
# and which keeps the program. A program whose TRAP takes the Bad
# subscript of INPUT's element, which is no Redo from start, and whose
# handler's RESUME to a line that is not there stops it, with ER and EL
# of that RESUME. A handler that goes on with GOTO and traps again with
# TRAP; and the break key, which a TRAP does not take, and CONT after
# it.
TRAP_TAIL = \003? ER, EL\rCONT\r\003HALT\r
# load_emu: LOAD where 0xFFFFFF9E reads 0, as in niceemu, so a program's RAM
# goes up to the screen: 10000 and FFFEFFFF take words, and FFFF0000 does
# not.
LOAD_EMU = load\r10000 7\rFFFEFFFF 8\rFFFF0000 1\r\rdump 0x10000, 1\rhalt\r
# load_64k: LOAD with 0x10000 words of RAM, as on the Nexys4DDR, which
# build/ram64k.bin writes to 0xFFFFFF9E: E3FF takes a word, and E400, the
# stack's room below BASIC's variables, and 1EFFF, past the RAM, do not.
LOAD_64K = load\rE3FF 1\rE400 2\r1EFFF 3\r\rdump 0xE3FF, 1\rhalt\r
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
TIME = time\rload\r8000 1\r\rbsave "old.bin", 0x8000, 1\rtime "2026-11-11 14:30:01"\rtime\rbsave "new.bin", 0x8000, 1\rtime "2023-02-29 00:00:00"\rtime "2100-02-29 00:00:00"\rtime "1969-12-31 23:59:59"\rtime "2106-01-01 00:00:00"\rtime "2026-13-01 00:00:00"\rtime "2026-11-31 00:00:00"\rtime "2026-11-11 24:00:00"\rtime "2026-11-11 23:60:00"\rtime "2026-11-11 23:59:60"\rtime "26-11-11 00:00:00"\rtime "2026-1-1 00:00:00"\rtime "2026-11-11"\rtime "2026-11-11 01:02:03 x"\rtime "2026-11-11 001:02:03"\rtime "2026-11-11 1:2:3"\rtimex\rti\rtime "2000-02-29 00:00:00"\rtime "2100-03-01 00:00:00"\rtime "2104-02-29 12:00:00"\rtime "2038-01-19 03:14:08"\rtime "2105-12-31 23:59:59"\rtime "  2026-11-11 14:30:01  "\rtime "2026-00-10 00:00:00"\rtime "2026-11-00 00:00:00"\rtime "2O26-11-11 00:00:00"\rtime "2026/11/11 00:00:00"\rtime "2026-11-11T00:00:00"\rtime "2026-11-11 00.00.00"\rtime\rtime "2024-02-29 00:00:00"\rtime "2024-12-31 23:59:59"\rtime "2100-02-28 23:59:59"\rtime "2099-12-31 23:59:59"\rtime ""\rTIME  "1970-01-01 00:00:00" \rbsave "y1970.bin", 0x8000, 1\rhalt\r
# The words of each test that are dumped with the screen: for cmds the
# variables, the cursor's registers, and the IP and MAC addresses
DUMP_cmds    = -d 0xFFFFF000:4 -d 0xFFFFE800:2 -d 0xFFFFFF80:6 -d 0xFFFFFF9F:1 -d 0xFFFFFFB0:3
DUMP_basic   = -d 0xFFFFF000:4 -d 0xFFFFE800:2 -d 0xFFFFFFB0:1
DUMP_expr    = -d 0x8000:16 -d 0xFFFFED51:1
DUMP_load    = -d 0xFFFFF000:4 -d 0xFFFFF005:6 -d 0xFFFFE800:5
DUMP_load_emu = -d 0xFFFFE816:1 -d 0xFFFEFFFF:1
DUMP_load_64k = -d 0xFFFFE816:1
MAX_STEPS = 10000000
# The header of the tests' image, as basic_rom.py check shows it, but for
# its length, which changes with the code
HEADER_TEST = version 9.9.0+0, layout 2, 42 entries, [0-9]* words, RAM 2048 words, flags 1

# The benchmarks (doc/BASIC.md, "Tests"): Rugg/Feldman 1 to 7 and the
# sieve, as they are written, and since stage 6 Rugg/Feldman 8. make bench prints their steps in niceemu
# as the rows of the table in doc/BASIC.md.
BENCH = bench/bm1.bas bench/bm2.bas bench/bm3.bas bench/bm4.bas bench/bm5.bas \
        bench/bm6.bas bench/bm7.bas bench/bm8.bas bench/sieve.bas bench/str.bas

bench: $(ROM_TEST)
	@$(PYTHON) test/bench.py --table $(EMU) $(ROM_TEST) $(BENCH)

# The ECMA-55 conformance suite, NBS SP 500-70 (doc/BASIC.md, "Tests"):
# bas55 2.0's 208 programs, fetched into $(BUILD)/ecma55 the first time,
# each typed and run, and its outcome compared with test/ecma55.expected.
# It needs the network once, so make test does not run it.
ecma55: $(ROM_TEST)
	@$(PYTHON) test/ecma55.py $(EMU) $(ROM_TEST) $(BUILD)/ecma55 test/ecma55.expected \
	  $(BUILD)/ecma55.out

# Each test runs the ROM with its input, and compares the console output,
# the dumps, and the screen with test/NAME.expected. The Halted line and
# the registers are left out, as the steps and the registers change with
# the code, and so are those of a stop at the step limit, of which its
# words stay, but for VBASE, bits 23-0 of R14, which must be 0.
# test/dis.py
# checks the rows of DIS against nicedis.py and niceasm first,
# test/ntp.py NTP, with DHCP and DNS before it, and test/tftp.py TFTP's
# LOAD and DIR, and test/bench.py runs the benchmarks of bench/ and
# checks their output. time writes to a copy of super.img, and runs with
# --step-time, so that the dates it writes are fixed; its output has what
# the card holds that the image did not (fat_tool.py diff, the dates
# masked) and the order of its sector writes, from a second run with -t
# (fat_tool.py order).
test: fmt $(ROM_TEST) test/prog.bas test/arr.bas test/str.bas test/struct.bas test/proc.bas test/mach.bas test/trap.bas test/int.bas test/kw.bas test/files.in test/files_card.py $(BUILD)/dis.bin $(MON)/build/hello.bin $(MON)/build/fat/super.img
	@test '$(FOLDER_UC)' = NICE || { echo "make test needs FOLDER=NICE, not $(FOLDER)"; exit 1; }
	@$(BAS_ROM) check $(BUILD)/basic_image_test.bin > $(BUILD)/header.out
	@if grep -qx '$(BUILD)/basic_image_test.bin: $(HEADER_TEST)' $(BUILD)/header.out; \
	then echo "PASS basic header"; else echo "FAIL basic header"; cat $(BUILD)/header.out; exit 1; fi
	@$(PYTHON) test/dis.py $(EMU) $(ROM_TEST) $(BUILD)/dis.bin
	@$(PYTHON) test/print_numbers.py $(EMU) $(ROM_TEST)
	@$(PYTHON) test/functions.py $(EMU) $(ROM_TEST)
	@$(PYTHON) test/bench.py $(EMU) $(ROM_TEST) $(BENCH)
	@$(PYTHON) test/ntp.py $(EMU) $(ROM_TEST) test/ntp.expected $(BUILD)/ntp.out
	@$(PYTHON) test/tftp.py $(EMU) $(ROM_TEST) test/tftp.expected $(BUILD)/tftp.out
	@echo 'FFFFFF9E 00020000' > $(BUILD)/ram128k.bin
	@echo 'FFFFFF9E 00010000' > $(BUILD)/ram64k.bin
	@printf '$(LOAD_EMU)' > $(BUILD)/load_emu.txt
	@printf '$(LOAD_64K)' > $(BUILD)/load_64k.txt
	@printf '$(CMDS)' > $(BUILD)/cmds.txt
	@printf '$(BASIC)' > $(BUILD)/basic.txt
	@printf '$(EXPR)' > $(BUILD)/expr.txt
	@printf '$(FUNCS)' > $(BUILD)/funcs.txt
	@printf '$(TIME)' > $(BUILD)/time.txt
	@tr '\n' '\r' < test/prog.bas > $(BUILD)/prog.txt
	@tr '\n' '\r' < test/arr.bas > $(BUILD)/arr.txt
	@tr '\n' '\r' < test/str.bas > $(BUILD)/str.txt
	@tr '\n' '\r' < test/struct.bas > $(BUILD)/struct.txt
	@tr '\n' '\r' < test/proc.bas > $(BUILD)/proc.txt
	@tr '\n' '\r' < test/int.bas > $(BUILD)/int.txt
	@tr '\n' '\r' < test/kw.bas > $(BUILD)/kw.txt
	@{ tr '\n' '\r' < test/mach.bas; printf '$(MACH_TAIL)'; } > $(BUILD)/mach.txt
	@{ tr '\n' '\r' < test/trap.bas; printf '$(TRAP_TAIL)'; } > $(BUILD)/trap.txt
	@tr '\n' '\r' < test/files.in > $(BUILD)/files.txt
	@printf '$(KEYS)' > $(BUILD)/keys.txt
	@printf '$(EDIT)' > $(BUILD)/edit.txt
	@printf '$(LONG)' > $(BUILD)/long.txt
	@printf '$(REDO)' > $(BUILD)/redo.txt
	@printf '$(LINES)' > $(BUILD)/lines.txt
	@{ printf '$(LOAD_HEAD)'; head -n 3 $(MON)/build/hello.bin | awk '{ printf "%s\r\n", $$0 }'; \
	  tail -n +4 $(MON)/build/hello.bin; printf '$(LOAD_TAIL)'; } > $(BUILD)/load.txt
	@fail=0; \
	for t in cmds basic expr funcs prog keys edit long redo lines arr str struct proc mach trap int kw load load_emu load_64k time files; do \
	  opts=; sd=; base0=; \
	  case $$t in \
	    cmds) prog=; dump='$(DUMP_cmds)';; \
	    basic) prog=; dump='$(DUMP_basic)';; \
	    expr) prog=; dump='$(DUMP_expr)';; \
	    funcs|prog|keys|edit|long|lines|arr|struct|proc|trap|int|kw) prog=; dump=;; \
	    str|mach) prog=; dump=; opts=--step-time;; \
	    redo) prog=; dump='$(DUMP_redo)';; \
	    load) prog=$(BUILD)/ram128k.bin; dump='$(DUMP_load)';; \
	    load_emu) prog=; dump='$(DUMP_load_emu)';; \
	    load_64k) prog=$(BUILD)/ram64k.bin; dump='$(DUMP_load_64k)';; \
	    time) prog=; dump=; base0=$(MON)/build/fat/super.img; opts=--step-time;; \
	    files) prog=; dump=; base0=$(MON)/build/fat/super.img; opts=--step-time;; \
	  esac; \
	  card() { if [ -n "$$base0" ]; then \
	    cp --sparse=always $$base0 $(BUILD)/$${t}0.img; sd="--sd0 $(BUILD)/$${t}0.img"; fi; \
	    if [ $$t = files ]; then $(PYTHON) test/files_card.py $(BUILD)/files0.img; fi; }; \
	  card; \
	  cat $(ROM_TEST) $$prog > $(BUILD)/$$t.full.bin; \
	  $(EMU) -s -n $(MAX_STEPS) -i $(BUILD)/$$t.txt $$dump $$opts $$sd $(BUILD)/$$t.full.bin \
	    > $(BUILD)/$$t.raw; status=$$?; \
	  { sed -e '/^Halted (HALT)/,/^R12 /d' \
	      -e '/Stopped at the step limit/,/^R12 /{/Stopped/!d;s/Stopped at the step limit.*/Stopped at the step limit/;}' \
	      $(BUILD)/$$t.raw; \
	    sed -n 's/.* R14 ..\(......\) .*/VBASE at the halt \1/p' $(BUILD)/$$t.raw; \
	    echo "exit $$status"; \
	    if [ $$t = time ]; then \
	      $(PYTHON) $(MON_TEST)/fat_check.py $(BUILD)/time0.img; \
	      echo "Dates in NICE:"; mdir -i $(BUILD)/time0.img ::NICE | grep -E '^(old|new|y1970) '; \
	      $(PYTHON) $(MON_TEST)/fat_tool.py diff --mask-times $$base0 $(BUILD)/time0.img; \
	      card; \
	      $(EMU) -t -n $(MAX_STEPS) -i $(BUILD)/$$t.txt $$opts $$sd $(BUILD)/$$t.full.bin | \
	        $(PYTHON) $(MON_TEST)/fat_tool.py order --sd0 $$base0; fi; \
	    if [ $$t = files ]; then \
	      $(PYTHON) $(MON_TEST)/fat_check.py $(BUILD)/files0.img; \
	      for f in PROG.BAS T.TXT EMPTY.BAS; do echo "$$f:"; \
	        mtype -i $(BUILD)/files0.img ::NICE/$$f | od -An -c; done; fi; } \
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
