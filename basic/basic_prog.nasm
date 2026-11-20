; BASIC's programs (stage 3, issue #114, doc/BASIC.md, "Programs"): the
; lines, their entry, LIST, and the statements that run them, RUN, GOTO,
; GOSUB and RETURN, IF with THEN and ELSE, FOR and NEXT, END, STOP, CONT,
; NEW, CLR, and REM; and the keys: BASIC's line input, the break key,
; the keys typed ahead, GET, and INPUT.
;
; A line is its length in words, its number, its tokens, as tokenize
; makes them (basic_expr.nasm), and the 0 that ends them, so the next
; line starts right after that 0. The lines go from PROGRAM to V_PEND, in
; the order of their numbers, and the variables follow them, from V_PEND
; to V_VEND, so that a variable's token holds its offset from V_PEND,
; which an edit moves with the variables. The arrays' data follows the
; variables, from V_VEND to V_AEND, so that an array's entry holds the
; offset of its data from V_VEND, which a new variable moves with the
; data. An empty program writes no word at PROGRAM. A line number after GOTO, GOSUB, RUN, THEN, and ELSE
; is a K_LINE token, with the address of its line in the word after it,
; 0 until the first jump finds the line. An edit clears those words, and
; drops the frames and CONT, but keeps the variables.
;
; V_CUR is the line that runs, 0 in direct mode, where the statements are
; those of V_TOK. At the end of a line, run goes on with the next, and at
; the end of the program it goes back to main. A statement that jumps
; sets V_CUR and V_TP, where run_next goes on.
;
; The frames of FOR and GOSUB are in a region of FRAMES words below the
; top of BASIC's memory, himem, and grow down from it, V_FP the last.
; The top of the arrays is FRAMES words below himem. A GOSUB frame is
; GOSUB_TAG, the token after its statement, and its line. A FOR frame is
; FOR_TAG with the FPU's command that compares the variable with the
; limit, the variable's offset, the limit, the step, the token after the
; FOR statement, the body's start, and its line.
;
; The break key is CTRL-C, a byte of the console. run polls the console
; every POLL_EVERY statements, and LIST at each line, with con_key and no
; wait, and a byte that is not CTRL-C goes into a ring of RING keys typed
; ahead, or is dropped when the ring is full. getline, GET, and INPUT read
; the ring first. getline reads the line of BASIC, as con_getline reads
; one, on the entries con_key, scr_back, and fs_complete (doc/BASIC.md,
; "What the stages need of the monitor").

V_PEND          .EQU    0xFFFFED58      ; the end of the program, where the variables start
V_CUR           .EQU    0xFFFFED59      ; the line that runs, or 0 in direct mode
V_FP            .EQU    0xFFFFED5A      ; the last frame
V_HIMEM         .EQU    0xFFFFED5B      ; the top of BASIC's memory, or 0 for the RAM's
V_CONT          .EQU    0xFFFFED5C      ; where CONT goes on, the token,
V_CONTL         .EQU    0xFFFFED5D      ; and its line, 0 when it cannot
V_STORE         .EQU    0xFFFFED5E      ; not 0 while a line to store is tokenized
V_LNUM          .EQU    0xFFFFED5F      ; the number of the line entered
V_LPREV         .EQU    0xFFFFED60      ; for LIST: the token before
V_RHEAD         .EQU    0xFFFFED61      ; the ring of the keys typed ahead: where the next goes,
V_RTAIL         .EQU    0xFFFFED62      ; and the next to read, the same when it is empty
V_POLL          .EQU    0xFFFFED63      ; the statements until the next poll
V_REDO          .EQU    0xFFFFED64      ; the token after INPUT while INPUT reads, else 0
V_RING          .EQU    0xFFFFED70      ; the ring, RING words
V_AEND          .EQU    0xFFFFED65      ; the end of the arrays' data
V_ITOK          .EQU    0xFFFFED91      ; the tokens of INPUT's line, TOK_MAX words, after a 0
V_LINE          .EQU    0xFFFFEE40      ; the line, EDIT_MAX words and a 0, or LINE_MAX, one over for LOAD, and a 0
EDIT_MAX        .EQU    254             ; the characters of the screen editor's line, as LOAD's of a program
LINE_MAX        .EQU    76              ; the characters of a line of a .bin file that LOAD takes

FRAMES          .EQU    0x200           ; the words of the frames
LINE_LAST       .EQU    65535           ; the largest line number
GOSUB_TAG       .EQU    0x47000000      ; G
GOSUB_WORDS     .EQU    3
FOR_TAG         .EQU    0x46000000      ; F, with the FPU's command in bits 15..0
FOR_WORDS       .EQU    8
CMD_LE          .EQU    0x031C          ; CMP 3, Y <= X
CMD_GE          .EQU    0x061C          ; CMP 6, Y >= X
FPU_ADD         .EQU    0x10
MPU_A           .EQU    0xFFFFFF20      ; the math unit: A,
MPU_B           .EQU    0xFFFFFF21      ; B,
MPU_LO          .EQU    0xFFFFFF24      ; and A times B, unsigned, bits 31..0,
MPU_HI          .EQU    0xFFFFFF25      ; and 63..32
RING            .EQU    32              ; the keys typed ahead that the ring holds
POLL_EVERY      .EQU    64              ; the statements from one poll to the next

; get_lineno: the line number in decimal at R5, R3, and R5 after its
; digits; above LINE_LAST is a Syntax error. Uses R1 and R2.
get_lineno
                CLR     R3
:
                SUB     R1, @R5, 0x30
                CMP     R1, 10
        ?!C     RET
                DBL     R2, R3          ; 10 R3 + the digit
                SHL     R3, R3, 3
                ADD     R3, R3, R2
                ADD     R3, R3, R1
                CMP     R3, LINE_LAST+1
        ?!C     JMP     err_syntax
                MOVE    R5++, R5
                JMP     :-

