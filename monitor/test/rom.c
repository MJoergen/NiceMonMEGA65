// The test of the ROM's C code (Makefile, rom), joined to ROM_C in the
// ROM of the test only, and called by test/rom.nasm by the labels.
// rom_count returns 7 the first time after a cold start, from the initial
// value that ___wasm_start copies to the RAM, and one more each time after.
// rom_zero returns the sum of a static array that ___wasm_start sets to 0,
// and then writes it, so that it returns 0 only after a cold start.
// rom_hello prints through nice_print and the putc vector, and rom_trap
// traps, with code 1, unreachable.
void nice_print(const char *s);

static int count = 7;
static int zero[4];

int rom_count(void)
{
    return count++;
}

int rom_zero(void)
{
    int sum = 0;
    for (int i = 0; i < 4; i++) {
        sum += zero[i];
        zero[i] = i + 1;
    }
    return sum;
}

void rom_hello(void)
{
    nice_print("Hello from the ROM's C code\n");
}

void rom_trap(void)
{
    __builtin_trap();
}
