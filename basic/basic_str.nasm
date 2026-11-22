; BASIC's strings (stage 5, issue #116, doc/BASIC.md, "Strings"): the
; heap, its sweep, the strings' stack, the expressions of strings, their
; functions, their comparisons, DATA, READ, and RESTORE, the items of
; INPUT and READ, and TIME$.
;
; A string is its length and its characters, one a word, as the screen's
; cells are, at most STR_MAX of them. A string variable, or an element of
; a string array, holds the two words of a double: the address of its
; first character, and its length, which is 0xFFFFFFFF for a variable
; never assigned, as for a number. An array of strings starts with each
; element empty, 0 and 0.
;
; The heap holds the strings' characters. It is between V_SBOT and
; V_STOP, below the frames, and grows down, towards the arrays, which
; grow up to it. A block in it is the characters, then the length, then
; the back word, which says whose the block is: the offset of a variable
; from V_PEND, TAG_ARR and the offset of an array's element from V_VEND,
; TAG_SLOT and a slot of the strings' stack, or TAG_FRAME and the offset
; from V_STOP of a variable's two words that an L frame keeps, for LOCAL
; and the parameters (basic_struct.nasm). A block is live when its
; owner holds its address and its length, or when its slot is on the
; strings' stack and holds an address in it. Nothing frees a block: an
; assignment that replaces a string leaves its old block dead, and so
; does the end of a statement for the blocks of its temporaries. The
; offsets stay right when an edit moves the variables and the arrays,
; and when a new variable moves the arrays, and RUN, CLR, NEW, and HIMEM
; empty the heap.
;
; When a block does not fit above the arrays, gc sweeps the heap once,
; from its top down, and moves each live block up over the dead ones
; below it: the back word gives the owner, whose address it sets again,
; and each entry of the strings' stack with an address in the block
; moves with it. A block that does not fit the heap, which a program
; that SYS ran may leave, ends the sweep, and the blocks below it stay
; where they are.
;
; The strings of an expression are on the strings' stack, V_SSTK, of
; SSTK_N entries, each an address and a length, as the numbers are on
; the FPU's. A string variable, a constant of the line, and a part of
; another string, which LEFT$, MID$, and RIGHT$ give, are pushed as
; they are, with no copy. A new string, of +, CHR$, STR$, HEX$, TIME$,
; INPUT, READ, and GET, is a block owned by its slot. An assignment
; takes over such a block when the string is the whole of it, and
; copies any other into a new block of the variable. As any new block
; may sweep the heap, a routine reads a string's address from its entry
; after it made a block, and not before. err and main empty the stack.

V_SSP           .EQU    0xFFFFE848      ; the entries on the strings' stack
V_SBOT          .EQU    0xFFFFE849      ; the heap's bottom, its last block's first word
V_STOP          .EQU    0xFFFFE84A      ; the heap's top, the word after its first block
V_DPTR          .EQU    0xFFFFE84B      ; for READ: the next item's character in a DATA, or 0,
V_DTOK          .EQU    0xFFFFE84C      ; and the token after which the next DATA is looked for, or 0 for the first line
V_SSTK          .EQU    0xFFFFE850      ; the strings' stack, SSTK_N entries of 2 words
V_SCR           .EQU    0xFFFFE870      ; the characters of STR$ and TIME$, 32 words, which putc writes
V_SARG1         .EQU    0xFFFFEF40      ; a statement's first string, and a 0, SARG_MAX + 1 words,
V_SARG2         .EQU    0xFFFFEF91      ; and its second, up to 0xFFFFEFE1
V_NUMC          .EQU    V_ITOK+16       ; for str_num: the characters of a number, NUMC_MAX and a 0

STR_MAX         .EQU    255             ; the characters of a string at most
SSTK_N          .EQU    16              ; the entries of the strings' stack
SARG_MAX        .EQU    80              ; the characters of a statement's string
NUMC_MAX        .EQU    143             ; the characters that str_num looks at
TAG_ARR         .EQU    0x40000000      ; in a back word: an array's element,
TAG_SLOT        .EQU    0x80000000      ; or a slot of the strings' stack,
TAG_FRAME       .EQU    0xC0000000      ; or an L frame's variable, from V_STOP
STR_KINDS       .EQU    0x8E0020        ; the kinds of the tokens that start a string, a bit each
T_TIMES         .EQU    K_SFN*K+6       ; TIME$

; is_str: not Z when the token R1 starts a string: a string in quotes, a
; string variable or array, or a function of strings, FNNAME$ among them.
; Uses R2.
is_str
                SHR     R2, R1, 24
                SHR     R2, STR_KINDS, R2
                AND[M]  R0, R2, 1
                RET

; The strings' stack. s_push: the string at R1, of R2 characters, on
; top. Uses R3.
s_push
                MOVE    R3, @V_SSP
                CMP     R3, SSTK_N
        ?!C     JMP     err_complex
                ADD     @V_SSP, R3, 1
                DBL     R3, R3
                MOVE    @V_SSTK[R3], R1
                MOVE    @V_SSTK+1[R3], R2
                RET

