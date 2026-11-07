; The monitor, the program of the ROM at 0x0000 (README.md). The core boots
; from it at reset. It gives the programs at 0x8000 a hardware abstraction
; layer, the HAL: nine routines, called through the dispatch table at the
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
; sd shows a sector of an SD card, which the sector routines sd_init,
; sd_read, and sd_write read; they are the ROM's own, with no entries in
; the dispatch table (issue #57, doc/SDCARD.md). i dhcp gets the IP
; address from a DHCP server through the port for Ethernet frames, with
; the frame routines eth_on, eth_recv, and eth_send, which are the ROM's
; own too, as is the ARP cache of arp_resolve (issue #83, README.md, "The
; network").
;
; u disassembles instructions, a row each, in the text of nice_cpu's
; nicedis.py, with the pairs of a call shown as CALL, the return as RET,
; and the words of NOP, JMP, PUSH, POP, CLR, TST, and CMP as those, the
; pseudo-instructions of nice_cpu's ISA.md §10.1 (README.md, "The
; disassembler").
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
; The ROM's C code, rom.c and the files after it in the Makefile's ROM_C,
; is one wasm module, which nicewasm --ram translates for a ROM and the
; Makefile joins after mon.nasm, with nice_cpu's lib.nasm and
; muldiv_mpu.nasm (README.md, "C in the ROM"). The words that it writes,
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
; monlib.nasm, which the Makefile joins after this file, with mon.nasm and
; build/version.nasm, which defines VERSION, the string of the banner.

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
SD_CSR          .EQU    0xFFFFFFA0      ; the SD card's status, and a write starts a command (nice_cpu's SYSTEM.md §5)
SD_LBA          .EQU    0xFFFFFFA1      ; the sector of a Read or Write
SD_CHUNK        .EQU    0xFFFFFFA2      ; the 8 words of the buffer at SD_BUF
SD_ERROR        .EQU    0xFFFFFFA3      ; the error of the last command, 0 for none
SD_SELECT       .EQU    0xFFFFFFA4      ; the selected slot
SD_LAST         .EQU    0xFFFFFFA5      ; the card's last sector, while it is ready
SD_SLOTS        .EQU    0xFFFFFFA6      ; the slots of the system
SD_BUF          .EQU    0xFFFFFFA8      ; SD_BUF0 to SD_BUF7, the words of the chunk
ETH_CSR         .EQU    0xFFFFFFC0      ; the port for Ethernet frames: its status, and a write of bit 0 enables it (nice_cpu's SYSTEM.md §7)
ETH_RX_LEN      .EQU    0xFFFFFFC1      ; the bytes of the frame at the head of the queue, and a write releases it
ETH_TX_LEN      .EQU    0xFFFFFFC2      ; a write of N sends the first N bytes of the send buffer
ETH_CHUNK       .EQU    0xFFFFFFC3      ; the 8 words at ETH_BUF, and in bit 8 the buffer: 0 the queue's, 1 the send buffer
ETH_BUF         .EQU    0xFFFFFFC8      ; ETH_BUF0 to ETH_BUF7, the words of the chunk
TIME_HI         .EQU    0xFFFFFF45      ; bits 63..32 of the microseconds, from the snapshot that a read of io.us takes

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
V_TXF           .EQU    0xFFFFF120      ; a frame to send, from byte 2, DHCP_WORDS words, as the send buffer has it
V_RXF           .EQU    0xFFFFF180      ; a frame received, from byte 2, 380 words, as the queue's buffer has it
___wasm_trap_vector .EQU 0xFFFFF300     ; the routine that a wasm trap jumps to, mon_trap (lib.nasm)
___putc_vector  .EQU    0xFFFFF301      ; the routine that nice_putc and nice_print jump to, mon_putc
WASM_RAM        .EQU    0xFFFFF400      ; the words that the ROM's C code writes, from here
WASM_END        .EQU    0xFFFFFF00      ; up to below here, the I/O page, which the Makefile checks

PROGRAM         .EQU    0x8000          ; where a program is, above the ROM
VARS_WORDS      .EQU    0x1000          ; the words from 0xFFFFF000, the variables, which end a program's RAM
DEMO            .EQU    0x2000          ; the demo's words in the ROM, after their number
DEMO_MAX        .EQU    PROGRAM-DEMO    ; more words than fit from DEMO + 1 below the RAM
COLOR           .EQU    0x000FFF00      ; white on black, the color at the cold start
OUT_LINE        .EQU    1
OUT_SCREEN      .EQU    2
TABLE_VERSION   .EQU    0x00010000      ; what mon_version returns: 1.0
DUMP_WORDS      .EQU    32              ; the words that d shows without a count
ROW_WORDS       .EQU    4               ; the words of a row of d
DIS_ROWS        .EQU    20              ; the instructions that u shows without a count
PAGE            .EQU    24              ; the rows of a Page Up or Page Down
SCR_MAX         .EQU    0x7FFF          ; the largest display offset
SD_INIT         .EQU    0               ; the commands of SD_CSR
SD_RD           .EQU    1
SD_WR           .EQU    2
SD_BUSY         .EQU    0x01            ; the bits of its status
SD_READY        .EQU    0x08
SD_CHANGED      .EQU    0x10
ETH_ON          .EQU    0x01            ; the bits of ETH_CSR: enabled,
ETH_BUSY        .EQU    0x04            ; and a frame being sent
ETH_TXBUF       .EQU    0x100           ; the send buffer, in ETH_CHUNK
ARP_SLOTS       .EQU    4               ; the entries of the ARP cache
ARP_AGE         .EQU    60              ; the ticks of arp_tick an entry is kept, about a minute
ARP_TRIES       .EQU    3               ; the requests that arp_resolve sends
ARP_WAIT        .EQU    1000000         ; the microseconds it waits for a reply to each
DHCP_TRIES      .EQU    4               ; the DISCOVERs that i dhcp sends
DHCP_WAIT       .EQU    2000000         ; the microseconds it waits for each reply
DHCP_LEN        .EQU    342             ; the bytes of its frames: 14 Ethernet, 20 IP, 8 UDP, and 300 DHCP
DHCP_WORDS      .EQU    86              ; their words, with the 2 bytes before the frame
DHCP_DISCOVER   .EQU    1               ; the message types of option 53
DHCP_OFFER      .EQU    2
DHCP_REQUEST    .EQU    3
DHCP_ACK        .EQU    5
DHCP_NAK        .EQU    6

; The dispatch table (README.md, "The dispatch table"). Entries are only
; ever added at the end.
                JMP     mon_reset       ; 0 at 0x00
                JMP     mon_exit        ; 1 at 0x02
                JMP     mon_version     ; 2 at 0x04
                JMP     mon_putc        ; 3 at 0x06
                JMP     mon_out         ; 4 at 0x08
                JMP     scr_cls         ; 5 at 0x0A
                JMP     scr_moveto      ; 6 at 0x0C
                JMP     scr_getxy       ; 7 at 0x0E
                JMP     scr_color       ; 8 at 0x10

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
; without N, DUMP_WORDS.
cmd_dump
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

; u [ADDR] [N]: N instructions from ADDR, disassembled, a row each: the
; address, the instruction's words, 1 to 4, and its text, as nicedis.py
; shows it (README.md). Without ADDR, the instructions after the last
; shown; without N, DIS_ROWS. ADD @--R13, n, R15 and MOVE R15, target,
; with the same condition, no modifier, and n the words of the MOVE, are
; one row, CALL target, MOVE R15, @R13++ is RET, and the other
; pseudo-instructions of nice_cpu's ISA.md §10.1 are those of U_PSEUDO,
; the first that matches. R7 is the address of the instruction, R8 counts
; the rows left, R9 is the instruction word, R10 its kind, an index of
; DIS_KINDS, and R12 the address after it. The fields are at V_UF, their
; constants at V_UC, and the operands of the mnemonic at V_UNOPS.
cmd_dis
                MOVE    R1, R2
                CALL    _io_gethex      ; R1 the address, R2 its digits, R3 after it
                TST     R2
        ?!Z     MOVE    @V_UNEXT, R1
                MOVE    R1, R3
                CALL    _io_gethex      ; R1 the count
                TST     R2
        ?Z      MOVE    R1, DIS_ROWS
                MOVE[M] R8, R1
        ?Z      JMP     main
                MOVE    R7, @V_UNEXT
dis_row
                MOVE    R9, @R7
                ADD     R12, R7, 1
                AND     R1, R9, 0x0C000000
                CMP     R1, 0x0C000000
        ?Z      JMP     dis_ctrl
; An ALU or SHIFT instruction: its fields, and the constant words that
; follow it, in field order dest, s0, s1
                SHR     R1, R9, 14
                AND     @V_UF, R1, 0x7F
                SHR     R1, R9, 7
                AND     @V_UF+1, R1, 0x7F
                AND     @V_UF+2, R9, 0x7F
                MOVE    R11, 0
dis_const
                AND     R1, @V_UF[R11], 0x30
                CMP     R1, 0x30
        ?Z      MOVE    @V_UC[R11], @R12++
                ADD     R11, R11, 1
                CMP     R11, 3
        ?!Z     JMP     dis_const
; RET, the first half of a CALL, another pseudo-instruction, or another
; instruction
                AND     R1, R9, 0x0FFFFFFF  ; without the condition
                MOVE    R10, 2
                CMP     R1, 0x0003F680  ; MOVE R15, @R13++
        ?Z      JMP     dis_print
                CMP     R1, 0x0077580F  ; ADD @--R13, n, R15
        ?!Z     JMP     dis_find
                MOVE    R2, @R12        ; the word after it
                XOR     R3, R2, R9
                AND[M]  R0, R3, 0xF0000000
        ?!Z     JMP     dis_find        ; another condition
                AND     R3, R2, 0x0FFFC07F
                CMP     R3, 0x0003C000  ; MOVE R15, s0
        ?!Z     JMP     dis_find
                MOVE    R4, 1           ; the words of the MOVE
                SHR     R3, R2, 7
                AND     R3, R3, 0x30
                CMP     R3, 0x30
        ?Z      MOVE    R4, 2
                CMP     R4, @V_UC+1
        ?!Z     JMP     dis_find        ; n is not their number
                ADD     R12, R12, R4
                MOVE    R10, 3
                JMP     dis_print
; The first entry of U_PSEUDO whose mask and value match, kind 5 for the
; first, or kind 0, a plain instruction
dis_find
                MOVE    R10, 5
                MOVE    R2, U_PSEUDO
dis_find_next
                AND     R3, R1, @R2++   ; the mask
                CMP     R3, @R2++       ; the value
        ?Z      JMP     dis_print
                ADD     R2, R2, 3
                ADD     R10, R10, 1
                CMP     R10, 5+U_PSEUDOS
        ?!Z     JMP     dis_find_next
                MOVE    R10, 0
                JMP     dis_print
; A control instruction, which is reserved with a command past INT, a bit
; of 20..8 set, or a vector but for INT
dis_ctrl
                MOVE    R10, 1
                SHR     R1, R9, 21
                AND     R1, R1, 0x1F
                CMP     R1, 3
        ?!C     MOVE    R10, 4
                AND[M]  R0, R9, 0x001FFF00
        ?!Z     MOVE    R10, 4
                CMP     R1, 2
        ?Z      JMP     dis_print
                AND[M]  R0, R9, 0xFF
        ?!Z     MOVE    R10, 4
; The address, the words, blanks for the words that the instruction does
; not have, and the text of its kind
dis_print
                MOVE    R1, R7
                MOVE    R2, 8
                CALL    u_hex
                MOVE    R11, R7
dis_word
                CMP     R11, R12
        ?Z      JMP     dis_pad
                MOVE    R1, 0x20
                CALL    mon_putc
                MOVE    R1, @R11++
                MOVE    R2, 8
                CALL    u_hex
                JMP     dis_word
dis_pad         SUB     R1, R11, R7
                CMP     R1, 4
        ?Z      JMP     dis_text
                MOVE    R1, S_UBLANK
                CALL    _io_puts
                ADD     R11, R11, 1
                JMP     dis_pad
dis_text
                MOVE    R1, S_UGAP
                CALL    _io_puts
                JMP     @DIS_KINDS[R10]
; Kind 0, an ALU or SHIFT instruction, which is a .DAT if a field that its
; mnemonic does not use is not R0
dis_insn
                SHR     R1, R9, 21
                AND     R1, R1, 0xF     ; the opcode
                MOVE    R2, 3
                AND[M]  R0, R9, 0x08000000
        ?Z      MOVE    R2, @U_NOPS[R1]  ; an ALU instruction's
                MOVE    @V_UNOPS, R2
                MOVE    R3, 0
dis_unused
                CMP     R2, 3
        ?Z      JMP     dis_used
                OR      R3, R3, @V_UF[R2]
                ADD     R2, R2, 1
                JMP     dis_unused
dis_used
                TST     R3
        ?Z      JMP     dis_plain
                CALL    u_dat
                CALL    u_stmt
                CALL    u_unused
                JMP     dis_end
dis_plain
                CALL    u_stmt
                JMP     dis_end
; Kind 1, HALT, RTI, or INT, with its vector in decimal
dis_cmd         MOVE    R1, R9
                CALL    u_cond
                SHR     R1, R9, 21
                AND     R11, R1, 0x1F
                MOVE    R1, @U_CTRL[R11]
                CALL    _io_puts
                CMP     R11, 2
        ?!Z     JMP     dis_end
                MOVE    R1, 0x20
                CALL    mon_putc
                AND     R1, R9, 0xFF
                CALL    _io_putdec
                JMP     dis_end
; Kind 2, RET
dis_ret         MOVE    R1, R9
                CALL    u_cond
                MOVE    R1, S_URET
                CALL    _io_puts
                JMP     dis_end
; Kind 3, CALL, with the operand of the MOVE, the third word, whose
; constant is the fourth
dis_call
                MOVE    R1, R9
                CALL    u_cond
                MOVE    R1, S_UCALL
                CALL    _io_puts
                ADD     R1, R7, 2
                SHR     R1, @R1, 7
                AND     R1, R1, 0x7F
                ADD     R2, R7, 3
                MOVE    R2, @R2
                MOVE    R3, 0
                CALL    u_op
                JMP     dis_end
; Kind 4, a reserved control word
dis_rsvd
                CALL    u_dat
                MOVE    R1, S_URSVD
                CALL    _io_puts
                JMP     dis_end
; Kinds 5 and up, the pseudo-instruction of entry R10 - 5 of U_PSEUDO,
; with its fields, from its first, as u_stmt writes them
dis_pseudo
                MOVE    R1, R9
                CALL    u_cond
                SUB     R1, R10, 5
                SHL     R2, R1, 2
                ADD     R2, R2, R1
                ADD     R11, R2, U_PSEUDO+2  ; the name, the first field, and their number
                MOVE    R1, @R11++
                CALL    _io_puts
                MOVE    R10, @R11++
                ADD[M]  @V_UNOPS, R10, @R11
        ?Z      JMP     dis_end         ; NOP
                MOVE    R1, 0x20
                CALL    mon_putc
                CALL    u_stmt_op
; The end of the row, and the next instruction
dis_end         CALL    _io_crlf
                MOVE    R7, R12
                SUB[M]  R8, R8, 1
        ?!Z     JMP     dis_row
                MOVE    @V_UNEXT, R7
                JMP     main

; u_stmt: the condition, the mnemonic with its modifiers, and the operands
; of the ALU or SHIFT instruction R9. Uses R1-R6 and R10.
u_stmt
                MOVE    R1, R9
                CALL    u_cond
                SHR     R1, R9, 21
                AND     R1, R1, 0xF
                AND[M]  R0, R9, 0x08000000
        ?!Z     ADD     R1, R1, 16      ; the SHIFT names follow the ALU's
                MOVE    R1, @U_NAMES[R1]
                CALL    _io_puts
                AND[M]  R0, R9, 0x06000000
        ?Z      JMP     u_stmt_ops      ; no modifier
                MOVE    R1, 0x5B        ; [
                CALL    mon_putc
                AND[M]  R0, R9, 0x04000000
        ?!Z     MOVE    R1, 0x43        ; C
        ?!Z     CALL    mon_putc
                AND[M]  R0, R9, 0x02000000
        ?!Z     MOVE    R1, 0x4D        ; M
        ?!Z     CALL    mon_putc
                MOVE    R1, 0x5D        ; ]
                CALL    mon_putc
u_stmt_ops
                MOVE    R1, 0x20
                CALL    mon_putc
                MOVE    R10, 0
u_stmt_op
                MOVE    R1, @V_UF[R10]
                MOVE    R2, @V_UC[R10]
                MOVE    R3, 0
                TST     R10
        ?Z      MOVE    R3, 1           ; the dest
                CALL    u_op
                ADD     R10, R10, 1
                CMP     R10, @V_UNOPS
        ?Z      RET
                MOVE    R1, S_UCOMMA
                CALL    _io_puts
                JMP     u_stmt_op

; u_unused: the fields that the mnemonic does not use and that are not
; R0, by name, in brackets, as nicedis.py writes them after the .DAT.
; Uses R1-R6, R10, and R11.
u_unused
                MOVE    R1, S_UOPEN
                CALL    _io_puts
                MOVE    R10, @V_UNOPS
                MOVE    R11, 0          ; not 0 after the first
u_unused_f
                CMP     R10, 3
        ?Z      MOVE    R1, 0x29        ; )
        ?Z      JMP     mon_putc        ; which returns to the caller
                TST     @V_UF[R10]
        ?Z      JMP     u_unused_n
                TST     R11
        ?!Z     MOVE    R1, S_UCOMMA
        ?!Z     CALL    _io_puts
                MOVE    R11, 1
                MOVE    R1, @U_FIELDS[R10]
                CALL    _io_puts
                MOVE    R1, @V_UF[R10]
                MOVE    R2, @V_UC[R10]
                MOVE    R3, 0
                CALL    u_op
u_unused_n
                ADD     R10, R10, 1
                JMP     u_unused_f

; u_dat: .DAT, the words from R7 up to R12 in hex, and the ; of the
; comment that says what they would do. Uses R1-R6 and R11.
u_dat
                MOVE    R1, S_UDAT
                CALL    _io_puts
                MOVE    R11, R7
u_dat_word
                MOVE    R1, S_U0X
                CALL    _io_puts
                MOVE    R1, @R11++
                MOVE    R2, 8
                CALL    u_hex
                CMP     R11, R12
        ?Z      MOVE    R1, S_USEMI
        ?Z      JMP     _io_puts        ; which returns to the caller
                MOVE    R1, S_UCOMMA
                CALL    _io_puts
                JMP     u_dat_word

; u_cond: the condition of the instruction word R1 and a blank, or nothing
; for "always". Uses R1-R5.
u_cond
                SHR[M]  R5, R1, 28      ; NEG and SEL
        ?Z      RET
                MOVE    R1, 0x3F        ; ?
                CALL    mon_putc
                AND[M]  R0, R5, 8
        ?Z      JMP     u_cond_flag
                MOVE    R1, 0x21        ; !
                CALL    mon_putc
u_cond_flag
                AND     R1, R5, 7
                MOVE    R1, @S_UFLAGS[R1]
                CALL    mon_putc
                MOVE    R1, 0x20
                JMP     mon_putc        ; which returns to the caller

; u_op: the operand of the field R1, with its constant R2, in the syntax
; of nice_cpu's ISA.md §10.2, as nicedis.py writes it, the constant in
; lower-case hex without leading zeros. R3 is not 0 for a dest, whose
; mode 001 is Rx--, which bit 7 of R5 marks. Uses R1-R6.
u_op
                MOVE    R5, R1          ; the field
                MOVE    R6, R2          ; the constant
                TST     R3
        ?Z      JMP     u_op_at
                AND     R4, R1, 0x70
                CMP     R4, 0x10
        ?Z      OR      R5, R5, 0x80    ; Rx--
u_op_at
                AND[M]  R0, R5, 0x40
        ?Z      JMP     u_op_mode
                MOVE    R1, 0x40        ; @
                CALL    mon_putc
u_op_mode
                AND     R4, R5, 0x30
                CMP     R4, 0x30
        ?Z      JMP     u_op_const
                CMP     R4, 0x10
        ?!Z     JMP     u_op_reg
                AND[M]  R0, R5, 0x80
        ?!Z     JMP     u_op_reg
                MOVE    R1, S_UDEC      ; --Rx
                CALL    _io_puts
u_op_reg
                AND     R1, R5, 0xF
                CALL    u_reg
                AND     R4, R5, 0x30
                CMP     R4, 0x20
        ?Z      MOVE    R1, S_UINC      ; Rx++
        ?Z      JMP     _io_puts        ; which returns to the caller
                AND[M]  R0, R5, 0x80
        ?Z      RET
                MOVE    R1, S_UDEC      ; Rx--
                JMP     _io_puts
u_op_const
                MOVE    R1, S_U0X
                CALL    _io_puts
                PUSH    R5
                MOVE    R1, R6
                MOVE    R2, 1
                CALL    u_hex
                AND[M]  R1, @SP++, 0xF  ; the register
        ?Z      RET                     ; R0: the constant alone
                PUSH    R1
                MOVE    R1, 0x5B        ; [
                CALL    mon_putc
                POP     R1
                CALL    u_reg
                MOVE    R1, 0x5D        ; ]
                JMP     mon_putc

; u_reg: R and the number R1 in decimal. Uses R1-R4.
u_reg
                PUSH    R1
                MOVE    R1, 0x52        ; R
                CALL    mon_putc
                POP     R1
                JMP     _io_putdec      ; which returns to the caller

; u_hex: R1 in lower-case hex, with R2 digits, 1 to 8, or more if it needs
; them, and no other leading zeros. Uses R1-R6.
u_hex
                MOVE    R5, R1
                MOVE    R6, 8           ; the digits left
u_hex_skip
                CMP     R6, R2
        ?Z      JMP     u_hex_digit
                AND[M]  R0, R5, 0xF0000000
        ?!Z     JMP     u_hex_digit
                SHL     R5, R5, 4       ; a leading zero
                SUB     R6, R6, 1
                JMP     u_hex_skip
u_hex_digit
                ROL     R5, R5, 4       ; the top digit to the bottom
                AND     R1, R5, 0xF
                ADD     R1, R1, 0x30
                CMP     R1, 0x3A
        ?!C     ADD     R1, R1, 0x27    ; a to f
                CALL    mon_putc
                SUB[M]  R6, R6, 1
        ?!Z     JMP     u_hex_digit
                RET

; i [A.B.C.D | dhcp]: the Ethernet station's IP address (doc/SYSTEM.md,
; "The Ethernet station"), written from four decimal numbers of 0 to 255
; with dots between them, or from DHCP with the word dhcp, in either
; case, and shown, in decimal with dots. Without an address it is only
; shown. Blanks may come before and after the address, and anything else
; makes it no address, which is not written. R7 gathers the address, a
; byte at a time, and R8 counts the numbers left.
cmd_ip
                MOVE    R7, 0
                MOVE    R8, 4
