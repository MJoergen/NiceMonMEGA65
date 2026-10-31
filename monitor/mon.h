// The entries of the monitor's ROM for a C program (monitor/README.md, "The
// dispatch table"). The program is built with nicebuild.py --monitor --asm
// mon.nasm, whose stubs call the entries: a call to one of these functions
// is a call to the stub of its name. The program runs at 0x8000, with the
// ROM visible, as every program for the monitor does. printf and the other
// output of the C library reach the monitor's outputs through the putc
// vector, without this header.
#ifndef MON_H
#define MON_H

// Back to the monitor's main loop with a status, on a fresh stack. exit()
// of the C library returns to the monitor too, with the stack of the entry.
__attribute__((noreturn)) void mon_exit(int status);

// The version of the dispatch table: the major number in bits 31..16, the
// minor in 15..0.
unsigned mon_version(void);

// A character, bits 7..0, to the outputs that mon_out selects: on the
// screen at the cursor, which moves on; on the line as it is.
void mon_putc(int c);

// The outputs of mon_putc: bit 0 the line, bit 1 the screen, both at reset.
// Returns the old ones.
unsigned mon_out(unsigned outputs);

// The screen blank in the current color, the cursor at the top left.
void scr_cls(void);

// The cursor to a column, 0 to 79, and a row, 0 to 24.
void scr_moveto(int col, int row);

// The cursor's column, and its row. scr_getxy of the table gives both at
// once, in R1 and R2, which C cannot take.
int scr_getx(void);
int scr_gety(void);

// The color of the characters put from now on, bits 31..8 of a screen
// word: the background in 31..20, the foreground in 19..8. Returns the
// old one.
unsigned scr_color(unsigned color);

#endif