; s_top: R3 the top's entry, and R1 and R2 its address and its length
s_top
                MOVE    R3, @V_SSP
                DBL     R3, R3
                ADD     R3, R3, V_SSTK-2
                MOVE    R1, @R3
                MOVE    R2, @1[R3]
                RET

; s_copy: R2 words from R1 to R4, after which R1 and R4 point
s_copy
                SUB[M]  R2, R2, 1
        ?N      RET
                MOVE    @R4++, @R1++
                JMP     s_copy

; salloc: R1 = the first word of a new block of R1 characters, whose back
; word is R2, after a sweep when it does not fit; Out of memory when it
; still does not. Uses R3 and R4.
salloc
                ADD     R3, R1, 2
                SUB     R3, @V_SBOT, R3
                CMP     R3, @V_AEND
        ?!C     JMP     :+
                CALL    gc
                ADD     R3, R1, 2
                SUB     R3, @V_SBOT, R3
                CMP     R3, @V_AEND
        ?C      JMP     err_memory
:
                MOVE    @V_SBOT, R3
                ADD     R4, R3, R1
                MOVE    @R4, R1
                MOVE    @1[R4], R2
                MOVE    R1, R3
                RET

; s_new: a new string of R1 characters on top, its block owned by its
; slot: R1 its first character, and R2 its length. Uses R3 and R4.
s_new
                CMP     R1, STR_MAX+1
        ?!C     JMP     err_strlong
                OR      R2, @V_SSP, TAG_SLOT
                PUSH    R1
                CALL    salloc
                POP     R2
                JMP     s_push

; s_text: a new string on top, a copy of the R2 characters at R1, which
; are not in the heap. Uses R1-R4.
s_text
                PUSH    R1
                MOVE    R1, R2
                CALL    s_new
                MOVE    R4, R1
                POP     R1
                JMP     s_copy

; heap_reset: an empty heap, below the frames, for RUN, CLR, NEW, and
; HIMEM, which make every string variable unassigned. Uses R2.
heap_reset
                CALL    mem_top
                MOVE    @V_STOP, R2
                MOVE    @V_SBOT, R2
                RET

; room: for the program, the variables, and the arrays, which are to
; end at R3: a sweep when R3 is above the heap's bottom, and Out of
; memory when it still is, or when it is above the top of the arrays
; below the frames. Uses R2.
room
                CALL    mem_top
                CMP     R2, R3
        ?C      JMP     err_memory      ; above the RAM's top
                CMP     @V_SBOT, R3
        ?!C     RET
                CALL    gc
                CMP     @V_SBOT, R3
        ?C      JMP     err_memory
                RET

; gc: the sweep, with every register kept. R1 is the end of the next
; block down, and R2 where the live blocks go; R5 the block's first word,
; R4 its length, R6 its back word, R7 its owner's descriptor, and R8 how
; far it moves.
gc
                PUSH    R1
                PUSH    R2
                PUSH    R3
                PUSH    R4
                PUSH    R5
                PUSH    R6
                PUSH    R7
                PUSH    R8
                PUSH    R9
                PUSH    R10
                PUSH    R11
                MOVE    R1, @V_STOP
                MOVE    R2, R1
gc_next
                SUB     R3, R1, @V_SBOT  ; the words below
                CMP     R3, 2
        ?C      JMP     gc_end
                MOVE    R4, @-2[R1]
                SUB     R3, R3, 2
                CMP     R3, R4
        ?C      JMP     gc_bad          ; longer than the heap below it
                SUB     R5, R1, R4
                SUB     R5, R5, 2
                MOVE    R6, @-1[R1]
                CALL    gc_live
        ?!Z     JMP     gc_dead
                SUB[M]  R8, R2, R1
        ?Z      JMP     gc_keep         ; in its place
                MOVE    R9, R1
                MOVE    R10, R2
                ADD     R11, R4, 2
:
                MOVE    @--R10, @--R9
                SUB[M]  R11, R11, 1
        ?!Z     JMP     :-
                TST     R7
        ?!Z     ADD     @R7, @R7, R8
                MOVE    R11, @V_SSP     ; the entries with an address in the block
                MOVE    R10, V_SSTK
                ADD     R3, R4, 1
:
                SUB[M]  R11, R11, 1
        ?N      JMP     gc_keep
                SUB     R9, @R10, R5
                CMP     R9, R3
        ?C      ADD     @R10, @R10, R8
                ADD     R10, R10, 2
                JMP     :-
gc_keep
                SUB     R2, R2, R4
                SUB     R2, R2, 2
gc_dead
                MOVE    R1, R5
                JMP     gc_next
gc_bad
                SUB[M]  R3, R2, R1      ; the room above it: a dead block
        ?Z      JMP     gc_done
                SUB     R3, R3, 2
                MOVE    @-2[R2], R3
                MOVE    @-1[R2], 0xFFFFFFFF
                JMP     gc_done
gc_end
                MOVE    @V_SBOT, R2
gc_done
                POP     R11
                POP     R10
                POP     R9
                POP     R8
                POP     R7
                POP     R6
                POP     R5
                POP     R4
                POP     R3
                POP     R2
                POP     R1
                RET

