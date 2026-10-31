// A C program for the monitor (README.md, "Programs"), built with
// nicebuild.py --monitor --asm mon.nasm (Makefile). printf goes through the
// putc vector, which the start-up code set to the monitor's mon_putc
// entry, and the HAL's routines are called through mon.h: the version of
// the table, a text at column 40 of the next row in yellow, and a line on
// the line only. It returns 7. The test runs it with the input
// test/run.txt.
#include <stdio.h>
#include "mon.h"

int main(void)
{
    unsigned v = mon_version();
    printf("Hello from C at 00008000, table %u.%u\n", v >> 16, v & 0xFFFF);
    scr_moveto(40, scr_gety());
    unsigned old = scr_color(0x000FF000);
    printf("at column 40\n");
    scr_color(old);
    mon_out(1);
    printf("on the line only\n");
    mon_out(3);
    return 7;
}
