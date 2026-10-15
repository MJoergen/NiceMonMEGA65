; Echo the bytes received on the console until the input ends, then halt.
; The emulator ends the input at the end of its input file, and the MEGA65
; at a break on the UART.
PC      .EQU    R15
CONSOLE .EQU    0xFFFFFF00      ; a read: bit 8 and the byte, or bit 9 at the end

LOOP    MOVE    R1, @CONSOLE
        AND[M]  R2, R1, 0x200   ; Z is clear at the end of the input
    ?!Z MOVE    PC, DONE
        AND[M]  R2, R1, 0x100   ; Z is clear when a byte has arrived
    ?Z  MOVE    PC, LOOP        ; nothing yet
        AND     R1, R1, 0xFF
        MOVE    @CONSOLE, R1
        MOVE    PC, LOOP
DONE    HALT
