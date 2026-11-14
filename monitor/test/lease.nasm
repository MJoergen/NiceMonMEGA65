; The test of the DHCP lease's renewal in net_poll (issue #111), which
; test/lease.py runs under the monitor of the tests in niceemu with
; --step-time, --eth-in, and --eth-out, one case a run, the case's number
; in the word at LT_CASE. The step is a microsecond, so a run counts the
; same each time. The Makefile assembles it after the monitor's sources,
; as for tcpt.nasm, so that it reaches the variables by name.
;
; The program sets 10.0.0.9, takes a lease with net_dhcp, opens the UDP
; endpoint, which keeps the network on, and polls for the case's time,
; waiting for the timer's request with WAIT between the polls, through a
; vector table of its own at LT_VEC, which niceemu jumps over at once. It
; notes the microseconds since net_dhcp returned whenever V_IPID shows
; that a frame was sent. Its results, at LT_RES, 16 words:
;
;  0  net_dhcp, 0
;  1  udp_open of port 5000, 5000
;  2  V_LEASE, 1, a lease kept
;  3  the times of the frames sent, LT_SENDS words, 0 for none
; 11  the frames sent
; 12  V_LEASE at the end
; 13  the IP address at the end
; 14  udp_close, 0
; 15  ETH_CSR, 0, the port disabled
;
; It returns the number of results, 16.

                .ORG    0x8000
LT_CASE         .EQU    0x9000          ; the case, which lease.py writes
LT_RES          .EQU    0x9100          ; the results, a word each
LT_VEC          .EQU    0x9200          ; the vector table, VBASE 0x92
LT_V            .EQU    0x41            ; the timer's vector
LT_IRQ          .EQU    0xFFFFFF12      ; the timer's vector register
LT_TICK         .EQU    100000          ; the period of the polls, 100 ms
LT_SENDS        .EQU    8               ; the times of frames sent noted

lt_main
                MOVE    R7, LT_RES
                MOVE    R1, LT_RES
:
                MOVE    @R1++, 0
                CMP     R1, LT_RES+16
        ?!Z     JMP     :-
                MOVE    @LT_VEC+LT_V, lt_isr
                MOVE    @LT_IRQ, LT_V
                MOVE    @TIMER, LT_TICK
                AND     R14, R14, 0xFF000000
                OR      R14, R14, 0x40000092  ; E = 1, VBASE LT_VEC / 256
                MOVE    R1, LT_SET
                CALL    _net_set
                CALL    _net_dhcp
                MOVE    @R7++, R1       ; 0
                MOVE    R10, @io.us     ; the start of the times
                MOVE    R1, 5000
                CALL    _udp_open
                MOVE    @R7++, R1       ; 5000
                MOVE    @R7++, @V_LEASE  ; 1
                MOVE    R8, R7          ; the next time noted
                MOVE    R11, @V_IPID    ; the identification seen last
                MOVE    R12, 0          ; the frames sent
                SUB     R1, @LT_CASE, 1
                MOVE    R9, @LT_TIMES[R1]
:
                WAIT
                CALL    _net_poll
                CMP     @V_IPID, R11
        ?Z      JMP     :+
                MOVE    R11, @V_IPID
                ADD     R12, R12, 1
                CMP     R8, LT_RES+3+LT_SENDS
        ?Z      JMP     :+              ; no room
                SUB     @R8++, @io.us, R10
:
                SUB     R1, @io.us, R10
                CMP     R1, R9
        ?C      JMP     :--
                ADD     R7, R7, LT_SENDS
                MOVE    @R7++, R12
                MOVE    @R7++, @V_LEASE
                MOVE    @R7++, @E_IP
                CALL    _udp_close
                MOVE    @R7++, R1       ; 0
                MOVE    @TIMER, 0
                AND     R14, R14, 0xBF000000  ; E = 0, VBASE 0
                MOVE    @R7++, @ETH_CSR  ; 0
                SUB     R1, R7, LT_RES
                RET

lt_isr
                RTI

; The microseconds that each case polls for, from net_dhcp's return
LT_TIMES
                .DAT    230000000, 60000000, 120000000, 1560000000, 30000000
LT_SET          .DAT    0x0A000009, 0xFFFFFF00, 0, 0  ; 10.0.0.9
