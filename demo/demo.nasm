; The demos in the ROM of the release. They show that the core runs, and
; that the keyboard and the screen work, on a board with no computer on its
; debug UART. Their test, in demo/Makefile, runs them in niceemu and
; compares the screens with demo/test.expected.
;
; One demo runs at a time, and a function key switches to another: the
; menu in the second row of the screen lists them. A switch starts the demo
; afresh. F3 shows the bytes of each key, in hex and as characters, F5 the
; 256 characters of the font and ramps of colors, F7 the performance
; counters and those of a prime sieve, F9 is a game, the comet, and F11 is
; the board: it tests the RAM, the math unit, the timer's interrupts, and
; the counters, and shows and sets the Ethernet station's addresses.
; At power-up the typewriter, F1, runs. Its top rows say what the core is
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
M_SMUL  .EQU    0xFFFFFF22      ; A * B, signed, and its bits 63..32
M_SMULH .EQU    0xFFFFFF23
M_UMULH .EQU    0xFFFFFF25      ; bits 63..32 of A * B
M_SDIVQ .EQU    0xFFFFFF26      ; A / B, signed, and the remainder
M_SDIVR .EQU    0xFFFFFF27
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

; The variables of F11, in the same RAM, and the RAM that it tests, which
; is RAM on every board
S_TICKS .EQU    0xFFFFF800      ; the interrupts of the timer
B_MODE  .EQU    0xFFFFF810      ; 0, or 1 or 2 while an IP or MAC address is typed
RAM_LO  .EQU    0xFFFF8000      ; the RAM tested, up to the variables
RAM_N   .EQU    28672

; The timer, and the vector of its interrupt, whose entry in the table at
; VBASE * 256 is at 0x7F41
TM_PER  .EQU    0xFFFFFF10      ; the period, in cycles, or 0 to stop
TM_VEC  .EQU    0xFFFFFF12
VBASE   .EQU    0x7F
VECTOR  .EQU    0x41

; The Ethernet station (doc/SYSTEM.md, "The Ethernet station")
E_GOOD  .EQU    0xFFFFFF98      ; the good frames received
E_BAD   .EQU    0xFFFFFF99      ; the bad frames received, and the dropped ones
E_IP    .EQU    0xFFFFFF9A      ; the IP address, the first byte in bits 31..24
E_MACH  .EQU    0xFFFFFF9B      ; MAC bytes 0 and 1, in bits 15..0
E_MACL  .EQU    0xFFFFFF9C      ; MAC bytes 2 to 5
E_SENT  .EQU    0xFFFFFF9D      ; the frames sent

; The colors: the background in bits 31..20, the foreground in bits 19..8
BAR     .EQU    0x00AFFF00      ; white on blue
TEXT    .EQU    0x000CCC00      ; light gray on black
LINK    .EQU    0x000FF000      ; yellow on black
MENU_ON .EQU    0xFFF00000      ; black on white, the running demo in the menu
TYPED   .EQU    0x000FFF00      ; white on black
TAIL    .EQU    0x0000F000      ; green on black
RED     .EQU    0x000F0000      ; red on black

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

; The longest wait for the next byte of an escape sequence, in microseconds.
; A sequence from the keyboard or a terminal comes at once, and a person
; cannot type a byte after ESC that fast.
T_ESC   .EQU    10000

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
; no key, still ends. An ESC shows with the bytes that come within T_ESC
; after it, as POLL waits for them, so an ESC alone has a row of its own.
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
; each tick. Each tick sets the next one from the time that it came, so a
; tick that comes late delays the ticks after it, and they do not run back
; to back to catch up. So in niceemu, where a microsecond is a step, an input file is
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
        ADD     @G_NEXT, @P_US, @G_TICK ; from now, not from G_NEXT
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

