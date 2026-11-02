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
; a letter, and after d a hex address and a hex count. l writes words into
; the RAM from lines of ADDR WORD in hex, as a .bin file has them, typed or
; pasted, up to an empty line, so that a program is loaded with no host's
; tools and no storage. Each line is shown in one row of the screen, which
; the next line clears, and not on the line, so that no line scrolls the
; screen and a paste at 2 Mbaud keeps up. r runs the program
; at 0x8000 as a subroutine, with R1 = the entry of mon_putc, R2 = 0,
; R3 = 0, and E = 0 (ABI.md, "Programs under a monitor"). At its return,
; and at mon_exit, the monitor clears E, stops the timer, sets VBASE to 0,
; takes a fresh stack, and prints the status, R1. x copies the demo from
; the ROM to 0x8000 and runs it as r does, for the time being (issue #65).
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
V_LINE          .EQU    0xFFFFF010      ; the command line, LINE_MAX words, one over for l, and a 0
LINE_MAX        .EQU    76              ; so that the prompt and the line fit a row

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
PAGE            .EQU    24              ; the rows of a Page Up or Page Down
SCR_MAX         .EQU    0x7FFF          ; the largest display offset

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
                MOVE    PC, getline
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
                SUB[M]  R0, @R2, 0x20
        ?Z      ADD     R2, R2, 1
        ?Z      MOVE    PC, ip_blank
                MOVE[M] R0, @R2
        ?Z      MOVE    PC, ip_show     ; no address
ip_num          MOVE    R4, 0           ; the number
                MOVE    R5, 0           ; and its digits
ip_digit
                SUB     R3, @R2, 0x30
                SUB[M]  R0, R3, 10
        ?!C     MOVE    PC, ip_end      ; no digit
                SHL     R1, R4, 3       ; R4 is 10 * R4 + the digit
                SHL     R4, R4, 1
                ADD     R4, R4, R1
                ADD     R4, R4, R3
                SUB[M]  R0, R4, 256
        ?!C     MOVE    PC, ip_bad
                ADD     R5, R5, 1
                ADD     R2, R2, 1
                MOVE    PC, ip_digit
ip_end          MOVE[M] R0, R5
        ?Z      MOVE    PC, ip_bad      ; a number without digits
                SHL     R7, R7, 8
                OR      R7, R7, R4
                SUB[M]  R8, R8, 1
        ?Z      MOVE    PC, ip_last
                SUB[M]  R0, @R2, 0x2E   ; .
        ?!Z     MOVE    PC, ip_bad
                ADD     R2, R2, 1
                MOVE    PC, ip_num
ip_last         SUB[M]  R0, @R2, 0x20   ; blanks, then the end of the line
        ?Z      ADD     R2, R2, 1
        ?Z      MOVE    PC, ip_last
                MOVE[M] R0, @R2
        ?!Z     MOVE    PC, ip_bad
                MOVE    @E_IP, R7
ip_show         MOVE    R1, S_IP
                ADD     @--SP, 2, PC
                MOVE    PC, _io_puts
                MOVE    R8, @E_IP
                MOVE    R9, 4           ; the bytes left
ip_byte         ROL     R8, R8, 8       ; the top byte to the bottom
                AND     R1, R8, 0xFF
                ADD     @--SP, 2, PC
                MOVE    PC, _io_putdec
                SUB[M]  R9, R9, 1
        ?Z      MOVE    PC, ip_done
                MOVE    R1, 0x2E
                ADD     @--SP, 2, PC
                MOVE    PC, mon_putc
                MOVE    PC, ip_byte
ip_done         ADD     @--SP, 2, PC
                MOVE    PC, _io_crlf
                MOVE    PC, main
ip_bad          MOVE    R1, S_BADIP
                ADD     @--SP, 2, PC
                MOVE    PC, puts_crlf
                MOVE    PC, main

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
                ADD     @--SP, 2, PC
                MOVE    PC, puts_crlf
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
                ADD     @--SP, 2, PC
                MOVE    PC, load_row
                MOVE    R6, V_LINE
load_key
                ADD     @--SP, 2, PC
                MOVE    PC, _io_getc
                MOVE    R2, @V_LEND
                MOVE    @V_LEND, R1
                SUB[M]  R0, R1, 0x0A
        ?!Z     MOVE    PC, load_char
                SUB[M]  R0, R2, 0x0D
        ?Z      MOVE    PC, load_key    ; the LF of a CR LF
                MOVE    PC, load_end
load_char
                SUB[M]  R0, R1, 0x0D
        ?Z      MOVE    PC, load_end
                SUB[M]  R0, R1, 0x7F
        ?Z      MOVE    PC, load_del
                SUB[M]  R0, R1, 0x08
        ?Z      MOVE    PC, load_del
                SUB[M]  R0, R1, 0x03
        ?Z      MOVE    PC, load_done   ; CTRL-C
                SUB[M]  R0, R1, 0x1B
        ?Z      MOVE    PC, load_esc
                SUB[M]  R0, R1, 0x09
        ?Z      MOVE    R1, 0x20        ; a TAB is a blank
                SUB[M]  R0, R1, 0x20
        ?C      MOVE    PC, load_key    ; another control code
                SUB[M]  R0, R1, 0x80
        ?!C     MOVE    PC, load_key    ; 0x80 and above
                SUB[M]  R0, R6, V_LINE+LINE_MAX+1
        ?Z      MOVE    PC, load_key    ; the line is over full
                MOVE    @R6++, R1
                ADD     @--SP, 2, PC
                MOVE    PC, mon_putc
                MOVE    PC, load_key
load_del
                SUB[M]  R0, R6, V_LINE
        ?Z      MOVE    PC, load_key    ; nothing before the cursor
                SUB     R6, R6, 1
                MOVE    R1, _io_gets.rub
                ADD     @--SP, 2, PC
                MOVE    PC, _io_puts
                MOVE    PC, load_key
; An ESC: with a [ or an O within io.t_esc, a sequence, whose bytes up to
; its final one, 0x40 to 0x7E, are dropped; another byte is dropped with
; the ESC.
load_esc
                ADD     @--SP, 2, PC
                MOVE    PC, _io_getc.soon
        ?Z      MOVE    PC, load_key
                SUB[M]  R0, R1, 0x5B    ; [
        ?Z      MOVE    PC, load_seq
                SUB[M]  R0, R1, 0x4F    ; O
        ?!Z     MOVE    PC, load_key
load_seq
                ADD     @--SP, 2, PC
                MOVE    PC, _io_getc.soon
        ?Z      MOVE    PC, load_key
                SUB[M]  R0, R1, 0x40
        ?C      MOVE    PC, load_seq    ; a parameter byte
                MOVE    PC, load_key    ; the final byte
; The end of a line: an empty one ends the load, one of blanks only is
; passed over, and another is parsed, and its word written
load_end
                MOVE    @R6, 0
                SUB[M]  R0, R6, V_LINE
        ?Z      MOVE    PC, load_done
                ADD     R11, R11, 1
                SUB[M]  R0, R6, V_LINE+LINE_MAX+1
        ?Z      MOVE    PC, load_bad    ; longer than LINE_MAX
                MOVE    R1, V_LINE
                ADD     @--SP, 2, PC
                MOVE    PC, _io_gethex  ; R1 the address, R2 its digits, R3 after it
                MOVE[M] R0, R2
        ?!Z     MOVE    PC, load_addr
                MOVE[M] R0, @R3
        ?Z      MOVE    PC, load_line   ; blanks only
load_addr
                SUB     R4, R2, 1
                SUB[M]  R0, R4, 8
        ?!C     MOVE    PC, load_bad    ; no digit, or more than 8
                SUB[M]  R0, R1, PROGRAM
        ?C      MOVE    PC, load_bad    ; in the ROM
                SUB[M]  R0, R1, @V_PEND
        ?!C     MOVE    PC, load_bad    ; the variables, or past the RAM
                MOVE    R6, R1
                MOVE    R1, R3
                ADD     @--SP, 2, PC
                MOVE    PC, _io_gethex  ; R1 the word
                SUB     R4, R2, 1
                SUB[M]  R0, R4, 8
        ?!C     MOVE    PC, load_bad
load_tail
                SUB[M]  R0, @R3, 0x20
        ?Z      ADD     R3, R3, 1
        ?Z      MOVE    PC, load_tail
                MOVE[M] R0, @R3
        ?!Z     MOVE    PC, load_bad    ; more after the word
                MOVE    @R6, R1
                ADD     R8, R8, 1
                SUB[M]  R0, R6, R9
        ?C      MOVE    R9, R6          ; a lower address
                SUB[M]  R0, R10, R6
        ?C      MOVE    R10, R6         ; a higher one
                MOVE    PC, load_line
load_bad
                ADD     R12, R12, 1
                SUB[M]  R0, R12, 1
        ?Z      MOVE    @V_LBAD, R11
                MOVE    PC, load_line
; The end of the load: the row blank again, the outputs back, the words
; written, and the lines skipped
load_done
                ADD     @--SP, 2, PC
                MOVE    PC, load_row
                MOVE    @V_OUT, @V_LOUT
                MOVE    R1, S_LOADED
                ADD     @--SP, 2, PC
                MOVE    PC, _io_puts
                MOVE    R1, R8
                ADD     @--SP, 2, PC
                MOVE    PC, _io_putdec
                MOVE[M] R0, R8
        ?Z      MOVE    PC, load_skipped
                MOVE    R1, S_LFROM
                ADD     @--SP, 2, PC
                MOVE    PC, _io_puts
                MOVE    R1, R9
                ADD     @--SP, 2, PC
                MOVE    PC, _io_puthex
                MOVE    R1, S_LTO
                ADD     @--SP, 2, PC
                MOVE    PC, _io_puts
                MOVE    R1, R10
                ADD     @--SP, 2, PC
                MOVE    PC, _io_puthex
load_skipped
                ADD     @--SP, 2, PC
                MOVE    PC, _io_crlf
                MOVE[M] R0, R12
        ?Z      MOVE    PC, main
                MOVE    R1, S_SKIPPED
                ADD     @--SP, 2, PC
                MOVE    PC, _io_puts
                MOVE    R1, R12
                ADD     @--SP, 2, PC
                MOVE    PC, _io_putdec
                MOVE    R1, S_FIRST
                ADD     @--SP, 2, PC
                MOVE    PC, _io_puts
                MOVE    R1, @V_LBAD
                ADD     @--SP, 2, PC
                MOVE    PC, _io_putdec
                MOVE    R1, S_LFORM
                ADD     @--SP, 2, PC
                MOVE    PC, _io_puts
                SUB     R1, @V_PEND, 1
                ADD     @--SP, 2, PC
                MOVE    PC, _io_puthex
                ADD     @--SP, 2, PC
                MOVE    PC, _io_crlf
                MOVE    PC, main

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
        ?!Z     MOVE    PC, load_blank
                MOVE    @V_COL, 0
                MOVE    @V_ROW, R7
                MOVE    PC, putc_cur

; x: the demo, for the time being (issue #65, README.md). The ROM has its
; number of words at DEMO, and the words after it, which are copied to
; 0x8000 and run as r runs a program. A number of 0, or one too big for
; the ROM, is no demo. The copy and x go when the demo goes.
cmd_demo
                MOVE[M] R1, @DEMO       ; the words left
        ?Z      MOVE    PC, no_demo
                SUB[M]  R0, R1, DEMO_MAX
        ?!C     MOVE    PC, no_demo
                MOVE    R2, DEMO+1
                MOVE    R3, PROGRAM
demo_copy
                MOVE    @R3++, @R2++
                SUB[M]  R1, R1, 1
        ?!Z     MOVE    PC, demo_copy
                MOVE    PC, cmd_run
no_demo         MOVE    R1, S_NODEMO
                ADD     @--SP, 2, PC
                MOVE    PC, puts_crlf
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
; Row 0 into the history, at slot V_HHEAD, which moves down the ring, when
; the memory has room for one
                MOVE[M] R0, @V_HCAP
        ?Z      MOVE    PC, putc_scroll
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
        ?!Z     MOVE    PC, putc_hist
                SUB[M]  R1, @V_HHEAD, 1
        ?C      SUB     R1, @V_HCAP, 1  ; from slot 0 to the last
                MOVE    @V_HHEAD, R1
                ADD     R1, @V_HCOUNT, 1
                SUB[M]  R0, @V_HCAP, R1
        ?!C     MOVE    @V_HCOUNT, R1
putc_scroll
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

; getline: a line into the buffer at R1, of up to R2 characters, as
; _io_gets reads it, with the keys of the history before it: Page Up, ESC
; [ 5 ~, and Page Down, ESC [ 6 ~. The other escape sequences are dropped,
; as _io_gets drops them, and any key but those two shows the screen again.
; The first key of the line goes on to _io_gets.first. _io_getc.soon uses
; only R1 and R2, so R3 keeps the first byte of a sequence's parameter.
getline
                MOVE    @--SP, R1
                MOVE    @--SP, R2
getline_key
                ADD     @--SP, 2, PC
                MOVE    PC, _io_getc
                SUB[M]  R0, R1, 0x1B
        ?!Z     MOVE    PC, getline_line
                ADD     @--SP, 2, PC
                MOVE    PC, _io_getc.soon
        ?Z      MOVE    PC, getline_drop  ; an ESC alone
                SUB[M]  R0, R1, 0x4F    ; O: one more byte
        ?Z      MOVE    PC, getline_ss3
                SUB[M]  R0, R1, 0x5B    ; [
        ?!Z     MOVE    PC, getline_line  ; another byte, on its own
                ADD     @--SP, 2, PC
                MOVE    PC, _io_getc.soon
        ?Z      MOVE    PC, getline_drop
                MOVE    R3, R1
                SUB[M]  R0, R1, 0x40
        ?!C     MOVE    PC, getline_drop  ; the final byte, such as A
                ADD     @--SP, 2, PC
                MOVE    PC, _io_getc.soon
        ?Z      MOVE    PC, getline_drop
                SUB[M]  R0, R1, 0x7E    ; ~
        ?!Z     MOVE    PC, getline_csi
                SUB[M]  R0, R3, 0x35    ; 5
        ?Z      MOVE    PC, getline_up
                SUB[M]  R0, R3, 0x36    ; 6
        ?Z      MOVE    PC, getline_down
                MOVE    PC, getline_drop
getline_csi
                SUB[M]  R0, R1, 0x40
        ?!C     MOVE    PC, getline_drop  ; the final byte
                ADD     @--SP, 2, PC
                MOVE    PC, _io_getc.soon
        ?Z      MOVE    PC, getline_drop
                MOVE    PC, getline_csi
getline_ss3
                ADD     @--SP, 2, PC
                MOVE    PC, _io_getc.soon
getline_drop
                ADD     @--SP, 2, PC
                MOVE    PC, hist_leave
                MOVE    PC, getline_key
getline_up
                ADD     @--SP, 2, PC
                MOVE    PC, hist_up
                MOVE    PC, getline_key
getline_down
                ADD     @--SP, 2, PC
                MOVE    PC, hist_down
                MOVE    PC, getline_key
getline_line
                MOVE    R3, R1
                ADD     @--SP, 2, PC
                MOVE    PC, hist_leave
                MOVE    R2, @SP++
                MOVE    R1, @SP++
                MOVE    PC, _io_gets.first  ; which returns to the caller

; hist_up: PAGE rows further back, up to the rows kept. The first turns
; the ring and keeps SCR_CTL. Uses R1-R6.
hist_up
                MOVE[M] R0, @V_HCOUNT
        ?Z      MOVE    PC, @SP++       ; no history
                MOVE[M] R1, @V_BACK
        ?!Z     MOVE    PC, hist_more
                MOVE    @V_CTL, @SCR_CTL
                ADD     @--SP, 2, PC
                MOVE    PC, hist_turn
                MOVE    R1, 0
hist_more
                ADD     R1, R1, PAGE
                SUB[M]  R0, @V_HCOUNT, R1
        ?C      MOVE    R1, @V_HCOUNT
; R1 rows back: the offset V_HSIZE - 80 R1 on, and the cursor off
hist_show
                MOVE    @V_BACK, R1
                SHL     R2, R1, 6
                SHL     R1, R1, 4
                ADD     R1, R1, R2
                SUB     @SCR_OFFS, @V_HSIZE, R1
                MOVE    @SCR_CTL, 0x400
                MOVE    PC, @SP++

; hist_down: PAGE rows forward, and the screen again at the end. Uses R1
; and R2.
hist_down
                MOVE[M] R1, @V_BACK
        ?Z      MOVE    PC, @SP++
                SUB[M]  R1, R1, PAGE
        ?C      MOVE    PC, hist_leave
        ?Z      MOVE    PC, hist_leave
                MOVE    PC, hist_show

; hist_leave: the screen again, if the history is shown, with its SCR_CTL.
; Uses no register.
hist_leave
                MOVE[M] R0, @V_BACK
        ?Z      MOVE    PC, @SP++
                MOVE    @V_BACK, 0
                MOVE    @SCR_CTL, @V_CTL
                MOVE    @SCR_OFFS, 0
                MOVE    PC, @SP++

; hist_turn: the ring turned so that its newest row, at slot V_HHEAD + 1,
; is at slot 0, at the top of the memory, and the next goes to the last
; slot. The slots are V_HCAP rows of words from B, slot i at a lower
; address than slot i - 1, so this turns the words from B up by D = 80
; (V_HHEAD + 1), with three reversals: all of them, the first D, and the
; rest. R4 is B, R5 is D, and R6 the words of the ring. Uses R1-R6.
hist_turn
                ADD     R1, @V_HHEAD, 1
                SUB[M]  R0, R1, @V_HCAP
        ?Z      MOVE    R1, 0
                SUB     @V_HHEAD, @V_HCAP, 1
                SHL     R2, R1, 6
                SHL     R5, R1, 4
                ADD[M]  R5, R5, R2
        ?Z      MOVE    PC, @SP++       ; turned already
                MOVE    R6, @V_HCAP
                SHL     R2, R6, 6
                SHL     R6, R6, 4
                ADD     R6, R6, R2
                ADD     R4, @V_HSIZE, SCREEN
                SUB     R4, R4, R6
                MOVE    R1, R4
                ADD     R2, R4, R6
                ADD     @--SP, 2, PC
                MOVE    PC, hist_rev
                MOVE    R1, R4
                ADD     R2, R4, R5
                ADD     @--SP, 2, PC
                MOVE    PC, hist_rev
                ADD     R1, R4, R5
                ADD     R2, R4, R6
; hist_rev: the words from R1 up to R2, which is after the last, in the
; reverse order. Uses R1-R3.
hist_rev
                SUB     R2, R2, 1       ; the last word
hist_rev_loop
                SUB[M]  R0, R1, R2
        ?!C     MOVE    PC, @SP++       ; the two have met
                MOVE    R3, @R1
                MOVE    @R1++, @R2
                MOVE    @R2, R3
                SUB     R2, R2, 1
                MOVE    PC, hist_rev_loop

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
                .DAT    0x69, cmd_ip    ; i
                .DAT    0x6C, cmd_load  ; l
                .DAT    0x72, cmd_run   ; r
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
                .ASCII_L 'No program at 00008000'
S_NODEMO
                .ASCII_L 'No demo in the ROM'
S_IP            .ASCII_L 'IP address '
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

HELP            .DAT    H_R, H_L, H_X, H_D, H_I, H_C, H_V, H_H, H_Q, H_P, 0
H_R             .ASCII_L 'r             run the program at 00008000'
H_L             .ASCII_L 'l             load lines of ADDR WORD in hex, as a .bin file has them'
H_X             .ASCII_L 'x             run the demo of the ROM, which F12 leaves'
H_D             .ASCII_L 'd [ADDR] [N]  show N words from ADDR, in hex, or the next ones'
H_I             .ASCII_L 'i [A.B.C.D]   show the IP address, or set it, such as 192.168.1.65'
H_C             .ASCII_L 'c             clear the screen'
H_V             .ASCII_L 'v             the version'
H_H             .ASCII_L 'h             halt the core'
H_Q             .ASCII_L '?             the commands'
H_P             .ASCII_L 'PgUp PgDn     scroll back, before a command; MEGA with CRSR up or down'
