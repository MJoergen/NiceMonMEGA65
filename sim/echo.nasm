; Echo the bytes received on the console, until a '.', then halt.
PC              .EQU    R15
CONSOLE         .EQU    0xFFFFFF00      ; a read: bit 8 set, and the byte in bits 7..0

LOOP            MOVE    R1, @CONSOLE
                AND[M]  R2, R1, 0x100   ; Z is clear when a byte has arrived
        ?Z      MOVE    PC, LOOP        ; nothing yet
                AND     R1, R1, 0xFF
                MOVE    @CONSOLE, R1
                SUB[M]  R2, R1, 0x2E    ; a '.'?
        ?!Z     MOVE    PC, LOOP
                HALT