ip_blank
                CMP     @R2, 0x20
        ?Z      ADD     R2, R2, 1
        ?Z      JMP     ip_blank
                TST     @R2
        ?Z      JMP     ip_show         ; no address
                OR      R1, @R2, 0x20
                SUB     R1, R1, 0x61
                CMP     R1, 26
        ?C      JMP     ip_word         ; a letter
ip_num          MOVE    R4, 0           ; the number
                MOVE    R5, 0           ; and its digits
ip_digit
                SUB     R3, @R2, 0x30
                CMP     R3, 10
        ?!C     JMP     ip_end          ; no digit
                SHL     R1, R4, 3       ; R4 is 10 * R4 + the digit
                SHL     R4, R4, 1
                ADD     R4, R4, R1
                ADD     R4, R4, R3
                CMP     R4, 256
        ?!C     JMP     ip_bad
                ADD     R5, R5, 1
                ADD     R2, R2, 1
                JMP     ip_digit
ip_end          TST     R5
        ?Z      JMP     ip_bad          ; a number without digits
                SHL     R7, R7, 8
                OR      R7, R7, R4
                SUB[M]  R8, R8, 1
        ?Z      JMP     ip_last
                CMP     @R2, 0x2E       ; .
        ?!Z     JMP     ip_bad
                ADD     R2, R2, 1
                JMP     ip_num
