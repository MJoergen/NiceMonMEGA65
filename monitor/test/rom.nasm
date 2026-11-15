; The test of the ROM's C code, test/rom.c, which the Makefile joins to the
; ROM's module in the ROM of this test only. This program is assembled
; after it and the monitor's sources, so that it calls the functions by
; their labels, and r runs it. Each run stores the results of rom_count,
; rom_count, and rom_zero at ROMT_RESULTS + 3 n, where n is the number of
; the run, from ROMT_RUNS, which no cold start clears: 7, 8, and 0 after a
; cold start, and 9, 10, and 10 after a run without one. Then rom_hello
; prints its line, and rom_trap traps, so that the monitor's mon_trap
; prints the trap and goes back to the main loop.
;
; The FPU (issue #141): each run stores FPU_STATUS at ROMT_FPU + n as it
; starts, and leaves 10 values and the four flags on the FPU before it
; traps, so the status of the next run, 0, shows that mon_trap cleared
; them. romt_reset, at ROMT_RESET, which r runs too, leaves them as well,
; and jumps to entry 0, mon_reset, the cold start, after which the next
; run finds them cleared again.

                .ORG    0x8000
ROMT_RUNS       .EQU    0x9100
ROMT_RESULTS    .EQU    0x9101
ROMT_FPU        .EQU    0x9110
ROMT_RESET      .EQU    0x8100
FPU_X_W         .EQU    0xFFFFFF8B
FPU_STATUS      .EQU    0xFFFFFF8D

romt_main
                MOVE    R7, @ROMT_RUNS
                ADD     R1, R7, ROMT_FPU
                MOVE    @R1, @FPU_STATUS
                ADD     @ROMT_RUNS, @ROMT_RUNS, 1
                SHL     R8, R7, 1
                ADD     R7, R7, R8      ; 3 n
                ADD     R7, R7, ROMT_RESULTS
                CALL    _rom_count
                MOVE    @R7++, R1
                CALL    _rom_count
                MOVE    @R7++, R1
                CALL    _rom_zero
                MOVE    @R7++, R1
                CALL    _rom_hello
                CALL    romt_fpu
                CALL    _rom_trap
                HALT                    ; never reached

; Pushes 10 values, more than the 8 of a routine (nice_cpu's DEVICES.md
; §11.5), and sets the four flags. Uses R1.
romt_fpu
                MOVE    R1, 10
:               MOVE    @FPU_X_W, R1
                DEC[M]  R1, R1
        ?!Z     JMP     :-
                MOVE    @FPU_STATUS, 0x0F00
                RET

                .ORG    ROMT_RESET
romt_reset
                CALL    romt_fpu
                JMP     0               ; mon_reset
