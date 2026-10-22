# Builds the example C programs into .bin files for tools/load.py.
#
# C goes through WebAssembly: clang compiles it to a wasm module, linked
# with the C library of nice_cpu (nice_cpu/runtime/libc), nicewasm
# (nice_cpu/translator) translates that to NICE assembly, and niceasm
# assembles it with the start-up code and the runtime library. The options
# are those of nice_cpu/runtime/README.md: they keep the linear memory to
# one page, 16384 words, so the program fits in the 64K words of the
# MEGA65's memory. The translated code and the runtime use the math unit,
# so muldiv_mpu.nasm is joined in.
#
# make          builds build/primes.bin, and build/bench.bin from nice_cpu's
#               benchmark, bench/bench.c, which tools/hwtest.py runs
# make clean    removes build/
#
# Needs clang with the wasm32 target, wasm-ld and llvm-ar (the lld and llvm
# packages), and Python 3.

CLANG  ?= clang
PYTHON ?= python3
NICE    = ../nice_cpu
LIBC    = $(NICE)/runtime/libc
BUILD   = build

CFLAGS  = --target=wasm32 -mbulk-memory -O2 -ffreestanding -nostdlibinc \
          -isystem $(LIBC)/include -Wall -Wextra
LDFLAGS = -nostdlib -Wl,--no-entry -Wl,--export=main \
          -Wl,--stack-first -Wl,-z,stack-size=4096 -Wl,--initial-memory=65536

RUNTIME = $(NICE)/runtime/lib.nasm $(NICE)/runtime/muldiv_mpu.nasm
START   = $(NICE)/runtime/start_wasm.nasm
# The tools are prerequisites, so a bump of the submodule rebuilds the files.
NICEWASM = $(wildcard $(NICE)/translator/*.py)
NICEASM  = $(wildcard $(NICE)/assembler/*.py)

PROGRAMS = primes bench

all: $(PROGRAMS:%=$(BUILD)/%.bin)

# The library is built in the submodule, which ignores its build files.
$(LIBC)/libc.a: FORCE
	$(MAKE) -C $(LIBC) libc.a

$(BUILD)/%.wasm: %.c $(LIBC)/libc.a | $(BUILD)
	$(CLANG) $(CFLAGS) $(LDFLAGS) -o $@ $< $(LIBC)/libc.a

$(BUILD)/bench.wasm: $(NICE)/bench/bench.c $(LIBC)/libc.a | $(BUILD)
	$(CLANG) $(CFLAGS) $(LDFLAGS) -o $@ $< $(LIBC)/libc.a

$(BUILD)/%.nasm: $(BUILD)/%.wasm $(NICEWASM)
	$(PYTHON) $(NICE)/translator/nicewasm.py -o $@ $<

$(BUILD)/%_full.nasm: $(BUILD)/%.nasm $(START) $(RUNTIME)
	cat $(START) $< $(RUNTIME) > $@

$(BUILD)/%.bin: $(BUILD)/%_full.nasm $(NICEASM)
	$(PYTHON) $(NICE)/assembler/niceasm.py -o $@ $<

$(BUILD):
	mkdir -p $@

clean:
	rm -rf $(BUILD)

.PHONY: all clean FORCE
.PRECIOUS: $(BUILD)/%.wasm $(BUILD)/%.nasm $(BUILD)/%_full.nasm