ip_last         CMP     @R2, 0x20       ; blanks, then the end of the line
        ?Z      ADD     R2, R2, 1
        ?Z      JMP     ip_last
                TST     @R2
        ?!Z     JMP     ip_bad
                MOVE    @E_IP, R7
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

; i dhcp: the IP address from a DHCP server (RFC 2131), through the port
; for Ethernet frames, which it enables, and disables at the end. It
; broadcasts a DISCOVER, waits DHCP_WAIT microseconds for an OFFER, then
; broadcasts a REQUEST of the address offered, from the server that
; offered it, and waits as long for its ACK; a reply without an address
; is passed over. A timeout or a NAK starts again from the DISCOVER, up
; to DHCP_TRIES times, with the same transaction, whose number is the
; microseconds at the start, XOR the low word of the MAC address. The
; ACK's address is written to E_IP, which breaks a host's connection over
; TCP, as a write of i does, and shown, with the mask, the gateway, and
; the server. Without an ACK, i says so and leaves E_IP alone. The lease
; is not renewed. R7 counts the tries left.
ip_dhcp
                CALL    eth_on
                MOVE    R1, @io.us
                XOR     @V_XID, R1, @E_MACL
                MOVE    R7, DHCP_TRIES
dhcp_try
                MOVE    R1, DHCP_DISCOVER
                CALL    dhcp_send
                MOVE    R1, DHCP_OFFER
                CALL    dhcp_wait
                CMP     R1, DHCP_OFFER
        ?!Z     JMP     dhcp_again
                MOVE    R1, DHCP_REQUEST
                CALL    dhcp_send
                MOVE    R1, DHCP_ACK
                CALL    dhcp_wait
                CMP     R1, DHCP_ACK
        ?Z      JMP     dhcp_bound
