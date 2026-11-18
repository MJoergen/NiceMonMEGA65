; The monitor, the program of the ROM at 0x0000 (README.md). The core boots
; from it at reset. It gives the programs at 0x8000 a hardware abstraction
; layer, the HAL: thirty-seven routines, called through the dispatch table at
; the start of the ROM, and its main loop is BASIC's (issue #54), whose
; statements are typed on the keyboard or sent over the line, and shown
; on the screen and the line.
;
; The dispatch table has one JMP routine per entry, two words, so that
; entry n is at address 2n, and entry 0 is the reset. The routines follow
; the C ABI of nice_cpu/runtime/ABI.md: the arguments in R1-R4, the result
; in R1, R1-R6 changed, and R7-R13 kept. mon.nasm has the address of each
; entry as an .EQU, and a stub that jumps to it.
;
; The cold start, mon_reset, sets SP to STACK, the variables, and the
; screen, and goes to bas_start, which prints the banner and runs the main
; loop, main, of basic.nasm. At mon_exit, the monitor clears E, stops the
; timer, clears the FPU, sets VBASE to 0, and shows the cursor,
; blinking, with mon_restore, takes a fresh stack, and goes to BASIC's
; warm start, bas_warm, which prints the status, R1, and goes back to
; main; a program that SYS called and that returns has the same, but
; the stack, and BASIC goes on. BASIC calls the monitor through the
; entries of the dispatch table (issue #152), but for the routines that
; it has not left yet.
;
; The monitor is this file and ten more, which the Makefile joins after
; it, in this order, so that the dispatch table is at 0. The first four
; are BASIC's, which reaches the monitor through the entries of the
; dispatch table alone (issue #152), as test/sides.py checks:
;
; - monitor_cmd.nasm: the routines of BASIC's statements that replace the
;   monitor's commands, and the routines and texts that only they use.
; - basic.nasm: BASIC, the main loop, the scanner of a line, which calls
;   the statements, and its keywords and messages (issues #112 and #115,
;   doc/BASIC.md).
; - basic_net.nasm: the statements DHCP, NTP, and TFTP's LOAD and DIR
;   (issues #84 and #127).
; - basic_time.nasm: TIME, and the clock's side of NTP (issues #105 and
;   #127).
; - monitor_dis.nasm: DIS, the disassembler (README.md, "The
;   disassembler").
; - monitor_sd.nasm: the SD cards below the file system, the sector
;   routines sd_init, sd_read, and sd_write that FAT32 reads and writes
;   through (issue #57, doc/SDCARD.md).
; - monitor_fat.nasm: FAT32, the file entries 9 to 15 and 20, and TAB
;   of a card (issues #58, #59, and #149, INTERNALS.md, "FAT32").
; - monitor_eth.nasm: the network, the frame routines, the ARP cache, the
;   demultiplexing of the frames and net_poll, the UDP entries 16 to 19,
;   the entries 21 to 25 of the IP settings, DHCP, the poll, and DNS
;   (issues #83 and #111, README.md, "The network", and INTERNALS.md,
;   "The frame routines").
; - monitor_tcp.nasm: TCP, the entries 26 to 31 of its clients and its
;   servers, and their part of the poll (issue #111).
; - monitor_clock.nasm: the clock of the time of day, clock_set, entry
;   34, the dates of FAT's entries, and the real-time clock (issues #105,
;   #109, and #148).
; - common.nasm: what both share, the addresses of the devices that both
;   use, the packed texts of puts_b, IP addresses, and the conversions of
;   a date and a time.
;
; Each has the .EQUs of its devices and its constants, and its texts, but
; the variables of all of them are here, as one map of the RAM. The
; assembler takes a name
; before its .EQU or its label, so the files reach each other's names in
; either direction.
;
; The ROM's texts are packed, four characters a word, with .ASCII_B
; (nice_cpu's ISA.md §10.3), and end with a 0 byte: a text whose length is
; a multiple of 4 has a .DAT 0 after it, which test/texts.py checks at
; each build. puts_b prints one by its word address, through the byte
; window at TEXT_B (nice_cpu's DEVICES.md §9), in which _io_puts reads one
; byte at a time. Code that reads a text by the character takes its
; address in that window, TEXT_B+4*S_NAME, and the tables of texts hold
; word addresses, which puts_b takes. Programs keep .ASCII_L, one
; character a word, which _io_puts prints (issue #131).
;
; mon_putc writes a character to the outputs that V_OUT selects. On the
; line, the console at 0xFFFFFF00, every byte goes as it is. On the screen
; a character goes at the cursor, which moves on; CR moves the cursor to
; column 0, LF to column 0 of the next row, BS one column back, and TAB to
; the next multiple of 8; the other control codes and 0x7F do nothing.
; 0x80 to 0x9F go on the screen as any character: they are blank in Spleen,
; and show what a program draws for them in the font RAM (nice_cpu's
; DEVICES.md §1.8). Past the last column the cursor goes to the next row, and past
; the last row the screen's rows move up by one, by copying, which scrolls
; in niceemu too, where the display offset is plain memory, and the same
; on a board whose screen is smaller. So the rows shown are always the 2000
; words at SCREEN, as in niceemu.
;
; The scrollback: the row that leaves the top of the screen is copied into
; the history, a ring of rows in the rest of the screen's memory, from its
; top down. The cold start finds the size of the memory from the display
; offset, which keeps only the bits that address it on a board, and all of
; them in niceemu, where it is plain memory: 32768 words at most, 384 rows
; of history, 77 on the Nexys4DDR. Before a line is typed,
; the cursor keys up and down, ESC [ A and ESC [ B, show the history a row
; further back or forward, and Page Up and Page Down a page, through the
; display offset: k rows back is the offset 32768 - 80 k, which wraps to
; row 0 of the screen, so the first of those keys turns the ring so that
; its newest row is at the top of the memory. Any other key shows the screen again, and goes
; on to the line. niceemu has no display offset, so there the history is
; kept but not shown.
;
; The variables are in the RAM at 0xFFFFF000 and up, and the stack grows
; down from STACK, as the demo's do: a write to the ROM is dropped, so
; nothing of the monitor's is written below 0x8000. In niceemu, which has
; no ROM, the monitor is a program at 0 like any other, and cat
; monitor.bin prog.bin runs it with a program at 0x8000 (Makefile, test).
;
; The ROM is assembly only. A program in C brings nice_cpu's runtime
; library with it, and calls the entries of the dispatch table through
; the stubs of mon.nasm and mon_c.nasm (README.md, "Programs").
;
; The routines that the statements share with programs, _io_puts, _io_crlf,
; _io_puthex, _io_putdec, _io_gethex, _io_gets, and _io_getc, are in
; monlib.nasm, which the Makefile joins after the monitor's files, with
; mon.nasm and build/version.nasm, which defines VERSION, the string of
; the banner.

PC              .EQU    R15

CONSOLE         .EQU    0xFFFFFF00      ; a write: a byte to the line
SCR_CTL         .EQU    0xFFFFFF80      ; bit 6 shows the cursor, bit 5 blinks it
SCR_X           .EQU    0xFFFFFF81      ; the cursor's column
SCR_Y           .EQU    0xFFFFFF82      ; the cursor's row
SCR_OFFS        .EQU    0xFFFFFF85      ; the display offset, in words
SCR_FONT        .EQU    0xFFFFFF86      ; the font base: 0 shows Spleen
SCR_MODE        .EQU    0xFFFFFF87      ; the mode word: 0 shows the text, 1 the chunky mode
TIMER           .EQU    0xFFFFFF10      ; the timer's period, 0 to stop it
FPU_CMD         .EQU    0xFFFFFF8C      ; the FPU's command: 0x101, CLEAR 1, empties its stack and clears its flags

V_COL           .EQU    0xFFFFF000      ; the cursor's column, 0 to 79
V_ROW           .EQU    0xFFFFF001      ; and its row, 0 to 24
V_COLOR         .EQU    0xFFFFF002      ; the color of the characters put, bits 31..8
V_OUT           .EQU    0xFFFFF003      ; the outputs: bit 0 the line, bit 1 the screen
V_NEXT          .EQU    0xFFFFF004      ; the address that the next DUMP goes on at
V_HSIZE         .EQU    0xFFFFF005      ; the words of the screen's memory
V_HCAP          .EQU    0xFFFFF006      ; the rows of the history, after the 25 of the screen
V_HHEAD         .EQU    0xFFFFF007      ; the slot of the next row, slot i at SCREEN + V_HSIZE - 80 (i + 1)
V_HCOUNT        .EQU    0xFFFFF008      ; the rows kept, up to V_HCAP
V_BACK          .EQU    0xFFFFF009      ; the rows shown back, 0 for the screen
V_CTL           .EQU    0xFFFFF00A      ; SCR_CTL while the history is shown
V_LOUT          .EQU    0xFFFFF00B      ; V_OUT while LOAD reads its lines
V_LEND          .EQU    0xFFFFF00C      ; the last byte that LOAD read, for the LF of a CR LF
V_LPOS          .EQU    0xFFFFF00D      ; for LOAD from a file: the next free word of V_LINE
V_UNEXT         .EQU    0xFFFFF00F      ; the address that the next DIS goes on at
V_LINE          .EQU    0xFFFFF010      ; the line, LINE_MAX words, one over for LOAD, and a 0
LINE_MAX        .EQU    76              ; as the monitor's line had, after a prompt of 2
V_UF            .EQU    0xFFFFF060      ; for DIS: the fields dest, s0, and s1,
V_UC            .EQU    0xFFFFF063      ; their constant words,
V_UNOPS         .EQU    0xFFFFF066      ; and the operands of the mnemonic
V_I             .EQU    0xFFFFF068      ; for the clock: the fields of a date and a time to set, and a 7th word,
V_F             .EQU    0xFFFFF06E      ; the fields of the clock's time, which is the 7th of V_I,
V_DAYS          .EQU    0xFFFFF074      ; and its days since 1970
V_ARGS          .EQU    0xFFFFF075      ; for BASIC: the values of a statement, 4 words, slots 1, 2, and 4 at V_ARGS, +1, and +3
V_LSTATS        .EQU    0xFFFFF079      ; for LOAD: the counts of bin_line, 7 words
V_NET           .EQU    0xFFFFF080      ; for IP, DHCP, and NTP: the words of net_config and net_servers, 6 words
V_ENT           .EQU    0xFFFFF400      ; for DIR: an entry of fs_readname, 4 words,
V_NAME          .EQU    0xFFFFF404      ; and its name, 256 words
V_FBUF          .EQU    0xFFFFF504      ; for LOAD and SAVE: the bytes of fs_read and fs_write, FBUF_BYTES words
V_TBUF          .EQU    0xFFFFF584      ; for TFTP: a packet that udp_recv copied, TFTP_MAX words,
V_TSRC          .EQU    0xFFFFF788      ; and its source's IP address and port, 2 words
V_NTPQ          .EQU    0xFFFFF584      ; for NTP, in V_TBUF: the query, 48 words,
V_NTPA          .EQU    0xFFFFF5B4      ; and the answer, 48 words
V_ARP           .EQU    0xFFFFF100      ; the ARP cache: ARP_SLOTS entries of an IP address, 0 for none, the MAC address as E_MACH and E_MACL have it, and the time of arp_tick it was learned
V_ARPNEXT       .EQU    0xFFFFF110      ; the entry that arp_learn takes next, 4 times its number
V_XID           .EQU    0xFFFFF111      ; for DHCP: the transaction's number,
V_DIP           .EQU    0xFFFFF112      ; and the address of the OFFER or the ACK, its server, mask, and gateway,
V_DSRV          .EQU    0xFFFFF113
V_DMASK         .EQU    0xFFFFF114
V_DGW           .EQU    0xFFFFF115
V_PIP           .EQU    0xFFFFF116      ; and those of the last reply that dhcp_parse took
V_PSRV          .EQU    0xFFFFF117
V_PMASK         .EQU    0xFFFFF118
V_PGW           .EQU    0xFFFFF119
V_TXF           .EQU    0xFFFFF120      ; a frame to send, from byte 2, DHCP_WORDS words, as the send buffer has it
V_RXF           .EQU    0xFFFFF180      ; a frame received, from byte 2, 380 words, as the queue's buffer has it
V_MASK          .EQU    0xFFFFF302      ; the network's mask, from DHCP, 0 for none
V_GW            .EQU    0xFFFFF303      ; and its gateway, 0 for none
V_UPORT         .EQU    0xFFFFF304      ; the local port of the UDP endpoint, 0 while it is closed
V_UHDR          .EQU    0xFFFFF305      ; for udp_send: the headers, UDP_HDR words, as the send buffer has them
V_TSRV          .EQU    0xFFFFF310      ; for TFTP: the server's IP address,
V_TTID          .EQU    0xFFFFF311      ; its port, its TID, 0 before its first DATA,
V_TBLK          .EQU    0xFFFFF312      ; the block waited for,
V_TLEN          .EQU    0xFFFFF313      ; the bytes of the packet at V_TPKT,
V_TTIME         .EQU    0xFFFFF314      ; the microseconds when it was sent,
V_TEND          .EQU    0xFFFFF317      ; the bytes of the DATA's block,
V_TPORT         .EQU    0xFFFFF318      ; the server's port for the RRQ,
V_TLIST         .EQU    0xFFFFF319      ; not 0 for a listing, of DIR, which bin_eol shows,
V_TPKT          .EQU    0xFFFFF320      ; and the packet sent, a byte per word, up to TFTP_PKT
V_DNS           .EQU    0xFFFFF380      ; the DNS server, from DHCP or net_set, 0 for none
V_ULEN          .EQU    0xFFFFF381      ; the bytes of the datagram held for the endpoint at V_RXF, 0 for none
V_NWAIT         .EQU    0xFFFFF382      ; the local UDP port of the ROM's own wait, whose frames net_step copies to V_RXF, 0 for none
V_NARM          .EQU    0xFFFFF383      ; not 0 while the nearest deadline, V_NDUE, is armed
V_NDUE          .EQU    0xFFFFF384      ; the nearest deadline, on the fine clock of net_clock
V_IPID          .EQU    0xFFFFF385      ; the identification of the next IPv4 packet sent, in bits 15..0
V_DDNS          .EQU    0xFFFFF386      ; for DHCP: the DNS server of the OFFER or the ACK,
V_PDNS          .EQU    0xFFFFF387      ; and of the last reply that dhcp_parse took
V_QID           .EQU    0xFFFFF388      ; the ID of the query of dns_lookup, in bits 15..0; its port is V_NWAIT
V_TCPORT        .EQU    0xFFFFF389      ; the local port of the last TCP connection opened
V_TCOPENS       .EQU    0xFFFFF38A      ; the TCP connections opened since the cold start
V_TCWORK        .EQU    0xFFFFF38B      ; not 0 when a TCP connection may have something to send, for net_step
V_SDATA         .EQU    0xFFFFF38C      ; the word of the queue's buffer where the data of the segment taken starts
V_NHDR          .EQU    0xFFFFF390      ; the first 8 NHDR_CHUNKS words of the frame at the head of the queue, from byte 2
V_TCB           .EQU    0xFFFFF3A0      ; the plain address of each TCP handle's control block, 0 for a free one, and a word of 0 after them
V_TCR           .EQU    0xFFFFF3A8      ; for a RST to a segment of no connection: words 3 to 7 as a control block has them
V_TCH           .EQU    0xFFFFF3B0      ; the headers of a TCP segment to send, 15 words, as the send buffer has them
V_LEASE         .EQU    0xFFFFF3C0      ; not 0 while a DHCP lease is kept, which net_poll renews
V_LARM          .EQU    0xFFFFF3C1      ; not 0 while the lease's housekeeping deadline, V_LDUE, is armed
V_LDUE          .EQU    0xFFFFF3C2      ; that deadline, on the fine clock of net_clock
V_LNEXT         .EQU    0xFFFFF3C3      ; the lease's next REQUEST, on the coarse clock of arp_tick,
V_LT2           .EQU    0xFFFFF3C4      ; its T2, from which the REQUESTs are broadcast,
V_LEXP          .EQU    0xFFFFF3C5      ; and its end
V_LSRV          .EQU    0xFFFFF3C6      ; the lease's server, and its MAC address, as E_MACH
V_LMACH         .EQU    0xFFFFF3C7      ; and E_MACL have it
V_LMACL         .EQU    0xFFFFF3C8
V_PLEASE        .EQU    0xFFFFF3C9      ; of the last reply that dhcp_parse took: the lease, option 51,
V_PT1           .EQU    0xFFFFF3CA      ; T1 and T2, options 58 and 59, in seconds, 0 without them,
V_PT2           .EQU    0xFFFFF3CB
V_PMACH         .EQU    0xFFFFF3CC      ; and the MAC address that the frame came from
V_PMACL         .EQU    0xFFFFF3CD
V_BSTATE        .EQU    0xFFFFF3CE      ; the DHCP exchange in the background: the reply it waits for, DHCP_OFFER or DHCP_ACK, 0 for none,
V_BDUE          .EQU    0xFFFFF3CF      ; when it sends the next DISCOVER, on the fine clock of net_clock,
V_BWAIT         .EQU    0xFFFFF3D0      ; and the microseconds it waits after that one
V_NTP           .EQU    0xFFFFF3D1      ; the NTP server, the first of DHCP's option 42, 0 for none
V_DNTP          .EQU    0xFFFFF3D2      ; for DHCP: the NTP server of the OFFER or the ACK,
V_PNTP          .EQU    0xFFFFF3D3      ; and of the last reply that dhcp_parse took
V_NTPIP         .EQU    0xFFFFF3D4      ; for NTP: the server's IP address, which dns_lookup writes
; FAT32's state (monitor_fat.nasm), from FAT_RAM up to below the I/O page
FAT_RAM         .EQU    0xFFFFF980
V_MOUNTED       .EQU    0xFFFFF980      ; not 0 while a card is mounted, in the slot V_SLOT
V_EVER          .EQU    0xFFFFF981      ; not 0 once a mount was tried since the cold start
V_SLOT          .EQU    0xFFFFF982
V_FAT           .EQU    0xFFFFF983      ; the first sector of the first FAT,
V_DATA          .EQU    0xFFFFF984      ; the first sector of cluster 2,
V_BYTES         .EQU    0xFFFFF985      ; the bytes of a cluster, 512 << V_LOG,
V_LOG           .EQU    0xFFFFF986      ; log2 of the sectors of a cluster,
V_ROOT          .EQU    0xFFFFF987      ; the first cluster of the root directory,
V_DIR           .EQU    0xFFFFF988      ; and of the folder FOLDER,
V_TOP           .EQU    0xFFFFF989      ; the cluster after the last,
V_NFATS         .EQU    0xFFFFF98A      ; the copies of the FAT,
V_FATSZ         .EQU    0xFFFFF98B      ; and the sectors of each,
V_END           .EQU    0xFFFFF98C      ; the sector after the partition,
V_FSINFO        .EQU    0xFFFFF98D      ; the sector of FSInfo, 0 for none,
V_HINT          .EQU    0xFFFFF98E      ; the cluster to search for a free one from, 0 for FSInfo's,
V_UNKNOWN       .EQU    0xFFFFF98F      ; not 0 once FSInfo's free count is unknown since the mount,
V_CHANGED       .EQU    0xFFFFF990      ; and once the FAT changed since FSInfo was written
V_FATLBA        .EQU    0xFFFFF991      ; the sector in FATBUF, ~0 for none
V_FSP           .EQU    0xFFFFF992      ; SP in a file entry, where an error goes back to
V_LASCII        .EQU    0xFFFFF993      ; 0 when LNAME has a ? for a character outside ASCII
V_WLEN          .EQU    0xFFFFF994      ; the characters in WANT
V_BYLONG        .EQU    0xFFFFF995      ; not 0 when find matches long names too
V_N             .EQU    0xFFFFF996      ; an 8.3 name, 3 words, as an entry's first, 0 for none,
V_LOWER         .EQU    0xFFFFF999      ; the lower-case flags of its byte 12,
V_NL            .EQU    0xFFFFF99A      ; and the long-name entries of a new one
FATBUF          .EQU    0xFFFFF9B0      ; a sector of the FAT, 128 words
SEC             .EQU    0xFFFFFA30      ; a sector for FSInfo, an entry, or zeros, and TAB's and LOAD's line, 256 words
LNAME           .EQU    0xFFFFFB30      ; the name of the entry found last, a character a word, up to a 0, 256 words
WANT            .EQU    0xFFFFFC30      ; the name sought, a character a word, 256 words
DIRF            .EQU    0xFFFFFD30      ; the folder that lookups and TAB read, F_WORDS words,
FILE0           .EQU    0xFFFFFDBB      ; and the files of handles 0 and 1, to 0xFFFFFED0
FILE1           .EQU    0xFFFFFE46
V_T             .EQU    0xFFFFFEE0      ; 24 words for TAB, to 0xFFFFFEF7

VARS_WORDS      .EQU    0x1000          ; the words from 0xFFFFF000, the variables, which end a program's RAM
COLOR           .EQU    MON_FG_WHITE+MON_BG_BLACK  ; the color at the cold start
OUT_LINE        .EQU    1
OUT_SCREEN      .EQU    2
TABLE_VERSION   .EQU    0x00010006      ; what mon_version returns: 1.6
PAGE            .EQU    24              ; the rows of a Page Up or Page Down
SCR_MAX         .EQU    0x7FFF          ; the largest display offset

; The dispatch table (README.md, "The dispatch table"). Entries are only
; ever added at the end. The comment of each entry is its number, its
; address, its name in mon.nasm and mon.h where that differs from its
; label, and the file of the routine. mon.nasm is joined to the monitor
; too, for monlib.nasm, so the labels of the routines have no _ in front
; of them, such as udp_open, as the names of its stubs, such as
; _udp_open, would clash with them.
                JMP     mon_reset       ; 0 at 0x00, monitor.nasm
                JMP     mon_exit        ; 1 at 0x02, monitor.nasm
                JMP     mon_version     ; 2 at 0x04, monitor.nasm
                JMP     mon_putc        ; 3 at 0x06, monitor.nasm
                JMP     mon_out         ; 4 at 0x08, monitor.nasm
                JMP     scr_cls         ; 5 at 0x0A, monitor.nasm
                JMP     scr_moveto      ; 6 at 0x0C, monitor.nasm
                JMP     scr_getxy       ; 7 at 0x0E, monitor.nasm
                JMP     scr_color       ; 8 at 0x10, monitor.nasm
                JMP     fs_mount        ; 9 at 0x12, monitor_fat.nasm
                JMP     fs_open         ; 10 at 0x14, monitor_fat.nasm
                JMP     fs_read         ; 11 at 0x16, monitor_fat.nasm
                JMP     fs_readdir      ; 12 at 0x18, monitor_fat.nasm
                JMP     fs_close        ; 13 at 0x1A, monitor_fat.nasm
                JMP     fs_write        ; 14 at 0x1C, monitor_fat.nasm
                JMP     fs_delete       ; 15 at 0x1E, monitor_fat.nasm
                JMP     udp_open        ; 16 at 0x20, monitor_eth.nasm
                JMP     udp_send        ; 17 at 0x22, monitor_eth.nasm
                JMP     udp_recv        ; 18 at 0x24, monitor_eth.nasm
                JMP     udp_close       ; 19 at 0x26, monitor_eth.nasm
                JMP     fs_readname     ; 20 at 0x28, monitor_fat.nasm
                JMP     net_config      ; 21 at 0x2A, monitor_eth.nasm
                JMP     net_set         ; 22 at 0x2C, monitor_eth.nasm
                JMP     net_dhcp        ; 23 at 0x2E, monitor_eth.nasm
                JMP     net_poll        ; 24 at 0x30, monitor_eth.nasm
                JMP     dns_lookup      ; 25 at 0x32, monitor_eth.nasm
                JMP     tcp_open        ; 26 at 0x34, monitor_tcp.nasm
                JMP     tcp_state       ; 27 at 0x36, monitor_tcp.nasm
                JMP     tcp_send        ; 28 at 0x38, monitor_tcp.nasm
                JMP     tcp_recv        ; 29 at 0x3A, monitor_tcp.nasm
                JMP     tcp_close       ; 30 at 0x3C, monitor_tcp.nasm
                JMP     tcp_listen      ; 31 at 0x3E, monitor_tcp.nasm
                JMP     con_getline     ; 32 at 0x40, monitor.nasm
                JMP     bin_line        ; 33 at 0x42, monitor.nasm
                JMP     clock_set       ; 34 at 0x44, monitor_clock.nasm
                JMP     net_servers     ; 35 at 0x46, monitor_eth.nasm
                JMP     mon_restore     ; 36 at 0x48, monitor.nasm

; mon_reset: the cold start, entry 0, which reset runs and a program may
; call. E is cleared, the timer stopped, the FPU's stack emptied and its
; flags cleared (issue #141), VBASE set to 0, the font base and the mode
; word set to 0, so that the screen shows text in Spleen, and the port
; for Ethernet frames disabled, as at a return, after a RST for each TCP
; connection that a program left open, the mask, the gateway, the DNS
; server, the DHCP server, and the NTP server set to none, the DHCP
; lease forgotten, and the ARP cache emptied. The identification of the
; IPv4 packets starts from the fine clock, net_clock, and the local
; ports of TCP from the microseconds, with no connection opened. Without
; an IP address, the DHCP exchange in the background starts, with
; bg_start (issue #126). FAT32's state is cleared, with fat_reset, so
; that no card is mounted and no file open. The clock of the time of
; day, while it is not set, is set from the MEGA65's real-time clock,
; with clock_rtc (issue #105). The RAM from 0x8000 is left alone, so
; that a program a host has loaded is still there.
mon_reset
                CLR     R14             ; E = 0, VBASE = 0; bit 24 stays 1
                CLR     @TIMER
                MOVE    @FPU_CMD, 0x0101  ; CLEAR 1, as a reset of the core does
                CLR     @SCR_FONT
                CLR     @SCR_MODE       ; the text, not the chunky mode
                MOVE    SP, STACK
                CALL    net_close
                CLR     @V_MASK
                CLR     @V_GW
                CLR     @V_DNS
                CLR     @V_NTP
                CLR     @V_DSRV
                CLR     @V_LEASE
                CALL    net_clock
                MOVE    @V_IPID, R1
                CALL    bg_start
                AND     R1, @io.us, 0x3FFF
                OR      @V_TCPORT, R1, 0xC000
                CLR     @V_TCOPENS
                CALL    fat_reset
                MOVE    R1, V_ARP
:
                CLR     @R1++
                CMP     R1, V_ARP+4*ARP_SLOTS+1  ; and V_ARPNEXT
        ?!Z     JMP     :-
                MOVE    @V_COLOR, COLOR
                MOVE    @V_OUT, OUT_LINE+OUT_SCREEN
; The size of the screen's memory, from the bits of the display offset
; that it keeps, with the offset off, and the rows of history that fit
; after the 25 of the screen. The math unit divides (nice_cpu's DEVICES.md
; §2).
                CLR     @SCR_CTL
                MOVE    @SCR_OFFS, 0xFFFFFFFF
                AND     R1, @SCR_OFFS, SCR_MAX
                ADD     R1, R1, 1
                MOVE    @V_HSIZE, R1
                SUB[M]  R1, R1, 2000
        ?C      CLR     R1
                MOVE    @io.mpu_a, R1
                MOVE    @io.mpu_b, 80
                MOVE    @V_HCAP, @io.mpu_udivq
                CLR     @V_HHEAD
                CLR     @V_HCOUNT
                CLR     @V_BACK
                CALL    scr_cls
                CALL    clock_rtc
                JMP     bas_start       ; basic.nasm

; mon_exit: entry 1, and where a program returns to. Back to BASIC's
; warm start, bas_warm, with R1 the status, which it prints: E cleared, the timer stopped, the FPU's
; stack empty and its flags clear, VBASE 0, the font base and the mode
; word 0, the network
; closed, net_close, the cursor shown and blinking with the display
; offset off, a fresh stack, and the status printed where the program left
; the cursor's registers, after a new line if that is not column 0.
mon_exit
                MOVE    SP, STACK
                PUSH    R1
                CALL    mon_restore
                POP     R1
                JMP     bas_warm        ; basic.nasm

; mon_restore: entry 36, the state after a program, for a caller that
; ran one, as SYS does: E cleared, the timer stopped, the FPU's stack
; empty and its flags clear, VBASE 0, the font base and the mode word 0,
; the network closed, net_close, and the cursor shown and blinking with
; the display offset off, where the program left the cursor's registers.
; The cursor is taken from its registers, SCR_X and SCR_Y, as a program
; may have moved it there and not through scr_moveto, such as the demo,
; which clears the screen and leaves the cursor at the top left. A column
; past 79 is 79, and a row past 24 is 24. R1 = 0. Uses R1-R6.
mon_restore
                CLR     R14             ; E = 0, VBASE = 0; bit 24 stays 1
                CLR     @TIMER
                MOVE    @FPU_CMD, 0x0101  ; CLEAR 1: no values or flags for the next program
                CLR     @SCR_FONT       ; Spleen, whatever the program chose
                CLR     @SCR_MODE       ; the text, whatever the program chose
                CALL    net_close       ; no frames, if the program took them
                MOVE    @SCR_CTL, 0x60  ; the cursor, which a program may hide
                MOVE    R1, @SCR_X
                CMP     R1, 80
        ?!C     MOVE    R1, 79
                MOVE    @V_COL, R1
                MOVE    R1, @SCR_Y
                CMP     R1, 25
        ?!C     MOVE    R1, 24
                MOVE    @V_ROW, R1
                CLR     R1
                RET

; mon_version: entry 2. R1 = the version of the table, the major number in
; bits 31..16 and the minor in 15..0.
mon_version
                MOVE    R1, TABLE_VERSION
                RET

; mon_putc: entry 3. R1 a character, bits 7..0, to the outputs of V_OUT:
; the line as it is, and the screen as the header says. Uses R1-R4.
mon_putc
                AND     R1, R1, 0xFF
                AND[M]  R0, @V_OUT, OUT_LINE
        ?!Z     MOVE    @CONSOLE, R1
                AND[M]  R0, @V_OUT, OUT_SCREEN
        ?Z      RET
                CMP     R1, 0x20
        ?C      JMP     putc_ctl        ; a control code
                CMP     R1, 0x7F
        ?C      JMP     :+              ; 0x20 to 0x7E
        ?Z      RET                     ; 0x7F: nothing
; The character at the cursor, SCREEN + 80 * row + column, and the cursor
; moved on
:
                MOVE    R2, @V_ROW
                SHL     R3, R2, 6
                SHL     R2, R2, 4
                ADD     R2, R2, R3
                ADD     R2, R2, @V_COL
                OR      @SCREEN[R2], R1, @V_COLOR
                ADD     R1, @V_COL, 1
                CMP     R1, 80
        ?!Z     MOVE    @V_COL, R1
        ?!Z     JMP     putc_cur
; Column 0 of the next row, with the rows moved up by one after the last
putc_lf         CLR     @V_COL
                ADD     R1, @V_ROW, 1
                CMP     R1, 25
        ?!Z     MOVE    @V_ROW, R1
        ?!Z     JMP     putc_cur
; Row 0 into the history, at slot V_HHEAD, which moves down the ring, when
; the memory has room for one
                TST     @V_HCAP
        ?Z      JMP     putc_scroll
                ADD     R2, @V_HHEAD, 1
                SHL     R3, R2, 6
                SHL     R2, R2, 4
                ADD     R2, R2, R3      ; 80 * (V_HHEAD + 1)
                SUB     R2, @V_HSIZE, R2
                ADD     R2, R2, SCREEN
                MOVE    R3, SCREEN
                MOVE    R4, 80
:
                MOVE    @R2++, @R3++
                SUB[M]  R4, R4, 1
        ?!Z     JMP     :-
                SUB[M]  R1, @V_HHEAD, 1
        ?C      SUB     R1, @V_HCAP, 1  ; from slot 0 to the last
                MOVE    @V_HHEAD, R1
                ADD     R1, @V_HCOUNT, 1
                CMP     @V_HCAP, R1
        ?!C     MOVE    @V_HCOUNT, R1
putc_scroll
                MOVE    R2, SCREEN
                MOVE    R3, SCREEN+80
                MOVE    R4, 1920        ; rows 1 to 24 to rows 0 to 23
:               MOVE    @R2++, @R3++
                SUB[M]  R4, R4, 1
        ?!Z     JMP     :-
                OR      R3, @V_COLOR, 0x20
                MOVE    R4, 80          ; row 24 blank
:
                MOVE    @R2++, R3
                SUB[M]  R4, R4, 1
        ?!Z     JMP     :-
; The cursor's registers from the variables
putc_cur
                MOVE    @SCR_X, @V_COL
                MOVE    @SCR_Y, @V_ROW
                RET
putc_ctl
                CMP     R1, 0x0D
        ?Z      CLR     @V_COL
        ?Z      JMP     putc_cur
                CMP     R1, 0x0A
        ?Z      JMP     putc_lf
                CMP     R1, 0x08
        ?Z      JMP     :+
                CMP     R1, 0x09
        ?!Z     RET                     ; another control code: nothing
                OR      R1, @V_COL, 7   ; TAB: the next multiple of 8
                ADD     R1, R1, 1
                CMP     R1, 80
        ?!C     JMP     putc_lf         ; past the last column
                MOVE    @V_COL, R1
                JMP     putc_cur
:               MOVE[M] R1, @V_COL
        ?!Z     SUB     @V_COL, R1, 1
                JMP     putc_cur

; mon_out: entry 4. R1 the outputs of mon_putc, bit 0 the line and bit 1
; the screen. R1 = the old ones. Uses R2.
mon_out         MOVE    R2, @V_OUT
                AND     @V_OUT, R1, OUT_LINE+OUT_SCREEN
                MOVE    R1, R2
                RET

; scr_cls: entry 5. The screen blank in the current color, the cursor at
; the top left, shown and blinking, and the display offset 0. Uses R1 and
; R3.
scr_cls         CLR     @SCR_OFFS
                MOVE    @SCR_CTL, 0x60
                OR      R3, @V_COLOR, 0x20
                MOVE    R1, 2000
:
                DEC[M]  R1, R1
                MOVE    @SCREEN[R1], R3
        ?!Z     JMP     :-
                CLR     @V_COL
                CLR     @V_ROW
                JMP     putc_cur

; scr_moveto: entry 6. The cursor to column R1 and row R2. A column past
; 79 is 79, and a row past 24 is 24.
scr_moveto
                CMP     R1, 80
        ?!C     MOVE    R1, 79
                CMP     R2, 25
        ?!C     MOVE    R2, 24
                MOVE    @V_COL, R1
                MOVE    @V_ROW, R2
                JMP     putc_cur

; scr_getxy: entry 7. R1 = the cursor's column, R2 = its row.
scr_getxy
                MOVE    R1, @V_COL
                MOVE    R2, @V_ROW
                RET

; scr_color: entry 8. R1 the color of the characters put from now on, bits
; 31..8 of a screen word. R1 = the old one. Uses R2.
scr_color
                MOVE    R2, @V_COLOR
                AND     @V_COLOR, R1, 0xFFFFFF00
                MOVE    R1, R2
                RET

; getline: a line into the buffer at R1, of up to R2 characters, as
; _io_gets reads it, with the keys of the history before it: up, ESC [ A,
; and down, ESC [ B, a row, and Page Up, ESC [ 5 ~, and Page Down, ESC [ 6
; ~, a page. The other escape sequences are dropped, as _io_gets drops
; them, and any key but those four shows the screen again.
; The first key of the line goes on to _io_gets.first. _io_getc.soon uses
; only R1 and R2, so R3 keeps the first byte of a sequence's parameter.
; While it waits for the first key, getline_wait keeps the network going.
; TAB completes a file's name with complete (issue #137). It is entry 32,
; con_getline, the line that BASIC reads, with R1 the buffer, of R2 + 1
; words, which may be in the word window, as net_waddr takes it, for C,
; and R1 = the number of characters, as _io_gets returns it.
con_getline
                PUSH    R2
                CALL    net_waddr
                POP     R2
getline
                PUSH    R1
                PUSH    R2
getline_key
                CALL    getline_wait
                CMP     R1, 0x1B
        ?!Z     JMP     getline_line
                CALL    _io_getc.soon
        ?Z      JMP     getline_drop    ; an ESC alone
                CMP     R1, 0x4F        ; O: one more byte
        ?Z      JMP     getline_ss3
                CMP     R1, 0x5B        ; [
        ?!Z     JMP     getline_line    ; another byte, on its own
                CALL    _io_getc.soon
        ?Z      JMP     getline_drop
                MOVE    R3, R1
                CMP     R1, 0x41        ; A
        ?Z      JMP     getline_row_up
                CMP     R1, 0x42        ; B
        ?Z      JMP     getline_row_down
                CMP     R1, 0x40
        ?!C     JMP     getline_drop    ; another final byte, such as C
                CALL    _io_getc.soon
        ?Z      JMP     getline_drop
                CMP     R1, 0x7E        ; ~
        ?!Z     JMP     :+
                CMP     R3, 0x35        ; 5
        ?Z      JMP     getline_up
                CMP     R3, 0x36        ; 6
        ?Z      JMP     getline_down
                JMP     getline_drop
:
                CMP     R1, 0x40
        ?!C     JMP     getline_drop    ; the final byte
                CALL    _io_getc.soon
        ?Z      JMP     getline_drop
                JMP     :-
getline_ss3
                CALL    _io_getc.soon
getline_drop
                CALL    hist_leave
                JMP     getline_key
getline_row_up
                MOVE    R3, 1
                JMP     :+
getline_up
                MOVE    R3, PAGE
:
                CALL    hist_up
                JMP     getline_key
getline_row_down
                MOVE    R3, 1
                JMP     :+
getline_down
                MOVE    R3, PAGE
:
                CALL    hist_down
                JMP     getline_key
getline_line
                MOVE    R3, R1
                CALL    hist_leave
                CALL    net_off         ; the network of getline_wait
                POP     R2
                POP     R1
                MOVE    R4, complete    ; the routine of TAB
                JMP     _io_gets.first  ; which returns to the caller

; complete: TAB on the line, for _io_gets: R1 the line, R2 the cursor, R3
; the word after the last, and R1 = the new cursor, with fat_complete of
; monitor_fat.nasm (issue #137). When it lists the matches, the line is shown
; again. Uses R1-R6, and R7 and R8 across the calls, saved.
complete
                PUSH    R7
                PUSH    R8
                MOVE    R7, R1          ; the line
                MOVE    R8, R2          ; the cursor
                CALL    fat_complete
                TST     R1
        ?!Z     JMP     complete_end
:
                CMP     R7, R8
        ?Z      JMP     :+
                MOVE    R1, @R7++
                CALL    _mon_putc
                JMP     :-
:
                MOVE    R1, R8
complete_end
                POP     R8
                POP     R7
                RET

; getline_wait: R1 = the next byte of the console, which it waits for, as
; _io_getc does. While the DHCP exchange in the background runs, or a
; lease is kept, it enables the port for Ethernet frames, with net_on,
; and polls, so that the exchange goes on and the lease is renewed
; (issue #126); the port stays enabled until getline_line disables it.
; An address that the exchange gets is shown with bg_show. Uses R1-R6.
getline_wait
                MOVE    R1, @io.console
                AND[M]  R0, R1, 0x100
        ?!Z     AND     R1, R1, 0xFF
        ?!Z     RET
                TST     @V_BSTATE
        ?!Z     JMP     :+
                TST     @V_LEASE
        ?Z      JMP     getline_wait    ; nothing to keep going
:
                CALL    net_on
                TST     @V_BSTATE
        ?!Z     MOVE    @V_NWAIT, DHCP_CLIENT
                CALL    net_step
                CLR     @V_NWAIT
                CALL    bg_step
                TST     R1
        ?!Z     CALL    bg_show
                JMP     getline_wait

; hist_up: R3 rows further back, up to the rows kept. The first turns
; the ring and keeps SCR_CTL. Uses R1-R6.
hist_up
                TST     @V_HCOUNT
        ?Z      RET                     ; no history
                TST     @V_BACK
        ?!Z     JMP     :+
                MOVE    @V_CTL, @SCR_CTL
                PUSH    R3
                CALL    hist_turn
                POP     R3
:
                ADD     R1, @V_BACK, R3
                CMP     @V_HCOUNT, R1
        ?C      MOVE    R1, @V_HCOUNT
; R1 rows back: the offset V_HSIZE - 80 R1 on, and the cursor off
hist_show
                MOVE    @V_BACK, R1
                SHL     R2, R1, 6
                SHL     R1, R1, 4
                ADD     R1, R1, R2
                SUB     @SCR_OFFS, @V_HSIZE, R1
                MOVE    @SCR_CTL, 0x400
                RET

; hist_down: R3 rows forward, and the screen again at the end. Uses R1
; and R2.
hist_down
                MOVE[M] R1, @V_BACK
        ?Z      RET
                SUB[M]  R1, R1, R3
        ?C      JMP     hist_leave
        ?Z      JMP     hist_leave
                JMP     hist_show

; hist_leave: the screen again, if the history is shown, with its SCR_CTL.
; Uses no register.
hist_leave
                TST     @V_BACK
        ?Z      RET
                CLR     @V_BACK
                MOVE    @SCR_CTL, @V_CTL
                CLR     @SCR_OFFS
                RET

; hist_turn: the ring turned so that its newest row, at slot V_HHEAD + 1,
; is at slot 0, at the top of the memory, and the next goes to the last
; slot. The slots are V_HCAP rows of words from B, slot i at a lower
; address than slot i - 1, so this turns the words from B up by D = 80
; (V_HHEAD + 1), with three reversals: all of them, the first D, and the
; rest. R4 is B, R5 is D, and R6 the words of the ring. Uses R1-R6.
hist_turn
                ADD     R1, @V_HHEAD, 1
                CMP     R1, @V_HCAP
        ?Z      CLR     R1
                SUB     @V_HHEAD, @V_HCAP, 1
                SHL     R2, R1, 6
                SHL     R5, R1, 4
                ADD[M]  R5, R5, R2
        ?Z      RET                     ; turned already
                MOVE    R6, @V_HCAP
                SHL     R2, R6, 6
                SHL     R6, R6, 4
                ADD     R6, R6, R2
                ADD     R4, @V_HSIZE, SCREEN
                SUB     R4, R4, R6
                MOVE    R1, R4
                ADD     R2, R4, R6
                CALL    hist_rev
                MOVE    R1, R4
                ADD     R2, R4, R5
                CALL    hist_rev
                ADD     R1, R4, R5
                ADD     R2, R4, R6
; hist_rev: the words from R1 up to R2, which is after the last, in the
; reverse order. Uses R1-R3.
hist_rev
                SUB     R2, R2, 1       ; the last word
:
                CMP     R1, R2
        ?!C     RET                     ; the two have met
                MOVE    R3, @R1
                MOVE    @R1++, @R2
                MOVE    @R2, R3
                SUB     R2, R2, 1
                JMP     :-

; bin_line: entry 33, a line of a .bin file (nice_cpu's ISA.md §10.4):
; R1 the line, one character a word up to a 0 word, and R2 the word
; address of its counts, 7 words that the caller clears before the first
; line of a load; each may be in the word window, as net_waddr takes it,
; for C. ADDR WORD, two hex numbers of 1 to 8 digits with blanks
; between them and around them, writes WORD at ADDR, when ADDR is in a
; program's RAM, from PROGRAM up to the monitor's variables. The RAM of
; a board repeats every RAM_WORDS words, so an address past it could
; reach the ROM or the monitor's variables and stack, which are at
; RAM_WORDS - VARS_WORDS and up of the RAM, 0x1F000 on the MEGA65 and
; 0xF000 on the Nexys4DDR; where RAM_WORDS reads 0, as in niceemu, the
; RAM goes up to the screen. A line with anything else is skipped, and a
; line of blanks only is passed over. A second line for an address writes
; its word over the first's. The counts: 0 the words written, 1 and 2 the
; lowest and the highest address written, from the first word, 3 the
; lines skipped, 4 the number of the first, 5 the lines, this one with
; them, and 6 the end of a program's RAM, which it writes, after the last
; address that a line may have. R1 = 1 when the word was written, 0 for
; a line of blanks only, or -1 when the line was skipped. Uses R1-R6, and
; R7 and R8 across the calls, saved: the counts and the address.
bin_line
                PUSH    R7
                PUSH    R8
                PUSH    R1
                MOVE    R1, R2
                CALL    net_waddr
                MOVE    R7, R1
                POP     R1
                CALL    net_waddr
                MOVE[M] R2, @RAM_WORDS
        ?Z      MOVE    R2, SCREEN+VARS_WORDS  ; no limit
                SUB     @6[R7], R2, VARS_WORDS
                ADD     @5[R7], @5[R7], 1
                CALL    _io_gethex      ; R1 the address, R2 its digits, R3 after it
                TST     R2
        ?!Z     JMP     :+
                TST     @R3
        ?Z      JMP     bin_blank       ; blanks only
:
                SUB     R4, R2, 1
                CMP     R4, 8
        ?!C     JMP     bin_bad         ; no digit, or more than 8
                CMP     R1, PROGRAM
        ?C      JMP     bin_bad         ; in the ROM
                CMP     R1, @6[R7]
        ?!C     JMP     bin_bad         ; the variables, or past the RAM
                MOVE    R8, R1
                MOVE    R1, R3
                CALL    _io_gethex      ; R1 the word
                SUB     R4, R2, 1
                CMP     R4, 8
        ?!C     JMP     bin_bad
:
                CMP     @R3, 0x20
        ?Z      ADD     R3, R3, 1
        ?Z      JMP     :-
                TST     @R3
        ?!Z     JMP     bin_bad         ; more after the word
                MOVE    @R8, R1
                MOVE[M] R1, @R7         ; the words written before
        ?Z      MOVE    @1[R7], R8      ; the first
        ?Z      MOVE    @2[R7], R8
                ADD     @R7, R1, 1
                CMP     R8, @1[R7]
        ?C      MOVE    @1[R7], R8      ; a lower address
                CMP     @2[R7], R8
        ?C      MOVE    @2[R7], R8      ; a higher one
                ONE     R1
                JMP     bin_end
bin_bad
                TST     @3[R7]
        ?Z      MOVE    @4[R7], @5[R7]
                ADD     @3[R7], @3[R7], 1
                NOT     R1, R0          ; -1
                JMP     bin_end
bin_blank
                CLR     R1
bin_end
                POP     R8
                POP     R7
                RET
