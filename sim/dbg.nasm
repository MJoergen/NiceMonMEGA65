; Counts in R1 to LIMIT, then halts, for tb_dbg: the debugger pauses it,
; steps it, lets it go on, and catches the halt, with R1 at LIMIT and Z
; set. It needs no RAM, so that it runs from the ROM.
PC              .EQU    R15
LIMIT           .EQU    0x800

                MOVE    R1, 0
LOOP            ADD     R1, R1, 1
                SUB[M]  R2, R1, LIMIT
        ?!Z     MOVE    PC, LOOP
                HALT
