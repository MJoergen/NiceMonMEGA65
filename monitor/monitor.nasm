; The monitor, the program of the ROM at 0x0000 (README.md). The core boots
; from it at reset. It gives the programs at 0x8000 a hardware abstraction
; layer, the HAL: nine routines, called through the dispatch table at the
; start of the ROM, and it has a main loop with a few commands, typed on
; the keyboard or sent over the line, and shown on the screen and the line.
;
; The dispatch table has one MOVE PC, routine per entry, two words, so that
; entry n is at address 2n, and entry 0 is the reset. The routines follow
; the C ABI of nice_cpu/runtime/ABI.md: the arguments in R1-R4, the result
; in R1, R1-R6 changed, and R7-R13 kept. mon.nasm has the address of each
; entry as an .EQU, and a stub that jumps to it.
;
; The cold start, mon_reset, sets SP to STACK, the variables, and the
; screen, prints the banner, and runs the main loop. A command is a line:
; a letter, and after d a hex address and a hex count. r runs the program
; at 0x8000 as a subroutine, with R1 = the entry of mon_putc, R2 = 0,
; R3 = 0, and E = 0 (ABI.md, "Programs under a monitor"). At its return,
; and at mon_exit, the monitor clears E, stops the timer, sets VBASE to 0,
; takes a fresh stack, and prints the status, R1.
;
; mon_putc writes a character to the outputs that V_OUT selects. On the
; line, the console at 0xFFFFFF00, every byte goes as it is. On the screen
; a character goes at the cursor, which moves on; CR moves the cursor to
; column 0, LF to column 0 of the next row, BS one column back, and TAB to
; the next multiple of 8; the other control codes and 0x7F to 0x9F do
; nothing. Past the last column the cursor goes to the next row, and past
; the last row the screen's rows move up by one, by copying, which scrolls
; in niceemu too, where the display offset is plain memory, and the same
; on a board whose screen is smaller. The display offset stays 0.
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

STACK           .EQU    0xFFFFF000      ; SP at the cold start, above the program's RAM
V_COL           .EQU    0xFFFFF000      ; the cursor's column, 0 to 79
V_ROW           .EQU    0xFFFFF001      ; and its row, 0 to 24
V_COLOR         .EQU    0xFFFFF002      ; the color of the characters put, bits 31..8
V_OUT           .EQU    0xFFFFF003      ; the outputs: bit 0 the line, bit 1 the screen
V_NEXT          .EQU    0xFFFFF004      ; the address that the next d goes on at
V_LINE          .EQU    0xFFFFF010      ; the command line, LINE_MAX words and a 0
LINE_MAX        .EQU    76              ; so that the prompt and the line fit a row

PROGRAM         .EQU    0x8000          ; where a program is, above the ROM
COLOR           .EQU    0x000FFF00      ; white on black, the color at the cold start
OUT_LINE        .EQU    1
OUT_SCREEN      .EQU    2
TABLE_VERSION   .EQU    0x00010000      ; what mon_version returns: 1.0
DUMP_WORDS      .EQU    32              ; the words that d shows without a count
ROW_WORDS       .EQU    4               ; the words of a row of d

; The dispatch table (README.md, "The dispatch table"). Entries are only
; ever added at the end.
                MOVE    PC, mon_reset   ; 0 at 0x00
                MOVE    PC, mon_exit    ; 1 at 0x02
                MOVE    PC, mon_version  ; 2 at 0x04
                MOVE    PC, mon_putc    ; 3 at 0x06
                MOVE    PC, mon_out     ; 4 at 0x08
                MOVE    PC, scr_cls     ; 5 at 0x0A
                MOVE    PC, scr_moveto  ; 6 at 0x0C
                MOVE    PC, scr_getxy   ; 7 at 0x0E
                MOVE    PC, scr_color   ; 8 at 0x10

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
                ADD     @--SP, 2, PC
                MOVE    PC, scr_cls
                MOVE    R1, S_NAME
                ADD     @--SP, 2, PC
                MOVE    PC, _io_puts
                MOVE    R1, VERSION
                ADD     @--SP, 2, PC
                MOVE    PC, puts_crlf
                MOVE    R1, S_HINT
                ADD     @--SP, 2, PC
                MOVE    PC, puts_crlf

