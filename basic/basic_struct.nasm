; BASIC's structure (stage 8, issue #119, doc/BASIC.md, "Structure"): ON
; ... GOTO and ON ... GOSUB, DEF FN, DEF PROC, ENDPROC, LOCAL, DO and
; LOOP with WHILE and UNTIL, and EXIT, and IF, ELSE, and ENDIF over
; lines.
;
; A DO frame is DO_TAG, the token after DO, where its WHILE or UNTIL is,
; DO's line, and the token after the LOOP statement that matches it and
; its line, 0 until a LOOP went back to the DO, FOR_WORDS words in all. A
; LOOP drops the FOR frames after its DO's, and a DO that runs again,
; after a GOTO, drops its own frame and the FOR and DO frames after it.
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
; A name that starts with FN or PROC and goes on is a function's or a
; procedure's, a K_UFN token, or a K_SFNU token with $, whose entry in
; the table of the variables has FUNC in its length. The entry has the
; address of the token after the name in its DEF in the place of the
; double's low word, and the DEF's line in its high word, once a call
; found the DEF in the program; until then its high word is 0xFFFFFFFF,
; as CLR, RUN, and an edit set it again.
;
; A call evaluates an argument for each parameter, a number on the FPU's
; stack or a string on the strings' stack, and then pushes an L frame,
; LOCAL_TAG's, with the parameters' values, which then hold the
; arguments. LOCAL pushes one as well. An L frame has three words for
; each variable: its offset, with bit 31 for a string's, and its two
; words. The block of a string that the frame keeps is the frame's, its
; back word TAG_FRAME and the offset of the two words from V_STOP, so
; the sweep keeps it. unwind sets the variables again, each block their
; variable's again, when ENDPROC, =, or RETURN drops the frame.
;
; A procedure's call pushes a PROC frame before the L frame, PROC_TAG,
; the token after the call, and its line, where ENDPROC goes on. A
; function on one line evaluates the X of its DEF's = X with the
; parameters set. A function over lines runs its lines from after its
; DEF's parameters, up to the statement = X, as statements of their own,
; in a loop of run on the processor's stack of its call, below V_SBASE.
; Its FN frame, after the L frame, has the old V_SBASE, V_CUR, and V_SSB,
; the function's kind, and the numbers that pended on the FPU's stack at
; the call, their count, and theirs, the top last. = X drops the frames
; after it, puts the numbers back below X, and returns from the call
; with SP at V_SBASE. A function may call itself while SP is FN_ROOM
; words below STACK at most, which leaves an expression EXPR_ROOM words
; below that, and the frames room. The FN frame stops a RETURN, an
; ENDPROC, and an EXIT, as the PROC frame stops a RETURN and an =.

FUNC            .EQU    0x400           ; in the length of a function's name
DO_TAG          .EQU    0x44000000      ; D, a DO frame's
LOCAL_TAG       .EQU    0x4C000000      ; L, an L frame's
FN_TAG          .EQU    0x4E000000      ; N, a FN frame's,
FN_WORDS        .EQU    6               ; and its words, and 2 for each number
PROC_TAG        .EQU    0x50000000      ; P, a PROC frame's,
PROC_WORDS      .EQU    3               ; and its words
FN_ROOM         .EQU    0x200           ; the words of the processor's stack that FNs may take

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
                MOVE    @R1, GOSUB_TAG+GOSUB_WORDS*SIZE1
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
; ...)], its string on the strings' stack. Keeps R10-R12. Uses R1-R9.
p_ufn
s_ufn
                PUSH    R10
                PUSH    R11
                PUSH    R12
                SHR     R2, R1, 24
                PUSH    R2              ; the kind, K_UFN or K_SFNU
                MOVE    R9, S_FN
                CALL    fn_args
                PUSH    R8
                CMP     @R10, T_EQ
        ?!Z     JMP     fc_body
                ADD     R8, R10, 1      ; DEF FNNAME(...) = X
                ADD     R1, SP, 1
                MOVE    R1, @R1
                CALL    fn_eq