; gc_live: Z when the block at R5, of R4 characters, with the back word
; R6, is live, and R7 its owner's descriptor, or 0 for a slot's. Uses R7
; and R9-R11.
gc_live
                CLR     R7
                SHR     R9, R6, 30      ; 0 a variable, 1 an array, 2 a slot, 3 none
                AND     R10, R6, 0x3FFFFFFF
                CMP     R9, 2
        ?Z      JMP     gl_slot
        ?!C     JMP     gl_frame
                TST     R9
        ?Z      ADD     R7, R10, @V_PEND
        ?Z      MOVE    R11, @V_VEND
        ?!Z     ADD     R7, R10, @V_VEND
        ?!Z     MOVE    R11, @V_AEND
gl_owner
                ADD     R9, R7, 1
                CMP     R9, R11
        ?!C     JMP     gl_no           ; past the table, or the arrays
                CMP     @R7, R5
        ?!Z     RET
                CMP     @1[R7], R4
                RET
gl_slot
                CMP     R10, @V_SSP
        ?!C     JMP     gl_no
                DBL     R10, R10
                SUB     R9, @V_SSTK[R10], R5
                ADD     R11, R4, 1
                CMP     R9, R11
        ?!C     JMP     gl_no
                CMP     R0, R0          ; Z
                RET
gl_no
                CMP     R0, 1           ; not Z
                RET
gl_frame
                ADD     R7, R10, @V_STOP  ; in a frame that is there
                CMP     R7, @V_FP
        ?C      JMP     gl_no
                MOVE    R11, FRAMES
                ADD     R11, R11, @V_STOP
                JMP     gl_owner

; store_str: the string on top to the descriptor at R1, a variable's or
; an element's, and off the stack: the block of a new string whose whole
; it is becomes the variable's, and any other string is copied into a
; new block. Uses R1-R7.
store_str
                MOVE    R7, R1
                SUB     R6, R1, @V_PEND
                CMP     R1, @V_VEND
        ?!C     SUB     R6, R1, @V_VEND
        ?!C     OR      R6, R6, TAG_ARR
                CALL    s_top
                TST     R2
        ?Z      JMP     ss_set
                ADD     R4, R1, R2      ; the length's word, if the whole of a block
                CMP     @R4, R2
        ?!Z     JMP     ss_copy
                SUB     R5, @V_SSP, 1
                OR      R5, R5, TAG_SLOT
                CMP     @1[R4], R5
        ?!Z     JMP     ss_copy
                MOVE    @1[R4], R6      ; the variable's now
ss_set
                MOVE    @R7, R1
                MOVE    @1[R7], R2
                SUB     @V_SSP, @V_SSP, 1
                RET
ss_copy
                PUSH    R7
                MOVE    R1, R2
                MOVE    R2, R6
                CALL    salloc
                MOVE    R4, R1
                PUSH    R1
                CALL    s_top           ; again, as the sweep may have moved it
                CALL    s_copy
                POP     R1
                MOVE    R2, @1[R3]
                POP     R7
                JMP     ss_set

; s_own: the string on top in a block of its own slot: a copy, unless it
; is one, or is empty, or is not in the heap. Uses R1-R7.
s_own
                CALL    s_top
                TST     R2
        ?Z      RET
                CMP     R1, @V_SBOT
        ?C      RET
                CMP     R1, @V_STOP
        ?!C     RET
                SUB     R5, @V_SSP, 1
                OR      R5, R5, TAG_SLOT
                ADD     R4, R1, R2      ; the length's word, if the whole of a block
                CMP     @R4, R2
        ?Z      CMP     @1[R4], R5
        ?Z      RET
                MOVE    R1, R2
                MOVE    R2, R5
                CALL    salloc
                MOVE    R4, R1
                PUSH    R1
                CALL    s_top           ; again, as the sweep may have moved it
                CALL    s_copy
                POP     @R3
                RET

; The expressions. sexpr: a string from R8, on the strings' stack: an
; operand, and + and another, which joins them, as often as it comes.
; Uses R1-R7 and R9.
sexpr
                CMP     SP, @V_ELIM
        ?C      JMP     err_complex
                CALL    sprimary
:
                CMP     @R8, T_PLUS
        ?!Z     RET
                MOVE    R8++, R8
                CALL    sprimary
                CALL    s_concat
                JMP     :-

; sprimary: a string in quotes, a variable, an array's element, a
; function, or a string expression in ( ); a number is a Type mismatch
sprimary
                MOVE    R1, @R8++
                SHR     R2, R1, 24
                CMP     R2, K_STR
        ?Z      JMP     sp_lit
                CMP     R2, K_SVAR
        ?Z      JMP     sp_var
                CMP     R2, K_SARR
        ?Z      JMP     sp_arr
                CMP     R2, K_SFN
        ?Z      AND     R1, R1, 0xFF
        ?Z      JMP     @SFNS[R1]
                CMP     R2, K_SFNU
        ?Z      JMP     s_ufn
                CMP     R1, T_LPAR
        ?!Z     JMP     err_type
                CALL    sexpr
                JMP     rpar