; The board: the self-test of the RAM from RAM_LO, the math unit, the timer's
; interrupts, and the performance counters, each with PASS or FAIL, once each
; time that F11 starts it. R10 counts the failures. Then the Ethernet
; station's addresses and counts, which BLOOP shows again and again, and
; which I and M change (see ESTART).
BOARD   MOVE    SP, 0xFFFFFF00
        MOVE    R6, BOARD
        ADD     @--SP, 2, PC
        MOVE    PC, FRAME
        MOVE    R5, S_TEXTS
        ADD     @--SP, 2, PC
        MOVE    PC, PRINTS
        MOVE    R10, 0
        ADD     @--SP, 2, PC
        MOVE    PC, TRAM
        MOVE    R2, SCREEN+450
        ADD     @--SP, 2, PC
        MOVE    PC, RESULT
        ADD     @--SP, 2, PC
        MOVE    PC, TMATH
        MOVE    R2, SCREEN+530
        ADD     @--SP, 2, PC
        MOVE    PC, RESULT
        ADD     @--SP, 2, PC
        MOVE    PC, TTIMER
        MOVE    R2, SCREEN+610
        ADD     @--SP, 2, PC
        MOVE    PC, RESULT
        ADD     @--SP, 2, PC
        MOVE    PC, TCOUNT
        MOVE    R2, SCREEN+690
        ADD     @--SP, 2, PC
        MOVE    PC, RESULT
        MOVE    R1, S_PASSED
        MOVE    R3, TAIL
        MOVE[M] R0, R10
    ?!Z MOVE    R1, S_FAILED
    ?!Z MOVE    R3, RED
        MOVE    R2, SCREEN+802
        ADD     @--SP, 2, PC
        MOVE    PC, PRINT
        ADD     @--SP, 2, PC
        MOVE    PC, EIDLE
BLOOP   ADD     @--SP, 2, PC
        MOVE    PC, SHOWNET
        ADD     @--SP, 2, PC
        MOVE    PC, POLL
        MOVE[M] R0, R1
    ?Z  MOVE    PC, BLOOP       ; no key
        MOVE[M] R0, @B_MODE
    ?!Z MOVE    PC, BEDIT       ; an address is being typed
        OR      R1, R1, 0x20    ; I or i, M or m
        SUB[M]  R0, R1, 0x69
    ?Z  MOVE    R7, 1
    ?Z  MOVE    PC, ESTART
        SUB[M]  R0, R1, 0x6D
    ?Z  MOVE    R7, 2
    ?Z  MOVE    PC, ESTART
        MOVE    PC, BLOOP

; Each test sets R1 to 0 when it passes. When it fails, R1 is 1, and R5 and
; R6 tell what failed: an address and the word read there, or for the timer,
; the interrupts and the cycles that they took.

; TRAM writes each word of the RAM_N words from RAM_LO with its address,
; checks them, and does the same with the addresses inverted.
TRAM    MOVE    R7, 0           ; 0, or -1 to invert
RPASS   MOVE    R2, RAM_LO
        MOVE    R4, RAM_N
RWRITE  XOR     @R2++, R2, R7
        SUB[M]  R4, R4, 1
    ?!Z MOVE    PC, RWRITE
        MOVE    R2, RAM_LO
        MOVE    R4, RAM_N
RREAD   XOR     R6, R2, R7
        SUB[M]  R0, @R2, R6
    ?!Z MOVE    PC, RBAD
        ADD     R2, R2, 1
        SUB[M]  R4, R4, 1
    ?!Z MOVE    PC, RREAD
        XOR[M]  R7, R7, -1
    ?!Z MOVE    PC, RPASS
        MOVE    R1, 0
        MOVE    PC, @SP++
RBAD    MOVE    R5, R2
        MOVE    R6, @R2
        MOVE    R1, 1
        MOVE    PC, @SP++

; TMATH runs the script MATH, which writes operands of the math unit and
; checks its results.
TMATH   MOVE    R2, MATH
MSTEP   MOVE[M] R3, @R2++       ; 1 to write, 2 to check, 0 at the end
    ?Z  MOVE    PC, MPASS
        MOVE    R5, @R2++       ; the address
        MOVE    R4, @R2++       ; and the word
        SUB[M]  R0, R3, 1
    ?Z  MOVE    @R5, R4
    ?Z  MOVE    PC, MSTEP
        MOVE    R6, @R5
        SUB[M]  R0, R6, R4
    ?Z  MOVE    PC, MSTEP
        MOVE    R1, 1
        MOVE    PC, @SP++
MPASS   MOVE    R1, 0
        MOVE    PC, @SP++

; TTIMER lets the timer raise 10 interrupts, one every 1000 cycles, which
; TICK counts, and checks that they came in 9500 to 10500 cycles. It waits
; at most 100000 cycles. It sets VBASE, and leaves E clear.
TTIMER  MOVE    @S_TICKS, 0
        MOVE    @TM_VEC, VECTOR
        AND     R14, R14, 0xFF000000
        OR      R14, R14, VBASE
        MOVE    R5, @P_CYC
        MOVE    @TM_PER, 1000
        OR      R14, R14, 0x40000000 ; E, which lets the interrupts in
