; The monitor's network, which the Makefile joins after monitor.nasm (its
; header): the frame routines eth_on, eth_recv, and eth_send, the IP
; checksum, and the ARP cache of arp_resolve, which are the ROM's own,
; with no entries in the dispatch table (issue #83, README.md, "The
; network"); the demultiplexing of the frames that come, and the poll,
; net_poll, entry 24, which the other entries and the ROM's own waits call
; (issue #111); the DHCP exchange in the background, which the cold start
; begins and getline carries on (issue #126); the UDP endpoint, the
; entries 16 to 19, udp_open, udp_send, udp_recv, and udp_close; the IP
; settings, net_config and net_set, entries 21 and 22; net_dhcp, entry
; 23, and i dhcp, which get the IP address from a DHCP server, and the
; renewal of its lease in the poll; dns_lookup, entry 25, the IPv4
; address of a name from the DNS server; time ntp, which sets the clock
; from a time server (issue #127); and tftp IP NAME, which reads a .bin
; file through the endpoint from a TFTP server as load NAME reads one
; from the card (issue #84).
;
; The i command, which shows and writes the IP address, is in
; monitor_cmd.nasm, and jumps to ip_dhcp for the word dhcp. tftp reads its
; lines with l's bin_line, and its names with the file commands' fs_name
; and match. The cold start disables the port and empties the ARP cache.
; The variables of all of it are in monitor.nasm, with the others.

ETH_CSR         .EQU    0xFFFFFFC0      ; the port for Ethernet frames: its status, and a write of bit 0 enables it (nice_cpu's SYSTEM.md §7)
ETH_RX_LEN      .EQU    0xFFFFFFC1      ; the bytes of the frame at the head of the queue, and a write releases it
ETH_TX_LEN      .EQU    0xFFFFFFC2      ; a write of N sends the first N bytes of the send buffer
ETH_CHUNK       .EQU    0xFFFFFFC3      ; the 8 words at ETH_BUF, and in bit 8 the buffer: 0 the queue's, 1 the send buffer
ETH_BUF         .EQU    0xFFFFFFC8      ; ETH_BUF0 to ETH_BUF7, the words of the chunk
TIME_HI         .EQU    0xFFFFFF45      ; bits 63..32 of the microseconds, from the snapshot that a read of io.us takes
ETH_ON          .EQU    0x01            ; the bits of ETH_CSR: enabled,
ETH_WAITS       .EQU    0x02            ; a frame waits in the queue,
ETH_BUSY        .EQU    0x04            ; and a frame being sent
NHDR_CHUNKS     .EQU    2               ; the chunks of a frame that net_frames copies to V_NHDR, its headers, 16 words
NET_TAKE        .EQU    4               ; the frames that a poll takes at most, the queue's
FINE_START      .EQU    0xFFC2F700      ; added to the microseconds for the fine clock: 2^32 less 4 seconds
DHCP_CLIENT     .EQU    68              ; the UDP ports of DHCP's client
ETH_TXBUF       .EQU    0x100           ; the send buffer, in ETH_CHUNK
ARP_SLOTS       .EQU    4               ; the entries of the ARP cache
ARP_AGE         .EQU    60              ; the ticks of arp_tick an entry is kept, about a minute
ARP_TRIES       .EQU    3               ; the requests that arp_resolve sends
ARP_WAIT        .EQU    1000000         ; the microseconds it waits for a reply to each
DHCP_TRIES      .EQU    4               ; the DISCOVERs that i dhcp sends
DHCP_WAIT       .EQU    2000000         ; the microseconds it waits for each reply
DHCP_LEN        .EQU    382             ; the bytes of its frames: 14 Ethernet, 20 IP, 8 UDP, and 340 DHCP
DHCP_WORDS      .EQU    96              ; their words, with the 2 bytes before the frame, all of V_TXF
DHCP_SMAX       .EQU    48              ; the bytes of option 60 at most, which the version may cut
DHCP_DISCOVER   .EQU    1               ; the message types of option 53
DHCP_OFFER      .EQU    2
DHCP_REQUEST    .EQU    3
DHCP_ACK        .EQU    5
DHCP_NAK        .EQU    6
DHCP_RENEW      .EQU    0x103           ; for dhcp_send: a REQUEST of the lease's renewal, to its server,
DHCP_REBIND     .EQU    0x203           ; and one broadcast, from T2
BG_FIRST        .EQU    2000000         ; the microseconds from the cold start to the first DISCOVER in the background,
BG_START        .EQU    4000000         ; the wait after it, doubled after each DISCOVER,
BG_MAX          .EQU    64000000        ; up to this, as RFC 2131 §4.1 has it
LEASE_AGAIN     .EQU    60              ; the ticks of arp_tick between the REQUESTs of a renewal
LEASE_FAR       .EQU    1024            ; the ticks of the housekeeping deadline at most, 2^30 microseconds
UDP_HDR         .EQU    11              ; the words of the headers of a datagram, with the 2 bytes before the frame
UDP_MAX         .EQU    1472            ; the bytes of a datagram's data, at most
E_NOIP          .EQU    -40             ; the errors of the UDP entries: no IP address,
E_PORT          .EQU    -41             ; no such port,
E_UCLOSED       .EQU    -42             ; the endpoint is not open,
E_ULONG         .EQU    -43             ; a datagram too long,
E_NOROUTE       .EQU    -44             ; and no answer to ARP from the host or the gateway
E_NODHCP        .EQU    -45             ; no answer from a DHCP server, of net_dhcp
E_NODNS         .EQU    -46             ; the errors of dns_lookup: no DNS server,
E_DNSTIME       .EQU    -47             ; no answer from it,
E_DNSNAME       .EQU    -48             ; no such name, no A record, or not a valid name,
E_DNSFAIL       .EQU    -49             ; and an error of the server, or a truncated answer
DNS_PORT        .EQU    53              ; the DNS server's UDP port
DNS_TRIES       .EQU    3               ; the queries that dns_lookup sends
DNS_WAIT        .EQU    2000000         ; the microseconds it waits after each
DNS_NAME        .EQU    56              ; the byte of the buffer where a query's name starts, after its 12 bytes of header
NTP_PORT        .EQU    123             ; the time server's UDP port (RFC 4330)
NTP_TRIES       .EQU    3               ; the queries that time ntp sends
NTP_WAIT        .EQU    2000000         ; the microseconds it waits after each
E_NTPTIME       .EQU    -60             ; the errors of time ntp, which no entry returns: no answer,
E_NTPBAD        .EQU    -61             ; an answer that is not to be trusted, or a time that the clock does not take,
E_NTPKOD        .EQU    -62             ; and a kiss-o'-death
TFTP_PORT       .EQU    69              ; the TFTP server's port (RFC 1350)
TFTP_TRIES      .EQU    5               ; the sends of a packet that tftp waits for an answer to
TFTP_WAIT       .EQU    1000000         ; the microseconds it waits after each
TFTP_PKT        .EQU    96              ; the words of V_TPKT

; i dhcp: net_dhcp, and the address, the mask, the gateway, the DNS
; server, the DHCP server, and the NTP server, if it gave one, shown, or
; that no server answered.
ip_dhcp
                CALL    net_dhcp
                TST     R1
        ?N      JMP     :+
                MOVE    R1, S_IP
                MOVE    R2, @E_IP
                CALL    show_ip
                MOVE    R1, S_MASK
                MOVE    R2, @V_MASK
                CALL    show_ip
                MOVE    R1, S_GW
                MOVE    R2, @V_GW
                CALL    show_ip
                MOVE    R1, S_DNS
                MOVE    R2, @V_DNS
                CALL    show_ip
                MOVE    R1, S_DSRV
                MOVE    R2, @V_DSRV
                CALL    show_ip
                MOVE    R1, S_NTPSRV
                MOVE[M] R2, @V_NTP
        ?!Z     CALL    show_ip
                JMP     main
:
                MOVE    R1, S_NODHCP
                CALL    puts_b_crlf
                JMP     main

; net_dhcp: entry 23, the IP address from a DHCP server (RFC 2131),
; through the port for Ethernet frames, which net_on enables, and net_off
; disables at the end, unless the endpoint is open. It broadcasts a
; DISCOVER, which asks for the address set, if there is one, waits
; DHCP_WAIT microseconds for an OFFER, then broadcasts a REQUEST of the
; address offered, from the server that offered it, and waits as long for
; its ACK; a reply without an address is passed over. The waits poll, so
; the other frames go where net_frames takes them. A timeout or a NAK
; starts again from the DISCOVER, up to DHCP_TRIES times, with the same
; transaction, whose number is the microseconds at the start, XOR the low
; word of the MAC address. The ACK's address is written to E_IP only if
; it is another, which breaks a host's connection over TCP, as a write of
; i does, and ends the program's TCP connections in E_TRESET, and the
; mask, the gateway, and the DNS server are kept, and the lease, by
; lease_take, which net_poll renews. Without an ACK, E_IP and the rest,
; and a lease kept, are left alone.
; It ends the exchange in the background. R1 = 0, or E_NODHCP. Uses R1-R6,
; and R7 across the calls, saved: the tries left.
net_dhcp
                PUSH    R7
                MOVE    @V_BSTATE, 0
                CALL    net_on
                MOVE    @V_NWAIT, DHCP_CLIENT
                MOVE    R1, @io.us
                XOR     @V_XID, R1, @E_MACL
                MOVE    R7, DHCP_TRIES
dhcp_try
                MOVE    R1, DHCP_DISCOVER
                CALL    dhcp_send
                MOVE    R1, DHCP_OFFER
                CALL    dhcp_wait
                CMP     R1, DHCP_OFFER
        ?!Z     JMP     :+
                MOVE    R1, DHCP_REQUEST
                CALL    dhcp_send
                MOVE    R1, DHCP_ACK
                CALL    dhcp_wait
                CMP     R1, DHCP_ACK
        ?Z      JMP     :++
:
                SUB[M]  R7, R7, 1
        ?!Z     JMP     dhcp_try
                MOVE    R7, E_NODHCP
                JMP     :++
:
                CALL    dhcp_commit
                MOVE    R7, 0
:
                MOVE    @V_NWAIT, 0
                CALL    net_off
                MOVE    R1, R7
                POP     R7
                RET

; dhcp_commit: the address of the ACK, V_DIP, written to E_IP if it is
; another, which breaks a host's connection over TCP, as a write of i
; does, and ends the program's TCP connections in E_TRESET; its mask,
; gateway, DNS server, and NTP server kept, and its lease, by lease_take.
; Uses R1-R6.
dhcp_commit
                CMP     @E_IP, @V_DIP
        ?!Z     MOVE    @E_IP, @V_DIP
        ?!Z     CALL    tcp_resetall
                MOVE    @V_MASK, @V_DMASK
                MOVE    @V_GW, @V_DGW
                MOVE    @V_DNS, @V_DDNS
                MOVE    @V_NTP, @V_DNTP
                JMP     lease_take      ; which returns to the caller

; The DHCP exchange in the background (issue #126). After a reset of the
; system the station has no IP address, and the cold start begins an
; exchange with bg_start. getline carries it on while it waits for the
; first key of a line, with bg_step, so it costs nothing while a command
; or a program runs, and nothing without a cable. The first DISCOVER goes
; BG_FIRST microseconds after the cold start, as the PHY negotiates the
; link again after a reset; each after it waits twice as long as the one
; before, from BG_START up to BG_MAX, plus up to a second that the
; microseconds pick (RFC 2131 §4.1). An OFFER with an address gets a
; REQUEST, and DHCP_WAIT microseconds for its ACK; without it, or with a
; NAK, the next DISCOVER goes. The ACK sets the address, as i dhcp does,
; and bg_show shows it. The exchange ends there, or when the station has
; an address from elsewhere: i, net_set, net_dhcp, or the link.

; bg_start: the exchange in the background begun, if the station has no
; IP address, with a transaction of its own. Uses R1 and R2.
bg_start
                MOVE    @V_BSTATE, 0
                TST     @E_IP
        ?!Z     RET
                MOVE    R1, @io.us
                XOR     @V_XID, R1, @E_MACL
                CALL    net_clock
                ADD     @V_BDUE, R1, BG_FIRST
                MOVE    @V_BWAIT, BG_START
                MOVE    @V_BSTATE, DHCP_OFFER
                RET

; bg_step: for getline_wait, after a poll, net_step, with R1 the bytes of
; the frame to port 68 that it copied to V_RXF, or 0: the exchange in the
; background carried on, if it runs, with the port for Ethernet frames
; enabled. R1 = 1 when the ACK came and the address is set, or else 0.
; Uses R1-R6.
bg_step
                TST     @V_BSTATE
        ?Z      JMP     bg_none
                TST     @E_IP
        ?!Z     JMP     bg_stop         ; an address from elsewhere
                TST     R1
        ?Z      JMP     bg_time
                CALL    dhcp_parse
                CMP     R1, DHCP_NAK
        ?Z      JMP     bg_nak
                CMP     R1, @V_BSTATE
        ?!Z     JMP     bg_time         ; not the reply waited for
                TST     @V_PIP
        ?Z      JMP     bg_time         ; no address: passed over
                CALL    dhcp_keep
                CMP     @V_BSTATE, DHCP_ACK
        ?Z      JMP     bg_ack
                MOVE    R1, DHCP_REQUEST  ; an OFFER
                CALL    dhcp_send
                MOVE    @V_BSTATE, DHCP_ACK
                CALL    net_clock
                ADD     @V_BDUE, R1, DHCP_WAIT
                JMP     bg_none
bg_nak
                CMP     @V_BSTATE, DHCP_ACK
        ?!Z     JMP     bg_time
                CALL    net_clock
                MOVE    @V_BDUE, R1     ; the next DISCOVER at once
; The next DISCOVER, when it is due
bg_time
                CALL    net_clock
                SUB[M]  R0, R1, @V_BDUE
        ?N      JMP     bg_none
                MOVE    @V_BSTATE, DHCP_OFFER
                MOVE    R1, DHCP_DISCOVER
                CALL    dhcp_send
                CALL    net_clock
                ADD     R1, R1, @V_BWAIT
                AND     R2, @io.us, 0xFFFFF
                ADD     @V_BDUE, R1, R2
                SHL     R1, @V_BWAIT, 1
                CMP     R1, BG_MAX
        ?!C     MOVE    R1, BG_MAX
                MOVE    @V_BWAIT, R1
                JMP     bg_none
bg_ack
                CALL    dhcp_commit
                MOVE    @V_BSTATE, 0
                MOVE    R1, 1
                RET
bg_stop
                MOVE    @V_BSTATE, 0
bg_none
                MOVE    R1, 0
                RET

; bg_show: for getline_wait, the address that the exchange in the
; background got shown, over the prompt, which is on its own in its row,
; as no key of the line has come, and the prompt again after it. The
; screen is shown again if the history is. Uses R1-R4.
bg_show
                CALL    hist_leave
                MOVE    R1, 0x0D
                CALL    mon_putc
                MOVE    R1, S_IP
                MOVE    R2, @E_IP
                CALL    put_ip
                MOVE    R1, S_BGDHCP
                CALL    puts_b_crlf
                MOVE    R1, S_PROMPT
                JMP     puts_b          ; which returns to the caller

; The frame routines, the ROM's own, with no entries in the dispatch table
; (INTERNALS.md, "The frame routines"). They follow the C ABI, and drive the port for
; Ethernet frames of nice_cpu's SYSTEM.md §7. A frame is in RAM as the
; port's buffers have it: from byte 2 of its buffer, 4 bytes a word,
; big-endian, so that word n of the RAM is word n of the port's buffer,
; and the words of nice_cpu's SYSTEM.md §7 are where its table says.

; eth_on: the port enabled, with its queue emptied, so that no frame from
; before comes. Uses no register.
eth_on
                MOVE    @ETH_CSR, 0
                MOVE    @ETH_CSR, ETH_ON
                RET

; eth_recv: the frame at the head of the queue copied to the 380 words at
; R1, and released. R1 = its length in bytes, or 0 when the queue is
; empty. Uses R1-R5.
eth_recv
                MOVE[M] R2, @ETH_RX_LEN
        ?Z      MOVE    R1, 0
        ?Z      RET
                ADD     R3, R2, 5       ; the words, with the 2 bytes before the frame
                SHR     R3, R3, 2
                MOVE    R4, 0           ; the chunk, of the queue's buffer
:
                MOVE    @ETH_CHUNK, R4
                MOVE    R5, ETH_BUF
:
                MOVE    @R1++, @R5++
                SUB[M]  R3, R3, 1
        ?Z      JMP     :+
                CMP     R5, ETH_BUF+8
        ?!Z     JMP     :-
                ADD     R4, R4, 1
                JMP     :--
:
                MOVE    @ETH_RX_LEN, 0  ; the frame released
                MOVE    R1, R2
                RET

; eth_send: the frame at R1, R2 bytes long, 14 to 1514, copied to the send
; buffer and sent, after the frame before it has gone. The port must be
; enabled, or nothing is sent. Uses R1-R5.
eth_send
                AND[M]  R0, @ETH_CSR, ETH_BUSY
        ?!Z     JMP     eth_send        ; as the send buffer takes no write while busy
                ADD     R3, R2, 5
                SHR     R3, R3, 2
                MOVE    R4, ETH_TXBUF   ; chunk 0 of the send buffer
:
                MOVE    @ETH_CHUNK, R4
                MOVE    R5, ETH_BUF
:
                MOVE    @R5++, @R1++
                SUB[M]  R3, R3, 1
        ?Z      JMP     :+
                CMP     R5, ETH_BUF+8
        ?!Z     JMP     :-
                ADD     R4, R4, 1
                JMP     :--
:
                MOVE    @ETH_TX_LEN, R2
                RET

; eth_head: the Ethernet header of the frame at R1: to everyone, from the
; station's MAC address, with the EtherType R2. Uses R3 and R4.
eth_head
                MOVE    @R1, 0xFFFF
                MOVE    @1[R1], 0xFFFFFFFF
                SHL     R3, @E_MACH, 16
                SHR     R4, @E_MACL, 16
                OR      @2[R1], R3, R4
                SHL     R3, @E_MACL, 16
                OR      @3[R1], R3, R2
                RET

; ip_csum: the checksum of the IPv4 header of the frame at R1, the 5
; words 4 to 8, written to bits 15..0 of word 6: the ones' complement of
; the ones' complement sum of its halves. Uses R2-R6.
ip_csum
                AND     @6[R1], @6[R1], 0xFFFF0000
                ADD     R2, R1, 4
                MOVE    R3, 5
                MOVE    R4, 0
:
                MOVE    R5, @R2++
                SHR     R6, R5, 16
                ADD     R4, R4, R6
                AND     R5, R5, 0xFFFF
                ADD     R4, R4, R5
                SUB[M]  R3, R3, 1
        ?!Z     JMP     :-
                SHR     R5, R4, 16      ; the carries added back in, twice
                AND     R4, R4, 0xFFFF
                ADD     R4, R4, R5
                SHR     R5, R4, 16
                AND     R4, R4, 0xFFFF
                ADD     R4, R4, R5
                XOR     R4, R4, 0xFFFF
                OR      @6[R1], @6[R1], R4
                RET

; rx_byte: R1 = the byte at R1 of V_RXF, counted from the start of the
; buffer, 2 bytes before the frame. Uses R1 and R2.
rx_byte
                SHR     R2, R1, 2
                AND     R1, R1, 3
                XOR     R1, R1, 3
                SHL     R1, R1, 3       ; 8 times the bytes after it in the word
                SHR     R1, @V_RXF[R2], R1
                AND     R1, R1, 0xFF
                RET

; rx_long: R1 = the 4 bytes from the byte at R1 of V_RXF, big-endian,
; whichever byte of a word they start at. Uses R1-R3.
rx_long
                SHR     R2, R1, 2
                AND     R1, R1, 3
                SHL     R1, R1, 3
                SHL     R3, @V_RXF[R2], R1
                SUB     R1, 32, R1      ; a shift of 32 gives 0
                ADD     R2, R2, 1
                SHR     R1, @V_RXF[R2], R1
                OR      R1, R1, R3
                RET

; The ARP cache: ARP_SLOTS entries at V_ARP, which the cold start empties.
; arp_resolve gives the MAC address of an IP address, from the cache, or
; else from a request, broadcast up to ARP_TRIES times, and the reply,
; which goes into the cache. An entry is kept ARP_AGE ticks of arp_tick,
; about a minute, and a new one takes the entry of its IP address, or else
; the next in turn. The port must be enabled. arp_resolve polls while it
; waits, with net_step, which learns every ARP reply in place, and takes
; the other frames where they go.

; arp_resolve: R1 an IP address, not 0. R1 = 0, R2 the MAC address's first
; two bytes, as E_MACH has them, and R3 its last four, as E_MACL has
; them; or R1 = -1 when no reply came. Uses R1-R6, and R7-R9 across the
; calls, saved.
arp_resolve
                PUSH    R7
                PUSH    R8
                PUSH    R9
                MOVE    R7, R1          ; the IP address
                MOVE    R8, ARP_TRIES   ; the requests left
arp_look
                MOVE    R1, R7
                CALL    arp_find
                TST     R1
        ?!Z     JMP     arp_found
                TST     R8
        ?Z      JMP     arp_none
                SUB     R8, R8, 1
                MOVE    R1, R7
                CALL    arp_request
                MOVE    R9, @io.us      ; when it was sent
:
                CALL    net_step
                MOVE    R1, R7
                CALL    arp_find
                TST     R1
        ?!Z     JMP     arp_found
                SUB     R1, @io.us, R9
                CMP     R1, ARP_WAIT
        ?C      JMP     :-
                JMP     arp_look
arp_found
                MOVE    R2, @1[R1]
                MOVE    R3, @2[R1]
                MOVE    R1, 0
                JMP     :+
arp_none
                MOVE    R1, -1
:
                POP     R9
                POP     R8
                POP     R7
                RET

; arp_find: R1 = the entry of the IP address R1, if it is younger than
; ARP_AGE, or 0. Uses R1-R4.
arp_find
                MOVE[M] R3, R1
        ?Z      RET                     ; 0, which marks no entry
                CALL    arp_tick
                MOVE    R4, V_ARP
:
                CMP     @R4, R3
        ?!Z     JMP     :+
                SUB     R2, R1, @3[R4]
                CMP     R2, ARP_AGE
        ?C      MOVE    R1, R4
        ?C      RET
:
                ADD     R4, R4, 4
                CMP     R4, V_ARP+4*ARP_SLOTS
        ?!Z     JMP     :--
                MOVE    R1, 0
                RET

; arp_take: the ARP frame of at least 42 bytes, whose headers are at
; V_NHDR, learned in place, if it is a reply, for Ethernet and IPv4,
; whoever it is to. Uses R1-R6.
arp_take
                CMP     @V_NHDR+4, 0x00010800  ; Ethernet, IPv4
        ?!Z     RET
                CMP     @V_NHDR+5, 0x06040002  ; their lengths, and a reply
        ?!Z     RET
                SHL     R1, @V_NHDR+7, 16  ; the sender's IP address
                SHR     R2, @V_NHDR+8, 16
                OR      R1, R1, R2
                SHR     R2, @V_NHDR+6, 16  ; and its MAC address
                SHL     R3, @V_NHDR+6, 16
                SHR     R4, @V_NHDR+7, 16
                OR      R3, R3, R4
; arp_learn: the IP address R1 at the MAC address R2 and R3 into the
; cache, at the time of now. Uses R1-R6.
arp_learn
                MOVE    R4, V_ARP
:
                CMP     @R4, R1
        ?Z      JMP     :+
                ADD     R4, R4, 4
                CMP     R4, V_ARP+4*ARP_SLOTS
        ?!Z     JMP     :-
                MOVE    R4, @V_ARPNEXT  ; the next entry in turn
                ADD     R5, R4, 4
                AND     @V_ARPNEXT, R5, 4*ARP_SLOTS-1
                ADD     R4, R4, V_ARP
:
                MOVE    @R4++, R1
                MOVE    @R4++, R2
                MOVE    @R4++, R3
                MOVE    R6, R4
                CALL    arp_tick
                MOVE    @R6, R1
                RET

; arp_tick: R1 = the time in units of 2^20 microseconds, about a second,
; from the 64 bits of the microsecond counter, so that it wraps after
; 4000 years. Uses R1 and R2.
arp_tick
                SHR     R1, @io.us, 20  ; which takes the snapshot of TIME_HI
                SHL     R2, @TIME_HI, 12
                OR      R1, R1, R2
                RET

; arp_request: a request for the IP address R1 broadcast, from E_IP and the
; station's MAC address. Uses R1-R6.
arp_request
                MOVE    R6, R1
                MOVE    R1, V_TXF
                MOVE    R2, 0x0806
                CALL    eth_head
                MOVE    @V_TXF+4, 0x00010800  ; Ethernet, IPv4
                MOVE    @V_TXF+5, 0x06040001  ; their lengths, and a request
                MOVE    @V_TXF+6, @V_TXF+2  ; the sender's MAC address
                SHL     R3, @E_MACL, 16
                SHR     R4, @E_IP, 16
                OR      @V_TXF+7, R3, R4  ; and its IP address
                SHL     @V_TXF+8, @E_IP, 16  ; the target's MAC address, 0
                MOVE    @V_TXF+9, 0
                MOVE    @V_TXF+10, R6
                MOVE    R1, V_TXF
                MOVE    R2, 42
                JMP     eth_send        ; which returns to the caller

; The demultiplexing and the poll (issue #111, INTERNALS.md, "The frame
; routines"). While the network is on, while the endpoint is open, or
; net_dhcp or dns_lookup runs, the ROM alone reads the queue and writes
; the send buffer. A poll takes the frames that wait, NET_TAKE at most,
; the queue's 4, and releases each: an ARP reply is learned in place, from its
; headers at V_NHDR, so it never touches V_RXF; a datagram for the
; endpoint is copied to V_RXF, where it is held for udp_recv, unless one
; is held already, and then it is dropped; a datagram to the port of the
; ROM's own wait, V_NWAIT, such as a DHCP reply, is copied to V_RXF, and
; the poll stops there, so that the wait parses it; it takes the place of
; a datagram held, which is lost, as does a DHCP reply to the lease's
; transaction while a lease is kept, which lease_reply takes in V_RXF.
; Every other frame is released unread.
; Nothing moves between polls: a program calls net_poll every 100 ms or
; so (README.md, "The network").
;
; The fine clock, net_clock, is the microseconds plus FINE_START, so that
; it wraps 4 seconds after reset and every run crosses a wrap. A deadline
; on it is due when the signed difference of the clock and it is not
; negative. The nearest deadline of all is V_NDUE, which counts only
; while V_NARM is not 0, so that a stale one is never due.

; net_on: the port for Ethernet frames enabled, with its queue emptied,
; and the housekeeping deadline of a lease kept armed, if it is not
; enabled, and else left as it is, with the frames that wait. Uses no
; register.
net_on
                AND[M]  R0, @ETH_CSR, ETH_ON
        ?!Z     RET
                CALL    eth_on
                TST     @V_LEASE
        ?Z      RET
                PUSH    R1
                PUSH    R2
                PUSH    R3
                CALL    lease_arm
                POP     R3
                POP     R2
                POP     R1
                RET

; net_off: the port disabled, and its queue emptied, with no deadline
; armed, unless the endpoint is open, a wait of the ROM's own runs, or a
; TCP handle is taken, which keep the network on. A lease is kept, and
; renewed when the network is on again. Uses no register.
net_off
                TST     @V_UPORT
        ?!Z     RET
                TST     @V_NWAIT
        ?!Z     RET
                PUSH    R1
                MOVE    R1, V_TCB
:
                TST     @R1
        ?!Z     JMP     :+              ; a handle
                ADD     R1, R1, 1
                CMP     R1, V_TCB+TCP_HANDLES
        ?!Z     JMP     :-
                MOVE    @ETH_CSR, 0
                MOVE    @V_LARM, 0
                MOVE    @V_NARM, 0      ; as no connection has a deadline
:
                POP     R1
                RET

; net_close: the network closed, for the cold start, mon_exit, and
; mon_trap: a RST for each TCP connection, at best effort, and every
; handle freed, by tcp_close_all, the endpoint closed, the datagram held
; forgotten, no wait of the ROM's own, no deadline armed, and the port
; disabled. A lease is kept. Uses R1-R6.
net_close
                CALL    tcp_close_all
                MOVE    @V_UPORT, 0
                MOVE    @V_ULEN, 0
                MOVE    @V_NWAIT, 0
                MOVE    @V_LARM, 0
                MOVE    @V_NARM, 0
                MOVE    @ETH_CSR, 0
                RET

; net_clock: R1 = the fine clock, in microseconds. Uses R1.
net_clock
                ADD     R1, @io.us, FINE_START
                RET

; ip_ident: R1 = word 5 of an IPv4 header with the identification
; V_IPID, which counts up by one for each packet sent, and the flags and
; the fragment's offset 0, DF clear (RFC 6864). Uses R1.
ip_ident
                SHL     R1, @V_IPID, 16
                ADD     @V_IPID, @V_IPID, 1
                RET

; net_poll: entry 24. The frames that wait taken, and the deadline that
; is due done. Never waits. R1 = 0, which is not negative: a later table
; may give it a meaning. Uses R1-R6.
net_poll
                CALL    net_step
                MOVE    R1, 0
                RET

; net_step: the poll of net_poll, for the ROM's waits too. R1 = the bytes
; of the frame for the ROM's own wait that it copied to V_RXF, or 0. Its
; cost with nothing to do is a read of ETH_CSR, and while a deadline is
; armed, a read of the clock and a comparison. Uses R1-R6.
net_step
                MOVE    R1, 0
                AND[M]  R0, @ETH_CSR, ETH_WAITS
        ?!Z     CALL    net_frames
                TST     @V_TCWORK
        ?Z      JMP     :+
                PUSH    R1
                CALL    tcp_work
                POP     R1
:
                TST     @V_NARM
        ?Z      RET
                PUSH    R1
                CALL    net_clock
                SUB[M]  R0, R1, @V_NDUE
        ?!N     CALL    net_due
                POP     R1
                RET

; net_due: the deadline that is due: the lease's housekeeping, with
; lease_due, and the timeouts of the TCP connections, with tcp_due, which
; arms the next. Uses R1-R6.
net_due
                TST     @V_LARM
        ?Z      JMP     tcp_due         ; which returns to the caller
                CALL    net_clock
                SUB[M]  R0, R1, @V_LDUE
        ?!N     CALL    lease_due
                JMP     tcp_due         ; which returns to the caller

; net_frames: the frames of the queue taken, as the header above says, up
; to NET_TAKE of them, or up to a frame for the ROM's own wait. R1 = the
; bytes of that frame, copied to V_RXF, or 0. Uses R1-R6, and R7 and R8
; across the calls, saved: the bytes of the frame, and the frames left.
net_frames
                PUSH    R7
                PUSH    R8
                MOVE    R8, NET_TAKE
net_frame
                MOVE[M] R7, @ETH_RX_LEN
        ?Z      JMP     net_frames_none
                MOVE    R2, V_NHDR      ; its headers, chunks 0 and 1
                MOVE    R3, 0
:
                MOVE    @ETH_CHUNK, R3
                MOVE    R1, ETH_BUF
:
                MOVE    @R2++, @R1++
                CMP     R1, ETH_BUF+8
        ?!Z     JMP     :-
                ADD     R3, R3, 1
                CMP     R3, NHDR_CHUNKS
        ?!Z     JMP     :--
                CMP     R7, 42
        ?C      JMP     net_drop        ; too short for ARP and UDP
                AND     R1, @V_NHDR+3, 0xFFFF
                CMP     R1, 0x0806
        ?Z      JMP     net_arp
                CMP     R1, 0x0800
        ?!Z     JMP     net_drop
                SHR     R1, @V_NHDR+4, 24
                CMP     R1, 0x45
        ?!Z     JMP     net_drop        ; not IPv4, or with options
                AND[M]  R0, @V_NHDR+5, 0x3FFF
        ?!Z     JMP     net_drop        ; a fragment
                SHR     R1, @V_NHDR+6, 16
                AND     R1, R1, 0xFF
                CMP     R1, 6           ; TCP
        ?Z      JMP     net_tcp
                CMP     R1, 17          ; UDP
        ?!Z     JMP     net_drop
; A datagram: for the ROM's own wait, whatever its IP address, as a DHCP
; server may send to the address it offers
                AND     R2, @V_NHDR+9, 0xFFFF  ; its port
                MOVE[M] R1, @V_NWAIT
        ?Z      JMP     :+
                CMP     R1, R2
        ?!Z     JMP     :+
                MOVE    @V_ULEN, 0      ; the datagram held, lost
                MOVE    R1, V_RXF
                CALL    eth_recv
                JMP     net_frames_end
; Or a reply to the lease's renewal: from port 67 to port 68, of the
; transaction V_XID
:
                TST     @V_LEASE
        ?Z      JMP     :+
                CMP     @V_NHDR+9, 0x00430044
        ?!Z     JMP     :+
                CMP     @V_NHDR+12, @V_XID
        ?Z      JMP     net_lease
; Or for the endpoint: to E_IP or to everyone, to its port, no shorter
; than its UDP length says, and with 1 to UDP_MAX bytes of data
:
                TST     @V_ULEN
        ?!Z     JMP     net_drop        ; one is held
                MOVE[M] R1, @V_UPORT
        ?Z      JMP     net_drop        ; closed
                CMP     R1, R2
        ?!Z     JMP     net_drop
                MOVE    R1, @V_NHDR+8
                CMP     R1, 0xFFFFFFFF
        ?Z      JMP     :+
                CMP     R1, @E_IP
        ?!Z     JMP     net_drop
:
                SHR     R2, @V_NHDR+10, 16  ; the UDP length
                SUB     R3, R7, 34      ; the bytes after the IP header
                CMP     R3, R2
        ?C      JMP     net_drop        ; shorter than that
                SUB     R1, R2, 9       ; the bytes of data, less 1
                CMP     R1, UDP_MAX
        ?!C     JMP     net_drop        ; no data, or too long
                ADD     R7, R1, 1       ; the bytes of data
                MOVE    R1, V_RXF
                CALL    eth_recv
                MOVE    @V_ULEN, R7     ; held
                JMP     net_next
net_lease
                MOVE    @V_ULEN, 0      ; the datagram held, lost
                MOVE    R1, V_RXF
                CALL    eth_recv
                CALL    lease_reply
                JMP     net_next
net_tcp
                MOVE    R1, R7
                CALL    tcp_input
                JMP     net_drop
net_arp
                CALL    arp_take
net_drop
                MOVE    @ETH_RX_LEN, 0  ; released
net_next
                SUB[M]  R8, R8, 1
        ?!Z     JMP     net_frame
net_frames_none
                MOVE    R1, 0
net_frames_end
                POP     R8
                POP     R7
                RET

; net_waddr: R1 = the plain address of the word address R1, which is
; plain, or one in the word window, 0x10000000 + 4 W, of the word W
; (nice_cpu's SYSTEM.md §9). Uses R1 and R2.
net_waddr
                SHR     R2, R1, 28
                CMP     R2, 1
        ?Z      AND     R1, R1, 0x0FFFFFFF
        ?Z      SHR     R1, R1, 2
                RET

; net_config: entry 21. The IP address, the mask, the gateway, and the
; DNS server, each 0 for none, written to the 4 words at the word address
; R1, after a poll. R1 = 0. Uses R1-R6, and R7 across the calls, saved.
net_config
                PUSH    R7
                CALL    net_waddr
                MOVE    R7, R1
                CALL    net_step
                MOVE    @R7, @E_IP
                MOVE    @1[R7], @V_MASK
                MOVE    @2[R7], @V_GW
                MOVE    @3[R7], @V_DNS
                MOVE    R1, 0
                POP     R7
                RET

; net_set: entry 22. The IP address, the mask, the gateway, and the DNS
; server set from the 4 words at the word address R1, as net_config gives
; them, after a poll, and no NTP server kept. The IP address is written
; to E_IP only if it is another, as a write breaks a host's connection
; over TCP, and ends every TCP connection of the program in E_TRESET; 0
; clears it. The lease is forgotten, and not renewed, and the exchange in
; the background ended. R1 = 0. Uses R1-R6, and R7 across the calls,
; saved.
net_set
                PUSH    R7
                CALL    net_waddr
                MOVE    R7, R1
                CALL    net_step
                CMP     @R7, @E_IP
        ?!Z     MOVE    @E_IP, @R7
        ?!Z     CALL    tcp_resetall
                MOVE    @V_MASK, @1[R7]
                MOVE    @V_GW, @2[R7]
                MOVE    @V_DNS, @3[R7]
                MOVE    @V_NTP, 0
                MOVE    @V_BSTATE, 0
                CALL    lease_forget
                MOVE    R1, 0
                POP     R7
                RET

; The UDP endpoint, the entries 16 to 19 (README.md, "The network"): one
; local port, V_UPORT, 0 while it is closed, which the cold start and
; mon_exit close, as they disable the port for Ethernet frames. Datagrams
; are IPv4, from E_IP, with no options, DF clear, the identification of
; ip_ident, and the UDP checksum 0, none, as IPv4 allows. A datagram's
; data is one byte per word, bits 7..0, as the file entries have it. The
; poll holds one datagram for the endpoint at V_RXF, V_ULEN bytes, which
; udp_recv returns.

; udp_open: the endpoint opened on the local port R1, or with R1 = 0 on a
; port from 49152 to 65535 that the microsecond counter picks, with no
; datagram held, and the port for Ethernet frames enabled by net_on, with
; its queue emptied if it was not enabled. R1 = the port, or E_NOIP
; without an IP address, or E_PORT for one past 65535. Uses R1.
udp_open
                TST     @E_IP
        ?Z      MOVE    R1, E_NOIP
        ?Z      RET
                CMP     R1, 0x10000
        ?!C     MOVE    R1, E_PORT
        ?!C     RET
                TST     R1
        ?Z      AND     R1, @io.us, 0x3FFF
        ?Z      OR      R1, R1, 0xC000
                MOVE    @V_UPORT, R1
                MOVE    @V_ULEN, 0
                JMP     net_on          ; which returns to the caller

; udp_close: the endpoint closed, the datagram held forgotten, and the
; port for Ethernet frames disabled by net_off. R1 = 0.
udp_close
                MOVE    @V_UPORT, 0
                MOVE    @V_ULEN, 0
                MOVE    R1, 0
                JMP     net_off         ; which returns to the caller

; udp_send: the R4 bytes at R3 sent to the port R2 of the IP address R1,
; through the gateway, V_GW, when the mask, V_MASK, puts the address in
; another network, and to everyone for 255.255.255.255. R1 = 0, or
; E_UCLOSED, E_PORT for a port of 0 or past 65535, E_ULONG for more than
; UDP_MAX bytes, or E_NOROUTE when the host or the gateway did not answer
; ARP. It polls first. The headers are built at V_UHDR, and copied with
; the bytes to the send buffer a word at a time. Uses R1-R6, and R7-R10
; across the calls, saved: the address, the port, the bytes, and their
; number.
udp_send
                TST     @V_UPORT
        ?Z      MOVE    R1, E_UCLOSED
        ?Z      RET
                SUB     R5, R2, 1
                CMP     R5, 0xFFFF
        ?!C     MOVE    R1, E_PORT
        ?!C     RET
                CMP     R4, UDP_MAX+1
        ?!C     MOVE    R1, E_ULONG
        ?!C     RET
                PUSH    R7
                PUSH    R8
                PUSH    R9
                PUSH    R10
                MOVE    R7, R1
                MOVE    R8, R2
                MOVE    R9, R3
                MOVE    R10, R4
                CALL    net_step
                MOVE    R1, R7
                CALL    net_hop
                TST     R1
        ?!Z     JMP     udp_noroute
                MOVE    R1, V_UHDR
                MOVE    R4, R7
                SHL     R5, @V_UPORT, 16
                OR      R5, R5, R8
                MOVE    R6, R10
                CALL    udp_head
                CALL    ip_ident
                MOVE    @V_UHDR+5, R1
                MOVE    R1, V_UHDR
                CALL    ip_csum
:
                AND[M]  R0, @ETH_CSR, ETH_BUSY
        ?!Z     JMP     :-              ; as the send buffer takes no write while busy
                MOVE    R5, 0           ; the word of the send buffer
                MOVE    R6, R10         ; the bytes left
udp_word
                CMP     R5, UDP_HDR
        ?!C     JMP     :+
                MOVE    R2, @V_UHDR[R5]
                JMP     udp_put
:
                TST     R6
        ?Z      JMP     udp_go          ; all written
                MOVE    R2, 0
                MOVE    R4, 4
:
                SHL     R2, R2, 8
                TST     R6
        ?Z      JMP     :+
                AND     R1, @R9++, 0xFF
                OR      R2, R2, R1
                SUB     R6, R6, 1
:
                SUB[M]  R4, R4, 1
        ?!Z     JMP     :--
udp_put
                SHR     R1, R5, 3
                OR      @ETH_CHUNK, R1, ETH_TXBUF
                AND     R1, R5, 7
                MOVE    @ETH_BUF[R1], R2
                ADD     R5, R5, 1
                JMP     udp_word
udp_go
                ADD     @ETH_TX_LEN, R10, 42
                MOVE    R1, 0
                JMP     :+
udp_noroute
                MOVE    R1, E_NOROUTE
:
                POP     R10
                POP     R9
                POP     R8
                POP     R7
                RET

; net_hop: the MAC address of the next hop to the IP address R1, not 0:
; everyone's for 255.255.255.255; the host's, by arp_resolve, when the
; mask, V_MASK, puts it in this network, or there is no mask; and else
; the gateway's, V_GW. R1 = 0, and R2 and R3 the MAC address, as E_MACH
; and E_MACL have it, or R1 not 0 when there is no gateway, or no answer
; to ARP. Uses R1-R6.
net_hop
                MOVE    R2, 0xFFFF
                MOVE    R3, 0xFFFFFFFF
                CMP     R1, 0xFFFFFFFF
        ?Z      MOVE    R1, 0
        ?Z      RET                     ; to everyone
                XOR     R2, R1, @E_IP
                AND[M]  R0, R2, @V_MASK
        ?Z      JMP     arp_resolve     ; in this network, or no mask
                MOVE[M] R1, @V_GW
        ?!Z     JMP     arp_resolve     ; which returns to the caller
                MOVE    R1, -1
                RET

; udp_head: the headers of a datagram, its first UDP_HDR words as the
; send buffer has them, written at R1: to the MAC address R2 and R3, as
; E_MACH and E_MACL have it, from the station's; IPv4 from E_IP to R4,
; with no options, TTL 64, DF clear, and the identification and the
; checksum left for the caller, ip_ident and ip_csum; UDP from the port in
; bits 31..16 of R5 to the one in bits 15..0, with R6 bytes of data, and
; the checksum 0, none, as IPv4 allows. Uses R2 and R3.
udp_head
                MOVE    @R1, R2
                MOVE    @1[R1], R3
                SHL     R2, @E_MACH, 16
                SHR     R3, @E_MACL, 16
                OR      @2[R1], R2, R3
                SHL     R2, @E_MACL, 16
                OR      @3[R1], R2, 0x0800
                ADD     R2, R6, 28
                OR      @4[R1], R2, 0x45000000  ; IPv4, a header of 5 words, and the length
                MOVE    @6[R1], 0x40110000  ; the TTL 64, UDP
                MOVE    @7[R1], @E_IP
                MOVE    @8[R1], R4
                MOVE    @9[R1], R5
                ADD     R2, R6, 8
                SHL     @10[R1], R2, 16  ; the UDP length, and checksum 0
                RET

; udp_recv: after a poll, the datagram held for the endpoint copied to
; the words at R1, R2 bytes at most, a byte per word, and its source's IP
; address and port to the 2 words at R3, unless R3 is 0. R1 = the bytes
; copied, 0 when no datagram is held, or E_UCLOSED. With R2 0 nothing is
; copied, and the datagram stays held, so none is lost to a call with no
; room. Uses R1-R6, and R7-R9 across the calls, saved.
udp_recv
                TST     @V_UPORT
        ?Z      MOVE    R1, E_UCLOSED
        ?Z      RET
                PUSH    R7
                PUSH    R8
                PUSH    R9
                MOVE    R7, R1
                MOVE    R8, R2
                MOVE    R9, R3
                CALL    net_step
                MOVE    R1, 0
                TST     R8
        ?Z      JMP     udp_recv_end    ; no room: the datagram stays
                CALL    udp_take
                CMP     R1, R8
        ?C      MOVE    R8, R1          ; the bytes to copy
                TST     R1
        ?Z      JMP     udp_recv_end
                TST     R9
        ?Z      JMP     :+
                MOVE    @R9, @V_RXF+7
                SHR     @1[R9], @V_RXF+9, 16
:
                MOVE    R6, 0           ; the byte
:
                ADD     R1, R6, 4*UDP_HDR
                CALL    rx_byte
                MOVE    @R7++, R1
                ADD     R6, R6, 1
                CMP     R6, R8
        ?!Z     JMP     :-
                MOVE    R1, R8
udp_recv_end
                POP     R9
                POP     R8
                POP     R7
                RET

; udp_next: a poll, and udp_take, for tftp. Uses R1-R6.
udp_next
                CALL    net_step
; udp_take: the datagram held for the endpoint, which is held no more:
; R1 = its bytes, or 0 when none is held. It stays in V_RXF, its data from
; word UDP_HDR, its source's IP address in word 7, and its port in bits
; 31..16 of word 9, until the next poll. Uses R1.
udp_take
                MOVE    R1, @V_ULEN
                MOVE    @V_ULEN, 0
                RET

; The frames of net_dhcp (RFC 2131 and RFC 2132): a DISCOVER or a
; REQUEST, broadcast from 0.0.0.0 port 68 to port 67, with the broadcast
; flag set, as the station may have no address yet, and padded to the 300
; bytes of a BOOTP message (RFC 1542). The UDP checksum is 0, none, as
; IPv4 allows, and the IPv4 header has the identification of ip_ident.
; With the 2 bytes before the frame, the fields fall on words: the IP
; header at 4, the UDP header at 9, the message at 11, its transaction at
; 12, the address offered at 15, the client's MAC address at 18, the
; magic cookie at 70, and the options from 71, which are written a byte
; at a time: 53, the message type; 50, the address asked for, the one
; offered for a REQUEST, and for a DISCOVER the station's, E_IP, if it
; has one, so that the server offers it again; for a REQUEST, 54, the
; server; 55, the options asked for, 1 the mask, 3 the gateway, 6 the
; DNS servers, and 42 the NTP servers; 12, the host name,
; nicemon- and the last three bytes of the MAC address in lower-case hex,
; such as nicemon-434506, a valid name for the network's DNS; 60, the
; vendor class, NiceMonMEGA65 and the monitor's version, cut at DHCP_SMAX
; bytes; and 255, the end (issue #124). The message is 340 bytes, more
; than the 300 of BOOTP, so that a long version fits.

; dhcp_send: a message of the type R1, DHCP_DISCOVER, or DHCP_REQUEST of
; the address V_DIP from the server V_DSRV, with the transaction V_XID.
; Or a REQUEST of the lease's renewal (RFC 2131 §4.3.2), R1 DHCP_RENEW to
; its server, V_LSRV, at its MAC address, or DHCP_REBIND to everyone:
; from E_IP, with E_IP in ciaddr, no options 50 and 54, and the broadcast
; flag clear. Uses R1-R6.
dhcp_send
                MOVE    R5, R1          ; the type
                MOVE    R1, V_TXF
                MOVE    R2, DHCP_WORDS
:
                MOVE    @R1++, 0
                SUB[M]  R2, R2, 1
        ?!Z     JMP     :-
                MOVE    R1, V_TXF
                MOVE    R2, 0x0800
                CALL    eth_head
                MOVE    @V_TXF+4, 0x45000000+DHCP_LEN-14  ; IPv4, a header of 5 words, and the length
                CALL    ip_ident
                MOVE    @V_TXF+5, R1
                MOVE    @V_TXF+6, 0x40110000  ; the TTL 64, UDP
                MOVE    @V_TXF+8, 0xFFFFFFFF  ; to everyone
                MOVE    @V_TXF+9, 0x00440043  ; from port 68 to 67
                MOVE    @V_TXF+10, 0x10000*DHCP_LEN-0x10000*34  ; the UDP length, and checksum 0
                MOVE    @V_TXF+11, 0x01010600  ; a request, Ethernet, 6 bytes of MAC address
                MOVE    @V_TXF+12, @V_XID
                MOVE    @V_TXF+13, 0x8000  ; broadcast
                MOVE    @V_TXF+18, @V_TXF+2  ; the MAC address
                SHL     @V_TXF+19, @E_MACL, 16
                MOVE    @V_TXF+70, 0x63825363
                MOVE    R6, 4*71        ; the byte of the first option
                MOVE    R1, 53
                CALL    dhcp_put
                MOVE    R1, 1
                CALL    dhcp_put
                AND     R1, R5, 0xFF
                CALL    dhcp_put
                MOVE    R4, @E_IP
                CMP     R5, DHCP_REQUEST
        ?Z      MOVE    R4, @V_DIP
                CMP     R5, DHCP_RENEW
        ?!C     MOVE    R4, 0           ; a renewal's
                MOVE    R1, 50
                CALL    dhcp_addr
                MOVE    R4, 0
                CMP     R5, DHCP_REQUEST
        ?Z      MOVE    R4, @V_DSRV
                MOVE    R1, 54
                CALL    dhcp_addr
                CMP     R5, DHCP_RENEW
        ?C      JMP     :+
                MOVE    @V_TXF+7, @E_IP  ; a renewal's: from E_IP,
                MOVE    @V_TXF+13, 0    ; no broadcast flag,
                MOVE    @V_TXF+14, @E_IP  ; and ciaddr
                CMP     R5, DHCP_RENEW
        ?!Z     JMP     :+
                MOVE    @V_TXF, @V_LMACH  ; to the server
                MOVE    @V_TXF+1, @V_LMACL
                MOVE    @V_TXF+8, @V_LSRV
:
                MOVE    R4, R6
                MOVE    R5, D_PARAMS
                CALL    dhcp_str
                MOVE    R1, 12          ; the host name
                CALL    dhcp_code
                MOVE    R5, TEXT_B+4*S_HOST
                CALL    dhcp_str
                SHL     R5, @E_MACL, 8  ; the last three bytes, from the top
:
                SHR     R1, R5, 28
                CMP     R1, 10
        ?!C     ADD     R1, R1, 0x27    ; a to f
                ADD     R1, R1, 0x30
                CALL    dhcp_put
                SHL     R5, R5, 4
                SUB     R1, R6, R4
                CMP     R1, 15          ; the length, 8 and 6 digits
        ?!Z     JMP     :-
                CALL    dhcp_len
                MOVE    R1, 60          ; the vendor class
                CALL    dhcp_code
                MOVE    R5, TEXT_B+4*S_VCLASS
                CALL    dhcp_str
                MOVE    R5, TEXT_B+4*VERSION
                CALL    dhcp_str
                CALL    dhcp_len
                MOVE    R1, 0xFF        ; the end
                CALL    dhcp_put
dhcp_go
                MOVE    R1, V_TXF
                CALL    ip_csum
                MOVE    R1, V_TXF
                MOVE    R2, DHCP_LEN
                JMP     eth_send        ; which returns to the caller

; dhcp_put: the byte R1 written to byte R6 of V_TXF, which is 0 before,
; a frame's byte as the send buffer has it, and R6 the next byte. Uses
; R1-R3.
dhcp_put
                SHR     R2, R6, 2
                ADD     R2, R2, V_TXF
                AND     R3, R6, 3
                XOR     R3, R3, 3
                SHL     R3, R3, 3       ; 24 for the first byte of a word
                SHL     R1, R1, R3
                OR      @R2, @R2, R1
                ADD     R6, R6, 1
                RET

; dhcp_addr: the option R1 of the address R4, 4 bytes, put at R6, unless
; R4 is 0. Uses R1-R4.
dhcp_addr
                TST     R4
        ?Z      RET
                PUSH    R5
                CALL    dhcp_put
                MOVE    R1, 4
                CALL    dhcp_put
                MOVE    R5, 4           ; the bytes left
:
                ROL     R4, R4, 8       ; the top byte to the bottom
                AND     R1, R4, 0xFF
                CALL    dhcp_put
                SUB[M]  R5, R5, 1
        ?!Z     JMP     :-
                POP     R5
                RET

; dhcp_code: the code R1 of an option put at R6, and its length left 0, at
; R4. Uses R1-R4.
dhcp_code
                CALL    dhcp_put
                MOVE    R4, R6
                ADD     R6, R6, 1
                RET

; dhcp_str: the string at R5, up to its 0, put at R6, as long as the
; option of the length at R4 has fewer than DHCP_SMAX bytes, so at most
; DHCP_SMAX. Uses R1-R3, and R5.
dhcp_str
                SUB     R1, R6, R4
                CMP     R1, DHCP_SMAX+1
        ?!C     RET                     ; full
                MOVE[M] R1, @R5++
        ?Z      RET
                CALL    dhcp_put
                JMP     dhcp_str

; dhcp_len: the length of the option, from R4 to R6, put at R4.
; Uses R1-R3, and R5.
dhcp_len
                SUB     R1, R6, R4
                SUB     R1, R1, 1
                MOVE    R5, R6
                MOVE    R6, R4
                CALL    dhcp_put
                MOVE    R6, R5
                RET

; dhcp_wait: the reply of the type R1, DHCP_OFFER or DHCP_ACK, to the
; transaction V_XID, within DHCP_WAIT microseconds. R1 = its type, or
; DHCP_NAK when an ACK is waited for and a NAK comes, or 0 when none came.
; The address, the server, the mask, the gateway, the DNS server, and the
; NTP server of the reply that is waited for are copied to V_DIP, V_DSRV,
; V_DMASK, V_DGW, V_DDNS, and V_DNTP. A reply of the type without an
; address is passed over, so that the station's address is never made 0. It polls with
; net_step, which copies a datagram to port 68 to V_RXF, and takes the
; other frames where they go. Uses R1-R6, and R7 and R8 across the calls,
; saved.
dhcp_wait
                PUSH    R7
                PUSH    R8
                MOVE    R7, R1
                MOVE    R8, @io.us      ; the start
dhcp_listen
                CALL    net_step
                TST     R1
        ?Z      JMP     :+
                CALL    dhcp_parse
                CMP     R1, R7
        ?Z      JMP     :++
                CMP     R1, DHCP_NAK
        ?!Z     JMP     :+
                CMP     R7, DHCP_ACK
        ?Z      JMP     dhcp_wait_end   ; a NAK, R1
:
                SUB     R1, @io.us, R8
                CMP     R1, DHCP_WAIT
        ?C      JMP     dhcp_listen
                MOVE    R1, 0
                JMP     dhcp_wait_end
:
                TST     @V_PIP
        ?Z      JMP     :--             ; no address: passed over
                CALL    dhcp_keep
dhcp_wait_end
                POP     R8
                POP     R7
                RET

; dhcp_keep: the address, the server, the mask, the gateway, the DNS
; server, and the NTP server of the reply that dhcp_parse took last, V_PIP and the rest,
; copied to V_DIP and the rest. Uses no register.
dhcp_keep
                MOVE    @V_DIP, @V_PIP
                MOVE    @V_DSRV, @V_PSRV
                MOVE    @V_DMASK, @V_PMASK
                MOVE    @V_DGW, @V_PGW
                MOVE    @V_DDNS, @V_PDNS
                MOVE    @V_DNTP, @V_PNTP
                RET

; dhcp_parse: the frame of R1 bytes at V_RXF, if it is a DHCP reply to the
; transaction V_XID: an IPv4 packet with a header of 5 words, UDP from port
; 67 to 68, a BOOTP reply, and the magic cookie. Its checksums are not
; checked, as the FCS was. R1 = the message type of option 53, or 0 when
; it is no reply of ours or has no type, and V_PIP, V_PSRV, V_PMASK,
; V_PGW, V_PDNS, and V_PNTP are its address, and the options 54, 1, 3, 6,
; and 42, the first address of each, V_PLEASE, V_PT1, and V_PT2 the options 51, 58,
; and 59, each 0 without them, and V_PMACH and V_PMACL the MAC address
; of the frame's source. The options are walked from byte 284 of the
; buffer up to 255, or the end of the frame, R8, the byte after its last;
; R7 is the option, and R5 the type. Uses R1-R6, and R7 and R8 across the
; calls, saved.
dhcp_parse
                PUSH    R7
                PUSH    R8
                ADD     R8, R1, 2
                MOVE    R5, 0
                CMP     R1, 282         ; up to the cookie
        ?C      JMP     dhcp_parse_end
                AND     R2, @V_RXF+3, 0xFFFF
                CMP     R2, 0x0800
        ?!Z     JMP     dhcp_parse_end
                SHR     R2, @V_RXF+4, 24
                CMP     R2, 0x45
        ?!Z     JMP     dhcp_parse_end
                SHR     R2, @V_RXF+6, 16
                AND     R2, R2, 0xFF
                CMP     R2, 17          ; UDP
        ?!Z     JMP     dhcp_parse_end
                CMP     @V_RXF+9, 0x00430044
        ?!Z     JMP     dhcp_parse_end
                SHR     R2, @V_RXF+11, 24
                CMP     R2, 2           ; a reply
        ?!Z     JMP     dhcp_parse_end
                CMP     @V_RXF+12, @V_XID
        ?!Z     JMP     dhcp_parse_end
                CMP     @V_RXF+70, 0x63825363
        ?!Z     JMP     dhcp_parse_end
                MOVE    @V_PIP, @V_RXF+15
                MOVE    @V_PSRV, 0
                MOVE    @V_PMASK, 0
                MOVE    @V_PGW, 0
                MOVE    @V_PDNS, 0
                MOVE    @V_PNTP, 0
                MOVE    @V_PLEASE, 0
                MOVE    @V_PT1, 0
                MOVE    @V_PT2, 0
                SHR     @V_PMACH, @V_RXF+2, 16
                SHL     R1, @V_RXF+2, 16
                SHR     R2, @V_RXF+3, 16
                OR      @V_PMACL, R1, R2
                MOVE    R7, 284
dhcp_opt
                CMP     R7, R8
        ?!C     JMP     dhcp_parse_end  ; at the end of the frame
                MOVE    R1, R7
                CALL    rx_byte
                MOVE[M] R6, R1          ; the option's code
        ?Z      ADD     R7, R7, 1       ; a pad
        ?Z      JMP     dhcp_opt
                CMP     R6, 255
        ?Z      JMP     dhcp_parse_end
                ADD     R1, R7, 1
                CMP     R1, R8
        ?!C     JMP     dhcp_parse_end  ; no length
                CALL    rx_byte
                MOVE    R4, R1          ; the length
                ADD     R1, R7, 2       ; the value
                ADD     R7, R1, R4      ; the next option
                CMP     R8, R7
        ?C      JMP     dhcp_parse_end  ; past the end
                TST     R4
        ?Z      JMP     dhcp_opt
                CMP     R6, 53
        ?Z      JMP     dhcp_type
                CMP     R4, 4
        ?C      JMP     dhcp_opt        ; too short for an address or a time
                CMP     R6, 51
        ?Z      MOVE    R6, V_PLEASE
        ?Z      JMP     :+
                CMP     R6, 58
        ?Z      MOVE    R6, V_PT1
        ?Z      JMP     :+
                CMP     R6, 59
        ?Z      MOVE    R6, V_PT2
        ?Z      JMP     :+
                CMP     R6, 1
        ?Z      MOVE    R6, V_PMASK
        ?Z      JMP     :+
                CMP     R6, 3
        ?Z      MOVE    R6, V_PGW
        ?Z      JMP     :+
                CMP     R6, 6
        ?Z      MOVE    R6, V_PDNS
        ?Z      JMP     :+
                CMP     R6, 42
        ?Z      MOVE    R6, V_PNTP
        ?Z      JMP     :+
                CMP     R6, 54
        ?!Z     JMP     dhcp_opt
                MOVE    R6, V_PSRV
:
                CALL    rx_long
                MOVE    @R6, R1
                JMP     dhcp_opt
dhcp_type
                CALL    rx_byte
                MOVE    R5, R1
                JMP     dhcp_opt
dhcp_parse_end
                MOVE    R1, R5
                POP     R8
                POP     R7
                RET

; The lease (RFC 2131 §4.4.5), which net_dhcp keeps with lease_take, and
; net_poll renews, only while the network is on: at T1 a REQUEST to its
; server by unicast, at the MAC address of its ACK's frame, as net_poll
; sends no ARP, and again every LEASE_AGAIN ticks until T2; from T2
; broadcast, as often, until the end. Its times are on the coarse clock,
; arp_tick, as they are hours away. The housekeeping deadline, V_LDUE, on
; the fine clock, is armed for the next REQUEST, or LEASE_FAR ticks ahead
; if that is farther, while the network is on, and tcp_rearm takes it
; into the nearest deadline, V_NDUE. An ACK sets the times again, and
; writes E_IP if it has another address; a NAK, or the end, forgets the
; lease, and the address stays. A REQUEST that is due while a wait of the
; ROM's own uses V_TXF goes a tick later.

; lease_take: the lease of the ACK that dhcp_parse took last kept: its
; server and its MAC address, and T1, T2, and the end from now, from the
; options 58, 59, and 51, or half and 7/8 of the lease without the first
; two; armed while the network is on. A lease of 0xFFFFFFFF, never to be
; renewed, or none, forgets the lease. Uses R1-R6.
lease_take
                MOVE    R4, @V_PLEASE
                SUB     R1, R4, 1
                CMP     R1, 0xFFFFFFFE
        ?!C     JMP     lease_forget    ; 0 or 0xFFFFFFFF
                MOVE    @V_LSRV, @V_PSRV
                MOVE    @V_LMACH, @V_PMACH
                MOVE    @V_LMACL, @V_PMACL
                CALL    arp_tick
                MOVE    R5, R1          ; now
                MOVE    R1, R4
                CALL    lease_ticks
                ADD     @V_LEXP, R5, R1
                MOVE[M] R1, @V_PT2
        ?Z      SHR     R1, R4, 3
        ?Z      SUB     R1, R4, R1
                CALL    lease_ticks
                ADD     @V_LT2, R5, R1
                MOVE[M] R1, @V_PT1
        ?Z      SHR     R1, R4, 1
                CALL    lease_ticks
                ADD     @V_LNEXT, R5, R1
                MOVE    @V_LEASE, 1
                AND[M]  R0, @ETH_CSR, ETH_ON
        ?Z      RET
                JMP     lease_arm       ; which returns to the caller

; lease_ticks: R1 = the R1 seconds in ticks of arp_tick, 2^20
; microseconds, a little less: R1 less R1/16, plus R1/64. Uses R2.
lease_ticks
                SHR     R2, R1, 4
                SUB     R2, R1, R2
                SHR     R1, R1, 6
                ADD     R1, R2, R1
                RET

; lease_arm: the housekeeping deadline armed for the next REQUEST, or
; LEASE_FAR ticks ahead if that is farther, and the nearest deadline
; again, tcp_rearm. Uses R1-R3.
lease_arm
                CALL    arp_tick
                SUB     R3, @V_LNEXT, R1
                CMP     @V_LNEXT, R1
        ?C      MOVE    R3, 0           ; past
                CMP     R3, LEASE_FAR
        ?!C     MOVE    R3, LEASE_FAR
                SHL     R3, R3, 20
                CALL    net_clock
                ADD     @V_LDUE, R1, R3
                MOVE    @V_LARM, 1
                JMP     tcp_rearm       ; which returns to the caller

; lease_due: for net_due, the housekeeping deadline, due: at the end, the
; lease forgotten; else a REQUEST if one is due, by unicast before T2 and
; with a server, else broadcast, and the next a LEASE_AGAIN ticks later,
; at T2 or the end at the latest. Uses R1-R6.
lease_due
                CALL    arp_tick
                CMP     R1, @V_LNEXT
        ?C      JMP     lease_arm       ; not yet: LEASE_FAR passed
                CMP     R1, @V_LEXP
        ?!C     JMP     lease_forget    ; its end
                TST     @V_NWAIT
        ?!Z     ADD     @V_LNEXT, R1, 1  ; a wait of the ROM's own uses V_TXF
        ?!Z     JMP     lease_arm
                ADD     R5, R1, LEASE_AGAIN
                MOVE    R6, DHCP_REBIND
                CMP     R1, @V_LT2
        ?!C     JMP     :+              ; from T2
                CMP     R5, @V_LT2
        ?!C     MOVE    R5, @V_LT2
                TST     @V_LSRV
        ?!Z     MOVE    R6, DHCP_RENEW
:
                CMP     R5, @V_LEXP
        ?!C     MOVE    R5, @V_LEXP
                MOVE    @V_LNEXT, R5
                MOVE    R1, R6
                CALL    dhcp_send
                JMP     lease_arm       ; which returns to the caller

; lease_reply: the DHCP reply of R1 bytes at V_RXF, for a lease kept: an
; ACK with an address sets the lease's times again, with lease_take, and
; writes E_IP if the address is another, which ends the TCP connections
; in E_TRESET; a NAK forgets the lease; anything else is passed over.
; Uses R1-R6.
lease_reply
                CALL    dhcp_parse
                CMP     R1, DHCP_NAK
        ?Z      JMP     lease_forget    ; which returns to the caller
                CMP     R1, DHCP_ACK
        ?!Z     RET
                MOVE[M] R1, @V_PIP
        ?Z      RET                     ; no address
                CMP     R1, @E_IP
        ?!Z     MOVE    @E_IP, R1
        ?!Z     CALL    tcp_resetall
                JMP     lease_take      ; which returns to the caller

; lease_forget: no lease kept, and no housekeeping deadline. Uses R1-R3.
lease_forget
                MOVE    @V_LEASE, 0
                MOVE    @V_LARM, 0
                JMP     tcp_rearm       ; which returns to the caller

; The DNS client (RFC 1035), dns_lookup, entry 25 (issue #111). A query
; has one question, type A, class IN, with RD set, and goes from a local
; port of its own, V_NWAIT, to port 53 of the DNS server, V_DNS. It is
; built in V_TXF as the send buffer has it, the message from word UDP_HDR
; and the name from byte DNS_NAME, with dhcp_put and dhcp_len, and is sent
; again after DNS_WAIT microseconds, DNS_TRIES times in all, with the same
; ID, V_QID. The poll copies a datagram to the port to V_RXF, where
; dns_parse reads it. No answer is kept: a program keeps the address.

; dns_lookup: entry 25. R1 the byte address of a name, up to a 0 byte, R2
; the word address of the result, where the name's IPv4 address is
; written. A name of four decimal numbers with dots, as i takes them, is
; the address, with no query and no IP address needed. Else the name's
; labels must have 1 to 63 bytes, 253 in all, with a dot after the last
; allowed; the query goes to the next hop of net_hop, which may wait for
; ARP up to 3 seconds, and the answer is waited for up to DNS_WAIT
; microseconds after each send, polling. The port for Ethernet frames is
; enabled by net_on, and disabled by net_off at the end, unless the
; endpoint is open. R1 = 0, or E_NOIP, E_NODNS, E_DNSNAME, E_NOROUTE,
; E_DNSTIME, E_DNSFAIL, or the E_DNSNAME of an answer. Uses R1-R6, and
; R7-R10 across the calls, saved: the name, and then the sends left, the
; result's word, the time of the send, and the bytes of the frame.
dns_lookup
                PUSH    R7
                PUSH    R8
                PUSH    R9
                PUSH    R10
                MOVE    R7, R1
                MOVE    R1, R2
                CALL    net_waddr
                MOVE    R8, R1
                MOVE    R1, R7
                CALL    get_ip
                TST     R2
        ?Z      JMP     :+
                TST     @R3
        ?!Z     JMP     :+              ; a name that starts as an address
                MOVE    @R8, R1
                MOVE    R1, 0
                JMP     dns_end
:
                MOVE    R1, E_NOIP
                TST     @E_IP
        ?Z      JMP     dns_end
                MOVE    R1, E_NODNS
                TST     @V_DNS
        ?Z      JMP     dns_end
; The message: the header, and the question
                MOVE    R1, V_TXF
                MOVE    R2, DHCP_WORDS
:
                MOVE    @R1++, 0
                SUB[M]  R2, R2, 1
        ?!Z     JMP     :-
                CALL    net_clock
                AND     @V_QID, R1, 0xFFFF
                SHR     R1, R1, 4
                AND     R1, R1, 0x3FFF
                OR      R1, R1, 0xC000  ; the port, 49152 to 65535
                CMP     R1, @V_UPORT
        ?Z      XOR     R1, R1, 1       ; and not the endpoint's
                MOVE    R9, R1
                SHL     R1, @V_QID, 16
                OR      @V_TXF+UDP_HDR, R1, 0x0100  ; the ID, a query, RD
                MOVE    @V_TXF+UDP_HDR+1, 0x00010000  ; one question
                MOVE    R4, DNS_NAME    ; the length of the label
                ADD     R6, R4, 1       ; the next byte
dns_char
                SUB     R1, R6, DNS_NAME
                CMP     R1, 256
        ?!C     JMP     dns_badname     ; too long, which also ends a name with no 0
                SUB     R1, R6, R4
                CMP     R1, 65
        ?!C     JMP     dns_badname     ; a label of 64 bytes
                MOVE[M] R1, @R7++
        ?Z      JMP     :+
                CMP     R1, 0x2E        ; .
        ?Z      JMP     dns_dot
                CALL    dhcp_put
                JMP     dns_char
dns_dot
                SUB     R1, R6, R4
                CMP     R1, 1
        ?Z      JMP     dns_badname     ; a label of 0 bytes
                CALL    dhcp_len
                MOVE    R4, R6
                ADD     R6, R6, 1
                JMP     dns_char
:
                SUB     R1, R6, R4
                CMP     R1, 1
        ?!Z     JMP     :+
                CMP     R4, DNS_NAME
        ?Z      JMP     dns_badname     ; no name
                JMP     :++             ; a dot at the end: the 0 is there
:
                CALL    dhcp_len
                ADD     R6, R6, 1       ; the 0 that ends the name
:
                SUB     R1, R6, DNS_NAME
                CMP     R1, 256
        ?!C     JMP     dns_badname     ; more than 255 bytes, so 253 with no dots at the ends
                ADD     R6, R6, 1
                MOVE    R1, 1           ; type A
                CALL    dhcp_put
                ADD     R6, R6, 1
                MOVE    R1, 1           ; class IN
                CALL    dhcp_put
                SUB     R10, R6, 2      ; the bytes of the frame
; The next hop, and the headers. V_NWAIT keeps the network on through
; the ARP.
                MOVE    @V_NWAIT, R9
                CALL    net_on
                MOVE    R1, @V_DNS
                CALL    net_hop         ; whose ARP may use the words before UDP_HDR
                TST     R1
        ?!Z     MOVE    R1, E_NOROUTE
        ?!Z     JMP     dns_off
                MOVE    R1, V_TXF
                MOVE    R4, @V_DNS
                SHL     R5, R9, 16
                OR      R5, R5, DNS_PORT
                SUB     R6, R10, 42
                CALL    udp_head
                MOVE    R7, DNS_TRIES
dns_send
                CALL    ip_ident
                MOVE    @V_TXF+5, R1
                MOVE    R1, V_TXF
                CALL    ip_csum
                MOVE    R1, V_TXF
                MOVE    R2, R10
                CALL    eth_send
                MOVE    R9, @io.us
dns_wait
                CALL    net_step
                TST     R1
        ?Z      JMP     :+
                CALL    dns_parse
                CMP     R1, 1
        ?Z      JMP     :+              ; passed over
                TST     R1
        ?Z      MOVE    @R8, R2
                JMP     dns_off
:
                SUB     R1, @io.us, R9
                CMP     R1, DNS_WAIT
        ?C      JMP     dns_wait
                SUB[M]  R7, R7, 1
        ?!Z     JMP     dns_send
                MOVE    R1, E_DNSTIME
dns_off
                MOVE    @V_NWAIT, 0
                CALL    net_off
                JMP     dns_end
dns_badname
                MOVE    R1, E_DNSNAME
dns_end
                POP     R10
                POP     R9
                POP     R8
                POP     R7
                RET

; dns_parse: the datagram of R1 bytes at V_RXF, to the query's port, if
; it is the answer: from the DNS server's address and port 53, with the
; query's ID, QR set, and one question. R1 = 1 when it is not, and it is
; passed over. Else R1 = 0, with R2 the address of the first record of
; the answer section of type A, class IN, and 4 bytes of data, past any
; CNAMEs, which are not checked against the chain; or E_DNSNAME for RCODE
; 3, or no such record; or E_DNSFAIL for another RCODE, TC set, or an
; answer that ends inside a record. A name is skipped up to its 0 byte or
; its first compression pointer, which ends it, so a loop of pointers is
; never followed. R5 is the byte of the buffer after the message, by the
; frame's length and the UDP length, the smaller, R6 the byte read, and
; R4 the records left. Uses R1-R6, and R7 across the calls, saved.
dns_parse
                PUSH    R7
                ADD     R5, R1, 2
                MOVE    R1, 1
                CMP     @V_RXF+7, @V_DNS
        ?!Z     JMP     dns_parse_end
                SHR     R2, @V_RXF+9, 16
                CMP     R2, DNS_PORT
        ?!Z     JMP     dns_parse_end
                SHR     R2, @V_RXF+10, 16
                ADD     R2, R2, 36      ; the end by the UDP length
                CMP     R2, R5
        ?C      MOVE    R5, R2
                CMP     R5, DNS_NAME
        ?C      JMP     dns_parse_end   ; no header
                MOVE    R7, @V_RXF+UDP_HDR
                SHR     R2, R7, 16
                CMP     R2, @V_QID
        ?!Z     JMP     dns_parse_end
                AND[M]  R0, R7, 0x8000  ; QR
        ?Z      JMP     dns_parse_end
                SHR     R2, @V_RXF+UDP_HDR+1, 16
                CMP     R2, 1
        ?!Z     JMP     dns_parse_end   ; not one question
                MOVE    R1, E_DNSFAIL
                AND[M]  R0, R7, 0x0200  ; TC
        ?!Z     JMP     dns_parse_end
                AND[M]  R2, R7, 0x000F  ; RCODE
        ?Z      JMP     :+
                CMP     R2, 3
        ?Z      MOVE    R1, E_DNSNAME
                JMP     dns_parse_end
:
                AND     R4, @V_RXF+UDP_HDR+1, 0xFFFF  ; the answers
                MOVE    R6, DNS_NAME
                CALL    dns_skip
        ?!Z     JMP     dns_fail
                ADD     R6, R6, 4       ; the type and the class
dns_record
                MOVE    R1, E_DNSNAME
                SUB[M]  R4, R4, 1
        ?C      JMP     dns_parse_end   ; no record of type A
                CALL    dns_skip
        ?!Z     JMP     dns_fail
                ADD     R1, R6, 10
                CMP     R5, R1
        ?C      JMP     dns_fail        ; ends in the record's fields
                MOVE    R1, R6
                CALL    rx_long
                MOVE    R7, R1          ; its type and its class
                ADD     R1, R6, 8
                CALL    rx_long
                SHR     R2, R1, 16      ; the bytes of its data
                ADD     R6, R6, 10
                ADD     R3, R6, R2      ; the next record
                CMP     R5, R3
        ?C      JMP     dns_fail        ; ends in the record's data
                CMP     R7, 0x00010001  ; A, IN
        ?!Z     JMP     :+
                CMP     R2, 4
        ?Z      JMP     :++
:
                MOVE    R6, R3
                JMP     dns_record
:
                MOVE    R1, R6
                CALL    rx_long
                MOVE    R2, R1
                MOVE    R1, 0
                JMP     dns_parse_end
dns_fail
                MOVE    R1, E_DNSFAIL
dns_parse_end
                POP     R7
                RET

; dns_skip: the name at byte R6 of V_RXF skipped, up to R5, the byte after
; the message. R6 = the byte after it, and Z set; or Z clear when it does
; not end before R5, or has a label of the types 0x40 or 0x80. Uses R1-R3.
dns_skip
                CMP     R6, R5
        ?!C     JMP     :++             ; at the end
                MOVE    R1, R6
                CALL    rx_byte
                ADD     R6, R6, 1
                TST     R1
        ?Z      RET                     ; the 0 that ends it
                CMP     R1, 0xC0
        ?C      JMP     :+
                ADD     R6, R6, 1       ; a pointer, which ends it
                CMP     R5, R6
        ?C      JMP     :++
                TST     R0
                RET
:
                CMP     R1, 0x40
        ?!C     JMP     :+              ; 0x40 to 0xBF
                ADD     R6, R6, R1
                JMP     dns_skip
:
                MOVE[M] R1, 1
                RET

; time ntp [SERVER] [+HH:MM | -HH:MM]: the clock of the time of day set
; from a time server by SNTP (RFC 4330), and the MEGA65's real-time clock
; with it, by clock_ntp of clock.c (issue #127). SERVER is a name, which
; dns_lookup looks up, or an IP address; without it the server is the NTP
; server of DHCP's option 42, V_NTP, and without that NTP_POOL. The
; offset is local time less UTC, which clock_zone of clock.c reads, and
; +00:00 without it. The query is 48 bytes from a local port of its own,
; V_NWAIT, to port 123: version 4, mode 3, and the transmit timestamp,
; which the fine clock and the microseconds make, as the answer's
; originate timestamp must be the same. It is built in V_TXF as dns_lookup
; builds its query, and sent again after NTP_WAIT microseconds, NTP_TRIES
; times in all. ntp_parse takes the answer. There is no correction for
; the delay, which is far below the second that the clock shows. R7 is
; the server's name, 0 for none, then the sends left, R8 the offset, R9
; the server's address, and R10 the time of the send.
time_ntp
                MOVE    R7, 0
                MOVE    R8, 0
:
                CMP     @R1, 0x20
        ?Z      ADD     R1, R1, 1
        ?Z      JMP     :-
                TST     @R1
        ?Z      JMP     ntp_server      ; neither
                CMP     @R1, 0x2B       ; +
        ?Z      JMP     ntp_zone
                CMP     @R1, 0x2D       ; -
        ?Z      JMP     ntp_zone
                MOVE    R7, R1          ; the server's name, up to a blank
:
                ADD     R1, R1, 1
                TST     @R1
        ?Z      JMP     ntp_server
                CMP     @R1, 0x20
        ?!Z     JMP     :-
                MOVE    @R1++, 0        ; the name ends, for dns_lookup
:
                CMP     @R1, 0x20
        ?Z      ADD     R1, R1, 1
        ?Z      JMP     :-
                TST     @R1
        ?Z      JMP     ntp_server
ntp_zone
                CALL    _clock_zone
                CMP     R1, 1
        ?Z      JMP     ntp_bad
                MOVE    R8, R1
; The server's address
ntp_server
                MOVE    R1, E_NOIP
                TST     @E_IP
        ?Z      JMP     ntp_fail
                MOVE[M] R9, @V_NTP
                TST     R7
        ?!Z     JMP     :+
                TST     R9
        ?!Z     JMP     ntp_query       ; DHCP's
                MOVE    R7, TEXT_B+4*S_POOL
:
                MOVE    R1, R7
                MOVE    R2, V_NTPIP
                CALL    dns_lookup
                TST     R1
        ?!Z     JMP     ntp_fail
                MOVE    R9, @V_NTPIP
; The query, from a port of its own, which is not the endpoint's
ntp_query
                MOVE    R1, V_TXF
                MOVE    R2, UDP_HDR+12
:
                MOVE    @R1++, 0
                SUB[M]  R2, R2, 1
        ?!Z     JMP     :-
                CALL    net_clock
                MOVE    @V_TXF+UDP_HDR+10, R1  ; the transmit timestamp
                XOR     @V_TXF+UDP_HDR+11, @io.us, @E_MACL
                SHR     R1, R1, 4
                AND     R1, R1, 0x3FFF
                OR      R1, R1, 0xC000  ; the port, 49152 to 65535
                CMP     R1, @V_UPORT
        ?Z      XOR     R1, R1, 1       ; and not the endpoint's
                MOVE    R10, R1
                MOVE    @V_TXF+UDP_HDR, 0x23000000  ; version 4, mode 3
                MOVE    @V_NWAIT, R10
                CALL    net_on
                MOVE    R1, R9
                CALL    net_hop         ; whose ARP may use the words before UDP_HDR
                TST     R1
        ?!Z     MOVE    R1, E_NOROUTE
        ?!Z     JMP     ntp_off
                MOVE    R1, V_TXF
                MOVE    R4, R9
                SHL     R5, R10, 16
                OR      R5, R5, NTP_PORT
                MOVE    R6, 48
                CALL    udp_head
                MOVE    R7, NTP_TRIES
ntp_send
                CALL    ip_ident
                MOVE    @V_TXF+5, R1
                MOVE    R1, V_TXF
                CALL    ip_csum
                MOVE    R1, V_TXF
                MOVE    R2, 90          ; the bytes of the frame
                CALL    eth_send
                MOVE    R10, @io.us
ntp_wait
                CALL    net_step
                TST     R1
        ?Z      JMP     :+
                CALL    ntp_parse
                CMP     R1, 1
        ?!Z     JMP     ntp_off         ; not passed over
:
                SUB     R1, @io.us, R10
                CMP     R1, NTP_WAIT
        ?C      JMP     ntp_wait
                SUB[M]  R7, R7, 1
        ?!Z     JMP     ntp_send
                MOVE    R1, E_NTPTIME
ntp_off
                MOVE    @V_NWAIT, 0
                CALL    net_off
                TST     R1
        ?!Z     JMP     ntp_fail
                MOVE    R1, @V_RXF+UDP_HDR+10  ; the transmit timestamp
                MOVE    R2, @V_RXF+UDP_HDR+11
                MOVE    R3, R8
                MOVE    R4, R9
                CALL    _clock_ntp
                TST     R1
        ?Z      JMP     main
                MOVE    R1, E_NTPBAD    ; a time that the clock does not take
; An error: its line, and for a kiss-o'-death the server's code, the 4
; characters of the reference ID, with ? for one that does not print
ntp_fail
                MOVE    R7, R1
                MOVE    R2, NTP_ERRORS
:
                MOVE    R1, @R2++
                MOVE    R3, @R2++
                CMP     R1, R7
        ?!Z     JMP     :-              ; the list ends with E_NTPKOD
                MOVE    R1, R3
                CALL    puts_b
                CMP     R7, E_NTPKOD
        ?!Z     JMP     ntp_end
                MOVE    R7, @V_RXF+UDP_HDR+3
                MOVE    R8, 4
:
                ROL     R7, R7, 8
                AND     R1, R7, 0xFF
                SUB     R2, R1, 0x20
                CMP     R2, 0x5F
        ?!C     MOVE    R1, 0x3F        ; ?
                CALL    mon_putc
                SUB[M]  R8, R8, 1
        ?!Z     JMP     :-
ntp_end
                CALL    _io_crlf
                JMP     main
ntp_bad
                MOVE    R1, S_BADNTP
                CALL    puts_b_crlf
                JMP     main

; ntp_parse: the datagram of R1 bytes at V_RXF, to the query's port, if it
; is the answer of the server R9: from its port 123, with 48 bytes of data
; at least, mode 4, and the originate timestamp of the query's transmit
; timestamp. R1 = 1 when it is not, and it is passed over. Else R1 = 0,
; or E_NTPKOD for a stratum of 0, a kiss-o'-death, or E_NTPBAD for a leap
; indicator of 3, not synchronized, a stratum over 15, or a transmit
; timestamp of 0, which is not to be trusted. Uses R1 and R2.
ntp_parse
                CMP     R1, 90
        ?C      JMP     :+              ; too short
                CMP     @V_RXF+7, R9
        ?!Z     JMP     :+
                SHR     R1, @V_RXF+9, 16
                CMP     R1, NTP_PORT
        ?!Z     JMP     :+
                SHR     R1, @V_RXF+10, 16
                CMP     R1, 56          ; the UDP length
        ?C      JMP     :+
                MOVE    R2, @V_RXF+UDP_HDR
                SHR     R1, R2, 24
                AND     R1, R1, 7
                CMP     R1, 4           ; a server's
        ?!Z     JMP     :+
                CMP     @V_RXF+UDP_HDR+6, @V_TXF+UDP_HDR+10
        ?!Z     JMP     :+
                CMP     @V_RXF+UDP_HDR+7, @V_TXF+UDP_HDR+11
        ?!Z     JMP     :+
                SHR     R1, R2, 16
                AND[M]  R1, R1, 0xFF    ; the stratum
        ?Z      MOVE    R1, E_NTPKOD
        ?Z      RET
                CMP     R1, 16
        ?!C     JMP     :++
                SHR     R1, R2, 30
                CMP     R1, 3           ; not synchronized
        ?Z      JMP     :++
                OR[M]   R0, @V_RXF+UDP_HDR+10, @V_RXF+UDP_HDR+11
        ?Z      JMP     :++
                MOVE    R1, 0
                RET
:
                MOVE    R1, 1
                RET
:
                MOVE    R1, E_NTPBAD
                RET

; tftp IP[:PORT] [NAME]: the .bin file NAME of the TFTP server at IP
; (RFC 1350), read in octet mode through the UDP endpoint, which it opens
; on a port that udp_open picks, and closes at the end, and its lines
; written as load NAME writes them, with bin_line, and shown as l shows
; them. A NAME with * or ? is a pattern, which tools/tftpd.py answers with
; a listing of its files, whose lines are shown instead; no NAME is *.
; The RRQ goes to PORT, 69 by default, and the server's first DATA gives
; its TID; the
; packets of other hosts and TIDs are passed over. Each DATA of the block
; waited for is answered with its ACK, and a DATA of the block before
; with the ACK again; a block of less than 512 bytes is the last. A
; packet that has no answer within TFTP_WAIT microseconds is sent again,
; up to TFTP_TRIES times in all. An ERROR ends the load with its code and
; its message. R7 counts the sends left, and R8-R12 are bin_line's.
cmd_tftp
                MOVE    R1, R2
                MOVE    R2, TEXT_B+4*S_FTP
                CALL    match           ; R1 after ftp, or 0
                TST     R1
        ?Z      JMP     unknown
                TST     @R1
        ?Z      JMP     tftp_bad        ; tftp alone
                CMP     @R1, 0x20
        ?!Z     JMP     unknown         ; tftpx
:
                CMP     @R1, 0x20
        ?Z      ADD     R1, R1, 1
        ?Z      JMP     :-
                CALL    get_ip
                TST     R2
        ?Z      JMP     tftp_bad
                MOVE    @V_TSRV, R1
                MOVE    @V_TPORT, TFTP_PORT
                CMP     @R3, 0x3A       ; :
        ?!Z     JMP     tftp_name
                ADD     R3, R3, 1
                MOVE    R4, 0           ; the port
                MOVE    R5, R3          ; where it starts
:
                SUB     R2, @R3, 0x30
                CMP     R2, 10
        ?!C     JMP     :+              ; no digit
                ADD     R4, R4, R4      ; R4 is 10 * R4 + the digit
                ADD     R2, R2, R4
                SHL     R4, R4, 2
                ADD     R4, R4, R2
                CMP     R4, 0x10000
        ?!C     JMP     tftp_bad
                ADD     R3, R3, 1
                JMP     :-
:
                CMP     R3, R5
        ?Z      JMP     tftp_bad        ; a port without digits
                TST     R4
        ?Z      JMP     tftp_bad        ; port 0
                MOVE    @V_TPORT, R4
tftp_name
                MOVE    R7, TEXT_B+4*S_STAR
                TST     @R3
        ?Z      JMP     :+              ; no name: the listing of *
                CMP     @R3, 0x20
        ?!Z     JMP     tftp_bad        ; no blank after the address
                MOVE    R1, R3
                CALL    fs_name
                TST     R1
        ?Z      JMP     :+              ; only blanks
                MOVE    R7, R1
                CALL    rest_blank
        ?!Z     JMP     tftp_bad        ; a third word
:
                MOVE    @V_TLIST, 0
                MOVE    R1, R7
:
                MOVE[M] R2, @R1++
        ?Z      JMP     :+
                CMP     R2, 0x2A        ; *
        ?Z      MOVE    @V_TLIST, 1
                CMP     R2, 0x3F        ; ?
        ?Z      MOVE    @V_TLIST, 1
                JMP     :-
:
; The RRQ: the opcode 1, the name, a 0, octet, and a 0
                MOVE    R2, V_TPKT
                MOVE    @R2++, 0
                MOVE    @R2++, 1
:
                MOVE[M] @R2++, @R7++
        ?!Z     JMP     :-
                MOVE    R1, TEXT_B+4*S_OCTET
:
                MOVE[M] @R2++, @R1++
        ?!Z     JMP     :-
                SUB     @V_TLEN, R2, V_TPKT
                MOVE    R1, 0
                CALL    udp_open
                TST     R1
        ?N      JMP     tftp_fail
                MOVE    @V_TTID, 0
                MOVE    @V_TBLK, 1
                MOVE    @V_TLAST, 0
                MOVE    @V_TLINE, V_LINE
                CALL    load_pend
                MOVE    R8, 0
                MOVE    R9, 0xFFFFFFFF
                MOVE    R10, 0
                MOVE    R11, 0
                MOVE    R12, 0
tftp_try
                MOVE    R7, TFTP_TRIES
tftp_send
                MOVE    R1, @V_TSRV
                MOVE[M] R2, @V_TTID
        ?Z      MOVE    R2, @V_TPORT
                MOVE    R3, V_TPKT
                MOVE    R4, @V_TLEN
                CALL    udp_send
                TST     R1
        ?N      JMP     tftp_fail
                MOVE    @V_TTIME, @io.us
tftp_wait
                CALL    udp_next
                TST     R1
        ?Z      JMP     tftp_time
                CMP     @V_RXF+7, @V_TSRV
        ?!Z     JMP     tftp_wait       ; from another host
                SHR     R2, @V_RXF+9, 16  ; its port
                MOVE[M] R3, @V_TTID
        ?Z      JMP     :+
                CMP     R2, R3
        ?!Z     JMP     tftp_wait       ; from another TID
:
                SHR     R3, @V_RXF+UDP_HDR, 16  ; the opcode
                CMP     R3, 5
        ?Z      JMP     tftp_error
                CMP     R3, 3
        ?!Z     JMP     tftp_wait       ; no DATA
                CMP     R1, 4
        ?C      JMP     tftp_wait       ; too short
                AND     R4, @V_RXF+UDP_HDR, 0xFFFF  ; the block
                CMP     R4, @V_TBLK
        ?Z      JMP     :+
                ADD     R4, R4, 1
                AND     R4, R4, 0xFFFF
                CMP     R4, @V_TBLK
        ?!Z     JMP     tftp_wait
                TST     @V_TTID
        ?Z      JMP     tftp_wait
                JMP     tftp_send       ; the block before: its ACK again
:
                MOVE    @V_TTID, R2
                SUB     @V_TEND, R1, 4
                MOVE    R7, 0           ; the byte of the block
:
                CMP     R7, @V_TEND
        ?Z      JMP     :+
                ADD     R1, R7, 4*UDP_HDR+4
                CALL    rx_byte
                ADD     R7, R7, 1
                CALL    tftp_char
                JMP     :-
:
                MOVE    @V_TPKT, 0
                MOVE    @V_TPKT+1, 4
                MOVE    R1, @V_TBLK
                SHR     @V_TPKT+2, R1, 8
                AND     @V_TPKT+3, R1, 0xFF
                MOVE    @V_TLEN, 4
                ADD     R1, R1, 1
                AND     @V_TBLK, R1, 0xFFFF
                CMP     @V_TEND, 512
        ?!C     JMP     tftp_try        ; a full block, so more follow
                MOVE    R1, @V_TSRV     ; the last ACK
                MOVE    R2, @V_TTID
                MOVE    R3, V_TPKT
                MOVE    R4, 4
                CALL    udp_send
                CMP     @V_TLINE, V_LINE  ; the last line, with no end
        ?!Z     CALL    tftp_eol
                CALL    udp_close
                TST     @V_TLIST
        ?!Z     JMP     main            ; a listing, shown
                JMP     load_summary
tftp_time
                SUB     R1, @io.us, @V_TTIME
                CMP     R1, TFTP_WAIT
        ?C      JMP     tftp_wait
                SUB[M]  R7, R7, 1
        ?!Z     JMP     tftp_send
                CALL    udp_close
                MOVE    R1, S_NOTFTP
                CALL    puts_b_crlf
                JMP     main
; An ERROR: its code, and its message, up to a 0 or the end of the
; datagram, without control codes. R7 is the byte, and R8 the end.
tftp_error
                MOVE    R7, 4*UDP_HDR+4
                ADD     R8, R1, 4*UDP_HDR
                CALL    udp_close
                MOVE    R1, S_TFTPERR
                CALL    puts_b
                AND     R1, @V_RXF+UDP_HDR, 0xFFFF
                CALL    _io_putdec
                MOVE    R1, S_UCOMMA
                CALL    puts_b
:
                CMP     R7, R8
        ?!C     JMP     :+
                MOVE    R1, R7
                CALL    rx_byte
                TST     R1
        ?Z      JMP     :+
                ADD     R7, R7, 1
                SUB     R2, R1, 0x20
                CMP     R2, 0x5F
        ?!C     JMP     :-              ; a control code
                CALL    mon_putc
                JMP     :-
:
                CALL    _io_crlf
                JMP     main
; An error of udp_open or udp_send: no IP address, or no route
tftp_fail
                MOVE    R7, R1
                CALL    udp_close
                MOVE    R1, S_NOIP
                CMP     R7, E_NOIP
        ?!Z     MOVE    R1, S_NOROUTE
                CALL    puts_b_crlf
                JMP     main
tftp_bad
                MOVE    R1, S_BADTFTP
                CALL    puts_b_crlf
                JMP     main

; tftp_char: the byte R1 of a DATA, into the line at V_TLINE, as fat_load
; of fat32.c takes the bytes of a file: CR, LF, or CR LF ends a line,
; which is shown for a listing, or else goes to bin_line, or is counted
; and passed over when it is empty;
; TAB is a blank, and other control codes and bytes from 0x80 are dropped,
; and so are the bytes after LINE_MAX + 1. Uses R1-R6.
tftp_char
                MOVE    R2, @V_TLAST
                MOVE    @V_TLAST, R1
                CMP     R1, 0x0A
        ?!Z     JMP     :+
                CMP     R2, 0x0D
        ?Z      RET                     ; the LF of a CR LF
                JMP     tftp_eol
:
                CMP     R1, 0x0D
        ?Z      JMP     tftp_eol
                CMP     R1, 0x09
        ?Z      MOVE    R1, 0x20
                SUB     R2, R1, 0x20
                CMP     R2, 0x60
        ?!C     RET                     ; another control code, or from 0x80
                MOVE    R6, @V_TLINE
                CMP     R6, V_LINE+LINE_MAX+1
        ?Z      RET                     ; the line is over full
                MOVE    @R6++, R1
                MOVE    @V_TLINE, R6
                RET
tftp_eol
                MOVE    R6, @V_TLINE
                MOVE    @V_TLINE, V_LINE
                MOVE    @R6, 0
                MOVE    R1, V_LINE
                TST     @V_TLIST
        ?!Z     JMP     puts_crlf       ; a line of a listing, shown
                CMP     R6, V_LINE
        ?!Z     JMP     bin_line        ; which returns to the caller
                ADD     R11, R11, 1     ; an empty line, passed over
                RET

S_NODHCP
                .ASCII_B 'No answer from a DHCP server'
                .DAT    0
S_BGDHCP
                .ASCII_B ' from DHCP'
S_HOST          .ASCII_B 'nicemon-'
                .DAT    0
S_VCLASS
                .ASCII_B 'NiceMonMEGA65 '
S_MASK          .ASCII_B 'Mask '
S_GW            .ASCII_B 'Gateway '
                .DAT    0
S_DNS           .ASCII_B 'DNS server '
S_DSRV          .ASCII_B 'DHCP server '
                .DAT    0
D_PARAMS
                .DAT    55, 4, 1, 3, 6, 42, 0  ; option 55: the mask, the gateway, the DNS servers, and the NTP servers
S_FTP           .ASCII_B 'ftp'
S_OCTET         .ASCII_B 'octet'
S_STAR          .ASCII_B '*'
S_BADTFTP
                .ASCII_B 'tftp IP[:PORT] [NAME]: tftp 192.168.1.10 hello.bin loads, *.bin lists'
S_NOTFTP
                .ASCII_B 'No answer from the TFTP server'
S_TFTPERR
                .ASCII_B 'TFTP error '
S_NOIP          .ASCII_B 'No IP address; i sets one'
S_NOROUTE
                .ASCII_B 'No answer to ARP from the server, or from the gateway'
S_NTPSRV
                .ASCII_B 'NTP server '
S_POOL          .ASCII_B 'pool.ntp.org'
                .DAT    0
S_BADNTP
                .ASCII_B 'time ntp [SERVER] [+HH:MM | -HH:MM], local time less UTC: time ntp +01:00'
S_NODNS         .ASCII_B 'No DNS server; i dhcp gets one'
S_DNSTIME
                .ASCII_B 'No answer from the DNS server'
S_DNSNAME
                .ASCII_B 'No such name'
                .DAT    0
S_DNSFAIL
                .ASCII_B 'DNS error'
S_NONTP         .ASCII_B 'No answer from the time server'
S_NTPBAD
                .ASCII_B 'The time server is not to be trusted'
                .DAT    0
S_NTPKOD
                .ASCII_B 'The time server refused: '
; The errors of time ntp, and their texts, which E_NTPKOD ends
NTP_ERRORS
                .DAT    E_NOIP, S_NOIP, E_NOROUTE, S_NOROUTE, E_NODNS, S_NODNS
                .DAT    E_DNSTIME, S_DNSTIME, E_DNSNAME, S_DNSNAME, E_DNSFAIL, S_DNSFAIL
                .DAT    E_NTPTIME, S_NONTP, E_NTPBAD, S_NTPBAD, E_NTPKOD, S_NTPKOD
