# Builds the example C programs into .bin files for tools/nicemon.py load.
#
# C goes through WebAssembly: clang compiles it to a wasm module, linked
# with the C library of nice_cpu (nice_cpu/runtime/libc), nicewasm
# (nice_cpu/translator) translates that to NICE assembly, and niceasm
# assembles it with the start-up code and the runtime library. The options
# are those of nice_cpu/runtime/README.md: they keep the linear memory to
# one page, 16384 words, so the program fits in the 64K words of the
# Nexys4DDR's memory, the smaller board's. The translated code and the
# runtime use the math unit, so muldiv_mpu.nasm is joined in. A program
# that calls scanf is joined with the float library, float_fpu.nasm, too,
# which computes on the FPU, as nicebuild.py joins it.
#
# The programs use the byte windows of nice_cpu's DEVICES.md §9, which the
# board and the emulator have: nicewasm's WINDOWS options make each byte
# or halfword load and store one MOVE, and take an access to be aligned as
# its hint says. bench.bin alone is built without them, so that its code
# and cycles compare with those of nice_cpu's testbench; bench_win.bin is
# the same benchmark with them.
#
# weather.bin, the weather display of issue #128, is a program for the
# monitor at 0x8000, which calls the ROM's entries of the network, so
# nicebuild.py builds it, with the stubs of monitor/mon.nasm and
# monitor/mon_c.nasm, as doc/PROGRAMMING.md says, with -Oz, so that it
# fits below the variables in the Nexys4DDR's 26K words for a
# program at 0x8000, with its page of wasm memory. Its text,
# weather_parse.c, is checked on the host by test/weather_test.c with the
# answers of test/*.http, and the whole program in niceemu by
# tools/weathertest.py (make weathertest at the top).
#
# sieve.bin is no C: it is a routine of machine code at 0xC000, which the
# BASIC program sieve.bas loads above its HIMEM and calls with SYS. niceasm
# assembles it, and sieve.bas is copied beside it, so that the release's
# zip of build/ has both. The test runs sieve.bas in niceemu with the
# monitor of the tests, ../build/rom_test.bin, and a card in slot 0 with
# both in its folder NICE, with --step-time, so that TI counts a
# microsecond a step, and compares the output with test/sieve.expected.
#
# weather.bas is the weather display in BASIC, which fetches with BASIC's
# HTTP$, and is copied as sieve.bas is. tools/weathertest.py runs it in
# niceemu against its server of HTTP (make weathertest at the top).
#
# chess.bas is a chess program in BASIC, and is copied as sieve.bas is.
# The test types it into BASIC in niceemu, with no card, sets its time
# limit to 2 seconds, which --step-time makes 2 million steps, and plays
# three moves of white against it, one of them typed wrong first. The
# output after RUN, up to the step limit, where it waits for the fourth
# move, is compared with test/chess.expected.
#
# make          builds build/primes.bin, build/weather.bin, build/sieve.bin,
#               and build/bench.bin and build/bench_win.bin
#               from nice_cpu's benchmark, bench/bench.c, which
#               tools/hwtest.py runs, and copies sieve.bas, weather.bas,
#               and chess.bas
# make test     checks weather_parse.c on the host, with cc, sieve.bas
#               with sieve.bin in niceemu, and chess.bas in niceemu
# make clean    removes build/ and test/build/
#
# Needs clang with the wasm32 target, wasm-ld and llvm-ar (the lld and llvm
# packages), and Python 3. The test needs niceemu, built with make -C
# ../nice_cpu/emulator build, mkfs.fat, and mtools.

CLANG  ?= clang
CC     ?= cc
PYTHON ?= python3
NICE_CPU = ../nice_cpu
LIBC    = $(NICE_CPU)/runtime/libc
BUILD   = build
EMU     = $(NICE_CPU)/emulator/zig-out/bin/niceemu
ROM_TEST = ../build/rom_test.bin

CFLAGS  = --target=wasm32 -mbulk-memory -O2 -ffreestanding -nostdlibinc \
          -isystem $(LIBC)/include -Wall -Wextra
LDFLAGS = -nostdlib -Wl,--no-entry -Wl,--export=main \
          -Wl,--stack-first -Wl,-z,stack-size=4096 -Wl,--initial-memory=65536

