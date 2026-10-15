; The program of the ROM in the tests: it prints a greeting and halts, like
; hello.nasm of nice_cpu. Its stack is at the top of the memory, as the
; runtime's is (ISA.md §9.3), which is RAM. hello.nasm's stack at 0x1000 is
; in the ROM on the board, where a push is dropped and the return address
; reads back as 0, so that program restarts forever.
SP      .EQU    R13
PC      .EQU    R15
CONSOLE .EQU    0xFFFFFF00

        MOVE    SP, 0xFFFFFF00  ; the stack, at the top of the memory
        MOVE    R1, TEXT        ; the argument: the string's address
        ADD     @--SP, 2, PC    ; push the return address ...
        MOVE    PC, PUTS        ; ... and jump: a subroutine call
        MOVE    @CONSOLE, 10    ; a newline
        HALT

; PUTS prints the string at R1. The string ends with a 0 word.
PUTS    MOVE[M] R2, @R1++       ; next character, and set Z if it is 0
    ?Z  MOVE    PC, @SP++       ; at the end: return
        MOVE    @CONSOLE, R2    ; print the character
        MOVE    PC, PUTS        ; and loop

TEXT    .ASCII_L 'Hello from the ROM!'
