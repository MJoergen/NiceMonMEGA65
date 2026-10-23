; Print the bytes that the command line prints at a halt, CR LF HALT CR LF,
; as output of the program, then more, ending in CR, and halt. A tool that
; copies a program's output must not take the first for the halt, and must
; show the CR at the end at once.
PC      .EQU    R15
CONSOLE .EQU    0xFFFFFF00

        MOVE    R1, TEXT
LOOP    MOVE[M] R2, @R1++       ; next byte, and set Z if it is 0
    ?Z  MOVE    PC, DONE
        MOVE    @CONSOLE, R2
        MOVE    PC, LOOP
DONE    HALT

TEXT    .DAT    97, 13, 10, 72, 65, 76, 84, 13, 10     ; a CR LF HALT CR LF
        .DAT    109, 111, 114, 101, 13, 0              ; more CR