dhcp_again
                SUB[M]  R7, R7, 1
        ?!Z     JMP     dhcp_try
                MOVE    @ETH_CSR, 0
                MOVE    R1, S_NODHCP
                CALL    puts_crlf
                JMP     main
dhcp_bound
                MOVE    @ETH_CSR, 0
                MOVE    @E_IP, @V_DIP
                MOVE    R1, S_IP
                MOVE    R2, @E_IP
                CALL    show_ip
                MOVE    R1, S_MASK
                MOVE    R2, @V_DMASK
                CALL    show_ip
                MOVE    R1, S_GW
                MOVE    R2, @V_DGW
                CALL    show_ip
                MOVE    R1, S_DSRV
                MOVE    R2, @V_DSRV
                CALL    show_ip
                JMP     main

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
; the line.
cmd_load
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
                MOVE[M] R1, @RAM_WORDS
        ?Z      MOVE    R1, SCREEN+VARS_WORDS  ; no limit
                SUB     @V_PEND, R1, VARS_WORDS
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
; The end of a line: an empty one ends the load, one of blanks only is
; passed over, and another is parsed, and its word written
load_end
                MOVE    @R6, 0
                CMP     R6, V_LINE
        ?Z      JMP     load_done
                ADD     R11, R11, 1
                CMP     R6, V_LINE+LINE_MAX+1
        ?Z      JMP     load_bad        ; longer than LINE_MAX
                MOVE    R1, V_LINE
                CALL    _io_gethex      ; R1 the address, R2 its digits, R3 after it
                TST     R2
        ?!Z     JMP     load_addr
                TST     @R3
        ?Z      JMP     load_line       ; blanks only
load_addr
                SUB     R4, R2, 1
                CMP     R4, 8
        ?!C     JMP     load_bad        ; no digit, or more than 8
                CMP     R1, PROGRAM
        ?C      JMP     load_bad        ; in the ROM
                CMP     R1, @V_PEND
        ?!C     JMP     load_bad        ; the variables, or past the RAM
                MOVE    R6, R1
                MOVE    R1, R3
                CALL    _io_gethex      ; R1 the word
                SUB     R4, R2, 1
                CMP     R4, 8
        ?!C     JMP     load_bad
load_tail
                CMP     @R3, 0x20
        ?Z      ADD     R3, R3, 1
        ?Z      JMP     load_tail
                TST     @R3
        ?!Z     JMP     load_bad        ; more after the word
                MOVE    @R6, R1
                ADD     R8, R8, 1
                CMP     R6, R9
        ?C      MOVE    R9, R6          ; a lower address
                CMP     R10, R6
        ?C      MOVE    R10, R6         ; a higher one
                JMP     load_line
load_bad
                ADD     R12, R12, 1
                CMP     R12, 1
        ?Z      MOVE    @V_LBAD, R11
                JMP     load_line
; The end of the load: the row blank again, the outputs back, the words
; written, and the lines skipped
load_done
                CALL    load_row
                MOVE    @V_OUT, @V_LOUT
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

; sd [SLOT] LBA: the sector LBA of the card in SLOT, both in hex, read with
; sd_read into V_SECTOR and shown as 32 rows of 16 bytes: the offset of
; the row, the bytes in hex, and the bytes as text, with a dot for a byte
; outside 0x20 to 0x7E. Without SLOT, the slot that SD_SELECT holds, which
; is 0 after reset and the slot of the last sd_init after it. The card is
; started up with sd_init when the slot is not the selected one, or its
; card is not ready, or has changed since its last Init, so that a second
; sd on a slot costs no Init. A SLOT at or above SD_SLOTS is no slot. An
; error of the controller is shown with its number and its meaning. The
; command is the letter s, which main finds, and a d after it. R7 is the
; slot, R8 the sector, R9 the offset of the row, and R10 the bytes left in
; the row.
cmd_sd
                MOVE    R1, @R2++
                OR      R1, R1, 0x20    ; D as d
                CMP     R1, 0x64        ; d
        ?!Z     JMP     unknown
                CMP     @R2, 0x20
        ?Z      JMP     sd_args
                TST     @R2
        ?!Z     JMP     unknown         ; another letter, such as sdx
sd_args
                MOVE    R1, R2
                CALL    _io_gethex      ; R1 the first number, R2 its digits, R3 after it
                SUB     R4, R2, 1
                CMP     R4, 8
        ?!C     JMP     sd_bad          ; no digit, or more than 8
                MOVE    R8, R1
                MOVE    R7, @SD_SELECT
                MOVE    R1, R3
                CALL    _io_gethex      ; a second number
                TST     R2
        ?Z      JMP     sd_tail
                SUB     R4, R2, 1
                CMP     R4, 8
        ?!C     JMP     sd_bad
                MOVE    R7, R8          ; the first was the slot
                MOVE    R8, R1
                MOVE    R1, R3
                CALL    _io_gethex      ; for the blanks after it
                TST     R2
        ?!Z     JMP     sd_bad          ; a third number
sd_tail
                TST     @R3
        ?!Z     JMP     sd_bad          ; more after the numbers
                CMP     R7, @SD_SLOTS
        ?!C     JMP     sd_noslot
                CALL    sd_wait
                CMP     R7, @SD_SELECT
        ?!Z     JMP     sd_start
                AND     R1, @SD_CSR, SD_READY+SD_CHANGED
                CMP     R1, SD_READY
        ?Z      JMP     sd_ready
sd_start
                MOVE    R1, R7
                CALL    sd_init
                TST     R1
        ?!Z     JMP     sd_fail
sd_ready
                MOVE    R1, R8
                MOVE    R2, V_SECTOR
                CALL    sd_read
                TST     R1
        ?!Z     JMP     sd_fail
                MOVE    R1, S_SLOT
                CALL    _io_puts
                MOVE    R1, R7
                CALL    _io_putdec
                MOVE    R1, S_SECTOR
                CALL    _io_puts
                MOVE    R1, R8
                CALL    _io_puthex
                CALL    _io_crlf
                MOVE    R9, 0
sd_row
                SHR     R1, R9, 8       ; the offset, in three digits
                CALL    mac_digit
                SHR     R1, R9, 4
                CALL    mac_digit
                MOVE    R1, R9
                CALL    mac_digit
                MOVE    R1, 0x20
                CALL    mon_putc
                MOVE    R10, 16
sd_hex
                MOVE    R1, 0x20
                CALL    mon_putc
                ADD     R1, R9, 16
                SUB     R1, R1, R10
                CALL    sd_byte
                PUSH    R1
                SHR     R1, R1, 4
                CALL    mac_digit
                POP     R1
                CALL    mac_digit
                SUB[M]  R10, R10, 1
        ?!Z     JMP     sd_hex
                MOVE    R1, S_UGAP
                CALL    _io_puts
                MOVE    R10, 16
