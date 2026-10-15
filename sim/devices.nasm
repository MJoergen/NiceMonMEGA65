; Uses the math unit (ISA.md §8.4) and the performance counters (§8.5), and
; leaves the results in memory at RESULT, where tb_nicemon reads them with
; the CLI.
MPU_A    .EQU    0xFFFFFF20
MPU_B    .EQU    0xFFFFFF21
SMUL_LO  .EQU    0xFFFFFF22
SDIV_Q   .EQU    0xFFFFFF26
UDIV_Q   .EQU    0xFFFFFF28
UDIV_R   .EQU    0xFFFFFF29
INSTR_LO .EQU    0xFFFFFF12
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
        HALT
