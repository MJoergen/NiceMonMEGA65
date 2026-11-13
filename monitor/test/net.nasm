; The test of the poll and the IP settings of issue #111: net_config,
; net_set, and net_poll, the entries 21, 22, and 24, and the datagram that
; the poll holds for the UDP endpoint. The Makefile assembles this program
; after the sources of the monitor, as for udp.nasm, so that it reaches
; the variables by name, and runs it under the monitor of the tests with
; the frames of test/net.eth, which wait for the frames sent, and
; --step-time. The identification of the packets starts at 0x1000, so that
; the frames sent do not change with the steps of the code. The program
; stores the result of each call at NTT_RESULTS, which the test dumps,
; with the words of net_config and the bytes and the sources that
; udp_recv wrote; the frames sent are compared too.
;
;  0  net_config at the word-window address of NTT_CFG, 0, and the four
;     words 0, over 0xEEEEEEEE, as the cold start set none
;  1  net_set of 10.0.0.9, the mask 255.255.255.0, the gateway 10.0.0.1,
;     and the DNS server 10.0.0.53, 0
;  2  net_config at NTT_CFG+4, a plain address, 0, and the four of net_set
;  3  net_poll with the port disabled, 0
;  4  udp_open of port 5000, 5000
;  5  udp_send of hi to 255.255.255.255 port 9, 0: frame 1. Then come an
;     ARP reply of 10.0.0.2, which no one asked for, the datagrams one and
;     two of 10.0.0.2 port 7, and a TCP segment
;  6  net_poll, 0, which takes the four
;  7  the bytes of the datagram held, 3, one
;  8  ETH_RX_LEN, 0, the queue empty
;  9  udp_recv of up to 100 bytes, 3, one from 10.0.0.2 port 7
; 10  udp_recv, 0, as two came while one was held, and was dropped
; 11  udp_send of x to 10.0.0.2 port 7, 0, from the ARP reply that the poll
;     learned in place, with no request: frame 2. Then come the datagram
;     three, an ARP reply of 10.0.0.3, and the datagram four
; 12  udp_send of y to 10.0.0.3 port 7, 0, which polls first, and so
;     learns 10.0.0.3, with no request: frame 3
; 13  udp_recv, 5, three, held by the poll of udp_send
; 14  udp_recv, 0, as four was dropped
; 15  V_NARM after a poll with a deadline a second ahead, 1, still armed
; 16  V_NARM after a poll with a deadline a microsecond past, 0, done
; 17  udp_close, 0
; 18  ETH_CSR, 0, the port disabled
; 19  net_poll, 0
;
; It returns the number of results, 20.

                .ORG    0x8000
NTT_RESULTS     .EQU    0x9100
NTT_CFG         .EQU    0x9180          ; the words of results 0 and 2
NTT_BUF         .EQU    0x9190          ; the bytes of result 9
NTT_SRC         .EQU    0x9193          ; and its source
NTT_BUF2        .EQU    0x9195          ; the bytes of result 13
NTT_SRC2        .EQU    0x919A          ; and its source

ntt_main
                MOVE    R7, NTT_RESULTS
                MOVE    @V_IPID, 0x1000
                MOVE    R1, NTT_CFG
:
                MOVE    @R1++, 0xEEEEEEEE
                CMP     R1, NTT_CFG+8
        ?!Z     JMP     :-
                MOVE    R1, 0x10000000+4*NTT_CFG
                CALL    _net_config
                MOVE    @R7++, R1
                MOVE    R1, NTT_SET
                CALL    _net_set
                MOVE    @R7++, R1
                MOVE    R1, NTT_CFG+4
                CALL    _net_config
                MOVE    @R7++, R1
                CALL    _net_poll
                MOVE    @R7++, R1
                MOVE    R1, 5000
                CALL    _udp_open
                MOVE    @R7++, R1
                MOVE    R1, 0xFFFFFFFF
                MOVE    R2, 9
                MOVE    R3, NTT_HI
                MOVE    R4, 2
                CALL    _udp_send
                MOVE    @R7++, R1
; The poll, and the datagram held
                CALL    _net_poll
                MOVE    @R7++, R1
                MOVE    @R7++, @V_ULEN
                MOVE    @R7++, @ETH_RX_LEN
                MOVE    R1, NTT_BUF
                MOVE    R2, 100
                MOVE    R3, NTT_SRC
                CALL    _udp_recv
                MOVE    @R7++, R1
                MOVE    R1, NTT_BUF
                MOVE    R2, 100
                MOVE    R3, 0
                CALL    _udp_recv
                MOVE    @R7++, R1
; The ARP replies learned in place
                MOVE    R1, 0x0A000002
                MOVE    R2, 7
                MOVE    R3, NTT_X
                MOVE    R4, 1
                CALL    _udp_send
                MOVE    @R7++, R1
                MOVE    R1, 0x0A000003
                MOVE    R2, 7
                MOVE    R3, NTT_Y
                MOVE    R4, 1
                CALL    _udp_send
                MOVE    @R7++, R1
                MOVE    R1, NTT_BUF2
                MOVE    R2, 100
                MOVE    R3, NTT_SRC2
                CALL    _udp_recv
                MOVE    @R7++, R1
                MOVE    R1, NTT_BUF2
                MOVE    R2, 100
                MOVE    R3, 0
                CALL    _udp_recv
                MOVE    @R7++, R1
; The deadline
                CALL    net_clock
                ADD     @V_NDUE, R1, 1000000
                MOVE    @V_NARM, 1
                CALL    _net_poll
                MOVE    @R7++, @V_NARM
                CALL    net_clock
                SUB     @V_NDUE, R1, 1
                CALL    _net_poll
                MOVE    @R7++, @V_NARM
                CALL    _udp_close
                MOVE    @R7++, R1
                MOVE    @R7++, @ETH_CSR
                CALL    _net_poll
                MOVE    @R7++, R1
                SUB     R1, R7, NTT_RESULTS
                RET

NTT_SET         .DAT    0x0A000009, 0xFFFFFF00, 0x0A000001, 0x0A000035
NTT_HI          .DAT    0x68, 0x69      ; hi
NTT_X           .DAT    0x78            ; x
NTT_Y           .DAT    0x79            ; y