sd_text
                ADD     R1, R9, 16
                SUB     R1, R1, R10
                CALL    sd_byte
                CMP     R1, 0x20
        ?C      MOVE    R1, 0x2E        ; a control code as a dot
                CMP     R1, 0x7F
        ?!C     MOVE    R1, 0x2E        ; and 0x7F and up
                CALL    mon_putc
                SUB[M]  R10, R10, 1
        ?!Z     JMP     sd_text
                CALL    _io_crlf
                ADD     R9, R9, 16
                CMP     R9, 512
        ?!Z     JMP     sd_row
                JMP     main
; An error of the controller, R1 its negative: the number, the slot, and
; the meaning, with the last sector after error 7
sd_fail
                SUB     R8, R0, R1      ; the error
                MOVE    R1, S_SDERR
                CALL    _io_puts
                MOVE    R1, R8
                CALL    _io_putdec
                MOVE    R1, S_INSLOT
                CALL    _io_puts
                MOVE    R1, R7
                CALL    _io_putdec
                MOVE    R1, S_UCOMMA
                CALL    _io_puts
                SUB     R1, R8, 1
                CMP     R1, SD_ERRS
        ?!C     JMP     sd_fail_end     ; an error without a meaning here
                ADD     R1, R1, SD_ERRORS
                MOVE    R1, @R1
                CALL    _io_puts
                CMP     R8, 7
        ?!Z     JMP     sd_fail_end
                MOVE    R1, @SD_LAST
                CALL    _io_puthex
sd_fail_end
                CALL    _io_crlf
                JMP     main
sd_noslot
                MOVE    R1, S_NOSLOT
                CALL    _io_puts
                MOVE    R1, R7
                CALL    _io_putdec
                MOVE    R1, S_SLOTS
                CALL    _io_puts
                MOVE    R1, @SD_SLOTS
                CALL    _io_putdec
                CALL    _io_crlf
                JMP     main
sd_bad
                MOVE    R1, S_BADSD
                CALL    puts_crlf
                JMP     main

; sd_byte: R1 = the byte R1 of the sector at V_SECTOR, 4 bytes a word,
; little-endian. Uses R1 and R2.
sd_byte
                SHR     R2, R1, 2
                ADD     R2, R2, V_SECTOR
                AND     R1, R1, 3
                SHL     R1, R1, 3
                SHR     R1, @R2, R1
                AND     R1, R1, 0xFF
                RET

; The sector routines, the ROM's own, with no entries in the dispatch table
; (doc/SDCARD.md, "The ROM"). They follow the C ABI, wait for busy before
; the command and after it, as nice_cpu's SYSTEM.md §5 asks, and return 0,
; or the negative of SD_ERROR. sd_init selects the slot and starts its card
; up; sd_read and sd_write use the slot that is selected, which is the
; slot of the last sd_init unless a program has changed it. Their buffer is
; 128 words in RAM, 4 bytes a word, little-endian, as the controller's is,
; and is copied through SD_CHUNK and SD_BUF0-SD_BUF7, so that no sector of
; theirs is left for another to rely on in the controller's buffer.

; sd_init: R1 the slot, selected, and its card started up. Uses R1.
sd_init
                CALL    sd_wait
                MOVE    @SD_SELECT, R1
                MOVE    @SD_CSR, SD_INIT
                JMP     sd_end

; sd_read: the sector R1 into the 128 words at R2. Uses R1-R4.
sd_read
                CALL    sd_wait
                MOVE    @SD_LBA, R1
                MOVE    @SD_CSR, SD_RD
                CALL    sd_wait
                MOVE[M] R1, @SD_ERROR
        ?!Z     JMP     sd_neg
                MOVE    R3, 0           ; the chunk
sd_read_chunk
                MOVE    @SD_CHUNK, R3
                MOVE    R4, SD_BUF
sd_read_word
                MOVE    @R2++, @R4++
                CMP     R4, SD_BUF+8
        ?!Z     JMP     sd_read_word
                ADD     R3, R3, 1
                CMP     R3, 16
        ?!Z     JMP     sd_read_chunk
                RET                     ; R1 is 0

; sd_write: the 128 words at R2 to the sector R1. Uses R1-R4.
sd_write
                CALL    sd_wait         ; as the buffer takes no write while busy
                MOVE    R3, 0
sd_write_chunk
                MOVE    @SD_CHUNK, R3
                MOVE    R4, SD_BUF
sd_write_word
                MOVE    @R4++, @R2++
                CMP     R4, SD_BUF+8
        ?!Z     JMP     sd_write_word
                ADD     R3, R3, 1
                CMP     R3, 16
        ?!Z     JMP     sd_write_chunk
                MOVE    @SD_LBA, R1
                MOVE    @SD_CSR, SD_WR
; sd_end: the end of a command, R1 = 0, or the negative of SD_ERROR
sd_end
                CALL    sd_wait
                MOVE[M] R1, @SD_ERROR
        ?Z      RET
sd_neg
                SUB     R1, R0, R1
                RET

; sd_wait: until busy is 0, which every command reaches, as the controller
; has a timeout for each step. Uses no register.
sd_wait
                AND[M]  R0, @SD_CSR, SD_BUSY
        ?!Z     JMP     sd_wait
                RET

; The frame routines, the ROM's own, with no entries in the dispatch table
; (README.md, "The network"). They follow the C ABI, and drive the port for
; Ethernet frames of nice_cpu's SYSTEM.md §7. A frame is in RAM as the
; port's buffers have it: from byte 2 of its buffer, 4 bytes a word,
; big-endian, so that word n of the RAM is word n of the port's buffer,
; and the words of nice_cpu's SYSTEM.md §7 are where its table says.

; eth_on: the port enabled, with its queue emptied, so that no frame from
; before comes. Uses no register.
eth_on
                MOVE    @ETH_CSR, 0
                MOVE    @ETH_CSR, ETH_ON
                RET

; eth_recv: the frame at the head of the queue copied to the 380 words at
; R1, and released. R1 = its length in bytes, or 0 when the queue is
; empty. Uses R1-R5.
eth_recv
                MOVE[M] R2, @ETH_RX_LEN
        ?Z      MOVE    R1, 0
        ?Z      RET
                ADD     R3, R2, 5       ; the words, with the 2 bytes before the frame
                SHR     R3, R3, 2
                MOVE    R4, 0           ; the chunk, of the queue's buffer
eth_recv_chunk
                MOVE    @ETH_CHUNK, R4
                MOVE    R5, ETH_BUF
eth_recv_word
                MOVE    @R1++, @R5++
                SUB[M]  R3, R3, 1
        ?Z      JMP     eth_recv_end
                CMP     R5, ETH_BUF+8
        ?!Z     JMP     eth_recv_word
                ADD     R4, R4, 1
                JMP     eth_recv_chunk
eth_recv_end
                MOVE    @ETH_RX_LEN, 0  ; the frame released
                MOVE    R1, R2
                RET

; eth_send: the frame at R1, R2 bytes long, 14 to 1514, copied to the send
; buffer and sent, after the frame before it has gone. The port must be
; enabled, or nothing is sent. Uses R1-R5.
eth_send
                AND[M]  R0, @ETH_CSR, ETH_BUSY
        ?!Z     JMP     eth_send        ; as the send buffer takes no write while busy
                ADD     R3, R2, 5
                SHR     R3, R3, 2
                MOVE    R4, ETH_TXBUF   ; chunk 0 of the send buffer
eth_send_chunk
                MOVE    @ETH_CHUNK, R4
                MOVE    R5, ETH_BUF
eth_send_word
                MOVE    @R5++, @R1++
                SUB[M]  R3, R3, 1
        ?Z      JMP     eth_send_go
                CMP     R5, ETH_BUF+8
        ?!Z     JMP     eth_send_word
                ADD     R4, R4, 1
                JMP     eth_send_chunk
eth_send_go
                MOVE    @ETH_TX_LEN, R2
                RET

; eth_head: the Ethernet header of the frame at R1: to everyone, from the
; station's MAC address, with the EtherType R2. Uses R3 and R4.
eth_head
                MOVE    @R1, 0xFFFF
                MOVE    @1[R1], 0xFFFFFFFF
                SHL     R3, @E_MACH, 16
                SHR     R4, @E_MACL, 16
                OR      @2[R1], R3, R4
                SHL     R3, @E_MACL, 16
                OR      @3[R1], R3, R2
                RET

