; The demos in the ROM of the release. They show that the core runs, and
; that the keyboard and the screen work, on a board with no computer on its
; debug UART. Their test, in demo/Makefile, runs them in niceemu and
; compares the screens with demo/test.expected.
;
; One demo runs at a time, and a function key switches to another: the
; menu in the second row of the screen lists them. A switch starts the demo
; afresh. F3 shows the bytes of each key, in hex and as characters, F5 the
; 256 characters of the font and ramps of colors, F7 the performance
; counters and those of a prime sieve, and F9 is a game, the comet. At
; power-up the typewriter, F1, runs. Its top rows say what the core is
; and how to go further, and the rows below them take what is typed, from
; the keyboard or the UART: a character goes at the cursor, RETURN starts a
; new line, DEL (or backspace) deletes the character before the cursor, TAB
; goes to the next column that is a multiple of 8, the cursor keys move the
; cursor, and CTRL-L clears the rows.
;
; The keys come through POLL, which every demo calls. It turns the escape
; sequences of the cursor keys and of the function keys, as xterm sends
; them, into codes of their own, and on a function key with a demo it
; starts that demo. A demo starts with SP at its top, so the switch leaves
; nothing on the stack. A demo that wants the bytes themselves, as F3 does,
; puts the address of a routine in ECHO, which POLL calls with each byte.
;
; When the cursor goes past the last row, the typewriter scrolls its rows
; up by one, by copying each row to the one above it. The top rows do not
; move. The display offset (0xFFFFFF85) is not used, for three reasons. It
; would scroll the top rows away too. It wraps at the end of the screen's
; memory, whose size differs between the boards. And in niceemu it is plain
; memory, so the program would not scroll there.
;
; The program runs from the ROM, and a write to the ROM is dropped. So the
; program keeps its variables in the RAM below the stack, from 0xFFFFF000,
; and most of its state in registers. It writes no memory but these words,
; the screen, the cursor's registers, the math unit, and the stack. SP
; starts at 0xFFFFFF00, as in sim/rom.nasm, so the stack grows down from
; 0xFFFFFEFF. No register or screen is there, so on the board these words
; are RAM: the 64K words of RAM repeat through the address space, and
; 0xFFFFFEFF is RAM word 0xFEFF, far above the ROM (doc/SYSTEM.md,
; "Address map"). On the Nexys4DDR, the RAM starts at 0xFFFF2000, below
; the variables too. In niceemu they are ordinary memory.
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

; The math unit, with A and B of 32 bits, and C and D of 64 bits
M_A     .EQU    0xFFFFFF20
M_B     .EQU    0xFFFFFF21
M_UMUL  .EQU    0xFFFFFF24      ; bits 31..0 of A * B
M_UDIVQ .EQU    0xFFFFFF28      ; A / B, and the remainder
M_UDIVR .EQU    0xFFFFFF29
M_CLO   .EQU    0xFFFFFF30
M_CHI   .EQU    0xFFFFFF31
M_DLO   .EQU    0xFFFFFF32
M_DHI   .EQU    0xFFFFFF33
M_QLO   .EQU    0xFFFFFF38      ; C / D, and the remainder
M_QHI   .EQU    0xFFFFFF39
M_RLO   .EQU    0xFFFFFF3A

; The performance counters, 64 bits each. A read of the low word takes the
; snapshot that the high word returns.
P_CYC   .EQU    0xFFFFFF40
P_CYCH  .EQU    0xFFFFFF41
P_INS   .EQU    0xFFFFFF42
P_INSH  .EQU    0xFFFFFF43
P_US    .EQU    0xFFFFFF44
P_USH   .EQU    0xFFFFFF45

; The variables of F7, in the RAM below the stack
SIEVE   .EQU    0xFFFFF000      ; the sieve, a word for each number
SIEVE_N .EQU    2048            ; its numbers, 0 to SIEVE_N - 1
V_RUNS  .EQU    0xFFFFF800      ; the runs of the sieve
V_CYC   .EQU    0xFFFFF801      ; the cycles of the last run
V_INS   .EQU    0xFFFFF802      ; its instructions
V_US    .EQU    0xFFFFF803      ; and its microseconds
V_TLO   .EQU    0xFFFFF804      ; the microseconds since reset
V_THI   .EQU    0xFFFFF805
V_CLO   .EQU    0xFFFFF806      ; the cycles since reset
V_CHI   .EQU    0xFFFFF807
V_ILO   .EQU    0xFFFFF808      ; the instructions since reset
V_IHI   .EQU    0xFFFFF809

; The variables of F9, in the same RAM, as only one demo runs at a time
BODY    .EQU    0xFFFFF000      ; the ring of the comet's cells, head last
BODY_M  .EQU    2047            ; the mask of an index of the ring
G_HEAD  .EQU    0xFFFFF800      ; the index of the head in the ring
G_LEN   .EQU    0xFFFFF801      ; the cells of the comet
G_GROW  .EQU    0xFFFFF802      ; the cells it still grows by
G_DIR   .EQU    0xFFFFF803      ; its step, -80, 80, 1, or -1, or 0 at the start
G_POS   .EQU    0xFFFFF804      ; the address of the head
G_SCORE .EQU    0xFFFFF805
G_BEST  .EQU    0xFFFFF806
G_SEED  .EQU    0xFFFFF807      ; the state of RANDOM
G_NEXT  .EQU    0xFFFFF808      ; the microsecond counter at the next tick
G_TICK  .EQU    0xFFFFF809      ; the microseconds from a tick to the next
G_OVER  .EQU    0xFFFFF80A      ; 1 after the game has ended

; The colors: the background in bits 31..20, the foreground in bits 19..8
BAR     .EQU    0x00AFFF00      ; white on blue
TEXT    .EQU    0x000CCC00      ; light gray on black
LINK    .EQU    0x000FF000      ; yellow on black
MENU_ON .EQU    0xFFF00000      ; black on white, the running demo in the menu
TYPED   .EQU    0x000FFF00      ; white on black
TAIL    .EQU    0x0000F000      ; green on black

