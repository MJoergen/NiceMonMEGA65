; BASIC's machine (stage 10, issue #121, doc/BASIC.md, "The machine"):
; TI, SLEEP, FOREGROUND, BACKGROUND, CURSOR, and RCURSOR, through the
; microsecond counter, the screen's registers, and the entries scr_color,
; scr_moveto, and scr_getxy.
;
; TI is the microsecond counter of nice_cpu's DEVICES.md §3, all 64 bits
; of it, read low word first, so that the two halves are of one moment.
; It counts from the start of the core, real time on a board and in
; niceemu, and a microsecond a step with --step-time.
;
; SLEEP waits on the counter, and polls the console meanwhile, as a
; program's statements do: CTRL-C breaks it, and CONT goes on after it.
; Each round writes the microseconds left, up to SLEEP_STEP, to
; TIME_SKIP, which niceemu with --step-time skips at once, and which a
; board and niceemu without it ignore, so that a test of SLEEP takes no
; real time.
;
; The colors are those of a screen word: the foreground in bits 19..8
; and the background in bits 31..20, each of 4 bits of red, green, and
; blue. A color's number of 0 to 15 is one of BASIC 65's 16, PALETTE, and
; three numbers of 0 to 15 are the red, the green, and the blue.
;
; The cursor's style is bit 5 of SCR_CTL, which blinks it, and bit 4,
; which makes it small. main shows it again, blinking, at each READY.

TIME_LO         .EQU    0xFFFFFF44      ; the microsecond counter, bits 31..0, which a read snaps
TIME_HI         .EQU    0xFFFFFF45      ; and bits 63..32 of the snapshot
TIME_SKIP       .EQU    0xFFFFFF5F      ; the microseconds that niceemu --step-time skips
SCR_CTL         .EQU    0xFFFFFF80      ; the screen's state: bit 6 shows the cursor,
CUR_SHOW        .EQU    0x40
CUR_STYLE       .EQU    0x30            ; bit 5 blinks it, and bit 4 makes it small
FPU_MUL         .EQU    0x12            ; the FPU's commands: MUL,
FPU_UTOF        .EQU    0x29            ; UTOF,
FPU_FTOI        .EQU    0x2A            ; and FTOI
SLEEP_STEP      .EQU    10000           ; the microseconds skipped at a time
T_TI            .EQU    K_FN*K+0x400000  ; TI's token
T_OFF           .EQU    K_SEP*K+6       ; OFF's, after CURSOR

; TI: the microsecond counter, on the FPU's stack, which primary's p_fn
; comes to
p_ti
                MOVE    @FPU_X_LO, @TIME_LO
                MOVE    @FPU_X_HI, @TIME_HI
                MOVE    @FPU_CMD, FPU_UTOF
                RET

; SLEEP S: S seconds, of which a fraction counts to the microsecond. A
; negative S is an Illegal quantity. R9 and R10 hold the counter's value
; at the end, which poll and con_key keep.
st_sleep
                CALL    eval_num
                CALL    stmt_end
                MOVE    R1, @FPU_STATUS
                AND[M]  R0, R1, FPU_ZERO
        ?!Z     JMP     :+              ; 0 and -0: no wait
                AND[M]  R0, R1, FPU_NEGATIVE
        ?!Z     JMP     err_quant
:
                MOVE    @FPU_X_W, 1000000
                MOVE    @FPU_CMD, FPU_MUL
                MOVE    @FPU_CMD, FPU_FTOI
                MOVE    R9, @FPU_X_LO
                MOVE    R10, @FPU_X_HI
                MOVE    @FPU_CMD, FPU_DROP
                ADD[M]  R9, R9, @TIME_LO
                ADD[C]  R10, R10, @TIME_HI
                MOVE    R8, @V_TP       ; the break key goes on after SLEEP
sleep_wait
                CALL    poll
                SUB[M]  R1, R9, @TIME_LO
                SUB[MC] R2, R10, @TIME_HI
        ?N      RET                     ; past the end
                TST     R2
        ?!Z     MOVE    R1, SLEEP_STEP
                CMP     R1, SLEEP_STEP
        ?!C     MOVE    R1, SLEEP_STEP
                TST     R1
        ?Z      RET                     ; at the end
                MOVE    @TIME_SKIP, R1
                JMP     sleep_wait

; FOREGROUND N and FOREGROUND R, G, B: the color of the characters put
; from now on; BACKGROUND likewise their background. R11 is the color's
; shift in the screen word, and R12 the bits of the other color, which
; stay.
st_fg
                MOVE    R11, 8
                MOVE    R12, 0xFFF00000
                JMP     color
st_bg
                MOVE    R11, 20
                MOVE    R12, 0x000FFF00
