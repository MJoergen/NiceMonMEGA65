; A short program for the checks of the single step (tools/hwtest.py): each
; step's registers are compared with those of niceemu --trace. It has
; two-word instructions, a store, a skipped instruction, a jump, flags in
; R14, and an INT with its routine and RTI, and it ends with HALT. The
; routine's vector is at 0x103, as VBASE is 1.
PC              .EQU    R15
SR              .EQU    R14

                MOVE    SR, 1           ; VBASE = 1: the table is at 0x100
                MOVE    R13, 0x200
                MOVE    R1, 0xFFFFFFFF
                ADD[M]  R2, R1, 1       ; carry and Z, and R2 = 0
                MOVE    @R13++, R1
        ?!Z     MOVE    R3, 0x55        ; skipped: R2 is 0
                INT     3
                MOVE    R4, 2
LOOP            SUB[M]  R4, R4, 1
        ?!Z     MOVE    PC, LOOP
                MOVE    @R13++, R4
                HALT
V3              MOVE    R5, 0x1234
                RTI
                .ORG    0x103
                .DAT    V3