; ip_csum: the checksum of the IPv4 header of the frame at R1, the 5
; words 4 to 8, written to bits 15..0 of word 6: the ones' complement of
; the ones' complement sum of its halves. Uses R2-R6.
ip_csum
                AND     @6[R1], @6[R1], 0xFFFF0000
                ADD     R2, R1, 4
                MOVE    R3, 5
                MOVE    R4, 0
ip_csum_word
                MOVE    R5, @R2++
                SHR     R6, R5, 16
                ADD     R4, R4, R6
                AND     R5, R5, 0xFFFF
                ADD     R4, R4, R5
                SUB[M]  R3, R3, 1
        ?!Z     JMP     ip_csum_word
                SHR     R5, R4, 16      ; the carries added back in, twice
                AND     R4, R4, 0xFFFF
                ADD     R4, R4, R5
                SHR     R5, R4, 16
                AND     R4, R4, 0xFFFF
                ADD     R4, R4, R5
                XOR     R4, R4, 0xFFFF
                OR      @6[R1], @6[R1], R4
                RET

; rx_byte: R1 = the byte at R1 of V_RXF, counted from the start of the
; buffer, 2 bytes before the frame. Uses R1 and R2.
rx_byte
                SHR     R2, R1, 2
                AND     R1, R1, 3
                XOR     R1, R1, 3
                SHL     R1, R1, 3       ; 8 times the bytes after it in the word
                SHR     R1, @V_RXF[R2], R1
                AND     R1, R1, 0xFF
                RET

; rx_long: R1 = the 4 bytes from the byte at R1 of V_RXF, big-endian,
; whichever byte of a word they start at. Uses R1-R3.
rx_long
                SHR     R2, R1, 2
                AND     R1, R1, 3
                SHL     R1, R1, 3
                SHL     R3, @V_RXF[R2], R1
                SUB     R1, 32, R1      ; a shift of 32 gives 0
                ADD     R2, R2, 1
                SHR     R1, @V_RXF[R2], R1
                OR      R1, R1, R3
                RET

; The ARP cache: ARP_SLOTS entries at V_ARP, which the cold start empties.
; arp_resolve gives the MAC address of an IP address, from the cache, or
; else from a request, broadcast up to ARP_TRIES times, and the reply,
; which goes into the cache. An entry is kept ARP_AGE ticks of arp_tick,
; about a minute, and a new one takes the entry of its IP address, or else
; the next in turn. The port must be enabled. The frames received while
; arp_resolve waits that are no ARP reply are released unread.

; arp_resolve: R1 an IP address, not 0. R1 = 0, R2 the MAC address's first
; two bytes, as E_MACH has them, and R3 its last four, as E_MACL has
; them; or R1 = -1 when no reply came. Uses R1-R6, and R7-R9 across the
; calls, saved.
arp_resolve
                PUSH    R7
                PUSH    R8
                PUSH    R9
                MOVE    R7, R1          ; the IP address
                MOVE    R8, ARP_TRIES   ; the requests left
arp_look
                MOVE    R1, R7
                CALL    arp_find
                TST     R1
        ?!Z     JMP     arp_found
                TST     R8
        ?Z      JMP     arp_none
                SUB     R8, R8, 1
                MOVE    R1, R7
                CALL    arp_request
                MOVE    R9, @io.us      ; when it was sent
arp_listen
                MOVE    R1, V_RXF
                CALL    eth_recv
                TST     R1
        ?!Z     CALL    arp_take
                MOVE    R1, R7
                CALL    arp_find
                TST     R1
        ?!Z     JMP     arp_found
                SUB     R1, @io.us, R9
                CMP     R1, ARP_WAIT
        ?C      JMP     arp_listen
                JMP     arp_look
arp_found
                MOVE    R2, @1[R1]
                MOVE    R3, @2[R1]
                MOVE    R1, 0
                JMP     arp_end
arp_none
                MOVE    R1, -1
arp_end
                POP     R9
                POP     R8
                POP     R7
                RET

; arp_find: R1 = the entry of the IP address R1, if it is younger than
; ARP_AGE, or 0. Uses R1-R4.
arp_find
                MOVE[M] R3, R1
        ?Z      RET                     ; 0, which marks no entry
                CALL    arp_tick
                MOVE    R4, V_ARP
arp_find_next
                CMP     @R4, R3
        ?!Z     JMP     arp_find_skip
                SUB     R2, R1, @3[R4]
                CMP     R2, ARP_AGE
        ?C      MOVE    R1, R4
        ?C      RET
arp_find_skip
                ADD     R4, R4, 4
                CMP     R4, V_ARP+4*ARP_SLOTS
        ?!Z     JMP     arp_find_next
                MOVE    R1, 0
                RET

; arp_take: the frame of R1 bytes at V_RXF learned, if it is an ARP reply,
; for Ethernet and IPv4, whoever it is to. Uses R1-R6.
arp_take
                CMP     R1, 42
        ?C      RET                     ; too short
                AND     R2, @V_RXF+3, 0xFFFF
                CMP     R2, 0x0806
        ?!Z     RET
                CMP     @V_RXF+4, 0x00010800  ; Ethernet, IPv4
        ?!Z     RET
                CMP     @V_RXF+5, 0x06040002  ; their lengths, and a reply
        ?!Z     RET
                SHL     R1, @V_RXF+7, 16  ; the sender's IP address
                SHR     R2, @V_RXF+8, 16
                OR      R1, R1, R2
                SHR     R2, @V_RXF+6, 16  ; and its MAC address
                SHL     R3, @V_RXF+6, 16
                SHR     R4, @V_RXF+7, 16
                OR      R3, R3, R4
; arp_learn: the IP address R1 at the MAC address R2 and R3 into the
; cache, at the time of now. Uses R1-R6.
arp_learn
                MOVE    R4, V_ARP
arp_learn_same
                CMP     @R4, R1
        ?Z      JMP     arp_learn_put
                ADD     R4, R4, 4
                CMP     R4, V_ARP+4*ARP_SLOTS
        ?!Z     JMP     arp_learn_same
                MOVE    R4, @V_ARPNEXT  ; the next entry in turn
                ADD     R5, R4, 4
                AND     @V_ARPNEXT, R5, 4*ARP_SLOTS-1
                ADD     R4, R4, V_ARP
arp_learn_put
                MOVE    @R4++, R1
                MOVE    @R4++, R2
                MOVE    @R4++, R3
                MOVE    R6, R4
                CALL    arp_tick
                MOVE    @R6, R1
                RET

; arp_tick: R1 = the time in units of 2^20 microseconds, about a second,
; from the 64 bits of the microsecond counter, so that it wraps after
; 4000 years. Uses R1 and R2.
arp_tick
                SHR     R1, @io.us, 20  ; which takes the snapshot of TIME_HI
                SHL     R2, @TIME_HI, 12
                OR      R1, R1, R2
                RET

; arp_request: a request for the IP address R1 broadcast, from E_IP and the
; station's MAC address. Uses R1-R6.
arp_request
                MOVE    R6, R1
                MOVE    R1, V_TXF
                MOVE    R2, 0x0806
                CALL    eth_head
                MOVE    @V_TXF+4, 0x00010800  ; Ethernet, IPv4
                MOVE    @V_TXF+5, 0x06040001  ; their lengths, and a request
                MOVE    @V_TXF+6, @V_TXF+2  ; the sender's MAC address
                SHL     R3, @E_MACL, 16
                SHR     R4, @E_IP, 16
                OR      @V_TXF+7, R3, R4  ; and its IP address
                SHL     @V_TXF+8, @E_IP, 16  ; the target's MAC address, 0
                MOVE    @V_TXF+9, 0
                MOVE    @V_TXF+10, R6
                MOVE    R1, V_TXF
                MOVE    R2, 42
                JMP     eth_send        ; which returns to the caller

; The frames of i dhcp (RFC 2131 and RFC 2132): a DISCOVER or a REQUEST,
; broadcast from 0.0.0.0 port 68 to port 67, with the broadcast flag set,
; as the station has no address yet, and padded to the 300 bytes of a
; BOOTP message (RFC 1542). The UDP checksum is 0, none, as IPv4 allows.
; With the 2 bytes before the frame, the fields fall on words: the IP
; header at 4, the UDP header at 9, the message at 11, its transaction at
; 12, the address offered at 15, the client's MAC address at 18, the
; magic cookie at 70, and the options from 71, which are written a word at
; a time: 53, the message type; for a REQUEST, 50, the address asked for,
; and 54, the server; 55, the options asked for, 1 the mask, 3 the gateway,
; and 6 the DNS servers; and 255, the end.

