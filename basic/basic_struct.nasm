; BASIC's structure (stage 8, issue #119, doc/BASIC.md, "Structure"), of
; which this has ON ... GOTO and ON ... GOSUB, and the functions of DEF
; FN on one line.
;
; ON's lines are K_LINE tokens, as GOTO's are, so they keep the address
; of their line once found, and RENUMBER changes them.
;
; A name that starts with FN and goes on is a function's, a K_UFN token,
; or a K_SFNU token with $, whose entry in the table of the variables
; has FUNC in its length. The entry has the address of the token after
; the name in its DEF in the place of the double's low word, and 0 in
; its high word, once a call found the DEF in the program; until then
; its high word is 0xFFFFFFFF, as CLR, RUN, and an edit set it again. A
; function's parameters are numbers' variables, and its arguments
; numbers, one for each. A call keeps the parameters' values on the
; processor's stack while the function's expression runs with the
; arguments in them, and sets them again after it, so that a function
; may call itself, as deep as an expression may nest.

FUNC            .EQU    0x400           ; in the length of a function's name

; ON X GOTO N, M, ... and ON X GOSUB N, M, ...: the line of the X-th
; number, X rounded toward zero, as GOTO and GOSUB go to it. An X of 0,
; or past the list, goes on after the statement, as in V2, and one below
; 0 is Illegal quantity.
st_on
                CALL    eval_word
                TST     R1
        ?N      JMP     err_quant
                MOVE    R2, @R8++
                AND     R2, R2, 0xFFFFFF00
                CMP     R2, K_KW*K+I_GOTO*0x100
        ?!Z     CMP     R2, K_KW*K+I_GOSUB*0x100
        ?!Z     JMP     err_syntax
                CLR     R10             ; the X-th line's token, or 0
:
                SHR     R3, @R8, 24
                CMP     R3, K_LINE
        ?!Z     JMP     err_syntax
                SUB[M]  R1, R1, 1
        ?Z      MOVE    R10, R8
                ADD     R8, R8, 2
                CMP     @R8, T_COMMA
        ?Z      MOVE    R8++, R8
        ?Z      JMP     :-
                CALL    stmt_end
                TST     R10
        ?Z      RET                     ; no such line: the next statement
                CMP     R2, K_KW*K+I_GOSUB*0x100
        ?!Z     JMP     :+
                MOVE    R1, GOSUB_WORDS
                CALL    frame_new
                MOVE    @R1, GOSUB_TAG
                MOVE    @1[R1], R8
                MOVE    @2[R1], @V_CUR
:
                MOVE    R8, R10
                JMP     go_line

; DEF FNNAME[(P, ...)] = X: a function, which its first call finds in
; the program. When it runs, DEF passes over the rest of its line, as REM
; does.
st_def
                SHR     R2, @R8, 24
                CMP     R2, K_UFN
        ?!Z     CMP     R2, K_SFNU
        ?!Z     JMP     err_syntax
:
                MOVE[M] R1, @R8
        ?Z      JMP     :+
                CALL    tok_skip
                JMP     :-
:
                MOVE    @V_TP, R8
                RET

; p_ufn: for primary, FNNAME[(X, ...)], with R1 its token and R8 after
; it, its value on the FPU's stack. s_ufn: for sprimary, FNNAME$[(X,
; ...)], its string on the strings' stack. A function that no DEF of the
; program has is Undefined function, a count of arguments that is not
; that of the parameters a Syntax error, and a string's parameter a Type
; mismatch. Keeps R10-R12. Uses R1-R9.
p_ufn
s_ufn
                PUSH    R10
                PUSH    R11
                PUSH    R12
                MOVE    R10, R1         ; the token
                AND     R1, R1, 0xFFFFFF
                CMP     R1, NO_VAR
        ?Z      JMP     err_fn
                ADD     R11, R1, @V_PEND  ; the entry
                CMP     @1[R11], 0xFFFFFFFF
        ?Z      CALL    fn_find
                PUSH    @R11            ; the DEF's tokens after its name
                CLR     R12             ; the arguments, on the FPU's stack
                CMP     @R8, T_LPAR
        ?!Z     JMP     fc_params
                MOVE    R8++, R8