; enter_line: the line at R5 that starts with a number, stored, or
; replacing the line of that number, or deleting it when nothing
; follows the number. Then main_line, with no READY. enter_store: the
; same, and back to the caller, for LOAD of a program's text. Uses R1-R12.
enter_line
                PUSH    main_line       ; where enter_store returns
enter_store
                CALL    get_lineno
                MOVE    @V_LNUM, R3
                ONE     @V_STORE        ; each name gets its variable
                CALL    tokenize_at
                CLR     @V_STORE
                CLR     @V_ETOK
                ADD     R9, R8, 3
                SUB     R9, R9, V_TOK   ; the words of the new line
                CALL    drop_run
                MOVE    R3, @V_LNUM
                CALL    find_line
        ?!Z     JMP     :+
                PUSH    R1              ; the old line goes
                SUB     R2, R0, @R1
                ADD     R1, R1, @R1
                CALL    shift
                POP     R1
:
                CMP     R9, 3
        ?Z      JMP     clear_cache     ; no tokens: the line is deleted
                CALL    mem_top
                ADD     R3, @V_AEND, R9
                CMP     R2, R3
        ?C      JMP     err_memory
                PUSH    R1
                MOVE    R2, R9
                CALL    shift
                POP     R1
                MOVE    @R1++, R9
                MOVE    @R1++, @V_LNUM
                MOVE    R2, V_TOK
                SUB     R4, R9, 2
:
                MOVE    @R1++, @R2++
                SUB[M]  R4, R4, 1
        ?!Z     JMP     :-
; clear_cache: the addresses of the lines of the K_LINE tokens cleared,
; after an edit. Uses R1-R3 and R8.
clear_cache
                MOVE    R1, PROGRAM
cc_line
                CMP     R1, @V_PEND
        ?!C     RET
                ADD     R8, R1, 2
:
                MOVE[M] R2, @R8
        ?Z      JMP     :+
                SHR     R2, R2, 24
                CMP     R2, K_LINE
        ?Z      MOVE    @1[R8], R0
                CALL    tok_skip
                JMP     :-
:
                ADD     R1, R1, @R1
                JMP     cc_line

; find_line: R1 the line of number R3, and Z; or the first line after
; it, or V_PEND, and not Z
find_line
                MOVE    R1, PROGRAM
:
                CMP     R1, @V_PEND
        ?!C     JMP     :+
                CMP     @1[R1], R3
        ?!C     RET
                ADD     R1, R1, @R1
                JMP     :-
:
                CMP     R0, 1           ; not Z
                RET

; shift: the program from R1 on, the variables, and the arrays, R2 words
; up, or down when R2 is negative. Uses R1-R5.
shift
                ADD     @V_PEND, @V_PEND, R2
                ADD     @V_VEND, @V_VEND, R2
                MOVE    R3, @V_AEND
                ADD     @V_AEND, R3, R2
                ADD     R2, R1, R2
; mem_move: the words from R1 up to R3 to R2 on; the two may overlap.
; Uses R1-R5.
mem_move
                SUB     R4, R3, R1
                CMP     R2, R1
        ?C      JMP     mm_down
                ADD     R2, R2, R4      ; up: from the last
:
                TST     R4
        ?Z      RET
                MOVE    @--R2, @--R3
                SUB     R4, R4, 1
                JMP     :-
mm_down
                TST     R4
        ?Z      RET
                MOVE    @R2++, @R1++
                SUB     R4, R4, 1
                JMP     mm_down

; tok_skip: R8 after the token at R8 and the words that its kind has.
; Uses R2 and R3.
tok_skip
                MOVE    R2, @R8++
                SHR     R3, R2, 24
                CMP     R3, K_STR
        ?!Z     CMP     R3, K_REM
        ?Z      JMP     :+
                ADD     R8, R8, @TOK_EXTRA[R3]
                RET
:
                AND     R2, R2, 0xFFFFFF
                ADD     R8, R8, R2
                MOVE    R8++, R8        ; and its 0
                RET
TOK_EXTRA
                .DAT    0, 0, 1, 1, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0

; himem: R2 the top of BASIC's memory, HIMEM, or that of the RAM, less
; the variables and the stack's room. mem_top: R2 the top of the
; arrays, below the frames.
himem
                MOVE[M] R2, @V_HIMEM
        ?!Z     RET
                MOVE[M] R2, @RAM_WORDS
        ?Z      MOVE    R2, RAM_MEGA65
                SUB     R2, R2, MON_VARS+BASIC_WORDS+STACK_ROOM
                RET
mem_top
                CALL    himem
                SUB     R2, R2, FRAMES
                RET

; drop_run: no frames, and no CONT. Uses R2.
drop_run
                CALL    himem
                MOVE    @V_FP, R2
                CLR     @V_CONTL
                RET

; new_prog: no program, no variables, and no arrays. Uses R2.
new_prog
                MOVE    @V_PEND, PROGRAM
                MOVE    @V_VEND, PROGRAM
                MOVE    @V_AEND, PROGRAM
                JMP     drop_run

; clr_vars: every variable not assigned, every array not made, and no
; frames and no CONT. A length of 0 or above 16 cuts the table there, as
; var_find does. Uses R1 and R2.
clr_vars
                MOVE    R1, @V_PEND
:
                CMP     R1, @V_VEND
        ?!C     JMP     :++
                AND[M]  R2, @2[R1], NOT_ARRAY
        ?Z      JMP     :+
                CMP     R2, 17
        ?!C     JMP     :+
                MOVE    @1[R1], 0xFFFFFFFF
                ADD     R2, R2, 3
                SHR     R2, R2, 2
                ADD     R1, R1, R2
                ADD     R1, R1, 3
                JMP     :-
:
                MOVE    @V_VEND, R1
:
                MOVE    @V_AEND, @V_VEND
                JMP     drop_run

