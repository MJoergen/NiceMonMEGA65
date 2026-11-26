; A short program for the checks of the single step (tools/hwtest.py): each
; step's registers are compared with those of niceemu --trace. It has
; two-word instructions, a store, a skipped instruction, a jump, flags in
; R14, and a CALL of a routine and RET, and it ends with HALT. CALL pushes
; through R13.
PC              .EQU    R15
SR              .EQU    R14

                MOVE    R13, 0x200
                MOVE    R1, 0xFFFFFFFF
                ADD[M]  R2, R1, 1       ; carry and Z, and R2 = 0
                MOVE    @R13++, R1
        ?!Z     MOVE    R3, 0x55        ; skipped: R2 is 0
                CALL    ROUTINE         ; RET returns here
                MOVE    R4, 2
LOOP            SUB[M]  R4, R4, 1
        ?!Z     JMP     LOOP
                MOVE    @R13++, R4
                HALT
ROUTINE         MOVE    R5, 0x1234
                RET