RUNTIME = $(NICE_CPU)/runtime/lib.nasm $(NICE_CPU)/runtime/muldiv_mpu.nasm
START   = $(NICE_CPU)/runtime/start_wasm.nasm
FLOAT   = $(NICE_CPU)/runtime/float_fpu.nasm
# The tools are prerequisites, so a bump of the submodule rebuilds the files.
NICEWASM = $(wildcard $(NICE_CPU)/translator/*.py)
NICEASM  = $(wildcard $(NICE_CPU)/assembler/*.py)

PROGRAMS = primes bench bench_win
# nicewasm's options for the byte windows, for every program but bench
WINDOWS  = --byte-windows --trust-alignment
WASM_OPTS = $(if $(filter bench,$*),,$(WINDOWS))
# The programs that call scanf, and so need float_fpu.nasm.
FLOAT_PROGRAMS = primes

all: $(PROGRAMS:%=$(BUILD)/%.bin) $(BUILD)/weather.bin $(BUILD)/sieve.bin $(BUILD)/sieve.bas \
     $(BUILD)/weather.bas $(BUILD)/chess.bas

MON      = ../monitor
NICEBUILD = $(PYTHON) $(NICE_CPU)/translator/nicebuild.py
WEATHER  = weather.c weather_parse.c

$(BUILD)/weather.bin: $(WEATHER) weather_parse.h $(MON)/mon.h $(MON)/mon.nasm $(MON)/mon_c.nasm \
                      $(NICEWASM) $(NICEASM) | $(BUILD)
	$(NICEBUILD) -O z --monitor $(WINDOWS) --asm $(MON)/mon.nasm --asm $(MON)/mon_c.nasm -I $(MON) \
	  -o $@ $(WEATHER)

# The host's program goes to test/build/, not build/, whose files the
# release zips (tools/release.py).
test/build/weather_test: test/weather_test.c weather_parse.c weather_parse.h
	mkdir -p test/build
	$(CC) -std=c11 -O2 -Wall -Wextra -Werror -o $@ test/weather_test.c weather_parse.c

test: test/build/weather_test test/build/sieve.img $(ROM_TEST)
	test/build/weather_test test
	printf 'RUN "SIEVE"\rHALT\r' > test/build/sieve.in
	$(EMU) -s -n 100000000 --step-time --sd0 test/build/sieve.img -i test/build/sieve.in \
	  $(ROM_TEST) | sed -e '/^Halted/,$$d' > test/build/sieve.out
	@if cmp -s test/sieve.expected test/build/sieve.out; then echo "PASS sieve"; \
	else echo "FAIL sieve"; diff test/sieve.expected test/build/sieve.out; exit 1; fi
	{ cat chess.bas; printf '30 TL = 2\nRUN\nW\ne2e4\ne2e5\nd2d4\ng1f3\n'; } | tr '\n' '\r' \
	  > test/build/chess.in
	$(EMU) --step-time -n 60000000 -i test/build/chess.in $(ROM_TEST) \
	  | sed -e '1,/^RUN/d' -e '/Stopped at the step limit/{s/Stopped at.*//;q;}' > test/build/chess.out
	@if cmp -s test/chess.expected test/build/chess.out; then echo "PASS chess"; \
	else echo "FAIL chess"; diff test/chess.expected test/build/chess.out; exit 1; fi

# sieve.bin, the routine, and sieve.bas, the program that calls it
$(BUILD)/sieve.bin: sieve.nasm $(NICEASM) | $(BUILD)
	$(PYTHON) $(NICE_CPU)/assembler/niceasm.py -o $@ sieve.nasm

$(BUILD)/sieve.bas: sieve.bas | $(BUILD)
	cp sieve.bas $@

$(BUILD)/weather.bas: weather.bas | $(BUILD)
	cp weather.bas $@

$(BUILD)/chess.bas: chess.bas | $(BUILD)
	cp chess.bas $@

# The card of the test: FAT32 on the whole card, with both in NICE
test/build/sieve.img: $(BUILD)/sieve.bin sieve.bas
	mkdir -p test/build
	rm -f $@
	truncate -s 40M $@
	mkfs.fat -F 32 -i 4E494345 $@ > /dev/null
	mmd -i $@ ::NICE
	mcopy -i $@ $(BUILD)/sieve.bin ::NICE/SIEVE.BIN
	mcopy -i $@ sieve.bas ::NICE/SIEVE.BAS

$(ROM_TEST): FORCE
	$(MAKE) -C .. build/rom_test.bin

# The library is built in the submodule, which ignores its build files.
$(LIBC)/libc.a: FORCE
	$(MAKE) -C $(LIBC) libc.a

$(BUILD)/%.wasm: %.c $(LIBC)/libc.a | $(BUILD)
	$(CLANG) $(CFLAGS) $(LDFLAGS) -o $@ $< $(LIBC)/libc.a

$(BUILD)/bench.wasm $(BUILD)/bench_win.wasm: $(NICE_CPU)/bench/bench.c $(LIBC)/libc.a | $(BUILD)
	$(CLANG) $(CFLAGS) $(LDFLAGS) -o $@ $< $(LIBC)/libc.a

$(BUILD)/%.nasm: $(BUILD)/%.wasm $(NICEWASM) Makefile
	$(PYTHON) $(NICE_CPU)/translator/nicewasm.py $(WASM_OPTS) -o $@ $<

$(BUILD)/%_full.nasm: $(BUILD)/%.nasm $(START) $(RUNTIME)
	cat $(START) $< $(RUNTIME) > $@

$(FLOAT_PROGRAMS:%=$(BUILD)/%_full.nasm): $(BUILD)/%_full.nasm: $(BUILD)/%.nasm $(START) $(RUNTIME) $(FLOAT)
	cat $(START) $< $(RUNTIME) $(FLOAT) > $@

$(BUILD)/%.bin: $(BUILD)/%_full.nasm $(NICEASM)
	$(PYTHON) $(NICE_CPU)/assembler/niceasm.py -o $@ $<

$(BUILD):
	mkdir -p $@

clean:
	rm -rf $(BUILD) test/build

.PHONY: all test clean FORCE
.PRECIOUS: $(BUILD)/%.wasm $(BUILD)/%.nasm $(BUILD)/%_full.nasm
