; The monitor's network, which the Makefile joins after monitor.nasm (its
; header): the frame routines eth_on, eth_recv, and eth_send, the IP
; checksum, and the ARP cache of arp_resolve, which are the ROM's own,
; with no entries in the dispatch table (issue #83, README.md, "The
; network"); the UDP endpoint, the entries 16 to 19, udp_open, udp_send,
; udp_recv, and udp_close; i dhcp, which gets the IP address from a DHCP
; server; and tftp IP NAME, which reads a .bin file through the endpoint
; from a TFTP server as load NAME reads one from the card (issue #84).
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
ETH_BUSY        .EQU    0x04            ; and a frame being sent
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
UDP_HDR         .EQU    11              ; the words of the headers of a datagram, with the 2 bytes before the frame
UDP_MAX         .EQU    1472            ; the bytes of a datagram's data, at most
E_NOIP          .EQU    -40             ; the errors of the UDP entries: no IP address,
E_PORT          .EQU    -41             ; no such port,
E_UCLOSED       .EQU    -42             ; the endpoint is not open,
E_ULONG         .EQU    -43             ; a datagram too long,
E_NOROUTE       .EQU    -44             ; and no answer to ARP from the host or the gateway
TFTP_PORT       .EQU    69              ; the TFTP server's port (RFC 1350)
TFTP_TRIES      .EQU    5               ; the sends of a packet that tftp waits for an answer to
TFTP_WAIT       .EQU    1000000         ; the microseconds it waits after each
TFTP_PKT        .EQU    96              ; the words of V_TPKT

; i dhcp: the IP address from a DHCP server (RFC 2131), through the port
; for Ethernet frames, which it enables, and disables at the end. It
; broadcasts a DISCOVER, waits DHCP_WAIT microseconds for an OFFER, then
; broadcasts a REQUEST of the address offered, from the server that
; offered it, and waits as long for its ACK; a reply without an address
; is passed over. A timeout or a NAK starts again from the DISCOVER, up
; to DHCP_TRIES times, with the same transaction, whose number is the
; microseconds at the start, XOR the low word of the MAC address. The
; ACK's address is written to E_IP, which breaks a host's connection over
; TCP, as a write of i does, and shown, with the mask, the gateway, and
; the server. Without an ACK, i says so and leaves E_IP alone. The lease
; is not renewed. R7 counts the tries left.
ip_dhcp
                CALL    eth_on
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
                MOVE    @ETH_CSR, 0
                MOVE    R1, S_NODHCP
                CALL    puts_crlf
                JMP     main
:
                MOVE    @ETH_CSR, 0
                MOVE    @E_IP, @V_DIP
                MOVE    @V_MASK, @V_DMASK
                MOVE    @V_GW, @V_DGW
                MOVE    R1, S_IP
                MOVE    R2, @E_IP
                CALL    show_ip
                MOVE    R1, S_MASK
                MOVE    R2, @V_DMASK
                CALL    show_ip
                MOVE    R1, S_GW
                MOVE    R2, @V_DGW
                CALL    show_ip
                MOVE    R1, S_DSRV
                MOVE    R2, @V_DSRV
                CALL    show_ip
                JMP     main

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
; the next in turn. The port must be enabled. The frames received while
; arp_resolve waits that are no ARP reply are released unread.

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
                MOVE    R1, V_RXF
                CALL    eth_recv
                TST     R1
        ?!Z     CALL    arp_take
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

; arp_take: the frame of R1 bytes at V_RXF learned, if it is an ARP reply,
; for Ethernet and IPv4, whoever it is to. Uses R1-R6.
arp_take
                CMP     R1, 42
        ?C      RET                     ; too short
                AND     R2, @V_RXF+3, 0xFFFF
                CMP     R2, 0x0806
        ?!Z     RET
                CMP     @V_RXF+4, 0x00010800  ; Ethernet, IPv4
        ?!Z     RET
                CMP     @V_RXF+5, 0x06040002  ; their lengths, and a reply
        ?!Z     RET
                SHL     R1, @V_RXF+7, 16  ; the sender's IP address
                SHR     R2, @V_RXF+8, 16
                OR      R1, R1, R2
                SHR     R2, @V_RXF+6, 16  ; and its MAC address
                SHL     R3, @V_RXF+6, 16
                SHR     R4, @V_RXF+7, 16
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

; The UDP endpoint, the entries 16 to 19 (README.md, "The network"): one
; local port, V_UPORT, 0 while it is closed, which the cold start and
; mon_exit close, as they disable the port for Ethernet frames. Datagrams
; are IPv4, from E_IP, with no options, not fragmented, and with the UDP
; checksum 0, none, as IPv4 allows. A datagram's data is one byte per
; word, bits 7..0, as the file entries have it.

; udp_open: the endpoint opened on the local port R1, or with R1 = 0 on a
; port from 49152 to 65535 that the microsecond counter picks, and the
; port for Ethernet frames enabled, with its queue emptied. R1 = the
; port, or E_NOIP without an IP address, or E_PORT for one past 65535.
; Uses R1.
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
                JMP     eth_on          ; which returns to the caller

; udp_close: the endpoint closed, and the port for Ethernet frames
; disabled. R1 = 0.
udp_close
                MOVE    @V_UPORT, 0
                MOVE    @ETH_CSR, 0
                MOVE    R1, 0
                RET

; udp_send: the R4 bytes at R3 sent to the port R2 of the IP address R1,
; through the gateway, V_GW, when the mask, V_MASK, puts the address in
; another network, and to everyone for 255.255.255.255. R1 = 0, or
; E_UCLOSED, E_PORT for a port of 0 or past 65535, E_ULONG for more than
; UDP_MAX bytes, or E_NOROUTE when the host or the gateway did not answer
; ARP. The headers are built at V_UHDR, and copied with the bytes to the
; send buffer a word at a time. Uses R1-R6, and R7-R10 across the calls,
; saved: the address, the port, the bytes, and their number.
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
; The next hop's MAC address, in R2 and R3
                MOVE    R2, 0xFFFF
                MOVE    R3, 0xFFFFFFFF
                CMP     R1, 0xFFFFFFFF
        ?Z      JMP     :++             ; to everyone
                XOR     R2, R1, @E_IP
                AND[M]  R0, R2, @V_MASK
        ?Z      JMP     :+              ; in this network, or no mask
                MOVE[M] R1, @V_GW
        ?Z      JMP     udp_noroute
:
                CALL    arp_resolve
                TST     R1
        ?!Z     JMP     udp_noroute
:
                MOVE    @V_UHDR, R2
                MOVE    @V_UHDR+1, R3
                SHL     R3, @E_MACH, 16
                SHR     R4, @E_MACL, 16
                OR      @V_UHDR+2, R3, R4
                SHL     R3, @E_MACL, 16
                OR      @V_UHDR+3, R3, 0x0800
                ADD     R1, R10, 28
                OR      @V_UHDR+4, R1, 0x45000000  ; IPv4, a header of 5 words, and the length
                MOVE    @V_UHDR+5, 0x4000  ; don't fragment
                MOVE    @V_UHDR+6, 0x40110000  ; the TTL 64, UDP
                MOVE    @V_UHDR+7, @E_IP
                MOVE    @V_UHDR+8, R7
                SHL     R1, @V_UPORT, 16
                OR      @V_UHDR+9, R1, R8
                ADD     R1, R10, 8
                SHL     @V_UHDR+10, R1, 16  ; the UDP length, and checksum 0
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

; udp_recv: the next datagram for the endpoint, of the frames in the
; queue, copied to the words at R1, R2 bytes at most, a byte per word,
; and its source's IP address and port to the 2 words at R3, unless R3
; is 0. R1 = the bytes copied, 0 when no datagram waits, or E_UCLOSED.
; The frames before it that are no datagram for the endpoint are
; released unread, and so are empty datagrams. With R2 0 nothing is
; copied, and the queue is left as it is, so no datagram is lost to a
; call with no room. Uses R1-R6, and R7-R9 across the calls, saved.
udp_recv
                TST     @V_UPORT
        ?Z      MOVE    R1, E_UCLOSED
        ?Z      RET
                TST     R2
        ?Z      MOVE    R1, 0           ; no room: the datagram stays
        ?Z      RET
                PUSH    R7
                PUSH    R8
                PUSH    R9
                MOVE    R7, R1
                MOVE    R8, R2
                MOVE    R9, R3
                CALL    udp_next
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
                MOVE[M] R5, R8
        ?Z      JMP     :++
:
                ADD     R1, R6, 4*UDP_HDR
                CALL    rx_byte
                MOVE    @R7++, R1
                ADD     R6, R6, 1
                CMP     R6, R5
        ?!Z     JMP     :-
:
                MOVE    R1, R8
udp_recv_end
                POP     R9
                POP     R8
                POP     R7
                RET

; udp_next: the next frame of the queue that is a datagram for the
; endpoint in V_RXF, its data from word UDP_HDR, its source's IP address
; in word 7, and its port in bits 31..16 of word 9. R1 = its bytes, or 0
; when the queue has none. The frames before it are released unread:
; frames that are not IPv4 with a header of 5 words, not UDP, fragments,
; to another IP address than E_IP and 255.255.255.255, to another port,
; shorter than their UDP length says, or of no data. Uses R1-R5.
udp_next
                MOVE    R1, V_RXF
                CALL    eth_recv
                TST     R1
        ?Z      RET                     ; none
                CMP     R1, 42
        ?C      JMP     udp_next        ; too short
                AND     R2, @V_RXF+3, 0xFFFF
                CMP     R2, 0x0800
        ?!Z     JMP     udp_next
                SHR     R2, @V_RXF+4, 24
                CMP     R2, 0x45
        ?!Z     JMP     udp_next
                SHR     R2, @V_RXF+6, 16
                AND     R2, R2, 0xFF
                CMP     R2, 17          ; UDP
        ?!Z     JMP     udp_next
                AND[M]  R0, @V_RXF+5, 0x3FFF
        ?!Z     JMP     udp_next        ; a fragment
                MOVE    R2, @V_RXF+8
                CMP     R2, 0xFFFFFFFF
        ?Z      JMP     :+
                CMP     R2, @E_IP
        ?!Z     JMP     udp_next
:
                AND     R2, @V_RXF+9, 0xFFFF
                CMP     R2, @V_UPORT
        ?!Z     JMP     udp_next
                SHR     R2, @V_RXF+10, 16  ; the UDP length
                SUB     R3, R1, 34      ; the bytes after the IP header
                CMP     R3, R2
        ?C      JMP     udp_next        ; shorter than that
                SUB     R1, R2, 9       ; the bytes of data, less 1
                CMP     R1, UDP_MAX
        ?!C     JMP     udp_next        ; no data, or too long
                ADD     R1, R1, 1
                RET

; The frames of i dhcp (RFC 2131 and RFC 2132): a DISCOVER or a REQUEST,
; broadcast from 0.0.0.0 port 68 to port 67, with the broadcast flag set,
; as the station has no address yet, and padded to the 300 bytes of a
; BOOTP message (RFC 1542). The UDP checksum is 0, none, as IPv4 allows.
; With the 2 bytes before the frame, the fields fall on words: the IP
; header at 4, the UDP header at 9, the message at 11, its transaction at
; 12, the address offered at 15, the client's MAC address at 18, the
; magic cookie at 70, and the options from 71, which are written a word at
; a time: 53, the message type; for a REQUEST, 50, the address asked for,
; and 54, the server; 55, the options asked for, 1 the mask, 3 the gateway,
; and 6 the DNS servers. Then a byte at a time: 12, the host name,
; nicemon- and the last three bytes of the MAC address in lower-case hex,
; such as nicemon-434506, a valid name for the network's DNS; 60, the
; vendor class, NiceMonMEGA65 and the monitor's version, cut at DHCP_SMAX
; bytes; and 255, the end (issue #124). The message is 340 bytes, more
; than the 300 of BOOTP, so that a long version fits.

; dhcp_send: a message of the type R1, DHCP_DISCOVER, or DHCP_REQUEST of
; the address V_DIP from the server V_DSRV, with the transaction V_XID.
; Uses R1-R6.
dhcp_send
                MOVE    R6, R1
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
                CMP     R6, DHCP_REQUEST
        ?Z      JMP     :+
                MOVE    @V_TXF+71, 0x35010137  ; 53 DISCOVER, and 55
                MOVE    @V_TXF+72, 0x03010306
                MOVE    R6, 4*73        ; the byte of the next option
                JMP     dhcp_names
:
                MOVE    @V_TXF+71, 0x35010332  ; 53 REQUEST, and 50
                MOVE    R1, @V_DIP
                MOVE    R2, @V_DSRV
                SHR     R3, R1, 8
                OR      @V_TXF+72, R3, 0x04000000
                SHL     R3, R1, 24
                SHR     R4, R2, 24
                OR      R3, R3, R4
                OR      @V_TXF+73, R3, 0x00360400  ; and 54
                SHL     R3, R2, 8
                OR      @V_TXF+74, R3, 0x37  ; and 55
                MOVE    @V_TXF+75, 0x03010306
                MOVE    R6, 4*76
dhcp_names
                MOVE    R1, 12          ; the host name
                CALL    dhcp_code
                MOVE    R5, S_HOST
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
                MOVE    R5, S_VCLASS
                CALL    dhcp_str
                MOVE    R5, VERSION
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
; The address, the server, the mask, and the gateway of the reply that
; is waited for are copied to V_DIP, V_DSRV, V_DMASK, and V_DGW. A reply
; of the type without an address is passed over, so that the station's
; address is never made 0. The other frames are released unread. Uses
; R1-R6, and R7 and R8 across the calls, saved.
dhcp_wait
                PUSH    R7
                PUSH    R8
                MOVE    R7, R1
                MOVE    R8, @io.us      ; the start
dhcp_listen
                MOVE    R1, V_RXF
                CALL    eth_recv
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
                MOVE    @V_DIP, @V_PIP
                MOVE    @V_DSRV, @V_PSRV
                MOVE    @V_DMASK, @V_PMASK
                MOVE    @V_DGW, @V_PGW
dhcp_wait_end
                POP     R8
                POP     R7
                RET

; dhcp_parse: the frame of R1 bytes at V_RXF, if it is a DHCP reply to the
; transaction V_XID: an IPv4 packet with a header of 5 words, UDP from port
; 67 to 68, a BOOTP reply, and the magic cookie. Its checksums are not
; checked, as the FCS was. R1 = the message type of option 53, or 0 when
; it is no reply of ours or has no type, and V_PIP, V_PSRV, V_PMASK, and
; V_PGW are its address, and the options 54, 1, and 3, the first address
; of each, or 0 without them. The options are walked from byte 284 of the
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
        ?C      JMP     dhcp_opt        ; too short for an address
                CMP     R6, 1
        ?Z      MOVE    R6, V_PMASK
        ?Z      JMP     :+
                CMP     R6, 3
        ?Z      MOVE    R6, V_PGW
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
                MOVE    R2, S_FTP
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
                MOVE    R7, S_STAR
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
                MOVE    R1, S_OCTET
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
                CALL    puts_crlf
                JMP     main
; An ERROR: its code, and its message, up to a 0 or the end of the
; datagram, without control codes. R7 is the byte, and R8 the end.
tftp_error
                MOVE    R7, 4*UDP_HDR+4
                ADD     R8, R1, 4*UDP_HDR
                CALL    udp_close
                MOVE    R1, S_TFTPERR
                CALL    _io_puts
                AND     R1, @V_RXF+UDP_HDR, 0xFFFF
                CALL    _io_putdec
                MOVE    R1, S_UCOMMA
                CALL    _io_puts
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
                CALL    puts_crlf
                JMP     main
tftp_bad
                MOVE    R1, S_BADTFTP
                CALL    puts_crlf
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
                .ASCII_L 'No answer from a DHCP server'
S_HOST          .ASCII_L 'nicemon-'
S_VCLASS
                .ASCII_L 'NiceMonMEGA65 '
S_MASK          .ASCII_L 'Mask '
S_GW            .ASCII_L 'Gateway '
S_DSRV          .ASCII_L 'DHCP server '
S_FTP           .ASCII_L 'ftp'
S_OCTET         .ASCII_L 'octet'
S_STAR          .ASCII_L '*'
S_BADTFTP
                .ASCII_L 'tftp IP[:PORT] [NAME]: tftp 192.168.1.10 hello.bin loads, *.bin lists'
S_NOTFTP
                .ASCII_L 'No answer from the TFTP server'
S_TFTPERR
                .ASCII_L 'TFTP error '
S_NOIP          .ASCII_L 'No IP address; i sets one'
S_NOROUTE
                .ASCII_L 'No answer to ARP from the server, or from the gateway'
