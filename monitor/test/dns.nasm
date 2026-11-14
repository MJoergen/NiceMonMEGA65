; The test of dns_lookup, entry 25 (issue #111). The Makefile assembles
; this program after the sources of the monitor, as for net.nasm, so that
; it reaches the variables by name, and test/dns.py runs it under the
; monitor of the tests, with the frames that it builds from the queries of
; the run before. Each name is packed into DTT_NAME from byte 1, so that
; it starts at an odd byte, and dns_lookup writes the address to DTT_IP,
; which holds 0xEEEEEEEE before, given by its word-window address, but
; for the first lookup, which gives the plain address. Each lookup stores
; its result and the word of DTT_IP at DTT_RESULTS, which the test dumps;
; the other calls store their result alone:
;
;  0  1.2.3.4, with no IP address set: 0, and 0x01020304, with no query
;  2  example.com: E_NOIP, -40
;  4  net_set of 10.0.0.9, the mask 255.255.255.0, the gateway 10.0.0.1,
;     and no DNS server, 0
;  5  example.com: E_NODNS, -46
;  7  net_set of the DNS server 10.0.0.53, 0
;  8  the empty name, a..b, ., a label of 64 bytes, and a name of 254
;     bytes: E_DNSNAME, -48, each, with no frame sent
; 18  udp_open of port 5000, 5000
; 19  example.com.: 0, and 93.184.216.34, after an ARP request for
;     10.0.0.53 and its reply, and datagrams that are passed over: from
;     another address, from another port, with another ID, and with QR
;     clear
; 21  bit 0 of ETH_CSR, 1, as the endpoint keeps the port enabled
; 22  udp_close, 0
; 23  www.example.com: a CNAME before the A record, both with
;     compression pointers: 0, and 93.184.216.35
; 25  aaaa.example.com: an AAAA record, an A record of class CH, and the
;     A record: 0, and 10.1.2.3
; 27  nx.example.com: RCODE 3, E_DNSNAME, -48
; 29  fail.example.com: RCODE 2, E_DNSFAIL, -49
; 31  tc.example.com: TC set, E_DNSFAIL, -49
; 33  cname.example.com: a CNAME and no A record, E_DNSNAME, -48
; 35  loop.example.com: the record's name a pointer to itself, which is
;     skipped and not followed: 0, and 10.4.4.4
; 37  short.example.com: the answer ends in the A record's data,
;     E_DNSFAIL, -49
; 39  late.example.com: the answer only to the second query, which has
;     the same ID and port: 0, and 10.5.5.5
; 41  a name of 253 bytes, labels of 63, 63, 63, and 61: RCODE 3,
;     E_DNSNAME, -48, after a query with the whole name
; 43  net_set of the DNS server 8.8.8.8, in another network, 0
; 44  gw.example.com: 0, and 10.6.6.6, through the gateway, after its ARP
; 46  net_set of the DNS server 10.0.0.54, 0
; 47  noroute.example.com: E_NOROUTE, -44, after 3 ARP requests
; 49  net_set of the DNS server 10.0.0.53, 0
; 50  time.example.com: E_DNSTIME, -47, after 3 queries
; 52  ETH_CSR, 0, the port disabled
;
; It returns the number of results, 53.

                .ORG    0x8000
DTT_RESULTS     .EQU    0x9100
DTT_NAME        .EQU    0x9200          ; the name, packed, from byte 1
DTT_IP          .EQU    0x92FF          ; the address that dns_lookup writes

dtt_main
                MOVE    R7, DTT_RESULTS
                MOVE    R1, DTT_1234
                MOVE    R2, DTT_IP
                CALL    dtt_look2
                MOVE    R1, DTT_EX
                CALL    dtt_look
                MOVE    R1, DTT_SET
                CALL    dtt_set
                MOVE    R1, DTT_EX
                CALL    dtt_look
                MOVE    @DTT_SET+3, 0x0A000035
                MOVE    R1, DTT_SET
                CALL    dtt_set
                MOVE    R8, DTT_BAD
                CALL    dtt_list
                MOVE    R1, 5000
                CALL    _udp_open
                MOVE    @R7++, R1
                MOVE    R1, DTT_EXDOT
                CALL    dtt_look
                AND     @R7++, @ETH_CSR, ETH_ON
                CALL    _udp_close
                MOVE    @R7++, R1
                MOVE    R8, DTT_ANSWERS
                CALL    dtt_list
                MOVE    @DTT_SET+3, 0x08080808
                MOVE    R1, DTT_SET
                CALL    dtt_set
                MOVE    R1, DTT_GW
                CALL    dtt_look
                MOVE    @DTT_SET+3, 0x0A000036
                MOVE    R1, DTT_SET
                CALL    dtt_set
                MOVE    R1, DTT_NOROUTE
                CALL    dtt_look
                MOVE    @DTT_SET+3, 0x0A000035
                MOVE    R1, DTT_SET
                CALL    dtt_set
                MOVE    R1, DTT_TIME
                CALL    dtt_look
                MOVE    @R7++, @ETH_CSR
                SUB     R1, R7, DTT_RESULTS
                RET

; dtt_set: net_set of the 4 words at R1, and its result stored
dtt_set
                CALL    _net_set
                MOVE    @R7++, R1
                RET

; dtt_list: dtt_look of each name of the list at R8, up to a 0
dtt_list
                MOVE[M] R1, @R8++
        ?Z      RET
                CALL    dtt_look
                JMP     dtt_list

; dtt_look: dns_lookup of the name at R1, a character a word, packed to
; DTT_NAME from byte 1; a word of 0x100 + n is n bytes x. The address
; is given at DTT_IP's word-window address, or, from dtt_look2, at R2.
; Its result and DTT_IP stored.
dtt_look
                MOVE    R2, 0x10000000+4*DTT_IP
dtt_look2
                MOVE    R3, 0x20000000+4*DTT_NAME+1
:
                MOVE[M] R4, @R1++
        ?Z      JMP     :++
                CMP     R4, 0x100
        ?C      MOVE    @R3++, R4
        ?C      JMP     :-
                SUB     R4, R4, 0x100
:
                MOVE    @R3++, 0x78     ; x
                SUB[M]  R4, R4, 1
        ?!Z     JMP     :-
                JMP     :--
:
                MOVE    @R3, 0
                MOVE    @DTT_IP, 0xEEEEEEEE
                MOVE    R1, 0x20000000+4*DTT_NAME+1
                CALL    _dns_lookup
                MOVE    @R7++, R1
                MOVE    @R7++, @DTT_IP
                RET

DTT_SET         .DAT    0x0A000009, 0xFFFFFF00, 0x0A000001, 0
DTT_BAD         .DAT    DTT_EMPTY, DTT_DD, DTT_DOT, DTT_L64, DTT_N254, 0
DTT_ANSWERS
                .DAT    DTT_WWW, DTT_AAAA, DTT_NX, DTT_FAIL, DTT_TC, DTT_CNAME, DTT_LOOP
                .DAT    DTT_SHORT, DTT_LATE, DTT_N253, 0
DTT_1234
                .ASCII_L '1.2.3.4'
DTT_EX          .ASCII_L 'example.com'
DTT_EMPTY
                .DAT    0
DTT_DD          .ASCII_L 'a..b'
DTT_DOT         .ASCII_L '.'
DTT_L64         .DAT    0x140, 0x2E, 0x63, 0x6F, 0x6D, 0  ; 64 x, .com
DTT_N254
                .DAT    0x13F, 0x2E, 0x13F, 0x2E, 0x13F, 0x2E, 0x13E, 0
DTT_EXDOT
                .ASCII_L 'example.com.'
DTT_WWW         .ASCII_L 'www.example.com'
DTT_AAAA
                .ASCII_L 'aaaa.example.com'
DTT_NX          .ASCII_L 'nx.example.com'
DTT_FAIL
                .ASCII_L 'fail.example.com'
DTT_TC          .ASCII_L 'tc.example.com'
DTT_CNAME
                .ASCII_L 'cname.example.com'
DTT_LOOP
                .ASCII_L 'loop.example.com'
DTT_SHORT
                .ASCII_L 'short.example.com'
DTT_LATE
                .ASCII_L 'late.example.com'
DTT_N253
                .DAT    0x13F, 0x2E, 0x13F, 0x2E, 0x13F, 0x2E, 0x13D, 0
DTT_GW          .ASCII_L 'gw.example.com'
DTT_NOROUTE
                .ASCII_L 'noroute.example.com'
DTT_TIME
                .ASCII_L 'time.example.com'