fc_end
                MOVE    R1, @V_FP       ; the parameters' frame, gone
                CALL    frame_end
                CALL    unwind
                POP     R8
                POP     R2
                POP     R12
                POP     R11
                POP     R10
                RET
; fc_body: a function over lines: a FN frame, with the numbers that pend
; on the FPU's stack, and its lines from R10, the DEF's line R11, up to
; its =, which returns from fn_body
fc_body
                CMP     SP, STACK-FN_ROOM
        ?C      JMP     err_complex
                AND     R4, @FPU_STATUS, 0x1F  ; the numbers that pend
                DBL     R5, R4
                ADD     R5, R5, FN_WORDS
                MOVE    R1, R5
                CALL    frame_new
                SHL     R5, R5, 16
                OR      R5, R5, FN_TAG
                MOVE    @R1, R5
                MOVE    @1[R1], @V_SBASE
                MOVE    @2[R1], @V_CUR
                MOVE    @3[R1], @V_SSB
                ADD     R2, SP, 1
                MOVE    @4[R1], @R2     ; the kind
                MOVE    @5[R1], R4
                DBL     R3, R4
                ADD     R3, R3, R1
                ADD     R3, R3, FN_WORDS
:
                SUB[M]  R4, R4, 1
        ?N      JMP     :+
                SUB     R3, R3, 2
                MOVE    @R3, @FPU_X_LO
                MOVE    @1[R3], @FPU_X_HI
                MOVE    @FPU_CMD, FPU_DROP
                JMP     :-
:
                MOVE    @V_SSB, @V_SSP
                MOVE    @V_CUR, R11
                MOVE    R8, R10
                CALL    fn_body
                JMP     fc_end
fn_body
                MOVE    @V_SBASE, SP
                SUB     R1, SP, EXPR_ROOM
                MOVE    @V_ELIM, R1
                JMP     run

; = X: the value of the FN over lines that runs, X, back to the
; expression that called it, without the frames after its FN frame, each
; LOCAL's variables set again; = without FN when no FN frame comes before
; a PROC frame
st_fnret
                MOVE    R3, 0x4E        ; N
                MOVE    R4, 0x10000     ; not past a PROC's
                CALL    frame_find
        ?Z      JMP     err_fnret
                PUSH    R1
                MOVE    R8++, R8
                MOVE    R1, @4[R1]      ; the kind
                CALL    fn_eq
                POP     R1
                CALL    unwind
                MOVE    @V_CUR, @2[R1]
                MOVE    @V_SSB, @3[R1]
                MOVE    R9, @V_SBASE    ; the call's SP
                MOVE    R2, @1[R1]
                MOVE    @V_SBASE, R2
                SUB     R2, R2, EXPR_ROOM
                MOVE    @V_ELIM, R2
                CALL    frame_end
                MOVE    @V_FP, R1
                SUB     R1, R1, R2      ; the FN frame again
                CMP     @4[R1], K_SFNU
        ?Z      JMP     :+
                MOVE    R6, @FPU_X_LO   ; the value
                MOVE    R7, @FPU_X_HI
                MOVE    @FPU_CMD, FPU_DROP
:
                MOVE    R4, @5[R1]      ; the numbers that pended
                ADD     R5, R1, FN_WORDS
:
                SUB[M]  R4, R4, 1
        ?N      JMP     :+
                MOVE    @FPU_X_LO, @R5++
                MOVE    @FPU_X_HI, @R5++
                JMP     :-
:
                CMP     @4[R1], K_SFNU
        ?Z      JMP     :+
                MOVE    @FPU_X_LO, R6
                MOVE    @FPU_X_HI, R7
:
                MOVE    SP, R9
                RET

; fn_eq: a function's value, the X at R8 of = X, for the kind R1: a
; number on the FPU's stack for K_UFN, else a string on the strings'
; stack, in a block of its own, as the frames may set again a variable
; whose string it is; a Syntax error unless the statement ends after X.
; Uses R1-R12.
fn_eq
                PUSH    R1
                CMP     R1, K_SFNU
        ?Z      JMP     :+
                CALL    eval_num
                JMP     :++
