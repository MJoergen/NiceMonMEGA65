; The program of the ROM in the tests: it prints a greeting and halts, like
; hello.nasm of nice_cpu. Its stack is at the top of the memory, as the
; runtime's is (start.nasm), which is RAM. hello.nasm's stack at 0x1000 is
; in the ROM on the board, where a push is dropped and the return address
; reads back as 0, so that program restarts forever.
;
; The ROM of tb_nicemon has 2K words, so BASIC's half, which takes the
; core's writes until the lock (issue #153), is 0x400-0x7FF. PUTS runs
; from there, so a fetch from it, which does not close the lock, comes
; first. Then the program adds 1 to the word at 0x7FF, and reads it back
; right behind the write, to RESULT; writes word 0 back to itself, which
; closes the lock; and adds 1 to the word at 0x7FE, which is dropped, and
; reads it back to RESULT+1. At the first start the ROM has 0 and
; 0x5A5A0000 there, and RESULT and RESULT+1 get 1 and 0x5A5A0000; at any
; later start the lock is closed, so they get 1 and 0x5A5A0000 again.
SP              .EQU    R13
CONSOLE         .EQU    0xFFFFFF00
RESULT          .EQU    0x900           ; in the RAM above the ROM

                MOVE    SP, 0xFFFFFF00  ; the stack, at the top of the memory
                MOVE    R1, TEXT        ; the argument: the string's address
                CALL    PUTS            ; push the return address and jump
                MOVE    @CONSOLE, 10    ; a newline
                MOVE    R2, @0x7FF      ; BASIC's half takes the write
                ADD     R2, R2, 1
                MOVE    @0x7FF, R2
                MOVE    @RESULT, @0x7FF
                MOVE    @0, @0          ; the lock
                MOVE    R2, @0x7FE      ; the write is dropped
                ADD     R2, R2, 1
                MOVE    @0x7FE, R2
                MOVE    @RESULT+1, @0x7FE
                HALT

TEXT            .ASCII_L 'Hello from the ROM!'

; PUTS prints the string at R1. The string ends with a 0 word.
                .ORG    0x400
PUTS            MOVE[M] R2, @R1++       ; next character, and set Z if it is 0
        ?Z      RET                     ; at the end: return
                MOVE    @CONSOLE, R2    ; print the character
                JMP     PUTS            ; and loop

                .ORG    0x7FE
                .DAT    0x5A5A0000, 0