TWAIT   SUB     R6, @P_CYC, R5
        SUB[M]  R0, @S_TICKS, 10
    ?Z  MOVE    PC, TSTOP
        SUB[M]  R0, R6, 100000
    ?C  MOVE    PC, TWAIT
TSTOP   MOVE    @TM_PER, 0
        MOVE    R0, R0          ; a request still pending is taken here
        MOVE    R0, R0
        AND     R14, R14, 0xBFFFFFFF
        MOVE    R5, @S_TICKS
        MOVE    R1, 1
        SUB[M]  R0, R5, 10
    ?C  MOVE    PC, @SP++       ; fewer than 10
        SUB[M]  R0, R6, 9500
    ?C  MOVE    PC, @SP++
        SUB[M]  R0, R6, 10500
    ?!C MOVE    PC, @SP++
        MOVE    R1, 0
        MOVE    PC, @SP++

; TICK, the routine of the timer's interrupt, from the ROM
TICK    ADD     @S_TICKS, @S_TICKS, 1
        RTI

; TCOUNT checks the performance counters: the instructions of a known
; sequence, and over a loop, at least as many cycles as instructions, some
; microseconds, and 1 to 255 cycles per microsecond.
TCOUNT  MOVE    R5, @P_INS
        MOVE    R0, R0          ; eight instructions
        MOVE    R0, R0
        MOVE    R0, R0
        MOVE    R0, R0
        MOVE    R0, R0
        MOVE    R0, R0
        MOVE    R0, R0
        MOVE    R0, R0
        SUB     R6, @P_INS, R5  ; read 9 instructions after the first
        MOVE    R5, P_INS
        MOVE    R1, 1
        SUB[M]  R0, R6, 9
    ?!Z MOVE    PC, @SP++
        MOVE    R7, @P_INS
        MOVE    R8, @P_CYC
        MOVE    R9, @P_US
        MOVE    R4, 1000
CLOOP   SUB[M]  R4, R4, 1
    ?!Z MOVE    PC, CLOOP
        SUB     R7, @P_INS, R7
        SUB     R8, @P_CYC, R8
        SUB     R9, @P_US, R9
        MOVE    R5, P_CYC
        MOVE    R6, R8
        SUB[M]  R0, R8, R7
    ?C  MOVE    PC, @SP++       ; fewer cycles than instructions
        MOVE    R5, P_US
        MOVE    R6, R9
        MOVE[M] R0, R9
    ?Z  MOVE    PC, @SP++       ; no microsecond
        MOVE    @M_A, R8
        MOVE    @M_B, R9
        MOVE    R5, M_UDIVQ
        MOVE[M] R6, @M_UDIVQ
    ?Z  MOVE    PC, @SP++
        SUB[M]  R0, R6, 256
    ?!C MOVE    PC, @SP++
        MOVE    R1, 0
        MOVE    PC, @SP++

; SHOWNET shows the Ethernet station's registers: the IP address in decimal
; with dots, the MAC address in hex with colons, and the three counts. It
; changes R1 to R7 and R9.
SHOWNET MOVE    R3, TYPED
        MOVE    R2, SCREEN+1304
        MOVE    R5, @E_IP
        MOVE    R6, 24          ; the shift of the byte, 24 down to 0
IPBYTE  SHR     R1, R5, R6
        AND     R1, R1, 0xFF
        ADD     @--SP, 2, PC
        MOVE    PC, DECB
        SUB[M]  R6, R6, 8
    ?N  MOVE    PC, IPEND
        OR      @R2++, R3, 0x2E
        MOVE    PC, IPBYTE
IPEND   MOVE    R4, SCREEN+1319 ; blanks after a shorter address
        SUB[M]  R4, R4, R2
    ?!Z MOVE    R3, TEXT+0x20
    ?!Z ADD     @--SP, 2, PC
    ?!Z MOVE    PC, FILL
        MOVE    R3, TYPED
        MOVE    R2, SCREEN+1384
        MOVE    R6, 0           ; the byte of the MAC address