:
                CALL    sexpr
:
                CALL    at_end
        ?!Z     JMP     err_syntax
                POP     R1
                CMP     R1, K_SFNU
        ?Z      JMP     s_own
                RET

; fn_args: a call of the function or the procedure of the token R1, with
; its arguments at R8: its DEF, found once, an argument for each of its
; parameters, a number's or a string's, evaluated, and an L frame with
; the parameters' values, which then hold the arguments. R8 after the
; call, R10 after the DEF's parameters, and R11 the DEF's line. The
; message R9 when no DEF has it, Undefined function or procedure, and a
; Syntax error when the arguments do not match the parameters. Uses
; R1-R12.
fn_args
                MOVE    R10, R1
                AND     R1, R1, 0xFFFFFF
                CMP     R1, NO_VAR
        ?Z      MOVE    R1, R9
        ?Z      JMP     err
                ADD     R11, R1, @V_PEND  ; the entry
                CMP     @1[R11], 0xFFFFFFFF
        ?Z      CALL    fn_find
                PUSH    R11
                MOVE    R10, @R11       ; the DEF's tokens after its name
                CLR     R12             ; the parameters
                CMP     @R10, T_LPAR
        ?!Z     JMP     fa_frame
                CMP     @R8++, T_LPAR
        ?!Z     JMP     err_syntax
fa_arg
                MOVE    R10++, R10      ; past ( or ,
                SHR     R2, @R10, 24
                PUSH    R10
                PUSH    R12
                CMP     R2, K_SVAR
        ?Z      JMP     :+
                CMP     R2, K_VAR
        ?!Z     JMP     err_syntax
                CALL    eval_num
                JMP     :++
:
                CALL    sexpr
:
                POP     R12
                POP     R10
                MOVE    R12++, R12
                MOVE    R10++, R10      ; the , or ) after the parameter
                MOVE    R1, @R8++       ; and after the argument
                CMP     R1, @R10
        ?!Z     JMP     err_syntax
                CMP     R1, T_COMMA
        ?Z      JMP     fa_arg
                CMP     R1, T_RPAR
        ?!Z     JMP     err_syntax
                MOVE    R10++, R10
fa_frame
                PUSH    R8
                PUSH    R10
                ADD     R1, R12, R12    ; the L frame, 3 words a parameter
                ADD     R1, R1, R12
                ADD     R1, R1, 1
                MOVE    R9, R1
                CALL    frame_new
                SHL     R9, R9, 16
                OR      R9, R9, LOCAL_TAG
                MOVE    @R1, R9
                ADD     R2, SP, 2       ; the parameters again
                MOVE    R10, @R2
                MOVE    R10, @R10
                ADD     R10, R10, 1     ; past (
                ADD     R1, R1, 1
                MOVE    R6, R12
:
                SUB[M]  R6, R6, 1
        ?N      JMP     fa_bind
                MOVE    R2, @R10
                ADD     R10, R10, 2     ; and its , or )
                CALL    save_var
                ADD     R1, R1, 3
                JMP     :-
fa_bind
                MOVE    R10, R1         ; the arguments into them, the last first
:
                SUB[M]  R12, R12, 1
        ?N      JMP     :++
                SUB     R10, R10, 3
                MOVE    R2, @R10
                AND     R1, R2, 0xFFFFFF
                ADD     R1, R1, @V_PEND
                TST     R2
        ?N      JMP     :+
                MOVE    @R1, @FPU_X_LO
                MOVE    @1[R1], @FPU_X_HI
                MOVE    @FPU_CMD, FPU_DROP
                JMP     :-
:
                CALL    store_str
                JMP     :--
:
                POP     R10
                POP     R8
                POP     R11
                MOVE    R11, @1[R11]    ; the DEF's line
                RET

