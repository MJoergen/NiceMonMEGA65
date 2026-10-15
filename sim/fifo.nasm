; Waits about 20000 cycles, so that the input piles up in the FIFO of the
; UART, then echoes the bytes received, until a '.', and halts.
PC      .EQU    R15
CONSOLE .EQU    0xFFFFFF00      ; a read: bit 8 set, and the byte in bits 7..0
        MOVE    R3, 2000
WAIT    SUB[M]  R3, R3, 1
    ?!Z MOVE    PC, WAIT
LOOP    MOVE    R1, @CONSOLE
        AND[M]  R2, R1, 0x100   ; Z is clear when a byte has arrived
    ?Z  MOVE    PC, LOOP        ; nothing yet
        AND     R1, R1, 0xFF
        MOVE    @CONSOLE, R1
        SUB[M]  R2, R1, 0x2E    ; a '.'?
    ?!Z MOVE    PC, LOOP
        HALT