sp_lit
                AND     R2, R1, 0xFFFFFF
                MOVE    R1, R8
                ADD     R8, R8, R2
                MOVE    R8++, R8        ; and its 0
                JMP     s_push
sp_var
                AND     R1, R1, 0xFFFFFF
                CMP     R1, NO_VAR
        ?Z      JMP     err_undef
                ADD     R1, R1, @V_PEND
                MOVE    R2, @1[R1]
                CMP     R2, 0xFFFFFFFF
        ?Z      JMP     err_undef
                MOVE    R1, @R1
                JMP     s_push
sp_arr
                CALL    arr_elem
                MOVE    R2, @1[R1]
                MOVE    R1, @R1
                JMP     s_push

; s_concat: the two strings on top joined, Y and then X, in a new block
; of Y's slot, unless one of them is empty; String too long past STR_MAX.
; Uses R1-R7.
s_concat
                CALL    s_top           ; X
                TST     R2
        ?Z      JMP     s_drop
                MOVE[M] R5, @-1[R3]     ; Y's length
        ?!Z     JMP     :+
                MOVE    @-2[R3], R1     ; Y is empty: X in its place
                MOVE    @-1[R3], R2
                JMP     s_drop
:
                ADD     R1, R2, R5
                CMP     R1, STR_MAX+1
        ?!C     JMP     err_strlong
                SUB     R2, @V_SSP, 2
                OR      R2, R2, TAG_SLOT
                PUSH    R1
                CALL    salloc
                MOVE    R4, R1
                CALL    s_top           ; again, as the sweep may have moved them
                MOVE    R6, R1
                MOVE    R7, R2
                MOVE    R1, @-2[R3]
                MOVE    R2, @-1[R3]
                MOVE    @-2[R3], R4
                POP     R5
                MOVE    @-1[R3], R5
                CALL    s_copy          ; Y
                MOVE    R1, R6
                MOVE    R2, R7
                CALL    s_copy          ; X
s_drop
                SUB     @V_SSP, @V_SSP, 1
                RET

; s_compare: the strings Y and X on top compared by their codes, and
; off the stack: R6 = -1, 0, or 1 as Y is less than X, the same, or
; more. A string that is the start of the other is less. Uses R1-R6.
s_compare
                CALL    s_top           ; X
                MOVE    R4, @-2[R3]     ; Y
                MOVE    R5, @-1[R3]
                SUB     @V_SSP, @V_SSP, 2
                CLR     R6
:
                TST     R5
        ?Z      JMP     :++             ; Y ends
                TST     R2
        ?Z      ONE     R6              ; X ends first
        ?Z      RET
                MOVE    R3, @R4++
                CMP     R3, @R1++
        ?!Z     JMP     :+
                SUB     R5, R5, 1
                SUB     R2, R2, 1
                JMP     :-
:
        ?C      NOT     R6, R0
        ?!C     ONE     R6
                RET
:
                TST     R2
        ?!Z     NOT     R6, R0
                RET

; s_cmpop: the comparison R1, a token of K_OP, of the two strings on top,
; as -1 or 0 on the FPU's stack: the order of s_compare and 0, compared
; by the operator's command. Uses R1-R6.
s_cmpop
                PUSH    R1
                CALL    s_compare
                POP     R1
                MOVE    @FPU_X_W, R6
                MOVE    @FPU_X_W, R0
                AND     @FPU_CMD, R1, 0xFFFF
                RET

; p_scmp: for primary, a string in a number's place, with R8 after its
; first token, which must be compared with another, where a comparison
; binds: at the precedence R9 of a comparison or below
p_scmp
                SUB     R8, R8, 1
                CMP     R9, PREC_NOT+1
        ?!C     JMP     err_type
                CALL    sexpr
                MOVE    R1, @R8
                SHR     R2, R1, 16
                CMP     R2, K_OP*256+PREC_NOT
        ?!Z     JMP     err_type
                MOVE    R8++, R8
                PUSH    R1
                CALL    sexpr
                POP     R1
                JMP     s_cmpop

; eval_any: an expression from R8: a string on the strings' stack, and
; Z, or a number on the FPU's stack, with its flags checked, and not Z.
; A string that a comparison follows is a number, as are the operators
; after the comparison. Uses R1-R7 and R9.
eval_any
                MOVE    R1, @R8
                CALL    is_str
        ?!Z     JMP     :+
                CALL    eval_num
                CMP     R0, 1           ; not Z
                RET
:
                CALL    sexpr
                MOVE    R1, @R8
                SHR     R2, R1, 16
                CMP     R2, K_OP*256+PREC_NOT
        ?Z      JMP     :+
                CMP     R0, R0          ; Z
                RET
:
                MOVE    R8++, R8
                PUSH    R1
                CALL    sexpr
                POP     R1
                CALL    s_cmpop
                CLR     R9
                CALL    expr_more
                CALL    check_flags
                CMP     R0, 1           ; not Z
                RET

; s_paren: ( and a string and ), on the strings' stack; s_lpar: ( and a
; string
s_paren
                CALL    s_lpar
                JMP     rpar