; frame_new: R1 the new frame of R1 words, below the last. Uses R2.
frame_new
                SUB     R1, @V_FP, R1
                CALL    mem_top
                CMP     R1, R2
        ?C      JMP     err_memory
                MOVE    @V_FP, R1
                RET

; find_for: R1 the FOR frame of the variable of offset R1, or of any
; variable for R1 = -1, among those after the last GOSUB frame, and not
; Z; or Z when there is none. Uses R2-R4.
find_for
                MOVE    R3, R1
                CALL    himem
                MOVE    R1, @V_FP
:
                CMP     R1, R2
        ?!C     JMP     :+
                AND     R4, @R1, 0xFF000000
                CMP     R4, FOR_TAG
        ?!Z     JMP     :+
                CMP     R3, 0xFFFFFFFF
        ?!Z     CMP     R3, @1[R1]
        ?Z      JMP     :++
                ADD     R1, R1, FOR_WORDS
                JMP     :-
:
                CMP     R0, R0          ; Z
                RET
:
                CMP     R0, 1           ; not Z
                RET

; The statements. Each returns to run_next, with V_TP the token where it
; goes on.

; RUN [N]: CLR, and the program from its first line, or from line N
st_run
                SHR     R2, @R8, 24
                CMP     R2, K_STR
        ?Z      JMP     run_file
                CALL    clr_vars
                SHR     R2, @R8, 24
                CMP     R2, K_LINE
        ?Z      JMP     st_goto
                CALL    stmt_end
run_prog
                MOVE    R1, PROGRAM
                CMP     R1, @V_PEND
        ?Z      JMP     main            ; no program
                JMP     go_to

; RUN "NAME" [, "IP"]: LOAD "NAME" [, "IP"] with V_RUNF set, after
; which load_fin runs the program, or calls a .bin file at 0x8000
run_file
                ADD     R1, R8, 1       ; the name
                CALL    tok_skip
                CLR     R4              ; no server
                CMP     @R8, T_COMMA
        ?!Z     JMP     :+
                MOVE    R8++, R8
                SHR     R3, @R8, 24
                CMP     R3, K_STR
        ?!Z     JMP     err_syntax
                ADD     R4, R8, 1       ; the server
                CALL    tok_skip
:
                PUSH    R1
                CALL    stmt_end
                POP     R1
                MOVE    R2, R4
                ONE     @V_RUNF
                JMP     bas_lrun

; GOTO N: the line N
st_goto
                SHR     R2, @R8, 24
                CMP     R2, K_LINE
        ?!Z     JMP     err_syntax
                ADD     R8, R8, 2
                CALL    stmt_end
                SUB     R8, R8, 2
; go_line: the line of the K_LINE token at R8, found once and kept in
; the word after it
go_line
                MOVE[M] R1, @1[R8]
        ?!Z     JMP     go_to
                AND     R3, @R8, 0xFFFFFF
                CALL    find_line
        ?!Z     JMP     err_line
                MOVE    @1[R8], R1
; go_to: the statements of the line R1 next
go_to
                MOVE    @V_CUR, R1
                ADD     @V_TP, R1, 2
                RET

; GOSUB N: a frame with the token after the statement, and the line N
st_gosub
                SHR     R2, @R8, 24
                CMP     R2, K_LINE
        ?!Z     JMP     err_syntax
                ADD     R8, R8, 2
                CALL    stmt_end
                MOVE    R1, GOSUB_WORDS
                CALL    frame_new
                MOVE    @R1, GOSUB_TAG
                MOVE    @1[R1], R8
                MOVE    @2[R1], @V_CUR
                SUB     R8, R8, 2
                JMP     go_line

; RETURN: back after the last GOSUB, whose frame goes, with the FOR
; frames after it
st_return
                CALL    himem
                MOVE    R1, @V_FP
:
                CMP     R1, R2
        ?!C     JMP     err_return
                AND     R3, @R1, 0xFF000000
                CMP     R3, GOSUB_TAG
        ?Z      JMP     :+
                ADD     R1, R1, FOR_WORDS
                JMP     :-
:
                MOVE    @V_TP, @1[R1]
                MOVE    @V_CUR, @2[R1]
                ADD     @V_FP, R1, GOSUB_WORDS
                RET

; IF X THEN N or statements, or IF X GOTO N, each with ELSE and N or
; statements after it. A false X goes on after the ELSE of this IF,
; counting those of the IFs after it, or at the end of the line.
st_if
                CALL    eval_num
                MOVE    R1, @FPU_STATUS
                MOVE    @FPU_CMD, FPU_DROP
                MOVE    R2, @R8
                CMP     R2, T_THEN
        ?Z      MOVE    R8++, R8
        ?Z      JMP     :+
                AND     R2, R2, 0xFFFFFF00
                CMP     R2, K_KW*K+I_GOTO*0x100
        ?!Z     JMP     err_syntax
:
                AND[M]  R0, R1, FPU_ZERO
        ?!Z     JMP     if_false
; if_then: after THEN or ELSE, a line number, or statements
if_then
                SHR     R2, @R8, 24
                CMP     R2, K_LINE
        ?Z      JMP     st_goto
                MOVE    @V_TP, R8
                RET
if_false
                CLR     R9              ; the IFs after this one
:
                MOVE[M] R1, @R8
        ?Z      JMP     :++             ; the end of the line
                CMP     R1, T_ELSE
        ?!Z     JMP     :+
                TST     R9
        ?Z      MOVE    R8++, R8
        ?Z      JMP     if_then
                SUB     R9, R9, 1
:
                AND     R2, R1, 0xFFFFFF00
                CMP     R2, K_KW*K+I_IF*0x100
        ?Z      ADD     R9, R9, 1
                CALL    tok_skip
                JMP     :--
:
                MOVE    @V_TP, R8
                RET

