// The entries of the monitor's ROM for a C program (monitor/README.md, "The
// dispatch table"). The program is built with nicebuild.py --monitor --asm
// mon.nasm, whose stubs call the entries: a call to one of these functions
// is a call to the stub of its name, such as _mon_scr_cls for the entry
// scr_cls. Every function here starts with mon_, so that its name clashes
// with none of the program's. The program runs at 0x8000, with the ROM
// visible, as every program for the monitor does. printf and the other
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
enum { MON_OUT_LINE = 1, MON_OUT_SCREEN = 2 };
unsigned mon_out(unsigned outputs);

// The screen blank in the current color, the cursor at the top left.
void mon_scr_cls(void);

// The cursor to a column, 0 to 79, and a row, 0 to 24.
void mon_scr_moveto(int col, int row);

// The cursor's column, and its row. The table's scr_getxy gives both at
// once, in R1 and R2, which C cannot take; mon.nasm has a stub for each.
int mon_scr_getx(void);
int mon_scr_gety(void);

// The color of the characters put from now on, bits 31..8 of a screen
// word: the background in 31..20, the foreground in 19..8. Returns the
// old one.
unsigned mon_scr_color(unsigned color);

// Colors for mon_scr_color: a foreground and a background, added or
// or-ed, such as MON_FG_YELLOW | MON_BG_BLUE. A color left out is black.
#define MON_FG_BLACK         0x00000000u
#define MON_FG_RED           0x000F0000u
#define MON_FG_GREEN         0x0000F000u
#define MON_FG_YELLOW        0x000FF000u
#define MON_FG_BLUE          0x00000F00u
#define MON_FG_MAGENTA       0x000F0F00u
#define MON_FG_CYAN          0x0000FF00u
#define MON_FG_WHITE         0x000FFF00u
#define MON_FG_GRAY          0x00088800u
#define MON_FG_LIGHT_RED     0x000F6600u
#define MON_FG_LIGHT_GREEN   0x0008E800u
#define MON_FG_LIGHT_BLUE    0x0000DF00u
#define MON_FG_DARK_BLUE     0x00003600u

#define MON_BG_BLACK         0x00000000u
#define MON_BG_RED           0xF0000000u
#define MON_BG_GREEN         0x0F000000u
#define MON_BG_YELLOW        0xFF000000u
#define MON_BG_BLUE          0x00F00000u
#define MON_BG_MAGENTA       0xF0F00000u
#define MON_BG_CYAN          0x0FF00000u
#define MON_BG_WHITE         0xFFF00000u
#define MON_BG_GRAY          0x88800000u
#define MON_BG_LIGHT_RED     0xF6600000u
#define MON_BG_LIGHT_GREEN   0x8E800000u
#define MON_BG_LIGHT_BLUE    0x0DF00000u
#define MON_BG_DARK_BLUE     0x03600000u

// The files of the SD card's FAT32 file system, from table 1.1, and
// mon_fs_write and mon_fs_delete from table 1.2 (monitor/README.md,
// "Files"; the errors in doc/PROGRAMMING.md, "The monitor's error codes").
// The addresses are NICE word addresses, not C pointers: a name is one
// character per word up to a 0 word, and mon_fs_read and mon_fs_write
// take one byte per word, so a C program passes the address of an array
// of unsigned words of its own, which mon_words gives (below), or of
// words outside its memory, which it reads with nice_peek and writes with
// nice_poke. An error is negative: -1 to -8 those of the SD controller,
// and -16 on those of FAT32.

// The card in a slot mounted, and the files that were open closed. 0, or
// an error.
int mon_fs_mount(unsigned slot);

// A file of the folder NICE of the card's root directory opened, with
// mode 0 to read, with mode 1 to write, made or truncated (table 1.2), or
// with mode 2 the folder itself, whose name is empty or /. The name is
// its long name, up to 255 characters, or its 8.3 name, in either case
// (table 1.4). Two may be open at once. A handle, 0 or 1, or an error.
int mon_fs_open(unsigned name, int mode);