TOP     .EQU    10              ; the first row of the typewriter
LAST    .EQU    24              ; and its last
SCR_TOP .EQU    SCREEN+800      ; the address of row TOP, 80 * TOP words in
KTOP    .EQU    8               ; the first row of the keys of F3
SCR_KEY .EQU    SCREEN+640      ; its address, 80 * KTOP words in
K_MAX   .EQU    12              ; the bytes of a key that F3 shows

; The registers that hold the state of the demos
COL     .EQU    R10             ; the typewriter's column, 0 to 79, or the
                                ; bytes shown of the key, for F3
ROW     .EQU    R11             ; the row, TOP or KTOP to LAST
CR      .EQU    R8              ; 1 when the byte before was a CR
ECHO    .EQU    R12             ; a routine that POLL calls with each byte, or 0

; The codes that POLL gives for the cursor keys, above those of the bytes
KEY_UP  .EQU    0x101
KEY_DN  .EQU    0x102
KEY_RT  .EQU    0x103
KEY_LT  .EQU    0x104

        MOVE    PC, TYPEW       ; the demo at power-up

; The typewriter: the welcome, and the rows below it
TYPEW   MOVE    SP, 0xFFFFFF00  ; the stack, from RAM word 0xFEFF down
        MOVE    R6, TYPEW
        ADD     @--SP, 2, PC
        MOVE    PC, FRAME
        MOVE    R2, SCREEN+720
        MOVE    R3, BAR+0x20
        MOVE    R4, 80
        ADD     @--SP, 2, PC
        MOVE    PC, FILL
        MOVE    R5, WELCOME
        ADD     @--SP, 2, PC
        MOVE    PC, PRINTS
        MOVE    COL, 0
        MOVE    ROW, TOP
        MOVE    CR, 0
        MOVE    @SCR_CTL, 0x60  ; a blinking cursor, and no display offset
KEY     MOVE    @SCR_X, COL     ; the cursor where the next character goes
        MOVE    @SCR_Y, ROW
WAIT    ADD     @--SP, 2, PC
        MOVE    PC, POLL
        MOVE[M] R0, R1
    ?Z  MOVE    PC, WAIT
        MOVE    R7, CR          ; whether this key follows a CR
        MOVE    CR, 0
        SUB[M]  R0, R1, 0x100
    ?!C MOVE    PC, CURSOR      ; a cursor key
        SUB[M]  R0, R1, 0x20
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
        MOVE    PC, KEY         ; a code that does nothing

; The cursor keys move the cursor within the typewriter's rows
CURSOR  SUB[M]  R0, R1, KEY_UP
    ?Z  MOVE    PC, UP
        SUB[M]  R0, R1, KEY_DN
    ?Z  MOVE    PC, DOWN
        SUB[M]  R0, R1, KEY_RT
    ?Z  MOVE    PC, RIGHT
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
        MOVE    R4, 1120        ; the rows TOP+1 to LAST, 14 of 80 words
        ADD     @--SP, 2, PC
        MOVE    PC, SCROLL
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

; The key codes: each key on a row of its own, with its bytes in hex and as
; characters. ECHO shows the bytes as POLL reads them, and when POLL
; returns, the key has ended. A key that gives 0, such as a sequence that is
; no key, still ends. An ESC alone shows with the key after it, as POLL
; waits for it.
KCODES  MOVE    SP, 0xFFFFFF00
        MOVE    R6, KCODES
        ADD     @--SP, 2, PC
        MOVE    PC, FRAME
        MOVE    R2, SCREEN+560  ; the bar of row 7
        MOVE    R3, BAR+0x20
        MOVE    R4, 80
        ADD     @--SP, 2, PC
        MOVE    PC, FILL
        MOVE    R5, K_TEXTS
        ADD     @--SP, 2, PC
        MOVE    PC, PRINTS
        MOVE    COL, 0
        MOVE    ROW, KTOP
        MOVE    ECHO, SHOWB
KPOLL   ADD     @--SP, 2, PC
        MOVE    PC, POLL
        MOVE[M] R0, COL
    ?Z  MOVE    PC, KPOLL       ; no byte yet
        MOVE    COL, 0          ; the key has ended: the next row
        SUB[M]  R0, ROW, LAST
    ?!Z ADD     ROW, ROW, 1
    ?!Z MOVE    PC, KPOLL
        MOVE    R2, SCR_KEY     ; or a scroll after the last
        MOVE    R4, 1280        ; the rows KTOP+1 to LAST, 16 of 80 words
        ADD     @--SP, 2, PC
        MOVE    PC, SCROLL
        MOVE    PC, KPOLL

; SHOWB, the ECHO of F3, shows the byte R1 in the row ROW, as the byte COL of
; its key: in hex from column 2, and from column 42 as a character, or as ^
; and a character for a control code. 0x80 to 0x9F have no character, and
; the bytes after the first K_MAX of a key are not shown. It changes nothing
; but COL, which it counts up.
SHOWB   MOVE    @--SP, R2
        MOVE    @--SP, R3
        MOVE    @--SP, R4
        SUB[M]  R0, COL, K_MAX
    ?!C MOVE    PC, SHOWN
        SHL     R2, ROW, 4      ; R2 is SCREEN + 80 * ROW + 3 * COL
        SHL     R3, ROW, 6
        ADD     R2, R2, R3
        SHL     R4, COL, 1
        ADD     R4, R4, COL
        ADD     R2, R2, R4
        ADD     R2, R2, SCREEN
        SHR     R3, R1, 4
        OR      @2[R2], @HEXDIG[R3], TYPED
        AND     R3, R1, 0xF
        OR      @3[R2], @HEXDIG[R3], TYPED
        SUB[M]  R0, R1, 0x20
    ?C  MOVE    PC, CARET       ; a control code
        SUB[M]  R0, R1, 0x7F
    ?Z  MOVE    PC, CARET       ; DEL
    ?C  MOVE    PC, CHAR
        SUB[M]  R0, R1, 0xA0
    ?C  MOVE    PC, SHOWN       ; 0x80 to 0x9F
