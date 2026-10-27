; The demo in the ROM of the release: a welcome screen that turns into a
; typewriter. It shows that the core runs, and that the keyboard and the
; screen work, on a board with no computer on its debug UART. Its test, in
; demo/Makefile, runs it in niceemu and compares the screens with
; demo/test.expected.
;
; The top ten rows say what the core is and how to go further. The rows
; below them take what is typed, from the keyboard or the UART: a
; character goes at the cursor, RETURN starts a new line, DEL (or
; backspace) deletes the character before the cursor, TAB goes to the next
; column that is a multiple of 8, the cursor keys move the cursor, and
; CTRL-L clears the rows.
;
; When the cursor goes past the last row, the program scrolls these rows up
; by one, by copying each row to the one above it. The welcome does not
; move. The display offset (0xFFFFFF85) is not used, for three reasons. It
; would scroll the welcome away too. It wraps at the end of the screen's
; memory, whose size differs between the boards. And in niceemu it is plain
; memory, so the program would not scroll there.
;
; The program runs from the ROM, and a write to the ROM is dropped. So the
; program keeps no variables in memory: its state is in registers. The only
; memory it writes is the screen, the cursor's registers, and the stack.
; SP starts at 0xFFFFFF00, as in sim/rom.nasm, so the stack grows down from
; 0xFFFFFEFF. No register or screen is there, so on the board these words
; are RAM: the 64K words of RAM repeat through the address space, and
; 0xFFFFFEFF is RAM word 0xFEFF, far above the ROM (SYSTEM.md, "Address
; map"). In niceemu they are ordinary memory.
;
; On the board, a read of the console returns 0 until a byte arrives, so the
; program polls it in a loop. A read returns 0x200 when the input has ended,
; and then the program halts. In niceemu that happens after the last byte
; of the input file. On the board it happens after a break on the UART.
;
; It is assembled with build/version.nasm after it, which defines VERSION,
; the version string of the title bar (demo/Makefile).

SP      .EQU    R13
PC      .EQU    R15

CONSOLE .EQU    0xFFFFFF00      ; a read: bit 8 and the byte, or bit 9 at the end
SCREEN  .EQU    0xFFFF0000      ; 80 x 25 words, the character in bits 7..0
SCR_CTL .EQU    0xFFFFFF80      ; bit 6 shows the cursor, bit 5 blinks it
SCR_X   .EQU    0xFFFFFF81      ; the cursor's column
SCR_Y   .EQU    0xFFFFFF82      ; the cursor's row

; The colors: the background in bits 31..20, the foreground in bits 19..8
BAR     .EQU    0x00AFFF00      ; white on blue
TEXT    .EQU    0x000CCC00      ; light gray on black
LINK    .EQU    0x000FF000      ; yellow on black
TYPED   .EQU    0x000FFF00      ; white on black

TOP     .EQU    10              ; the first row of the typewriter
LAST    .EQU    24              ; and its last
SCR_TOP .EQU    SCREEN+800      ; the address of row TOP, 80 * TOP words in
SCR_2ND .EQU    SCREEN+880      ; and of the row after it

; The registers that hold the typewriter's state
COL     .EQU    R10             ; the cursor's column, 0 to 79
ROW     .EQU    R11             ; the cursor's row, TOP to LAST
ESC     .EQU    R9              ; 0, or 1 after ESC, or 2 after ESC [
CR      .EQU    R8              ; 1 when the byte before was a CR

        MOVE    SP, 0xFFFFFF00  ; the stack, from RAM word 0xFEFF down

; The welcome: the whole screen blank, the two bars, and the texts
        MOVE    R2, SCREEN
        MOVE    R3, TEXT+0x20
        MOVE    R4, 2000
        ADD     @--SP, 2, PC
        MOVE    PC, FILL
        MOVE    R2, SCREEN
        MOVE    R3, BAR+0x20
        MOVE    R4, 80
        ADD     @--SP, 2, PC
        MOVE    PC, FILL
        MOVE    R2, SCREEN+720  ; R3 is still BAR+0x20: FILL leaves it
        MOVE    R4, 80
        ADD     @--SP, 2, PC
        MOVE    PC, FILL
        MOVE    R5, TEXTS
NEXT    MOVE[M] R2, @R5++       ; the position, or -1 at the end
    ?X  MOVE    PC, TYPE
        ADD     R2, R2, SCREEN
        MOVE    R3, @R5++       ; the color
        MOVE    R1, @R5++       ; the string
        ADD     @--SP, 2, PC
        MOVE    PC, PRINT
        MOVE    PC, NEXT

; The typewriter
TYPE    MOVE    COL, 0
        MOVE    ROW, TOP
        MOVE    ESC, 0
        MOVE    CR, 0
        MOVE    @SCR_CTL, 0x60  ; a blinking cursor, and no display offset
KEY     MOVE    @SCR_X, COL     ; the cursor where the next character goes
        MOVE    @SCR_Y, ROW
WAIT    MOVE    R1, @CONSOLE
        AND[M]  R0, R1, 0x200   ; the end of the input
    ?!Z HALT
        AND[M]  R0, R1, 0x100   ; Z is clear when a byte has arrived
    ?Z  MOVE    PC, WAIT
        AND     R1, R1, 0xFF
        MOVE    R7, CR          ; whether this byte follows a CR
        MOVE    CR, 0
        MOVE[M] R0, ESC
    ?!Z MOVE    PC, INESC
PLAIN   SUB[M]  R0, R1, 0x20
    ?C  MOVE    PC, CONTROL     ; below 0x20
        SUB[M]  R0, R1, 0x7F
    ?C  MOVE    PC, PUT         ; printable ASCII
    ?Z  MOVE    PC, BACK        ; DEL
        SUB[M]  R0, R1, 0xA0
    ?C  MOVE    PC, KEY         ; 0x80 to 0x9F have no character
                                ; 0xA0 and above fall through to PUT

; A character at the cursor, which moves on, to the next line after the last
; column
PUT     ADD     @--SP, 2, PC
        MOVE    PC, CELL
        OR      @R2, R1, TYPED
        ADD     COL, COL, 1
        SUB[M]  R0, COL, 80
    ?Z  MOVE    PC, NEWLINE
        MOVE    PC, KEY

CONTROL SUB[M]  R0, R1, 0x0D
    ?Z  MOVE    CR, 1
    ?Z  MOVE    PC, NEWLINE
        SUB[M]  R0, R1, 0x0A    ; LF, but only if the byte before was no CR:
    ?Z  MOVE[M] R0, R7          ; Z after 0x0A stays only if R7, the CR, is 0
    ?Z  MOVE    PC, NEWLINE
        SUB[M]  R0, R1, 0x08    ; backspace
    ?Z  MOVE    PC, BACK
        SUB[M]  R0, R1, 0x09
    ?Z  MOVE    PC, TAB
        SUB[M]  R0, R1, 0x0C    ; CTRL-L
    ?Z  MOVE    PC, CLEAR
        SUB[M]  R0, R1, 0x1B
    ?Z  MOVE    ESC, 1
        MOVE    PC, KEY         ; ESC, or a code that does nothing

; An escape sequence: ESC [ and a final byte, of which A to D move the
; cursor, as the cursor keys send them. Other final bytes, and the
; parameters before them, do nothing. ESC without [ is dropped, and the
; byte after it is taken as it is.
INESC   SUB[M]  R0, ESC, 1
    ?!Z MOVE    PC, INCSI
        MOVE    ESC, 0
        SUB[M]  R0, R1, 0x5B    ; [
    ?!Z MOVE    PC, PLAIN
        MOVE    ESC, 2
        MOVE    PC, KEY
INCSI   SUB[M]  R0, R1, 0x40    ; parameters are below 0x40
    ?C  MOVE    PC, KEY
        MOVE    ESC, 0
        SUB[M]  R0, R1, 0x41
    ?Z  MOVE    PC, UP
        SUB[M]  R0, R1, 0x42
    ?Z  MOVE    PC, DOWN
        SUB[M]  R0, R1, 0x43
    ?Z  MOVE    PC, RIGHT
        SUB[M]  R0, R1, 0x44
    ?!Z MOVE    PC, KEY
        MOVE[M] R0, COL         ; left
    ?!Z SUB     COL, COL, 1
        MOVE    PC, KEY
UP      SUB[M]  R0, ROW, TOP
    ?!Z SUB     ROW, ROW, 1
        MOVE    PC, KEY
DOWN    SUB[M]  R0, ROW, LAST
    ?!Z ADD     ROW, ROW, 1
        MOVE    PC, KEY
RIGHT   SUB[M]  R0, COL, 79
    ?!Z ADD     COL, COL, 1
        MOVE    PC, KEY

; The first column of the next row, and a scroll after the last
NEWLINE MOVE    COL, 0
        SUB[M]  R0, ROW, LAST
    ?!Z ADD     ROW, ROW, 1
    ?!Z MOVE    PC, KEY
        MOVE    R2, SCR_TOP
        MOVE    R3, SCR_2ND
        MOVE    R4, 1120        ; the rows TOP+1 to LAST, 14 of 80 words
SCROLL  MOVE    @R2++, @R3++
        SUB[M]  R4, R4, 1
    ?!Z MOVE    PC, SCROLL
        MOVE    R3, TYPED+0x20  ; R2 is at the last row, which is cleared
        MOVE    R4, 80
        ADD     @--SP, 2, PC
        MOVE    PC, FILL
        MOVE    PC, KEY

; The character before the cursor deleted, in the cursor's row
BACK    MOVE[M] R0, COL
    ?Z  MOVE    PC, KEY
        SUB     COL, COL, 1
        ADD     @--SP, 2, PC
        MOVE    PC, CELL
        MOVE    @R2, TYPED+0x20
        MOVE    PC, KEY

; The next column that is a multiple of 8, or the next line after the last
TAB     OR      COL, COL, 7
        ADD     COL, COL, 1
        SUB[M]  R0, COL, 80
    ?!C MOVE    PC, NEWLINE
        MOVE    PC, KEY

; The typewriter's rows cleared, and the cursor at the top
CLEAR   MOVE    R2, SCR_TOP
        MOVE    R3, TYPED+0x20
        MOVE    R4, 1200        ; the rows TOP to LAST, 15 of 80 words
        ADD     @--SP, 2, PC
        MOVE    PC, FILL
        MOVE    COL, 0
        MOVE    ROW, TOP
        MOVE    PC, KEY

; CELL sets R2 to the address of the cursor's word, SCREEN + 80 * ROW + COL.
; It changes R3.
CELL    SHL     R2, ROW, 4
        SHL     R3, ROW, 6
        ADD     R2, R2, R3
        ADD     R2, R2, COL
        ADD     R2, R2, SCREEN
        MOVE    PC, @SP++

; FILL writes R3 to the R4 words from R2, and leaves R2 after them. R4 is
; at least 1. It changes R4.
FILL    MOVE    @R2++, R3
        SUB[M]  R4, R4, 1
    ?!Z MOVE    PC, FILL
        MOVE    PC, @SP++

; PRINT writes the string at R1, which ends with a 0 word, to the screen
; from R2, each character with the color R3. It changes R1, R2, and R4.
PRINT   MOVE[M] R4, @R1++
    ?Z  MOVE    PC, @SP++
        OR      @R2++, R4, R3
        MOVE    PC, PRINT

; The texts of the welcome: the position on the screen, 80 * row + column,
; the color, and the string, and -1 at the end
TEXTS   .DAT    1, BAR, NAME
        .DAT    15, BAR, VERSION
        .DAT    47, BAR, CPU
        .DAT    162, TEXT, T1
        .DAT    242, TEXT, T2
        .DAT    402, TEXT, T3
        .DAT    482, TEXT, T4
        .DAT    562, LINK, URL
        .DAT    721, BAR, KEYS
        .DAT    -1

NAME    .ASCII_L 'NiceMonMEGA65'
CPU     .ASCII_L 'the 32-bit NICE CPU of B. Ulmann'
T1      .ASCII_L 'This is the demo in the ROM, which the core runs at power-up. What you type'
T2      .ASCII_L 'on the keyboard, or send to the debug UART, appears below the blue bar.'
T3      .ASCII_L 'To run your own programs, connect a computer to the debug UART, at'
T4      .ASCII_L '2000000 baud, and load and debug them with tools/mon.py. More is at'
URL     .ASCII_L 'https://github.com/MJoergen/NiceMonMEGA65'
KEYS    .ASCII_L 'RETURN new line   DEL delete   cursor keys move   CTRL-L clear'