MBYTE   MOVE    R1, @E_MACH
        SUB[M]  R0, R6, 2
    ?!C MOVE    R1, @E_MACL
        SHR     R1, R1, @MSHIFT[R6]
        AND     R1, R1, 0xFF
        ADD     @--SP, 2, PC
        MOVE    PC, HEX2
        ADD     R6, R6, 1
        SUB[M]  R0, R6, 6
    ?Z  MOVE    PC, MEND
        OR      @R2++, R3, 0x3A
        MOVE    PC, MBYTE
MEND    MOVE    R4, 10
        MOVE    R7, 0
        MOVE    R1, @E_GOOD
        MOVE    R2, SCREEN+1474
        ADD     @--SP, 2, PC
        MOVE    PC, DEC64
        MOVE    R7, 0
        MOVE    R1, @E_BAD
        MOVE    R2, SCREEN+1554
        ADD     @--SP, 2, PC
        MOVE    PC, DEC64
        MOVE    R7, 0
        MOVE    R1, @E_SENT
        MOVE    R2, SCREEN+1634
        ADD     @--SP, 2, PC
        MOVE    PC, DEC64
        MOVE    PC, @SP++

; DECB writes R1, which is below 256, in decimal at R2, in the color R3, and
; leaves R2 after it. It changes R1 and R4.
DECB    MOVE    R4, 0           ; the digits, pushed last first
DDIV    MOVE    @M_A, R1
        MOVE    @M_B, 10
        ADD     @--SP, @M_UDIVR, 0x30
        MOVE    R1, @M_UDIVQ
        ADD     R4, R4, 1
        MOVE[M] R0, R1
    ?!Z MOVE    PC, DDIV
DPUT    MOVE    R1, @SP++
        OR      @R2++, R1, R3
        SUB[M]  R4, R4, 1
    ?!Z MOVE    PC, DPUT
        MOVE    PC, @SP++

; HEX2 writes R1, which is below 256, as 2 hex digits at R2, in the color R3,
; and leaves R2 after them. It changes R9.
HEX2    SHR     R9, R1, 4
        OR      @R2++, @HEXDIG[R9], R3
        AND     R9, R1, 0xF
        OR      @R2++, @HEXDIG[R9], R3
        MOVE    PC, @SP++

; NIBBLE sets R1, a character, to its value as a hex digit, or to 99 if it
; is none.
NIBBLE  SUB     R1, R1, 0x30
        SUB[M]  R0, R1, 10
    ?C  MOVE    PC, @SP++       ; 0 to 9
        ADD     R1, R1, 0x30
        OR      R1, R1, 0x20    ; A to F as a to f
        SUB     R1, R1, 0x61
        SUB[M]  R0, R1, 6
    ?C  ADD     R1, R1, 10
    ?!C MOVE    R1, 99
        MOVE    PC, @SP++

; EIDLE ends the typing of an address: it clears the three rows at the
; bottom, shows the keys that start it, and hides the cursor. It changes R1
; to R4.
EIDLE   MOVE    @B_MODE, 0
        MOVE    @SCR_CTL, 0
        MOVE    R2, SCREEN+1760
        MOVE    R3, TEXT+0x20
        MOVE    R4, 240
        ADD     @--SP, 2, PC
        MOVE    PC, FILL
        MOVE    R1, E_HELP
        MOVE    R2, SCREEN+1762
        MOVE    R3, TEXT
        ADD     @--SP, 2, PC
        MOVE    PC, PRINT
        MOVE    PC, @SP++

; The typing of an address. I starts the IP address, with R7 = 1, and M the
; MAC address, with R7 = 2. The characters go to row 22 from column 20, and
; COL counts them. The keys are digits and dots for the IP address, and hex
; digits and colons for the MAC address, DEL or backspace, CTRL-C, which is
; RUN/STOP on the MEGA65, or ESC to cancel, and RETURN to write the address
; to the station. A function key still starts its demo.
ESTART  MOVE    @B_MODE, R7
        MOVE    COL, 0
        MOVE    R2, SCREEN+1760
        MOVE    R3, TEXT+0x20
        MOVE    R4, 240
        ADD     @--SP, 2, PC
        MOVE    PC, FILL
        MOVE    R1, E_NEWIP
        MOVE    R5, E_HINTIP
        SUB[M]  R0, R7, 1
    ?!Z MOVE    R1, E_NEWMAC
    ?!Z MOVE    R5, E_HINTMAC
        MOVE    R2, SCREEN+1762
        MOVE    R3, LINK
        ADD     @--SP, 2, PC
        MOVE    PC, PRINT
        MOVE    R1, R5
        MOVE    R2, SCREEN+1842
        MOVE    R3, TEXT
        ADD     @--SP, 2, PC
        MOVE    PC, PRINT
        MOVE    @SCR_Y, 22
        MOVE    @SCR_X, 20
        MOVE    @SCR_CTL, 0x60
        MOVE    PC, BLOOP