s_lpar
                CMP     @R8++, T_LPAR
        ?!Z     JMP     err_syntax
                JMP     sexpr

; s_num_arg: ( and a string, on the strings' stack, a comma, and a number
; of 0 or more, in R1
s_num_arg
                CALL    s_lpar
                CMP     @R8++, T_COMMA
        ?!Z     JMP     err_syntax
                CALL    eval_word
                TST     R1
        ?N      JMP     err_quant
                RET

; The functions of strings, each called by sprimary with R8 after its
; token, which leave a string on top. LEFT$, MID$, and RIGHT$ give a part
; of their string, which they do not copy.
SFNS
                .DAT    f_chr, f_str, f_hex, f_left, f_mid, f_right, f_time, f_err, f_ds

; CHR$(N): the character of code N, 0 to 255
f_chr
                CALL    paren_word
                CMP     R1, 256
        ?!C     JMP     err_quant
                PUSH    R1
                ONE     R1
                CALL    s_new
                POP     R2
                MOVE    @R1, R2
                RET

; STR$(X): X as PRINT writes it, through putc into V_SCR
f_str
                CALL    paren
                CALL    check_flags
                PUSH    R10
                PUSH    R11
                PUSH    R12
                MOVE    @V_SPOS, V_SCR
                CALL    put_num
                POP     R12
                POP     R11
                POP     R10
s_scr
                SUB     R2, @V_SPOS, V_SCR
                CLR     @V_SPOS
                MOVE    R1, V_SCR
                JMP     s_text

; HEX$(X): the word X in 8 digits of hex, in upper case
f_hex
                CALL    paren_word
                PUSH    R1
                MOVE    R1, 8
                CALL    s_new
                MOVE    R4, R1
                POP     R1
                MOVE    R3, 8
:
                ROL     R1, R1, 4
                AND     R2, R1, 0xF
                ADD     R2, R2, 0x30
                CMP     R2, 0x3A
        ?!C     ADD     R2, R2, 7       ; A to F
                MOVE    @R4++, R2
                SUB[M]  R3, R3, 1
        ?!Z     JMP     :-
                RET

; LEFT$(A$, N), RIGHT$(A$, N), and MID$(A$, I [, N]): the first N
; characters of A$, its last N, and N from the I-th on, or all from it;
; fewer when A$ has fewer. I is 1 or more.
f_left
                CALL    s_num_arg
                CALL    rpar
                MOVE    R5, R1
                CLR     R4
                JMP     s_cut
f_right
                CALL    s_num_arg
                CALL    rpar
                MOVE    R5, R1
                CALL    s_top
                SUB[M]  R4, R2, R5
        ?N      CLR     R4
                JMP     s_cut
f_mid
                CALL    s_num_arg
                SUB[M]  R1, R1, 1
        ?N      JMP     err_quant       ; I = 0
                PUSH    R1
                MOVE    R1, STR_MAX
                CMP     @R8, T_COMMA
        ?!Z     JMP     :+
                MOVE    R8++, R8
                CALL    eval_word
                TST     R1
        ?N      JMP     err_quant
:
                CALL    rpar
                MOVE    R5, R1
                POP     R4
; s_cut: the string on top, from its R4-th character on, R5 at most
s_cut
                CALL    s_top
                CMP     R2, R4
        ?C      MOVE    R4, R2          ; not past the end
                ADD     @R3, R1, R4
                SUB     R2, R2, R4
                CMP     R2, R5
        ?!C     MOVE    R2, R5
                MOVE    @1[R3], R2
                RET

; TIME$: the clock's date and time as TIME shows them, through putc into
; V_SCR, or an empty string when the clock is not set
f_time
                PUSH    R8
                MOVE    R8, V_BI
                CALL    clk_split
        ?!C     JMP     :+
                MOVE    @V_SPOS, V_SCR
                CALL    clk_show
                POP     R8
                JMP     s_scr
:
                POP     R8
                CLR     R1
                CLR     R2
                JMP     s_push

; TIME$ = A$: the clock set to the date and the time of A$, as TIME sets
; it, or an Illegal quantity, with run's R8 at TIME$
st_timeset
                MOVE    R8++, R8
                CMP     @R8++, T_EQ
        ?!Z     JMP     err_syntax
                CALL    sexpr
                CALL    stmt_end
                MOVE    R1, V_SARG1
                CALL    s_zero
                CALL    clock_put
        ?!Z     JMP     err_quant
                RET

; The functions of strings that give numbers, each called by primary with
; R1 its token and R8 after it, which leave a number on the FPU's stack
p_snum
                AND     R1, R1, 0xFF
                JMP     @SNUMS[R1]
SNUMS
                .DAT    f_len, f_asc, f_val, f_instr

; LEN(A$): its characters
f_len
                CALL    s_paren
                CALL    s_top
                SUB     @V_SSP, @V_SSP, 1
                MOVE    @FPU_X_W, R2
                RET

; ASC(A$): the code of its first character; an empty A$ is an Illegal
; quantity
f_asc
                CALL    s_paren
                CALL    s_top
                SUB     @V_SSP, @V_SSP, 1
                TST     R2
        ?Z      JMP     err_quant
                MOVE    @FPU_X_W, @R1
                RET

; VAL(A$): the number at its start, after blanks and a sign, or 0
f_val
                CALL    s_paren
                CALL    s_top
                SUB     @V_SSP, @V_SSP, 1
                CALL    str_num
        ?!C     MOVE    @FPU_X_W, R0
                RET

; INSTR(A$, B$ [, I]): where B$ first is in A$, from its I-th character
; on, or from its first, counted from 1; 0 when it is not. An empty B$ is
; at I.
f_instr
                CALL    s_lpar
                CMP     @R8++, T_COMMA
        ?!Z     JMP     err_syntax
                CALL    sexpr
                ONE     R1
                CMP     @R8, T_COMMA
        ?!Z     JMP     :+
                MOVE    R8++, R8
                CALL    eval_word
                TST     R1
        ?N      JMP     err_quant
        ?Z      JMP     err_quant
:
                CALL    rpar
                SUB     R6, R1, 1       ; the offset in A$
                CALL    s_top           ; B$
                MOVE    R4, @-2[R3]     ; A$
                MOVE    R5, @-1[R3]
                SUB     @V_SSP, @V_SSP, 2
fi_at
                SUB     R7, R5, R6      ; the characters from the offset
                CMP     R5, R6
        ?C      JMP     fi_none         ; past the end
                CMP     R7, R2
        ?C      JMP     fi_none         ; fewer than B$'s
                ADD     R3, R4, R6
                CLR     R7
:
                CMP     R7, R2
        ?Z      JMP     :+              ; all of B$
                ADD     R9, R1, R7
                MOVE    R9, @R9
                CMP     R9, @R3++
        ?!Z     ADD     R6, R6, 1
        ?!Z     JMP     fi_at
                ADD     R7, R7, 1
                JMP     :-
:
                ADD     @FPU_X_W, R6, 1
                RET
fi_none
                MOVE    @FPU_X_W, R0
                RET

; str_num: the number at R1, of the R2 characters there, after blanks and
; a sign, with blanks after the sign, pushed on the FPU's stack, with R1
; after its last character, and C; or no C and nothing pushed, when no
; number starts there. A number is digits with a point or not, or a point
; and digits, then an E with digits, or not; or 0x and hex digits. Its
; characters are copied to V_NUMC with a 0, and tokenized, as a constant
; of a line is, of which NUMC_MAX are looked at. Uses R1-R7 and R9, and
; keeps R8, R10-R12, and V_KW.
str_num
                PUSH    R8
                PUSH    R10
                PUSH    R11
                PUSH    R12
                PUSH    @V_KW
                MOVE    R7, R1          ; the text
                MOVE    R4, V_NUMC
                CMP     R2, NUMC_MAX+1
        ?!C     MOVE    R2, NUMC_MAX
                CALL    s_copy
                MOVE    @R4, R0
                MOVE    R5, V_NUMC
                CALL    sn_blanks
                CLR     R6              ; the sign
                CMP     @R5, 0x2D       ; -
        ?Z      ONE     R6
                CMP     @R5, 0x2B       ; +
        ?!Z     CMP     @R5, 0x2D
        ?Z      MOVE    R5++, R5
                CALL    sn_blanks
                MOVE    R9, R5          ; the number's first character
                CMP     @R5, 0x30
        ?!Z     JMP     sn_dec
                AND     R1, @1[R5], 0xDF
                CMP     R1, 0x58        ; X
        ?!Z     JMP     sn_dec
                MOVE    R1, @2[R5]
                CALL    dval
                CMP     R2, 16
        ?!C     JMP     sn_dec          ; 0 alone
                ADD     R5, R5, 2
:
                MOVE    R1, @R5
                CALL    dval
                CMP     R2, 16
        ?C      MOVE    R5++, R5
        ?C      JMP     :-
                JMP     sn_tok
sn_dec
                CLR     R3              ; the digits
                CALL    sn_digits
                CMP     @R5, 0x2E       ; .
        ?Z      MOVE    R5++, R5
        ?Z      CALL    sn_digits
                TST     R3
        ?Z      JMP     sn_none
                AND     R1, @R5, 0xDF
                CMP     R1, 0x45        ; E
        ?!Z     JMP     sn_tok
                ADD     R4, R5, 1
                CMP     @R4, 0x2B
        ?!Z     CMP     @R4, 0x2D
        ?Z      MOVE    R4++, R4
                SUB     R1, @R4, 0x30
                CMP     R1, 10
        ?!C     JMP     sn_tok          ; an E with no digits is not the number's
                MOVE    R5, R4
                CALL    sn_digits
sn_tok
                PUSH    R6
                PUSH    R7
                PUSH    R5
                MOVE    @R5, R0         ; the number's end
                MOVE    R5, R9
                MOVE    R8, V_ITOK
                MOVE    @-1[R8], R0     ; no token before it
                MOVE    @V_TLIM, V_ITOK+8
                CALL    tokenize_to
                MOVE    R8, V_ITOK
                CALL    primary
                POP     R5
                POP     R7
                POP     R6
                TST     R6
        ?!Z     MOVE    @FPU_CMD, FPU_NEG
                SUB     R1, R5, V_NUMC
                ADD     R1, R1, R7
                CMP     R0, 1           ; C
                JMP     :+
sn_none
                CMP     R0, R0          ; no C
:
                POP     @V_KW
                POP     R12
                POP     R11
                POP     R10
                POP     R8
                RET
; sn_blanks: R5 after the blanks at it
sn_blanks
                CMP     @R5, 0x20
        ?Z      MOVE    R5++, R5
        ?Z      JMP     sn_blanks
                RET
; sn_digits: R5 after the digits at it, and R3 plus their count. Uses R1.
sn_digits
                SUB     R1, @R5, 0x30
                CMP     R1, 10
        ?!C     RET
                MOVE    R5++, R5
                ADD     R3, R3, 1
                JMP     sn_digits

; s_zero: the string on top copied to R1 with a 0 after it, for a
; statement's routine, and off the stack; String too long past SARG_MAX.
; Keeps R1. Uses R2-R4.
s_zero
                MOVE    R4, R1
                PUSH    R1
                CALL    s_top
                SUB     @V_SSP, @V_SSP, 1
                CMP     R2, SARG_MAX+1
        ?!C     JMP     err_strlong
                CALL    s_copy
                MOVE    @R4, R0
                POP     R1
                RET

; k_str_expr: for k_string, a string expression, copied with a 0 to the
; buffer of the slot R12, V_SARG1 for slot 1 and V_SARG2 else: R1 the
; buffer. Keeps R3 and R10-R12.
k_str_expr
                PUSH    R3
                PUSH    R10
                PUSH    R11
                PUSH    R12
                CALL    sexpr
                POP     R12
                POP     R11
                POP     R10
                POP     R3
                MOVE    R1, V_SARG1
                CMP     R12, 1
        ?!Z     MOVE    R1, V_SARG2
                JMP     s_zero

; lvalue_s: R1 the address of the string variable, or of the element of
; an array of strings, at R8, and R8 after it, as lvalue has a number's.
; Uses R1-R12.
lvalue_s
                MOVE    R1, @R8++
                SHR     R2, R1, 24
                CMP     R2, K_SARR
        ?Z      JMP     arr_elem
                CMP     R2, K_SVAR
        ?!Z     JMP     err_name
                AND     R1, R1, 0xFFFFFF
                ADD     R1, R1, @V_PEND
                RET

; st_sassign: V$ = A$, which run_other goes to with R8 at V$, R2 its
; kind. assign_str: the same, after LET.
st_sassign
                CMP     R2, K_SARR
        ?!Z     CMP     @1[R8], T_EQ
        ?!Z     JMP     err_unknown
                MOVE    @V_KW, I_LET+1  ; for the lines of HELP of LET
assign_str
                CALL    lvalue_s
                CMP     @R8++, T_EQ
        ?!Z     JMP     err_syntax
                PUSH    R1
                CALL    sexpr
                POP     R1
                CALL    store_str
                JMP     stmt_end

; GET A$: A$ the next key typed ahead, or an empty string when there is
; none, with no wait
get_str
                CALL    lvalue_s
                PUSH    R1
                CALL    stmt_end
                CLR     R1
                CALL    key
                TST     R1
        ?N      JMP     :+
                PUSH    R1
                ONE     R1
                CALL    s_new
                POP     R2
                MOVE    @R1, R2
                JMP     :++
:
                CLR     R1
                CLR     R2
                CALL    s_push
:
                POP     R1
                JMP     store_str

; item: the item of INPUT's line or of a DATA's text at R5, up to a comma
; or the end: R6 its first character and R7 the word after its last, and
; R5 at the comma or the 0 after it, R4 1 for an item in quotes, else 0,
; and Z. The blanks around an item are not its, and an item in quotes is
; what is between them, which may have commas, after which only blanks
; may come: else not Z. Uses R1 and R4-R7.
item
                CLR     R4
item_b
                CMP     @R5, 0x20
        ?Z      MOVE    R5++, R5
        ?Z      JMP     item_b
                CMP     @R5, 0x22
        ?Z      JMP     it_quote
                MOVE    R6, R5
:
                MOVE[M] R1, @R5
        ?Z      JMP     :+
                CMP     R1, 0x2C
        ?Z      JMP     :+
                MOVE    R5++, R5
                JMP     :-
:
                MOVE    R7, R5          ; without the blanks at its end
:
                CMP     R7, R6
        ?Z      RET
                CMP     @-1[R7], 0x20
        ?!Z     JMP     it_ok
                SUB     R7, R7, 1
                JMP     :-
it_quote
                ONE     R4
                MOVE    R5++, R5
                MOVE    R6, R5
:
                MOVE[M] R1, @R5
        ?Z      JMP     :+              ; no closing quote: to the end
                CMP     R1, 0x22
        ?Z      JMP     :+
                MOVE    R5++, R5
                JMP     :-
:
                MOVE    R7, R5
                TST     R1
        ?!Z     MOVE    R5++, R5        ; after the quote
:
                CMP     @R5, 0x20
        ?Z      MOVE    R5++, R5
        ?Z      JMP     :-
                MOVE[M] R1, @R5
        ?Z      RET
                CMP     R1, 0x2C
                RET
it_ok
                CMP     R0, R0          ; Z
                RET

; get_item: the item R6 to R7, in quotes when R4 is 1, into the variable
; or the element at R11, a number's or a string's, and R11 after it and
; its subscripts, and Z; or not Z, with nothing stored, when the variable
; takes a number and the item is none, or is in quotes. Keeps R5. Uses
; R1-R12. V_REDO is 0 while the element is found, so that an error of
; its subscripts, which no other answer mends, is an error for INPUT
; too, and no Redo from start; an error of the item itself, a number
; too large, or one past a word for a variable with %, is still one.
get_item
                PUSH    R5
                MOVE    R1, R6
                SUB     R2, R7, R6
                SHR     R3, @R11, 24
                CMP     R3, K_SVAR
        ?!Z     CMP     R3, K_SARR
        ?!Z     JMP     :+
                CALL    s_text
                MOVE    R8, R11
                PUSH    @V_REDO
                CLR     @V_REDO
                CALL    lvalue_s
                POP     @V_REDO
                MOVE    R11, R8
                CALL    store_str
                JMP     gi_ok
:
                TST     R4
        ?!Z     JMP     gi_no           ; a string in quotes
                PUSH    R7
                CALL    str_num
                POP     R7
        ?!C     JMP     gi_no
                CMP     R1, R7
        ?!Z     JMP     gi_drop         ; more than a number
                MOVE    R8, R11
                PUSH    @V_REDO
                CLR     @V_REDO
                CALL    lvalue
                POP     @V_REDO
                MOVE    R11, R8
                CALL    store_var
gi_ok
                POP     R5
                CMP     R0, R0          ; Z
                RET
gi_drop
                MOVE    @FPU_CMD, FPU_DROP
gi_no
                POP     R5
                CMP     R0, 1           ; not Z
                RET

; DATA: the items that READ reads, the text up to the end of the line or
; to a colon that is not in quotes, a K_DATA token, passed over
st_data
                CALL    tok_skip
                JMP     stmt_end

; READ V [, W ...]: each the next item of DATA, a number or a string as
; the variable takes it; a number that is none is a Syntax error, and no
; item left is Out of data
st_read
                MOVE    R11, R8
:
                PUSH    R11
                CALL    data_item
                POP     R11
                CALL    get_item
        ?!Z     JMP     rd_name
                CMP     @R11, T_COMMA
        ?!Z     JMP     :+
                MOVE    R11++, R11
                JMP     :-
:
                MOVE    R8, R11
                JMP     stmt_end
rd_name
                MOVE    R1, @R11        ; READ ERR$, a keyword, or an item that does not fit
                JMP     err_name

; data_item: R6 and R7 the next item of DATA, as item gives it, and the
; next after it at V_DPTR, or 0 at the end of its DATA, after which the
; next DATA is looked for from V_DTOK, the token after this one. Uses
; R1-R8.
data_item
                MOVE[M] R5, @V_DPTR
        ?!Z     JMP     di_item
                MOVE[M] R8, @V_DTOK
        ?!Z     JMP     di_scan
                MOVE    R8, PROGRAM+2   ; the first line's first token
                MOVE    R1, PROGRAM
                CMP     R1, @V_PEND
        ?!C     JMP     err_data        ; no program
di_scan
                MOVE[M] R1, @R8
        ?!Z     JMP     :+
                ADD     R1, R8, 1       ; the next line
                CMP     R1, @V_PEND
        ?!C     JMP     err_data
                ADD     R8, R1, 2
                JMP     di_scan
:
                SHR     R2, R1, 24
                CMP     R2, K_DATA
        ?Z      JMP     :+
                CALL    tok_skip
                JMP     di_scan
:
                ADD     R5, R8, 1
                CALL    tok_skip
                MOVE    @V_DTOK, R8
di_item
                CALL    item
        ?!Z     JMP     err_syntax
                CLR     @V_DPTR
                CMP     @R5, 0x2C
        ?Z      ADD     @V_DPTR, R5, 1
                RET

; RESTORE [N]: READ from the first DATA again, or from the first of line
; N on
st_restore
                CLR     @V_DPTR
                CLR     @V_DTOK
                SHR     R2, @R8, 24
                CMP     R2, K_LINE
        ?!Z     JMP     stmt_end
                MOVE[M] R1, @1[R8]
        ?!Z     JMP     :+
                AND     R3, @R8, 0xFFFFFF
                CALL    find_line
        ?!Z     JMP     err_line
                MOVE    @1[R8], R1
:
                ADD     @V_DTOK, R1, 2
                ADD     R8, R8, 2
                JMP     stmt_end

err_type
                MOVE    R1, S_TYPE
                JMP     err
err_strlong
                MOVE    R1, S_STRLONG
                JMP     err
err_data
                MOVE    R1, S_DATA
                JMP     err

S_TYPE          .ASCII_B 'Type mismatch'
S_STRLONG
                .ASCII_B 'String too long'
S_DATA          .ASCII_B 'Out of data'
