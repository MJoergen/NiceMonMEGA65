; BASIC's statements of the network, which the Makefile joins after
; basic_cmd.nasm (basic.nasm's header): DHCP, on net_dhcp, net_config, and
; net_servers; NTP, which sets the clock from a time server (issue #127),
; on dns_lookup, the UDP entries, and clock_set, with clock_zone and
; clock_ntp of basic_time.nasm; LOAD "NAME.BIN", "IP", which reads a
; .bin file from a TFTP server on the UDP entries as LOAD "NAME.BIN"
; reads one from the card, and DIR "IP", its listing (issue #84); and
; SAVE "NAME", "IP" and BSAVE "NAME", A, N, "IP", which write a file to
; the server (issue #155). They reach the monitor through the entries of
; the dispatch table alone (issue #152).
;
; The statements are routines as those of basic_cmd.nasm are, which
; basic.nasm calls with their arguments in R1-R3. IP, which shows and
; writes the IP address, is in basic_cmd.nasm. TFTP takes its bytes
; with bin_char of basic_cmd.nasm, as LOAD from the card does, and gets
; those of a write from flush, as SAVE to the card writes them.

NTP_PORT        .EQU    123             ; the time server's UDP port (RFC 4330)
NTP_TRIES       .EQU    3               ; the queries that NTP sends
NTP_WAIT        .EQU    2000000         ; the microseconds it waits after each
E_NTPTIME       .EQU    -60             ; the errors of NTP, which no entry returns: no answer,
E_NTPBAD        .EQU    -61             ; an answer that is not to be trusted, or a time that the clock does not take,
E_NTPKOD        .EQU    -62             ; and a kiss-o'-death
TFTP_PORT       .EQU    69              ; the TFTP server's port (RFC 1350)
TFTP_TRIES      .EQU    5               ; the sends of a packet that TFTP waits for an answer to
TFTP_WAIT       .EQU    1000000         ; the microseconds it waits after each
TFTP_PKT        .EQU    96              ; the words of V_TPKT
TFTP_MAX        .EQU    516             ; the bytes of a packet received at most, the words of V_TBUF
E_TNOANS        .EQU    -63             ; the errors of TFTP, which no entry returns: no answer,
E_TERROR        .EQU    -64             ; and an ERROR of the server

; DHCP: net_dhcp, entry 23, and the address, the mask, the gateway, and
; the DNS server of net_config, entry 21, and the DHCP server and the
; NTP server, if it gave one, of net_servers, entry 35, at V_NET, shown,
; or the error raised with io_fail (basic_trap.nasm).
st_dhcp
                CALL    NET_DHCP
                TST     R1
        ?N      JMP     io_fail
                MOVE    R1, V_NET
                CALL    NET_CONFIG
                MOVE    R1, V_NET+4
                CALL    NET_SERVERS
                MOVE    R1, S_IP
                MOVE    R2, @V_NET
                CALL    show_ip
                MOVE    R1, S_MASK
                MOVE    R2, @V_NET+1
                CALL    show_ip
                MOVE    R1, S_GW
                MOVE    R2, @V_NET+2
                CALL    show_ip
                MOVE    R1, S_DNS
                MOVE    R2, @V_NET+3
                CALL    show_ip
                MOVE    R1, S_DSRV
                MOVE    R2, @V_NET+4
                CALL    show_ip
                MOVE    R1, S_NTPSRV
                MOVE[M] R2, @V_NET+5
        ?!Z     CALL    show_ip
                RET

; NTP ["SERVER"] [, "+HH:MM" | "-HH:MM"]: R1 SERVER, or 0 without it or
; for an empty one, and R2 the offset, or 0 without it. The clock of the
; time of day set from a time server by SNTP (RFC 4330), and the MEGA65's
; real-time clock with it, by clock_ntp of basic_time.nasm (issue #127),
; which goes to ntp_bad_time with a time that the clock does not take.
; SERVER is a name, which dns_lookup, entry 25, looks up, or an IP
; address; without it the server is the NTP server of DHCP's option 42,
; which net_servers, entry 35, gives, and without that S_POOL. The offset
; is local time less UTC, which clock_zone reads, and +00:00 without it.
; The query is 48 bytes from the UDP endpoint to port 123: version 4,
; mode 3, and the transmit timestamp, the microseconds, and in its
; fraction the microseconds XOR the low word of the MAC address, as the
; answer's originate timestamp must be the same. It is built in V_NTPQ,
; a byte a word, and sent again after NTP_WAIT microseconds, NTP_TRIES
; times in all. ntp_parse takes the answer. There is no correction for
; the delay, which is far below the second that the clock shows. R7 is
; the server's name, 0 for none, then the sends left, R8 the offset, R9
; the server's address, and R10 the time of the send.
st_ntp
                MOVE    R7, R1
                CLR     R8
                TST     R2
        ?Z      JMP     ntp_server      ; no offset
                MOVE    R1, R2
:
                CMP     @R1, 0x20
        ?Z      ADD     R1, R1, 1
        ?Z      JMP     :-
                CALL    clock_zone
        ?!Z     JMP     ntp_bad
                MOVE    R8, R1
; The server's address
ntp_server
                MOVE    R1, MON_E_NOIP
                TST     @E_IP
        ?Z      JMP     io_fail
                MOVE    R1, V_NET
                CALL    NET_SERVERS
                MOVE[M] R9, @V_NET+1
                TST     R7
        ?!Z     JMP     :+
                TST     R9
        ?!Z     JMP     ntp_query       ; DHCP's
                MOVE    R7, TEXT_B+4*S_POOL
:
                MOVE    R1, R7
                MOVE    R2, V_NTPIP
                CALL    DNS_LOOKUP
                TST     R1
        ?!Z     JMP     io_fail
                MOVE    R9, @V_NTPIP
; The query, from the UDP endpoint, which udp_open, entry 16, opens on
; a port of its own
ntp_query
                MOVE    R1, V_NTPQ
                MOVE    R2, 48
:
                CLR     @R1++
                SUB[M]  R2, R2, 1
        ?!Z     JMP     :-
                MOVE    @V_NTPQ, 0x23   ; version 4, mode 3
                MOVE    R1, @io.us      ; the transmit timestamp
                MOVE    R2, V_NTPQ+40
                CALL    put32
                XOR     R1, @io.us, @E_MACL
                MOVE    R2, V_NTPQ+44
                CALL    put32
                CLR     R1
                CALL    UDP_OPEN
                TST     R1
        ?N      JMP     io_fail
                MOVE    R7, NTP_TRIES
ntp_send
                MOVE    R1, R9
                MOVE    R2, NTP_PORT
                MOVE    R3, V_NTPQ
                MOVE    R4, 48
                CALL    UDP_SEND
                TST     R1
        ?N      JMP     ntp_off         ; MON_E_NOROUTE
                MOVE    R10, @io.us
ntp_wait
                MOVE    R1, V_NTPA
                MOVE    R2, 48
                MOVE    R3, V_TSRC
                CALL    UDP_RECV
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
                MOVE    R7, R1
                CALL    UDP_CLOSE
                MOVE[M] R1, R7
        ?!Z     JMP     io_fail
                MOVE    R1, V_NTPA+40   ; the transmit timestamp
                CALL    get32
                MOVE    R7, R1
                MOVE    R1, V_NTPA+44
                CALL    get32
                MOVE    R2, R1
                MOVE    R1, R7
                JMP     clock_ntp       ; which returns to the caller, or goes to ntp_bad_time
ntp_bad_time
                MOVE    R1, E_NTPBAD    ; a time that the clock does not take
                JMP     io_fail
ntp_bad
                MOVE    R1, E_NTPOFF
                JMP     io_fail

; ntp_parse: the datagram of R1 bytes at V_NTPA, from the source at
; V_TSRC, if it is the answer of the server R9: from its port 123, with
; 48 bytes of data at least, mode 4, and the originate timestamp of the
; query's transmit timestamp. R1 = 1 when it is not, and it is passed
; over. Else R1 = 0, or E_NTPKOD for a stratum of 0, a kiss-o'-death, or
; E_NTPBAD for a leap indicator of 3, not synchronized, a stratum over
; 15, or a transmit timestamp of 0, which is not to be trusted. Uses
; R1-R4.
ntp_parse
                CMP     R1, 48
        ?!Z     JMP     ntp_skip        ; too short
                CMP     @V_TSRC, R9
        ?!Z     JMP     ntp_skip
                CMP     @V_TSRC+1, NTP_PORT
        ?!Z     JMP     ntp_skip
                MOVE    R2, @V_NTPA     ; the leap indicator, the version, and the mode
                AND     R1, R2, 7
                CMP     R1, 4           ; a server's
        ?!Z     JMP     ntp_skip
                MOVE    R1, V_NTPA+24
                MOVE    R3, V_NTPQ+40
                MOVE    R4, 8
:
                CMP     @R1++, @R3++
        ?!Z     JMP     ntp_skip        ; another originate timestamp
                SUB[M]  R4, R4, 1
        ?!Z     JMP     :-
                MOVE[M] R1, @V_NTPA+1   ; the stratum
        ?Z      MOVE    R1, E_NTPKOD
        ?Z      RET
                CMP     R1, 16
        ?!C     JMP     ntp_untrusted
                SHR     R1, R2, 6
                CMP     R1, 3           ; not synchronized
        ?Z      JMP     ntp_untrusted
                MOVE    R1, V_NTPA+40
                CLR     R3
                MOVE    R4, 8
:
                OR      R3, R3, @R1++
                SUB[M]  R4, R4, 1
        ?!Z     JMP     :-
                TST     R3
        ?Z      JMP     ntp_untrusted
                CLR     R1
                RET
ntp_skip
                MOVE    R1, 1
                RET
ntp_untrusted
                MOVE    R1, E_NTPBAD
                RET

; get32: R1 = the 4 bytes from the word address R1, a byte a word,
; big-endian. Uses R1-R3.
get32
                MOVE    R2, R1
                CLR     R1
                MOVE    R3, 4
:
                SHL     R1, R1, 8
                OR      R1, R1, @R2++
                SUB[M]  R3, R3, 1
        ?!Z     JMP     :-
                RET

; put32: R1 as 4 bytes to the words from R2, a byte a word, big-endian.
; Uses R1-R3.
put32
                MOVE    R3, 4
:
                ROL     R1, R1, 8
                AND     @R2++, R1, 0xFF
                SUB[M]  R3, R3, 1
        ?!Z     JMP     :-
                RET

; LOAD "NAME.BIN", "IP[:PORT]" and DIR "IP[:PORT]" [, "PAT"]: R1 the
; string of IP, R2 the name, or 0 for *, and R3 not 0 for a listing, of
; DIR. The .bin file NAME of the TFTP server at IP (RFC 1350), read in
; octet mode through the UDP endpoint, which tftp_req opens on a port
; that udp_open picks, and closes at the end, and its lines written as
; LOAD "NAME.BIN" writes them, with bin_char, and shown as LOAD shows
; them, or for a program's text stored by bas_eol (issue #60); or for a listing the lines that nicemon.py tftpd answers a
; pattern, with * or ?, with, which are shown instead. The RRQ goes to
; PORT, 69 by default, and the server's first DATA gives its TID; the
; packets of other hosts and TIDs are passed over. Each DATA of the block
; waited for is answered with its ACK, and a DATA of the block before
; with the ACK again; a block of less than 512 bytes is the last. A
; packet that has no answer within TFTP_WAIT microseconds is sent again,
; up to TFTP_TRIES times in all. An ERROR ends the load with its code and
; its message. An error after a line of the file shows the summary
; first, with load_part. R7 counts the sends left.
st_tftp
                MOVE[M] R7, R2          ; the name
        ?Z      MOVE    R7, TEXT_B+4*S_STAR
                MOVE    @V_TLIST, R3
                ONE     @V_TOP          ; an RRQ
                CALL    tftp_req
                MOVE    @V_TBLK, 1
                CALL    bin_init
tftp_try
                MOVE    R7, TFTP_TRIES
tftp_send
                MOVE    R1, @V_TSRV
                MOVE[M] R2, @V_TTID
        ?Z      MOVE    R2, @V_TPORT
                MOVE    R3, V_TPKT
                MOVE    R4, @V_TLEN
                CALL    UDP_SEND
                TST     R1
        ?N      JMP     tftp_end
                MOVE    @V_TTIME, @io.us
tftp_wait
                MOVE    R1, V_TBUF
                MOVE    R2, TFTP_MAX
                MOVE    R3, V_TSRC
                CALL    UDP_RECV
                TST     R1
        ?Z      JMP     tftp_time
                CMP     @V_TSRC, @V_TSRV
        ?!Z     JMP     tftp_wait       ; from another host
                MOVE    R2, @V_TSRC+1   ; its port
                MOVE[M] R3, @V_TTID
        ?Z      JMP     :+
                CMP     R2, R3
        ?!Z     JMP     tftp_wait       ; from another TID
:
                SHL     R3, @V_TBUF, 8  ; the opcode
                OR      R3, R3, @V_TBUF+1
                CMP     R3, 5
        ?Z      JMP     tftp_error
                CMP     R3, 3
        ?!Z     JMP     tftp_wait       ; no DATA
                CMP     R1, 4
        ?C      JMP     tftp_wait       ; too short
                SHL     R4, @V_TBUF+2, 8  ; the block
                OR      R4, R4, @V_TBUF+3
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
                CLR     R7              ; the byte of the block
:
                CMP     R7, @V_TEND
        ?Z      JMP     :+
                MOVE    R1, @V_TBUF+4[R7]
                ADD     R7, R7, 1
                CALL    bin_char
                JMP     :-
:
                CLR     @V_TPKT
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
                CALL    UDP_SEND
                CALL    bin_last
                CLR     @V_OPEN
                CALL    UDP_CLOSE
                TST     @V_TLIST
        ?!Z     RET                     ; a listing, shown
                JMP     load_summary
tftp_time
                SUB     R1, @io.us, @V_TTIME
                CMP     R1, TFTP_WAIT
        ?C      JMP     tftp_wait
                SUB[M]  R7, R7, 1
        ?!Z     JMP     tftp_send
                MOVE    R1, E_TNOANS
                JMP     tftp_end
tftp_error
                MOVE    @V_TEND, R1     ; its bytes
                MOVE    R1, E_TERROR
                JMP     tftp_end

; tftp_req: the request V_TOP, an RRQ or a WRQ, of the name at R7 to the
; TFTP server of the string R1, IP[:PORT], with PORT 69 by default, made
; in octet mode, of V_TLEN bytes, in V_TPKT for an RRQ and in V_TBUF for
; a WRQ, which receives into V_TPKT, and the endpoint opened, with no TID
; yet. A string that is no server, E_TBAD, and an endpoint that does not
; open are raised with io_fail. Uses R1-R8.
tftp_req
                CLR     @V_LSTATS       ; no word loaded yet,
                CLR     @V_LSTATS+5     ; and no line read, for load_part
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
        ?!Z     JMP     tftp_ip
                ADD     R3, R3, 1
                CLR     R4              ; the port
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
tftp_ip
                CALL    rest_blank
        ?!Z     JMP     tftp_bad        ; more after the address
; The request: the opcode, the name, a 0, octet, and a 0
                MOVE    R2, V_TPKT
                CMP     @V_TOP, 1
        ?!Z     MOVE    R2, V_TBUF
                MOVE    R8, R2          ; its start
                CLR     @R2++
                MOVE    @R2++, @V_TOP
:
                MOVE[M] @R2++, @R7++
        ?!Z     JMP     :-
                MOVE    R1, TEXT_B+4*S_OCTET
:
                MOVE[M] @R2++, @R1++
        ?!Z     JMP     :-
                SUB     @V_TLEN, R2, R8
                CLR     R1
                CALL    UDP_OPEN
                TST     R1
        ?N      JMP     tftp_end
                NOT     @V_OPEN, R0     ; for files_end, at an error of a line
                CLR     @V_TTID
                RET
tftp_bad
                MOVE    R1, E_TBAD
                JMP     io_fail

; tftp_end: the end of a transfer that failed with the error R1:
; E_TNOANS, no answer; E_TERROR, an ERROR of V_TEND bytes, in V_TBUF
; for an RRQ and in V_TPKT for a WRQ; or an error of udp_open or
; udp_send, no IP address or no route. The endpoint closed, the summary
; of a load's lines first, with load_part, and the error raised with
; io_fail, whose text has the ERROR's code and its message.
tftp_end
                PUSH    R1
                CLR     @V_OPEN
                CALL    UDP_CLOSE
                POP     R1
                CALL    load_part
                JMP     io_fail

; The write of SAVE "NAME", "IP" and BSAVE "NAME", A, N, "IP" (issue
; #155), which out_file of basic_cmd.nasm drives: tput_open sends the
; WRQ, flush gives its bytes to tput_bytes, which sends each DATA block
; of 512 bytes as it fills, in V_TBUF, and tput_close sends the last,
; of less than 512 bytes, which may be empty. The server's ACK 0 gives
; its TID; the packets of other hosts and TIDs are passed over, and so
; are the ACKs of other blocks. A packet that has no ACK within
; TFTP_WAIT microseconds is sent again, up to TFTP_TRIES times in all.
; The first error, an ERROR of the server, no answer, or one of
; udp_send, is kept in V_SERR, and the rest of the bytes are dropped;
; tput_close shows it. While the bytes go, V_OPEN is -2, and files_end
; ends a write that the break key stopped with tput_abort.

; tput_open: R1 the name, and R2 the string of the server, IP[:PORT].
; The WRQ sent with tftp_req, and its ACK 0 waited for, with V_OPEN -2
; after, or the error raised with tftp_end. Keeps R9-R12.
tput_open
                PUSH    R7
                PUSH    R8
                MOVE    R7, R1
                MOVE    R1, R2
                MOVE    @V_TOP, 2       ; a WRQ
                CALL    tftp_req
                CLR     @V_TBLK         ; the ACK of block 0
                CALL    tput_xfer
                TST     R1
        ?!Z     JMP     tftp_end
                MOVE    @V_OPEN, 0xFFFFFFFE
                MOVE    @V_TBLK, 1
                CLR     @V_TEND
                POP     R8
                POP     R7
                RET

; tput_xfer: the V_TLEN bytes of V_TBUF sent to the server, and the ACK
; of the block V_TBLK waited for, whose port is the TID. R1 0, or the
; error: E_TNOANS, E_TERROR with the ERROR's bytes in V_TEND, or an
; error of udp_send. Uses R1-R7.
tput_xfer
                MOVE    R7, TFTP_TRIES
tput_send
                MOVE    R1, @V_TSRV
                MOVE[M] R2, @V_TTID
        ?Z      MOVE    R2, @V_TPORT
                MOVE    R3, V_TBUF
                MOVE    R4, @V_TLEN
                CALL    UDP_SEND
                TST     R1
        ?N      RET
                MOVE    @V_TTIME, @io.us
tput_wait
                MOVE    R1, V_TPKT
                MOVE    R2, TFTP_PKT
                MOVE    R3, V_TSRC
                CALL    UDP_RECV
                TST     R1
        ?Z      JMP     tput_time
        ?N      JMP     tput_time
                CMP     @V_TSRC, @V_TSRV
        ?!Z     JMP     tput_wait       ; from another host
                MOVE    R2, @V_TSRC+1   ; its port
                MOVE[M] R3, @V_TTID
        ?Z      JMP     :+
                CMP     R2, R3
        ?!Z     JMP     tput_wait       ; from another TID
:
                CMP     R1, 4
        ?C      JMP     tput_wait       ; too short
                SHL     R3, @V_TPKT, 8  ; the opcode
                OR      R3, R3, @V_TPKT+1
                CMP     R3, 5
        ?Z      MOVE    @V_TEND, R1     ; its bytes
        ?Z      MOVE    R1, E_TERROR
        ?Z      RET
                CMP     R3, 4
        ?!Z     JMP     tput_wait       ; no ACK
                SHL     R4, @V_TPKT+2, 8  ; the block
                OR      R4, R4, @V_TPKT+3
                CMP     R4, @V_TBLK
        ?!Z     JMP     tput_wait       ; an ACK of another block
                MOVE    @V_TTID, R2
                CLR     R1
                RET
tput_time
                SUB     R1, @io.us, @V_TTIME
                CMP     R1, TFTP_WAIT
        ?C      JMP     tput_wait
                SUB[M]  R7, R7, 1
        ?!Z     JMP     tput_send
                MOVE    R1, E_TNOANS
                RET

; tput_block: the V_TEND bytes at V_TBUF+4 sent as the DATA of the block
; V_TBLK, with tput_xfer, and then V_TBLK the next block, with no bytes.
; R1 0, or the error of tput_xfer. Uses R1-R7.
tput_block
                CLR     @V_TBUF
                MOVE    @V_TBUF+1, 3
                MOVE    R1, @V_TBLK
                SHR     @V_TBUF+2, R1, 8
                AND     @V_TBUF+3, R1, 0xFF
                ADD     @V_TLEN, @V_TEND, 4
                CALL    tput_xfer
                TST     R1
        ?!Z     RET
                ADD     R2, @V_TBLK, 1
                AND     @V_TBLK, R2, 0xFFFF
                CLR     @V_TEND
                RET

; tput_bytes: the R3 bytes from V_FBUF, for flush, added to the block at
; V_TBUF+4, which is sent with tput_block each time it has 512, up to
; the first error, which goes to V_SERR. Uses R1-R4, as flush does.
tput_bytes
                PUSH    R5
                PUSH    R6
                PUSH    R7
                MOVE    R5, V_FBUF
                ADD     R6, R5, R3      ; the end
:
                CMP     R5, R6
        ?Z      JMP     :+
                MOVE    R1, @V_TEND
                MOVE    @V_TBUF+4[R1], @R5++
                ADD     R1, R1, 1
                MOVE    @V_TEND, R1
                CMP     R1, 512
        ?!Z     JMP     :-
                PUSH    R5
                PUSH    R6
                CALL    tput_block
                POP     R6
                POP     R5
                MOVE    @V_SERR, R1
                TST     R1
        ?Z      JMP     :-
:
                POP     R7
                POP     R6
                POP     R5
                RET

; tput_close: the end of a write: the last block sent, unless an error
; came before, and the endpoint closed. R1 0, or the error raised with
; tftp_end, V_SERR's or the last block's.
tput_close
                MOVE[M] R1, @V_SERR
        ?Z      CALL    tput_block
                TST     R1
        ?!Z     JMP     tftp_end        ; which raises the error, and does not return
                CLR     @V_OPEN
                CALL    UDP_CLOSE
                CLR     R1
                RET

; tput_abort: an ERROR 0, Break, to the server of a write that the break
; key stopped, so that it drops the file, and the endpoint closed, for
; files_end. Uses R1-R6.
tput_abort
                MOVE    R2, V_TPKT
                CLR     @R2++
                MOVE    @R2++, 5
                CLR     @R2++
                CLR     @R2++
                MOVE    R1, TEXT_B+4*S_BREAK
:
                MOVE[M] @R2++, @R1++
        ?!Z     JMP     :-
                SUB     R4, R2, V_TPKT
                MOVE    R1, @V_TSRV
                MOVE    R2, @V_TTID
                MOVE    R3, V_TPKT
                CALL    UDP_SEND
                JMP     UDP_CLOSE       ; which returns to the caller

; HTTP$(H$, P$) and URL$(S$), the functions of strings of HTTP (issue
; #170, doc/BASIC.md, "HTTP"), which sprimary calls through SFNS with R8
; after the token.
;
; HTTP$ fetches http://H$P$ with GET and HTTP/1.0, and gives the body,
; decoded from UTF-8 to the codes of the screen. H$ is a name or an IP
; address, which dns_lookup takes, with :PORT or not, 80 by default, and
; P$ starts with a /. The connection is a TCP connection of the entries
; 26 to 30, whose control block is a block of the heap, with no owner,
; for the call alone: no block is made while the ROM has it, as a sweep
; would move it, so the body's block, of HTTP_BODY characters, is made
; first, in the slot of the result. V_OPEN is HTTP_OPEN while it is
; open, so that files_end closes it after an error or the break key,
; and every way out closes it with an abort, which frees the handle at
; once. The answer is read in parts of up to HTTP_RX bytes into V_TBUF,
; and each byte goes to h_byte: the status line, the headers, whose
; Content-Length and Location it keeps, and the body. The whole exchange
; waits HTTP_WAIT microseconds at most, and polls the console, so that
; CTRL-C breaks it. The registers R9-R12 are kept, which the expression
; that calls it may hold.
HTTP_RX         .EQU    512             ; the bytes of the ring received,
HTTP_RINGS      .EQU    0x02000100      ; and the rings as tcp_open takes them, 512 and 256
HTTP_CB         .EQU    224             ; the words of the control block: 32, and the rings packed
HTTP_BODY       .EQU    257             ; the characters of the body's block: a string, and a CR LF
HTTP_WAIT       .EQU    20000000        ; the microseconds of the exchange at most
HTTP_LINE       .EQU    95              ; the characters of a header's line kept at V_TPKT
HTTP_OPEN       .EQU    0xFFFFFFFD      ; V_OPEN while the connection is open, -3
V_REQ           .EQU    V_NAME          ; the request, a byte a word, up to V_TSRC, 900 words,
V_HDST          .EQU    V_NAME          ; and after it is sent, the text of DS$ for a status
E_HNOTHTTP      .EQU    -67             ; the errors of HTTP$, which no entry returns: not HTTP,
E_HSHORT        .EQU    -68             ; an answer cut short,
E_HSTATUS       .EQU    -69             ; and a status other than 200
f_http
                PUSH    R9
                PUSH    R10
                PUSH    R11
                PUSH    R12
                MOVE    R1, HTTP_BODY
                OR      R2, @V_SSP, TAG_SLOT
                CALL    salloc
                CLR     R2
                CALL    s_push          ; the body, empty, in the slot of the result
                CALL    s_lpar          ; H$
                CMP     @R8++, T_COMMA
        ?!Z     JMP     err_syntax
                CALL    sexpr           ; P$
                CALL    rpar
                MOVE    R1, HTTP_CB
                NOT     R2, R0          ; a block with no owner
                CALL    salloc
                MOVE    R11, R1         ; the control block
; From here on no block is made, and no string moves
                CALL    s_top
                MOVE    R9, R3          ; P$'s entry, after H$'s and the body's
                TST     R2
        ?Z      JMP     err_quant
                CMP     @R1, 0x2F       ; /
        ?!Z     JMP     err_quant
                MOVE    @V_HBODY, @-4[R3]
                MOVE    R4, V_REQ
                MOVE    R1, TEXT_B+4*S_HGET
                CALL    h_text
                MOVE    R1, @R9
                MOVE    R2, @1[R9]
                CALL    s_copy          ; P$
                MOVE    R1, TEXT_B+4*S_HHOST
                CALL    h_text
                MOVE    R10, R4         ; the host's first character
                MOVE    R1, @-2[R9]
                MOVE    R2, @-1[R9]
                CALL    s_copy          ; H$
                MOVE    R12, R4         ; the word after it
                MOVE    R1, TEXT_B+4*S_HAGENT
                CALL    h_text
                MOVE    R1, TEXT_B+4*VERSION
                CALL    h_text
                MOVE    R1, TEXT_B+4*S_HEND
                CALL    h_text
                MOVE    @V_HN, R4       ; the request's end, until it is sent
; The port after a colon, which ends the host
                MOVE    @V_TPORT, 80
                MOVE    R1, R10
:
                CMP     R1, R12
        ?Z      JMP     h_host          ; no port
                CMP     @R1++, 0x3A     ; :
        ?!Z     JMP     :-
                SUB     R5, R1, 1       ; the colon
                CMP     R1, R12
        ?Z      JMP     err_quant       ; a port without digits
                CLR     R2
:
                CMP     R1, R12
        ?Z      JMP     :+
                SUB     R3, @R1++, 0x30
                CMP     R3, 10
        ?!C     JMP     err_quant       ; no digit
                ADD     R2, R2, R2      ; R2 is 10 * R2 + the digit
                ADD     R3, R3, R2
                SHL     R2, R2, 2
                ADD     R2, R2, R3
                CMP     R2, 0x10000
        ?!C     JMP     err_quant
                JMP     :-
:
                TST     R2
        ?Z      JMP     err_quant       ; port 0
                MOVE    @V_TPORT, R2
                MOVE    R12, R5
h_host
                CMP     R10, R12
        ?Z      JMP     err_quant       ; no host
                MOVE    R6, @R12        ; the host with a 0 after it, for dns_lookup
                PUSH    R6
                CLR     @R12
                MOVE    R1, R10
                MOVE    R2, V_TSRV
                CALL    DNS_LOOKUP
                POP     R6
                MOVE    @R12, R6
                TST     R1
        ?!Z     JMP     io_fail
                MOVE    R1, R11
                MOVE    R2, @V_TSRV
                MOVE    R3, @V_TPORT
                MOVE    R4, HTTP_RINGS
                CALL    TCP_OPEN
                TST     R1
        ?N      JMP     io_fail
                MOVE    @V_TTID, R1     ; the handle
                MOVE    @V_OPEN, HTTP_OPEN
                MOVE    @V_TTIME, @io.us
; The request, in the parts that the ring to send takes
                MOVE    R9, V_REQ
                SUB     R10, @V_HN, R9
h_send
                MOVE    R1, @V_TTID
                MOVE    R2, R9
                MOVE    R3, R10
                CALL    TCP_SEND
                TST     R1
        ?N      JMP     h_fail
                ADD     R9, R9, R1
                SUB[M]  R10, R10, R1
        ?Z      JMP     :+
                CALL    h_wait
                JMP     h_send
; The answer
:
                CLR     @V_HN
                CLR     @V_HNEED
                CLR     @V_HLINE
                NOT     @V_HCL, R0
                CLR     @V_HSTAT
                CLR     @V_HDS
h_recv
                MOVE    R1, @V_TTID
                MOVE    R2, V_TBUF
                MOVE    R3, HTTP_RX
                CALL    TCP_RECV
                TST     R1
        ?Z      JMP     h_idle
                CMP     R1, MON_E_TEOF
        ?Z      JMP     h_end
                TST     R1
        ?N      JMP     h_fail
                MOVE    R9, V_TBUF
                ADD     R10, R9, R1
:
                CMP     R9, R10
        ?Z      JMP     h_recv
                MOVE    R1, @R9++
                CALL    h_byte
                TST     @V_HCL
        ?!Z     JMP     :-
                CMP     @V_HLINE, 0xFFFFFFFF
        ?!Z     JMP     :-
                JMP     h_end           ; the body's bytes of Content-Length
h_idle
                CALL    h_wait
                JMP     h_recv
; The end of the answer: the body, without a line end at its end, in
; the slot of the result, or the error
h_end
                MOVE    R1, E_HNOTHTTP
                TST     @V_HSTAT
        ?Z      JMP     h_fail          ; no status line
                MOVE    R1, E_HSHORT
                CMP     @V_HLINE, 0xFFFFFFFF
        ?!Z     JMP     h_fail          ; in the headers
                MOVE[M] R2, @V_HCL
        ?N      JMP     :+
        ?!Z     JMP     h_fail          ; fewer bytes than Content-Length
:
                CMP     @V_HSTAT, 200
        ?!Z     JMP     h_status
                TST     @V_HNEED
        ?Z      JMP     :+
                MOVE    R1, 0x3F        ; a sequence cut short
                CALL    h_put
:
                CALL    h_close
                MOVE    R5, @V_HN
                ADD     R3, R5, @V_HBODY
                TST     R5
        ?Z      JMP     :+
                CMP     @-1[R3], 10     ; LF
        ?!Z     JMP     :+
                SUB[M]  R5, R5, 1
        ?Z      JMP     :+
                CMP     @-2[R3], 13     ; CR
        ?Z      SUB     R5, R5, 1
:
                CMP     R5, STR_MAX+1
        ?!C     JMP     err_strlong
                SUB     @V_SSP, @V_SSP, 2  ; H$ and P$
                CALL    s_top
                MOVE    @1[R3], R5
                POP     R12
                POP     R11
                POP     R10
                POP     R9
                RET
h_status
                MOVE    R1, E_HSTATUS
; h_fail: the connection closed, and the failure R1 raised with io_fail
h_fail
                PUSH    R1
                CALL    h_close
                POP     R1
                JMP     io_fail
h_long
                CALL    h_close
                JMP     err_strlong
h_nothttp
                MOVE    R1, E_HNOTHTTP
                JMP     h_fail

; h_close: the connection of HTTP$ aborted, which frees its handle at
; once, also for files_end. Uses R1-R6.
h_close
                CLR     @V_OPEN
                MOVE    R1, @V_TTID
                ONE     R2
                JMP     TCP_CLOSE       ; which returns to the caller

; h_wait: the timeout of HTTP$, MON_E_TTIMEOUT, when the exchange took
; HTTP_WAIT microseconds; else the console polled, so that CTRL-C is a
; break, at the statement, which CONT runs again. Uses R1-R6.
h_wait
                SUB     R1, @io.us, @V_TTIME
                CMP     R1, HTTP_WAIT
        ?!C     JMP     :+
                PUSH    R8
                MOVE    R8, @V_STMT
                CALL    poll
                POP     R8
                RET
:
                MOVE    R1, MON_E_TTIMEOUT
                JMP     h_fail

; h_text: the packed text at the byte address R1, up to its 0, to the
; words from R4, a byte a word, with CR LF for each |. Uses R1-R3.
h_text
                MOVE[M] R2, @R1++
        ?Z      RET
                CMP     R2, 0x7C        ; |
        ?Z      MOVE    @R4++, 13
        ?Z      MOVE    R2, 10
                MOVE    @R4++, R2
                JMP     h_text

; h_byte: the byte R1 of the answer, in the status line or a header, or
; in the body: of a status of 200 decoded from UTF-8 into the body, else
; its first line kept for DS$, after which the status is raised. Uses
; R1-R7.
h_byte
                MOVE[M] R2, @V_HLINE
        ?N      JMP     h_body
                CMP     R1, 10          ; LF
        ?Z      JMP     :+
                CMP     R2, HTTP_LINE
        ?!C     RET                     ; past what is kept
                MOVE    @V_TPKT[R2], R1
                ADD     @V_HLINE, R2, 1
                RET
:
                CLR     @V_HLINE
                TST     R2
        ?Z      JMP     :+
                CMP     @V_TPKT-1[R2], 13  ; CR
        ?Z      SUB     R2, R2, 1
:
                TST     @V_HSTAT
        ?Z      JMP     h_first
                TST     R2
        ?Z      JMP     h_hend
                MOVE    R1, TEXT_B+4*S_HLEN
                CALL    h_hdr
        ?Z      JMP     h_clen
                MOVE    R1, TEXT_B+4*S_HLOC
                CALL    h_hdr
        ?!Z     RET
                MOVE    R4, V_HDST      ; Location: its value, for DS$
:
                CMP     R3, R2
        ?Z      JMP     :+
                MOVE    @R4++, @V_TPKT[R3]
                ADD     R3, R3, 1
                JMP     :-
:
                SUB     @V_HDS, R4, V_HDST
                RET
h_clen
                CLR     R4              ; Content-Length: its digits
:
                CMP     R3, R2
        ?Z      JMP     :+
                SUB     R5, @V_TPKT[R3], 0x30
                CMP     R5, 10
        ?!C     JMP     :+
                CMP     R4, 0x1000000
        ?!C     JMP     :+              ; more than any body
                ADD     R4, R4, R4
                ADD     R5, R5, R4
                SHL     R4, R4, 2
                ADD     R4, R4, R5
                ADD     R3, R3, 1
                JMP     :-
:
                MOVE    @V_HCL, R4
                RET
; The status line, HTTP/ and the version, a blank, and the 3 digits
h_first
                MOVE    R1, TEXT_B+4*S_HTTP
                CLR     R3
:
                MOVE[M] R4, @R1++
        ?Z      JMP     :+
                CMP     R3, R2
        ?Z      JMP     h_nothttp
                CMP     @V_TPKT[R3], R4
        ?!Z     JMP     h_nothttp
                ADD     R3, R3, 1
                JMP     :-
:
                CMP     R3, R2
        ?Z      JMP     h_nothttp
                CMP     @V_TPKT[R3], 0x20
                ADD     R3, R3, 1
        ?!Z     JMP     :-
                CLR     R4
                MOVE    R5, 3
:
                CMP     R3, R2
        ?Z      JMP     h_nothttp
                SUB     R6, @V_TPKT[R3], 0x30
                CMP     R6, 10
        ?!C     JMP     h_nothttp
                ADD     R4, R4, R4
                ADD     R6, R6, R4
                SHL     R4, R4, 2
                ADD     R4, R4, R6
                ADD     R3, R3, 1
                SUB[M]  R5, R5, 1
        ?!Z     JMP     :-
                TST     R4
        ?Z      JMP     h_nothttp
                MOVE    @V_HSTAT, R4
                RET
; The empty line after the headers: the body, or for another status
; with a Location, that status
h_hend
                NOT     @V_HLINE, R0
                CMP     @V_HSTAT, 200
        ?Z      RET
                TST     @V_HDS
        ?Z      RET
                JMP     h_status
h_body
                MOVE[M] R2, @V_HCL
        ?N      JMP     :+
                SUB     @V_HCL, R2, 1
:
                CMP     @V_HSTAT, 200
        ?Z      JMP     h_utf8
                CMP     R1, 10          ; the end of another status's first line
        ?Z      JMP     h_status
                CMP     R1, 13
        ?Z      JMP     h_status
                MOVE    R2, @V_HDS
                CMP     R2, DSS_MAX
        ?!C     RET
                SUB     R3, R1, 0x20
                CMP     R3, 0x5F
        ?!C     RET                     ; a control code, or not ASCII
                MOVE    @V_HDST[R2], R1
                ADD     @V_HDS, R2, 1
                RET
; UTF-8: a sequence cut short is a ?, and its byte starts anew
h_utf8
                MOVE[M] R2, @V_HNEED
        ?Z      JMP     h_lead
                AND     R3, R1, 0xC0
                CMP     R3, 0x80
        ?!Z     JMP     :+
                SHL     R3, @V_HCP, 6
                AND     R4, R1, 0x3F
                OR      R1, R3, R4
                MOVE    @V_HCP, R1
                SUB     R2, R2, 1
                MOVE    @V_HNEED, R2
                TST     R2
        ?!Z     RET
                JMP     h_cp
:
                CLR     @V_HNEED
                PUSH    R1
                MOVE    R1, 0x3F
                CALL    h_put
                POP     R1
h_lead
                CMP     R1, 0x80
        ?C      JMP     h_put           ; ASCII
                CMP     R1, 0xC0
        ?C      JMP     h_q             ; a byte that starts no sequence
                MOVE    R2, 1
                AND     R3, R1, 0x1F
                CMP     R1, 0xE0
        ?C      JMP     :+
                MOVE    R2, 2
                AND     R3, R1, 0x0F
                CMP     R1, 0xF0
        ?C      JMP     :+
                MOVE    R2, 3
                AND     R3, R1, 0x07
                CMP     R1, 0xF8
        ?!C     JMP     h_q
:
                MOVE    @V_HNEED, R2
                MOVE    @V_HCP, R3
                RET
; h_cp: the code point R1 as a code of the screen: the arrows U+2190 to
; U+2199 and the blocks U+2580 to U+258F as the low byte of their code
; point, the codes of their glyphs in the character ROM, ISO 8859-1 as it
; is, and a ? for U+0080 to U+009F and anything else
h_cp
                SUB     R2, R1, 0x2190
                CMP     R2, 10
        ?C      JMP     :+
                SUB     R2, R1, 0x2580
                CMP     R2, 16
        ?C      JMP     :+
                SUB     R2, R1, 0x80
                CMP     R2, 0x20
        ?C      JMP     h_q
                CMP     R1, 0x100
        ?C      JMP     h_put
h_q
                MOVE    R1, 0x3F        ; ?
                JMP     h_put
:
                AND     R1, R1, 0xFF
; h_put: the code R1 to the body, or String too long past its block
h_put
                MOVE    R2, @V_HN
                CMP     R2, HTTP_BODY
        ?!C     JMP     h_long
                ADD     R3, R2, @V_HBODY
                MOVE    @R3, R1
                ADD     @V_HN, R2, 1
                RET

; h_hdr: Z when the line at V_TPKT, of R2 characters, is the header of
; the name at the byte address R1, in lower case with its colon, in any
; case, with R3 at its value, after the blanks. Uses R1 and R3-R6.
h_hdr
                CLR     R3
:
                MOVE[M] R4, @R1++
        ?Z      JMP     :+
                CMP     R3, R2
        ?Z      JMP     :++             ; the line is shorter
                MOVE    R5, @V_TPKT[R3]
                SUB     R6, R5, 0x41
                CMP     R6, 26
        ?C      ADD     R5, R5, 0x20    ; in lower case
                CMP     R5, R4
        ?!Z     RET
                ADD     R3, R3, 1
                JMP     :-
:
                CMP     R3, R2
        ?Z      RET                     ; Z
                CMP     @V_TPKT[R3], 0x20
        ?!Z     JMP     h_yes
                ADD     R3, R3, 1
                JMP     :-
:
                CMP     R0, 1           ; not Z
                RET
h_yes
                CMP     R0, R0          ; Z
                RET

; URL$(S$): S$ percent-encoded for the path of a URL: a letter, a digit,
; and -._~ stay, a character from 0x80 becomes the two bytes of its
; UTF-8 as %XX%XX, and any other %XX, so a blank is %20. Its block
; takes S$'s slot, as + takes Y's. Uses R1-R7.
f_url
                CALL    s_paren
                CALL    s_top
                CLR     R5              ; the characters of the result
:
                SUB[M]  R2, R2, 1
        ?N      JMP     :+
                MOVE    R6, @R1++
                CALL    url_kind
                ADD     R5, R5, R7
                JMP     :-
:
                CMP     R5, STR_MAX+1
        ?!C     JMP     err_strlong
                SUB     R2, @V_SSP, 1
                OR      R2, R2, TAG_SLOT
                MOVE    R1, R5
                CALL    salloc
                MOVE    R4, R1
                CALL    s_top           ; again, as the sweep may have moved S$
                MOVE    @R3, R4
                MOVE    @1[R3], R5
                MOVE    R5, R1
:
                SUB[M]  R2, R2, 1
        ?N      RET
                MOVE    R6, @R5++
                CALL    url_kind
                CMP     R7, 3
        ?Z      JMP     :+
        ?C      MOVE    @R4++, R6       ; as it is
        ?C      JMP     :-
                SHR     R1, R6, 6       ; two bytes of UTF-8
                OR      R1, R1, 0xC0
                CALL    url_hex
                AND     R6, R6, 0x3F
                OR      R6, R6, 0x80
:
                MOVE    R1, R6
                CALL    url_hex
                JMP     :--

; url_kind: R7 the characters that URL$ makes of the character R6: 1, 3,
; or 6. Uses R3 and R7.
url_kind
                MOVE    R7, 6
                CMP     R6, 0x80
        ?!C     RET
                MOVE    R7, 1
                OR      R3, R6, 0x20
                SUB     R3, R3, 0x61
                CMP     R3, 26
        ?C      RET                     ; a letter
                SUB     R3, R6, 0x30
                CMP     R3, 10
        ?C      RET                     ; a digit
                CMP     R6, 0x2D        ; -
        ?Z      RET
                CMP     R6, 0x2E        ; .
        ?Z      RET
                CMP     R6, 0x5F        ; _
        ?Z      RET
                CMP     R6, 0x7E        ; ~
        ?Z      RET
                MOVE    R7, 3
                RET

; url_hex: % and the byte R1 in 2 hex digits to the words from R4. Uses R3.
url_hex
                MOVE    @R4++, 0x25
                SHR     R3, R1, 4
                CALL    :+
                AND     R3, R1, 0xF
:
                ADD     R3, R3, 0x30
                CMP     R3, 0x3A
        ?!C     ADD     R3, R3, 7       ; A to F
                MOVE    @R4++, R3
                RET

S_NODHCP
                .ASCII_B 'No answer from a DHCP server'
                .DAT    0
S_MASK          .ASCII_B 'Mask '
S_GW            .ASCII_B 'Gateway '
                .DAT    0
S_DNS           .ASCII_B 'DNS server '
S_DSRV          .ASCII_B 'DHCP server '
                .DAT    0
S_OCTET         .ASCII_B 'octet'
S_STAR          .ASCII_B '*'
S_BADTFTP
                .ASCII_B 'Not a TFTP server: IP[:PORT], such as "192.168.1.10" or "192.168.1.10:6969"'
S_NOTFTP
                .ASCII_B 'No answer from the TFTP server'
S_TFTPERR
                .ASCII_B 'TFTP error '
S_NOIP          .ASCII_B 'No IP address; IP or DHCP sets one'
S_NOROUTE
                .ASCII_B 'No answer to ARP from the server, or from the gateway'
S_NTPSRV
                .ASCII_B 'NTP server '
S_POOL          .ASCII_B 'pool.ntp.org'
                .DAT    0
; The pattern that clock_zone gives clk_parse is in this text, HH:MM from
; byte 17 up to the quote after it, so a change of the text before it
; moves it
S_BADNTP
                .ASCII_B 'Not an offset: "+HH:MM" or "-HH:MM", local time less UTC, such as "+01:00"'
S_NODNS         .ASCII_B 'No DNS server; DHCP gets one'
                .DAT    0
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
S_HGET          .ASCII_B 'GET '
                .DAT    0
S_HHOST         .ASCII_B ' HTTP/1.0|Host: '
                .DAT    0
S_HAGENT
                .ASCII_B '|User-Agent: NiceMon-BASIC/'
S_HEND          .ASCII_B '|Connection: close||'
                .DAT    0
S_HTTP          .ASCII_B 'HTTP/'
S_HLEN          .ASCII_B 'content-length:'
S_HLOC          .ASCII_B 'location:'
S_HNOT          .ASCII_B 'Not an HTTP server'
S_HSHORT
                .ASCII_B 'The answer of the server was cut short'
S_HSTAT         .ASCII_B 'HTTP status '
                .DAT    0
S_TREF          .ASCII_B 'The server refused the connection'
S_TRESET
                .ASCII_B 'The server reset the connection'
S_TTIME         .ASCII_B 'No answer from the server'
; The failures of the network, and their texts, which io_fail's
; io_text shows (basic_trap.nasm), and a 0
IO_TEXTS
                .DAT    MON_E_NOIP, S_NOIP, MON_E_NOROUTE, S_NOROUTE, MON_E_NODNS, S_NODNS
                .DAT    MON_E_DNSTIME, S_DNSTIME, MON_E_DNSNAME, S_DNSNAME, MON_E_DNSFAIL, S_DNSFAIL
                .DAT    MON_E_NODHCP, S_NODHCP, E_NTPTIME, S_NONTP, E_NTPBAD, S_NTPBAD
                .DAT    E_NTPKOD, S_NTPKOD, E_TNOANS, S_NOTFTP, E_TERROR, S_TFTPERR
                .DAT    E_TBAD, S_BADTFTP, E_NTPOFF, S_BADNTP, E_HNOTHTTP, S_HNOT
                .DAT    E_HSHORT, S_HSHORT, E_HSTATUS, S_HSTAT, MON_E_TREFUSED, S_TREF
                .DAT    MON_E_TRESET, S_TRESET, MON_E_TTIMEOUT, S_TTIME, 0