; A key while typing, in R1. The error row is cleared first.
BEDIT   MOVE    R2, SCREEN+1920
        MOVE    R3, TEXT+0x20
        MOVE    R4, 80
        ADD     @--SP, 2, PC
        MOVE    PC, FILL
        SUB[M]  R0, R1, 0x0D
    ?Z  MOVE    PC, EENTER
        SUB[M]  R0, R1, 0x0A
    ?Z  MOVE    PC, EENTER
        SUB[M]  R0, R1, 0x03
    ?Z  MOVE    PC, ECANCEL
        SUB[M]  R0, R1, 0x1B
    ?Z  MOVE    PC, ECANCEL
        SUB[M]  R0, R1, 0x08
    ?Z  MOVE    PC, EBACK
        SUB[M]  R0, R1, 0x7F
    ?Z  MOVE    PC, EBACK
        MOVE    R4, 10          ; the base, the separator, and the length
        MOVE    R5, 0x2E
        MOVE    R6, 15
        SUB[M]  R0, @B_MODE, 1
    ?!Z MOVE    R4, 16
    ?!Z MOVE    R5, 0x3A
    ?!Z MOVE    R6, 17
        SUB[M]  R0, COL, R6
    ?!C MOVE    PC, BLOOP       ; the line is full
        MOVE    R9, R1
        SUB[M]  R0, R1, R5
    ?Z  MOVE    PC, EPUT
        ADD     @--SP, 2, PC
        MOVE    PC, NIBBLE
        SUB[M]  R0, R1, R4
    ?!C MOVE    PC, BLOOP       ; no digit of the base
EPUT    ADD     R2, COL, SCREEN+1780
        OR      @R2, R9, TYPED
        ADD     COL, COL, 1
        ADD     @SCR_X, COL, 20
        MOVE    PC, BLOOP
EBACK   MOVE[M] R0, COL
    ?Z  MOVE    PC, BLOOP
        SUB     COL, COL, 1
        ADD     R2, COL, SCREEN+1780
        MOVE    @R2, TEXT+0x20
        ADD     @SCR_X, COL, 20
        MOVE    PC, BLOOP
ECANCEL ADD     @--SP, 2, PC
        MOVE    PC, EIDLE
        MOVE    PC, BLOOP

; RETURN: the text is parsed, and written to the station if it is an
; address. Otherwise a message shows, and the typing goes on.
EENTER  MOVE    R2, SCREEN+1780
        MOVE    R3, COL
        MOVE    R4, 10
        MOVE    R5, 0x2E
        MOVE    R6, 4
        SUB[M]  R0, @B_MODE, 1
    ?!Z MOVE    R4, 16
    ?!Z MOVE    R5, 0x3A
    ?!Z MOVE    R6, 6
        ADD     @--SP, 2, PC
        MOVE    PC, PARSE
        MOVE[M] R0, R1
    ?!Z MOVE    PC, EBAD
        SUB[M]  R0, @B_MODE, 1
    ?Z  MOVE    @E_IP, R8
    ?Z  MOVE    PC, ECANCEL     ; which ends the typing
        AND[M]  R0, R11, 0x100  ; bit 0 of the first byte: a group address
    ?!Z MOVE    PC, EBAD
        MOVE    @E_MACH, R11
        MOVE    @E_MACL, R8
        MOVE    PC, ECANCEL
EBAD    MOVE    R1, E_BADIP
        SUB[M]  R0, @B_MODE, 1
    ?!Z MOVE    R1, E_BADMAC
        MOVE    R2, SCREEN+1922
        MOVE    R3, RED
        ADD     @--SP, 2, PC
        MOVE    PC, PRINT
        MOVE    PC, BLOOP