CHAR    OR      @42[R2], R1, LINK
        MOVE    PC, SHOWN
CARET   MOVE    @42[R2], LINK+0x5E
        XOR     R3, R1, 0x40    ; ^@ to ^_, and ^? for DEL
        OR      @43[R2], R3, LINK
SHOWN   ADD     COL, COL, 1
        MOVE    R4, @SP++
        MOVE    R3, @SP++
        MOVE    R2, @SP++
        MOVE    PC, @SP++

; The character set and the colors. On the left, the 256 characters in 16
; rows of 16, each row labeled with the high digit of its codes, and each
; column with the low digit. On the right, a ramp of each color of COLORS,
; with the intensities 0 to F: as backgrounds, and below them as
; foregrounds, the digits of the intensities on black. The keys do nothing
; here, but the function keys.
CHARS   MOVE    SP, 0xFFFFFF00
        MOVE    R6, CHARS
        ADD     @--SP, 2, PC
        MOVE    PC, FRAME
        MOVE    R5, C_TEXTS
        ADD     @--SP, 2, PC
        MOVE    PC, PRINTS
        MOVE    R1, 0           ; the code
        MOVE    R2, SCREEN+405  ; row 5, column 5, where code 0 goes
CROW    SHR     R3, R1, 4       ; the label of the row: its first code
        OR      @-3[R2], @HEXDIG[R3], LINK
        MOVE    @-2[R2], LINK+0x30
CCELL   OR      @R2, R1, TYPED
        ADD     R2, R2, 2
        ADD     R1, R1, 1
        AND[M]  R0, R1, 0xF
    ?!Z MOVE    PC, CCELL
        ADD     R2, R2, 48      ; the next row, 80 - 2 * 16 words on
        SUB[M]  R0, R1, 256
    ?!Z MOVE    PC, CROW
        MOVE    R2, SCREEN+444  ; row 5, column 44
        MOVE    R7, 20          ; the background
        ADD     @--SP, 2, PC
        MOVE    PC, RAMPS
        MOVE    R2, SCREEN+1164 ; row 14, column 44
        MOVE    R7, 8           ; the foreground
        ADD     @--SP, 2, PC
        MOVE    PC, RAMPS
CPOLL   ADD     @--SP, 2, PC
        MOVE    PC, POLL
        MOVE    PC, CPOLL

; RAMPS draws a row for each color of COLORS: its letter at R2, and from
; three columns on, 16 cells of two columns, with the intensities 0 to F of
; the color. R7 is where the color goes in a word: 20 for the background,
; where a cell is two blanks, or 8 for the foreground, where it is the digit
; of the intensity on black. It changes R1 to R5, R8, and R9.
RAMPS   MOVE    R5, COLORS
RROW    MOVE[M] R1, @R5++       ; the letter, or 0 after the last
    ?Z  MOVE    PC, @SP++
        OR      @R2, R1, TEXT
        MOVE    R3, @R5++       ; the color at intensity 1
        MOVE    R4, 0           ; the color of the cell
        MOVE    R8, 0           ; the intensity of the cell
        ADD     R9, R2, 3       ; the cell
RCELL   SHL     R1, R4, R7
        SUB[M]  R0, R7, 20
    ?Z  OR      @R9, R1, 0x20
    ?Z  OR      @1[R9], R1, 0x20
    ?!Z OR      @R9, R1, @HEXDIG[R8]
        ADD     R9, R9, 2
        ADD     R4, R4, R3
        ADD     R8, R8, 1
        SUB[M]  R0, R8, 16
    ?!Z MOVE    PC, RCELL
        ADD     R2, R2, 80
        MOVE    PC, RROW

; The performance counters: those since reset, as a clock and as numbers,
; and the clock's frequency, cycles per microsecond; and those of a run of a
; prime sieve, which runs again before each update of the screen, with the
; cycles per instruction and the instructions per microsecond. The keys do
; nothing here, but the function keys. The values end at column 60, and R3
; is their color.
COUNTS  MOVE    SP, 0xFFFFFF00
        MOVE    R6, COUNTS
        ADD     @--SP, 2, PC
        MOVE    PC, FRAME
        MOVE    R5, P_TEXTS
        ADD     @--SP, 2, PC
        MOVE    PC, PRINTS
        MOVE    @V_RUNS, 0
