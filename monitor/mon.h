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

// The files of the SD card's FAT32 file system, from table 1.1, and
// fs_write and fs_delete from table 1.2 (monitor/README.md, "Files";
// the errors in doc/PROGRAMMING.md, "The monitor's error codes"). The
// addresses are NICE word addresses, not C pointers: a name is one
// character per word up to a 0 word, and fs_read and fs_write take one
// byte per word, so a C program passes the address of words outside its
// memory, which it reads with nice_peek and writes with nice_poke. An
// error is negative: -1 to -8 those of the SD controller, and -16 on
// those of fat32.c.

// The card in a slot mounted, and the files that were open closed. 0, or
// an error.
int fs_mount(unsigned slot);

// A file of the folder NICE of the card's root directory opened, with
// mode 0 to read, with mode 1 to write, made or truncated (table 1.2), or
// with mode 2 the folder itself, whose name is empty or /. Two may be
// open at once. A handle, 0 or 1, or an error.
int fs_open(unsigned name, int mode);

// Up to n bytes of a file read, one per word from buf. The number read, 0
// at the end, or an error.
int fs_read(int handle, unsigned buf, unsigned n);

// The next entry of a directory: in the 4 words from buf, the 11 bytes of
// the 8.3 name, padded with blanks, and the attributes, 4 bytes to a word
// from bits 7..0, and the size. 1, 0 at the end, or an error.
int fs_readdir(int handle, unsigned buf);

// A file or directory closed; a file opened to write is finished, its
// size written. 0, or an error.
int fs_close(int handle);

// Up to n bytes written to a file opened to write, from bits 7..0 of the
// words from buf. The number written, fewer when the card is full, or an
// error. Table 1.2.
int fs_write(int handle, unsigned buf, unsigned n);

// A file of the folder NICE deleted, with its long name. 0, or an error.
// Table 1.2.
int fs_delete(unsigned name);

// The UDP endpoint, from table 1.3 (monitor/README.md, "The network"): one
// local port, and datagrams of bytes one per word, as for the files. An
// error is negative, from -40 (doc/PROGRAMMING.md, "The monitor's error
// codes").

// The endpoint opened on a local port, or with 0 on one from 49152 to
// 65535, and the port for Ethernet frames enabled. The port, or an error.
int udp_open(unsigned port);

// n bytes, up to 1472, from bits 7..0 of the words from buf, sent as a
// datagram to a port of an IP address, through the gateway of i dhcp when
// the address is in another network. 0, or an error.
int udp_send(unsigned ip, unsigned port, unsigned buf, unsigned n);

// Up to n bytes of the next datagram copied, one per word from buf, and
// its source's IP address and port to the 2 words at src, unless src is
// 0; with n 0 nothing, and the datagram stays. Does not wait. The bytes
// copied, 0 when none waits, or an error.
int udp_recv(unsigned buf, unsigned n, unsigned src);

// The endpoint closed, and the port for Ethernet frames disabled. 0.
int udp_close(void);

#endif
