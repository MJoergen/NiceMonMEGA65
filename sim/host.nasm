; Writes the bytes 0x00 to 0xFF to the console, again and again, and stores
; the next byte at 0x100, for tb_dbg_host: the console bytes come in order,
; 0xFF among them, and while the core is paused, R1 is the byte at 0x100,
; or the one after it.
PC              .EQU    R15
CONSOLE         .EQU    0xFFFFFF00
NEXT            .EQU    0x100

                MOVE    R1, 0
LOOP            MOVE    @CONSOLE, R1
                ADD     R1, R1, 1
                AND     R1, R1, 0xFF
                MOVE    @NEXT, R1
                MOVE    PC, LOOP
