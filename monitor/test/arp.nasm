; The test of the ARP cache, arp_resolve, which has no entry in the
; dispatch table (README.md). The Makefile assembles this program after the
; sources of the monitor, as for sd.nasm, so that it calls the routines by
; their labels, and runs it under the monitor of the tests with the frames
; of test/arp.eth, which wait for the requests sent. The program stores
; R1, R2, and R3 of each call at ART_RESULTS, which the test dumps:
; 10.0.0.1, which replies after a UDP broadcast and a request of its own,
; which are not learned, so 0 and 0A:00:00:00:00:01; 10.0.0.1 again, from
; the cache, with no request; 10.0.0.2, which never replies, -1 after
; ARP_TRIES requests; 10.0.0.1 once more, with its entry made ARP_AGE ticks
; older, so that a request goes out, and the reply has a new address,
; 0A:00:00:00:00:11; and 10.0.0.3 to 10.0.0.6, which fill the cache and go
; round it. Then it copies the cache without its times, which change with
; the steps, and V_ARPNEXT. The frames sent, ARP_TRIES + 7 requests, are
; compared too.

                .ORG    0x8000
ART_RESULTS     .EQU    0x9100

art_main
                MOVE    R7, ART_RESULTS
                MOVE    @E_IP, 0x0A000009  ; 10.0.0.9
                CALL    eth_on
                MOVE    R1, 0x0A000001
                CALL    art_resolve
                MOVE    R1, 0x0A000001
                CALL    art_resolve
                MOVE    R1, 0x0A000002
                CALL    art_resolve
                SUB     @V_ARP+3, @V_ARP+3, ARP_AGE
                MOVE    R1, 0x0A000001
                CALL    art_resolve
                MOVE    R8, 0x0A000003
art_fill
                MOVE    R1, R8
                CALL    art_resolve
                ADD     R8, R8, 1
                CMP     R8, 0x0A000007
        ?!Z     JMP     art_fill
                MOVE    R1, V_ARP
art_copy
                MOVE    @R7++, @R1++    ; the IP address and the MAC address
                MOVE    @R7++, @R1++
                MOVE    @R7++, @R1++
                ADD     R1, R1, 1       ; but not the time
                CMP     R1, V_ARP+4*ARP_SLOTS
        ?!Z     JMP     art_copy
                MOVE    @R7++, @V_ARPNEXT
                MOVE    R1, 0
                RET

; art_resolve: arp_resolve of R1, and its results stored at R7
art_resolve
                CALL    arp_resolve
                TST     R1
        ?!Z     MOVE    R2, 0           ; no address
        ?!Z     MOVE    R3, 0
                MOVE    @R7++, R1
                MOVE    @R7++, R2
                MOVE    @R7++, R3
                RET