; FOR V = A TO B [STEP C]: V = A, and a frame, after the FOR frame of V
; and those after it are dropped
st_for
                SHR     R2, @R8, 24
                CMP     R2, K_VAR
        ?!Z     JMP     err_syntax
                AND     R10, @R8++, 0xFFFFFF  ; the variable
                CMP     @R8++, T_EQ
        ?!Z     JMP     err_syntax
                CALL    eval_num
                ADD     R1, R10, @V_PEND
                MOVE    @R1, @FPU_X_LO
                MOVE    @1[R1], @FPU_X_HI
                MOVE    @FPU_CMD, FPU_DROP
                CMP     @R8++, T_TO
        ?!Z     JMP     err_syntax
                CALL    eval_num        ; the limit
                CMP     @R8, T_STEP
        ?!Z     JMP     :+
                MOVE    R8++, R8
                CALL    eval_num        ; the step
                JMP     :++
:
                MOVE    @FPU_X_W, 1
:
                CALL    stmt_end
                MOVE    R1, R10
                CALL    find_for
        ?!Z     ADD     @V_FP, R1, FOR_WORDS
                MOVE    R1, FOR_WORDS
                CALL    frame_new
                MOVE    R2, FOR_TAG+CMD_LE
                AND[M]  R0, @FPU_STATUS, FPU_NEGATIVE
        ?!Z     MOVE    R2, FOR_TAG+CMD_GE
                MOVE    @R1, R2
                MOVE    @1[R1], R10
                MOVE    @4[R1], @FPU_X_LO
                MOVE    @5[R1], @FPU_X_HI
                MOVE    @FPU_CMD, FPU_DROP
                MOVE    @2[R1], @FPU_X_LO
                MOVE    @3[R1], @FPU_X_HI
                MOVE    @FPU_CMD, FPU_DROP
                MOVE    @6[R1], R8
                MOVE    @7[R1], @V_CUR
                RET

; NEXT [V [, W ...]]: the step added to the variable of the latest loop,
; or of V's, and the body again while the variable has not passed the
; limit; else the frame goes, and NEXT goes on with W
st_next
                NOT     R1, R0          ; any loop
                SHR     R2, @R8, 24
                CMP     R2, K_VAR
        ?Z      AND     R1, @R8++, 0xFFFFFF
                CALL    find_for
        ?Z      JMP     err_next
                MOVE    R9, R1          ; the frame
                ADD     R10, @1[R9], @V_PEND  ; the variable
                MOVE    @FPU_X_LO, @R10
                MOVE    @FPU_X_HI, @1[R10]
                MOVE    @FPU_X_LO, @4[R9]
                MOVE    @FPU_X_HI, @5[R9]
                MOVE    @FPU_CMD, FPU_ADD
                CALL    check_flags
                MOVE    @R10, @FPU_X_LO
                MOVE    @1[R10], @FPU_X_HI
                MOVE    @FPU_X_LO, @2[R9]
                MOVE    @FPU_X_HI, @3[R9]
                AND     @FPU_CMD, @R9, 0xFFFF
                AND[M]  R0, @FPU_STATUS, FPU_ZERO
                MOVE    @FPU_CMD, FPU_DROP
        ?Z      JMP     :+              ; -1: again
                ADD     @V_FP, R9, FOR_WORDS
                CMP     @R8, T_COMMA
        ?!Z     JMP     stmt_end
                MOVE    R8++, R8
                SHR     R2, @R8, 24
                CMP     R2, K_VAR
        ?!Z     JMP     err_syntax
                JMP     st_next
:
                MOVE    @V_FP, R9
                MOVE    @V_TP, @6[R9]
                MOVE    @V_CUR, @7[R9]
                RET

; END: the end, which CONT goes on after; nothing in direct mode
st_end
                TST     @V_CUR
        ?Z      RET
                MOVE    @V_CONT, @V_TP
                MOVE    @V_CONTL, @V_CUR
                JMP     main

; STOP: Break in N, which CONT goes on after; nothing in direct mode
st_stop
                TST     @V_CUR
        ?Z      RET
                MOVE    @V_CONT, @V_TP
                MOVE    @V_CONTL, @V_CUR
                MOVE    R1, S_BREAK
                CALL    put_msg
                JMP     main

; CONT: on after STOP or END, unless the program was edited or an error
; came since
st_cont
                MOVE[M] R1, @V_CONTL
        ?Z      JMP     err_cont
                MOVE    @V_CUR, R1
                MOVE    @V_TP, @V_CONT
                CLR     @V_CONTL        ; until the next STOP or END
                RET

; NEW: no program and no variables
st_new
                CALL    new_prog
                JMP     main

; CLR: the variables not assigned
st_clr          JMP     clr_vars

; REM: the rest of the line, a K_REM token, passed over
st_rem
                CALL    tok_skip
                MOVE    @V_TP, R8
                RET

