// The ROM's C code (README.md, "C in the ROM"). The Makefile compiles the
// files of ROM_C, this one first, to one wasm module, which nicewasm --ram
// translates for the ROM, with its writable words in the RAM at WASM_RAM
// (monitor.nasm). Each function that is not static is exported, and the
// monitor's assembly calls it as _name, in the C ABI of nice_cpu's
// runtime/ABI.md. This file is empty; the module's code is fat32.c, the
// FAT32 code of issue #58.
