; BASIC's numbers (stage 2, issue #113, doc/BASIC.md): the tokenizer of a
; line, the evaluator of an expression on the FPU, the variables, the
; errors, and PRINT, LET, and POKE. basic.nasm's main loop tokenizes each
; line into V_TOK and runs its statements from there, as stage 3 runs a
; stored line.
;
; A token is a word with its kind in bits 31..24 (K_*), and the words
; after it that the kind has:
;
;   K_SMALL  a whole number of 0 to 0xFFFFFF, in bits 23..0
;   K_WORD   a whole number in decimal, a signed word, in the word after
;   K_HEX    a number in hex, a signed word, in the word after
;   K_NUM    any other number: the exponent e in bits 15..0, then the
;            double, low word first, then up to 16 digits in BCD, low
;            word first, the first digit in bits 31..28 of the second, as
;            DIGITS gives them (nice_cpu's DEVICES.md 11.3), so that the
;            value is the digits read by FROMBCD, times 10^(e - 15)
;   K_STR    a string: its length n in bits 23..0, its n characters, one
;            a word, and a 0
;   K_VAR    a variable: its offset from V_PEND in bits 23..0
;   K_OP     an operator on two numbers: its precedence in bits 22..16,
;            bit 23 for one that divides, and its FPU command in 15..0
;   K_PUNCT  ( ) , ; and :, the character in bits 7..0
;   K_FN     ABS, SGN, INT, SQR, and PEEK: the FPU command, 0 for PEEK
;   K_NOT    NOT, with its FPU command
;   K_KW     a statement: its index in KEYWORDS in bits 15..8, and the
;            byte after its keyword, its program of ops, in bits 7..0
;   K_PRT    TAB and SPC, which only PRINT takes
;   K_SEP    THEN, ELSE, TO, and STEP
;   K_LINE   a line number after GOTO, GOSUB, RUN, THEN, or ELSE, in
;            bits 23..0, and the address of its line in the word after,
;            0 until a jump finds it (basic_prog.nasm)
;   K_REM    the text after REM, as K_STR has it
;   K_ARR    an array: its entry's offset from V_PEND in bits 23..0
;
; The line ends with a 0 word, T_END. A name is a keyword only as a
; whole name, up to 16 letters and digits.
;
; A variable is its double, then its name: the name's length, then its
; characters in upper case, packed four to a word, as .ASCII_B packs
; them. A variable that was never assigned has 0xFFFFFFFF, a NaN, in the
; high word of its double. An array's entry has ARRAY in its length, and
; the offset of its data from V_VEND in the place of the double's low
; word, and its high word is 0xFFFFFFFF until DIM makes the array
; (basic_prog.nasm). A name with ( after it is an array's. The variables go from V_PEND, the end of the
; program, to V_VEND. The tokenizer makes a variable for each name of a
; line to store (basic_prog.nasm), and in a direct line for a name after
; GET or INPUT, or a comma of INPUT, and with = after it at the start of
; a statement, or after LET, FOR, THEN, or ELSE, and an array's name in
; a direct line after DIM, or a comma of DIM. Any other name without a variable is a K_VAR of NO_VAR, an
; Undefined variable when it runs, so that a line that only reads a
; name, or has a typo, does not write over a program at PROGRAM. The walk
; of the table stops at V_VEND and at a length of 0 or above 16, where
; it cuts the table, so that a program that SYS ran and that wrote over
; the table never loses it. LOAD clears the table, and the program.
;
; The evaluator takes the tokens from R8, and pushes the operands on the
; FPU's stack, where an operator is one command. It recurses on the
; processor's stack, and an expression that would take more than
; EXPR_ROOM words of it is Formula too complex, as is one with more
; than 16 values pending on the FPU's stack. Its errors, and every
; other of BASIC's, go through err, which clears the FPU's stack and its
; flags, sets SP again, prints the message, and goes back to main.

FPU_X_LO        .EQU    0xFFFFFF88      ; the FPU: X, bits 31..0, a write pushes
FPU_X_HI        .EQU    0xFFFFFF89      ; X, bits 63..32
FPU_X_W         .EQU    0xFFFFFF8B      ; X as a signed word, a write pushes
FPU_CMD         .EQU    0xFFFFFF8C      ; a command
FPU_STATUS      .EQU    0xFFFFFF8D      ; the depth, the flags in bits 11..8, and the class of X
FPU_CLEAR       .EQU    0x101           ; the commands: CLEAR 1, the stack and the flags,
FPU_DROP        .EQU    0x03            ; DROP,
FPU_NEG         .EQU    0x15            ; NEG,
FPU_NOT         .EQU    0x63            ; NOT,
FPU_SCALE10     .EQU    0x39            ; SCALE10,
FPU_DIGITS15    .EQU    0x0F3A          ; DIGITS 15,
FPU_FROMBCD     .EQU    0x3B            ; and FROMBCD
FPU_ZERO        .EQU    0x20000         ; the class of X: zero,
FPU_NEGATIVE    .EQU    0x10000         ; negative,
FPU_FITS        .EQU    0x200000        ; and fits a word

EXPR_ROOM       .EQU    0x100           ; the words of the stack that an expression may take
STACK_ROOM      .EQU    0x400           ; the words of the stack below the variables
RAM_MEGA65      .EQU    0x20000         ; the words of the RAM where RAM_WORDS reads 0

V_TOK           .EQU    0xFFFFECB0      ; the tokens of the line, TOK_MAX words
TOK_MAX         .EQU    160             ; two a character and a 0, for the 76 of a line
V_TP            .EQU    0xFFFFED50      ; the next statement's token
V_VEND          .EQU    0xFFFFED51      ; the end of the variables
V_KW            .EQU    0xFFFFED52      ; the statement's index in KEYWORDS plus 1, or 0
V_PNAME         .EQU    0xFFFFED54      ; a name, packed, 4 words

NO_VAR          .EQU    0xFFFFFF        ; the offset of a name that has no variable
K_SMALL         .EQU    1               ; the kinds of a token
K_WORD          .EQU    2
K_HEX           .EQU    3
K_NUM           .EQU    4
K_STR           .EQU    5
K_VAR           .EQU    6
K_OP            .EQU    7
K_PUNCT         .EQU    8
K_FN            .EQU    9
K_NOT           .EQU    10
K_KW            .EQU    11
K_PRT           .EQU    12
K_SEP           .EQU    13
K_LINE          .EQU    14
K_REM           .EQU    15
K_ARR           .EQU    16
ARRAY           .EQU    0x100           ; in the length of an array's name
NOT_ARRAY       .EQU    0xFFFFFEFF      ; the length alone
K               .EQU    0x1000000       ; a kind's unit
P               .EQU    0x10000         ; a precedence's unit
P_DIVIDES       .EQU    0x800000        ; an operator that divides

T_END           .EQU    0
T_LPAR          .EQU    K_PUNCT*K+0x28
T_RPAR          .EQU    K_PUNCT*K+0x29
T_COMMA         .EQU    K_PUNCT*K+0x2C
T_SEMI          .EQU    K_PUNCT*K+0x3B
T_COLON         .EQU    K_PUNCT*K+0x3A
T_OR            .EQU    K_OP*K+1*P+0x61  ; the operators, by precedence
T_XOR           .EQU    K_OP*K+1*P+0x62
T_AND           .EQU    K_OP*K+2*P+0x60
PREC_NOT        .EQU    4               ; NOT takes the comparisons
T_EQ            .EQU    K_OP*K+4*P+0x021C  ; CMP 2
T_NE            .EQU    K_OP*K+4*P+0x051C  ; CMP 5
T_LT            .EQU    K_OP*K+4*P+0x011C  ; CMP 1
T_GT            .EQU    K_OP*K+4*P+0x041C  ; CMP 4
T_LE            .EQU    K_OP*K+4*P+0x031C  ; CMP 3
T_GE            .EQU    K_OP*K+4*P+0x061C  ; CMP 6
T_SHL           .EQU    K_OP*K+5*P+0x64
T_SHR           .EQU    K_OP*K+5*P+0x65
T_PLUS          .EQU    K_OP*K+6*P+0x10
T_MINUS         .EQU    K_OP*K+6*P+0x11
T_MUL           .EQU    K_OP*K+7*P+0x12
T_DIV           .EQU    K_OP*K+P_DIVIDES+7*P+0x13
T_IDIV          .EQU    K_OP*K+P_DIVIDES+7*P+0x66
T_MOD           .EQU    K_OP*K+P_DIVIDES+7*P+0x67
PREC_SIGN       .EQU    8               ; the signs take what binds more than * and /
T_TAB           .EQU    K_PRT*K
T_SPC           .EQU    K_PRT*K+1
T_PRINT         .EQU    K_KW*K+I_PRINT*0x100
T_THEN          .EQU    K_SEP*K
T_ELSE          .EQU    K_SEP*K+1
T_TO            .EQU    K_SEP*K+2
T_STEP          .EQU    K_SEP*K+3

; The tokens of the keywords that are no statements, from index N_STMT of
; KEYWORDS on
KW_TOK
                .DAT    T_AND, T_OR, T_XOR, K_NOT*K+FPU_NOT, T_IDIV, T_MOD
                .DAT    K_FN*K+0x16, K_FN*K+0x1B, K_FN*K+0x20, K_FN*K+0x14, K_FN*K
                .DAT    T_TAB, T_SPC, T_THEN, T_ELSE, T_TO, T_STEP
KW_TOK_END

; The characters of one-character tokens, each with its token
PUNCTS
                .DAT    0x2B, T_PLUS, 0x2D, T_MINUS, 0x2A, T_MUL, 0x2F, T_DIV
                .DAT    0x3D, T_EQ, 0x28, T_LPAR, 0x29, T_RPAR, 0x2C, T_COMMA
                .DAT    0x3B, T_SEMI, 0x3A, T_COLON, 0x3F, T_PRINT, 0

; tokenize: the line at V_LINE as tokens at V_TOK, and R8 at their 0.
; tokenize_at: the same, from R5; tokenize_to: from R5 to R8, with the
; limit of the tokens at V_TLIM. A token starts below the limit, and a
; character of a string or of REM goes below it, so that the line's
; tokens end below the limit plus 6, or else the line is too long, which
; a line of a file may be. An error goes to err, with the last
; statement's keyword before it in V_KW, for its lines of HELP. Uses
; R1-R12.
tokenize
                MOVE    R5, V_LINE
tokenize_at
                MOVE    R8, V_TOK
                MOVE    @V_TLIM, V_TOK+TOK_MAX-6
tokenize_to
                MOVE    @V_KW, R0
tok_next
                CMP     R8, @V_TLIM
        ?!C     JMP     err_long
                MOVE    R1, @R5
                CMP     R1, 0x20
        ?Z      MOVE    R5++, R5
        ?Z      JMP     tok_next
                TST     R1
        ?Z      MOVE    @R8, R0
        ?Z      RET
                SUB     R2, R1, 0x30
                CMP     R2, 10
        ?C      JMP     tok_number
                CMP     R1, 0x2E        ; .
        ?Z      JMP     tok_number
                AND     R2, R1, 0xDF
                SUB     R2, R2, 0x41
                CMP     R2, 26
        ?C      JMP     tok_name
                CMP     R1, 0x22        ; "
        ?Z      JMP     tok_string
                MOVE    R3, @1[R5]      ; the next character
                CMP     R1, 0x3C        ; <
        ?Z      JMP     tok_less
                CMP     R1, 0x3E        ; >
        ?Z      JMP     tok_more
                MOVE    R3, PUNCTS
:
                MOVE[M] R4, @R3++
        ?Z      JMP     err_syntax
                CMP     R4, R1
                MOVE    R4, @R3++
        ?!Z     JMP     :-
tok_put
                CMP     R4, T_PRINT
        ?Z      MOVE    @V_KW, I_PRINT+1  ; ?, for the lines of HELP of PRINT
                MOVE    @R8++, R4
                MOVE    R5++, R5
                JMP     tok_next
tok_less
                MOVE    R4, T_LT
                CMP     R3, 0x3D        ; =
        ?Z      MOVE    R4, T_LE
                CMP     R3, 0x3E        ; >
        ?Z      MOVE    R4, T_NE
                CMP     R3, 0x3C        ; <
        ?Z      MOVE    R4, T_SHL
                CMP     R4, T_LT
        ?!Z     MOVE    R5++, R5
                JMP     tok_put
tok_more
                MOVE    R4, T_GT
                CMP     R3, 0x3D        ; =
        ?Z      MOVE    R4, T_GE
                CMP     R3, 0x3E        ; >
        ?Z      MOVE    R4, T_SHR
                CMP     R4, T_GT
        ?!Z     MOVE    R5++, R5
                JMP     tok_put

; A string in quotes, one without its closing quote ending with the line
tok_string
                MOVE    R5++, R5
                MOVE    R6, R8          ; its token
                MOVE    R8++, R8
                CLR     R2              ; its length
:
                MOVE[M] R1, @R5
        ?Z      JMP     :+
                MOVE    R5++, R5
                CMP     R1, 0x22
        ?Z      JMP     :+
                CMP     R8, @V_TLIM
        ?!C     JMP     err_long
                MOVE    @R8++, R1
                MOVE    R2++, R2
                JMP     :-
:
                MOVE    @R8++, R0
                ADD     @R6, R2, K_STR*K
                JMP     tok_next

; A name: a keyword, or a variable, found or made. R9 its first
; character, R10 its length.
tok_name
                MOVE    R9, R5
:
                MOVE    R1, @R5
                CALL    dval
        ?C      MOVE    R5++, R5
        ?C      JMP     :-
                SUB     R10, R5, R9
                CMP     R10, 17
        ?!C     JMP     err_syntax      ; longer than 16
                MOVE    R3, TEXT_B+4*OPS+KEYWORDS
                CLR     R11             ; the index
:
                MOVE    R5, R9
                CALL    match
        ?Z      JMP     :+
                MOVE    R11++, R11
                TST     @R3
        ?!Z     JMP     :-
                JMP     tok_var
:
                CMP     R11, N_STMT
        ?!C     MOVE    @R8++, @KW_TOK-N_STMT[R11]
        ?!C     JMP     tok_next
                ADD     @V_KW, R11, 1
                SHL     R1, R11, 8
                OR      R1, R1, R4
                OR      @R8++, R1, K_KW*K
                CMP     R11, I_REM
        ?!Z     JMP     tok_next
                MOVE    R6, R8          ; REM: the rest of the line as it is
                MOVE    R8++, R8
                CLR     R2
:
                MOVE[M] R1, @R5++
        ?Z      JMP     :+
                CMP     R8, @V_TLIM
        ?!C     JMP     err_long
                MOVE    @R8++, R1
                MOVE    R2++, R2
                JMP     :-
:
                MOVE    @R8++, R0
                ADD     @R6, R2, K_REM*K
                MOVE    @R8, R0
                RET
tok_var
                ADD     R5, R9, R10
                CMP     @R5, 0x25       ; %
        ?!Z     CMP     @R5, 0x24       ; $
        ?Z      JMP     err_syntax
                MOVE    R11, @V_STORE   ; not 0 to make the variable: in a
                MOVE    R2, @-1[R8]     ; line to store, after GET or INPUT,
                AND     R3, R2, 0xFFFFFF00  ; or with = after it, at the start
                CMP     R3, K_KW*K+I_INPUT*0x100  ; of a statement
        ?!Z     CMP     R3, K_KW*K+I_GET*0x100
        ?Z      ONE     R11
                CMP     R2, T_COMMA     ; and after a comma of INPUT
        ?Z      CMP     @V_KW, I_INPUT+1
        ?Z      ONE     R11
                MOVE    R1, R5
:
                CMP     @R1, 0x20
        ?Z      MOVE    R1++, R1
        ?Z      JMP     :-
                CMP     @R1, 0x28       ; (: an array's name
        ?!Z     JMP     tv_eq
                OR      R10, R10, ARRAY
                MOVE    R2, @-1[R8]
                AND     R3, R2, 0xFFFFFF00
                CMP     R3, K_KW*K+I_DIM*0x100
        ?Z      ONE     R11
                CMP     R2, T_COMMA
        ?Z      CMP     @V_KW, I_DIM+1
        ?Z      ONE     R11
                JMP     :+
tv_eq
                CMP     @R1, 0x3D       ; =
        ?!Z     JMP     :+
                CMP     R8, V_TOK
        ?Z      ONE     R11
                MOVE    R2, @-1[R8]
                CMP     R2, T_COLON
        ?!Z     CMP     R2, T_THEN
        ?!Z     CMP     R2, T_ELSE
        ?Z      ONE     R11
                AND     R2, R2, 0xFFFFFF00
                CMP     R2, K_KW*K+I_LET*0x100
        ?!Z     CMP     R2, K_KW*K+I_FOR*0x100
        ?Z      ONE     R11
:
                MOVE    R2, V_PNAME     ; the name, packed in upper case
                MOVE    @R2, R0
                MOVE    @1[R2], R0
                MOVE    @2[R2], R0
                MOVE    @3[R2], R0
                MOVE    R3, R9
                CLR     R4              ; the shift
:
                MOVE    R1, @R3++
                CMP     R1, 0x61        ; a
        ?!C     AND     R1, R1, 0xDF
                SHL     R1, R1, R4
                OR      @R2, @R2, R1
                ADD     R4, R4, 8
                CMP     R4, 32
        ?Z      CLR     R4
        ?Z      MOVE    R2++, R2
                CMP     R3, R5
        ?!Z     JMP     :-
                CALL    var_find
                SUB     R1, R1, @V_PEND
                AND[M]  R0, R10, ARRAY
        ?Z      OR      @R8++, R1, K_VAR*K
        ?!Z     OR      @R8++, R1, K_ARR*K
                JMP     tok_next

; var_find: R1 = the variable of the name at V_PNAME, of length R10,
; with ARRAY for an array's, found, or made at V_VEND when R11 is not 0,
; else V_PEND + NO_VAR. Uses R1-R4, R6, and R12.
var_find
                AND     R6, R10, NOT_ARRAY
                ADD     R6, R6, 3
                SHR     R6, R6, 2       ; the name's words
                MOVE    R1, @V_PEND
                MOVE    R4, @V_VEND
var_next
                CMP     R1, R4
        ?!C     JMP     var_new
                MOVE    R2, @2[R1]      ; the length, and ARRAY
                AND[M]  R3, R2, NOT_ARRAY
        ?Z      JMP     var_cut
                CMP     R3, 17
        ?!C     JMP     var_cut
                CMP     R2, R10
        ?!Z     JMP     var_skip
                CLR     R3
:
                ADD     R12, R1, R3
                CMP     @3[R12], @V_PNAME[R3]
        ?!Z     JMP     var_skip
                MOVE    R3++, R3
                CMP     R3, R6
        ?!Z     JMP     :-
                RET                     ; found
var_skip
                AND     R2, R2, NOT_ARRAY
                ADD     R2, R2, 3
                SHR     R2, R2, 2
                ADD     R1, R1, R2
                ADD     R1, R1, 3
                JMP     var_next
var_cut
                MOVE    @V_VEND, R1     ; a length of 0 or above 16: the table ends here,
                MOVE    @V_AEND, R1     ; and the arrays go
var_new
                TST     R11
        ?Z      ADD     R1, @V_PEND, NO_VAR
        ?Z      RET
                CALL    mem_top
                ADD     R3, R6, 3       ; the words of the new variable
                ADD     R4, @V_AEND, R3
                CMP     R2, R4
        ?C      JMP     err_memory
                MOVE    @V_AEND, R4     ; the arrays move up
                PUSH    R1
                PUSH    R5
                ADD     R2, R1, R3
                MOVE    @V_VEND, R2
                SUB     R3, R4, R3
                CALL    mem_move
                POP     R5
                POP     R1
                MOVE    @R1, R0
                MOVE    @1[R1], 0xFFFFFFFF  ; not assigned
                MOVE    @2[R1], R10
                CLR     R3
:
                ADD     R12, R1, R3
                MOVE    @3[R12], @V_PNAME[R3]
                MOVE    R3++, R3
                CMP     R3, R6
        ?!Z     JMP     :-
                RET

; A number in decimal or in hex. A decimal one is up to 16 significant
; digits in BCD, R1:R2, right-aligned, the count R3 of them, and the
; power of ten R4 of the last; the 17th digit, R7, or -1, rounds the
; 16th. R6 is not 0 after the point, R9 after a digit, and R10 after a
; point or an exponent, which make the number a K_NUM.
tok_number
                CMP     R8, V_TOK
        ?Z      JMP     :+
                MOVE    R2, @-1[R8]     ; after GOTO, GOSUB, RUN, THEN, or ELSE
                CMP     R2, T_THEN      ; a line number
        ?!Z     CMP     R2, T_ELSE
        ?Z      JMP     tok_line
                AND     R2, R2, 0xFFFFFF00
                CMP     R2, K_KW*K+I_GOTO*0x100
        ?!Z     CMP     R2, K_KW*K+I_GOSUB*0x100
        ?!Z     CMP     R2, K_KW*K+I_RUN*0x100
        ?Z      JMP     tok_line
:
                CMP     R1, 0x30
        ?!Z     JMP     :+
                AND     R2, @1[R5], 0xDF
                CMP     R2, 0x58        ; X
        ?Z      JMP     tok_hex
:
                CLR     R1
                CLR     R2
                CLR     R3
                CLR     R4
                CLR     R6
                NOT     R7, R0
                CLR     R9
                CLR     R10
tok_digit
                MOVE    R12, @R5
                CMP     R12, 0x2E       ; .
        ?!Z     JMP     :+
                TST     R6
        ?!Z     JMP     tok_numend      ; a second point
                ONE     R6
                ONE     R10
                MOVE    R5++, R5
                JMP     tok_digit
:
                SUB     R12, R12, 0x30
                CMP     R12, 10
        ?!C     JMP     tok_numend
                ONE     R9
                MOVE    R5++, R5
                OR[M]   R0, R3, R12
        ?!Z     JMP     :+
                TST     R6              ; a leading 0
        ?!Z     SUB     R4, R4, 1
                JMP     tok_digit
:
                CMP     R3, 16
        ?!C     JMP     :+
                SHL     R1, R1, 4       ; R1:R2 times 16 plus the digit
                SHR     R11, R2, 28
                OR      R1, R1, R11
                SHL     R2, R2, 4
                OR      R2, R2, R12
                MOVE    R3++, R3
                TST     R6
        ?!Z     SUB     R4, R4, 1
                JMP     tok_digit
:
                TST     R7              ; a digit after the 16th
        ?N      MOVE    R7, R12
                TST     R6
        ?Z      MOVE    R4++, R4
                JMP     tok_digit
tok_numend
                TST     R9
        ?Z      JMP     err_syntax      ; a point alone
                AND     R12, @R5, 0xDF
                CMP     R12, 0x45       ; E
        ?!Z     JMP     tok_digits
                ONE     R10             ; 1 for +, 2 for -
                MOVE    R5++, R5
                MOVE    R12, @R5
                CMP     R12, 0x2D       ; -
        ?Z      MOVE    R10, 2
        ?!Z     CMP     R12, 0x2B       ; +
        ?Z      MOVE    R5++, R5
                CLR     R9              ; the exponent, up to 9999
                MOVE    R6, R5
:
                SUB     R12, @R5, 0x30
                CMP     R12, 10
        ?!C     JMP     :+
                MOVE    R5++, R5
                CMP     R9, 1000
        ?!C     MOVE    R9, 999
                DBL     R11, R9         ; 10 * R9 + the digit
                SHL     R9, R9, 3
                ADD     R9, R9, R11
                ADD     R9, R9, R12
                JMP     :-
:
                CMP     R5, R6
        ?Z      JMP     err_syntax      ; an E without digits
                CMP     R10, 2
        ?Z      SUB     R4, R4, R9
        ?!Z     ADD     R4, R4, R9
tok_digits
                MOVE    R12, @R5        ; no letter, digit, or point after it
                SUB     R11, R12, 0x30
                CMP     R11, 10
        ?C      JMP     err_syntax
                AND     R11, R12, 0xDF
                SUB     R11, R11, 0x41
                CMP     R11, 26
        ?C      JMP     err_syntax
                CMP     R12, 0x2E
        ?Z      JMP     err_syntax
                TST     R7
        ?!N     CMP     R7, 5
        ?N      JMP     :+              ; no rounding
        ?C      JMP     :+
                ONE     R12             ; R1:R2 plus 1, in BCD
                CALL    bcd_inc
                MOVE    R9, R2
                MOVE    R2, R1
                CALL    bcd_inc
                MOVE    R1, R2
                MOVE    R2, R9
                TST     R12
        ?!Z     MOVE    R1, 0x10000000  ; 16 nines and 1: 10^16
        ?!Z     MOVE    R4++, R4
:
                ADD     R4, R4, R3      ; the exponent of the first digit
                SUB     R4, R4, 1
                TST     R3
        ?Z      CLR     R4
:
                CMP     R3, 16          ; left-aligned
        ?Z      JMP     :+
                SHL     R1, R1, 4
                SHR     R11, R2, 28
                OR      R1, R1, R11
                SHL     R2, R2, 4
                MOVE    R3++, R3
                JMP     :-
:
                MOVE    @FPU_X_LO, R2
                MOVE    @FPU_X_HI, R1
                MOVE    @FPU_CMD, FPU_FROMBCD
                SUB     @FPU_X_W, R4, 15
                MOVE    @FPU_CMD, FPU_SCALE10
                PUSH    R1
                CALL    check_flags
                POP     R1
                TST     R10
        ?!Z     JMP     :+
                AND[M]  R0, @FPU_STATUS, FPU_FITS
        ?Z      JMP     :+
                MOVE    R3, @FPU_X_W    ; a whole number in a word
                MOVE    @FPU_CMD, FPU_DROP
                CMP     R3, 0x1000000
        ?C      OR      @R8++, R3, K_SMALL*K
        ?C      JMP     tok_next
                MOVE    @R8++, K_WORD*K
                MOVE    @R8++, R3
                JMP     tok_next
:
                AND     R4, R4, 0xFFFF
                OR      @R8++, R4, K_NUM*K
                MOVE    @R8++, @FPU_X_LO
                MOVE    @R8++, @FPU_X_HI
                MOVE    @FPU_CMD, FPU_DROP
                MOVE    @R8++, R2
                MOVE    @R8++, R1
                JMP     tok_next

; A line number, digits only, and no letter, digit, or point after it
tok_line
                MOVE    R6, R5
                CALL    get_lineno
                CMP     R5, R6
        ?Z      JMP     err_syntax      ; no digit
                MOVE    R1, @R5
                CALL    dval
        ?C      JMP     err_syntax
                CMP     R1, 0x2E
        ?Z      JMP     err_syntax
                OR      @R8++, R3, K_LINE*K
                MOVE    @R8++, R0
                JMP     tok_next

; A number in hex after 0x or 0X, of at most 8 significant digits
tok_hex
                ADD     R5, R5, 2
                MOVE    R6, R5
                CLR     R3
:
                MOVE    R1, @R5
                CALL    dval
                CMP     R2, 16
        ?!C     JMP     :+
                CMP     R3, 0x10000000
        ?!C     JMP     err_quant       ; 33 bits or more
                SHL     R3, R3, 4
                OR      R3, R3, R2
                MOVE    R5++, R5
                JMP     :-
:
                CMP     R5, R6
        ?Z      JMP     err_syntax      ; no digits
                CMP     R2, 36
        ?C      JMP     err_syntax      ; a letter after it
                CMP     @R5, 0x2E
        ?Z      JMP     err_syntax
                MOVE    @R8++, K_HEX*K
                MOVE    @R8++, R3
                JMP     tok_next

; bcd_inc: R2 plus the carry R12, 0 or 1, in BCD, and R12 the carry out.
; Uses R6 and R11.
bcd_inc
                MOVE    R11, 8
:
                AND     R6, R2, 0xF
                TST     R12
        ?Z      JMP     :+
                CMP     R6, 9
        ?Z      AND     R2, R2, 0xFFFFFFF0
        ?!Z     ADD     R2, R2, 1
        ?!Z     CLR     R12
:
                ROR     R2, R2, 4
                SUB[M]  R11, R11, 1
        ?!Z     JMP     :--
                RET

; The evaluator. eval_num: an expression from R8, its value on the FPU's
; stack, with its flags checked. eval_word: the same, as a signed word in
; R1, taken off the stack. Both use R1-R7 and R9.
eval_word
                CALL    eval_num
x_word
                AND[M]  R0, @FPU_STATUS, FPU_FITS
        ?Z      JMP     err_quant
                MOVE    R1, @FPU_X_W
                MOVE    @FPU_CMD, FPU_DROP
                RET
eval_num
                CLR     R9
                CALL    expr
; check_flags: the error of the FPU's flags, if any. Uses R1.
check_flags
                AND[M]  R1, @FPU_STATUS, 0xF00
        ?Z      RET
                AND[M]  R0, R1, 0x800   ; stack fault
        ?!Z     JMP     err_complex
                AND[M]  R0, R1, 0x200
        ?!Z     JMP     err_div
                AND[M]  R0, R1, 0x400
        ?!Z     JMP     err_over
                JMP     err_quant

; expr: an operand, then the operators of precedence R9 and more, each
; with an operand of its precedence plus 1, so that they group to the
; left
expr
                CMP     SP, STACK-EXPR_ROOM
        ?C      JMP     err_complex
                PUSH    R9
                CALL    primary
expr_op
                MOVE    R1, @R8
                SHR     R2, R1, 24
                CMP     R2, K_OP
        ?!Z     JMP     :+
                SHR     R3, R1, 16
                AND     R3, R3, 0x7F
                CMP     R3, @SP
        ?C      JMP     :+              ; it binds less
                MOVE    R8++, R8
                PUSH    R1
                ADD     R9, R3, 1
                CALL    expr
                POP     R1
                AND[M]  R0, R1, P_DIVIDES
        ?!Z     AND[M]  R0, @FPU_STATUS, FPU_ZERO
        ?!Z     JMP     err_div
                AND     @FPU_CMD, R1, 0xFFFF
                JMP     expr_op
:
                POP     R9
                RET

; primary: an operand, by the kind of its token
primary
                MOVE    R1, @R8++
                SHR     R2, R1, 24
                CMP     R2, K_ARR
        ?Z      JMP     p_arr
                CMP     R2, K_PRT
        ?!C     JMP     err_syntax
                JMP     @PRIMS[R2]
PRIMS
                .DAT    err_syntax, p_small, p_word, p_word, p_num, err_syntax, p_var
                .DAT    p_op, p_punct, p_fn, p_not, p_kw
p_small
                AND     @FPU_X_W, R1, 0xFFFFFF
                RET
p_word
                MOVE    @FPU_X_W, @R8++
                RET
p_num
                MOVE    @FPU_X_LO, @R8++
                MOVE    @FPU_X_HI, @R8++
                ADD     R8, R8, 2
                RET
p_var
                AND     R1, R1, 0xFFFFFF
                CMP     R1, NO_VAR
        ?Z      JMP     err_undef
                ADD     R1, R1, @V_PEND
                CMP     @1[R1], 0xFFFFFFFF
        ?Z      JMP     err_undef
                MOVE    @FPU_X_LO, @R1
                MOVE    @FPU_X_HI, @1[R1]
                RET
p_arr
                CALL    arr_elem
                MOVE    @FPU_X_LO, @R1
                MOVE    @FPU_X_HI, @1[R1]
                RET
p_kw
                CMP     R1, T_HIMEM
        ?!Z     JMP     err_syntax
                CALL    himem
                MOVE    @FPU_X_W, R2
                RET
p_op
                CMP     R1, T_MINUS
        ?!Z     CMP     R1, T_PLUS
        ?!Z     JMP     err_syntax
                PUSH    R1
                MOVE    R9, PREC_SIGN
                CALL    expr
                POP     R1
                CMP     R1, T_MINUS
        ?Z      MOVE    @FPU_CMD, FPU_NEG
                RET
p_punct
                CMP     R1, T_LPAR
        ?!Z     JMP     err_syntax
                CLR     R9
                CALL    expr
rpar
                CMP     @R8++, T_RPAR
        ?!Z     JMP     err_syntax
                RET
p_fn
                PUSH    R1
                CALL    paren
                POP     R1
                AND[M]  R1, R1, 0xFFFF
        ?!Z     MOVE    @FPU_CMD, R1
        ?!Z     RET
                CALL    x_word          ; PEEK
                MOVE    @FPU_X_W, @R1
                RET
p_not
                MOVE    R9, PREC_NOT
                CALL    expr
                MOVE    @FPU_CMD, FPU_NOT
                RET

; paren: ( and an expression and ), on the FPU's stack. paren_word: the
; same, as a word in R1.
paren
                CMP     @R8++, T_LPAR
        ?!Z     JMP     err_syntax
                CLR     R9
                CALL    expr
                JMP     rpar
paren_word
                CMP     @R8++, T_LPAR
        ?!Z     JMP     err_syntax
                CALL    eval_word
                JMP     rpar

; stmt_end: the end of a statement at R8, where the next statement
; starts, at V_TP, and the return to run_next. Uses R1.
stmt_end
                CALL    at_end
        ?!Z     JMP     err_syntax
                MOVE    @V_TP, R8
                RET

; at_end: Z when the token at R8, R1, ends a statement: the end of the
; line, a colon, or ELSE
at_end
                MOVE    R1, @R8
                TST     R1
        ?!Z     CMP     R1, T_COLON
        ?!Z     CMP     R1, T_ELSE
                RET

; LET V = X, and V = X, which run goes to with R8 at V, a variable or an
; array's element
st_let
                JMP     assign
st_assign
                CMP     R2, K_ARR
        ?!Z     CMP     @1[R8], T_EQ
        ?!Z     JMP     err_unknown
                MOVE    @V_KW, I_LET+1  ; for the lines of HELP of LET
assign
                CALL    lvalue
                CMP     @R8++, T_EQ
        ?!Z     JMP     err_syntax
                PUSH    R1
                CALL    eval_num
                POP     R1
                CALL    store_var
                JMP     stmt_end

; POKE A, X: X to the word at A
bas_poke
                MOVE    @R1, R2
                RET

; PRINT and ?: the items, strings and numbers, with ; between them, or a
; comma, which goes to the next column of 8, and TAB(N), which goes to
; column N, and SPC(N), N blanks. A ; or a comma at the end leaves the
; cursor after the last item; else a CR LF ends the line.
st_print
                CALL    at_end
        ?Z      JMP     pr_end
                CMP     R1, T_SEMI
        ?Z      JMP     pr_next
                CMP     R1, T_COMMA
        ?Z      JMP     pr_comma
                SHR     R2, R1, 24
                CMP     R2, K_STR
        ?Z      JMP     pr_str
                CMP     R2, K_PRT
        ?Z      JMP     pr_tab
                CALL    eval_num
                CALL    put_num
                JMP     st_print
pr_end
                CALL    _io_crlf
                JMP     stmt_end
pr_comma
                MOVE    R1, 0x20
                CALL    MON_PUTC
                CALL    SCR_GETXY
                AND[M]  R0, R1, 7
        ?!Z     JMP     pr_comma
pr_next
                MOVE    R8++, R8
                CALL    at_end
        ?Z      JMP     stmt_end
                JMP     st_print
pr_str
                ADD     R1, R8, 1
                AND     R2, @R8, 0xFFFFFF
                ADD     R8, R8, R2
                ADD     R8, R8, 2
                CALL    _io_puts
                JMP     st_print
pr_tab
                MOVE    R8++, R8
                PUSH    R1
                CALL    paren_word
                MOVE    R7, R1
                CMP     R7, 256
        ?!C     JMP     err_quant       ; not 0 to 255
                POP     R1
                CMP     R1, T_TAB
        ?!Z     JMP     :+
                CALL    SCR_GETXY
                SUB[M]  R7, R7, R1
        ?N      CLR     R7
:
                TST     R7
        ?Z      JMP     st_print
                MOVE    R1, 0x20
                CALL    MON_PUTC
                SUB     R7, R7, 1
                JMP     :-

; put_num: X, taken off the FPU's stack, as %.15G writes it: DIGITS 15
; with the trailing zeros dropped, in fixed notation for the exponents
; -4 to 14, and else in E notation, with a sign and two digits at least.
; A zero, -0 too, is 0. Uses R1-R7 and R9-R12.
put_num
                MOVE    R1, @FPU_STATUS
                AND[M]  R0, R1, FPU_ZERO
        ?!Z     MOVE    @FPU_CMD, FPU_DROP
        ?!Z     MOVE    R1, 0x30
        ?!Z     JMP     putc            ; which returns to the caller
                AND[M]  R0, R1, FPU_NEGATIVE
        ?!Z     MOVE    R1, 0x2D        ; -
        ?!Z     CALL    putc
                MOVE    @FPU_CMD, FPU_DIGITS15
                MOVE    R7, @FPU_X_W    ; the exponent
                MOVE    @FPU_CMD, FPU_DROP
                MOVE    R10, @FPU_X_LO  ; the digits, R9:R10
                MOVE    R9, @FPU_X_HI
                MOVE    @FPU_CMD, FPU_DROP
; put_bcd: the 16 digits in BCD R9:R10, the first in bits 31..28 of R9,
; not all 0, with the exponent R7 of the first, as put_num writes them.
; Uses R1-R7 and R9-R12.
put_bcd
                MOVE    R1, R10         ; R11 the digits without the trailing zeros
                MOVE    R2, R9
                MOVE    R11, 16
:
                AND[M]  R0, R1, 0xF
        ?!Z     JMP     :+
                SHR     R1, R1, 4
                SHL     R3, R2, 28
                OR      R1, R1, R3
                SHR     R2, R2, 4
                SUB     R11, R11, 1
                JMP     :-
:
                ADD     R1, R7, 4
                CMP     R1, 19
        ?!C     JMP     pn_exp
                TST     R7
        ?N      JMP     :+
                ADD     R12, R7, 1      ; the digits before the point
                SUB     R11, R11, R12
                CALL    put_digits
                TST     R11
        ?N      RET
        ?Z      RET
                JMP     pn_frac
:
                MOVE    R1, 0x30        ; 0.
                CALL    putc
                MOVE    R1, 0x2E
                CALL    putc
                NOT     R12, R7         ; -e - 1 zeros
:
                TST     R12
        ?Z      JMP     :+
                MOVE    R1, 0x30
                CALL    putc
                SUB     R12, R12, 1
                JMP     :-
:
                MOVE    R12, R11
                JMP     put_digits      ; which returns to the caller
pn_exp
                ONE     R12
                CALL    put_digits
                SUB[M]  R11, R11, 1
        ?!Z     CALL    pn_frac
                MOVE    R1, 0x45        ; E
                CALL    putc
                MOVE    R1, 0x2B        ; +
                TST     R7
        ?N      MOVE    R1, 0x2D        ; -
        ?N      SUB     R7, R0, R7
                CALL    putc
                CMP     R7, 10
        ?C      MOVE    R1, 0x30
        ?C      CALL    putc
                MOVE    R1, R7
                JMP     putdec          ; which returns to the caller
pn_frac
                MOVE    R1, 0x2E        ; the point, and R11 digits
                CALL    putc
                MOVE    R12, R11
; put_digits: the first R12 digits of R9:R10, which move up. Uses R1-R6.
put_digits
:
                TST     R12
        ?Z      RET
                SHR     R1, R9, 28
                SHL     R9, R9, 4
                SHR     R2, R10, 28
                OR      R9, R9, R2
                SHL     R10, R10, 4
                ADD     R1, R1, 0x30
                CALL    putc
                SUB     R12, R12, 1
                JMP     :-

; The errors: each a message, after a CR LF if the cursor is not in
; column 0. A Syntax error in a statement shows its lines of HELP too,
; and one before a statement's keyword says that HELP lists them.
err_unknown
                MOVE    R1, S_UNKNOWN
                JMP     err
err_syntax
                MOVE    R1, S_SYNTAX
                JMP     err
err_quant
                MOVE    R1, S_QUANT
                JMP     err
err_div
                MOVE    R1, S_DIVZERO
                JMP     err
err_over
                MOVE    R1, S_OVERFLOW
                JMP     err
err_complex
                MOVE    R1, S_COMPLEX
                JMP     err
err_undef
                MOVE    R1, S_UNDEF
                JMP     err
err_memory
                MOVE    R1, S_MEMORY
                JMP     err
err_line
                MOVE    R1, S_LINE
                JMP     err
err_next
                MOVE    R1, S_NEXT
                JMP     err
err_return
                MOVE    R1, S_RETNG
                JMP     err
err_array
                MOVE    R1, S_ARRAY
                JMP     err
err_subscript
                MOVE    R1, S_SUBSCR
                JMP     err
err_redim
                MOVE    R1, S_REDIM
                JMP     err
err_cont
                MOVE    R1, S_CONT
                JMP     err
err_long
                MOVE    R1, S_LONG
                JMP     err
err_nonum
                MOVE    R1, S_NONUM
                JMP     err
err_char
                MOVE    R1, S_CHAR
err
                MOVE    @FPU_CMD, FPU_CLEAR
                MOVE    SP, STACK
                MOVE[M] R8, @V_REDO
        ?!Z     JMP     in_redo         ; in INPUT's line
                CMP     R1, S_SYNTAX
        ?Z      TST     @V_KW
        ?Z      MOVE    R1, S_UNKNOWN   ; not in a statement
                MOVE    R7, R1
                CALL    drop_run        ; no frames, and no CONT
                MOVE    R1, R7
                CALL    put_msg         ; with the line's number in a program
                TST     @V_LBAS
        ?!Z     CALL    show_bline      ; the line of LOAD's file
                CMP     R7, S_SYNTAX
        ?!Z     JMP     main
                MOVE[M] R1, @V_KW
        ?Z      JMP     main
                SUB     R1, R1, 1
                CALL    kw_addr         ; the statement's keyword
                MOVE    R7, R3
                MOVE    R10, HELP
:
                MOVE[M] R12, @R10++
        ?Z      JMP     main
                DBL     R5, R12
                DBL     R5, R5
                ADD     R5, R5, TEXT_B
                MOVE    R3, R7
                CALL    match
        ?!Z     JMP     :-
                MOVE    R1, R12
                CALL    puts_b_crlf
                JMP     :-

S_DIVZERO
                .ASCII_B 'Division by zero'
                .DAT    0
S_OVERFLOW
                .ASCII_B 'Overflow'
                .DAT    0
S_COMPLEX
                .ASCII_B 'Formula too complex'
S_UNDEF         .ASCII_B 'Undefined variable'
S_MEMORY
                .ASCII_B 'Out of memory'
S_LONG          .ASCII_B 'Line too long'
S_NONUM         .ASCII_B 'Line without a number'
S_CHAR          .ASCII_B 'A byte that is no character'
