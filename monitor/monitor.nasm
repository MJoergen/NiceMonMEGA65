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
; takes a fresh stack, and prints the status, R1. x copies the demo from
; the ROM to 0x8000 and runs it as r does, for the time being (issue #65).
;
; u disassembles instructions, a row each, in the text of nice_cpu's
; nicedis.py, with the pairs of a call shown as CALL, and the return as
; RET, the pseudo-instructions of nice_cpu's ISA.md §10.1 (README.md, "The
; disassembler").
;
; mon_putc writes a character to the outputs that V_OUT selects. On the
; line, the console at 0xFFFFFF00, every byte goes as it is. On the screen
; a character goes at the cursor, which moves on; CR moves the cursor to
; column 0, LF to column 0 of the next row, BS one column back, and TAB to
; the next multiple of 8; the other control codes and 0x7F to 0x9F do
; nothing. Past the last column the cursor goes to the next row, and past
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
TIMER           .EQU    0xFFFFFF10      ; the timer's period, 0 to stop it
E_IP            .EQU    0xFFFFFF9A      ; the Ethernet station's IP address, the first byte in bits 31..24
E_MACH          .EQU    0xFFFFFF9B      ; the first two bytes of its MAC address, in bits 15..0
E_MACL          .EQU    0xFFFFFF9C      ; the last four bytes of its MAC address
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

PROGRAM         .EQU    0x8000          ; where a program is, above the ROM
VARS_WORDS      .EQU    0x1000          ; the words from 0xFFFFF000, the variables, which end a program's RAM
DEMO            .EQU    0x1000          ; the demo's words in the ROM, after their number
DEMO_MAX        .EQU    0x7000          ; more words than fit from DEMO + 1 below the RAM
COLOR           .EQU    0x000FFF00      ; white on black, the color at the cold start
OUT_LINE        .EQU    1
OUT_SCREEN      .EQU    2
TABLE_VERSION   .EQU    0x00010000      ; what mon_version returns: 1.0
DUMP_WORDS      .EQU    32              ; the words that d shows without a count
ROW_WORDS       .EQU    4               ; the words of a row of d
DIS_ROWS        .EQU    20              ; the instructions that u shows without a count
PAGE            .EQU    24              ; the rows of a Page Up or Page Down
SCR_MAX         .EQU    0x7FFF          ; the largest display offset

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
; call. E is cleared, the timer stopped, and VBASE set to 0, as at a
; return. The RAM from 0x8000 is left alone, so that a program a host has
; loaded is still there.
mon_reset
                MOVE    R14, 0          ; E = 0, VBASE = 0; bit 24 stays 1
                MOVE    @TIMER, 0
                MOVE    SP, STACK
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
; one row, CALL target, and MOVE R15, @R13++ is RET (nice_cpu's ISA.md
; §10.1). R7 is the address of the instruction, R8 counts the rows left,
; R9 is the instruction word, R10 its kind, an index of DIS_KINDS, and R12
; the address after it. The fields are at V_UF, their constants at V_UC,
; and the operands of the mnemonic at V_UNOPS.
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
; RET, the first half of a CALL, or another instruction
                AND     R1, R9, 0x0FFFFFFF  ; without the condition
                MOVE    R10, 2
                CMP     R1, 0x0003F680  ; MOVE R15, @R13++
        ?Z      JMP     dis_print
                MOVE    R10, 0
                CMP     R1, 0x0077580F  ; ADD @--R13, n, R15
        ?!Z     JMP     dis_print
                MOVE    R2, @R12        ; the word after it
                XOR     R3, R2, R9
                AND[M]  R0, R3, 0xF0000000
        ?!Z     JMP     dis_print       ; another condition
                AND     R3, R2, 0x0FFFC07F
                CMP     R3, 0x0003C000  ; MOVE R15, s0
        ?!Z     JMP     dis_print
                MOVE    R4, 1           ; the words of the MOVE
                SHR     R3, R2, 7
                AND     R3, R3, 0x30
                CMP     R3, 0x30
        ?Z      MOVE    R4, 2
                CMP     R4, @V_UC+1
        ?!Z     JMP     dis_print       ; n is not their number
                ADD     R12, R12, R4
                MOVE    R10, 3
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

; i [A.B.C.D]: the Ethernet station's IP address (doc/SYSTEM.md, "The
; Ethernet station"), written from four decimal numbers of 0 to 255 with
; dots between them, and shown, in decimal with dots. Without an address
; it is only shown. Blanks may come before and after the address, and
; anything else makes it no address, which is not written. R7 gathers the
; address, a byte at a time, and R8 counts the numbers left.
cmd_ip
                MOVE    R7, 0
                MOVE    R8, 4
ip_blank
                CMP     @R2, 0x20
        ?Z      ADD     R2, R2, 1
        ?Z      JMP     ip_blank
                TST     @R2
        ?Z      JMP     ip_show         ; no address
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
                CALL    _io_puts
                MOVE    R8, @E_IP
                MOVE    R9, 4           ; the bytes left
ip_byte         ROL     R8, R8, 8       ; the top byte to the bottom
                AND     R1, R8, 0xFF
                CALL    _io_putdec
                SUB[M]  R9, R9, 1
        ?Z      JMP     ip_done
                MOVE    R1, 0x2E
                CALL    mon_putc
                JMP     ip_byte
ip_done         CALL    _io_crlf
                JMP     main
ip_bad          MOVE    R1, S_BADIP
                CALL    puts_crlf
                JMP     main

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
        ?Z      JMP     ip_done
                SHR     R4, R8, 24
                SHL     R7, R7, 8
                OR      R7, R7, R4
                SHL     R8, R8, 8
                MOVE    R1, 0x3A        ; :
                CALL    mon_putc
                JMP     mac_put
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

; x: the demo, for the time being (issue #65, README.md). The ROM has its
; number of words at DEMO, and the words after it, which are copied to
; 0x8000 and run as r runs a program. A number of 0, or one too big for
; the ROM, is no demo. The copy and x go when the demo goes.
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
                MOVE    R7, PROGRAM
                JMP     run_at
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
                ADD     @--SP, 2, PC
                JMP     R7

; mon_exit: entry 1, and where a program returns to. Back to the main loop
; with R1 the status: E cleared, the timer stopped, VBASE 0, a fresh
; stack, and the status printed, after a new line if the program left the
; cursor in a row.
mon_exit
                MOVE    R14, 0          ; E = 0, VBASE = 0; bit 24 stays 1
                MOVE    @TIMER, 0
                MOVE    SP, STACK
                PUSH    R1
                TST     @V_COL
        ?!Z     CALL    _io_crlf
                MOVE    R1, S_RETURN
                CALL    _io_puts
                POP     R1
                CALL    _io_puthex
                CALL    _io_crlf
                JMP     main
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
                CMP     R1, 0xA0
        ?C      RET                     ; 0x7F to 0x9F: nothing
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
S_BADMAC
                .ASCII_L 'Not a MAC address: six bytes in hex with colons, the first one even'

HELP            .DAT    H_R, H_L, H_X, H_D, H_U, H_I, H_M, H_C, H_V, H_H, H_Q, H_P, 0
H_R             .ASCII_L 'r [ADDR]      run the program at ADDR, or at 00008000; r 0 restarts'
H_L             .ASCII_L 'l             load lines of ADDR WORD in hex, as a .bin file has them'
H_X             .ASCII_L 'x             run the demo of the ROM, which F12 leaves'
H_D             .ASCII_L 'd [ADDR] [N]  show N words from ADDR, in hex, or the next ones'
H_U             .ASCII_L 'u [ADDR] [N]  disassemble N instructions from ADDR, or the next ones'
H_I             .ASCII_L 'i [A.B.C.D]   show the IP address, or set it, such as 192.168.1.65'
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