PLOOP   MOVE    @V_CYC, @P_CYC  ; a run of the sieve, and its counts
        MOVE    @V_INS, @P_INS
        MOVE    @V_US, @P_US
        ADD     @--SP, 2, PC
        MOVE    PC, PRIMES
        SUB     @V_CYC, @P_CYC, @V_CYC
        SUB     @V_INS, @P_INS, @V_INS
        SUB     @V_US, @P_US, @V_US
        ADD     @V_RUNS, @V_RUNS, 1
        MOVE    R3, TYPED
        MOVE    R4, 20
        MOVE    R7, 0
        MOVE    R2, SCREEN+1100 ; the primes, from R1
        ADD     @--SP, 2, PC
        MOVE    PC, DEC64
        MOVE    R1, @V_RUNS
        MOVE    R7, 0
        MOVE    R2, SCREEN+1020
        ADD     @--SP, 2, PC
        MOVE    PC, DEC64
        MOVE    R1, @V_INS
        MOVE    R7, 0
        MOVE    R2, SCREEN+1180
        ADD     @--SP, 2, PC
        MOVE    PC, DEC64
        MOVE    R1, @V_CYC
        MOVE    R7, 0
        MOVE    R2, SCREEN+1260
        ADD     @--SP, 2, PC
        MOVE    PC, DEC64
        MOVE    R1, @V_US
        MOVE    R7, 0
        MOVE    R2, SCREEN+1340
        ADD     @--SP, 2, PC
        MOVE    PC, DEC64
        MOVE    @M_A, @V_CYC    ; 100 times the cycles per instruction
        MOVE    @M_B, 100
        MOVE    @M_A, @M_UMUL
        MOVE    @M_B, @V_INS
        MOVE    R1, @M_UDIVQ
        MOVE    R2, SCREEN+1417
        ADD     @--SP, 2, PC
        MOVE    PC, FIX2
        MOVE    @M_A, @V_INS    ; 100 times the instructions per microsecond
        MOVE    @M_B, 100
        MOVE    @M_A, @M_UMUL
        MOVE    @M_B, @V_US
        MOVE    R1, @M_UDIVQ
        MOVE    R2, SCREEN+1497
        ADD     @--SP, 2, PC
        MOVE    PC, FIX2
        MOVE    @V_TLO, @P_US   ; the counters since reset, low word first
        MOVE    @V_THI, @P_USH
        MOVE    @V_CLO, @P_CYC
        MOVE    @V_CHI, @P_CYCH
        MOVE    @V_ILO, @P_INS
        MOVE    @V_IHI, @P_INSH
        MOVE    R4, 20
        MOVE    R1, @V_TLO
        MOVE    R7, @V_THI
        MOVE    R2, SCREEN+540
        ADD     @--SP, 2, PC
        MOVE    PC, DEC64
        MOVE    R1, @V_CLO
        MOVE    R7, @V_CHI
        MOVE    R2, SCREEN+620
        ADD     @--SP, 2, PC
        MOVE    PC, DEC64
        MOVE    R1, @V_ILO
        MOVE    R7, @V_IHI
        MOVE    R2, SCREEN+700
        ADD     @--SP, 2, PC
        MOVE    PC, DEC64
        MOVE    @M_CLO, @V_CLO  ; the cycles per microsecond
        MOVE    @M_CHI, @V_CHI
        MOVE    @M_DLO, @V_TLO
        MOVE    @M_DHI, @V_THI
        MOVE    R1, @M_QLO
        MOVE    R7, @M_QHI
        MOVE    R2, SCREEN+780
        ADD     @--SP, 2, PC
        MOVE    PC, DEC64
        MOVE    @M_CLO, @V_TLO  ; the clock: the seconds in R5
        MOVE    @M_CHI, @V_THI
        MOVE    @M_DLO, 1000000
        MOVE    @M_DHI, 0
        MOVE    R5, @M_QLO
        MOVE    @M_A, @M_RLO    ; the hundredths
        MOVE    @M_B, 10000
        MOVE    R1, @M_UDIVQ
        MOVE    R2, SCREEN+458
        ADD     @--SP, 2, PC
        MOVE    PC, TWO
        MOVE    @M_A, R5        ; the seconds, and the minutes in R5
        MOVE    @M_B, 60
        MOVE    R1, @M_UDIVR
        MOVE    R5, @M_UDIVQ
        MOVE    R2, SCREEN+455
        ADD     @--SP, 2, PC
        MOVE    PC, TWO
        MOVE    @M_A, R5        ; the minutes, and the hours in R5
        MOVE    @M_B, 60
        MOVE    R1, @M_UDIVR
        MOVE    R5, @M_UDIVQ
        MOVE    R2, SCREEN+452
        ADD     @--SP, 2, PC
        MOVE    PC, TWO
        MOVE    R1, R5
        MOVE    R7, 0
        MOVE    R4, 8
        MOVE    R2, SCREEN+451
        ADD     @--SP, 2, PC
        MOVE    PC, DEC64
        ADD     @--SP, 2, PC
        MOVE    PC, POLL
        MOVE    PC, PLOOP

; PRIMES runs the sieve of Eratosthenes on the numbers below SIEVE_N, and
; sets R1 to the primes among them. It changes R2 to R6.
PRIMES  MOVE    R2, SIEVE       ; every number a prime
        MOVE    R3, 1
        MOVE    R4, SIEVE_N
        ADD     @--SP, 2, PC
        MOVE    PC, FILL
        MOVE    R5, 2           ; R5 is the prime, whose multiples go
PRIME   MOVE[M] R0, @SIEVE[R5]
    ?Z  MOVE    PC, PNEXT
        MOVE    @M_A, R5        ; from its square on
        MOVE    @M_B, R5
        MOVE    R6, @M_UMUL
MULT    SUB[M]  R0, R6, SIEVE_N
    ?!C MOVE    PC, PNEXT
        MOVE    @SIEVE[R6], 0
        ADD     R6, R6, R5
        MOVE    PC, MULT
PNEXT   ADD     R5, R5, 1
        SUB[M]  R0, R5, 46      ; up to 45, as 46 * 46 is above SIEVE_N
    ?!Z MOVE    PC, PRIME
        MOVE    R1, 0
        MOVE    R5, 2
PCOUNT  ADD     R1, R1, @SIEVE[R5]
        ADD     R5, R5, 1
        SUB[M]  R0, R5, SIEVE_N
    ?!Z MOVE    PC, PCOUNT
        MOVE    PC, @SP++

; DEC64 writes R7:R1 in decimal, in the color R3, right-aligned in the R4
; words before R2, with blanks before it. R4 must have room for the digits.
; It changes R1, R2, R7, and R9.
DEC64   SUB     R9, R2, R4
DBLANK  OR      @R9++, R3, 0x20
        SUB[M]  R0, R9, R2
    ?!Z MOVE    PC, DBLANK
        MOVE    @M_DLO, 10
        MOVE    @M_DHI, 0
