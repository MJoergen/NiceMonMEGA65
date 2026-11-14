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
// with mode 2 the folder itself, whose name is empty or /. The name is
// its long name, up to 255 characters, or its 8.3 name, in either case
// (table 1.4). Two may be open at once. A handle, 0 or 1, or an error.
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

// A file of the folder NICE deleted, with its long-name entries. 0, or an
// error.
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

// The IP address from the network's DHCP server, as i dhcp gets it,
// with the mask, the gateway, and the DNS server, printing nothing. With
// an address set, it asks for that one. Waits up to 16 seconds. 0, or an
// error. Entry 23 (issue #111).
int net_dhcp(void);

// The poll of the network: the frames that wait taken, a datagram for the
// endpoint held for udp_recv. Never waits. Not negative. A program that
// uses the network calls it every 100 ms or so. Entry 24 (issue #111).
int net_poll(void);

// The IP settings, DNS, and TCP, from table 1.5 (monitor/README.md, "The
// network", and "TCP"). These take C pointers: the program joins
// mon_c.nasm too, with nicebuild.py --monitor --asm mon.nasm --asm
// mon_c.nasm, whose stubs turn a pointer into the address of the ROM's
// windows. An error is negative, from -40 (doc/PROGRAMMING.md, "The
// monitor's error codes").
#define MON_ENTRY(name) __attribute__((import_name("c_" #name)))

// The IP address, the mask, the gateway, and the DNS server, each 0 for
// none, written to cfg. 0. Entry 21.
MON_ENTRY(net_config) int net_config(unsigned cfg[4]);

// The four set from cfg, as net_config gives them, for a network with no
// DHCP. A new IP address ends every TCP connection in E_TRESET. 0. Entry
// 22.
MON_ENTRY(net_set) int net_set(const unsigned cfg[4]);

// The IPv4 address of a name, up to its 0 byte, written to *ip: an
// address with dots, such as 192.168.1.10, as it is, or else the answer of
// the DNS server, which takes up to about 9 seconds. 0, or an error. Entry
// 25.
MON_ENTRY(dns_lookup) int dns_lookup(const char *name, unsigned *ip);

// TCP, up to 4 connections at once, each with a control block of
// TCP_CB_WORDS(rx, tx) words in the program's RAM, which is the ROM's from
// tcp_open or tcp_listen until tcp_state gives TCP_FREE. The ROM moves
// a connection only when the program calls an entry of the network: a
// program polls, with net_poll, every 100 ms or so.
#define TCP_CB_WORDS(rx, tx) (32 + ((rx) + 3) / 4 + ((tx) + 3) / 4)
#define TCP_SIZES(rx, tx) (((unsigned)(rx) << 16) | (unsigned)(tx))
enum {
    TCP_FREE = 0,       // the handle is free
    TCP_CONNECTING = 1, // the handshake; bytes sent go after it
    TCP_OPEN = 2,       // send and receive
    TCP_PEER_CLOSED = 3, // receive what is left, then E_TEOF; send; close
    TCP_CLOSING = 4,    // after tcp_close; the handle frees itself
    TCP_LISTEN = 5,     // tcp_listen's, until a peer connects
};
enum {
    E_NOIP = -40, E_PORT = -41, E_UCLOSED = -42, E_ULONG = -43, E_NOROUTE = -44,
    E_NODHCP = -45, E_NODNS = -46, E_DNSTIME = -47, E_DNSNAME = -48, E_DNSFAIL = -49,
    E_THANDLE = -50, E_TFULL = -51, E_TSIZE = -52, E_TREFUSED = -53, E_TRESET = -54,
    E_TTIMEOUT = -55, E_TCLOSED = -56, E_TEOF = -57,
};

// A connection opened to a port of an IP address, with the rings of
// TCP_SIZES(rx, tx) bytes, each 64 or more, in the control block cb. Waits
// up to 3 seconds for ARP, sends the SYN, and does not wait for the
// answer. A handle, 0 to 3, or an error. Entry 26.
MON_ENTRY(tcp_open) int tcp_open(unsigned *cb, unsigned ip, unsigned port, unsigned sizes);

// The state of a handle, TCP_FREE to TCP_LISTEN, or the connection's
// error, or E_THANDLE. A state not known here is one to wait in. Entry 27.
int tcp_state(int h);

// Up to n bytes from buf taken into the ring to send, and sent as far as
// the windows let them. The bytes taken, 0 when the ring is full, or an
// error. Entry 28.
MON_ENTRY(tcp_send) int tcp_send(int h, const void *buf, unsigned n);

// Up to n of the bytes received copied to buf. The bytes copied, 0 when
// none wait, E_TEOF when the peer has closed and every byte is read, or
// an error. Entry 29.
MON_ENTRY(tcp_recv) int tcp_recv(int h, void *buf, unsigned n);

// A close, abort 0, which sends the bytes that wait, then the FIN, and
// drops what comes, or an abort, abort 1, which sends a RST. The handle
// frees itself, or at once for an abort or an error. 0, or E_THANDLE.
// Entry 30.
int tcp_close(int h, int abort);

// A handle that waits in TCP_LISTEN for a peer to connect to port, 1 to
// 65535 but 4510, with the rings of TCP_SIZES(rx, tx) bytes in the
// control block cb. The first SYN takes it, through TCP_CONNECTING, to
// TCP_OPEN, one connection for each handle; a failed handshake brings it
// back to TCP_LISTEN. Other handles may listen on the same port. Sends
// nothing, and does not wait. A handle, 0 to 3, or an error. Entry 31.
MON_ENTRY(tcp_listen) int tcp_listen(unsigned *cb, unsigned port, unsigned sizes);

// The next entry of a directory, as fs_readdir gives it in the 4 words
// from buf, and its name in the words from name, one character per word
// up to a 0 word, 256 words at most: its long name, or else its 8.3 name
// as a name, HELLO.BIN, in lower case where the entry says so. A
// character of a long name outside ASCII is ?. 1, 0 at the end, or an
// error. Table 1.4 (monitor/README.md, "Files").
int fs_readname(int handle, unsigned buf, unsigned name);

#endif