color
                CLR     R10
                CALL    color_part
                CMP     @R8, T_COMMA
        ?Z      JMP     :+
                MOVE    R10, @PALETTE[R10]  ; one of the 16
                JMP     :++
:
                CMP     @R8++, T_COMMA  ; red, green, and blue
        ?!Z     JMP     err_syntax
                CALL    color_part
                CMP     @R8++, T_COMMA
        ?!Z     JMP     err_syntax
                CALL    color_part
:
                CALL    stmt_end
                SHL     R10, R10, R11
                CLR     R1
                CALL    SCR_COLOR       ; the color now, which scr_color
                AND     R1, R1, R12     ; changes only in R1 and R2
                OR      R1, R1, R10
                JMP     SCR_COLOR       ; which returns to run_next

; color_part: R10 times 16, plus a number of 0 to 15 at R8, else an
; Illegal quantity. Uses R1-R7 and R9.
color_part
                CALL    eval_word
                CMP     R1, 16
        ?!C     JMP     err_quant
                SHL     R10, R10, 4
                OR      R10, R10, R1
                RET

; BASIC 65's 16 colors, the C65's palette at its start, as screen words'
; 4 bits of red, green, and blue: black, white, red, cyan, purple,
; green, blue, yellow, orange, brown, light red, dark gray, gray, light
; green, light blue, and light gray
PALETTE
                .DAT    0x000, 0xFFF, 0xF00, 0x0FF, 0xF0F, 0x0F0, 0x00F, 0xFF0
                .DAT    0xF60, 0xA40, 0xF77, 0x555, 0x888, 0x9F9, 0x99F, 0xBBB

; CURSOR ON, CURSOR OFF, and CURSOR [ON, | OFF,] C, R [, S]: the cursor
; shown or not, and at column C and row R, with the style S: 0 solid, 1
; blinking, as BASIC 65 has them, and 2 and 3 the same, small. The
; column and the row stop at the screen's last, as scr_moveto has them,
; and a negative one is an Illegal quantity. R11 is 1 for ON, 0 for OFF,
; and -1 for neither, R12 1 with a place, and R10 the style or -1.
st_cursor
                NOT     R11, R0
                CLR     R12
                NOT     R10, R0
                MOVE    R1, @R8
                AND     R2, R1, 0xFFFFFF00
                CMP     R2, K_KW*K+I_ON*0x100
        ?Z      ONE     R11
                CMP     R1, T_OFF
        ?Z      CLR     R11
                TST     R11
        ?N      JMP     cur_place       ; neither: the place
                MOVE    R8++, R8
                CALL    at_end
        ?Z      JMP     cur_set
                CMP     @R8++, T_COMMA
        ?!Z     JMP     err_syntax
cur_place
                CALL    cur_num         ; the column
                PUSH    R1
                CMP     @R8++, T_COMMA
        ?!Z     JMP     err_syntax
                CALL    cur_num         ; the row
                PUSH    R1
                ONE     R12
                CMP     @R8, T_COMMA
        ?!Z     JMP     cur_set
                MOVE    R8++, R8
                CALL    cur_num         ; the style
                CMP     R1, 4
        ?!C     JMP     err_quant
                MOVE    R10, R1
cur_set
                CALL    stmt_end
                MOVE    R1, @SCR_CTL
                TST     R11
        ?Z      AND     R1, R1, 0xFFFFFFBF  ; OFF
                CMP     R11, 1
        ?Z      OR      R1, R1, CUR_SHOW  ; ON
                TST     R10
        ?N      JMP     :+
                AND     R1, R1, 0xFFFFFFCF
                AND     R2, R10, 1      ; blinking
                SHL     R2, R2, 5
                OR      R1, R1, R2
                AND     R2, R10, 2      ; small
                SHL     R2, R2, 3
                OR      R1, R1, R2
:
                MOVE    @SCR_CTL, R1
                TST     R12
        ?Z      RET
                POP     R2
                POP     R1
                JMP     SCR_MOVETO      ; which returns to run_next

; cur_num: R1 a number at R8 of 0 or more, else an Illegal quantity. Uses
; R1-R7 and R9.
cur_num
                CALL    eval_word
                TST     R1
        ?N      JMP     err_quant
                RET

; RCURSOR C, R: the cursor's column to the variable C, and its row to R
st_rcursor
                CALL    lvalue
                PUSH    R1
                CMP     @R8++, T_COMMA
        ?!Z     JMP     err_syntax
                CALL    lvalue
                PUSH    R1
                CALL    stmt_end
                CALL    SCR_GETXY
                MOVE    @FPU_X_W, R2
                POP     R1
                CALL    store_var
                CALL    SCR_GETXY
                MOVE    @FPU_X_W, R1
                POP     R1
                JMP     store_var       ; which returns to run_next