DIGIT   MOVE    @M_CLO, R1
        MOVE    @M_CHI, R7
        ADD     R9, @M_RLO, 0x30
        OR      @--R2, R9, R3
        MOVE    R1, @M_QLO
        MOVE    R7, @M_QHI
        OR[M]   R0, R1, R7
    ?!Z MOVE    PC, DIGIT
        MOVE    PC, @SP++

; TWO writes R1, which is below 100, as two digits at R2, in the color R3.
; It changes R9.
TWO     MOVE    @M_A, R1
        MOVE    @M_B, 10
        ADD     R9, @M_UDIVQ, 0x30
        OR      @R2, R9, R3
        ADD     R9, @M_UDIVR, 0x30
        OR      @1[R2], R9, R3
        MOVE    PC, @SP++

; FIX2 writes R1 / 100 with two decimals and its point at R2, in the color
; R3, and the integer part right-aligned in the 10 words before the point.
; It changes R1, R2, R4, R7, and R9.
FIX2    MOVE    @M_A, R1
        MOVE    @M_B, 100
        MOVE    R1, @M_UDIVQ
        MOVE    @--SP, @M_UDIVR
        MOVE    @--SP, R2
        OR      @R2, R3, 0x2E
        MOVE    R7, 0
        MOVE    R4, 10
        ADD     @--SP, 2, PC
        MOVE    PC, DEC64
        MOVE    R2, @SP++
        MOVE    R1, @SP++
        ADD     R2, R2, 1
        ADD     @--SP, 2, PC
        MOVE    PC, TWO
        MOVE    PC, @SP++

; The comet, a game. The comet, @, moves through the field, rows 4 to 23
; inside a frame, one cell at each tick, and the cursor keys steer it. Its
; tail follows it. A star, *, makes the tail longer by 4, scores 1, and
; makes the ticks shorter, from 150 to 50 ms, and a new star comes at a
; random free cell. The game ends when the comet hits the frame or its
; tail, and then a key starts a new game. The comet waits for a cursor key
; at the start, and a key that would turn it back is ignored.
;
; The ticks come from the microsecond counter, and the game takes one key at
; each tick. So in niceemu, where a microsecond is a step, an input file is
; a script with one key for each tick. RANDOM steps while the game waits
; for a tick, so on the board the stars depend on when the keys come. The
; ring BODY holds the addresses of the comet's cells, and the screen itself
; tells what is in a cell, by the whole word, as the frame is blanks too.
GAME    MOVE    SP, 0xFFFFFF00
        MOVE    R6, GAME
        ADD     @--SP, 2, PC
        MOVE    PC, FRAME
        MOVE    R5, G_TEXTS
        ADD     @--SP, 2, PC
        MOVE    PC, PRINTS
        MOVE    @G_BEST, 0
        MOVE    @G_SEED, 0x2545F491
GNEW    MOVE    R2, SCREEN+240  ; a new game: the frame, and the field cleared
        MOVE    R3, BAR+0x20
        MOVE    R4, 80
        ADD     @--SP, 2, PC
        MOVE    PC, FILL
        MOVE    R5, 20          ; R2 is at row 4
GROW    MOVE    @R2++, BAR+0x20
        MOVE    R3, TEXT+0x20
        MOVE    R4, 78
        ADD     @--SP, 2, PC
        MOVE    PC, FILL
        MOVE    @R2++, BAR+0x20
        SUB[M]  R5, R5, 1
    ?!Z MOVE    PC, GROW
        MOVE    R3, BAR+0x20
        MOVE    R4, 80
        ADD     @--SP, 2, PC
        MOVE    PC, FILL
        MOVE    R2, SCREEN+1079 ; the comet, in the middle
        MOVE    @R2, TYPED+0x40
        MOVE    @G_POS, R2
        MOVE    @G_HEAD, 0
        MOVE    @BODY, R2
        MOVE    @G_LEN, 1
        MOVE    @G_GROW, 2
        MOVE    @G_DIR, 0
        MOVE    @G_SCORE, 0
        MOVE    @G_OVER, 0
        MOVE    @G_TICK, 150000
        ADD     @G_NEXT, @P_US, 150000
        ADD     @--SP, 2, PC
        MOVE    PC, STAR
        MOVE    R1, G_START
        ADD     @--SP, 2, PC
        MOVE    PC, STATUS
GTICK   ADD     @--SP, 2, PC    ; wait for the tick
        MOVE    PC, RANDOM
        SUB[M]  R0, @P_US, @G_NEXT
    ?N  MOVE    PC, GTICK
        ADD     @G_NEXT, @G_NEXT, @G_TICK
        ADD     @--SP, 2, PC
        MOVE    PC, POLL
        MOVE[M] R0, @G_OVER
    ?Z  MOVE    PC, GKEY
        MOVE[M] R0, R1          ; after the end, a key starts a new game
    ?!Z MOVE    PC, GNEW
        MOVE    PC, GTICK
GKEY    SUB     R2, R1, KEY_UP
        SUB[M]  R0, R2, 4
    ?!C MOVE    PC, GMOVE       ; no cursor key
        MOVE    R3, @GSTEPS[R2]
        ADD[M]  R0, R3, @G_DIR  ; 0 for the key that turns it back
    ?!Z MOVE    @G_DIR, R3
GMOVE   MOVE[M] R4, @G_DIR
    ?Z  MOVE    PC, GTICK       ; not started yet
        ADD     R5, @G_POS, R4  ; the cell of the new head
        MOVE    R7, 0           ; 1 for a star
        SUB[M]  R0, @R5, TYPED+0x2A
    ?Z  MOVE    PC, GSTAR
        SUB[M]  R0, @R5, TEXT+0x20
    ?!Z MOVE    PC, GOVER       ; the frame, a blank on blue, or the tail
