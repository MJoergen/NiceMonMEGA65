; The test of TCP's timers (issue #111), which tools/tcptest.py runs with
; --timers under the monitor of the tests in niceemu with --step-time,
; --eth-in, and --eth-out, one case a run, the case's number in the word
; at TW_CASE. The step is a microsecond, so a run counts the same each
; time, and tcptest.py runs a case again with the answers to the frames
; that the last run sent, until it needs no new one. The Makefile
; assembles it after the monitor's sources, as for tcp.nasm.
;
; Between its polls the program waits for the timer's request with WAIT,
; through a vector table of its own at TW_VEC, which niceemu jumps over
; at once, so that minutes of the board's time take a second or two.

                .ORG    0x8000
TW_CASE         .EQU    0x9000          ; the case, which tcptest.py writes
TW_RES          .EQU    0x9100          ; the results, a word each
TW_VEC          .EQU    0x9200          ; the vector table, VBASE 0x92
TW_V            .EQU    0x41            ; the timer's vector
TW_CB           .EQU    0xA000          ; the control block
TW_TXB          .EQU    0x20000000+4*0x10000  ; the bytes to send
TW_RXB          .EQU    0x20000000+4*0x14000  ; the bytes received
TW_PEER         .EQU    0x0A000002      ; tcppeer.py's address
TW_TICK         .EQU    10000           ; the period of the polls, 10 ms
TW_IRQ          .EQU    0xFFFFFF12      ; the timer's vector

tw_main
                MOVE    R7, TW_RES
                MOVE    @TW_VEC+TW_V, tw_isr
                MOVE    @TW_IRQ, TW_V
                MOVE    @TIMER, TW_TICK
                AND     R14, R14, 0xFF000000
                OR      R14, R14, 0x40000092  ; E = 1, VBASE TW_VEC / 256
                MOVE    R1, TW_SET
                CALL    _net_set
                CMP     @TW_CASE, 6
        ?Z      JMP     tw_listen
                MOVE    R1, TW_CB
                MOVE    R2, TW_PEER
                ADD     R3, @TW_CASE, 2100
                MOVE    R4, 0x04000400
                CALL    _tcp_open
                MOVE    @R7++, R1
                MOVE    R8, R1
                MOVE    R1, @TW_CASE
                SUB     R1, R1, 1
                CMP     R1, 5
        ?!C     JMP     tw_end
                MOVE    R15, @TW_CASES[R1]

TW_CASES
                .DAT    tw_syn, tw_data, tw_fin2, tw_zero, tw_idle
TW_SET          .DAT    0x0A000009, 0xFFFFFF00, 0, 0

; Case 1, port 2101: no answer to the SYN; the state and the time to it
tw_syn
                MOVE    R1, 2
                MOVE    R2, 30000000
                CALL    tw_until
                MOVE    @R7++, R1       ; E_TTIMEOUT
                MOVE    @R7++, R2       ; 15 seconds
                JMP     tw_close

; Case 2, port 2102: 100 bytes, which the peer never acknowledges
tw_data
                CALL    tw_open
                MOVE    R1, R8
                MOVE    R2, TW_TXB
                MOVE    R3, 100
                CALL    _tcp_send
                MOVE    @R7++, R1       ; 100
                MOVE    R1, 99
                MOVE    R2, 300000000
                CALL    tw_until
                MOVE    @R7++, R1       ; E_TTIMEOUT
                MOVE    @R7++, R2       ; the time
                JMP     tw_close

; Case 3, port 2103: a close, whose FIN the peer acknowledges, with no FIN
; of its own
tw_fin2
                CALL    tw_open
                MOVE    R1, R8
                MOVE    R2, 0
                CALL    _tcp_close
                MOVE    @R7++, R1       ; 0
                MOVE    R1, 0
                MOVE    R2, 300000000
                CALL    tw_until
                MOVE    @R7++, R1       ; 0, TCP_FREE
                MOVE    @R7++, R2       ; 60 seconds
                JMP     tw_end

; Case 4, port 2104: 100 bytes to a peer whose window is 0, which answers
; the probes for a while, and then no more
tw_zero
                CALL    tw_open
                MOVE    R1, R8
                MOVE    R2, TW_TXB
                MOVE    R3, 100
                CALL    _tcp_send
                MOVE    @R7++, R1       ; 100
                MOVE    R1, 99
                MOVE    R2, 0x7FFFFFFF
                CALL    tw_until
                MOVE    @R7++, R1       ; E_TTIMEOUT
                MOVE    @R7++, R2       ; the time
                JMP     tw_close