:
                PUSH    R12
                CALL    eval_num
                POP     R12
                MOVE    R12++, R12
                MOVE    R1, @R8++
                CMP     R1, T_COMMA
        ?Z      JMP     :-
                CMP     R1, T_RPAR
        ?!Z     JMP     err_syntax
fc_params
                POP     R10
                SHR     R7, @-1[R10], 24  ; the kind, K_UFN or K_SFNU
                PUSH    R8              ; the caller's tokens
                CLR     R11             ; the parameters, each its address and its value
                CMP     @R10, T_LPAR
        ?!Z     JMP     fc_bind
                MOVE    R10++, R10
:
                MOVE    R1, @R10++
                SHR     R2, R1, 24
                CMP     R2, K_SVAR
        ?Z      JMP     err_type
                CMP     R2, K_VAR
        ?!Z     JMP     err_syntax
                AND     R1, R1, 0xFFFFFF
                ADD     R1, R1, @V_PEND
                PUSH    R1
                PUSH    @R1
                PUSH    @1[R1]
                MOVE    R11++, R11
                MOVE    R1, @R10++
                CMP     R1, T_COMMA
        ?Z      JMP     :-
                CMP     R1, T_RPAR
        ?!Z     JMP     err_syntax
fc_bind
                CMP     R11, R12
        ?!Z     JMP     err_syntax
                ADD     R2, SP, 2       ; the last parameter's address
                MOVE    R3, R11
:
                SUB[M]  R3, R3, 1       ; the last argument, on top, into it
        ?N      JMP     :+
                MOVE    R1, @R2
                MOVE    @R1, @FPU_X_LO
                MOVE    @1[R1], @FPU_X_HI
                MOVE    @FPU_CMD, FPU_DROP
                ADD     R2, R2, 3
                JMP     :-
:
                CMP     @R10++, T_EQ
        ?!Z     JMP     err_syntax
                MOVE    R8, R10
                PUSH    R11
                CMP     R7, K_SFNU
        ?Z      JMP     :+
                CALL    eval_num
                JMP     :++
:
                CALL    sexpr
:
                CALL    at_end
        ?!Z     JMP     err_syntax
                POP     R11
:
                SUB[M]  R11, R11, 1     ; the parameters' values again
        ?N      JMP     :+
                POP     R3
                POP     R2
                POP     R1
                MOVE    @R1, R2
                MOVE    @1[R1], R3
                JMP     :-
:
                POP     R8
                POP     R12
                POP     R11
                POP     R10
                RET

; fn_find: the DEF of the function of the token R10 in the program, whose
; tokens after the name go into the entry R11, with 0 in its high word;
; Undefined function when there is none. Keeps R8. Uses R1-R3.
fn_find
                PUSH    R8
                MOVE    R1, PROGRAM
ff_line
                CMP     R1, @V_PEND
        ?!C     JMP     err_fn
                ADD     R8, R1, 2
ff_tok
                MOVE[M] R2, @R8
        ?Z      JMP     ff_next
                AND     R2, R2, 0xFFFFFF00
                CMP     R2, K_KW*K+I_DEF*0x100
        ?Z      CMP     @1[R8], R10
        ?Z      JMP     ff_found
                CALL    tok_skip
                JMP     ff_tok
ff_next
                ADD     R1, R1, @R1
                JMP     ff_line
ff_found
                ADD     @R11, R8, 2
                MOVE    @1[R11], R0
                POP     R8
                RET

; fn_forget: each function's DEF to be found again, after an edit. A
; length of 0 or above 16 ends the walk, as it ends var_find's. Uses R1
; and R2.
fn_forget
                MOVE    R1, @V_PEND
:
                CMP     R1, @V_VEND
        ?!C     RET
                MOVE    R2, @2[R1]
                AND[M]  R0, R2, FUNC
        ?!Z     MOVE    @1[R1], 0xFFFFFFFF
                AND[M]  R2, R2, NAME_LEN
        ?Z      RET
                CMP     R2, 17
        ?!C     RET
                ADD     R2, R2, 3
                SHR     R2, R2, 2
                ADD     R1, R1, R2
                ADD     R1, R1, 3
                JMP     :-

err_fn
                MOVE    R1, S_FN
                JMP     err

S_FN            .ASCII_B 'Undefined function'
