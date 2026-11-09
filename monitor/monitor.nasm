; The monitor, the program of the ROM at 0x0000 (README.md). The core boots
; from it at reset. It gives the programs at 0x8000 a hardware abstraction
; layer, the HAL: twenty routines, called through the dispatch table at the
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
; screen, prints the banner, and runs the main loop. A command is a line:
; a letter, and after d and u a hex address and a hex count, and after r
; a hex address. l writes words into the RAM from lines of ADDR WORD in hex, as
; a .bin file has them, typed or pasted, up to an empty line, so that a
; program is loaded with no host's tools and no storage. Each line is
; shown in one row of the screen, which the next line clears, and not on
; the line, so that no line scrolls the screen and a paste at 2 Mbaud
; keeps up. r runs the program at its address, or at 0x8000, as a
; subroutine, with R1 = the entry of mon_putc, R2 = 0,
; R3 = 0, and E = 0 (ABI.md, "Programs under a monitor"). At its return,
; and at mon_exit, the monitor clears E, stops the timer, sets VBASE to 0,
; shows the cursor, blinking, takes a fresh stack, and prints the status, R1. x copies the demo from
; the ROM to 0x8000 and runs it as r does, for the time being (issue #65).
; dir lists the folder NICE of an SD card's FAT32 file system, load NAME
; reads a .bin file from it as l reads lines, save NAME ADDR N writes one,
; and del NAME deletes a file, with fat32.c, the ROM's C code, whose
; functions are also the entries 9 to 15, fs_mount, fs_open, fs_read,
; fs_readdir, fs_close, fs_write, and fs_delete (issues #58 and #59).
;
; The monitor is this file and three more, which the Makefile joins after
; it, in this order, so that the dispatch table is at 0:
;
; - monitor_dis.nasm: u, the disassembler (README.md, "The
;   disassembler").
; - monitor_sd.nasm: the SD cards below the file system, sd and the sector
;   routines sd_init, sd_read, and sd_write that fat32.c reads and writes
;   through (issue #57, doc/SDCARD.md).
; - monitor_eth.nasm: the network, the frame routines, the ARP cache, the
;   UDP entries 16 to 19, i dhcp, and tftp (issues #83 and #84, README.md,
;   "The network", and INTERNALS.md, "The frame routines").
;
; Each has the .EQUs of its devices and its constants, and its texts, but
; the variables of all four are here, as one map of the RAM. The commands
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
; Page Up and Page Down show the history through the display offset: k
; rows back is the offset 32768 - 80 k, which wraps to row 0 of the
; screen, so the first Page Up turns the ring so that its newest row is
; at the top of the memory. Any other key shows the screen again, and goes
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
RAM_WORDS       .EQU    0xFFFFFF9E      ; the words of the RAM, 0 in niceemu, where there is no limit

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
V_SECTOR        .EQU    0xFFFFF080      ; for sd: a sector, 128 words of 4 bytes, little-endian
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
WASM_RAM        .EQU    0xFFFFF400      ; the words that the ROM's C code writes, from here
WASM_END        .EQU    0xFFFFFF00      ; up to below here, the I/O page, which the Makefile checks

PROGRAM         .EQU    0x8000          ; where a program is, above the ROM
VARS_WORDS      .EQU    0x1000          ; the words from 0xFFFFF000, the variables, which end a program's RAM
DEMO            .EQU    0x6000          ; the demo's words in the ROM, after their number
DEMO_MAX        .EQU    PROGRAM-DEMO    ; more words than fit from DEMO + 1 below the RAM
COLOR           .EQU    0x000FFF00      ; white on black, the color at the cold start
OUT_LINE        .EQU    1
OUT_SCREEN      .EQU    2
TABLE_VERSION   .EQU    0x00010003      ; what mon_version returns: 1.3
DUMP_WORDS      .EQU    32              ; the words that d shows without a count
ROW_WORDS       .EQU    4               ; the words of a row of d
PAGE            .EQU    24              ; the rows of a Page Up or Page Down
SCR_MAX         .EQU    0x7FFF          ; the largest display offset

; The dispatch table (README.md, "The dispatch table"). Entries are only
; ever added at the end. The comment of each entry is its name in mon.nasm
; and mon.h. The entries 9 to 15 jump to the C functions fat_mount to
; fat_delete of fat32.c, which are _fat_mount to _fat_delete here, and
; not fs_mount to fs_delete: mon.nasm is joined to the monitor too, for
; monlib.nasm, and its stubs _fs_mount to _fs_delete would clash with
; them. The routines in assembly have no such clash, as their labels,
; such as udp_open, have no _ in front of them.
                JMP     mon_reset       ; 0 at 0x00
                JMP     mon_exit        ; 1 at 0x02
                JMP     mon_version     ; 2 at 0x04
                JMP     mon_putc        ; 3 at 0x06
                JMP     mon_out         ; 4 at 0x08
                JMP     scr_cls         ; 5 at 0x0A
                JMP     scr_moveto      ; 6 at 0x0C
                JMP     scr_getxy       ; 7 at 0x0E
                JMP     scr_color       ; 8 at 0x10
                JMP     _fat_mount      ; 9 at 0x12, fs_mount
                JMP     _fat_open       ; 10 at 0x14, fs_open
                JMP     _fat_read       ; 11 at 0x16, fs_read
                JMP     _fat_readdir    ; 12 at 0x18, fs_readdir
                JMP     _fat_close      ; 13 at 0x1A, fs_close
                JMP     _fat_write      ; 14 at 0x1C, fs_write
                JMP     _fat_delete     ; 15 at 0x1E, fs_delete
                JMP     udp_open        ; 16 at 0x20
                JMP     udp_send        ; 17 at 0x22
                JMP     udp_recv        ; 18 at 0x24
                JMP     udp_close       ; 19 at 0x26

; mon_reset: the cold start, entry 0, which reset runs and a program may
; call. E is cleared, the timer stopped, VBASE set to 0, the font base
; set to 0, so that the screen shows Spleen, and the port for Ethernet
; frames disabled, as at a return, and the ARP cache emptied. The vectors
; of lib.nasm are set, and ___wasm_start gives the words of the ROM's C
; code their initial values. The RAM from 0x8000 is left alone, so that
; a program a host has loaded is still there.
mon_reset
                MOVE    R14, 0          ; E = 0, VBASE = 0; bit 24 stays 1
                MOVE    @TIMER, 0
                MOVE    @SCR_FONT, 0
                MOVE    @ETH_CSR, 0
                MOVE    @V_UPORT, 0
                MOVE    @V_MASK, 0
                MOVE    @V_GW, 0
                MOVE    SP, STACK
                MOVE    @___wasm_trap_vector, mon_trap
                MOVE    @___putc_vector, mon_putc
                CALL    ___wasm_start
                MOVE    R1, V_ARP
arp_clear
                MOVE    @R1++, 0
                CMP     R1, V_ARP+4*ARP_SLOTS+1  ; and V_ARPNEXT
        ?!Z     JMP     arp_clear
                MOVE    @V_COLOR, COLOR
                MOVE    @V_OUT, OUT_LINE+OUT_SCREEN
                MOVE    @V_NEXT, PROGRAM
                MOVE    @V_UNEXT, PROGRAM
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
                MOVE    R1, S_NAME
                CALL    _io_puts
                MOVE    R1, VERSION
                CALL    puts_crlf
                MOVE    R1, S_HINT
                CALL    puts_crlf

; main: the prompt, a line, and its command. SP is fresh for each line, and
; a command jumps back here when it is done. The first character of the
; line that is no blank is the command, A to Z as a to z, looked up in
; COMMANDS; R2 points after it for the command's arguments.
main            MOVE    SP, STACK
                MOVE    R1, S_PROMPT
                CALL    _io_puts
                MOVE    R1, V_LINE
                MOVE    R2, LINE_MAX
                CALL    getline
                MOVE    R2, V_LINE
word            MOVE[M] R1, @R2++
        ?Z      JMP     main            ; an empty line
                CMP     R1, 0x20
        ?Z      JMP     word
                SUB     R3, R1, 0x41
                CMP     R3, 26
        ?C      OR      R1, R1, 0x20    ; A to Z folded to a to z
                MOVE    R3, COMMANDS
find            MOVE[M] R4, @R3++       ; a letter, or 0 at the end
        ?Z      JMP     unknown
                CMP     R4, R1
        ?Z      JMP     @R3             ; the command
                ADD     R3, R3, 1
                JMP     find
unknown         MOVE    R1, S_UNKNOWN
                CALL    puts_crlf
                JMP     main

; ?: the commands, a line each
cmd_help
                MOVE    R1, HELP
                CALL    puts_lines
                JMP     main

; c: the screen cleared
cmd_cls         CALL    scr_cls
                JMP     main

; v: the version of the monitor, and that of the table, major.minor
cmd_version
                MOVE    R1, S_NAME
                CALL    _io_puts
                MOVE    R1, VERSION
                CALL    _io_puts
                MOVE    R1, S_TABLE
                CALL    _io_puts
                SHR     R1, TABLE_VERSION, 16
                CALL    _io_putdec
                MOVE    R1, 0x2E        ; .
                CALL    mon_putc
                AND     R1, TABLE_VERSION, 0xFFFF
                CALL    _io_putdec
                CALL    _io_crlf
                JMP     main

; h: the core halted, until the reset button, or a host starts it
cmd_halt
                MOVE    R1, S_HALTED
                CALL    puts_crlf
                HALT

; d [ADDR] [N]: N words from ADDR, in hex, ROW_WORDS to a row, each row
; with its address first. Without ADDR, the words after the last shown;
; without N, DUMP_WORDS. A d with ir after it is dir, and one with el
; and a blank or nothing after it del.
cmd_dump
                OR      R1, @R2, 0x20   ; I as i
                CMP     R1, 0x69        ; i
        ?Z      JMP     cmd_dir
                CMP     R1, 0x65        ; e
        ?Z      JMP     cmd_del
dump_args
                MOVE    R1, R2
                CALL    _io_gethex      ; R1 the address, R2 its digits, R3 after it
                TST     R2
        ?!Z     MOVE    @V_NEXT, R1
                MOVE    R1, R3
                CALL    _io_gethex      ; R1 the count
                TST     R2
        ?Z      MOVE    R1, DUMP_WORDS
                MOVE[M] R8, R1          ; the words left
        ?Z      JMP     main
                MOVE    R7, @V_NEXT     ; the next word
dump_row
                MOVE    R1, R7
                CALL    _io_puthex
                MOVE    R9, ROW_WORDS   ; the words left in the row
dump_word
                MOVE    R1, 0x20
                CALL    mon_putc
                MOVE    R1, @R7++
                CALL    _io_puthex
                SUB[M]  R8, R8, 1
        ?Z      JMP     dump_end
                SUB[M]  R9, R9, 1
        ?!Z     JMP     dump_word
                CALL    _io_crlf
                JMP     dump_row
dump_end
                MOVE    @V_NEXT, R7
                CALL    _io_crlf
                JMP     main

; i [A.B.C.D | dhcp]: the Ethernet station's IP address (doc/SYSTEM.md,
; "The Ethernet station"), written from four decimal numbers of 0 to 255
; with dots between them, or from DHCP with the word dhcp, in either
; case, and shown, in decimal with dots. Without an address it is only
; shown. Blanks may come before and after the address, and anything else
; makes it no address, which is not written. A written address has no
; mask and no gateway, which only i dhcp gives.
cmd_ip
                CMP     @R2, 0x20
        ?Z      ADD     R2, R2, 1
        ?Z      JMP     cmd_ip
                TST     @R2
        ?Z      JMP     ip_show         ; no address
                OR      R1, @R2, 0x20
                SUB     R1, R1, 0x61
                CMP     R1, 26
        ?C      JMP     ip_word         ; a letter
                MOVE    R1, R2
                CALL    get_ip
                TST     R2
        ?Z      JMP     ip_bad
                MOVE    R7, R1
                CALL    rest_blank
        ?!Z     JMP     ip_bad
                MOVE    @E_IP, R7
                MOVE    @V_MASK, 0
                MOVE    @V_GW, 0
ip_show         MOVE    R1, S_IP
                MOVE    R2, @E_IP
                CALL    show_ip
                JMP     main
ip_bad          MOVE    R1, S_BADIP
                CALL    puts_crlf
                JMP     main
; The word after i, which must be dhcp, and blanks after it
ip_word
                MOVE    R3, S_DHCPW
ip_word_chr
                MOVE[M] R4, @R3++
        ?Z      JMP     ip_word_end
                OR      R1, @R2++, 0x20  ; A to Z as a to z
                CMP     R1, R4
        ?Z      JMP     ip_word_chr
                JMP     ip_bad
ip_word_end
                CMP     @R2, 0x20
        ?Z      ADD     R2, R2, 1
        ?Z      JMP     ip_word_end
                TST     @R2
        ?!Z     JMP     ip_bad
                JMP     ip_dhcp

; get_ip: the IP address at R1, four decimal numbers of 0 to 255 with dots
; between them: R1 the address, R2 = 1, and R3 after it, or R2 = 0 when
; there is none. Uses R1-R6.
get_ip
                MOVE    R3, R1          ; the next character
                MOVE    R1, 0           ; the address
                MOVE    R6, 4           ; the numbers left
get_ip_num
                MOVE    R4, 0           ; the number
                MOVE    R5, R3          ; where it starts
get_ip_digit
                SUB     R2, @R3, 0x30
                CMP     R2, 10
        ?!C     JMP     get_ip_end      ; no digit
                ADD     R4, R4, R4      ; R4 is 10 * R4 + the digit
                ADD     R2, R2, R4
                SHL     R4, R4, 2
                ADD     R4, R4, R2
                CMP     R4, 256
        ?!C     JMP     get_ip_bad
                ADD     R3, R3, 1
                JMP     get_ip_digit
get_ip_end
                CMP     R3, R5
        ?Z      JMP     get_ip_bad      ; a number without digits
                SHL     R1, R1, 8
                OR      R1, R1, R4
                SUB[M]  R6, R6, 1
        ?Z      MOVE    R2, 1
        ?Z      RET
                CMP     @R3, 0x2E       ; .
        ?!Z     JMP     get_ip_bad
                ADD     R3, R3, 1
                JMP     get_ip_num
get_ip_bad
                MOVE    R2, 0
                RET

; show_ip: the string at R1, the IP address R2 in decimal with dots, and
; CR LF. Uses R1-R4, and R7 and R8 across the calls, saved.
show_ip
                PUSH    R7
                PUSH    R8
                MOVE    R8, R2
                CALL    _io_puts
                MOVE    R7, 4           ; the bytes left
ip_byte         ROL     R8, R8, 8       ; the top byte to the bottom
                AND     R1, R8, 0xFF
                CALL    _io_putdec
                SUB[M]  R7, R7, 1
        ?Z      JMP     ip_done
                MOVE    R1, 0x2E
                CALL    mon_putc
                JMP     ip_byte
ip_done         POP     R8
                POP     R7
                JMP     _io_crlf        ; which returns to the caller

; m [MAC]: the Ethernet station's MAC address (doc/SYSTEM.md, "The
; Ethernet station"), written from six bytes of one or two hex digits, in
; either case, with colons between them, and shown, two hex digits a byte
; with colons. The first byte must be even, as bit 0 of it marks a group
; address, which is no station's. Without an address it is only shown.
; Blanks may come before and after the address, and anything else makes it
; no address, which is not written. R7:R8 gather the address, a byte at a
; time, R9 counts the bytes left, and R10 points into the line.
cmd_mac
                MOVE    R7, 0
                MOVE    R8, 0
                MOVE    R9, 6
mac_blank
                CMP     @R2, 0x20
        ?Z      ADD     R2, R2, 1
        ?Z      JMP     mac_blank
                TST     @R2
        ?Z      JMP     mac_show        ; no address
                MOVE    R10, R2
mac_byte
                CMP     @R10, 0x20      ; no blank inside the address
        ?Z      JMP     mac_bad
                MOVE    R1, R10
                CALL    _io_gethex
                MOVE    R10, R3
                SUB     R2, R2, 1
                CMP     R2, 2
        ?!C     JMP     mac_bad         ; no digit, or more than two
                SHR     R4, R8, 24      ; R7:R8 shifted by a byte, and R1 in
                SHL     R7, R7, 8
                OR      R7, R7, R4
                SHL     R8, R8, 8
                OR      R8, R8, R1
                SUB[M]  R9, R9, 1
        ?Z      JMP     mac_last
                CMP     @R10, 0x3A      ; :
        ?!Z     JMP     mac_bad
                ADD     R10, R10, 1
                JMP     mac_byte
mac_last
                CMP     @R10, 0x20      ; blanks, then the end of the line
        ?Z      ADD     R10, R10, 1
        ?Z      JMP     mac_last
                TST     @R10
        ?!Z     JMP     mac_bad
                AND[M]  R0, R7, 0x100   ; bit 0 of the first byte: a group address
        ?!Z     JMP     mac_bad
                MOVE    @E_MACH, R7
                MOVE    @E_MACL, R8
; The bytes go out from the top of R7, and R8 fills R7 from below.
mac_show
                MOVE    R1, S_MAC
                CALL    _io_puts
                AND     R7, @E_MACH, 0xFFFF
                SHL     R7, R7, 16
                MOVE    R8, @E_MACL
                SHR     R1, R8, 16
                OR      R7, R7, R1
                SHL     R8, R8, 16
                MOVE    R9, 6           ; the bytes left
mac_put         SHR     R1, R7, 28      ; the top byte, a digit at a time
                CALL    mac_digit
                SHR     R1, R7, 24
                CALL    mac_digit
                SUB[M]  R9, R9, 1
        ?Z      JMP     mac_done
                SHR     R4, R8, 24
                SHL     R7, R7, 8
                OR      R7, R7, R4
                SHL     R8, R8, 8
                MOVE    R1, 0x3A        ; :
                CALL    mon_putc
                JMP     mac_put
mac_done
                CALL    _io_crlf
                JMP     main
mac_bad         MOVE    R1, S_BADMAC
                CALL    puts_crlf
                JMP     main

; mac_digit: bits 3..0 of R1 as a hex digit
mac_digit
                AND     R1, R1, 0xF
                ADD     R1, R1, 0x30
                CMP     R1, 0x3A
        ?!C     ADD     R1, R1, 7       ; A to F
                JMP     mon_putc        ; which returns to the caller

; l: words into the memory from lines of ADDR WORD, two hex numbers of 1 to
; 8 digits with blanks between them and around them, as a .bin file has
; them (nice_cpu's ISA.md §10.4), up to an empty line or CTRL-C, which
; also drops the line it is in. CR, LF, and CR LF end a line, so a
; terminal's lines and a file's both serve; V_LEND starts as a CR, so
; that the LF of a terminal that ends the l line itself with CR LF is
; the LF of that CR LF, not an empty line. A TAB is a blank, as niceemu
; takes it. A line of blanks only is passed over, as niceemu passes it,
; and counted as a line and not as skipped. A line with anything else, or
; with ADDR outside a program's RAM, PROGRAM up to V_PEND, is skipped:
; the RAM of a board repeats every RAM_WORDS words, so an address past it
; could reach the ROM or the monitor's variables and stack, which are at
; RAM_WORDS - VARS_WORDS and up of the RAM, 0x1F000 on the MEGA65 and
; 0xF000 on the Nexys4DDR. V_PEND is that address, or the screen where
; RAM_WORDS reads 0, as in niceemu. A line of more than LINE_MAX
; characters is skipped too: LINE_MAX + 1 of them are kept, which tells
; it from a full line, and the rest dropped. A second line for an address
; writes its word over the first's, where niceemu rejects the file. The
; count of the words written and the lowest and highest address are
; shown at the end, and the count of the skipped lines, the number of the
; first, and the last address that a line may have. DEL
; and BS delete the character before the cursor; the other control codes,
; the bytes from 0x80, and the escape sequences of the cursor and function
; keys are dropped. The lines are shown in row R7, which the hint leaves
; the cursor in, and only on the screen: each line clears the row, and its
; end is not shown, so the screen never scrolls. R8 counts the words
; written, R9 and R10 are the lowest and highest address written, R11
; counts the lines, R12 the lines skipped, and R6 is the next free word of
; the line. An l with oad after it is load NAME.
cmd_load
                OR      R1, @R2, 0x20   ; O as o
                CMP     R1, 0x6F        ; o
        ?Z      JMP     cmd_fload
                MOVE    R1, S_LHINT
                CALL    puts_crlf
                MOVE    @V_LOUT, @V_OUT
                MOVE    @V_OUT, OUT_SCREEN
                MOVE    @V_LEND, 0x0D   ; as after the CR of the l line
                MOVE    R7, @V_ROW
                MOVE    R8, 0
                MOVE    R9, 0xFFFFFFFF
                MOVE    R10, 0
                MOVE    R11, 0
                MOVE    R12, 0
                CALL    load_pend
load_line
                CALL    load_row
                MOVE    R6, V_LINE
load_key
                CALL    _io_getc
                MOVE    R2, @V_LEND
                MOVE    @V_LEND, R1
                CMP     R1, 0x0A
        ?!Z     JMP     load_char
                CMP     R2, 0x0D
        ?Z      JMP     load_key        ; the LF of a CR LF
                JMP     load_end
load_char
                CMP     R1, 0x0D
        ?Z      JMP     load_end
                CMP     R1, 0x7F
        ?Z      JMP     load_del
                CMP     R1, 0x08
        ?Z      JMP     load_del
                CMP     R1, 0x03
        ?Z      JMP     load_done       ; CTRL-C
                CMP     R1, 0x1B
        ?Z      JMP     load_esc
                CMP     R1, 0x09
        ?Z      MOVE    R1, 0x20        ; a TAB is a blank
                CMP     R1, 0x20
        ?C      JMP     load_key        ; another control code
                CMP     R1, 0x80
        ?!C     JMP     load_key        ; 0x80 and above
                CMP     R6, V_LINE+LINE_MAX+1
        ?Z      JMP     load_key        ; the line is over full
                MOVE    @R6++, R1
                CALL    mon_putc
                JMP     load_key
load_del
                CMP     R6, V_LINE
        ?Z      JMP     load_key        ; nothing before the cursor
                SUB     R6, R6, 1
                MOVE    R1, _io_gets.rub
                CALL    _io_puts
                JMP     load_key
; An ESC: with a [ or an O within io.t_esc, a sequence, whose bytes up to
; its final one, 0x40 to 0x7E, are dropped; another byte is dropped with
; the ESC.
load_esc
                CALL    _io_getc.soon
        ?Z      JMP     load_key
                CMP     R1, 0x5B        ; [
        ?Z      JMP     load_seq
                CMP     R1, 0x4F        ; O
        ?!Z     JMP     load_key
load_seq
                CALL    _io_getc.soon
        ?Z      JMP     load_key
                CMP     R1, 0x40
        ?C      JMP     load_seq        ; a parameter byte
                JMP     load_key        ; the final byte
; The end of a line: an empty one ends the load, and another goes to
; bin_line
load_end
                MOVE    @R6, 0
                CMP     R6, V_LINE
        ?Z      JMP     load_done
                CALL    bin_line
                JMP     load_line

; bin_line: the line at V_LINE, which ends at R6 with a 0, LINE_MAX + 1
; characters when it was longer, of l and tftp: counted in R11, passed
; over when it has blanks only, or else parsed, and its word written,
; counted in R8, with the lowest and highest address in R9 and R10, or
; skipped, counted in R12, with the number of the first in V_LBAD. Uses
; R1-R6.
bin_line
                ADD     R11, R11, 1
                CMP     R6, V_LINE+LINE_MAX+1
        ?Z      JMP     bin_bad         ; longer than LINE_MAX
                MOVE    R1, V_LINE
                CALL    _io_gethex      ; R1 the address, R2 its digits, R3 after it
                TST     R2
        ?!Z     JMP     bin_addr
                TST     @R3
        ?Z      RET                     ; blanks only
bin_addr
                SUB     R4, R2, 1
                CMP     R4, 8
        ?!C     JMP     bin_bad         ; no digit, or more than 8
                CMP     R1, PROGRAM
        ?C      JMP     bin_bad         ; in the ROM
                CMP     R1, @V_PEND
        ?!C     JMP     bin_bad         ; the variables, or past the RAM
                MOVE    R6, R1
                MOVE    R1, R3
                CALL    _io_gethex      ; R1 the word
                SUB     R4, R2, 1
                CMP     R4, 8
        ?!C     JMP     bin_bad
bin_tail
                CMP     @R3, 0x20
        ?Z      ADD     R3, R3, 1
        ?Z      JMP     bin_tail
                TST     @R3
        ?!Z     JMP     bin_bad         ; more after the word
                MOVE    @R6, R1
                ADD     R8, R8, 1
                CMP     R6, R9
        ?C      MOVE    R9, R6          ; a lower address
                CMP     R10, R6
        ?C      MOVE    R10, R6         ; a higher one
                RET
bin_bad
                ADD     R12, R12, 1
                CMP     R12, 1
        ?Z      MOVE    @V_LBAD, R11
                RET
; The end of the load: the row blank again, the outputs back, the words
; written, and the lines skipped
load_done
                CALL    load_row
                MOVE    @V_OUT, @V_LOUT
load_summary
                MOVE    R1, S_LOADED
                CALL    _io_puts
                MOVE    R1, R8
                CALL    _io_putdec
                TST     R8
        ?Z      JMP     load_skipped
                MOVE    R1, S_LFROM
                CALL    _io_puts
                MOVE    R1, R9
                CALL    _io_puthex
                MOVE    R1, S_LTO
                CALL    _io_puts
                MOVE    R1, R10
                CALL    _io_puthex
load_skipped
                CALL    _io_crlf
                TST     R12
        ?Z      JMP     main
                MOVE    R1, S_SKIPPED
                CALL    _io_puts
                MOVE    R1, R12
                CALL    _io_putdec
                MOVE    R1, S_FIRST
                CALL    _io_puts
                MOVE    R1, @V_LBAD
                CALL    _io_putdec
                MOVE    R1, S_LFORM
                CALL    _io_puts
                SUB     R1, @V_PEND, 1
                CALL    _io_puthex
                CALL    _io_crlf
                JMP     main

; load_pend: V_PEND, the end of a program's RAM, where the variables
; start, from the size of the RAM, or the screen in niceemu. Uses R1.
load_pend
                MOVE[M] R1, @RAM_WORDS
        ?Z      MOVE    R1, SCREEN+VARS_WORDS  ; no limit
                SUB     @V_PEND, R1, VARS_WORDS
                RET

; dir [SLOT]: the folder NICE of the card in SLOT, in hex, mounted first,
; or of the card mounted, with fat_dir of fat32.c. R2 points after the d.
cmd_dir
                MOVE    R1, @R2++
                OR      R1, @R2++, 0x20  ; R as r
                CMP     R1, 0x72        ; r
        ?!Z     JMP     unknown
                MOVE    R1, @R2
                CMP     R1, 0x20
        ?Z      JMP     dir_args
                TST     R1
        ?!Z     JMP     unknown         ; dirx
dir_args
                MOVE    R1, R2
                CALL    _io_gethex      ; R1 the slot, R2 its digits, R3 after it
                MOVE    R7, R1
                CMP     R2, 9
        ?!C     JMP     dir_bad         ; more than 8 digits
                TST     R2
        ?Z      MOVE    R7, 0xFFFFFFFF  ; no slot: the card mounted
                CALL    rest_blank
        ?!Z     JMP     dir_bad
                MOVE    R1, R7
                CALL    _fat_dir
                TST     R1
        ?N      JMP     fs_fail
                JMP     main
dir_bad
                MOVE    R1, S_BADDIR
                CALL    puts_crlf
                JMP     main

; load NAME: the .bin file NAME of the card's folder NICE, read with
; fat_load of fat32.c, which writes its words as l does, and shown as l
; shows its lines. R2 points after the l.
cmd_fload
                MOVE    R1, R2
                MOVE    R2, S_OAD
                CALL    match           ; R1 after oad, or 0
                TST     R1
        ?Z      JMP     unknown
                TST     @R1
        ?Z      JMP     fload_bad       ; load alone
                CMP     @R1, 0x20
        ?!Z     JMP     unknown         ; loadx
                CALL    fs_name
                TST     R1
        ?Z      JMP     fload_bad       ; no name
                MOVE    R7, R1          ; the name
                CALL    rest_blank
        ?!Z     JMP     fload_bad       ; a second word
                MOVE    R1, R7
                MOVE    R2, 0           ; to read
                CALL    _fat_open
                TST     R1
        ?N      JMP     fs_fail
                MOVE    R8, R1          ; the handle
                CALL    load_pend
                MOVE    R1, R8
                MOVE    R2, @V_PEND
                MOVE    R3, V_LSTATS
                CALL    _fat_load
                MOVE    R9, R1
                MOVE    R1, R8
                CALL    _fat_close
                MOVE    R1, R9
                TST     R1
        ?N      JMP     fs_fail
                MOVE    R8, @V_LSTATS
                MOVE    R9, @V_LSTATS+1
                MOVE    R10, @V_LSTATS+2
                MOVE    R12, @V_LSTATS+3
                MOVE    @V_LBAD, @V_LSTATS+4
                JMP     load_summary
fload_bad
                MOVE    R1, S_BADLOAD
                CALL    puts_crlf
                JMP     main

; save NAME ADDR N: the N words from ADDR, both in hex, written to the
; file NAME of the card's folder, which is made or truncated, as a .bin
; file, with fat_save of fat32.c, and the words saved shown as load shows
; those loaded. R2 points after the s.
cmd_save
                MOVE    R1, R2
                MOVE    R2, S_AVE
                CALL    match           ; R1 after ave, or 0
                TST     R1
        ?Z      JMP     unknown
                TST     @R1
        ?Z      JMP     save_bad        ; save alone
                CMP     @R1, 0x20
        ?!Z     JMP     unknown         ; savex
                CALL    fs_name
                TST     R1
        ?Z      JMP     save_bad        ; no name
                MOVE    R7, R1          ; the name
                MOVE    R1, R3
                CALL    _io_gethex      ; R1 the address, R2 its digits, R3 after it
                SUB     R4, R2, 1
                CMP     R4, 8
        ?!C     JMP     save_bad        ; no digit, or more than 8
                MOVE    R9, R1
                MOVE    R1, R3
                CALL    _io_gethex      ; R1 the count
                SUB     R4, R2, 1
                CMP     R4, 8
        ?!C     JMP     save_bad
                MOVE    R10, R1
                CALL    rest_blank
        ?!Z     JMP     save_bad        ; a fourth word
                MOVE    R1, R7
                MOVE    R2, 1           ; to write
                CALL    _fat_open
                TST     R1
        ?N      JMP     fs_fail
                MOVE    R8, R1          ; the handle
                MOVE    R2, R9
                MOVE    R3, R10
                CALL    _fat_save
                MOVE    R11, R1
                MOVE    R1, R8
                CALL    _fat_close
                TST     R11
        ?N      MOVE    R1, R11         ; the error of the save, before the close's
                TST     R1
        ?N      JMP     fs_fail
                MOVE    R1, S_SAVED
                CALL    _io_puts
                MOVE    R1, R10
                CALL    _io_putdec
                TST     R10
        ?Z      JMP     save_end
                MOVE    R1, S_LFROM
                CALL    _io_puts
                MOVE    R1, R9
                CALL    _io_puthex
                MOVE    R1, S_LTO
                CALL    _io_puts
                ADD     R1, R9, R10
                SUB     R1, R1, 1
                CALL    _io_puthex
save_end
                CALL    _io_crlf
                JMP     main
save_bad
                MOVE    R1, S_BADSAVE
                CALL    puts_crlf
                JMP     main

; del NAME: the file NAME of the card's folder deleted, with fat_delete of
; fat32.c. R2 points after the d, at the e; a d with e and no l after it,
; such as de 10, is d.
cmd_del
                MOVE    R7, R2
                MOVE    R1, R2
                MOVE    R2, S_EL
                CALL    match           ; R1 after el, or 0
                TST     R1
        ?Z      JMP     del_dump
                TST     @R1
        ?Z      JMP     del_bad         ; del alone
                CMP     @R1, 0x20
        ?!Z     JMP     unknown         ; delx
                CALL    fs_name
                TST     R1
        ?Z      JMP     del_bad         ; no name
                MOVE    R7, R1          ; the name
                CALL    rest_blank
        ?!Z     JMP     del_bad         ; a second word
                MOVE    R1, R7
                CALL    _fat_delete
                TST     R1
        ?N      JMP     fs_fail
                MOVE    R1, S_DELETED
                CALL    _io_puts
                MOVE    R1, R7
                CALL    puts_crlf
                JMP     main
del_dump
                MOVE    R2, R7
                JMP     dump_args
del_bad
                MOVE    R1, S_BADDEL
                CALL    puts_crlf
                JMP     main

; fs_name: the name of a file in the line from R1, after blanks, ended in
; the line with a 0 at the first blank after it: R1 the name, and R3 the
; rest of the line, or R1 = 0 when the line has no more. Uses R1-R3.
fs_name
                CMP     @R1, 0x20
        ?Z      ADD     R1, R1, 1
        ?Z      JMP     fs_name
                TST     @R1
        ?Z      MOVE    R1, 0
        ?Z      RET
                MOVE    R3, R1
fs_name_end
                ADD     R3, R3, 1
                TST     @R3
        ?Z      RET
                CMP     @R3, 0x20
        ?!Z     JMP     fs_name_end
                MOVE    @R3++, 0
                RET

; match: Z clear and R1 after the string at R2 when the line at R1 starts
; with it, in either case, or R1 = 0. Uses R1-R4.
match
                MOVE[M] R3, @R2++
        ?Z      RET
                OR      R3, R3, 0x20
                OR      R4, @R1++, 0x20
                CMP     R3, R4
        ?Z      JMP     match
                MOVE    R1, 0
                RET

; rest_blank: Z when the line from R3 has only blanks. Uses R3.
rest_blank
                CMP     @R3, 0x20
        ?Z      ADD     R3, R3, 1
        ?Z      JMP     rest_blank
                TST     @R3
                RET

; fs_fail: an error of fat32.c, R1 its negative: one of the SD controller's
; as sd shows it, with the selected slot, or a file error, its number and
; its meaning
fs_fail
                CMP     R1, 0xFFFFFFF8  ; -8
        ?C      JMP     fs_file         ; below -8
                MOVE    R7, @SD_SELECT
                JMP     sd_fail
fs_file
                SUB     R8, R0, R1      ; the error
                MOVE    R1, S_FSERR
                CALL    _io_puts
                MOVE    R1, R8
                CALL    _io_putdec
                SUB     R1, R8, FS_ERR0
                CMP     R1, FS_ERRS
        ?!C     JMP     fs_file_end     ; an error without a meaning here
                ADD     R1, R1, FS_ERRORS
                MOVE    R7, @R1
                MOVE    R1, S_UCOMMA
                CALL    _io_puts
                MOVE    R1, R7
                CALL    _io_puts
fs_file_end
                CALL    _io_crlf
                JMP     main

; load_row: row R7 blank in the current color, and the cursor at its column
; 0. Uses R1-R3.
load_row
                SHL     R2, R7, 6
                SHL     R1, R7, 4
                ADD     R1, R1, R2
                ADD     R1, R1, SCREEN
                OR      R3, @V_COLOR, 0x20
                MOVE    R2, 80
load_blank
                MOVE    @R1++, R3
                SUB[M]  R2, R2, 1
        ?!Z     JMP     load_blank
                MOVE    @V_COL, 0
                MOVE    @V_ROW, R7
                JMP     putc_cur

; x: the demo, for the time being (issue #65, README.md). The ROM has its
; number of words at DEMO, and the words after it, which are copied to
; 0x8000 and run as r runs a program. A number of 0, or one too big for
; the ROM, is no demo. The demo, nice_cpu's, clears the screen at its
; return, and leaves the timer stopped and E clear, but the cursor of
; V_COL and V_ROW is the monitor's, so scr_cls sets it again before
; mon_exit. The copy and x go when the demo goes.
cmd_demo
                MOVE[M] R1, @DEMO       ; the words left
        ?Z      JMP     no_demo
                CMP     R1, DEMO_MAX
        ?!C     JMP     no_demo
                MOVE    R2, DEMO+1
                MOVE    R3, PROGRAM
demo_copy
                MOVE    @R3++, @R2++
                SUB[M]  R1, R1, 1
        ?!Z     JMP     demo_copy
                MOVE    R1, MON_PUTC    ; as run_at calls a program
                MOVE    R2, 0
                MOVE    R3, 0
                CALL    PROGRAM
                PUSH    R1              ; the status
                CALL    scr_cls
                POP     R1
                JMP     mon_exit
no_demo         MOVE    R1, S_NODEMO
                CALL    puts_crlf
                JMP     main

; r [ADDR]: the program at ADDR, 0x8000 without it, called as ABI.md
; says, on this stack: the return address is pushed, and the program
; returns with RET and its status in R1. A word of 0 at ADDR is no
; program: it is NOP, which no start-up code begins with. r 0
; is entry 0 of the dispatch table, the cold start. x enters at run_at,
; with R7 the address.
cmd_run
                MOVE    R1, R2
                CALL    _io_gethex      ; R1 the address, R2 its digits
                MOVE    R7, R1
                TST     R2
        ?Z      MOVE    R7, PROGRAM     ; no address
run_at          TST     @R7
        ?Z      JMP     no_prog
                MOVE    R1, MON_PUTC    ; the entry of mon_putc (mon.nasm)
                MOVE    R2, 0           ; argc
                MOVE    R3, 0           ; argv
                CALL    R7

; mon_exit: entry 1, and where a program returns to. Back to the main loop
; with R1 the status: E cleared, the timer stopped, VBASE 0, the font base
; 0, the port for Ethernet frames disabled, the cursor shown and blinking
; with the display offset off, a fresh stack, and the status printed,
; after a new line if the program left the cursor in a row.
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
; column 0.
exit_restore
                MOVE    R14, 0          ; E = 0, VBASE = 0; bit 24 stays 1
                MOVE    @TIMER, 0
                MOVE    @SCR_FONT, 0    ; Spleen, whatever the program chose
                MOVE    @ETH_CSR, 0     ; no frames, if the program took them
                MOVE    @V_UPORT, 0     ; and the UDP endpoint closed
                MOVE    @SCR_CTL, 0x60  ; the cursor, which a program may hide
                TST     @V_COL
        ?!Z     JMP     _io_crlf        ; which returns to the caller
                RET
no_prog         MOVE    R1, S_NOPROG
                CALL    _io_puts
                MOVE    R1, R7
                CALL    _io_puthex
                CALL    _io_crlf
                JMP     main

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
        ?C      JMP     putc_chr        ; 0x20 to 0x7E
        ?Z      RET                     ; 0x7F: nothing
; The character at the cursor, SCREEN + 80 * row + column, and the cursor
; moved on
putc_chr
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
putc_hist
                MOVE    @R2++, @R3++
                SUB[M]  R4, R4, 1
        ?!Z     JMP     putc_hist
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
putc_up         MOVE    @R2++, @R3++
                SUB[M]  R4, R4, 1
        ?!Z     JMP     putc_up
                OR      R3, @V_COLOR, 0x20
                MOVE    R4, 80          ; row 24 blank
putc_blk
                MOVE    @R2++, R3
                SUB[M]  R4, R4, 1
        ?!Z     JMP     putc_blk
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
        ?Z      JMP     putc_bs
                CMP     R1, 0x09
        ?!Z     RET                     ; another control code: nothing
                OR      R1, @V_COL, 7   ; TAB: the next multiple of 8
                ADD     R1, R1, 1
                CMP     R1, 80
        ?!C     JMP     putc_lf         ; past the last column
                MOVE    @V_COL, R1
                JMP     putc_cur
putc_bs         MOVE[M] R1, @V_COL
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
cls_loop
                DEC[M]  R1, R1
                MOVE    @SCREEN[R1], R3
        ?!Z     JMP     cls_loop
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
; _io_gets reads it, with the keys of the history before it: Page Up, ESC
; [ 5 ~, and Page Down, ESC [ 6 ~. The other escape sequences are dropped,
; as _io_gets drops them, and any key but those two shows the screen again.
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
                CMP     R1, 0x40
        ?!C     JMP     getline_drop    ; the final byte, such as A
                CALL    _io_getc.soon
        ?Z      JMP     getline_drop
                CMP     R1, 0x7E        ; ~
        ?!Z     JMP     getline_csi
                CMP     R3, 0x35        ; 5
        ?Z      JMP     getline_up
                CMP     R3, 0x36        ; 6
        ?Z      JMP     getline_down
                JMP     getline_drop
getline_csi
                CMP     R1, 0x40
        ?!C     JMP     getline_drop    ; the final byte
                CALL    _io_getc.soon
        ?Z      JMP     getline_drop
                JMP     getline_csi
getline_ss3
                CALL    _io_getc.soon
getline_drop
                CALL    hist_leave
                JMP     getline_key
getline_up
                CALL    hist_up
                JMP     getline_key
getline_down
                CALL    hist_down
                JMP     getline_key
getline_line
                MOVE    R3, R1
                CALL    hist_leave
                POP     R2
                POP     R1
                JMP     _io_gets.first  ; which returns to the caller

; hist_up: PAGE rows further back, up to the rows kept. The first turns
; the ring and keeps SCR_CTL. Uses R1-R6.
hist_up
                TST     @V_HCOUNT
        ?Z      RET                     ; no history
                MOVE[M] R1, @V_BACK
        ?!Z     JMP     hist_more
                MOVE    @V_CTL, @SCR_CTL
                CALL    hist_turn
                MOVE    R1, 0
hist_more
                ADD     R1, R1, PAGE
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

; hist_down: PAGE rows forward, and the screen again at the end. Uses R1
; and R2.
hist_down
                MOVE[M] R1, @V_BACK
        ?Z      RET
                SUB[M]  R1, R1, PAGE
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
hist_rev_loop
                CMP     R1, R2
        ?!C     RET                     ; the two have met
                MOVE    R3, @R1
                MOVE    @R1++, @R2
                MOVE    @R2, R3
                SUB     R2, R2, 1
                JMP     hist_rev_loop

; puts_crlf: the string at R1, and CR LF
puts_crlf
                CALL    _io_puts
                JMP     _io_crlf        ; which returns to the caller

; puts_lines: the strings of the table at R1, each with CR LF after it, up
; to a 0 word. Uses R7 across the calls, saved.
puts_lines
                PUSH    R7
                MOVE    R7, R1
lines           MOVE[M] R1, @R7++
        ?Z      POP     R7
        ?Z      RET
                CALL    puts_crlf
                JMP     lines

; The commands: the letter, and the routine, which main jumps to. A 0 ends
; the table.
COMMANDS
                .DAT    0x3F, cmd_help  ; ?
                .DAT    0x63, cmd_cls   ; c
                .DAT    0x64, cmd_dump  ; d
                .DAT    0x68, cmd_halt  ; h
                .DAT    0x69, cmd_ip    ; i
                .DAT    0x6C, cmd_load  ; l
                .DAT    0x6D, cmd_mac   ; m
                .DAT    0x72, cmd_run   ; r
                .DAT    0x73, cmd_sd    ; s, for sd
                .DAT    0x74, cmd_tftp  ; t, for tftp
                .DAT    0x75, cmd_dis   ; u
                .DAT    0x76, cmd_version  ; v
                .DAT    0x78, cmd_demo  ; x
                .DAT    0

S_NAME          .ASCII_L 'NiceMon '
S_HINT          .ASCII_L '? lists the commands'
S_PROMPT
                .ASCII_L '> '
S_UNKNOWN
                .ASCII_L 'Unknown command; ? lists them'
S_TABLE         .ASCII_L ', table '
S_HALTED
                .ASCII_L 'Halted'
S_RETURN
                .ASCII_L 'Returned '
S_TRAP          .ASCII_L 'Trap '
S_AT            .ASCII_L ' at '
S_NOPROG
                .ASCII_L 'No program at '
S_NODEMO
                .ASCII_L 'No demo in the ROM'
S_IP            .ASCII_L 'IP address '
S_MAC           .ASCII_L 'MAC address '
S_LHINT         .ASCII_L 'ADDR WORD in hex on each line, as in a .bin file; an empty line ends'
S_LOADED
                .ASCII_L 'Words loaded: '
S_LFROM         .ASCII_L ', '
S_LTO           .ASCII_L ' to '
S_SKIPPED
                .ASCII_L 'Lines skipped: '
S_FIRST         .ASCII_L ', first line '
S_LFORM         .ASCII_L '; ADDR WORD in hex, ADDR 00008000 to '
S_BADIP         .ASCII_L 'Not an IP address: four numbers from 0 to 255, with dots between them'
S_DHCPW         .ASCII_L 'dhcp'
S_BADMAC
                .ASCII_L 'Not a MAC address: six bytes in hex with colons, the first one even'
S_FSERR         .ASCII_L 'File error '
S_OAD           .ASCII_L 'oad'
S_BADDIR
                .ASCII_L 'dir [SLOT]: the slot in hex, such as dir 1'
S_BADLOAD
                .ASCII_L 'load NAME: the 8.3 name of a file, such as load HELLO.BIN'
S_AVE           .ASCII_L 'ave'
S_EL            .ASCII_L 'el'
S_SAVED         .ASCII_L 'Words saved: '
S_BADSAVE
                .ASCII_L 'save NAME ADDR N: a name, and the address and the count in hex'
S_DELETED
                .ASCII_L 'Deleted '
S_BADDEL
                .ASCII_L 'del NAME: the 8.3 name of a file, such as del HELLO.BIN'
; The meanings of fat32.c's errors FS_ERR0 to FS_ERR0 + FS_ERRS - 1.
; E_FS29 names the folder of the build, so the Makefile writes it, in
; build/folder.nasm.
FS_ERRORS
                .DAT    E_FS16, E_FS17, E_FS18, E_FS19, E_FS20, E_FS21, E_FS22
                .DAT    E_FS23, E_FS24, E_FS25, E_FS26, E_FS27, E_FS28, E_FS29
                .DAT    E_FS30, E_FS31, E_FS32
FS_ERR0         .EQU    16
FS_ERRS         .EQU    17
E_FS16          .ASCII_L 'no FAT32 file system'
E_FS17          .ASCII_L 'FAT12, which is not supported'
E_FS18          .ASCII_L 'FAT16, which is not supported'
E_FS19          .ASCII_L 'exFAT, which is not supported'
E_FS20          .ASCII_L 'not an 8.3 name'
E_FS21          .ASCII_L 'no such file'
E_FS22          .ASCII_L 'a directory'
E_FS23          .ASCII_L 'too many open files'
E_FS24          .ASCII_L 'not an open file'
E_FS25          .ASCII_L 'no such mode'
E_FS26          .ASCII_L 'the FAT is damaged'
E_FS27          .ASCII_L 'no such slot'
E_FS28          .ASCII_L 'the card has changed'
E_FS30          .ASCII_L 'the card or the folder is full'
E_FS31          .ASCII_L 'the file is open'
E_FS32          .ASCII_L 'the file is read-only'

HELP            .DAT    H_R, H_L, H_LOAD, H_SAVE, H_DEL, H_TFTP, H_TFTPL, H_X, H_D, H_U, H_S
                .DAT    H_DIR, H_I, H_ID, H_M, H_C, H_V, H_H, H_Q, H_P, 0
H_R             .ASCII_L 'r [ADDR]      run the program at ADDR, or at 00008000; r 0 restarts'
H_L             .ASCII_L 'l             enter lines of ADDR WORD in hex, as a .bin file has them'
H_LOAD          .ASCII_L 'load NAME     load the .bin file NAME of the SD card, as l loads lines'
H_SAVE          .ASCII_L 'save NAME A N save N words from A, both in hex, as the .bin file NAME'
H_DEL           .ASCII_L 'del NAME      delete the file NAME of the SD card'
H_TFTP          .ASCII_L 'tftp IP NAME  load the .bin file NAME from the TFTP server at IP'
H_TFTPL         .ASCII_L 'tftp IP [PAT] list the files of tools/tftpd.py at IP, or those of PAT'
H_X             .ASCII_L 'x             run the demo of the ROM, which F12 leaves'
H_D             .ASCII_L 'd [ADDR] [N]  show N words from ADDR, in hex, or the next ones'
H_U             .ASCII_L 'u [ADDR] [N]  disassemble N instructions from ADDR, or the next ones'
H_S             .ASCII_L 'sd [SLOT] LBA show sector LBA of the SD card in SLOT, or in the last slot'
H_DIR           .ASCII_L 'dir [SLOT]    list the files of the SD card in SLOT, or of the card mounted'
H_I             .ASCII_L 'i [A.B.C.D]   show the IP address, or set it, such as 192.168.1.65'
H_ID            .ASCII_L 'i dhcp        get the IP address from a DHCP server'
H_M             .ASCII_L 'm [MAC]       show the MAC address, or set it, such as 02:4E:49:43:45:01'
H_C             .ASCII_L 'c             clear the screen'
H_V             .ASCII_L 'v             the version'
H_H             .ASCII_L 'h             halt the core'
H_Q             .ASCII_L '?             the commands'
H_P             .ASCII_L 'PgUp PgDn     scroll back, before a command; MEGA with CRSR up or down'
S_UCOMMA
                .ASCII_L ', '
S_UGAP          .ASCII_L '  '
