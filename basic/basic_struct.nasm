; BASIC's structure (stage 8, issue #119, doc/BASIC.md, "Structure"), of
; which this has ON ... GOTO and ON ... GOSUB, the functions of DEF FN on
; one line, DO and LOOP with WHILE and UNTIL, and EXIT, and IF, ELSE,
; and ENDIF over lines.
;
; A DO frame is DO_TAG, the token after DO, where its WHILE or UNTIL is,
; DO's line, and the token after the LOOP statement that matches it and
; its line, 0 until a LOOP went back to the DO. It is FOR_WORDS words,
; as the walks of the frames pass over a frame that is not GOSUB's by
; FOR_WORDS. A LOOP drops the FOR frames after its DO's, and a DO that
; runs again, after a GOTO, drops its own frame and those after it.
;
; A block IF is an IF whose THEN ends its line, which the tokenizer
; makes T_BTHEN, and the ELSE of a block starts its line, T_BELSE, and so
; does its ENDIF. Each of T_BTHEN and T_BELSE has a word after it, the
; line where the block goes on, its ELSE's or its ENDIF's, 0 until the
; first run finds it; an edit clears it, as it clears K_LINE's.
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
DO_TAG          .EQU    0x44000000      ; D, a DO frame's

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

; DO [WHILE X | UNTIL X]: a DO frame, and the statements after it while X
; is not 0, or until it is not 0; else on after the LOOP that matches
st_do
                CALL    himem           ; this DO's frame, from a GOTO
                MOVE    R1, @V_FP       ; back to it, and those after it
:
                CMP     R1, R2
        ?!C     JMP     :++
                AND     R3, @R1, 0xFF000000
                CMP     R3, GOSUB_TAG
        ?Z      JMP     :++
                CMP     R3, DO_TAG
        ?Z      CMP     @1[R1], R8
        ?Z      JMP     :+
                ADD     R1, R1, FOR_WORDS
                JMP     :-
:
                ADD     @V_FP, R1, FOR_WORDS
:
                MOVE    R1, FOR_WORDS
                CALL    frame_new
                MOVE    @R1, DO_TAG
                MOVE    @1[R1], R8
                MOVE    @2[R1], @V_CUR
                MOVE    @3[R1], R0
; do_test: the WHILE or UNTIL at R8 of the DO of the frame R1, whose line
; V_CUR is: the statements after the DO when it holds, else those after
; the LOOP, without the frame
do_test
                PUSH    R1
                CALL    cond
                PUSH    R3
                CALL    stmt_end
                POP     R3
                POP     R1
                TST     R3
        ?!Z     RET
; do_leave: the frame R1 and those after it gone, and on after its LOOP
do_leave
                ADD     @V_FP, R1, FOR_WORDS
                MOVE[M] R2, @3[R1]
        ?Z      JMP     :+
                MOVE    @V_CUR, @4[R1]
                MOVE    @V_TP, R2
                RET
:
                MOVE    R8, @1[R1]
                MOVE    R10, @2[R1]
                CALL    scan_loop
                MOVE    @V_CUR, R10
                MOVE    @V_TP, R8
                RET

; LOOP [WHILE X | UNTIL X]: back to the latest DO, and its test, while X
; is not 0, or until it is not 0; else on after the LOOP, without the DO
; frame. A LOOP with no DO frame after the last GOSUB's is LOOP without
; DO.
st_loop
                CALL    find_do
        ?Z      JMP     err_loop
                PUSH    R1
                CALL    cond
                PUSH    R3
                CALL    stmt_end
                POP     R3
                POP     R1
                TST     R3
        ?Z      ADD     @V_FP, R1, FOR_WORDS
        ?Z      RET
                MOVE    @3[R1], R8
                MOVE    @4[R1], @V_CUR
                MOVE    @V_FP, R1       ; the FOR frames after it go
                MOVE    @V_CUR, @2[R1]
                MOVE    R8, @1[R1]
                JMP     do_test

; EXIT: on after the LOOP of the latest DO, without its frame and those
; after it; EXIT without DO when there is none
st_exit
                CALL    stmt_end
                CALL    find_do
        ?Z      JMP     err_exit
                JMP     do_leave

; find_do: R1 the latest DO frame, with FOR frames alone after it, and
; not Z; or Z when there is none. Uses R2 and R3.
find_do
                CALL    himem
                MOVE    R1, @V_FP
:
                CMP     R1, R2
        ?!C     JMP     :+
                AND     R3, @R1, 0xFF000000
                CMP     R3, DO_TAG
        ?Z      JMP     :++
                CMP     R3, FOR_TAG
        ?!Z     JMP     :+
                ADD     R1, R1, FOR_WORDS
                JMP     :-
:
                CMP     R0, R0          ; Z
                RET
:
                CMP     R0, 1           ; not Z
                RET

; cond: the WHILE X or UNTIL X at R8, and R8 after it: R3 1 when the
; loop goes on, as X is not 0 after WHILE, or 0 after UNTIL, else 0;
; and 1 without either. Uses R1-R7 and R9.
cond
                ONE     R3
                MOVE    R1, @R8
                CMP     R1, T_WHILE
        ?!Z     CMP     R1, T_UNTIL
        ?!Z     RET
                MOVE    R8++, R8
                PUSH    R1
                CALL    eval_num
                POP     R1
                MOVE    R2, @FPU_STATUS
                MOVE    @FPU_CMD, FPU_DROP
                CLR     R3
                AND[M]  R0, R2, FPU_ZERO
        ?Z      ONE     R3              ; X is not 0
                CMP     R1, T_UNTIL
        ?Z      XOR     R3, R3, 1
                RET

