; BASIC's errors in a program (stage 9, issue #120, doc/BASIC.md,
; "Errors"): TRAP, RESUME, ER, EL, and ERR$, with BASIC 65's names and,
; where BASIC 65 has the error, its number.
;
; err (basic_expr.nasm) calls trap with the error's message. trap sets
; ER, the error's number from ERRS, and EL, the number of the line that
; ran, or -1 in direct mode. While a program runs with a TRAP, and no
; error waits for its RESUME, the error is trapped: the frames that the
; statement made go, unwound as RETURN unwinds them, the frames before
; it stay, and the program goes on at the TRAP's line. Else trap
; returns, and err prints the message, drops the frames, and goes back
; to READY., as with no TRAP. An error while one waits for its RESUME
; is not trapped, so a handler that fails stops the program. The break
; key is no error, and stops the program with a TRAP too.
;
; run keeps the statement that runs, its first token at V_STMT, and V_FP
; at its start at V_SFP, which trap unwinds to. In a FN over lines, a
; statement runs on the processor's stack of the expression that called
; the FN. That expression cannot go on, so trap goes back to the
; statement of the program's own level that called the outermost FN,
; which its FN frame keeps (basic_struct.nasm): RESUME runs that
; statement again, and RESUME NEXT goes on after it. EL is still the
; line in the FN where the error came.
;
; V_RTOK is the statement that RESUME goes back to, and V_RLINE its
; line, while an error waits for its RESUME; else V_RTOK is 0. TRAP ends
; the wait too, so that a handler that goes on with GOTO and a TRAP
; traps the next error again. drop_run, which RUN, CLR, NEW, an edit,
; and an error that is not trapped call, ends the TRAP and the wait.

V_TRAP          .EQU    0xFFFFEFE2      ; the K_LINE token of TRAP's line, or 0 for no TRAP
V_ER            .EQU    0xFFFFEFE3      ; ER, the last error's number, or 0
V_EL            .EQU    0xFFFFEFE4      ; EL, its line's number, or -1
V_RTOK          .EQU    0xFFFFEFE5      ; the statement that RESUME goes back to, or 0,
V_RLINE         .EQU    0xFFFFEFE6      ; and its line
V_STMT          .EQU    0xFFFFEFE7      ; the first token of the statement that runs,
V_SFP           .EQU    0xFFFFEFE8      ; and V_FP at its start
T_ER            .EQU    K_FN*K+0x200000  ; ER's token,
T_EL            .EQU    K_FN*K+0x200001  ; EL's,
T_ERRS          .EQU    K_SFN*K+7       ; and ERR$'s
N_TAG           .EQU    0x4E            ; N, a FN frame's letter

; trap: for the error of the message R7, ER and EL, and the error
; trapped, which goes on at the TRAP's line and does not return; or the
; return, when it is not trapped. Keeps R7. Uses R1-R12.
trap
                MOVE    R1, ERRS
:
                MOVE[M] R2, @R1++
        ?Z      JMP     :+              ; none: ER 0
                AND     R3, R2, 0xFFFF
                CMP     R3, R7
        ?!Z     JMP     :-
                SHR     R2, R2, 16
:
                MOVE    @V_ER, R2
                MOVE[M] R1, @V_CUR
        ?!Z     MOVE    R1, @1[R1]      ; the line's number
        ?Z      NOT     R1, R0          ; -1 in direct mode
                MOVE    @V_EL, R1
                TST     @V_CUR
        ?Z      RET                     ; direct mode
                TST     @V_RTOK
        ?!Z     RET                     ; a handler's error
                MOVE[M] R3, @V_TRAP
        ?Z      RET                     ; no TRAP
                AND     R3, R3, 0xFFFFFF
                CALL    find_line
        ?!Z     RET                     ; no such line
                MOVE    R10, R1         ; the TRAP's line
                MOVE    R9, @V_CUR      ; the line of the statement
                CMP     @V_SBASE, STACK
        ?Z      JMP     tr_unwind
                CALL    himem           ; in a FN over lines: the last FN frame,
                MOVE    R4, @V_FP       ; the outermost
                CLR     R5
:
                CMP     R4, R2
        ?!C     JMP     :+
                SHR     R6, @R4, 24
                CMP     R6, N_TAG
        ?Z      MOVE    R5, R4
                SHR     R6, @R4, 16
                AND     R6, R6, 0xFF
                ADD     R4, R4, R6
                JMP     :-
:
                TST     R5
        ?Z      RET                     ; none, which cannot be
                MOVE    R9, @2[R5]      ; the call's line,
                MOVE    @V_SSB, @3[R5]  ; its strings,
                MOVE    @V_STMT, @6[R5]  ; its statement,
                MOVE    @V_SFP, @7[R5]  ; and its frames
                MOVE    @V_SBASE, STACK
                MOVE    @V_ELIM, STACK-EXPR_ROOM