; PARSE reads the R3 characters from R2 as R6 numbers of 1 to 3 digits in
; the base R4, from 0 to 255, with the separator R5 between them. It sets R1
; to 0 and R11:R8 to the bytes, the first in the highest bits, or sets R1 to
; 1 if the text is none of that. It changes R1 to R9, and R11.
PARSE   MOVE    R11, 0
        MOVE    R8, 0
PFIELD  MOVE    R7, 0           ; the digits of the number
        MOVE    R9, 0           ; and its value
PCHAR   MOVE[M] R0, R3
    ?Z  MOVE    PC, PLAST       ; the end of the text ends the number
        MOVE    R1, @R2++
        AND     R1, R1, 0xFF
        SUB     R3, R3, 1
        SUB[M]  R0, R1, R5
    ?Z  MOVE    PC, PSEP
        ADD     @--SP, 2, PC
        MOVE    PC, NIBBLE
        SUB[M]  R0, R1, R4
    ?!C MOVE    PC, PBAD        ; no digit of the base
        MOVE    @M_A, R9
        MOVE    @M_B, R4
        ADD     R9, @M_UMUL, R1
        ADD     R7, R7, 1
        SUB[M]  R0, R9, 256
    ?!C MOVE    PC, PBAD
        SUB[M]  R0, R7, 4
    ?!C MOVE    PC, PBAD
        MOVE    PC, PCHAR
PLAST   MOVE    R1, 0           ; R1 is 1 if a separator ended the number
        MOVE    PC, PEND
PSEP    MOVE    R1, 1
PEND    MOVE[M] R0, R7
    ?Z  MOVE    PC, PBAD        ; an empty number
        MOVE[M] R0, R6
    ?Z  MOVE    PC, PBAD        ; one number too many
        SUB     R6, R6, 1
        SHL     R11, R11, 8     ; the byte goes in at the low end of R11:R8
        SHR     R7, R8, 24
        OR      R11, R11, R7
        SHL     R8, R8, 8
        OR      R8, R8, R9
        MOVE[M] R0, R1
    ?!Z MOVE    PC, PFIELD      ; the next number
        MOVE[M] R0, R6
    ?Z  MOVE    R1, 0           ; all R6 numbers, and the text has ended
    ?!Z MOVE    R1, 1
        MOVE    PC, @SP++
PBAD    MOVE    R1, 1
        MOVE    PC, @SP++

; RESULT writes PASS in green at R2 when R1 is 0, or else FAIL in red, and
; R5 and R6 in hex after it, and counts the failure in R10. It changes R1,
; R2, R3, R4, and R9.
RESULT  MOVE[M] R0, R1
    ?!Z MOVE    PC, RFAIL
        MOVE    R1, S_PASS
        MOVE    R3, TAIL
        MOVE    PC, PRINT       ; which returns to the caller
RFAIL   ADD     R10, R10, 1
        MOVE    R1, S_FAIL
        MOVE    R3, RED
        ADD     @--SP, 2, PC
        MOVE    PC, PRINT
        ADD     R2, R2, 1
        MOVE    R1, R5
        MOVE    R3, TYPED
        ADD     @--SP, 2, PC
        MOVE    PC, HEX8
        ADD     R2, R2, 1
        MOVE    R1, R6
        MOVE    PC, HEX8        ; which returns to the caller

; HEX8 writes R1 in 8 hex digits from R2, in the color R3, and leaves R2
; after them. It changes R1, R2, R4, and R9.
HEX8    MOVE    R4, 8
HDIGIT  SHR     R9, R1, 28
        OR      @R2++, @HEXDIG[R9], R3
        SHL     R1, R1, 4
        SUB[M]  R4, R4, 1
    ?!Z MOVE    PC, HDIGIT
        MOVE    PC, @SP++

; POLL takes a key from the input, if one has arrived, and sets R1 to it: a
; byte, KEY_UP to KEY_LT for a cursor key, or 0 when there is none. It
; reads the escape sequences that xterm sends for the cursor keys and the
; function keys, and waits for the bytes of a sequence after its ESC, at
; most T_ESC microseconds for each. A function key with a demo in FKEYS
; starts that demo, and POLL does not return. Other sequences give 0. ESC
; and a byte that starts none gives that byte. An ESC with no byte after it
; in time gives ESC, 0x1B, as the MEGA65's ESC key sends it alone. At the
; end of the input, POLL halts. It changes R1 to R5, and calls ECHO, unless
; it is 0, with each byte in R1.
POLL    ADD     @--SP, 2, PC
        MOVE    PC, READ
    ?Z  MOVE    PC, @SP++       ; no byte, and R1 is 0
        SUB[M]  R0, R1, 0x1B
    ?!Z MOVE    PC, @SP++       ; a byte other than ESC
