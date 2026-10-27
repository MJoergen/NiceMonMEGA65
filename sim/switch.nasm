; Waits until switch 0 is on, so that the input piles up in the FIFO for as
; long as the testbench wants, then echoes the bytes received, until a '.',
; and halts.
PC              .EQU    R15
CONSOLE         .EQU    0xFFFFFF00      ; a read: bit 8 set, and the byte in bits 7..0
BRD_SW          .EQU    0xFFFFFF96
WAIT            MOVE    R1, @BRD_SW
                AND[M]  R2, R1, 1       ; Z is clear when switch 0 is on
        ?Z      MOVE    PC, WAIT
LOOP            MOVE    R1, @CONSOLE
                AND[M]  R2, R1, 0x100   ; Z is clear when a byte has arrived
        ?Z      MOVE    PC, LOOP        ; nothing yet
                AND     R1, R1, 0xFF
                MOVE    @CONSOLE, R1
                SUB[M]  R2, R1, 0x2E    ; a '.'?
        ?!Z     MOVE    PC, LOOP
                HALT
