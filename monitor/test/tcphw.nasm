; The board's test of TCP (issue #111), a program at 0x8000 under the
; ROM's monitor that calls the entries through the stubs of mon.nasm,
; which the Makefile joins after it. tools/hwtest.py loads it with the
; words at TH_ARGS, its PC's IP address, the port where the PC listens,
; and the number of bytes, at most 65536, and runs it with run.py
; --monitor. With the IP address 0, the program listens on the port
; instead, and the PC connects. The program connects, or waits for the
; PC, sends the bytes, byte i being
; 7 i + i / 256 modulo 256, receives what the PC echoes, compares, closes,
; and waits for the handle to free itself. It returns 0, or the step that
; failed times 1000, less the error, as test/tcp_c.c does, and keeps R7
; to R13, as the C ABI asks.

                .ORG    0x8000
TH_ARGS         .EQU    0x9000          ; the IP address, the port, and the bytes
TH_CB           .EQU    0xA000          ; the control block, 32 + 512 + 512 words
TH_TX           .EQU    0x20000000+4*0x10000  ; the bytes to send
TH_RX           .EQU    0x20000000+4*0x14000  ; the bytes received
TH_US           .EQU    0xFFFFFF44      ; the microseconds since reset
TH_LIMIT        .EQU    20000000        ; the longest a step may take

th_main
                PUSH    R7
                PUSH    R8
                PUSH    R9
                PUSH    R10
                PUSH    R11
                MOVE    R1, @TH_ARGS+2  ; the pattern
                MOVE    R2, TH_TX
                MOVE    R3, 0
:
                CMP     R3, R1
        ?Z      JMP     :+
                SHR     R4, R3, 8
                SHL     R5, R3, 3
                SUB     R5, R5, R3      ; 7 i
                ADD     @R2++, R4, R5   ; a byte window takes the low byte
                ADD     R3, R3, 1
                JMP     :-
:
                MOVE    R1, TH_CB
                MOVE    R2, @TH_ARGS
                MOVE    R3, @TH_ARGS+1
                MOVE    R4, 0x08000800
                TST     R2
        ?Z      JMP     :+
                CALL    _tcp_open
                JMP     :++
:
                MOVE    R2, R3          ; listen on the port
                MOVE    R3, R4
                CALL    _tcp_listen
:
                MOVE    R7, 1000
                TST     R1
        ?N      JMP     th_fail
                MOVE    R8, R1          ; the handle
                MOVE    R7, 2000
                MOVE    R2, 2
                CALL    th_wait
                CMP     R1, 2
        ?!Z     JMP     th_fail
; Send and receive, by turns, until every byte is back
                MOVE    R9, 0           ; sent
                MOVE    R10, 0          ; received
                MOVE    R11, @TH_US
th_loop
                MOVE    R7, 3000
                MOVE    R1, R8
                ADD     R2, R9, TH_TX
                SUB     R3, @TH_ARGS+2, R9
                CALL    _tcp_send
                TST     R1
        ?N      JMP     th_fail
                ADD     R9, R9, R1
                MOVE    R7, 4000
                MOVE    R1, R8
                ADD     R2, R10, TH_RX
                SUB     R3, @TH_ARGS+2, R10
                CALL    _tcp_recv
                TST     R1
        ?N      JMP     th_fail
                ADD     R10, R10, R1
                CMP     R10, @TH_ARGS+2
        ?Z      JMP     :+
                MOVE    R7, 5000
                MOVE    R1, 0
                SUB     R2, @TH_US, R11
                CMP     R2, TH_LIMIT
        ?C      JMP     th_loop
                JMP     th_fail
:
; Compare
                MOVE    R7, 6000
                MOVE    R1, 0
                MOVE    R2, TH_TX
                MOVE    R3, TH_RX
                MOVE    R4, @TH_ARGS+2
:
                SUB[M]  R4, R4, 1
        ?C      JMP     :+
                CMP     @R2++, @R3++
        ?Z      JMP     :-
                JMP     th_fail
:
; Close, and wait for the handle to free itself
                MOVE    R7, 7000
                MOVE    R1, R8
                MOVE    R2, 0
                CALL    _tcp_close
                TST     R1
        ?!Z     JMP     th_fail
                MOVE    R7, 8000
                MOVE    R2, 0
                CALL    th_wait
                TST     R1
        ?!Z     JMP     th_fail
                MOVE    R7, 0
; th_fail: R1 = R7 less R1, the step and the error, and R7 to R11 back
th_fail
                SUB     R1, R7, R1
                POP     R11
                POP     R10
                POP     R9
                POP     R8
                POP     R7
                RET

; th_wait: polls the handle R8 with tcp_state until its state is R2, or
; negative, or TH_LIMIT passed. R1 = the last state. Uses R1-R6, and
; R9-R10, saved.
th_wait
                PUSH    R9
                PUSH    R10
                MOVE    R9, R2
                MOVE    R10, @TH_US
:
                MOVE    R1, R8
                CALL    _tcp_state
                CMP     R1, R9
        ?Z      JMP     :+
                TST     R1
        ?N      JMP     :+
                SUB     R2, @TH_US, R10
                CMP     R2, TH_LIMIT
        ?C      JMP     :-
:
                POP     R10
                POP     R9
                RET