; dhcp_send: a message of the type R1, DHCP_DISCOVER, or DHCP_REQUEST of
; the address V_DIP from the server V_DSRV, with the transaction V_XID.
; Uses R1-R6.
dhcp_send
                MOVE    R6, R1
                MOVE    R1, V_TXF
                MOVE    R2, DHCP_WORDS
dhcp_zero
                MOVE    @R1++, 0
                SUB[M]  R2, R2, 1
        ?!Z     JMP     dhcp_zero
                MOVE    R1, V_TXF
                MOVE    R2, 0x0800
                CALL    eth_head
                MOVE    @V_TXF+4, 0x45000000+DHCP_LEN-14  ; IPv4, a header of 5 words, and the length
                MOVE    @V_TXF+6, 0x40110000  ; the TTL 64, UDP
                MOVE    @V_TXF+8, 0xFFFFFFFF  ; to everyone
                MOVE    @V_TXF+9, 0x00440043  ; from port 68 to 67
                MOVE    @V_TXF+10, 0x10000*DHCP_LEN-0x10000*34  ; the UDP length, and checksum 0
                MOVE    @V_TXF+11, 0x01010600  ; a request, Ethernet, 6 bytes of MAC address
                MOVE    @V_TXF+12, @V_XID
                MOVE    @V_TXF+13, 0x8000  ; broadcast
                MOVE    @V_TXF+18, @V_TXF+2  ; the MAC address
                SHL     @V_TXF+19, @E_MACL, 16
                MOVE    @V_TXF+70, 0x63825363
                CMP     R6, DHCP_REQUEST
        ?Z      JMP     dhcp_req
                MOVE    @V_TXF+71, 0x35010137  ; 53 DISCOVER, and 55
                MOVE    @V_TXF+72, 0x03010306
                MOVE    @V_TXF+73, 0xFF000000
                JMP     dhcp_go
dhcp_req
                MOVE    @V_TXF+71, 0x35010332  ; 53 REQUEST, and 50
                MOVE    R1, @V_DIP
                MOVE    R2, @V_DSRV
                SHR     R3, R1, 8
                OR      @V_TXF+72, R3, 0x04000000
                SHL     R3, R1, 24
                SHR     R4, R2, 24
                OR      R3, R3, R4
                OR      @V_TXF+73, R3, 0x00360400  ; and 54
                SHL     R3, R2, 8
                OR      @V_TXF+74, R3, 0x37  ; and 55
                MOVE    @V_TXF+75, 0x03010306
                MOVE    @V_TXF+76, 0xFF000000
dhcp_go
                MOVE    R1, V_TXF
                CALL    ip_csum
                MOVE    R1, V_TXF
                MOVE    R2, DHCP_LEN
                JMP     eth_send        ; which returns to the caller

; dhcp_wait: the reply of the type R1, DHCP_OFFER or DHCP_ACK, to the
; transaction V_XID, within DHCP_WAIT microseconds. R1 = its type, or
; DHCP_NAK when an ACK is waited for and a NAK comes, or 0 when none came.
; The address, the server, the mask, and the gateway of the reply that
; is waited for are copied to V_DIP, V_DSRV, V_DMASK, and V_DGW. A reply
; of the type without an address is passed over, so that the station's
; address is never made 0. The other frames are released unread. Uses
; R1-R6, and R7 and R8 across the calls, saved.
dhcp_wait
                PUSH    R7
                PUSH    R8
                MOVE    R7, R1
                MOVE    R8, @io.us      ; the start
dhcp_listen
                MOVE    R1, V_RXF
                CALL    eth_recv
                TST     R1
        ?Z      JMP     dhcp_time
                CALL    dhcp_parse
                CMP     R1, R7
        ?Z      JMP     dhcp_got
                CMP     R1, DHCP_NAK
        ?!Z     JMP     dhcp_time
                CMP     R7, DHCP_ACK
        ?Z      JMP     dhcp_wait_end   ; a NAK, R1
dhcp_time
                SUB     R1, @io.us, R8
                CMP     R1, DHCP_WAIT
        ?C      JMP     dhcp_listen
                MOVE    R1, 0
                JMP     dhcp_wait_end
dhcp_got
                TST     @V_PIP
        ?Z      JMP     dhcp_time       ; no address: passed over
                MOVE    @V_DIP, @V_PIP
                MOVE    @V_DSRV, @V_PSRV
                MOVE    @V_DMASK, @V_PMASK
                MOVE    @V_DGW, @V_PGW
dhcp_wait_end
                POP     R8
                POP     R7
                RET

; dhcp_parse: the frame of R1 bytes at V_RXF, if it is a DHCP reply to the
; transaction V_XID: an IPv4 packet with a header of 5 words, UDP from port
; 67 to 68, a BOOTP reply, and the magic cookie. Its checksums are not
; checked, as the FCS was. R1 = the message type of option 53, or 0 when
; it is no reply of ours or has no type, and V_PIP, V_PSRV, V_PMASK, and
; V_PGW are its address, and the options 54, 1, and 3, the first address
; of each, or 0 without them. The options are walked from byte 284 of the
; buffer up to 255, or the end of the frame, R8, the byte after its last;
; R7 is the option, and R5 the type. Uses R1-R6, and R7 and R8 across the
; calls, saved.
dhcp_parse
                PUSH    R7
                PUSH    R8
                ADD     R8, R1, 2
                MOVE    R5, 0
                CMP     R1, 282         ; up to the cookie
        ?C      JMP     dhcp_parse_end
                AND     R2, @V_RXF+3, 0xFFFF
                CMP     R2, 0x0800
        ?!Z     JMP     dhcp_parse_end
                SHR     R2, @V_RXF+4, 24
                CMP     R2, 0x45
        ?!Z     JMP     dhcp_parse_end
                SHR     R2, @V_RXF+6, 16
                AND     R2, R2, 0xFF
                CMP     R2, 17          ; UDP
        ?!Z     JMP     dhcp_parse_end
                CMP     @V_RXF+9, 0x00430044
        ?!Z     JMP     dhcp_parse_end
                SHR     R2, @V_RXF+11, 24
                CMP     R2, 2           ; a reply
        ?!Z     JMP     dhcp_parse_end
                CMP     @V_RXF+12, @V_XID
        ?!Z     JMP     dhcp_parse_end
                CMP     @V_RXF+70, 0x63825363
        ?!Z     JMP     dhcp_parse_end
                MOVE    @V_PIP, @V_RXF+15
                MOVE    @V_PSRV, 0
                MOVE    @V_PMASK, 0
                MOVE    @V_PGW, 0
                MOVE    R7, 284
dhcp_opt
                CMP     R7, R8
        ?!C     JMP     dhcp_parse_end  ; at the end of the frame
                MOVE    R1, R7
                CALL    rx_byte
                MOVE[M] R6, R1          ; the option's code
        ?Z      ADD     R7, R7, 1       ; a pad
        ?Z      JMP     dhcp_opt
                CMP     R6, 255
        ?Z      JMP     dhcp_parse_end
                ADD     R1, R7, 1
                CMP     R1, R8
        ?!C     JMP     dhcp_parse_end  ; no length
                CALL    rx_byte
                MOVE    R4, R1          ; the length
                ADD     R1, R7, 2       ; the value
                ADD     R7, R1, R4      ; the next option
                CMP     R8, R7
        ?C      JMP     dhcp_parse_end  ; past the end
                TST     R4
        ?Z      JMP     dhcp_opt
                CMP     R6, 53
        ?Z      JMP     dhcp_type
                CMP     R4, 4
        ?C      JMP     dhcp_opt        ; too short for an address
                CMP     R6, 1
        ?Z      MOVE    R6, V_PMASK
        ?Z      JMP     dhcp_addr
                CMP     R6, 3
        ?Z      MOVE    R6, V_PGW
        ?Z      JMP     dhcp_addr
                CMP     R6, 54
        ?!Z     JMP     dhcp_opt
                MOVE    R6, V_PSRV
dhcp_addr
                CALL    rx_long
                MOVE    @R6, R1
                JMP     dhcp_opt
dhcp_type
                CALL    rx_byte
                MOVE    R5, R1
                JMP     dhcp_opt
