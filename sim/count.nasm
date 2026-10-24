; Reads the read counter without writing it first, so the testbench sees
; that a start keeps the count that the program before left (SYSTEM.md §1).
COUNTER .EQU    0xFFFFFF01
        MOVE    R1, @COUNTER
        MOVE    @0x100, R1
        HALT