; main: the prompt, a line, and its command. SP is fresh for each line, and
; a command jumps back here when it is done. The first character of the
; line that is no blank is the command, A to Z as a to z, looked up in
; COMMANDS; R2 points after it for the command's arguments.
main            MOVE    SP, STACK
                MOVE    R1, S_PROMPT
                ADD     @--SP, 2, PC
                MOVE    PC, _io_puts
                MOVE    R1, V_LINE
                MOVE    R2, LINE_MAX
                ADD     @--SP, 2, PC
                MOVE    PC, _io_gets
                MOVE    R2, V_LINE
word            MOVE[M] R1, @R2++
        ?Z      MOVE    PC, main        ; an empty line
                SUB[M]  R0, R1, 0x20
        ?Z      MOVE    PC, word
                SUB     R3, R1, 0x41
                SUB[M]  R0, R3, 26
        ?C      OR      R1, R1, 0x20    ; A to Z folded to a to z
                MOVE    R3, COMMANDS
find            MOVE[M] R4, @R3++       ; a letter, or 0 at the end
        ?Z      MOVE    PC, unknown
                SUB[M]  R0, R4, R1
        ?Z      MOVE    PC, @R3         ; the command
                ADD     R3, R3, 1
                MOVE    PC, find
unknown         MOVE    R1, S_UNKNOWN
                ADD     @--SP, 2, PC
                MOVE    PC, puts_crlf
                MOVE    PC, main

; ?: the commands, a line each
cmd_help
                MOVE    R1, HELP
                ADD     @--SP, 2, PC
                MOVE    PC, puts_lines
                MOVE    PC, main

; c: the screen cleared
cmd_cls         ADD     @--SP, 2, PC
                MOVE    PC, scr_cls
                MOVE    PC, main

; v: the version of the monitor, and that of the table, major.minor
cmd_version
                MOVE    R1, S_NAME
                ADD     @--SP, 2, PC
                MOVE    PC, _io_puts
                MOVE    R1, VERSION
                ADD     @--SP, 2, PC
                MOVE    PC, _io_puts
                MOVE    R1, S_TABLE
                ADD     @--SP, 2, PC
                MOVE    PC, _io_puts
                SHR     R1, TABLE_VERSION, 16
                ADD     @--SP, 2, PC
                MOVE    PC, _io_putdec
                MOVE    R1, 0x2E        ; .
                ADD     @--SP, 2, PC
                MOVE    PC, mon_putc
                AND     R1, TABLE_VERSION, 0xFFFF
                ADD     @--SP, 2, PC
                MOVE    PC, _io_putdec
                ADD     @--SP, 2, PC
                MOVE    PC, _io_crlf
                MOVE    PC, main

; h: the core halted, until the reset button, or a host starts it
cmd_halt
                MOVE    R1, S_HALTED
                ADD     @--SP, 2, PC
                MOVE    PC, puts_crlf
                HALT

; d [ADDR] [N]: N words from ADDR, in hex, ROW_WORDS to a row, each row
; with its address first. Without ADDR, the words after the last shown;
; without N, DUMP_WORDS.
cmd_dump
                MOVE    R1, R2
                ADD     @--SP, 2, PC
                MOVE    PC, _io_gethex  ; R1 the address, R2 its digits, R3 after it
                MOVE[M] R0, R2
        ?!Z     MOVE    @V_NEXT, R1
                MOVE    R1, R3
                ADD     @--SP, 2, PC
                MOVE    PC, _io_gethex  ; R1 the count
                MOVE[M] R0, R2
        ?Z      MOVE    R1, DUMP_WORDS
                MOVE[M] R8, R1          ; the words left
        ?Z      MOVE    PC, main
                MOVE    R7, @V_NEXT     ; the next word
dump_row
                MOVE    R1, R7
                ADD     @--SP, 2, PC
                MOVE    PC, _io_puthex
                MOVE    R9, ROW_WORDS   ; the words left in the row
dump_word
                MOVE    R1, 0x20
                ADD     @--SP, 2, PC
                MOVE    PC, mon_putc
                MOVE    R1, @R7++
                ADD     @--SP, 2, PC
                MOVE    PC, _io_puthex
                SUB[M]  R8, R8, 1
        ?Z      MOVE    PC, dump_end
                SUB[M]  R9, R9, 1
        ?!Z     MOVE    PC, dump_word
                ADD     @--SP, 2, PC
                MOVE    PC, _io_crlf
                MOVE    PC, dump_row
