; A short program for the checks of the breakpoints (tools/hwtest.py),
; which sets them at its labels, from niceasm.py --symbols: a loop of three
; passes, a skipped instruction, a read from memory, a two-word instruction,
; whose second word never matches, a CALL of a routine, which writes the
; word that READ reads, and RET, and a HALT. tb_nicemon sets its
; watchpoints on that word. The stack, which CALL pushes through R13, is
; below 0x300.
PC              .EQU    R15
SR              .EQU    R14

START           MOVE    R12, 0x200
                MOVE    R13, 0x300
                MOVE    R4, 3
LOOP            SUB[M]  R4, R4, 1
        ?!Z     JMP     LOOP
SKIP    ?!Z     MOVE    R3, 0x55        ; skipped: R4 is 0
READ            MOVE    R1, @R12
TWO             MOVE    R5, 0x12345678
                CALL    ROUTINE         ; RET returns to AFTER
AFTER           MOVE    R6, 7
DONE            HALT
ROUTINE         MOVE    R7, 0x1234
STORE           MOVE    @R12, R7
                RET
