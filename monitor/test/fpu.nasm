; The test of the FPU at a program's end (issue #141), which the Makefile
; runs as fpu. Each run stores FPU_STATUS at FPUT_STATUS + n as it starts,
; where n is the number of the run, from FPUT_RUNS, which no cold start
; clears, and leaves 10 values and the four flags on the FPU as it ends,
; so the status of the next run, 0x00080000, that of an empty FPU, shows
; that the monitor cleared them. A run of an even number returns to SYS
; with RET, and one of an odd number leaves through entry 1, mon_exit,
; each with its number as the status. fput_reset, at FPUT_RESET, which
; SYS runs too, leaves the values and the flags as well, and jumps to
; entry 0, mon_reset, the cold start, after which the next run finds
; them cleared again.

                .ORG    0x8000
FPUT_RUNS       .EQU    0x9100
FPUT_STATUS     .EQU    0x9101
FPUT_RESET      .EQU    0x8100
MON_RESET       .EQU    0x00
MON_EXIT        .EQU    0x02
FPU_X_W         .EQU    0xFFFFFF8B
FPU_STATUS      .EQU    0xFFFFFF8D

fput_main
                MOVE    R2, @FPUT_RUNS
                MOVE    @FPUT_STATUS[R2], @FPU_STATUS
                ADD     @FPUT_RUNS, R2, 1
                CALL    fput_fill
                MOVE    R1, R2          ; the status
                AND[M]  R0, R2, 1
        ?!Z     JMP     MON_EXIT
                RET

; Pushes 10 values, more than the 8 of a routine (nice_cpu's DEVICES.md
; §11.5), and sets the four flags. Uses R1.
fput_fill
                MOVE    R1, 10
:               MOVE    @FPU_X_W, R1
                DEC[M]  R1, R1
        ?!Z     JMP     :-
                MOVE    @FPU_STATUS, 0x0F00
                RET

                .ORG    FPUT_RESET
fput_reset
                CALL    fput_fill
                JMP     MON_RESET
