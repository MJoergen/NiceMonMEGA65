; Runs until it is held, for the run control of the debug link: it counts
; in R1, reads WATCH, and writes the count to COUNT, in a loop. The
; instruction after each data access makes none, so that a watchpoint stops
; the pipelined core right after the access too (src/run_ctl.vhd).
COUNT   .EQU    0x100
WATCH   .EQU    0x101
        MOVE    R1, 0
LOOP    ADD     R1, R1, 1
        MOVE    R2, @WATCH
        MOVE    @COUNT, R1
        MOVE    R15, LOOP