; scan_loop: R8 after the LOOP statement that matches a DO, and R10 its
; line, from R8 after that DO in the line R10, or 0 for a direct line,
; counting the DOs and LOOPs between; Missing LOOP when there is none.
; Uses R1-R4.
scan_loop
                CLR     R4              ; the depth
sl_tok
                MOVE[M] R2, @R8
        ?!Z     JMP     :+
                TST     R10             ; the end of the line
        ?Z      JMP     err_noloop
                ADD     R10, R10, @R10
                CMP     R10, @V_PEND
        ?!C     JMP     err_noloop
                ADD     R8, R10, 2
                JMP     sl_tok
:
                AND     R2, R2, 0xFFFFFF00
                CMP     R2, K_KW*K+I_DO*0x100
        ?Z      ADD     R4, R4, 1
                CMP     R2, K_KW*K+I_LOOP*0x100
        ?!Z     JMP     :+
                SUB[M]  R4, R4, 1
        ?N      JMP     sl_found
:
                CALL    tok_skip
                JMP     sl_tok
sl_found
                MOVE    R8++, R8        ; LOOP's WHILE or UNTIL, passed over
:
                CALL    at_end
        ?Z      RET
                CALL    tok_skip
                JMP     :-

; if_block: for IF, a block, with R8 at its T_BTHEN and R1 the FPU's
; status of its X: the next line when X is not 0, else the statements
; after the ELSE that matches, or its ENDIF's line, which it finds once
; and keeps in the word after T_BTHEN. In a direct line, no line follows.
if_block
                ADD     R8, R8, 2       ; the end of the line
                MOVE    @V_TP, R8
                AND[M]  R0, R1, FPU_ZERO
        ?Z      RET
                MOVE[M] R3, @V_CUR
        ?Z      RET
                MOVE[M] R1, @-1[R8]
        ?!Z     JMP     :+
                ADD     R1, R3, @R3     ; from the next line
                ONE     R9              ; to an ELSE or an ENDIF
                CALL    blk_scan
                MOVE    @-1[R8], R1
:
                MOVE    @V_CUR, R1
                CMP     @2[R1], T_BELSE
        ?Z      ADD     @V_TP, R1, 4    ; after ELSE and its word
        ?!Z     ADD     @V_TP, R1, 2
                RET

; blk_else: a block's ELSE, with R8 at its T_BELSE, which the statements
; before it reach: on at its ENDIF's line, which it finds once and keeps
; in the word after T_BELSE
blk_else
                MOVE[M] R3, @V_CUR
        ?Z      JMP     err_unknown     ; a direct line
                MOVE[M] R1, @1[R8]
        ?!Z     JMP     go_to
                ADD     R1, R3, @R3
                CLR     R9              ; to the ENDIF
                CALL    blk_scan
                MOVE    @1[R8], R1
                JMP     go_to

; ENDIF: the end of a block IF, where it goes on
st_endif
                JMP     stmt_end

; blk_scan: R1 the line of the ELSE that matches a block IF, when R9 is
; not 0, or of its ENDIF, from the line R1 on, counting the block IFs
; and ENDIFs between; Missing ENDIF when there is none. Keeps R8. Uses
; R1-R5.
blk_scan
                PUSH    R8
                CLR     R4              ; the depth
bs_line
                CMP     R1, @V_PEND
        ?!C     JMP     err_endif
                MOVE    R2, @2[R1]      ; the line's first token
                CMP     R2, T_BELSE
        ?!Z     JMP     bs_endif
                TST     R4
        ?!Z     JMP     bs_last
                TST     R9
        ?!Z     JMP     bs_found
                JMP     bs_last
bs_endif
                AND     R2, R2, 0xFFFFFF00
                CMP     R2, K_KW*K+I_ENDIF*0x100
        ?!Z     JMP     bs_last
                SUB[M]  R4, R4, 1
        ?N      JMP     bs_found
bs_last
                ADD     R8, R1, 2       ; its last token
                MOVE    R5, R8
:
                MOVE[M] R2, @R8
        ?Z      JMP     :+
                MOVE    R5, R8
                CALL    tok_skip
                JMP     :-
:
                CMP     @R5, T_BTHEN
        ?Z      ADD     R4, R4, 1
                ADD     R1, R1, @R1
                JMP     bs_line
bs_found
                POP     R8
                RET

err_fn
                MOVE    R1, S_FN
                JMP     err
err_loop
                MOVE    R1, S_LOOP
                JMP     err
err_exit
                MOVE    R1, S_EXIT
                JMP     err
err_noloop
                MOVE    R1, S_NOLOOP
                JMP     err
err_endif
                MOVE    R1, S_ENDIF
                JMP     err

S_FN            .ASCII_B 'Undefined function'
S_LOOP          .ASCII_B 'LOOP without DO'
S_EXIT          .ASCII_B 'EXIT without DO'
S_NOLOOP
                .ASCII_B 'Missing LOOP'
                .DAT    0
S_ENDIF         .ASCII_B 'Missing ENDIF'