; LIST [N] [- [M]]: the lines from N to M, the keywords in upper case, a
; blank between two tokens but before ), a comma, ;, and :, and after (
; and a function's name before its (, and after a sign that is no
; operator on two numbers
st_list
                CALL    get_range
                CALL    stmt_end
; list_from: the lines from R10 to R11. Uses R1-R12.
list_from
                MOVE    R3, R10
                CALL    find_line
                MOVE    R9, R1
                JMP     list_line

; get_range: [N] [- [M]] at R8, as LIST and DELETE take it: R10 = N, or
; 0, and R11 = M, or N when there is no -, or LINE_LAST, and R8 after it.
; Uses R1 and R2.
get_range
                CLR     R10             ; from
                MOVE    R11, LINE_LAST  ; to
                MOVE    R1, @R8
                SHR     R2, R1, 24
                CMP     R2, K_SMALL
        ?!Z     JMP     :+
                AND     R10, R1, 0xFFFFFF
                MOVE    R11, R10
                MOVE    R8++, R8
                MOVE    R1, @R8
:
                CMP     R1, T_MINUS
        ?!Z     JMP     :+
                MOVE    R11, LINE_LAST
                MOVE    R8++, R8
                MOVE    R1, @R8
                SHR     R2, R1, 24
                CMP     R2, K_SMALL
        ?Z      AND     R11, R1, 0xFFFFFF
        ?Z      MOVE    R8++, R8
:
                RET
list_line
                CMP     R9, @V_PEND
        ?!C     RET
                CMP     R11, @1[R9]
        ?C      RET
                MOVE    R8, @V_TP       ; the break key goes on after LIST
                CALL    poll
                MOVE    R1, @1[R9]
                CALL    putdec
                CALL    put_blank
                ADD     R8, R9, 2
                CLR     R12             ; no blank before the first token
                CLR     @V_LPREV
:
                TST     @R8
        ?Z      JMP     :+
                CALL    list_tok
                JMP     :-
:
                CALL    list_eol
                ADD     R9, R9, @R9
                JMP     list_line

; list_eol: CR LF, or LF alone in a file of SAVE. Uses R1-R4.
list_eol
                MOVE    R1, 0x0A
                TST     @V_SPOS
        ?!Z     JMP     putc            ; which returns to the caller
                JMP     _io_crlf

; list_tok: the token at R8, and R8 after it. R12 is 0 for no blank
; before it, 2 for none before a (, and 1 else. Uses R1-R7 and R10.
list_tok
                MOVE    R6, @R8++
                SHR     R5, R6, 24
                TST     R12
        ?Z      JMP     lt_go
                CMP     R6, T_LPAR
        ?!Z     JMP     :+
                CMP     R12, 2
        ?Z      JMP     lt_go
:
                CMP     R6, T_RPAR
        ?!Z     CMP     R6, T_COMMA
        ?!Z     CMP     R6, T_SEMI
        ?!Z     CMP     R6, T_COLON
        ?!Z     CMP     R5, K_REM
        ?!Z     CALL    put_blank
lt_go
                ONE     R12
                CMP     R6, T_LPAR
        ?Z      CLR     R12
                CMP     R5, K_FN
        ?!Z     CMP     R5, K_PRT
        ?!Z     CMP     R5, K_ARR
        ?Z      MOVE    R12, 2
                CMP     R6, T_MINUS
        ?!Z     CMP     R6, T_PLUS
        ?!Z     JMP     :+
                MOVE    R1, @V_LPREV    ; a sign, unless after an operand
                CMP     R1, T_RPAR
        ?!Z     CMP     R1, T_HIMEM
        ?Z      JMP     :+
                SHR     R1, R1, 24
                SHR     R1, OPERANDS, R1
                AND[M]  R0, R1, 1
        ?Z      CLR     R12
:
                MOVE    @V_LPREV, R6
                JMP     @LIST_KINDS[R5]
; The kinds of the tokens that end an operand, a bit each
OPERANDS        .EQU    2+4+8+16+32+64+0x4000
LIST_KINDS
                .DAT    0, lt_dec, lt_dec, lt_hex, lt_num, lt_str, lt_var, lt_kw, lt_punct
                .DAT    lt_kw, lt_kw, lt_kwi, lt_kw, lt_kw, lt_dec, lt_rem, lt_var

; A whole number: K_SMALL's and K_LINE's in the token, which K_LINE's
; line follows, and K_WORD's in the word after it
lt_dec
                AND     R1, R6, 0xFFFFFF
                CMP     R5, K_WORD
        ?Z      MOVE    R1, @R8
                CMP     R5, K_SMALL
        ?!Z     MOVE    R8++, R8
                JMP     putdec

; A number in hex, with 0x and its digits from the first that is not 0
lt_hex
                MOVE    R1, 0x30
                CALL    putc
                MOVE    R1, 0x78        ; x
                CALL    putc
                MOVE    R6, @R8++
                MOVE    R5, 8
:
                CMP     R5, 1
        ?Z      JMP     :+
                SHR[M]  R1, R6, 28
        ?!Z     JMP     :+
                SHL     R6, R6, 4
                SUB     R5, R5, 1
                JMP     :-
:
                ROL     R6, R6, 4
                AND     R1, R6, 0xF
                ADD     R1, R1, 0x30
                CMP     R1, 0x3A
        ?!C     ADD     R1, R1, 7       ; A to F
                CALL    putc
                SUB[M]  R5, R5, 1
        ?!Z     JMP     :-
                RET

; A number with a fraction or an exponent: its digits as PRINT writes
; them, from those that the token keeps, and the exponent in the token
lt_num
                PUSH    R9
                PUSH    R11
                PUSH    R12
                SHL     R7, R6, 16      ; the exponent, with its sign
                C<0[M]  R0, R7, 1
                C>0     R7, R7, 16
                MOVE    R10, @2[R8]
                MOVE    R9, @3[R8]
                ADD     R8, R8, 4
                OR[M]   R0, R9, R10
        ?Z      JMP     :+              ; no digits: 0
                CALL    put_bcd
                JMP     :++
:
                MOVE    R1, 0x30
                CALL    putc
:
                POP     R12
                POP     R11
                POP     R9
                RET

; A string, in quotes, and the text of REM, as it is
lt_str
                MOVE    R1, 0x22
                CALL    putc
                CALL    lt_rem
                MOVE    R1, 0x22
                JMP     putc
lt_rem
                MOVE    R7, R8
                AND     R2, R6, 0xFFFFFF
                ADD     R8, R8, R2
                MOVE    R8++, R8
:
                MOVE[M] R1, @R7++
        ?Z      RET
                CALL    putc
                JMP     :-

; A variable's name, from its entry
lt_var
                AND     R1, R6, 0xFFFFFF
                ADD     R5, R1, @V_PEND
                AND     R6, @2[R5], NOT_ARRAY  ; its length
                ADD     R5, R5, 3
                SHL     R5, R5, 2
                ADD     R5, R5, TEXT_B
:
                SUB[M]  R6, R6, 1
        ?N      RET
                MOVE    R1, @R5++
                CALL    putc
                JMP     :-

; ( ) , ; and :
lt_punct
                AND     R1, R6, 0xFF
                JMP     putc

; A keyword: a statement's by its index, and the others' by their place
; in KW_TOK; an operator that is no keyword by SYMS
lt_kwi
                SHR     R1, R6, 8
                AND     R1, R1, 0xFF
                JMP     put_kw
lt_kw
                MOVE    R1, KW_TOK
:
                CMP     R1, KW_TOK_END
        ?Z      JMP     lt_sym
                CMP     @R1++, R6
        ?!Z     JMP     :-
                SUB     R1, R1, KW_TOK+1-N_STMT
; put_kw: the keyword of index R1. Uses R1-R5.
put_kw
                CALL    kw_addr
                MOVE    R5, R3
:
                MOVE    R1, @R5++
                CMP     R1, 0x41        ; A
        ?C      RET
                CALL    putc
                JMP     :-
lt_sym
                MOVE    R1, SYMS
:
                CMP     @R1++, R6
                MOVE    R5, @R1++
        ?!Z     JMP     :-
:
                AND     R1, R5, 0xFF
                CALL    putc
                SHR[M]  R5, R5, 8
        ?!Z     JMP     :-
                RET
; The operators that are no keywords, each with its characters
SYMS
                .DAT    T_PLUS, 0x2B, T_MINUS, 0x2D, T_MUL, 0x2A, T_DIV, 0x2F, T_EQ, 0x3D
                .DAT    T_NE, 0x3E3C, T_LT, 0x3C, T_GT, 0x3E, T_LE, 0x3D3C, T_GE, 0x3D3E
                .DAT    T_SHL, 0x3C3C, T_SHR, 0x3E3E

; GET V: V the code of the next key typed ahead, or 0 when there is none,
; with no wait
st_get
                CALL    lvalue
                PUSH    R1
                CALL    stmt_end
                CLR     R1
                CALL    key
                TST     R1
        ?N      CLR     R1
                MOVE    @FPU_X_W, R1
                POP     R1
; store_var: the FPU's X to the variable at R1, and off the stack
store_var
                MOVE    @R1, @FPU_X_LO
                MOVE    @1[R1], @FPU_X_HI
                MOVE    @FPU_CMD, FPU_DROP
                RET

; INPUT ["PROMPT";] V [, W ...]: the prompt and ? , and a line of
; numbers, each with a sign or not, with commas between them, one for
; each variable. A line that has no such number where one goes is Redo
; from start, and INPUT starts again, as it does after an error of the
; tokenizer, which err sends here while V_REDO is not 0. Too few numbers
; ask for the rest with ?? , and too many are Extra ignored. CTRL-C is a
; break, after which CONT runs INPUT again.
st_input
                MOVE    @V_REDO, R8
                MOVE    R1, @R8
                SHR     R2, R1, 24
                CMP     R2, K_STR
        ?!Z     JMP     :+
                AND     R2, R1, 0xFFFFFF
                ADD     R3, R8, R2
                CMP     @2[R3], T_SEMI
        ?!Z     JMP     in_syntax
                ADD     R1, R8, 1
                ADD     R8, R3, 3
                CALL    _io_puts        ; the prompt
:
                MOVE    R11, R8         ; the variables
:
                SHR     R2, @R8, 24
                CMP     R2, K_ARR
        ?Z      JMP     in_arr
                CMP     R2, K_VAR
        ?!Z     JMP     in_syntax
                MOVE    R8++, R8
in_vnext
                CMP     @R8, T_COMMA
        ?Z      MOVE    R8++, R8
        ?Z      JMP     :-
                CALL    at_end
        ?!Z     JMP     in_syntax
                MOVE    @V_TP, R8
                MOVE    R1, S_QUEST
in_ask
                CALL    puts_b
                ONE     R1              ; CTRL-C is a break
                CALL    getline
                PUSH    R11
                MOVE    R5, V_LINE
                MOVE    R8, V_ITOK
                MOVE    @-1[R8], R0     ; no token before the first
                MOVE    @V_TLIM, V_ITOK+TOK_MAX-6
                CALL    tokenize_to
                POP     R11
                MOVE    R9, V_ITOK
in_var
                TST     @R9
        ?Z      MOVE    R1, S_QQ        ; too few
        ?Z      JMP     in_ask
                CLR     R6              ; the sign
                CMP     @R9, T_PLUS
        ?Z      MOVE    R9++, R9
                CMP     @R9, T_MINUS
        ?Z      ONE     R6
        ?Z      MOVE    R9++, R9
                SHR     R2, @R9, 24
                SUB     R2, R2, K_SMALL
                CMP     R2, K_NUM-K_SMALL+1
        ?!C     JMP     in_redo         ; no number
                MOVE    R8, R9
                CALL    primary
                MOVE    R9, R8
                TST     R6
        ?!Z     MOVE    @FPU_CMD, FPU_NEG
                PUSH    R9
                MOVE    R8, R11
                CALL    lvalue
                MOVE    R11, R8
                CALL    store_var
                POP     R9
                MOVE    R1, @R9
                CMP     @R11, T_COMMA
        ?!Z     JMP     :+
                MOVE    R11++, R11      ; more variables
                CMP     R1, T_COMMA
        ?Z      MOVE    R9++, R9
        ?Z      JMP     in_var
                TST     R1
        ?Z      JMP     in_var
                JMP     in_redo
:
                TST     R1              ; the last variable
        ?!Z     CMP     R1, T_COMMA
        ?!Z     JMP     in_redo
                CLR     @V_REDO
                TST     R1
        ?Z      RET
                MOVE    R1, S_EXTRA
                JMP     puts_b_crlf     ; which returns to run_next
in_syntax
                CLR     @V_REDO
                JMP     err_syntax
; in_arr: an array's element, passed over to its ) at its depth
in_arr
                MOVE    R8++, R8
                CMP     @R8, T_LPAR
        ?!Z     JMP     in_syntax
                CLR     R4              ; the depth
:
                MOVE[M] R1, @R8
        ?Z      JMP     in_syntax
                CMP     R1, T_LPAR
        ?Z      ADD     R4, R4, 1
                CMP     R1, T_RPAR
        ?Z      SUB     R4, R4, 1
                CALL    tok_skip
                TST     R4
        ?!Z     JMP     :-
                JMP     in_vnext
; in_redo: Redo from start, and INPUT again
in_redo
                MOVE    @FPU_CMD, FPU_CLEAR
                MOVE    R1, S_REDO
                CALL    puts_b_crlf
                MOVE    SP, STACK
                MOVE    R8, @V_REDO
                PUSH    run_next
                JMP     st_input
; in_break: CTRL-C in INPUT's line, a break at INPUT
in_break
                SUB     R8, @V_REDO, 1
                CLR     @V_REDO

; brk: the break key, before the statement at R8, which CONT goes on
; with, while a program runs: Break, with the line's number, and main
brk
                MOVE[M] R1, @V_CUR
        ?!Z     MOVE    @V_CONT, R8
                MOVE    @V_CONTL, R1
                MOVE    R1, S_BREAK
                CALL    put_msg
                JMP     main

; poll: a byte of the console, if one waits: CTRL-C is the break key, at
; the statement at R8, and another byte goes into the ring of the keys
; typed ahead, or is dropped when the ring is full. Uses R1-R6.
poll
                MOVE    @V_POLL, POLL_EVERY
                CLR     R1
                CALL    CON_KEY
                TST     R1
        ?N      RET                     ; none
                CMP     R1, 3           ; CTRL-C
        ?Z      JMP     brk
; ring_put: R1 into the ring, or dropped when it is full. Uses R2 and R3.
ring_put
                MOVE    R3, @V_RHEAD
                ADD     R2, R3, 1
                AND     R2, R2, RING-1
                CMP     R2, @V_RTAIL
        ?Z      RET                     ; the ring is full
                MOVE    @V_RING[R3], R1
                MOVE    @V_RHEAD, R2
                RET

; key: R1 the next key, from the ring of the keys typed ahead first, and
; then from con_key with the flags R1: bit 0 to wait, and -1 when none
; waits; key_soon: the next key in the ring, or the next byte of the
; console within io.t_esc, with Z clear, or Z when there is none. Uses
; R1-R6.
key
                MOVE    R2, @V_RTAIL
                CMP     R2, @V_RHEAD
        ?Z      JMP     CON_KEY         ; the ring is empty
key_ring
                MOVE    R1, @V_RING[R2]
                ADD     R2, R2, 1
                AND     @V_RTAIL, R2, RING-1
                OR[M]   R0, R1, 0x100   ; Z clear
                RET
key_soon
                MOVE    R2, @V_RTAIL
                CMP     R2, @V_RHEAD
        ?!Z     JMP     key_ring
                JMP     _io_getc.soon


; load_fin: the end of a LOAD: main, and the line ends, unless the load
; wrote words above HIMEM alone. load_new: NEW after a load that wrote a
; word below HIMEM, and Z; else not Z. Uses R2.
load_fin
                TST     @V_LBAS
        ?!Z     JMP     :++
                TST     @V_RUNF
        ?!Z     JMP     :+
                CALL    load_new
        ?Z      JMP     main
                TST     @V_LSTATS
        ?Z      JMP     main            ; no word
                RET
:
                CALL    load_new        ; RUN "NAME.BIN"
                TST     @V_LSTATS
        ?Z      JMP     main            ; no word
                CLR     @V_CUR
                MOVE    R1, PROGRAM     ; SYS 0x8000, and READY.
                PUSH    main
                JMP     st_sys
:
                CMP     @V_LBAS, 1      ; a program's text: READY. when
        ?Z      JMP     main            ; it had no line,
                CLR     @V_LBAS
                TST     @V_RUNF
        ?Z      JMP     main            ; and after LOAD,
                CALL    clr_vars        ; or RUN
                JMP     run_prog
load_new
                TST     @V_LSTATS
        ?Z      JMP     :+
                CALL    himem
                CMP     @V_LSTATS+1, R2
        ?!C     JMP     :+              ; above HIMEM
                CALL    new_prog
                CMP     R0, R0          ; Z
                RET
:
                CMP     R0, 1           ; not Z
                RET

; lvalue: R1 the address of the variable, or of the array's element, at
; R8, and R8 after it. Uses R1-R12.
lvalue
                MOVE    R1, @R8++
                SHR     R2, R1, 24
                CMP     R2, K_ARR
        ?Z      JMP     arr_elem
                CMP     R2, K_VAR
        ?!Z     JMP     err_syntax
                AND     R1, R1, 0xFFFFFF
                ADD     R1, R1, @V_PEND
                RET

; arr_elem: R1 the address of the element of the array of the token R1,
; whose subscripts are at R8, and R8 after them. An array that no DIM
; made is Undefined array, and a subscript outside, or one too many or
; too few, is Bad subscript. Uses R1-R12.
arr_elem
                AND     R1, R1, 0xFFFFFF
                CMP     R1, NO_VAR
        ?Z      JMP     err_array
                ADD     R1, R1, @V_PEND
                CMP     @1[R1], 0xFFFFFFFF
        ?Z      JMP     err_array
                MOVE    R1, @R1
                ADD     R1, R1, @V_VEND  ; the data
                PUSH    R1
                CMP     @R8++, T_LPAR
        ?!Z     JMP     err_syntax
                CALL    eval_word
                MOVE    R2, @SP
                CMP     R1, @R2
        ?!C     JMP     err_subscript
                MOVE    R3, @1[R2]      ; the second size, or 0
                CMP     @R8, T_COMMA
        ?!Z     JMP     :+
                TST     R3
        ?Z      JMP     err_subscript   ; one dimension
                MOVE    R8++, R8
                MOVE    @MPU_A, R1
                MOVE    @MPU_B, R3
                MOVE    R1, @MPU_LO
                PUSH    R1
                CALL    eval_word
                POP     R3
                MOVE    R2, @SP
                CMP     R1, @1[R2]
        ?!C     JMP     err_subscript
                ADD     R1, R1, R3
                JMP     :++
:
                TST     R3
        ?!Z     JMP     err_subscript   ; two dimensions
:
                CMP     @R8++, T_RPAR
        ?!Z     JMP     err_syntax
                POP     R2
                DBL     R1, R1
                ADD     R1, R1, R2
                ADD     R1, R1, 2
                RET

; DIM A(N) [, B(N, M) ...]: the arrays, A of N + 1 elements, and B of
; N + 1 rows of M + 1, each element 0. An array's data is its two sizes,
; the second 0 for one dimension, and its doubles, row by row. A second
; DIM of an array is Redimensioned array, and a negative N or M an
; Illegal quantity.
st_dim
                MOVE    R1, @R8++
                SHR     R2, R1, 24
                CMP     R2, K_ARR
        ?!Z     JMP     err_syntax
                AND     R1, R1, 0xFFFFFF
                ADD     R1, R1, @V_PEND
                CMP     @1[R1], 0xFFFFFFFF
        ?!Z     JMP     err_redim
                PUSH    R1              ; the entry
                CMP     @R8++, T_LPAR
        ?!Z     JMP     err_syntax
                CALL    dim_size
                PUSH    R1              ; the first size
                CLR     R1
                CMP     @R8, T_COMMA
        ?!Z     JMP     :+
                MOVE    R8++, R8
                CALL    dim_size
:
                CMP     @R8++, T_RPAR
        ?!Z     JMP     err_syntax
                MOVE    R5, R1          ; the second size, or 0
                POP     R4              ; the first
                POP     R6              ; the entry
                MOVE    @MPU_A, R4
                MOVE    @MPU_B, R5
                TST     R5
        ?Z      MOVE    @MPU_B, 1
                TST     @MPU_HI
        ?!Z     JMP     err_memory
                MOVE    R7, @MPU_LO     ; the elements
                AND[M]  R0, R7, 0xE0000000
        ?!Z     JMP     err_memory
                DBL     R7, R7          ; their words
                CALL    mem_top
                MOVE    R3, @V_AEND
                SUB     R2, R2, R3      ; the room
                ADD     R1, R7, 2
                CMP     R1, R2
        ?!C     JMP     err_memory
                MOVE    @R3++, R4
                MOVE    @R3++, R5
                SUB     @R6, R3, @V_VEND
                SUB     @R6, @R6, 2
                MOVE    @1[R6], R0      ; made
:
                TST     R7
        ?Z      JMP     :+
                MOVE    @R3++, R0
                SUB     R7, R7, 1
                JMP     :-
:
                MOVE    @V_AEND, R3
                CMP     @R8, T_COMMA
        ?!Z     JMP     stmt_end
                MOVE    R8++, R8
                JMP     st_dim
; dim_size: an expression and 1, the size of a dimension, in R1
dim_size
                CALL    eval_word
                TST     R1
        ?N      JMP     err_quant
                ADD     R1, R1, 1
                RET

; HIMEM = A: the top of BASIC's memory A, and a CLR. An A below the end
; of the arrays and the room of the frames, or above the RAM's top, is
; Out of memory.
st_himem
                CMP     @R8++, T_EQ
        ?!Z     JMP     err_syntax
                CALL    eval_word
                MOVE    R10, R1
                CALL    stmt_end
                MOVE    R11, @V_HIMEM
                CLR     @V_HIMEM
                CALL    himem           ; the RAM's top
                MOVE    @V_HIMEM, R11
                CMP     R2, R10
        ?C      JMP     err_memory      ; above it
                ADD     R2, @V_AEND, FRAMES
                CMP     R10, R2
        ?C      JMP     err_memory      ; below the arrays and the frames
                MOVE    @V_HIMEM, R10
                JMP     clr_vars        ; which returns to run_next

; put_blank: a blank. Uses R1-R4.
put_blank
                MOVE    R1, 0x20
                JMP     putc

; put_msg: the packed text R1 on a row of its own, with " in N" after it
; while a line runs, N its number, and CR LF. Uses R1-R6.
put_msg
                PUSH    R1
                CALL    SCR_GETXY
                TST     R1
        ?!Z     CALL    _io_crlf
                POP     R1
                CALL    puts_b
                MOVE[M] R1, @V_CUR
        ?Z      JMP     _io_crlf
                MOVE    R1, S_IN
                CALL    puts_b
                MOVE    R1, @V_CUR
                MOVE    R1, @1[R1]
                CALL    _io_putdec
                JMP     _io_crlf

S_BREAK         .ASCII_B 'Break'
S_IN            .ASCII_B ' in '
                .DAT    0
S_LINE          .ASCII_B 'Undefined line'
S_NEXT          .ASCII_B 'NEXT without FOR'
                .DAT    0
S_RETNG         .ASCII_B 'RETURN without GOSUB'
                .DAT    0
S_CONT          .ASCII_B "Can't continue"
S_QUEST         .ASCII_B '? '
S_QQ            .ASCII_B '?? '
S_REDO          .ASCII_B 'Redo from start'
S_EXTRA         .ASCII_B 'Extra ignored'
S_ARRAY         .ASCII_B 'Undefined array'
S_SUBSCR
                .ASCII_B 'Bad subscript'
S_REDIM         .ASCII_B 'Redimensioned array'
