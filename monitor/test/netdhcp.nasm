; The test of net_dhcp, entry 23, as a program calls it, with the UDP
; endpoint open (issue #111). The Makefile assembles this program after the
; sources of the monitor, as for udp.nasm, so that it reaches the
; variables by name, and test/dhcp.py runs it under the monitor of the
; tests, with no frames, and then with the frames that it builds from the
; transaction of that run. The program stores its results at NDT_RESULTS,
; which the test dumps:
;
;  0  net_set of 192.168.1.50 with no mask, gateway, or DNS server, 0
;  1  udp_open of port 5000, 5000
;  2  net_dhcp, 0, or -45 with no server, after DISCOVERs that ask for
;     192.168.1.50 with option 50
;  3  bit 0 of ETH_CSR, 1, as the open endpoint keeps the port enabled
;  4  the IP address, the mask, the gateway, and the DNS server of
;     net_config
;  8  the DHCP server
;  9  the ARP cache's first entry, its IP address and its MAC address, an
;     ARP reply that came while net_dhcp waited, and was learned
; 12  udp_close, 0
; 13  ETH_CSR, 0, the port disabled
;
; It returns the number of results, 14.

                .ORG    0x8000
NDT_RESULTS     .EQU    0x9100

ndt_main
                MOVE    R7, NDT_RESULTS
                MOVE    R1, NDT_SET
                CALL    _net_set
                MOVE    @R7++, R1
                MOVE    R1, 5000
                CALL    _udp_open
                MOVE    @R7++, R1
                CALL    _net_dhcp
                MOVE    @R7++, R1
                AND     @R7++, @ETH_CSR, ETH_ON
                MOVE    R1, R7
                CALL    _net_config
                ADD     R7, R7, 4
                MOVE    @R7++, @V_DSRV
                MOVE    @R7++, @V_ARP
                MOVE    @R7++, @V_ARP+1
                MOVE    @R7++, @V_ARP+2
                CALL    _udp_close
                MOVE    @R7++, R1
                MOVE    @R7++, @ETH_CSR
                SUB     R1, R7, NDT_RESULTS
                RET

NDT_SET         .DAT    0xC0A80132, 0, 0, 0  ; 192.168.1.50
