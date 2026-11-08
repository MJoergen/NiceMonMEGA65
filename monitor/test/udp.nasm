; The test of the UDP entries, udp_open, udp_send, udp_recv, and
; udp_close, of table 1.3 (README.md, "The network"). The Makefile
; assembles this program after the sources of the monitor, as for
; arp.nasm, so that it reaches the variables V_MASK and V_GW by name, and
; runs it under the monitor of the tests with the frames of test/udp.eth,
; which wait for the frames sent, and --step-time. The program stores the
; result of each call at UDT_RESULTS, which the test dumps, with the bytes
; and the sources that udp_recv wrote; the frames sent are compared too.
;
;  0  udp_send before udp_open, -42, not open
;  1  udp_recv before udp_open, -42
;  2  udp_open with no IP address, -40
;  3  udp_open of port 0x10000, -41, after 10.0.0.9 is set
;  4  udp_open of port 5000, 5000
;  5  udp_send to port 0, -41
;  6  udp_send of 1473 bytes, -43, too long
;  7  udp_send of hello to 10.0.0.2 port 7, 0, after an ARP request and
;     its reply: frames 1 and 2
;  8  udp_send of hi to 255.255.255.255 port 9, 0, with no ARP: frame 3
;  9  udp_recv of up to 100 bytes, 6, world! from 10.0.0.2 port 7 at
;     UDT_BUF and UDT_SRC, after the frames that are no datagram for it:
;     the queue's 4 frames, which udp_recv releases
; 10  udp_send of hi to 255.255.255.255 port 9 again, 0: frame 4
; 11  udp_recv of up to 0 bytes, 0, which copies nothing and leaves the
;     queue as it is, so that the next call gets its datagram
; 12  udp_recv of up to 2 bytes, 2, ab of the broadcast of 10.0.0.3 port
;     9 at UDT_BUF2 and UDT_SRC2, after an ARP request and an empty
;     datagram
; 13  udp_recv, 0, as no datagram waits
; 14  udp_send of q to 8.8.8.8 port 53, 0, with the mask 255.255.255.0 and
;     the gateway 10.0.0.1: an ARP request for the gateway, its reply, and
;     the datagram to the gateway's MAC address, frames 5 and 6
; 15  udp_send of x to 10.0.0.2 port 7, 0, in the network, from the ARP
;     cache: frame 7
; 16  udp_send to 8.8.8.8 without a gateway, -44, with no frame
; 17  udp_send to 10.0.0.99, -44, after ARP_TRIES requests with no reply,
;     frames 8 to 10
; 18  udp_close, 0
; 19  udp_recv after udp_close, -42
;
; It returns the number of results, 20.

                .ORG    0x8000
UDT_RESULTS     .EQU    0x9100
UDT_BUF         .EQU    0x9180          ; the bytes of result 9
UDT_SRC         .EQU    0x9188          ; and its source
UDT_BUF2        .EQU    0x918A          ; the bytes of result 12
UDT_SRC2        .EQU    0x918C          ; and its source

udt_main
                MOVE    R7, UDT_RESULTS
                MOVE    @E_IP, 0
                MOVE    R1, 0x0A000002
                MOVE    R2, 7
                MOVE    R3, UDT_HELLO
                MOVE    R4, 5
                CALL    _udp_send
                MOVE    @R7++, R1
                MOVE    R1, UDT_BUF
                MOVE    R2, 100
                MOVE    R3, UDT_SRC
                CALL    _udp_recv
                MOVE    @R7++, R1
                MOVE    R1, 0
                CALL    _udp_open
                MOVE    @R7++, R1
                MOVE    @E_IP, 0x0A000009  ; 10.0.0.9
                MOVE    R1, 0x10000
                CALL    _udp_open
                MOVE    @R7++, R1
                MOVE    R1, 5000
                CALL    _udp_open
                MOVE    @R7++, R1
; Sends
                MOVE    R1, 0x0A000002
                MOVE    R2, 0
                MOVE    R3, UDT_HELLO
                MOVE    R4, 5
                CALL    _udp_send
                MOVE    @R7++, R1
                MOVE    R1, 0x0A000002
                MOVE    R2, 7
                MOVE    R3, UDT_HELLO
                MOVE    R4, UDP_MAX+1
                CALL    _udp_send
                MOVE    @R7++, R1
                MOVE    R1, 0x0A000002
                MOVE    R2, 7
                MOVE    R3, UDT_HELLO
                MOVE    R4, 5
                CALL    _udp_send
                MOVE    @R7++, R1
                MOVE    R1, 0xFFFFFFFF
                MOVE    R2, 9
                MOVE    R3, UDT_HI
                MOVE    R4, 2
                CALL    _udp_send
                MOVE    @R7++, R1
; Receives
                MOVE    R1, UDT_BUF
                MOVE    R2, 100
                MOVE    R3, UDT_SRC
                CALL    _udp_recv
                MOVE    @R7++, R1
                MOVE    R1, 0xFFFFFFFF
                MOVE    R2, 9
                MOVE    R3, UDT_HI
                MOVE    R4, 2
                CALL    _udp_send
                MOVE    @R7++, R1
                MOVE    R1, UDT_BUF2
                MOVE    R2, 0
                MOVE    R3, UDT_SRC2
                CALL    _udp_recv
                MOVE    @R7++, R1
                MOVE    R1, UDT_BUF2
                MOVE    R2, 2
                MOVE    R3, UDT_SRC2
                CALL    _udp_recv
                MOVE    @R7++, R1
                MOVE    R1, UDT_BUF2
                MOVE    R2, 2
                MOVE    R3, 0
                CALL    _udp_recv
                MOVE    @R7++, R1
; Through the gateway, in the network, and with no route
                MOVE    @V_MASK, 0xFFFFFF00
                MOVE    @V_GW, 0x0A000001
                MOVE    R1, 0x08080808
                MOVE    R2, 53
                MOVE    R3, UDT_Q
                MOVE    R4, 1
                CALL    _udp_send
                MOVE    @R7++, R1
                MOVE    R1, 0x0A000002
                MOVE    R2, 7
                MOVE    R3, UDT_X
                MOVE    R4, 1
                CALL    _udp_send
                MOVE    @R7++, R1
                MOVE    @V_GW, 0
                MOVE    R1, 0x08080808
                MOVE    R2, 53
                MOVE    R3, UDT_Q
                MOVE    R4, 1
                CALL    _udp_send
                MOVE    @R7++, R1
                MOVE    R1, 0x0A000063
                MOVE    R2, 7
                MOVE    R3, UDT_Q
                MOVE    R4, 1
                CALL    _udp_send
                MOVE    @R7++, R1
                CALL    _udp_close
                MOVE    @R7++, R1
                MOVE    R1, UDT_BUF
                MOVE    R2, 100
                MOVE    R3, UDT_SRC
                CALL    _udp_recv
                MOVE    @R7++, R1
                SUB     R1, R7, UDT_RESULTS
                RET

UDT_HELLO
                .DAT    0x68, 0x65, 0x6C, 0x6C, 0x6F  ; hello
UDT_HI          .DAT    0x168, 0x269    ; hi, with bits above 7..0, which are not sent
UDT_Q           .DAT    0x71            ; q
UDT_X           .DAT    0x78            ; x
