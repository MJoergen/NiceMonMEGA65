# Builds the example C programs into .bin files for tools/load.py.
#
# C goes through WebAssembly: clang compiles it to a wasm module, linked
# with the C library of nice_cpu (nice_cpu/runtime/libc), nicewasm
# (nice_cpu/translator) translates that to NICE assembly, and niceasm
# assembles it with the start-up code and the runtime library. The options
# are those of nice_cpu/runtime/README.md: they keep the linear memory to
# one page, 16384 words, so the program fits in the 64K words of the
# Nexys4DDR's memory, the smaller board's. The translated code and the
# runtime use the math unit, so muldiv_mpu.nasm is joined in. A program
# that calls scanf is joined with the float library, float.nasm, too,
# which the runtime builds.
#
# The programs use the byte windows of nice_cpu's SYSTEM.md §9, which the
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
# fits below the monitor's variables in the Nexys4DDR's 28K words for a
# program at 0x8000, with its page of wasm memory. Its text,
# weather_parse.c, is checked on the host by test/weather_test.c with the
# answers of test/*.http, and the whole program in niceemu by
# tools/weathertest.py (make weathertest at the top).
#
# make          builds build/primes.bin, build/weather.bin, and
#               build/bench.bin and build/bench_win.bin from nice_cpu's
#               benchmark, bench/bench.c, which tools/hwtest.py runs
# make test     checks weather_parse.c on the host, with cc
# make clean    removes build/ and test/build/
#
# Needs clang with the wasm32 target, wasm-ld and llvm-ar (the lld and llvm
# packages), and Python 3.

CLANG  ?= clang
CC     ?= cc
PYTHON ?= python3
NICE_CPU = ../nice_cpu
LIBC    = $(NICE_CPU)/runtime/libc
BUILD   = build

CFLAGS  = --target=wasm32 -mbulk-memory -O2 -ffreestanding -nostdlibinc \
          -isystem $(LIBC)/include -Wall -Wextra
LDFLAGS = -nostdlib -Wl,--no-entry -Wl,--export=main \
          -Wl,--stack-first -Wl,-z,stack-size=4096 -Wl,--initial-memory=65536

RUNTIME = $(NICE_CPU)/runtime/lib.nasm $(NICE_CPU)/runtime/muldiv_mpu.nasm
START   = $(NICE_CPU)/runtime/start_wasm.nasm
FLOAT   = $(NICE_CPU)/runtime/float.nasm
# The tools are prerequisites, so a bump of the submodule rebuilds the files.
NICEWASM = $(wildcard $(NICE_CPU)/translator/*.py)
NICEASM  = $(wildcard $(NICE_CPU)/assembler/*.py)

PROGRAMS = primes bench bench_win
# nicewasm's options for the byte windows, for every program but bench
WINDOWS  = --byte-windows --trust-alignment
WASM_OPTS = $(if $(filter bench,$*),,$(WINDOWS))
# The programs that call scanf, and so need float.nasm.
FLOAT_PROGRAMS = primes

all: $(PROGRAMS:%=$(BUILD)/%.bin) $(BUILD)/weather.bin

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

test: test/build/weather_test
	test/build/weather_test test

# The library is built in the submodule, which ignores its build files.
$(LIBC)/libc.a: FORCE
	$(MAKE) -C $(LIBC) libc.a

$(FLOAT): FORCE
	$(MAKE) -C $(NICE_CPU)/runtime float.nasm

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