// Up to n bytes of a file read, one per word from buf. The number read, 0
// at the end, or an error.
int mon_fs_read(int handle, unsigned buf, unsigned n);

// The next entry of a directory: in the 4 words from buf, the 11 bytes of
// the 8.3 name, padded with blanks, and the attributes, 4 bytes to a word
// from bits 7..0, and the size. 1, 0 at the end, or an error.
int mon_fs_readdir(int handle, unsigned buf);

// A file or directory closed; a file opened to write is finished, its
// size written. 0, or an error.
int mon_fs_close(int handle);

// Up to n bytes written to a file opened to write, from bits 7..0 of the
// words from buf. The number written, fewer when the card is full, or an
// error. Table 1.2.
int mon_fs_write(int handle, unsigned buf, unsigned n);

// A file of the folder NICE deleted, with its long-name entries. 0, or an
// error.
// Table 1.2.
int mon_fs_delete(unsigned name);

// The UDP endpoint, from table 1.3 (monitor/README.md, "The network"): one
// local port, and datagrams of bytes one per word, as for the files. An
// error is negative, from -40 (doc/PROGRAMMING.md, "The monitor's error
// codes").

// The endpoint opened on a local port, or with 0 on one from 49152 to
// 65535, and the port for Ethernet frames enabled. The port, or an error.
int mon_udp_open(unsigned port);

// n bytes, up to 1472, from bits 7..0 of the words from buf, sent as a
// datagram to a port of an IP address, through the gateway of i dhcp when
// the address is in another network. 0, or an error.
int mon_udp_send(unsigned ip, unsigned port, unsigned buf, unsigned n);

// Up to n bytes of the next datagram copied, one per word from buf, and
// its source's IP address and port to the 2 words at src, unless src is
// 0; with n 0 nothing, and the datagram stays. Does not wait. The bytes
// copied, 0 when none waits, or an error.
int mon_udp_recv(unsigned buf, unsigned n, unsigned src);

// The endpoint closed, and the port for Ethernet frames disabled. 0.
int mon_udp_close(void);

// The IP address from the network's DHCP server, as i dhcp gets it,
// with the mask, the gateway, and the DNS server, printing nothing. With
// an address set, it asks for that one. Waits up to 16 seconds. 0, or an
// error. Entry 23 (issue #111).
int mon_net_dhcp(void);

// The poll of the network: the frames that wait taken, a datagram for the
// endpoint held for mon_udp_recv. Never waits. Not negative. A program that
// uses the network calls it every 100 ms or so. Entry 24 (issue #111).
int mon_net_poll(void);

// The IP settings, DNS, and TCP, from table 1.5 (monitor/README.md, "TCP
// and DNS"). A program checks that mon_version is 0x00010005 or more.
// These take C pointers: the program joins mon_c.nasm too, with
// nicebuild.py --monitor --asm mon.nasm --asm mon_c.nasm, whose stubs
// turn a pointer into the address of the ROM's windows: MON_ENTRY names
// the stub of mon_c.nasm, _c_ and the entry's name. An error is negative,
// from -40 (doc/PROGRAMMING.md, "The monitor's error codes").
#define MON_ENTRY(name) __attribute__((import_name("c_" #name)))

// The IP address, the mask, the gateway, and the DNS server, each 0 for
// none, written to cfg. 0. Entry 21.
MON_ENTRY(net_config) int mon_net_config(unsigned cfg[4]);

// The four set from cfg, as mon_net_config gives them, for a network with
// no DHCP. A new IP address ends every TCP connection in MON_E_TRESET. 0.
// Entry 22.
MON_ENTRY(net_set) int mon_net_set(const unsigned cfg[4]);

// The IPv4 address of a name, up to its 0 byte, written to *ip: an
// address with dots, such as 192.168.1.10, as it is, or else the answer of
// the DNS server, which takes up to about 9 seconds. 0, or an error. Entry
// 25.
MON_ENTRY(dns_lookup) int mon_dns_lookup(const char *name, unsigned *ip);