dump_end
                MOVE    @V_NEXT, R7
                ADD     @--SP, 2, PC
                MOVE    PC, _io_crlf
                MOVE    PC, main

; r: the program at 0x8000, called as ABI.md says, on this stack: the
; return address is pushed, and the program returns with MOVE PC, @SP++
; and its status in R1. A word of 0 at 0x8000 is no program: it is MOVE
; R0, R0, which no start-up code begins with.
cmd_run         MOVE[M] R0, @PROGRAM
        ?Z      MOVE    PC, no_prog
                MOVE    R1, MON_PUTC    ; the entry of mon_putc (mon.nasm)
                MOVE    R2, 0           ; argc
                MOVE    R3, 0           ; argv
                ADD     @--SP, 2, PC
                MOVE    PC, PROGRAM

; mon_exit: entry 1, and where a program returns to. Back to the main loop
; with R1 the status: E cleared, the timer stopped, VBASE 0, a fresh
; stack, and the status printed, after a new line if the program left the
; cursor in a row.
mon_exit
                MOVE    R14, 0          ; E = 0, VBASE = 0; bit 24 stays 1
                MOVE    @TIMER, 0
                MOVE    SP, STACK
                MOVE    @--SP, R1
                MOVE[M] R0, @V_COL
        ?!Z     ADD     @--SP, 2, PC
        ?!Z     MOVE    PC, _io_crlf
                MOVE    R1, S_RETURN
                ADD     @--SP, 2, PC
                MOVE    PC, _io_puts
                MOVE    R1, @SP++
                ADD     @--SP, 2, PC
                MOVE    PC, _io_puthex
                ADD     @--SP, 2, PC
                MOVE    PC, _io_crlf
                MOVE    PC, main
no_prog         MOVE    R1, S_NOPROG
                ADD     @--SP, 2, PC
                MOVE    PC, puts_crlf
                MOVE    PC, main

; mon_version: entry 2. R1 = the version of the table, the major number in
; bits 31..16 and the minor in 15..0.
mon_version
                MOVE    R1, TABLE_VERSION
                MOVE    PC, @SP++

; mon_putc: entry 3. R1 a character, bits 7..0, to the outputs of V_OUT:
; the line as it is, and the screen as the header says. Uses R1-R4.
mon_putc
                AND     R1, R1, 0xFF
                AND[M]  R0, @V_OUT, OUT_LINE
        ?!Z     MOVE    @CONSOLE, R1
                AND[M]  R0, @V_OUT, OUT_SCREEN
        ?Z      MOVE    PC, @SP++
                SUB[M]  R0, R1, 0x20
        ?C      MOVE    PC, putc_ctl    ; a control code
                SUB[M]  R0, R1, 0x7F
        ?C      MOVE    PC, putc_chr    ; 0x20 to 0x7E
                SUB[M]  R0, R1, 0xA0
        ?C      MOVE    PC, @SP++       ; 0x7F to 0x9F: nothing
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
                SUB[M]  R0, R1, 80
        ?!Z     MOVE    @V_COL, R1
        ?!Z     MOVE    PC, putc_cur
; Column 0 of the next row, with the rows moved up by one after the last
putc_lf         MOVE    @V_COL, 0
                ADD     R1, @V_ROW, 1
                SUB[M]  R0, R1, 25
        ?!Z     MOVE    @V_ROW, R1
        ?!Z     MOVE    PC, putc_cur
                MOVE    R2, SCREEN
                MOVE    R3, SCREEN+80
                MOVE    R4, 1920        ; rows 1 to 24 to rows 0 to 23
putc_up         MOVE    @R2++, @R3++
                SUB[M]  R4, R4, 1
        ?!Z     MOVE    PC, putc_up
                OR      R3, @V_COLOR, 0x20
                MOVE    R4, 80          ; row 24 blank
putc_blk
                MOVE    @R2++, R3
                SUB[M]  R4, R4, 1
        ?!Z     MOVE    PC, putc_blk