GSTEP   MOVE    R6, @G_POS      ; the old head is now tail
        MOVE    @R6, TAIL+0x6F
        MOVE    @R5, TYPED+0x40
        MOVE    @G_POS, R5
        ADD     R2, @G_HEAD, 1
        AND     R2, R2, BODY_M
        MOVE    @G_HEAD, R2
        MOVE    @BODY[R2], R5
        MOVE[M] R0, @G_GROW
    ?Z  MOVE    PC, GTAIL
        SUB     @G_GROW, @G_GROW, 1
        ADD     @G_LEN, @G_LEN, 1
        MOVE    PC, GDONE
GTAIL   SUB     R2, R2, @G_LEN  ; the last cell of the tail is cleared
        AND     R2, R2, BODY_M
        MOVE    R6, @BODY[R2]
        MOVE    @R6, TEXT+0x20
GDONE   MOVE[M] R0, R7
    ?!Z ADD     @--SP, 2, PC
    ?!Z MOVE    PC, STAR
        MOVE    PC, GTICK
GSTAR   ADD     @G_SCORE, @G_SCORE, 1
        ADD     @G_GROW, @G_GROW, 4
        SUB[M]  R0, @G_TICK, 50000
    ?!Z SUB     @G_TICK, @G_TICK, 5000
        MOVE    R1, G_START
        ADD     @--SP, 2, PC
        MOVE    PC, STATUS
        MOVE    R7, 1
        MOVE    PC, GSTEP
GOVER   MOVE    @G_OVER, 1
        SUB[M]  R0, @G_BEST, @G_SCORE
    ?C  MOVE    @G_BEST, @G_SCORE
        MOVE    R1, G_END
        ADD     @--SP, 2, PC
        MOVE    PC, STATUS
        MOVE    PC, GTICK

; STAR puts a star at a random free cell of the field. It changes R1 to R4.
STAR    ADD     @--SP, 2, PC
        MOVE    PC, RANDOM
        MOVE    @M_A, R1        ; one of the 20 * 78 cells
        MOVE    @M_B, 1560
        MOVE    @M_A, @M_UDIVR
        MOVE    @M_B, 78
        SHL     R2, @M_UDIVQ, 4 ; R2 is SCREEN + 80 * (row + 4) + col + 1
        SHL     R3, @M_UDIVQ, 6
        ADD     R2, R2, R3
        ADD     R2, R2, @M_UDIVR
        ADD     R2, R2, SCREEN+321
        SUB[M]  R0, @R2, TEXT+0x20
    ?!Z MOVE    PC, STAR        ; not free: another
        MOVE    @R2, TYPED+0x2A
        MOVE    PC, @SP++

; RANDOM steps G_SEED, a xorshift generator, and sets R1 to it. It changes
; R2.
RANDOM  MOVE    R1, @G_SEED
        SHL     R2, R1, 13
        XOR     R1, R1, R2
        SHR     R2, R1, 17
        XOR     R1, R1, R2
        SHL     R2, R1, 5
        XOR     R1, R1, R2
        MOVE    @G_SEED, R1
        MOVE    PC, @SP++

; STATUS writes the score and the best in row 2, and the string at R1 after
; them. It changes R1, R2, R3, R4, R7, and R9.
STATUS  MOVE    @--SP, R1
        MOVE    R3, TYPED
        MOVE    R4, 5
        MOVE    R1, @G_SCORE
        MOVE    R7, 0
        MOVE    R2, SCREEN+173
        ADD     @--SP, 2, PC
        MOVE    PC, DEC64
        MOVE    R1, @G_BEST
        MOVE    R7, 0
        MOVE    R2, SCREEN+187
        ADD     @--SP, 2, PC
        MOVE    PC, DEC64
        MOVE    R2, SCREEN+192
        MOVE    R3, TEXT+0x20
        MOVE    R4, 48
        ADD     @--SP, 2, PC
        MOVE    PC, FILL
        MOVE    R1, @SP++
        MOVE    R2, SCREEN+192
        MOVE    R3, LINK
        ADD     @--SP, 2, PC
        MOVE    PC, PRINT
        MOVE    PC, @SP++

; POLL takes a key from the input, if one has arrived, and sets R1 to it: a
; byte, KEY_UP to KEY_LT for a cursor key, or 0 when there is none. It
; reads the escape sequences that xterm sends for the cursor keys and the
; function keys, and waits for the bytes of a sequence after its ESC. A
; function key with a demo in FKEYS starts that demo, and POLL does not
; return. Other sequences give 0. ESC and a byte that starts none gives that
; byte, so an ESC alone is dropped. At the end of the input, POLL halts. It
; changes R1 to R5, and calls ECHO, unless it is 0, with each byte in R1.
POLL    ADD     @--SP, 2, PC
        MOVE    PC, READ
    ?Z  MOVE    PC, @SP++       ; no byte, and R1 is 0
        SUB[M]  R0, R1, 0x1B
    ?!Z MOVE    PC, @SP++       ; a byte other than ESC