dhcp_parse_end
                MOVE    R1, R5
                POP     R8
                POP     R7
                RET

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
S_NODHCP
                .ASCII_L 'No answer from a DHCP server'
S_MASK          .ASCII_L 'Mask '
S_GW            .ASCII_L 'Gateway '
S_DSRV          .ASCII_L 'DHCP server '
S_BADMAC
                .ASCII_L 'Not a MAC address: six bytes in hex with colons, the first one even'
S_BADSD         .ASCII_L 'sd [SLOT] LBA: the slot and the sector in hex, such as sd 0 800'
S_NOSLOT
                .ASCII_L 'No SD slot '
S_SLOTS         .ASCII_L '; the SD slots of this system: '
S_SLOT          .ASCII_L 'Slot '
S_SECTOR
                .ASCII_L ', sector '
S_SDERR         .ASCII_L 'SD error '
S_INSLOT
                .ASCII_L ' in slot '
; The meanings of the errors 1 to SD_ERRS of SD_ERROR
SD_ERRORS
                .DAT    E_SD1, E_SD2, E_SD3, E_SD4, E_SD5, E_SD6, E_SD7, E_SD8
SD_ERRS         .EQU    8
E_SD1           .ASCII_L 'no card'
E_SD2           .ASCII_L 'the card is not ready'
E_SD3           .ASCII_L 'timeout, the card did not answer'
E_SD4           .ASCII_L 'CRC, the data from the card was corrupted'
E_SD5           .ASCII_L 'the card reported an error'
E_SD6           .ASCII_L 'the card is write-protected'
E_SD7           .ASCII_L 'the sector is after the last, '
E_SD8           .ASCII_L 'Init failed'

HELP            .DAT    H_R, H_L, H_X, H_D, H_U, H_S, H_I, H_ID, H_M, H_C, H_V, H_H, H_Q, H_P, 0
H_R             .ASCII_L 'r [ADDR]      run the program at ADDR, or at 00008000; r 0 restarts'
H_L             .ASCII_L 'l             load lines of ADDR WORD in hex, as a .bin file has them'
H_X             .ASCII_L 'x             run the demo of the ROM, which F12 leaves'
H_D             .ASCII_L 'd [ADDR] [N]  show N words from ADDR, in hex, or the next ones'
H_U             .ASCII_L 'u [ADDR] [N]  disassemble N instructions from ADDR, or the next ones'
H_S             .ASCII_L 'sd [SLOT] LBA show sector LBA of the SD card in SLOT, or in the last slot'
H_I             .ASCII_L 'i [A.B.C.D]   show the IP address, or set it, such as 192.168.1.65'
H_ID            .ASCII_L 'i dhcp        get the IP address from a DHCP server'
H_M             .ASCII_L 'm [MAC]       show the MAC address, or set it, such as 02:4E:49:43:45:01'
H_C             .ASCII_L 'c             clear the screen'
H_V             .ASCII_L 'v             the version'
H_H             .ASCII_L 'h             halt the core'
H_Q             .ASCII_L '?             the commands'
H_P             .ASCII_L 'PgUp PgDn     scroll back, before a command; MEGA with CRSR up or down'

; The text of u: the mnemonics of the ALU instructions by opcode, and then
; the SHIFT instructions', with the aliases, and the control commands; the
; operands of each ALU mnemonic; the names of the fields; and the pieces
; of a row
U_NAMES         .DAT    U_MOVE, U_SUB, U_MDBL, U_ADD, U_DBL, U_DEC, U_NOT, U_NOR
                .DAT    U_IAND, U_NAND, U_XOR, U_IOR, U_XNOR, U_AND, U_ONE, U_OR
                .DAT    U_SHL, U_S1, U_S2, U_S3, U_S4, U_S5, U_ROL, U_BPL
                .DAT    U_SHR, U_S9, U_S10, U_S11, U_S12, U_S13, U_ROR, U_BPR
U_CTRL          .DAT    U_HALT, U_RTI, U_INT
U_NOPS          .DAT    2, 3, 3, 3, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 1, 3
U_FIELDS
                .DAT    U_FDEST, U_FS0, U_FS1
DIS_KINDS
                .DAT    dis_insn, dis_cmd, dis_ret, dis_call, dis_rsvd
                .DAT    dis_pseudo, dis_pseudo, dis_pseudo, dis_pseudo
                .DAT    dis_pseudo, dis_pseudo, dis_pseudo
; The pseudo-instructions of u, in the order in which they are tried, after
; RET and CALL (README.md): the mask and the value of the instruction word
; without its condition, the name, the first field shown, and the number
; of fields shown. The masks take in the opcode and the modifiers, which
; must be 0 but for the [M] of TST and CMP, and the field that is unused,
; which must be R0.
U_PSEUDO
                .DAT    0x0FFFFFFF, 0x00000000, U_NOP, 0, 0  ; MOVE R0, R0
                .DAT    0x0FFFC07F, 0x0003C000, U_JMP, 1, 1  ; MOVE R15, s0
                .DAT    0x0FFFC07F, 0x00174000, U_PUSH, 1, 1  ; MOVE @--R13, s0
                .DAT    0x0FE03FFF, 0x00003680, U_POP, 0, 1  ; MOVE dest, @R13++
                .DAT    0x0FE03FFF, 0x00000000, U_CLR, 0, 1  ; MOVE dest, R0
                .DAT    0x0FFFC07F, 0x02000000, U_TST, 1, 1  ; MOVE[M] R0, s0
                .DAT    0x0FFFC000, 0x02200000, U_CMP, 1, 2  ; SUB[M] R0, s0, s1
U_PSEUDOS       .EQU    7
U_NOP           .ASCII_L 'NOP'
U_JMP           .ASCII_L 'JMP'
U_PUSH          .ASCII_L 'PUSH'
U_POP           .ASCII_L 'POP'
U_CLR           .ASCII_L 'CLR'
U_TST           .ASCII_L 'TST'
U_CMP           .ASCII_L 'CMP'
U_MOVE          .ASCII_L 'MOVE'
U_SUB           .ASCII_L 'SUB'
U_MDBL          .ASCII_L 'MDBL'
U_ADD           .ASCII_L 'ADD'
U_DBL           .ASCII_L 'DBL'
U_DEC           .ASCII_L 'DEC'
U_NOT           .ASCII_L 'NOT'
U_NOR           .ASCII_L 'NOR'
U_IAND          .ASCII_L 'IAND'
U_NAND          .ASCII_L 'NAND'
U_XOR           .ASCII_L 'XOR'
U_IOR           .ASCII_L 'IOR'
U_XNOR          .ASCII_L 'XNOR'
U_AND           .ASCII_L 'AND'
U_ONE           .ASCII_L 'ONE'
U_OR            .ASCII_L 'OR'
U_SHL           .ASCII_L 'SHL'
U_S1            .ASCII_L '0<1'
U_S2            .ASCII_L '0<C'
U_S3            .ASCII_L 'C<0'
U_S4            .ASCII_L 'C<1'
U_S5            .ASCII_L 'C<C'
U_ROL           .ASCII_L 'ROL'
U_BPL           .ASCII_L 'BPL'
U_SHR           .ASCII_L 'SHR'
U_S9            .ASCII_L '1>0'
U_S10           .ASCII_L 'C>0'
U_S11           .ASCII_L '0>C'
U_S12           .ASCII_L '1>C'
U_S13           .ASCII_L 'C>C'
U_ROR           .ASCII_L 'ROR'
U_BPR           .ASCII_L 'BPR'
U_HALT          .ASCII_L 'HALT'
U_RTI           .ASCII_L 'RTI'
U_INT           .ASCII_L 'INT'
U_FDEST         .ASCII_L 'dest: '
U_FS0           .ASCII_L 's0: '
U_FS1           .ASCII_L 's1: '
S_UFLAGS
                .ASCII_L '1XCZNVEI'
S_URET          .ASCII_L 'RET'
S_UCALL         .ASCII_L 'CALL '
S_URSVD         .ASCII_L 'reserved control word'
S_UDAT          .ASCII_L '.DAT '
S_U0X           .ASCII_L '0x'
S_UCOMMA
                .ASCII_L ', '
S_USEMI         .ASCII_L ' ; '
S_UOPEN         .ASCII_L ' ('
S_UDEC          .ASCII_L '--'
S_UINC          .ASCII_L '++'
S_UGAP          .ASCII_L '  '
S_UBLANK
                .ASCII_L '         '
