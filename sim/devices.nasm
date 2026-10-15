; Uses the math unit (ISA.md §8.4), the performance counters (§8.5), and
; the timer (§8.6), and leaves the results in memory at RESULT, where
; tb_nicemon reads them with the CLI.
;
; The timer raises IRQ through vector 0xF0 every 200 cycles, and the
; interrupt routine counts the requests in R6. The program waits for three,
; and then stops the timer. The core runs far more than one instruction in
; 200 cycles, so no request is pending when it stops.
MPU_A    .EQU    0xFFFFFF20
MPU_B    .EQU    0xFFFFFF21
SMUL_LO  .EQU    0xFFFFFF22
SDIV_Q   .EQU    0xFFFFFF26
UDIV_Q   .EQU    0xFFFFFF28
UDIV_R   .EQU    0xFFFFFF29
INSTR_LO .EQU    0xFFFFFF12
TIMER_PERIOD .EQU 0xFFFFFF40
TIMER_VECTOR .EQU 0xFFFFFF42
RESULT   .EQU    0x100

        MOVE    @MPU_A, 1000
        MOVE    @MPU_B, 7
        MOVE    @RESULT, @UDIV_Q        ; 142, read while the MPU computes
        MOVE    @0x101, @UDIV_R         ; 6
        MOVE    @MPU_A, -1000
        MOVE    @0x102, @SDIV_Q         ; -142
        MOVE    @0x103, @SMUL_LO        ; -7000
        MOVE    R1, @INSTR_LO
        MOVE    R2, @INSTR_LO
        SUB     @0x104, R2, R1          ; 1: one instruction in between

        MOVE    @TIMER_VECTOR, 0xF0
        MOVE    @TIMER_PERIOD, 200
        OR      R14, R14, 0x40000000    ; E = 1
wait    SUB[M]  R0, R6, 3
        ?!Z MOVE R15, wait
        MOVE    @TIMER_PERIOD, 0
        MOVE    @0x105, R6              ; 3 requests taken
        HALT

on_irq  ADD     R6, R6, 1
        RTI

        .ORG    0xF0
        .DAT    on_irq