ESCAPE  ADD     @--SP, 2, PC
        MOVE    PC, NEXT
    ?Z  MOVE    R1, 0x1B        ; an ESC alone is a key of its own
    ?Z  MOVE    PC, @SP++
        SUB[M]  R0, R1, 0x1B
    ?Z  MOVE    PC, ESCAPE      ; ESC again starts again
        SUB[M]  R0, R1, 0x5B    ; [
    ?Z  MOVE    PC, CSI
        SUB[M]  R0, R1, 0x4F    ; O
    ?!Z MOVE    PC, @SP++
; ESC O and a byte: A to D are the cursor keys, and P to S F1 to F4. No
; byte in time leaves R1 0, which is none of them.
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
; is 1 once it has ended. A sequence that stops before its final byte
; gives 0 at the timeout, so that the bytes typed after it are keys again.
CSI     MOVE    R3, 0
        MOVE    R4, 0
PARAM   ADD     @--SP, 2, PC
        MOVE    PC, NEXT
    ?Z  MOVE    PC, NONE        ; no byte in time
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

; NEXT waits at most T_ESC microseconds for a byte of the console, and sets
; R1 to it, with Z clear. If none comes, R1 is 0 and Z is set. It changes
; R5.
NEXT    ADD     R5, @P_US, T_ESC ; the deadline
NWAIT   ADD     @--SP, 2, PC
        MOVE    PC, READ
    ?!Z MOVE    PC, @SP++       ; a byte
        SUB[M]  R0, @P_US, R5
    ?N  MOVE    PC, NWAIT
        MOVE[M] R1, 0
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
FKEYS   .DAT    TYPEW, 0, KCODES, 0, CHARS, 0, COUNTS, 0, GAME, 0, BOARD, 0, 0, 0, 0, 0, 0, 0, 0, 0

; The numbers before ~ of F1 to F12. xterm sends ESC O P to ESC O S for F1
; to F4, and 11 to 14 are those of the VT220.
FNUMS   .DAT    11, 12, 13, 14, 15, 17, 18, 19, 20, 21, 23, 24

; The menu: the position of each entry, the demo, and the string, and -1 at
; the end
MENU    .DAT    80, TYPEW, M_TYPEW
        .DAT    96, KCODES, M_KEYS
        .DAT    111, CHARS, M_CHARS
        .DAT    124, COUNTS, M_COUNT
        .DAT    138, GAME, M_GAME
        .DAT    149, BOARD, M_BOARD
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
M_CHARS .ASCII_L ' F5 charset '
M_COUNT .ASCII_L ' F7 counters '
M_GAME  .ASCII_L ' F9 comet '
M_BOARD .ASCII_L ' F11 board '
T1      .ASCII_L 'This is the demo in the ROM, which the core runs at power-up. What you type'
T2      .ASCII_L 'on the keyboard, or send to the console, appears below the blue bar.'
T3      .ASCII_L 'To run your own programs, give the board an IP address with F11, then load'
T4      .ASCII_L 'and debug them over Ethernet with tools/mon.py --eth. More is at'
URL     .ASCII_L 'https://github.com/MJoergen/NiceMonMEGA65'
KEYS    .ASCII_L 'RETURN new line   DEL delete   cursor keys move   CTRL-L clear'

; The texts of F3
K_TEXTS .DAT    242, TEXT, K1
        .DAT    322, TEXT, K2
        .DAT    402, TEXT, K3
        .DAT    562, BAR, K_HEX
        .DAT    602, BAR, K_CHARS
        .DAT    -1

K1      .ASCII_L 'Each key that you type, or byte sequence sent to the console, shows'
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

; The shifts of the six bytes of the MAC address, in E_MACH and E_MACL
MSHIFT  .DAT    8, 0, 24, 16, 8, 0

; The texts of F11
S_TEXTS .DAT    242, LINK, S1
        .DAT    404, TEXT, S_RAM
        .DAT    484, TEXT, S_MATH
        .DAT    564, TEXT, S_TIMER
        .DAT    644, TEXT, S_COUNT
        .DAT    962, TEXT, S_NOTE1
        .DAT    1042, TEXT, S_NOTE2
        .DAT    1202, LINK, S_ETH
        .DAT    1282, TEXT, S_IP
        .DAT    1362, TEXT, S_MAC
        .DAT    1442, TEXT, S_GOOD
        .DAT    1522, TEXT, S_BAD
        .DAT    1602, TEXT, S_SENT
        .DAT    -1

S1      .ASCII_L 'A self-test, which runs each time that F11 starts it'
S_RAM   .ASCII_L 'RAM, FFFF8000 to FFFFEFFF'
S_MATH  .ASCII_L 'Math unit, multiply and divide'
S_TIMER .ASCII_L 'Timer, 10 interrupts every 1000 cycles'
S_COUNT .ASCII_L 'Performance counters'
S_NOTE1 .ASCII_L 'A failure shows where it failed and what was read: an address and its word,'
S_NOTE2 .ASCII_L 'or for the timer, the interrupts that came and the cycles that they took.'
S_ETH   .ASCII_L 'The Ethernet station, 0xFFFFFF98 to 0xFFFFFF9D'
S_IP    .ASCII_L 'IP address'
S_MAC   .ASCII_L 'MAC address'
S_GOOD  .ASCII_L 'Good frames received'
S_BAD   .ASCII_L 'Bad or dropped frames'
S_SENT  .ASCII_L 'Frames sent'
E_HELP  .ASCII_L 'I types a new IP address, and M a new MAC address.'
E_NEWIP .ASCII_L 'New IP address:'
E_NEWMAC .ASCII_L 'New MAC address:'
E_HINTIP .ASCII_L 'Digits and dots. RETURN writes it; ESC, CTRL-C, or RUN/STOP cancels.'
E_HINTMAC .ASCII_L 'Hex digits and colons. RETURN writes it; ESC, CTRL-C, or RUN/STOP cancels.'
E_BADIP .ASCII_L 'Not an IP address: four numbers from 0 to 255, with dots between them.'
E_BADMAC .ASCII_L 'Not a MAC address: six bytes in hex with colons, the first one even.'
S_PASS  .ASCII_L 'PASS'
S_FAIL  .ASCII_L 'FAIL'
S_PASSED .ASCII_L 'All tests passed.'
S_FAILED .ASCII_L 'A test failed.'

; The script of the math unit's test: 1, an address, and a word to write
; there, or 2, an address, and the word expected there, and 0 at the end
MATH    .DAT    1, M_A, -7
        .DAT    1, M_B, 6
        .DAT    2, M_SMUL, -42
        .DAT    2, M_SMULH, -1
        .DAT    2, M_UMUL, 0xFFFFFFD6
        .DAT    2, M_UMULH, 5
        .DAT    2, M_SDIVQ, -1
        .DAT    2, M_SDIVR, -1
        .DAT    2, M_UDIVQ, 0x2AAAAAA9
        .DAT    2, M_UDIVR, 3
        .DAT    1, M_B, 0       ; a division by zero
        .DAT    2, M_UDIVQ, 0xFFFFFFFF
        .DAT    2, M_UDIVR, -7
        .DAT    2, M_SDIVQ, -1
        .DAT    2, M_SDIVR, -7
        .DAT    1, M_A, 0x80000000
        .DAT    1, M_B, -1
        .DAT    2, M_SDIVQ, 0x80000000
        .DAT    2, M_SDIVR, 0
        .DAT    1, M_CLO, 0xA4C86240 ; 10^15 + 123456
        .DAT    1, M_CHI, 0x00038D7E
        .DAT    1, M_DLO, 1000000
        .DAT    1, M_DHI, 0
        .DAT    2, M_QLO, 0x3B9ACA00 ; 10^9
        .DAT    2, M_QHI, 0
        .DAT    2, M_RLO, 123456
        .DAT    1, M_CLO, 0xFFFFFFFF ; 2^64 - 1
        .DAT    1, M_CHI, 0xFFFFFFFF
        .DAT    1, M_DLO, 10
        .DAT    2, M_QLO, 0x99999999
        .DAT    2, M_QHI, 0x19999999
        .DAT    2, M_RLO, 5
        .DAT    0

; The entry of the timer's interrupt in the vector table, at VBASE * 256 +
; VECTOR, near the end of the ROM, where no code is
        .ORG    0x7F41
        .DAT    TICK