; save_var: the variable of the token R2, K_VAR or K_SVAR, into the three
; words at R1 of an L frame, and the variable 0, or empty; the block of
; its string the frame's. Uses R3-R5.
save_var
                AND     R3, R2, 0xFFFFFF
                ADD     R4, R3, @V_PEND
                MOVE    @1[R1], @R4
                MOVE    @2[R1], @1[R4]
                MOVE    @R4, R0
                MOVE    @1[R4], R0
                SHR     R5, R2, 24
                CMP     R5, K_SVAR
        ?!Z     JMP     :+
                OR      R3, R3, 0x80000000
                MOVE    @R1, R3
                MOVE[M] R3, @2[R1]      ; the length
        ?Z      RET
                CMP     R3, 0xFFFFFFFF
        ?Z      RET
                ADD     R3, R3, @1[R1]  ; the block's length word
                SUB     R5, R1, @V_STOP
                ADD     R5, R5, 1
                OR      R5, R5, TAG_FRAME
                MOVE    @1[R3], R5
                RET
:
                MOVE    @R1, R3
                RET

; unwind: the frames from V_FP up to R1 gone, each L frame's variables
; set again, and their strings' blocks theirs, and V_FP R1. Keeps R1.
; Uses R2-R7.
unwind
                MOVE    R2, @V_FP
uw_frame
                CMP     R2, R1
        ?!C     JMP     uw_done
                SHR     R3, @R2, 16
                AND     R3, R3, 0xFF
                ADD     R7, R2, R3      ; the next frame
                SHR     R3, @R2, 24
                CMP     R3, 0x4C        ; L
        ?!Z     JMP     uw_next
                ADD     R2, R2, 1
uw_var
                CMP     R2, R7
        ?!C     JMP     uw_next
                MOVE    R3, @R2
                AND     R4, R3, 0xFFFFFF
                ADD     R5, R4, @V_PEND
                MOVE    @R5, @1[R2]
                MOVE    @1[R5], @2[R2]
                TST     R3
        ?!N     JMP     :+
                MOVE[M] R6, @2[R2]      ; a string's length
        ?Z      JMP     :+
                CMP     R6, 0xFFFFFFFF
        ?Z      JMP     :+
                ADD     R6, R6, @1[R2]
                MOVE    @1[R6], R4      ; the variable's block again
:
                ADD     R2, R2, 3
                JMP     uw_var
uw_next
                MOVE    R2, R7
                JMP     uw_frame
uw_done
                MOVE    @V_FP, R1
                RET

; frame_end: R1 after the frame R1. Uses R2.
frame_end
                SHR     R2, @R1, 16
                AND     R2, R2, 0xFF
                ADD     R1, R1, R2
                RET

; frame_find: R1 the latest frame of the kind R3, a letter, and not Z;
; or Z when there is none, with R1 at R2, himem, or when a frame of a
; kind in the mask R4 comes first, a bit for each letter from 0x40, with
; R1 at it. Uses R5.
frame_find
                CALL    himem
                MOVE    R1, @V_FP
:
                CMP     R1, R2
        ?!C     JMP     :+
                SHR     R5, @R1, 24
                CMP     R5, R3
        ?Z      JMP     :++
                SUB     R5, R5, 0x40
                SHR     R5, R4, R5
                AND[M]  R0, R5, 1
        ?!Z     JMP     :+
                SHR     R5, @R1, 16
                AND     R5, R5, 0xFF
                ADD     R1, R1, R5
                JMP     :-
:
                CMP     R0, R0          ; Z
                RET
:
                CMP     R0, 1           ; not Z
                RET

; PROCNAME[(X, ...)]: the lines of DEF PROCNAME from after its
; parameters, which hold the arguments, up to ENDPROC, which goes on
; after the call
st_proc
                MOVE    R1, PROC_WORDS
                CALL    frame_new
                MOVE    @R1, PROC_TAG+PROC_WORDS*SIZE1
                MOVE    @2[R1], @V_CUR
                PUSH    R1
                MOVE    R1, @R8++
                MOVE    R9, S_PROC
                CALL    fn_args
                CALL    stmt_end
                POP     R1
                MOVE    @1[R1], R8
                MOVE    @V_CUR, R11
                MOVE    @V_TP, R10
                RET

