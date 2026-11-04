; Waits 2000 passes of 2 instructions, about 16000 cycles with the
; pipelined core and 45000 with the multi-cycle one, so that the input
; piles up in the FIFO of the UART, then echoes the bytes received, until a '.', and halts.
CONSOLE         .EQU    0xFFFFFF00      ; a read: bit 8 set, and the byte in bits 7..0
                MOVE    R3, 2000
WAIT            SUB[M]  R3, R3, 1
        ?!Z     JMP     WAIT
LOOP            MOVE    R1, @CONSOLE
                AND[M]  R2, R1, 0x100   ; Z is clear when a byte has arrived
        ?Z      JMP     LOOP            ; nothing yet
                AND     R1, R1, 0xFF
                MOVE    @CONSOLE, R1
                SUB[M]  R2, R1, 0x2E    ; a '.'?
        ?!Z     JMP     LOOP
                HALT