; The cursor's registers from the variables
putc_cur
                MOVE    @SCR_X, @V_COL
                MOVE    @SCR_Y, @V_ROW
                MOVE    PC, @SP++
putc_ctl
                SUB[M]  R0, R1, 0x0D
        ?Z      MOVE    @V_COL, 0
        ?Z      MOVE    PC, putc_cur
                SUB[M]  R0, R1, 0x0A
        ?Z      MOVE    PC, putc_lf
                SUB[M]  R0, R1, 0x08
        ?Z      MOVE    PC, putc_bs
                SUB[M]  R0, R1, 0x09
        ?!Z     MOVE    PC, @SP++       ; another control code: nothing
                OR      R1, @V_COL, 7   ; TAB: the next multiple of 8
                ADD     R1, R1, 1
                SUB[M]  R0, R1, 80
        ?!C     MOVE    PC, putc_lf     ; past the last column
                MOVE    @V_COL, R1
                MOVE    PC, putc_cur
putc_bs         MOVE[M] R1, @V_COL
        ?!Z     SUB     @V_COL, R1, 1
                MOVE    PC, putc_cur

; mon_out: entry 4. R1 the outputs of mon_putc, bit 0 the line and bit 1
; the screen. R1 = the old ones. Uses R2.
mon_out         MOVE    R2, @V_OUT
                AND     @V_OUT, R1, OUT_LINE+OUT_SCREEN
                MOVE    R1, R2
                MOVE    PC, @SP++

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
        ?!Z     MOVE    PC, cls_loop
                MOVE    @V_COL, 0
                MOVE    @V_ROW, 0
                MOVE    PC, putc_cur

; scr_moveto: entry 6. The cursor to column R1 and row R2. A column past
; 79 is 79, and a row past 24 is 24.
scr_moveto
                SUB[M]  R0, R1, 80
        ?!C     MOVE    R1, 79
                SUB[M]  R0, R2, 25
        ?!C     MOVE    R2, 24
                MOVE    @V_COL, R1
                MOVE    @V_ROW, R2
                MOVE    PC, putc_cur

; scr_getxy: entry 7. R1 = the cursor's column, R2 = its row.
scr_getxy
                MOVE    R1, @V_COL
                MOVE    R2, @V_ROW
                MOVE    PC, @SP++

; scr_color: entry 8. R1 the color of the characters put from now on, bits
; 31..8 of a screen word. R1 = the old one. Uses R2.
scr_color
                MOVE    R2, @V_COLOR
                AND     @V_COLOR, R1, 0xFFFFFF00
                MOVE    R1, R2
                MOVE    PC, @SP++

; puts_crlf: the string at R1, and CR LF
puts_crlf
                ADD     @--SP, 2, PC
                MOVE    PC, _io_puts
                MOVE    PC, _io_crlf    ; which returns to the caller

; puts_lines: the strings of the table at R1, each with CR LF after it, up
; to a 0 word. Uses R7 across the calls, saved.
puts_lines
                MOVE    @--SP, R7
                MOVE    R7, R1
lines           MOVE[M] R1, @R7++
        ?Z      MOVE    R7, @SP++
        ?Z      MOVE    PC, @SP++
                ADD     @--SP, 2, PC
                MOVE    PC, puts_crlf
                MOVE    PC, lines

; The commands: the letter, and the routine, which main jumps to. A 0 ends
; the table.
COMMANDS
                .DAT    0x3F, cmd_help  ; ?
                .DAT    0x63, cmd_cls   ; c
                .DAT    0x64, cmd_dump  ; d
                .DAT    0x68, cmd_halt  ; h
                .DAT    0x72, cmd_run   ; r
                .DAT    0x76, cmd_version  ; v
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
                .ASCII_L 'No program at 00008000'

HELP            .DAT    H_R, H_D, H_C, H_V, H_H, H_Q, 0
H_R             .ASCII_L 'r             run the program at 00008000'
H_D             .ASCII_L 'd [ADDR] [N]  show N words from ADDR, in hex, or the next ones'
H_C             .ASCII_L 'c             clear the screen'
H_V             .ASCII_L 'v             the version'
H_H             .ASCII_L 'h             halt the core'
H_Q             .ASCII_L '?             the commands'