// TCP, up to 4 connections at once, each with a control block of
// MON_TCP_CB_WORDS(rx, tx) words in the program's RAM, which is the
// ROM's from mon_tcp_open or mon_tcp_listen until mon_tcp_state gives
// MON_TCP_FREE. The ROM moves a connection only when the program calls an
// entry of the network: a program polls, with mon_net_poll, every 100 ms
// or so.
#define MON_TCP_CB_WORDS(rx, tx) (32 + ((rx) + 3) / 4 + ((tx) + 3) / 4)
#define MON_TCP_SIZES(rx, tx) (((unsigned)(rx) << 16) | (unsigned)(tx))
enum {
    MON_TCP_FREE = 0,        // the handle is free
    MON_TCP_CONNECTING = 1,  // the handshake; bytes sent go after it
    MON_TCP_OPEN = 2,        // send and receive
    MON_TCP_PEER_CLOSED = 3, // receive what is left, then MON_E_TEOF;
                             // send; close
    MON_TCP_CLOSING = 4,     // after mon_tcp_close; the handle frees itself
    MON_TCP_LISTEN = 5,      // mon_tcp_listen's, until a peer connects
};
enum {
    MON_E_NOIP = -40, MON_E_PORT = -41, MON_E_UCLOSED = -42,
    MON_E_ULONG = -43, MON_E_NOROUTE = -44, MON_E_NODHCP = -45,
    MON_E_NODNS = -46, MON_E_DNSTIME = -47, MON_E_DNSNAME = -48,
    MON_E_DNSFAIL = -49, MON_E_THANDLE = -50, MON_E_TFULL = -51,
    MON_E_TSIZE = -52, MON_E_TREFUSED = -53, MON_E_TRESET = -54,
    MON_E_TTIMEOUT = -55, MON_E_TCLOSED = -56, MON_E_TEOF = -57,
};

// A connection opened to a port of an IP address, with the rings of
// MON_TCP_SIZES(rx, tx) bytes, each 64 or more, in the control block cb. Waits
// up to 3 seconds for ARP, sends the SYN, and does not wait for the
// answer. A handle, 0 to 3, or an error. Entry 26.
MON_ENTRY(tcp_open) int mon_tcp_open(unsigned *cb, unsigned ip,
                                     unsigned port, unsigned sizes);

// The state of a handle, MON_TCP_FREE to MON_TCP_LISTEN, or the connection's
// error, or MON_E_THANDLE. A state not known here is one to wait in. Entry 27.
int mon_tcp_state(int h);

// Up to n bytes from buf taken into the ring to send, and sent as far as
// the windows let them. The bytes taken, 0 when the ring is full, or an
// error. Entry 28.
MON_ENTRY(tcp_send) int mon_tcp_send(int h, const void *buf, unsigned n);

// Up to n of the bytes received copied to buf. The bytes copied, 0 when
// none wait, MON_E_TEOF when the peer has closed and every byte is read, or
// an error. Entry 29.
MON_ENTRY(tcp_recv) int mon_tcp_recv(int h, void *buf, unsigned n);

// A close, abort 0, which sends the bytes that wait, then the FIN, and
// drops what comes, or an abort, abort 1, which sends a RST. The handle
// frees itself, or at once for an abort or an error. 0, or MON_E_THANDLE.
// Entry 30.
int mon_tcp_close(int h, int abort);

// A handle that waits in MON_TCP_LISTEN for a peer to connect to port, 1 to
// 65535 but 4510, with the rings of MON_TCP_SIZES(rx, tx) bytes in the
// control block cb. The first SYN takes it, through MON_TCP_CONNECTING, to
// MON_TCP_OPEN, one connection for each handle; a failed handshake brings it
// back to MON_TCP_LISTEN. Other handles may listen on the same port. Sends
// nothing, and does not wait. A handle, 0 to 3, or an error. Entry 31.
MON_ENTRY(tcp_listen) int mon_tcp_listen(unsigned *cb, unsigned port,
                                         unsigned sizes);

// The services of table 1.6 (issue #152), which BASIC uses too. A
// program checks that mon_version is 0x00010006 or more. Those with
// MON_ENTRY take C pointers, as those of table 1.5 do.

