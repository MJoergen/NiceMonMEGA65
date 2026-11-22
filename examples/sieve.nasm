; SIEVE.BIN: the sieve of Eratosthenes, as BYTE's benchmark has it, in
; machine code that a BASIC program calls with SYS, beside it in the
; RAM (sieve.bas, and basic/README.md, "Machine code beside a program").
;
; The program sets HIMEM = 0xC000, so that BASIC keeps below 0xC000, and
; loads this file, all of whose words are at 0xC000 or above, so the
; program goes on after the LOAD. 0xC000 to 0xE3FF is the room between
; that HIMEM and the stack's room on both boards, the MEGA65 and the
; Nexys4DDR. The program POKEs the size to 0xC000, calls SYS 0xC002, and
; PEEKs the number of primes at 0xC001.
;
; The flags are a word each, from FLAGS. Flag i stands for the odd
; number i + i + 3, and the sieve counts the primes among them, 1899 for
; the size 8190, as BYTE's benchmark does. A size above MAX_SIZE, whose
; flags would reach the stack, is not sieved, and the count is -1.
;
; It returns 0 with RET, so that SYS prints Returned 00000000 and the
; program goes on, and keeps R7 to R13, as the C ABI asks, as BASIC's
; own registers are there. Uses R1-R6: R1 the count, R2 the flag that is
; struck out, R3 the flag of the number that is tested, R4 the last
; flag, and R6 the prime.

FLAGS           .EQU    0xC100          ; the flags, up to 0xE3FF
MAX_SIZE        .EQU    0xE3FF-FLAGS    ; 8959

                .ORG    0xC000
                .DAT    8190            ; 0xC000: the size, which the program POKEs
                .DAT    0               ; 0xC001: the count, which it PEEKs
sieve                                   ; 0xC002, which SYS calls
                MOVE    R1, -1          ; the count of a size too big
                MOVE    R4, @0xC000
                CMP     R4, MAX_SIZE+1
        ?!C     JMP     sv_end          ; too big
                ADD     R4, R4, FLAGS   ; the last flag
                MOVE    R3, FLAGS
:               ONE     @R3++           ; every flag set
                CMP     R4, R3
        ?!C     JMP     :-
                CLR     R1
                MOVE    R3, FLAGS
sv_test
                TST     @R3
        ?Z      JMP     sv_next         ; struck out: not a prime
                ADD     R1, R1, 1
                SUB     R6, R3, FLAGS
                ADD     R6, R6, R6
                ADD     R6, R6, 3       ; the prime, i + i + 3
                ADD     R2, R3, R6
sv_strike
                CMP     R4, R2
        ?C      JMP     sv_next         ; past the last flag
                CLR     @R2             ; a multiple of the prime
                ADD     R2, R2, R6
                JMP     sv_strike
sv_next
                ADD     R3, R3, 1
                CMP     R4, R3
        ?!C     JMP     sv_test
sv_end
                MOVE    @0xC001, R1
                CLR     R1              ; the status
                RET
