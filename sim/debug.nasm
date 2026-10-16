; Runs until it is held, for the run control of the debug link: it counts
; in R1, writes the count to COUNT, and reads WATCH, in a loop.
COUNT   .EQU    0x100
WATCH   .EQU    0x101
        MOVE    R1, 0
LOOP    ADD     R1, R1, 1
        MOVE    @COUNT, R1
        MOVE    R2, @WATCH
        MOVE    R15, LOOP