; Case 5, port 2105: idle for 4300 seconds, across a wrap of the 32 bits
; of the microseconds, then 10 bytes echoed
tw_idle
                CALL    tw_open
                MOVE    @TIMER, 1000000
                MOVE    R1, 2150000000
                CALL    tw_sleep
                MOVE    R1, 2150000000
                CALL    tw_sleep
                MOVE    @TIMER, TW_TICK
                MOVE    R1, R8
                CALL    _tcp_state
                MOVE    @R7++, R1       ; 2, TCP_OPEN
                MOVE    R1, R8
                MOVE    R2, TW_TXB
                MOVE    R3, 10
                CALL    _tcp_send
                MOVE    @R7++, R1       ; 10
                MOVE    R1, 1000000
                CALL    tw_sleep
                MOVE    R1, R8
                MOVE    R2, TW_RXB
                MOVE    R3, 100
                CALL    _tcp_recv
                MOVE    @R7++, R1       ; 10
                MOVE    R1, R8
                CALL    _tcp_state
                MOVE    @R7++, R1       ; 2
                JMP     tw_close

; Case 6, port 2106: a handle that listens, whose SYN-ACK the peer never
; acknowledges; the state, and the time to TCP_LISTEN again; a close
tw_listen
                MOVE    R1, TW_CB
                MOVE    R2, 2106
                MOVE    R3, 0x04000400
                CALL    _tcp_listen
                MOVE    @R7++, R1       ; 0
                MOVE    R8, R1
                MOVE    R1, 1
                MOVE    R2, 10000000
                CALL    tw_until
                MOVE    @R7++, R1       ; 1, TCP_CONNECTING
                MOVE    R1, 5
                MOVE    R2, 30000000
                CALL    tw_until
                MOVE    @R7++, R1       ; 5, TCP_LISTEN
                MOVE    @R7++, R2       ; 15 seconds
                MOVE    R1, R8
                MOVE    R2, 0
                CALL    _tcp_close
                MOVE    @R7++, R1       ; 0
                JMP     tw_end
tw_close
                MOVE    R1, R8
                MOVE    R2, 1
                CALL    _tcp_close
                MOVE    @R7++, R1       ; 0
tw_end
                MOVE    @TIMER, 0
                AND     R14, R14, 0xBF000000  ; E = 0, VBASE 0
                MOVE    @R7++, @ETH_CSR  ; 0, the port disabled
                SUB     R1, R7, TW_RES
                RET

tw_isr
                RTI

; tw_open: tw_until of R8 for TCP_OPEN, within 10 seconds; the state is
; stored. Uses R1-R6.
tw_open
                MOVE    R1, 2
                MOVE    R2, 10000000
                CALL    tw_until
                MOVE    @R7++, R1
                RET

; tw_until: polls R8 with tcp_state, waiting between the polls, until
; its state is R1, or negative, or R2 microseconds passed. R1 = the last
; state, and R2 the microseconds. Uses R1-R6, and R9-R11, saved.
tw_until
                PUSH    R9
                PUSH    R10
                PUSH    R11
                MOVE    R9, R1
                MOVE    R10, R2
                MOVE    R11, @io.us
:
                WAIT
                MOVE    R1, R8
                CALL    _tcp_state
                CMP     R1, R9
        ?Z      JMP     :+
                TST     R1
        ?N      JMP     :+
                SUB     R2, @io.us, R11
                CMP     R2, R10
        ?C      JMP     :-
:
                SUB     R2, @io.us, R11
                POP     R11
                POP     R10
                POP     R9
                RET

; tw_sleep: R1 microseconds, below 2^31, with a poll after each wait. Uses
; R1-R6, and R9-R10, saved.
tw_sleep
                PUSH    R9
                PUSH    R10
                MOVE    R9, R1
                MOVE    R10, @io.us
:
                WAIT
                CALL    _net_poll
                SUB     R1, @io.us, R10
                CMP     R1, R9
        ?C      JMP     :-
                POP     R10
                POP     R9
                RET
