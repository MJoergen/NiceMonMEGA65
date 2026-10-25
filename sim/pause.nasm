; Counts in R1 without end, and stores each count at 0x100, for the checks
; of the pause (tools/hwtest.py): while the core is paused, R1 is the count
; at 0x100, or one more.
PC      .EQU    R15
COUNT   .EQU    0x100

        MOVE    R1, 0
LOOP    ADD     R1, R1, 1
        MOVE    @COUNT, R1
        MOVE    PC, LOOP
