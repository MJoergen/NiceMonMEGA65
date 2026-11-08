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
# make          builds build/primes.bin, and build/bench.bin from nice_cpu's
#               benchmark, bench/bench.c, which tools/hwtest.py runs
# make clean    removes build/
#
# Needs clang with the wasm32 target, wasm-ld and llvm-ar (the lld and llvm
# packages), and Python 3.

CLANG  ?= clang
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

PROGRAMS = primes bench
# The programs that call scanf, and so need float.nasm.
FLOAT_PROGRAMS = primes

all: $(PROGRAMS:%=$(BUILD)/%.bin)

# The library is built in the submodule, which ignores its build files.
$(LIBC)/libc.a: FORCE
	$(MAKE) -C $(LIBC) libc.a

$(FLOAT): FORCE
	$(MAKE) -C $(NICE_CPU)/runtime float.nasm

$(BUILD)/%.wasm: %.c $(LIBC)/libc.a | $(BUILD)
	$(CLANG) $(CFLAGS) $(LDFLAGS) -o $@ $< $(LIBC)/libc.a

$(BUILD)/bench.wasm: $(NICE_CPU)/bench/bench.c $(LIBC)/libc.a | $(BUILD)
	$(CLANG) $(CFLAGS) $(LDFLAGS) -o $@ $< $(LIBC)/libc.a

$(BUILD)/%.nasm: $(BUILD)/%.wasm $(NICEWASM)
	$(PYTHON) $(NICE_CPU)/translator/nicewasm.py -o $@ $<

$(BUILD)/%_full.nasm: $(BUILD)/%.nasm $(START) $(RUNTIME)
	cat $(START) $< $(RUNTIME) > $@

$(FLOAT_PROGRAMS:%=$(BUILD)/%_full.nasm): $(BUILD)/%_full.nasm: $(BUILD)/%.nasm $(START) $(RUNTIME) $(FLOAT)
	cat $(START) $< $(RUNTIME) $(FLOAT) > $@

$(BUILD)/%.bin: $(BUILD)/%_full.nasm $(NICEASM)
	$(PYTHON) $(NICE_CPU)/assembler/niceasm.py -o $@ $<

$(BUILD):
	mkdir -p $@

clean:
	rm -rf $(BUILD)

.PHONY: all clean FORCE
.PRECIOUS: $(BUILD)/%.wasm $(BUILD)/%.nasm $(BUILD)/%_full.nasm