// A line typed on the console into buf, one character a word, up to n
// characters and a 0 word after them, so buf has n + 1 words: BASIC's
// line, with the scrollback's keys before it, and TAB, which completes
// the name of a file of the card's folder. The number of characters.
// Entry 32.
MON_ENTRY(con_getline) int mon_con_getline(unsigned *buf, unsigned n);

// A line of a .bin file, one character a word up to a 0 word: ADDR WORD
// in hex writes WORD at ADDR in a program's RAM. counts, which the
// program clears before the first line, has the words written, the
// lowest and highest address, the lines skipped, the number of the
// first, the lines, and the end of a program's RAM, which it writes. 1
// when the word was written, 0 for blanks only, -1 when the line was
// skipped. Entry 33.
MON_ENTRY(bin_line) int mon_bin_line(const unsigned *line,
                                     unsigned counts[7]);

// The clock of the time of day set to secs since 1970, in local time,
// and usecs, and on the MEGA65 its real-time clock, in the years 2000 to
// 2099. 0. Entry 34.
int mon_clock_set(unsigned secs, unsigned usecs);

// The DHCP server of the last exchange, and the NTP server that DHCP
// gave, each 0 for none, written to srv. 0. Entry 35.
MON_ENTRY(net_servers) int mon_net_servers(unsigned srv[2]);

// The state after a program, for a program that runs another: E, the
// timer, the FPU, VBASE, the font base, and the mode word cleared, the
// network closed, and the cursor shown at its registers. 0. Entry 36.
int mon_restore(void);

// The services of table 1.7 (issue #153), for BASIC's own line and its
// banner. A program checks that mon_version is 0x00010007 or more.

// The word address of the monitor's version, a packed text, four
// characters a word, such as V2.3.1. Entry 37.
unsigned mon_build(void);

// The next byte of the console, waited for when bit 0 of flags is 1, or
// -1 when none waits and bit 0 is 0. Meanwhile it keeps the network going,
// as con_getline does, and with bit 1 shows an address that DHCP gets,
// for a caller whose line is empty. Entry 38.
int mon_con_key(unsigned flags);

// The scrollback: rows further back when rows is above 0, -rows forward
// when it is below 0, and the screen again when it is 0 or reaches the
// screen. The rows shown back now, 0 for the screen. Entry 39.
int mon_scr_back(int rows);

// TAB on a line of words, one character each, with the cursor at cursor
// and room up to end, the word after the last: completes the name of a
// file of the card's folder before the cursor, or lists the matches and
// shows the line again, up to the cursor. The new cursor. Entry 40.
MON_ENTRY(fs_complete) unsigned *mon_fs_complete(unsigned *line, unsigned *cursor,
                                                 unsigned *end);

// The service of table 1.8, for BASIC's screen editor. A program checks
// that mon_version is 0x00010008 or more.

// The rows of the screen that go on from the row above, bit r for row r,
// 1 to 24: mon_putc sets a row's bit when it wraps to it past the last
// column, clears it at a LF and when the row is written again from its
// column 0, and shifts the word when the screen scrolls; scr_cls clears
// it, and so does the end of a program that moved the cursor through
// its registers. links the new word, or -1 to keep it. The old word.
// Entry 41.
unsigned mon_scr_links(unsigned links);

// The NICE word address of a C array of words, for the entries above
// that take one character or byte per word, such as mon_fs_open's name
// and mon_fs_read's buffer, which the program then reads as plain unsigned
// words. Not an entry of the table: its stub in mon_c.nasm returns the
// address at once.
MON_ENTRY(mon_words) unsigned mon_words(const unsigned *p);

// The next entry of a directory, as mon_fs_readdir gives it in the 4
// words from buf, and its name in the words from name, one character per word
// up to a 0 word, 256 words at most: its long name, or else its 8.3 name
// as a name, HELLO.BIN, in lower case where the entry says so. A
// character of a long name outside ASCII is ?. 1, 0 at the end, or an
// error. Table 1.4 (monitor/README.md, "Files").
int mon_fs_readname(int handle, unsigned buf, unsigned name);

#endif
