; Uses what the system has in common with the emulator: the screen, memory
; in the I/O range, the read counter, and the registers after HALT. The
; testbench reads the results back with the command line.
SCREEN  .EQU    0xFFFF0000
COUNTER .EQU    0xFFFFFF01
        MOVE    @SCREEN, 0x41           ; 'A' at column 0 of row 0
        MOVE    @SCREEN+0x7CF, 0x42     ; 'B' at column 79 of row 24
        MOVE    @0xFFFFFF02, 0x1234     ; memory in the I/O range
        MOVE    R1, @0xFFFFFF02
        MOVE    @0x110, R1              ; 0x1234
        MOVE    @COUNTER, 0             ; reads since this write: 0
        MOVE    R1, @COUNTER            ; 0
        MOVE    R1, @COUNTER            ; 1
        MOVE    R1, @COUNTER            ; 2
        MOVE    @0x111, R1              ; 2, and the counter is 3
        MOVE    R5, 0xCAFE
        HALT