ESCAPE  ADD     @--SP, 2, PC
        MOVE    PC, NEXT
        SUB[M]  R0, R1, 0x1B
    ?Z  MOVE    PC, ESCAPE      ; ESC again starts again
        SUB[M]  R0, R1, 0x5B    ; [
    ?Z  MOVE    PC, CSI
        SUB[M]  R0, R1, 0x4F    ; O
    ?!Z MOVE    PC, @SP++
; ESC O and a byte: A to D are the cursor keys, and P to S F1 to F4
        ADD     @--SP, 2, PC
        MOVE    PC, NEXT
        SUB     R2, R1, 0x41
        SUB[M]  R0, R2, 4
    ?C  MOVE    PC, ARROW
        SUB     R2, R1, 0x50
        SUB[M]  R0, R2, 4
    ?C  MOVE    PC, FKEY
        MOVE    PC, NONE
; ESC [, parameters, and a final byte, which is 0x40 or above. A to D are
; the cursor keys, whatever the parameters. ~ is a function key, whose
; number in FNUMS is the first parameter. R3 is the first parameter, and R4
; is 1 once it has ended.
CSI     MOVE    R3, 0
        MOVE    R4, 0
PARAM   ADD     @--SP, 2, PC
        MOVE    PC, NEXT
        SUB[M]  R0, R1, 0x40
    ?!C MOVE    PC, FINAL
        SUB     R2, R1, 0x30
        SUB[M]  R0, R2, 10
    ?!C MOVE    R4, 1           ; not a digit, such as ;, ends the first
        MOVE[M] R0, R4
    ?!Z MOVE    PC, PARAM
        SHL     R5, R3, 1       ; R3 is 10 * R3 + the digit
        SHL     R3, R3, 3
        ADD     R3, R3, R5
        ADD     R3, R3, R2
        MOVE    PC, PARAM
FINAL   SUB     R2, R1, 0x41
        SUB[M]  R0, R2, 4
    ?C  MOVE    PC, ARROW
        SUB[M]  R0, R1, 0x7E    ; ~
    ?!Z MOVE    PC, NONE
        MOVE    R2, 0
FIND    SUB[M]  R0, R3, @FNUMS[R2]
    ?Z  MOVE    PC, FKEY
        ADD     R2, R2, 1
        SUB[M]  R0, R2, 12
    ?!Z MOVE    PC, FIND
NONE    MOVE    R1, 0
        MOVE    PC, @SP++
ARROW   ADD     R1, R2, KEY_UP  ; R2 is 0 to 3 for A to D
        MOVE    PC, @SP++
FKEY    MOVE[M] R1, @FKEYS[R2]  ; R2 is 0 to 11 for F1 to F12
    ?Z  MOVE    PC, @SP++       ; a key without a demo, and R1 is 0
        MOVE    PC, R1

; READ reads the console. Z is set when no byte has arrived, and R1 is the
; byte, or 0. It calls ECHO with the byte, unless ECHO is 0. At the end of
; the input it halts.
READ    MOVE    R1, @CONSOLE
        AND[M]  R0, R1, 0x200   ; the end of the input
    ?!Z HALT
        AND[M]  R0, R1, 0x100
    ?Z  MOVE    PC, @SP++       ; no byte, and R1 is 0
        AND     R1, R1, 0xFF
        MOVE[M] R0, ECHO
    ?!Z ADD     @--SP, 1, PC    ; MOVE PC, ECHO is a word long
    ?!Z MOVE    PC, ECHO
        OR[M]   R0, R1, 0x100   ; Z is clear, also for a byte of 0
        MOVE    PC, @SP++

; NEXT waits for a byte of the console, and sets R1 to it
NEXT    ADD     @--SP, 2, PC
        MOVE    PC, READ
    ?Z  MOVE    PC, NEXT
        MOVE    PC, @SP++

; FRAME clears the screen and hides the cursor, and draws the two rows at
; the top that every demo has: the title bar, and the menu of the demos, in
; which the demo that starts at R6 stands out. It sets ECHO to 0, and
; changes R1 to R5.
FRAME   MOVE    @SCR_CTL, 0
        MOVE    ECHO, 0
        MOVE    R2, SCREEN
        MOVE    R3, TEXT+0x20
        MOVE    R4, 2000
        ADD     @--SP, 2, PC
        MOVE    PC, FILL
        MOVE    R2, SCREEN
        MOVE    R3, BAR+0x20
        MOVE    R4, 160
        ADD     @--SP, 2, PC
        MOVE    PC, FILL
        MOVE    R5, TITLE
        ADD     @--SP, 2, PC
        MOVE    PC, PRINTS
        MOVE    R5, MENU
ITEM    MOVE[M] R2, @R5++       ; the position, or -1 at the end
    ?X  MOVE    PC, @SP++
        ADD     R2, R2, SCREEN
        MOVE    R3, BAR
        SUB[M]  R0, R6, @R5++   ; the demo
    ?Z  MOVE    R3, MENU_ON
        MOVE    R1, @R5++       ; the string
        ADD     @--SP, 2, PC
        MOVE    PC, PRINT
        MOVE    PC, ITEM

; SCROLL moves the R4 words from R2 + 80 to R2, which scrolls their rows up
; by one, and clears the row after them. R4 is at least 1. It changes R2 to
; R4.
SCROLL  ADD     R3, R2, 80
COPY    MOVE    @R2++, @R3++
        SUB[M]  R4, R4, 1
    ?!Z MOVE    PC, COPY
        MOVE    R3, TYPED+0x20
        MOVE    R4, 80
        MOVE    PC, FILL        ; which returns to the caller

; PRINTS writes the texts of the table at R5 to the screen. Each has its
; position on the screen, 80 * row + column, its color, and its string, and
; -1 ends the table. It changes R1 to R5.
PRINTS  MOVE[M] R2, @R5++
    ?X  MOVE    PC, @SP++
        ADD     R2, R2, SCREEN
        MOVE    R3, @R5++
        MOVE    R1, @R5++
        ADD     @--SP, 2, PC
        MOVE    PC, PRINT
        MOVE    PC, PRINTS

; The demos of the function keys F1 to F12, or 0 for none
FKEYS   .DAT    TYPEW, 0, KCODES, 0, CHARS, 0, COUNTS, 0, GAME, 0, 0, 0, 0, 0, 0, 0, 0, 0

; The numbers before ~ of F1 to F12. xterm sends ESC O P to ESC O S for F1
; to F4, and 11 to 14 are those of the VT220.
FNUMS   .DAT    11, 12, 13, 14, 15, 17, 18, 19, 20, 21, 23, 24

; The menu: the position of each entry, the demo, and the string, and -1 at
; the end
MENU    .DAT    80, TYPEW, M_TYPEW
        .DAT    96, KCODES, M_KEYS
        .DAT    111, CHARS, M_CHARS
        .DAT    127, COUNTS, M_COUNT
        .DAT    141, GAME, M_GAME
        .DAT    -1

; The texts of the title bar, and of the welcome
TITLE   .DAT    1, BAR, NAME
        .DAT    15, BAR, VERSION
        .DAT    47, BAR, CPU
        .DAT    -1
WELCOME .DAT    242, TEXT, T1
        .DAT    322, TEXT, T2
        .DAT    482, TEXT, T3
        .DAT    562, TEXT, T4
        .DAT    642, LINK, URL
        .DAT    721, BAR, KEYS
        .DAT    -1

NAME    .ASCII_L 'NiceMonMEGA65'
CPU     .ASCII_L 'the 32-bit NICE CPU of B. Ulmann'
M_TYPEW .ASCII_L ' F1 typewriter '
M_KEYS  .ASCII_L ' F3 key codes '
M_CHARS .ASCII_L ' F5 characters '
M_COUNT .ASCII_L ' F7 counters '
M_GAME  .ASCII_L ' F9 comet '
T1      .ASCII_L 'This is the demo in the ROM, which the core runs at power-up. What you type'
T2      .ASCII_L 'on the keyboard, or send to the debug UART, appears below the blue bar.'
T3      .ASCII_L 'To run your own programs, connect a computer to the debug UART, at'
T4      .ASCII_L '2000000 baud, and load and debug them with tools/mon.py. More is at'
URL     .ASCII_L 'https://github.com/MJoergen/NiceMonMEGA65'
KEYS    .ASCII_L 'RETURN new line   DEL delete   cursor keys move   CTRL-L clear'

; The texts of F3
K_TEXTS .DAT    242, TEXT, K1
        .DAT    322, TEXT, K2
        .DAT    402, TEXT, K3
        .DAT    562, BAR, K_HEX
        .DAT    602, BAR, K_CHARS
        .DAT    -1

K1      .ASCII_L 'Each key that you type, or byte sequence that the debug UART sends, shows'
K2      .ASCII_L 'its bytes in hex and as characters. A control code shows as ^ and a'
K3      .ASCII_L 'character, so ^[ is ESC and ^? is DEL. A function key with a demo starts it.'
K_HEX   .ASCII_L 'Bytes in hex'
K_CHARS .ASCII_L 'As characters'
HEXDIG  .ASCII_L '0123456789ABCDEF'

; The texts of F5
C_TEXTS .DAT    242, LINK, C1
        .DAT    284, LINK, C2
        .DAT    325, TEXT, C_DIGIT
        .DAT    364, TEXT, C_BACK
        .DAT    1084, TEXT, C_FORE
        .DAT    1762, TEXT, C_NAMES
        .DAT    -1

C1      .ASCII_L 'Characters, ISO 8859-1'
C2      .ASCII_L 'Colors, 4 bits of red, green, blue'
C_DIGIT .ASCII_L '0 1 2 3 4 5 6 7 8 9 A B C D E F'
C_BACK  .ASCII_L 'Backgrounds, 0 to F'
C_FORE  .ASCII_L 'Foregrounds, 0 to F'
C_NAMES .ASCII_L 'R red   G green   B blue   Y yellow   C cyan   M magenta   W gray'

; The colors of the ramps: the letter, and the 12-bit color at intensity 1
COLORS  .DAT    0x52, 0x100     ; R
        .DAT    0x47, 0x010     ; G
        .DAT    0x42, 0x001     ; B
        .DAT    0x59, 0x110     ; Y
        .DAT    0x43, 0x011     ; C
        .DAT    0x4D, 0x101     ; M
        .DAT    0x57, 0x111     ; W
        .DAT    0

; The texts of F7
P_TEXTS .DAT    242, LINK, P1
        .DAT    404, TEXT, P_TIME
        .DAT    451, TYPED, P_COLON
        .DAT    454, TYPED, P_COLON
        .DAT    457, TYPED, P_POINT
        .DAT    484, TEXT, L_US
        .DAT    564, TEXT, L_CYC
        .DAT    644, TEXT, L_INS
        .DAT    724, TEXT, P_CLOCK
        .DAT    882, LINK, P2
        .DAT    964, TEXT, P_RUNS
        .DAT    1044, TEXT, P_PRIMES
        .DAT    1124, TEXT, L_INS
        .DAT    1204, TEXT, L_CYC
        .DAT    1284, TEXT, L_US
        .DAT    1364, TEXT, P_CPI
        .DAT    1444, TEXT, P_IPUS
        .DAT    1602, TEXT, P3
        .DAT    1682, TEXT, P4
        .DAT    -1

P1      .ASCII_L 'Since reset, while the core runs'
P2      .ASCII_L 'A prime sieve to 2048, run before each update'
P3      .ASCII_L 'On the board, the time is real, and the clock is 100 MHz, or 90 MHz on the'
P4      .ASCII_L 'Nexys4DDR. In niceemu, each step counts as a cycle and as a microsecond.'
P_TIME  .ASCII_L 'Time, h:mm:ss.hh'
L_US    .ASCII_L 'Microseconds'
L_CYC   .ASCII_L 'Cycles'
L_INS   .ASCII_L 'Instructions'
P_CLOCK .ASCII_L 'Clock in MHz, cycles per microsecond'
P_RUNS  .ASCII_L 'Runs'
P_PRIMES .ASCII_L 'Primes found'
P_CPI   .ASCII_L 'Cycles per instruction'
P_IPUS  .ASCII_L 'Instructions per microsecond'
P_COLON .ASCII_L ':'
P_POINT .ASCII_L '.'

; The texts of F9, and its messages
G_TEXTS .DAT    162, TEXT, G_SCOREL
        .DAT    176, TEXT, G_BESTL
        .DAT    -1

G_SCOREL .ASCII_L 'Score'
G_BESTL .ASCII_L 'Best'
G_START .ASCII_L 'The cursor keys steer the comet @ to the stars *'
G_END   .ASCII_L 'Game over. A key starts a new game.'

; The steps of the cursor keys up, down, right, and left
GSTEPS  .DAT    -80, 80, 1, -1