; ENDPROC: on after the call of the latest PROC, without its frame and
; those after it, each LOCAL's variables set again; ENDPROC without PROC
; when there is none after the last FN frame
st_endproc
                CALL    stmt_end
                MOVE    R3, 0x50        ; P
                MOVE    R4, 0x4000      ; not past a FN's
                CALL    frame_find
        ?Z      JMP     err_endproc
                CALL    unwind
                MOVE    @V_TP, @1[R1]
                MOVE    @V_CUR, @2[R1]
                ADD     @V_FP, R1, PROC_WORDS
                RET

; LOCAL V [, W$ ...]: the variables' values kept in an L frame, until the
; ENDPROC or the = of the PROC or FN that runs, and V 0 and W$ empty;
; LOCAL without PROC when neither runs
st_local
                MOVE    R3, 0x50        ; P
                MOVE    R4, 0x4000      ; or N
                CALL    frame_find
        ?Z      CMP     R1, R2
        ?Z      JMP     err_local
                MOVE    R6, R8          ; the variables, counted
                CLR     R7
:
                MOVE    R1, @R6++
                SHR     R2, R1, 24
                CMP     R2, K_VAR
        ?!Z     CMP     R2, K_SVAR
        ?!Z     JMP     err_syntax
                AND     R1, R1, 0xFFFFFF
                CMP     R1, NO_VAR
        ?Z      JMP     err_syntax
                ADD     R7, R7, 3
                CMP     @R6, T_COMMA
        ?Z      MOVE    R6++, R6
        ?Z      JMP     :-
                ADD     R1, R7, 1
                MOVE    R6, R1
                CALL    frame_new
                SHL     R6, R6, 16
                OR      R6, R6, LOCAL_TAG
                MOVE    @R1, R6
                MOVE    R1++, R1
:
                MOVE    R2, @R8++
                CALL    save_var
                ADD     R1, R1, 3
                CMP     @R8, T_COMMA
        ?Z      MOVE    R8++, R8
        ?Z      JMP     :-
                JMP     stmt_end

; fn_find: the DEF of the function or procedure of the token R10 in the
; program, whose tokens after the name go into the entry R11, and its
; line into its high word; the message R9 when there is none. Keeps R8.
; Uses R1-R3.
fn_find
                PUSH    R8
                MOVE    R1, PROGRAM
ff_line
                CMP     R1, @V_PEND
        ?C      JMP     :+
                MOVE    R1, R9
                JMP     err
:
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
                MOVE    @1[R11], R1
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
                CMP     R3, DO_TAG
        ?Z      CMP     @1[R1], R8
        ?Z      JMP     :+
                CMP     R3, DO_TAG
        ?!Z     CMP     R3, FOR_TAG
        ?!Z     JMP     :++
                ADD     R1, R1, FOR_WORDS
                JMP     :-
:
                ADD     @V_FP, R1, FOR_WORDS
:
                MOVE    R1, FOR_WORDS
                CALL    frame_new
                MOVE    @R1, DO_TAG+FOR_WORDS*SIZE1
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

err_fnret
                MOVE    R1, S_FNRET
                JMP     err
err_noeq
                MOVE    R1, S_NOEQ
                JMP     err
err_endproc
                MOVE    R1, S_ENDPROC
                JMP     err
err_local
                MOVE    R1, S_LOCAL
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
S_PROC          .ASCII_B 'Undefined procedure'
S_FNRET         .ASCII_B '= without FN'
                .DAT    0
S_NOEQ          .ASCII_B 'FN without ='
                .DAT    0
S_ENDPROC
                .ASCII_B 'ENDPROC without PROC'
                .DAT    0
S_LOCAL         .ASCII_B 'LOCAL without PROC'
S_LOOP          .ASCII_B 'LOOP without DO'
S_EXIT          .ASCII_B 'EXIT without DO'
S_NOLOOP
                .ASCII_B 'Missing LOOP'
                .DAT    0
S_ENDIF         .ASCII_B 'Missing ENDIF'
