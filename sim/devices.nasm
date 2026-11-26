; Uses the math unit (DEVICES.md §2), the performance counters (§3), and
; the floating-point unit (§11), and leaves the results in memory at
; RESULT, where tb_nicemon reads them over the debug link.
;
; The FPU divides 1000 by 7. The reads of X_HI and X_LO come while DIV
; runs, so they stall until it ends, and the read of X_W waits for the
; unit. SQRT of that is left on the stack, for the link to read.
MPU_A           .EQU    0xFFFFFF20
MPU_B           .EQU    0xFFFFFF21
SMUL_LO         .EQU    0xFFFFFF22
SDIV_Q          .EQU    0xFFFFFF26
UDIV_Q          .EQU    0xFFFFFF28
UDIV_R          .EQU    0xFFFFFF29
INSTR_LO        .EQU    0xFFFFFF42
FPU_X_LO        .EQU    0xFFFFFF88
FPU_X_HI        .EQU    0xFFFFFF89
FPU_X_W         .EQU    0xFFFFFF8B
FPU_CMD         .EQU    0xFFFFFF8C
RESULT          .EQU    0x100

                MOVE    @MPU_A, 1000
                MOVE    @MPU_B, 7
                MOVE    @RESULT, @UDIV_Q  ; 142, read while the MPU computes
                MOVE    @0x101, @UDIV_R  ; 6
                MOVE    @MPU_A, -1000
                MOVE    @0x102, @SDIV_Q  ; -142
                MOVE    @0x103, @SMUL_LO  ; -7000
                MOVE    R1, @INSTR_LO
                MOVE    R2, @INSTR_LO
                SUB     @0x104, R2, R1  ; 1: one instruction in between

                MOVE    @FPU_X_W, 1000
                MOVE    @FPU_X_W, 7
                MOVE    @FPU_CMD, 0x13  ; DIV
                MOVE    @0x106, @FPU_X_HI  ; 0x4061DB6D, while DIV runs
                MOVE    @0x107, @FPU_X_LO  ; 0xB6DB6DB7
                MOVE    @0x108, @FPU_X_W  ; 142
                MOVE    @FPU_CMD, 0x14  ; SQRT, 0x4027E7920AF6B214
                HALT