tr_unwind
                MOVE    R1, @V_SFP
                CMP     @V_FP, R1
        ?C      CALL    unwind          ; the statement's frames
                MOVE    @V_RTOK, @V_STMT
                MOVE    @V_RLINE, R9
                CALL    files_end       ; what the statement left open
                MOVE    SP, STACK
                MOVE    @V_SSP, @V_SSB
                MOVE    @V_CUR, R10
                ADD     R8, R10, 2
                JMP     run

; TRAP N: an error while the program runs goes on at line N; TRAP alone:
; none does. Either ends the wait of an error for its RESUME.
st_trap
                CLR     R3
                SHR     R2, @R8, 24
                CMP     R2, K_LINE
        ?Z      MOVE    R3, @R8
        ?Z      ADD     R8, R8, 2
                CALL    stmt_end
                MOVE    @V_TRAP, R3
                CLR     @V_RTOK
                RET

; RESUME: the statement of the error again; RESUME NEXT: on after it, or
; after the line of an IF; RESUME N: on at line N. Can't resume when no
; error waits for its RESUME.
st_resume
                MOVE[M] R9, @V_RTOK
        ?Z      JMP     err_resume
                SHR     R2, @R8, 24
                CMP     R2, K_LINE
        ?!Z     JMP     :+
                CLR     @V_RTOK
                JMP     st_goto         ; which checks the statement's end
:
                AND     R10, @R8, 0xFFFFFF00
                CMP     R10, K_KW*K+I_NEXT*0x100
        ?Z      MOVE    R8++, R8
                CALL    stmt_end
                CLR     @V_RTOK
                MOVE    @V_CUR, @V_RLINE
                MOVE    R8, R9
                CMP     R10, K_KW*K+I_NEXT*0x100
        ?!Z     JMP     rs_go
                AND     R1, @R8, 0xFFFFFF00
                CMP     R1, K_KW*K+I_IF*0x100
        ?Z      JMP     rs_eol
:
                CALL    tok_skip        ; the statement passed over
                CALL    at_end
        ?!Z     JMP     :-
                JMP     rs_go
rs_eol
                CALL    tok_skip        ; an IF: its whole line
                TST     @R8
        ?!Z     JMP     rs_eol
rs_go
                MOVE    @V_TP, R8
                RET

; ER and EL, which primary's p_fn comes to with R1 the token
p_er
                CMP     R1, T_ER
                MOVE    R1, @V_ER
        ?!Z     MOVE    R1, @V_EL
                MOVE    @FPU_X_W, R1
                RET

; ERR$(N): the message of the error number N, as err prints it, or an
; empty string for 0; any other N is an Illegal quantity
f_err
                CALL    paren_word
                CLR     R2
                TST     R1
        ?Z      JMP     s_push          ; the empty string, at 0
                MOVE    R4, R1
                MOVE    R2, ERRS
:
                MOVE[M] R1, @R2++
        ?Z      JMP     err_quant
                SHR     R3, R1, 16
                CMP     R3, R4
        ?!Z     JMP     :-
                AND     R1, R1, 0xFFFF  ; the message, packed,
                SHL     R5, R1, 2       ; through the byte window
                ADD     R5, R5, TEXT_B
                MOVE    R4, V_SCR
:
                MOVE[M] R1, @R5++
        ?Z      JMP     :+
                MOVE    @R4++, R1
                JMP     :-
:
                SUB     R2, R4, V_SCR
                MOVE    R1, V_SCR
                JMP     s_text

err_resume
                MOVE    R1, S_RESUME
                JMP     err

; The errors' numbers, a word each: the message in bits 15..0, and its
; number in bits 31..16, BASIC 65's for the errors that it has, and from
; 100 on for those that it has not. ERR$ takes the first of a number.
ERRS
                .DAT    S_NEXT+65536*10, S_SYNTAX+65536*11, S_UNKNOWN+65536*11
                .DAT    S_RETNG+65536*12, S_DATA+65536*13, S_QUANT+65536*14
                .DAT    S_OVERFLOW+65536*15, S_MEMORY+65536*16, S_LINE+65536*17
                .DAT    S_SUBSCR+65536*18, S_REDIM+65536*19, S_DIVZERO+65536*20
                .DAT    S_TYPE+65536*22, S_STRLONG+65536*23, S_COMPLEX+65536*25
                .DAT    S_CONT+65536*26, S_FN+65536*27, S_RESUME+65536*31
                .DAT    S_NOLOOP+65536*32, S_LOOP+65536*33
                .DAT    S_UNDEF+65536*100, S_ARRAY+65536*101, S_PROC+65536*102
                .DAT    S_FNRET+65536*103, S_NOEQ+65536*104, S_ENDPROC+65536*105
                .DAT    S_LOCAL+65536*106, S_EXIT+65536*107, S_ENDIF+65536*108
                .DAT    S_LONG+65536*109, S_NONUM+65536*110, S_CHAR+65536*111
                .DAT    0

S_RESUME
                .ASCII_B "Can't resume"
                .DAT    0
