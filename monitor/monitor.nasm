; The monitor, the program of the ROM at 0x0000 (README.md). The core boots
; from it at reset. It gives the programs at 0x8000 a hardware abstraction
; layer, the HAL: thirty routines, called through the dispatch table at the
; start of the ROM, and it has a main loop with a few commands, typed on
; the keyboard or sent over the line, and shown on the screen and the line.
;
; The dispatch table has one JMP routine per entry, two words, so that
; entry n is at address 2n, and entry 0 is the reset. The routines follow
; the C ABI of nice_cpu/runtime/ABI.md: the arguments in R1-R4, the result
; in R1, R1-R6 changed, and R7-R13 kept. mon.nasm has the address of each
; entry as an .EQU, and a stub that jumps to it.
;
; The cold start, mon_reset, sets SP to STACK, the variables, and the
; screen, and goes to cmd_start, which prints the banner and runs the main
; loop, main, of monitor_cmd.nasm. At a program's return, and at
; mon_exit, the monitor clears E, stops the timer, sets VBASE to 0, shows
; the cursor, blinking, takes a fresh stack, prints the status, R1, and
; goes back to main.
;
; The monitor is this file and five more, which the Makefile joins after
; it, in this order, so that the dispatch table is at 0:
;
; - monitor_cmd.nasm: the main loop and its commands, and the routines and
;   texts that only they use, which the BASIC interpreter of issue #54 is
;   to replace.
; - monitor_dis.nasm: u, the disassembler (README.md, "The
;   disassembler").
; - monitor_sd.nasm: the SD cards below the file system, the sector
;   routines sd_init, sd_read, and sd_write that fat32.c reads and writes
;   through (issue #57, doc/SDCARD.md).
; - monitor_eth.nasm: the network, the frame routines, the ARP cache, the
;   demultiplexing of the frames and net_poll, the UDP entries 16 to 19,
;   the entries 21 to 25 of the IP settings, DHCP, the poll, and DNS, i
;   dhcp, and tftp (issues #83, #84, and #111, README.md, "The network",
;   and INTERNALS.md, "The frame routines").
; - monitor_tcp.nasm: TCP, the entries 26 to 31 of its clients and its
;   servers, and their part of the poll (issue #111).
;
; Each has the .EQUs of its devices and its constants, and its texts, but
; the variables of all six are here, as one map of the RAM. The commands
; in the other files jump back to main, and the assembler takes a name
; before its .EQU or its label, so the files reach each other's names in
; either direction.
;
; mon_putc writes a character to the outputs that V_OUT selects. On the
; line, the console at 0xFFFFFF00, every byte goes as it is. On the screen
; a character goes at the cursor, which moves on; CR moves the cursor to
; column 0, LF to column 0 of the next row, BS one column back, and TAB to
; the next multiple of 8; the other control codes and 0x7F do nothing.
; 0x80 to 0x9F go on the screen as any character: they are blank in Spleen,
; and show what a program draws for them in the font RAM (nice_cpu's
; SYSTEM.md §1.8). Past the last column the cursor goes to the next row, and past
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
; of history, 77 on the Nexys4DDR. At the prompt, before a line is typed,
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
; The ROM's C code, the files of the Makefile's ROM_C, fat32.c for now,
; is one wasm module, which nicewasm --ram translates for a ROM and the
; Makefile joins after mon.nasm, with nice_cpu's lib.nasm and
; muldiv_mpu.nasm (INTERNALS.md, "C in the ROM"). The words that it writes,
; its mutable globals and its memory, with its stack, are in the RAM
; from WASM_RAM up to below WASM_END, which the Makefile checks against
; ___wasm_ram_end; ___wasm_start copies their initial values there at
; every cold start. The two vectors that lib.nasm jumps through are words
; of the variables, which the cold start sets: ___putc_vector to
; mon_putc, and ___wasm_trap_vector to mon_trap, which prints the trap
; and goes back to the main loop as mon_exit does, so that a trap of the
; C code, or of a program's, does not halt the core.
;
; The routines that the commands share with programs, _io_puts, _io_crlf,
; _io_puthex, _io_putdec, _io_gethex, _io_gets, and _io_getc, are in
; monlib.nasm, which the Makefile joins after the monitor's files, with
; mon.nasm and build/version.nasm, which defines VERSION, the string of
; the banner.

SP              .EQU    R13
PC              .EQU    R15

CONSOLE         .EQU    0xFFFFFF00      ; a write: a byte to the line
SCREEN          .EQU    0xFFFF0000      ; 80 x 25 words, the character in bits 7..0
SCR_CTL         .EQU    0xFFFFFF80      ; bit 6 shows the cursor, bit 5 blinks it
SCR_X           .EQU    0xFFFFFF81      ; the cursor's column
SCR_Y           .EQU    0xFFFFFF82      ; the cursor's row
SCR_OFFS        .EQU    0xFFFFFF85      ; the display offset, in words
SCR_FONT        .EQU    0xFFFFFF86      ; the font base: 0 shows Spleen
TIMER           .EQU    0xFFFFFF10      ; the timer's period, 0 to stop it
E_IP            .EQU    0xFFFFFFB0      ; the network station's IP address, NET_IP, the first byte in bits 31..24
E_MACH          .EQU    0xFFFFFFB1      ; the first two bytes of its MAC address, in bits 15..0
E_MACL          .EQU    0xFFFFFFB2      ; the last four bytes of its MAC address

STACK           .EQU    0xFFFFF000      ; SP at the cold start, above the program's RAM
V_COL           .EQU    0xFFFFF000      ; the cursor's column, 0 to 79
V_ROW           .EQU    0xFFFFF001      ; and its row, 0 to 24
V_COLOR         .EQU    0xFFFFF002      ; the color of the characters put, bits 31..8
V_OUT           .EQU    0xFFFFF003      ; the outputs: bit 0 the line, bit 1 the screen
V_NEXT          .EQU    0xFFFFF004      ; the address that the next d goes on at
V_HSIZE         .EQU    0xFFFFF005      ; the words of the screen's memory
V_HCAP          .EQU    0xFFFFF006      ; the rows of the history, after the 25 of the screen
V_HHEAD         .EQU    0xFFFFF007      ; the slot of the next row, slot i at SCREEN + V_HSIZE - 80 (i + 1)
V_HCOUNT        .EQU    0xFFFFF008      ; the rows kept, up to V_HCAP
V_BACK          .EQU    0xFFFFF009      ; the rows shown back, 0 for the screen
V_CTL           .EQU    0xFFFFF00A      ; SCR_CTL while the history is shown
V_LOUT          .EQU    0xFFFFF00B      ; V_OUT while l reads its lines
V_LEND          .EQU    0xFFFFF00C      ; the last byte that l read, for the LF of a CR LF
V_LBAD          .EQU    0xFFFFF00D      ; the number of the first line that l skipped
V_PEND          .EQU    0xFFFFF00E      ; for l: after a program's RAM, at the variables
V_UNEXT         .EQU    0xFFFFF00F      ; the address that the next u goes on at
V_LINE          .EQU    0xFFFFF010      ; the command line, LINE_MAX words, one over for l, and a 0
LINE_MAX        .EQU    76              ; so that the prompt and the line fit a row
V_UF            .EQU    0xFFFFF060      ; for u: the fields dest, s0, and s1,
V_UC            .EQU    0xFFFFF063      ; their constant words,
V_UNOPS         .EQU    0xFFFFF066      ; and the operands of the mnemonic
V_ARP           .EQU    0xFFFFF100      ; the ARP cache: ARP_SLOTS entries of an IP address, 0 for none, the MAC address as E_MACH and E_MACL have it, and the time of arp_tick it was learned
V_ARPNEXT       .EQU    0xFFFFF110      ; the entry that arp_learn takes next, 4 times its number
V_XID           .EQU    0xFFFFF111      ; for i dhcp: the transaction's number,
V_DIP           .EQU    0xFFFFF112      ; and the address of the OFFER or the ACK, its server, mask, and gateway,
V_DSRV          .EQU    0xFFFFF113
V_DMASK         .EQU    0xFFFFF114
V_DGW           .EQU    0xFFFFF115
V_PIP           .EQU    0xFFFFF116      ; and those of the last reply that dhcp_parse took
V_PSRV          .EQU    0xFFFFF117
V_PMASK         .EQU    0xFFFFF118
V_PGW           .EQU    0xFFFFF119
V_LSTATS        .EQU    0xFFFFF11A      ; for load NAME: what fat_load gives, 5 words
V_TXF           .EQU    0xFFFFF120      ; a frame to send, from byte 2, DHCP_WORDS words, as the send buffer has it
V_RXF           .EQU    0xFFFFF180      ; a frame received, from byte 2, 380 words, as the queue's buffer has it
___wasm_trap_vector .EQU 0xFFFFF300     ; the routine that a wasm trap jumps to, mon_trap (lib.nasm)
___putc_vector  .EQU    0xFFFFF301      ; the routine that nice_putc and nice_print jump to, mon_putc
V_MASK          .EQU    0xFFFFF302      ; the network's mask, from i dhcp, 0 for none
V_GW            .EQU    0xFFFFF303      ; and its gateway, 0 for none
V_UPORT         .EQU    0xFFFFF304      ; the local port of the UDP endpoint, 0 while it is closed
V_UHDR          .EQU    0xFFFFF305      ; for udp_send: the headers, UDP_HDR words, as the send buffer has them
V_TSRV          .EQU    0xFFFFF310      ; for tftp: the server's IP address,
V_TTID          .EQU    0xFFFFF311      ; its port, its TID, 0 before its first DATA,
V_TBLK          .EQU    0xFFFFF312      ; the block waited for,
V_TLEN          .EQU    0xFFFFF313      ; the bytes of the packet at V_TPKT,
V_TTIME         .EQU    0xFFFFF314      ; the microseconds when it was sent,
V_TLAST         .EQU    0xFFFFF315      ; the byte before, for the LF of a CR LF,
V_TLINE         .EQU    0xFFFFF316      ; the next free word of V_LINE,
V_TEND          .EQU    0xFFFFF317      ; the bytes of the DATA's block,
V_TPORT         .EQU    0xFFFFF318      ; the server's port for the RRQ,
V_TLIST         .EQU    0xFFFFF319      ; not 0 for a listing, a name with * or ?,
V_TPKT          .EQU    0xFFFFF320      ; and the packet sent, a byte per word, up to TFTP_PKT
V_DNS           .EQU    0xFFFFF380      ; the DNS server, from i dhcp or net_set, 0 for none
V_ULEN          .EQU    0xFFFFF381      ; the bytes of the datagram held for the endpoint at V_RXF, 0 for none
V_NWAIT         .EQU    0xFFFFF382      ; the local UDP port of the ROM's own wait, whose frames net_step copies to V_RXF, 0 for none
V_NARM          .EQU    0xFFFFF383      ; not 0 while the nearest deadline, V_NDUE, is armed
V_NDUE          .EQU    0xFFFFF384      ; the nearest deadline, on the fine clock of net_clock
V_IPID          .EQU    0xFFFFF385      ; the identification of the next IPv4 packet sent, in bits 15..0
V_DDNS          .EQU    0xFFFFF386      ; for i dhcp: the DNS server of the OFFER or the ACK,
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
WASM_RAM        .EQU    0xFFFFF400      ; the words that the ROM's C code writes, from here
WASM_END        .EQU    0xFFFFFF00      ; up to below here, the I/O page, which the Makefile checks

PROGRAM         .EQU    0x8000          ; where a program is, above the ROM
VARS_WORDS      .EQU    0x1000          ; the words from 0xFFFFF000, the variables, which end a program's RAM
COLOR           .EQU    0x000FFF00      ; white on black, the color at the cold start
OUT_LINE        .EQU    1
OUT_SCREEN      .EQU    2
TABLE_VERSION   .EQU    0x00010005      ; what mon_version returns: 1.5
PAGE            .EQU    24              ; the rows of a Page Up or Page Down
SCR_MAX         .EQU    0x7FFF          ; the largest display offset

; The dispatch table (README.md, "The dispatch table"). Entries are only
; ever added at the end. The comment of each entry is its number, its
; address, its name in mon.nasm and mon.h where that differs from its
; label, and the file of the routine. The entries 9 to 15 and 20 jump to
; the C functions fat_mount to fat_readname of fat32.c, which are
; _fat_mount to _fat_readname here, and not fs_mount to fs_readname:
; mon.nasm is joined to the monitor too, for monlib.nasm, and its stubs
; _fs_mount to _fs_readname would clash with them. The routines in
; assembly have no such clash, as their labels, such as udp_open, have no
; _ in front of them.
                JMP     mon_reset       ; 0 at 0x00, monitor.nasm
                JMP     mon_exit        ; 1 at 0x02, monitor.nasm
                JMP     mon_version     ; 2 at 0x04, monitor.nasm
                JMP     mon_putc        ; 3 at 0x06, monitor.nasm
                JMP     mon_out         ; 4 at 0x08, monitor.nasm
                JMP     scr_cls         ; 5 at 0x0A, monitor.nasm
                JMP     scr_moveto      ; 6 at 0x0C, monitor.nasm
                JMP     scr_getxy       ; 7 at 0x0E, monitor.nasm
                JMP     scr_color       ; 8 at 0x10, monitor.nasm
                JMP     _fat_mount      ; 9 at 0x12, fs_mount, fat32.c
                JMP     _fat_open       ; 10 at 0x14, fs_open, fat32.c
                JMP     _fat_read       ; 11 at 0x16, fs_read, fat32.c
                JMP     _fat_readdir    ; 12 at 0x18, fs_readdir, fat32.c
                JMP     _fat_close      ; 13 at 0x1A, fs_close, fat32.c
                JMP     _fat_write      ; 14 at 0x1C, fs_write, fat32.c
                JMP     _fat_delete     ; 15 at 0x1E, fs_delete, fat32.c
                JMP     udp_open        ; 16 at 0x20, monitor_eth.nasm
                JMP     udp_send        ; 17 at 0x22, monitor_eth.nasm
                JMP     udp_recv        ; 18 at 0x24, monitor_eth.nasm
                JMP     udp_close       ; 19 at 0x26, monitor_eth.nasm
                JMP     _fat_readname   ; 20 at 0x28, fs_readname, fat32.c
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

; mon_reset: the cold start, entry 0, which reset runs and a program may
; call. E is cleared, the timer stopped, VBASE set to 0, the font base
; set to 0, so that the screen shows Spleen, and the port for Ethernet
; frames disabled, as at a return, after a RST for each TCP connection
; that a program left open, the mask, the gateway, and the DNS server set
; to none, the DHCP lease forgotten, and the ARP cache emptied. The identification of the IPv4
; packets starts from the fine clock, net_clock, and the local ports of
; TCP from the microseconds, with no connection opened. The vectors
; of lib.nasm are set, and ___wasm_start gives the words of the ROM's C
; code their initial values. The clock of the time of day, while it is not
; set, is set from the MEGA65's real-time clock, with clock_rtc of clock.c
; (issue #105). The RAM from 0x8000 is left alone, so that a program a
; host has loaded is still there.
mon_reset
                MOVE    R14, 0          ; E = 0, VBASE = 0; bit 24 stays 1
                MOVE    @TIMER, 0
                MOVE    @SCR_FONT, 0
                MOVE    SP, STACK
                CALL    net_close
                MOVE    @V_MASK, 0
                MOVE    @V_GW, 0
                MOVE    @V_DNS, 0
                MOVE    @V_LEASE, 0
                CALL    net_clock
                MOVE    @V_IPID, R1
                AND     R1, @io.us, 0x3FFF
                OR      @V_TCPORT, R1, 0xC000
                MOVE    @V_TCOPENS, 0
                MOVE    @___wasm_trap_vector, mon_trap
                MOVE    @___putc_vector, mon_putc
                CALL    ___wasm_start
                MOVE    R1, V_ARP
:
                MOVE    @R1++, 0
                CMP     R1, V_ARP+4*ARP_SLOTS+1  ; and V_ARPNEXT
        ?!Z     JMP     :-
                MOVE    @V_COLOR, COLOR
                MOVE    @V_OUT, OUT_LINE+OUT_SCREEN
; The size of the screen's memory, from the bits of the display offset
; that it keeps, with the offset off, and the rows of history that fit
; after the 25 of the screen. The math unit divides (nice_cpu's SYSTEM.md
; §2).
                MOVE    @SCR_CTL, 0
                MOVE    @SCR_OFFS, 0xFFFFFFFF
                AND     R1, @SCR_OFFS, SCR_MAX
                ADD     R1, R1, 1
                MOVE    @V_HSIZE, R1
                SUB[M]  R1, R1, 2000
        ?C      MOVE    R1, 0
                MOVE    @io.mpu_a, R1
                MOVE    @io.mpu_b, 80
                MOVE    @V_HCAP, @io.mpu_udivq
                MOVE    @V_HHEAD, 0
                MOVE    @V_HCOUNT, 0
                MOVE    @V_BACK, 0
                CALL    scr_cls
                CALL    _clock_rtc
                JMP     cmd_start       ; monitor_cmd.nasm

; mon_exit: entry 1, and where a program returns to. Back to the main loop,
; main, with R1 the status: E cleared, the timer stopped, VBASE 0, the
; font base 0, the network closed, net_close, the cursor shown and
; blinking with the display offset off, a fresh stack, and the status
; printed where the program left the cursor's registers, after a new line
; if that is not column 0.
mon_exit
                MOVE    SP, STACK
                PUSH    R1
                CALL    exit_restore
                MOVE    R1, S_RETURN
                CALL    _io_puts
                POP     R1
                CALL    _io_puthex
                CALL    _io_crlf
                JMP     main

; mon_trap: where a wasm trap of the ROM's C code jumps through
; ___wasm_trap_vector, with R1 the trap's code and R2 its address
; (nice_cpu's WASM.md). Back to the main loop as from mon_exit, with
; "Trap N at ADDR" printed, the code in decimal and the address in hex.
mon_trap
                MOVE    SP, STACK
                MOVE    R7, R1          ; the code
                MOVE    R8, R2          ; the address
                CALL    exit_restore
                MOVE    R1, S_TRAP
                CALL    _io_puts
                MOVE    R1, R7
                CALL    _io_putdec
                MOVE    R1, S_AT
                CALL    _io_puts
                MOVE    R1, R8
                CALL    _io_puthex
                CALL    _io_crlf
                JMP     main

; exit_restore: for mon_exit and mon_trap, the state as the header of
; mon_exit says, but the stack, and a new line if the cursor is not in
; column 0. The cursor is taken from its registers, SCR_X and SCR_Y, as
; a program may have moved it there and not through scr_moveto, such as
; the demo, which clears the screen and leaves the cursor at the top
; left. A column past 79 is 79, and a row past 24 is 24. Uses R1.
exit_restore
                MOVE    R14, 0          ; E = 0, VBASE = 0; bit 24 stays 1
                MOVE    @TIMER, 0
                MOVE    @SCR_FONT, 0    ; Spleen, whatever the program chose
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
                TST     @V_COL
        ?!Z     JMP     _io_crlf        ; which returns to the caller
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
putc_lf         MOVE    @V_COL, 0
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
        ?Z      MOVE    @V_COL, 0
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
scr_cls         MOVE    @SCR_OFFS, 0
                MOVE    @SCR_CTL, 0x60
                OR      R3, @V_COLOR, 0x20
                MOVE    R1, 2000
:
                DEC[M]  R1, R1
                MOVE    @SCREEN[R1], R3
        ?!Z     JMP     :-
                MOVE    @V_COL, 0
                MOVE    @V_ROW, 0
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
getline
                PUSH    R1
                PUSH    R2
getline_key
                CALL    _io_getc
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
                POP     R2
                POP     R1
                JMP     _io_gets.first  ; which returns to the caller

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
                MOVE    @V_BACK, 0
                MOVE    @SCR_CTL, @V_CTL
                MOVE    @SCR_OFFS, 0
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
        ?Z      MOVE    R1, 0
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

; puts_crlf: the string at R1, and CR LF
puts_crlf
                CALL    _io_puts
                JMP     _io_crlf        ; which returns to the caller

S_RETURN
                .ASCII_L 'Returned '
S_TRAP          .ASCII_L 'Trap '
S_AT            .ASCII_L ' at '
S_UCOMMA
                .ASCII_L ', '
S_UGAP          .ASCII_L '  '
