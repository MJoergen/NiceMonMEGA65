; The monitor's TCP, which the Makefile joins after monitor_eth.nasm
; (issue #111, README.md, "TCP", and INTERNALS.md, "TCP"): the entries 26
; to 31, tcp_open, tcp_state, tcp_send, tcp_recv, tcp_close, and
; tcp_listen, for up to TCP_HANDLES connections at once, and their part of
; the poll: tcp_input, which net_frames calls for each segment, tcp_work,
; which net_step calls when a connection may have something to send, and
; tcp_timeout, which net_due calls when a connection's deadline is due.
;
; A connection's state is in its control block, in the program's RAM:
; TCP_CB words, then the ring of the bytes received, and the ring of the
; bytes to send, packed, 4 to a word, which the ROM reaches through the
; byte window. V_TCB has the plain address of each handle's block, 0 for
; a free handle, and a fifth word that is always 0, for a number that is
; no handle. A block's first word is TCP_CHECK while the ROM has it.
;
; The sequence numbers follow RFC 9293: the SYN and the FIN take one each.
; The ring to send holds the bytes from CB_SEQ0 on, sent and not, until
; they are acknowledged; CB_NXT is the next to send, and CB_MAX the
; highest it reached, so that a byte sent again is not timed (Karn). After
; tcp_close, TF_FIN puts the FIN after the last byte of the ring. The ring
; received holds the bytes that tcp_recv has not taken, and the window
; announced ends at CB_EDGE, which never moves left.
;
; Segments go out from tcp_out, called from tcp_work at the end of a poll,
; from tcp_send, tcp_close, and a timeout: what the windows let go, the
; FIN, and an ACK when one is owed, TF_ACK, or the window opened by
; enough; a segment with data carries the ACK. So a poll sends one ACK for
; all the segments of a connection that it took. tcp_emit builds a
; segment in the send buffer.
;
; Each connection has one deadline, CB_DUE: the retransmission of the
; SYN, of data, or of the FIN, and the probe of a zero window, while
; TF_ARM is set, or the end of FIN-WAIT-2, while TF_FW2 is. tcp_rearm puts
; the nearest of them, and the lease's housekeeping deadline, in V_NDUE,
; for net_step. Times are on the fine
; clock, net_clock, compared by their signed difference.
;
; A handle of tcp_listen, TF_PASSIVE, waits in LISTEN for a SYN to its
; port, which takes it to SYN-RECEIVED, and with the ACK of its SYN-ACK to
; ESTABLISHED, as RFC 793's passive open: one connection for each handle.
; A failed handshake, by a RST, a timeout, or a new IP address, brings it
; back to LISTEN, with the bytes that tcp_send took.

TCP_CB          .EQU    32              ; the words of a control block before its rings
TCP_HANDLES     .EQU    4               ; the connections at once
TCP_CHECK       .EQU    0x54435042      ; the first word of a block while the ROM has it, TCPB
TCP_MINBUF      .EQU    64              ; the fewest bytes of a ring
TCP_MSS         .EQU    1460            ; the largest segment's data, ours and the peer's
TCP_MSS0        .EQU    536             ; the peer's MSS without its option
TCP_RTO0        .EQU    1000000         ; the timeout before a round trip is measured, in microseconds
TCP_RTOMIN      .EQU    200000          ; the least timeout
TCP_RTOMAX      .EQU    60000000        ; and the largest, also of the probes of a zero window
TCP_SYNTIME     .EQU    15000000        ; how long the SYN is sent
TCP_GIVEUP      .EQU    120000000       ; how long data or a probe is sent with no answer
TCP_FW2TIME     .EQU    60000000        ; how long FIN-WAIT-2 waits for the peer's FIN
TCP_LINK        .EQU    4510            ; the station's port, the debug link's, which tcp_listen cannot have
; The words of a control block
CB_CHECK        .EQU    0               ; TCP_CHECK while the ROM has the block
CB_STATE        .EQU    1               ; the state, TS_, or the error, negative
CB_FLAGS        .EQU    2               ; the flags, TF_
CB_LPORT        .EQU    3               ; the local port
CB_RPORT        .EQU    4               ; the remote port
CB_RIP          .EQU    5               ; the remote IP address
CB_MACH         .EQU    6               ; the next hop's MAC address, as E_MACH
CB_MACL         .EQU    7               ; and E_MACL have it
CB_UNA          .EQU    8               ; SND.UNA, the first not acknowledged
CB_NXT          .EQU    9               ; SND.NXT, the next to send
CB_MAX          .EQU    10              ; the highest SND.NXT
CB_SEQ0         .EQU    11              ; the sequence number of the ring's first byte to send
CB_WND          .EQU    12              ; SND.WND, the peer's window
CB_CWND         .EQU    13              ; the congestion window, in bytes
CB_MSS          .EQU    14              ; the peer's MSS
CB_RNXT         .EQU    15              ; RCV.NXT, the next to receive
CB_EDGE         .EQU    16              ; the right edge of the window announced
CB_SRTT         .EQU    17              ; the smoothed round trip, in microseconds, 0 before one is measured
CB_RTTVAR       .EQU    18              ; its variation
CB_RTO          .EQU    19              ; the retransmission timeout
CB_DUE          .EQU    20              ; the deadline, while TF_ARM or TF_FW2 is set
CB_RTTSEQ       .EQU    21              ; the sequence number timed, while TF_RTT is set,
CB_RTTT         .EQU    22              ; and when it was sent
CB_GIVEUP       .EQU    23              ; when the sends give up, while TF_GIVEUP is set
CB_RXB          .EQU    24              ; the byte address of the ring received,
CB_RXSZ         .EQU    25              ; its bytes,
CB_RXHEAD       .EQU    26              ; the byte of its first to read,
CB_RXLEN        .EQU    27              ; and the bytes to read
CB_TXSZ         .EQU    28              ; the bytes of the ring to send, after the ring received,
CB_TXHEAD       .EQU    29              ; the byte of its first, at CB_SEQ0,
CB_TXLEN        .EQU    30              ; and its bytes, sent or not
; The states, which T_TCPST turns into those of tcp_state. 0 is a handle
; that tcp_open has taken while it waits for ARP, which nothing else
; reads. The states of a connection are 1 to TS_SYNRCVD.
TS_SYNSENT      .EQU    1               ; SYN-SENT
TS_ESTAB        .EQU    2               ; ESTABLISHED
TS_CWAIT        .EQU    3               ; CLOSE-WAIT
TS_FINW1        .EQU    4               ; FIN-WAIT-1
TS_FINW2        .EQU    5               ; FIN-WAIT-2
TS_CLOSING      .EQU    6               ; CLOSING
TS_LASTACK      .EQU    7               ; LAST-ACK
TS_SYNRCVD      .EQU    8               ; SYN-RECEIVED
TS_LISTEN       .EQU    9               ; LISTEN
; The flags of a block
TF_ACK          .EQU    1               ; an ACK is owed
TF_FIN          .EQU    2               ; closed by tcp_close: the FIN after the ring's bytes
TF_RTT          .EQU    4               ; a segment is timed
TF_GIVEUP       .EQU    8               ; CB_GIVEUP counts
TF_PROBE        .EQU    16              ; the send of a timeout, which takes a zero window as 1
TF_ARM          .EQU    32              ; the deadline of a send again, or of a probe
TF_FW2          .EQU    64              ; the deadline of FIN-WAIT-2
TF_PASSIVE      .EQU    128             ; a handle of tcp_listen, in any state
; The flags of a segment
TH_FIN          .EQU    1
TH_SYN          .EQU    2
TH_RST          .EQU    4
TH_PSH          .EQU    8
TH_ACK          .EQU    16
; The errors
E_THANDLE       .EQU    -50             ; not a handle, or a free one
E_TFULL         .EQU    -51             ; every handle in use
E_TSIZE         .EQU    -52             ; a ring of fewer than 64 bytes, or a block not aligned or out of reach
E_TREFUSED      .EQU    -53             ; the peer refused the connection
E_TRESET        .EQU    -54             ; the peer reset it, or the IP address changed
E_TTIMEOUT      .EQU    -55             ; no answer from the peer
E_TCLOSED       .EQU    -56             ; tcp_close was called
E_TEOF          .EQU    -57             ; the peer has closed, and every byte is read

; tcp_open: entry 26. R1 the word address of a control block, R2 an IP
; address, R3 a port, R4 the sizes of the rings in bytes, to receive in
; bits 31..16 and to send in 15..0, each 64 or more. The next hop is
; resolved by net_hop, which may wait for ARP up to 3 seconds, with the
; handle taken, and the SYN sent, from the next local port of tcp_lport.
; Does not wait for the answer. R1 = the handle, 0 to 3, or E_NOIP,
; E_PORT, E_TSIZE, E_TFULL, or E_NOROUTE, also for the address 0 or
; 255.255.255.255. Uses R1-R6, and R7-R11 across the calls, saved: the
; block, the address, the port, the sizes, and the result.
tcp_open
                PUSH    R7
                PUSH    R8
                PUSH    R9
                PUSH    R10
                PUSH    R11
                MOVE    R7, R1
                MOVE    R8, R2
                MOVE    R9, R3
                MOVE    R10, R4
                CALL    net_step
                MOVE    R11, E_NOIP
                TST     @E_IP
        ?Z      JMP     topen_end
                MOVE    R11, E_PORT
                SUB     R1, R9, 1
                CMP     R1, 0xFFFF
        ?!C     JMP     topen_end       ; 0, or past 65535
                MOVE    R11, E_TSIZE
                MOVE    R1, R7
                MOVE    R2, R10
                CALL    tcp_cbok
                MOVE    R7, R1
        ?Z      JMP     topen_end
                MOVE    R11, E_TFULL
                CALL    tcp_slot
        ?Z      JMP     topen_end
                MOVE    R11, R1         ; the handle's word of V_TCB
                MOVE    @CB_CHECK[R7], 0
                MOVE    @CB_STATE[R7], 0  ; taken, which nothing else reads
                MOVE    @CB_FLAGS[R7], 0
                CALL    tcp_lport
                MOVE    @CB_LPORT[R7], R1
                MOVE    @R11, R7        ; taken, so that the network stays on through the ARP
                CALL    net_on
                ADD     R1, R8, 1
                CMP     R1, 2
        ?C      JMP     topen_noroute   ; 0 or 255.255.255.255
                MOVE    R1, R8
                CALL    net_hop
                TST     R1
        ?!Z     JMP     topen_noroute
                MOVE    @CB_MACH[R7], R2
                MOVE    @CB_MACL[R7], R3
                MOVE    @CB_RIP[R7], R8
                MOVE    @CB_RPORT[R7], R9
                MOVE    R1, R10
                CALL    tcp_init
                MOVE    @CB_STATE[R7], TS_SYNSENT
                CALL    net_clock
                ADD     @CB_GIVEUP[R7], R1, TCP_SYNTIME
                MOVE    @CB_FLAGS[R7], TF_GIVEUP
                MOVE    @CB_CHECK[R7], TCP_CHECK
                CALL    tcp_out         ; the SYN
                CALL    tcp_rearm
                SUB     R11, R11, V_TCB  ; the handle
                JMP     topen_end
topen_noroute
                MOVE    @R11, 0
                CALL    net_off
                MOVE    R11, E_NOROUTE
topen_end
                MOVE    R1, R11
                POP     R11
                POP     R10
                POP     R9
                POP     R8
                POP     R7
                RET

; tcp_cbok: R1 = the plain address of the control block at the word
; address R1, for the sizes R2, as tcp_open takes them, with Z clear; or
; R1 = 0, with Z set, for an address of the word window that is not
; aligned, a ring of fewer than TCP_MINBUF bytes, or a block below
; PROGRAM, or past the first 64M words, which the byte window reaches.
; Uses R1-R4.
tcp_cbok
                SHR     R3, R1, 28
                CMP     R3, 1
        ?!Z     JMP     :+
                AND[M]  R0, R1, 3
        ?!Z     JMP     tcbok_no        ; not aligned
                AND     R1, R1, 0x0FFFFFFF
                SHR     R1, R1, 2
:
                SHR     R3, R2, 16      ; the ring received
                AND     R4, R2, 0xFFFF  ; and the ring to send
                CMP     R3, TCP_MINBUF
        ?C      JMP     tcbok_no
                CMP     R4, TCP_MINBUF
        ?C      JMP     tcbok_no
                ADD     R3, R3, 3
                SHR     R3, R3, 2
                ADD     R4, R4, 3
                SHR     R4, R4, 2
                ADD     R3, R3, R4
                ADD     R3, R3, TCP_CB
                ADD     R3, R3, R1      ; the word after the block
                CMP     R1, PROGRAM
        ?C      JMP     tcbok_no
                CMP     R3, 0x04000001
        ?!C     JMP     tcbok_no
                MOVE[M] R1, R1
                RET
tcbok_no
                MOVE[M] R1, R0
                RET

; tcp_slot: R1 = the first free word of V_TCB, with Z clear, or 0, with Z
; set, when every handle is taken. Uses R1.
tcp_slot
                MOVE    R1, V_TCB
:
                TST     @R1
        ?Z      JMP     :+
                ADD     R1, R1, 1
                CMP     R1, V_TCB+TCP_HANDLES
        ?!Z     JMP     :-
                MOVE[M] R1, R0
                RET
:
                MOVE[M] R1, R1
                RET

; tcp_lport: R1 = V_TCPORT, the next local port of 49152 to 65535 after
; the one before, which no handle has. The cold start picks the first from
; the microseconds. Uses R1-R3.
tcp_lport
                MOVE    R1, @V_TCPORT
tlport_next
                ADD     R1, R1, 1
                CMP     R1, 0x10000
        ?!C     MOVE    R1, 0xC000
                MOVE    R2, V_TCB
tlport_slot
                MOVE[M] R3, @R2++
        ?Z      JMP     :+
                CMP     @CB_LPORT[R3], R1
        ?Z      JMP     tlport_next     ; in use
:
                CMP     R2, V_TCB+TCP_HANDLES
        ?!Z     JMP     tlport_slot
                MOVE    @V_TCPORT, R1
                RET

; tcp_init: the control block R7 set up for the sizes R1, as tcp_open
; takes them, by tcp_rings, then tcp_isn. Uses R1-R4.
tcp_init
                CALL    tcp_rings
; tcp_isn: the connection R7 set up to start: the timeout TCP_RTO0, the
; peer's MSS TCP_MSS0, and the initial sequence number the fine clock plus
; 64000 times the connections opened since the cold start, V_TCOPENS.
; Uses R1-R4.
tcp_isn
                MOVE    @CB_RTO[R7], TCP_RTO0
                MOVE    @CB_SRTT[R7], 0
                MOVE    @CB_RTTVAR[R7], 0
                MOVE    @CB_MSS[R7], TCP_MSS0
                MOVE    @CB_CWND[R7], 2*TCP_MSS0
                MOVE    @CB_WND[R7], 0
                MOVE    @CB_RNXT[R7], 0
                MOVE    @CB_EDGE[R7], 0
                MOVE    R2, @V_TCOPENS
                ADD     @V_TCOPENS, R2, 1
                SHL     R3, R2, 16
                SHL     R4, R2, 10
                SUB     R3, R3, R4
                SHL     R4, R2, 9
                SUB     R3, R3, R4      ; 64000 times, as 65536 - 1024 - 512
                CALL    net_clock
                ADD     R1, R1, R3
                MOVE    @CB_UNA[R7], R1
                MOVE    @CB_NXT[R7], R1
                MOVE    @CB_MAX[R7], R1
                ADD     @CB_SEQ0[R7], R1, 1
                RET

; tcp_rings: the rings of the control block R7 set up, empty, for the
; sizes R1, as tcp_open takes them. Uses R1.
tcp_rings
                SHR     @CB_RXSZ[R7], R1, 16
                AND     @CB_TXSZ[R7], R1, 0xFFFF
                ADD     R1, R7, TCP_CB
                SHL     R1, R1, 2
                ADD     @CB_RXB[R7], R1, 0x20000000
                MOVE    @CB_RXHEAD[R7], 0
                MOVE    @CB_RXLEN[R7], 0
                MOVE    @CB_TXHEAD[R7], 0
                MOVE    @CB_TXLEN[R7], 0
                RET

; tcp_hcb: R1 = the control block of the handle R1, with Z clear, or 0,
; with Z set, for a free handle or a number that is none. Uses R1.
tcp_hcb
                CMP     R1, TCP_HANDLES
        ?!C     MOVE    R1, TCP_HANDLES  ; the word after the handles, always 0
                MOVE[M] R1, @V_TCB[R1]
                RET

; tcp_state: entry 27. R1 a handle, after a poll. R1 = its state, as
; T_TCPST gives it: TCP_FREE, 0, for a free handle, or the error,
; negative; or E_THANDLE for a number that is no handle. Uses R1-R6, and
; R7 across the calls, saved.
tcp_state
                PUSH    R7
                MOVE    R7, R1
                CALL    net_step
                MOVE    R1, E_THANDLE
                CMP     R7, TCP_HANDLES
        ?!C     JMP     :+
                MOVE[M] R1, @V_TCB[R7]
        ?Z      JMP     :+              ; free
                MOVE[M] R1, @CB_STATE[R1]
        ?!N     MOVE    R1, @T_TCPST[R1]
:
                POP     R7
                RET

; tcp_send: entry 28. R1 a handle, R2 the byte address of a buffer, R3 a
; number of bytes. After a poll, as many as fit copied into the ring to
; send, and sent as far as the windows let them. R1 = the bytes taken, 0
; when none fit, or E_THANDLE, E_TCLOSED after tcp_close, or the error.
; Uses R1-R6, and R7-R9 across the calls, saved.
tcp_send
                PUSH    R7
                PUSH    R8
                PUSH    R9
                MOVE    R7, R1
                MOVE    R8, R2
                MOVE    R9, R3
                CALL    tcp_entry
        ?!Z     JMP     tsend_end
                SUB     R1, @CB_TXSZ[R7], @CB_TXLEN[R7]  ; the room
                CMP     R9, R1
        ?!C     MOVE    R9, R1
                CALL    tcp_txb
                ADD     R2, @CB_TXHEAD[R7], @CB_TXLEN[R7]
                MOVE    R3, @CB_TXSZ[R7]
                MOVE    R4, R8
                MOVE    R5, R9
                CALL    tcp_put
                ADD     @CB_TXLEN[R7], @CB_TXLEN[R7], R9
                CALL    tcp_out
                CALL    tcp_rearm
                MOVE    R1, R9
tsend_end
                POP     R9
                POP     R8
                POP     R7
                RET

; tcp_recv: entry 29. R1 a handle, R2 the byte address of a buffer, R3 a
; number of bytes. After a poll, up to that many of the bytes received
; copied, in order; the next poll announces the room they leave, if it
; is enough. R1 = the bytes copied, 0 when none wait, E_TEOF once the peer
; has closed and every byte is read, or E_THANDLE, E_TCLOSED after
; tcp_close, or the error. Uses R1-R6, and R7-R9 across the calls, saved.
tcp_recv
                PUSH    R7
                PUSH    R8
                PUSH    R9
                MOVE    R7, R1
                MOVE    R8, R2
                MOVE    R9, R3
                CALL    tcp_entry
        ?!Z     JMP     trecv_end
                MOVE    R1, @CB_RXLEN[R7]
                CMP     R9, R1
        ?!C     MOVE    R9, R1
                TST     R9
        ?!Z     JMP     :+
                MOVE    R1, 0
                CMP     @CB_STATE[R7], TS_CWAIT
        ?Z      MOVE    R1, E_TEOF
                JMP     trecv_end
:
                SUB     @CB_RXLEN[R7], @CB_RXLEN[R7], R9
                MOVE    R1, @CB_RXB[R7]
                MOVE    R2, @CB_RXHEAD[R7]
                MOVE    R3, @CB_RXSZ[R7]
                MOVE    R4, R8
                MOVE    R5, R9
                CALL    tcp_get
                MOVE    @CB_RXHEAD[R7], R2
                MOVE    @V_TCWORK, 1    ; the window, which may open
                MOVE    R1, R9
trecv_end
                POP     R9
                POP     R8
                POP     R7
                RET

; tcp_entry: for tcp_send and tcp_recv, a poll, and R7 = the control block
; of the handle R7, with Z set; or with Z clear, R1 = E_THANDLE for a free
; handle or a number that is none, the error of a connection, or
; E_TCLOSED after tcp_close. Uses R1-R6.
tcp_entry
                CALL    net_step
                MOVE    R1, R7
                CALL    tcp_hcb
                MOVE    R7, R1
        ?!Z     JMP     :+
                MOVE[M] R1, E_THANDLE
                RET
:
                MOVE[M] R1, @CB_STATE[R7]
        ?N      RET                     ; the error, with Z clear
                MOVE    R1, E_TCLOSED
                AND[M]  R0, @CB_FLAGS[R7], TF_FIN
                RET

; tcp_close: entry 30. R1 a handle, R2 0 to close, or 1 to abort. After a
; poll: a close drops the bytes received that wait, and those that come
; later, and puts the FIN after the bytes to send; the connection ends in
; the poll, and the handle frees itself. A close of a connection in an
; error, or of a handle in SYN-SENT or LISTEN, frees the handle at once,
; and one in SYN-RECEIVED after a RST. An abort sends a RST, but in
; SYN-SENT and LISTEN, and frees it at once, also during a close. R1 = 0,
; or E_THANDLE. Uses R1-R6, and R7 and R8 across the calls, saved.
tcp_close
                PUSH    R7
                PUSH    R8
                MOVE    R7, R1
                MOVE    R8, R2
                CALL    net_step
                MOVE    R1, R7
                CALL    tcp_hcb
                MOVE    R7, R1
        ?Z      MOVE    R1, E_THANDLE
        ?Z      JMP     tclose_end
                MOVE[M] R1, @CB_STATE[R7]
        ?N      JMP     tclose_free     ; an error
                CMP     R1, TS_LISTEN
        ?Z      JMP     tclose_free     ; which sends nothing
                TST     R8
        ?!Z     JMP     tclose_abort
                AND[M]  R0, @CB_FLAGS[R7], TF_FIN
        ?!Z     JMP     tclose_ok       ; closing already
                CMP     R1, TS_SYNSENT
        ?Z      JMP     tclose_free
                CMP     R1, TS_SYNRCVD
        ?Z      JMP     tclose_abort    ; a RST, and freed
                CMP     R1, TS_ESTAB
        ?Z      MOVE    @CB_STATE[R7], TS_FINW1
                CMP     R1, TS_CWAIT
        ?Z      MOVE    @CB_STATE[R7], TS_LASTACK
                OR      @CB_FLAGS[R7], @CB_FLAGS[R7], TF_FIN
                MOVE    @CB_RXLEN[R7], 0  ; the bytes that wait, dropped
                CALL    tcp_out
                JMP     tclose_ok
tclose_abort
                CMP     R1, TS_ESTAB
        ?!C     CALL    tcp_rst         ; but in SYN-SENT
tclose_free
                CALL    tcp_drop
tclose_ok
                CALL    tcp_rearm
                MOVE    R1, 0
tclose_end
                POP     R8
                POP     R7
                RET

; tcp_listen: entry 31. R1 the word address of a control block, R2 a
; local port, R3 the sizes of the rings, as R4 of tcp_open. A handle that
; waits in LISTEN for a peer to connect to the port, which tcp_input's
; tin_listen takes. Other handles may listen on the same port. Sends
; nothing, and does not wait. R1 = the handle, 0 to 3, or E_NOIP, E_PORT,
; for 0, past 65535, or TCP_LINK, E_TSIZE, or E_TFULL. Uses R1-R6, and
; R7-R10 across the calls, saved: the block, the port, the sizes, and the
; result.
tcp_listen
                PUSH    R7
                PUSH    R8
                PUSH    R9
                PUSH    R10
                MOVE    R7, R1
                MOVE    R8, R2
                MOVE    R9, R3
                CALL    net_step
                MOVE    R10, E_NOIP
                TST     @E_IP
        ?Z      JMP     tlisten_end
                MOVE    R10, E_PORT
                SUB     R1, R8, 1
                CMP     R1, 0xFFFF
        ?!C     JMP     tlisten_end     ; 0, or past 65535
                CMP     R8, TCP_LINK
        ?Z      JMP     tlisten_end
                MOVE    R10, E_TSIZE
                MOVE    R1, R7
                MOVE    R2, R9
                CALL    tcp_cbok
                MOVE    R7, R1
        ?Z      JMP     tlisten_end
                MOVE    R10, E_TFULL
                CALL    tcp_slot
        ?Z      JMP     tlisten_end
                MOVE    R10, R1         ; the handle's word of V_TCB
                MOVE    @CB_LPORT[R7], R8
                MOVE    R1, R9
                CALL    tcp_rings
                CALL    tcp_relisten
                MOVE    @CB_CHECK[R7], TCP_CHECK
                MOVE    @R10, R7
                CALL    net_on
                SUB     R10, R10, V_TCB  ; the handle
tlisten_end
                MOVE    R1, R10
                POP     R10
                POP     R9
                POP     R8
                POP     R7
                RET

; tcp_drop: the handle of the control block R7 freed, and its check word
; cleared, so that the block is the program's again, and the port for
; Ethernet frames disabled by net_off if nothing else has the network on.
; The caller calls tcp_rearm. Uses R1.
tcp_drop
                MOVE    R1, V_TCB
:
                CMP     @R1, R7
        ?Z      MOVE    @R1, 0
                ADD     R1, R1, 1
                CMP     R1, V_TCB+TCP_HANDLES
        ?!Z     JMP     :-
                MOVE    @CB_CHECK[R7], 0
                MOVE    @CB_FLAGS[R7], 0
                JMP     net_off         ; which returns to the caller

; tcp_fail: the connection R7 ended in the error R1, which stays until
; tcp_close, with no deadline; after tcp_close the handle is freed at once
; instead, and in SYN-RECEIVED it goes back to LISTEN. Uses R1.
tcp_fail
                AND[M]  R0, @CB_FLAGS[R7], TF_FIN
        ?!Z     JMP     tcp_drop
                CMP     @CB_STATE[R7], TS_SYNRCVD
        ?Z      JMP     tcp_relisten    ; which returns to the caller
                MOVE    @CB_STATE[R7], R1
                AND     @CB_FLAGS[R7], @CB_FLAGS[R7], 0xFFFFFFFF-TF_ARM-TF_FW2
                RET

; tcp_relisten: the handle of tcp_listen R7 back in LISTEN, after a failed
; handshake: the peer's address and port, and the deadlines, cleared; the
; local port, and the bytes that tcp_send took, kept. Uses no register.
tcp_relisten
                MOVE    @CB_STATE[R7], TS_LISTEN
                MOVE    @CB_FLAGS[R7], TF_PASSIVE
                MOVE    @CB_RIP[R7], 0
                MOVE    @CB_RPORT[R7], 0
                RET

; tcp_resetall: every connection ended in E_TRESET, as the IP address
; changed, with no RST; one in SYN-RECEIVED goes back to LISTEN, as
; tcp_fail has it, and a handle in LISTEN stays. Uses R1-R3.
tcp_resetall
                PUSH    R7
                MOVE    R2, V_TCB
:
                MOVE[M] R7, @R2++
        ?Z      JMP     :+
                MOVE    R1, @CB_STATE[R7]
                SUB     R1, R1, TS_SYNSENT
                CMP     R1, TS_SYNRCVD
        ?!C     JMP     :+              ; no connection
                MOVE    R1, E_TRESET
                CALL    tcp_fail
:
                CMP     R2, V_TCB+TCP_HANDLES
        ?!Z     JMP     :--
                POP     R7
                JMP     tcp_rearm       ; which returns to the caller

; tcp_close_all: for net_close, at the cold start, mon_exit, and
; mon_trap: a RST at best effort for each connection that has one, and
; every handle freed, with none for a handle in LISTEN. The block of a handle is trusted only if its address
; is one that tcp_open takes, and its check word is TCP_CHECK, as a host
; may have loaded another program over it. Uses R1-R6, and R7 and R8
; across the calls, saved.
tcp_close_all
                PUSH    R7
                PUSH    R8
                MOVE    R8, V_TCB
:
                MOVE    R7, @R8
                MOVE    @R8++, 0
                CMP     R7, PROGRAM
        ?C      JMP     :+
                CMP     R7, 0x04000000-TCP_CB
        ?!C     JMP     :+
                CMP     @CB_CHECK[R7], TCP_CHECK
        ?!Z     JMP     :+
                MOVE    @CB_CHECK[R7], 0
                MOVE    R1, @CB_STATE[R7]
                SUB     R1, R1, TS_ESTAB
                CMP     R1, TS_SYNRCVD-TS_ESTAB+1
        ?C      CALL    tcp_rst         ; ESTABLISHED to SYN-RECEIVED, not LISTEN
:
                CMP     R8, V_TCB+TCP_HANDLES+1
        ?!Z     JMP     :--
                MOVE    @V_TCWORK, 0
                POP     R8
                POP     R7
                RET

; tcp_txb: R1 = the byte address of the ring to send of R7, after the
; ring received, at a word. Uses R1.
tcp_txb
                ADD     R1, @CB_RXSZ[R7], 3
                AND     R1, R1, 0xFFFFFFFC
                ADD     R1, R1, @CB_RXB[R7]
                RET

; tcp_put: R5 bytes copied from the byte address R4 into the ring at the
; byte address R1, of R3 bytes, from its byte R2, up to twice R3, which
; wraps. Uses R1-R6.
tcp_put
                CMP     R2, R3
        ?!C     SUB     R2, R2, R3
:
                SUB[M]  R5, R5, 1
        ?C      RET
                ADD     R6, R1, R2
                MOVE    @R6, @R4++
                ADD     R2, R2, 1
                CMP     R2, R3
        ?Z      MOVE    R2, 0
                JMP     :-

; tcp_get: R5 bytes copied from the ring at the byte address R1, of R3
; bytes, from its byte R2, to the byte address R4. R2 = the ring's byte
; after them. Uses R1-R6.
tcp_get
                SUB[M]  R5, R5, 1
        ?C      RET
                ADD     R6, R1, R2
                MOVE    @R4++, @R6
                ADD     R2, R2, 1
                CMP     R2, R3
        ?Z      MOVE    R2, 0
                JMP     tcp_get

; tcp_work: for net_step, when V_TCWORK says that a connection may have
; something to send: tcp_out of each, and the deadlines again. Uses R1-R6,
; and R7 and R8 across the calls, saved.
tcp_work
                PUSH    R7
                PUSH    R8
                MOVE    @V_TCWORK, 0
                MOVE    R8, V_TCB
:
                MOVE[M] R7, @R8++
        ?!Z     CALL    tcp_out
                CMP     R8, V_TCB+TCP_HANDLES
        ?!Z     JMP     :-
                POP     R8
                POP     R7
                JMP     tcp_rearm       ; which returns to the caller

; tcp_rearm: V_NDUE the nearest deadline of all the connections and the
; lease's housekeeping, V_LDUE while V_LARM is armed, armed in V_NARM, or
; V_NARM 0 when none has one. Uses R1-R3.
tcp_rearm
                MOVE    @V_NARM, @V_LARM
                MOVE    @V_NDUE, @V_LDUE
                MOVE    R2, V_TCB
trearm_next
                MOVE[M] R3, @R2++
        ?Z      JMP     trearm_skip
                AND[M]  R0, @CB_FLAGS[R3], TF_ARM+TF_FW2
        ?Z      JMP     trearm_skip
                MOVE    R1, @CB_DUE[R3]
                TST     @V_NARM
        ?Z      JMP     :+
                SUB[M]  R0, R1, @V_NDUE
        ?!N     JMP     trearm_skip     ; not nearer
:
                MOVE    @V_NDUE, R1
                MOVE    @V_NARM, 1
trearm_skip
                CMP     R2, V_TCB+TCP_HANDLES
        ?!Z     JMP     trearm_next
                RET

; tcp_due: for net_due, tcp_timeout of each connection whose deadline is
; due, and the deadlines again. Uses R1-R6, and R7 and R8 across the
; calls, saved.
tcp_due
                PUSH    R7
                PUSH    R8
                MOVE    R8, V_TCB
tdue_next
                MOVE[M] R7, @R8++
        ?Z      JMP     tdue_skip
                AND[M]  R0, @CB_FLAGS[R7], TF_ARM+TF_FW2
        ?Z      JMP     tdue_skip
                CALL    net_clock
                SUB[M]  R0, R1, @CB_DUE[R7]
        ?!N     CALL    tcp_timeout
tdue_skip
                CMP     R8, V_TCB+TCP_HANDLES
        ?!Z     JMP     tdue_next
                POP     R8
                POP     R7
                JMP     tcp_rearm       ; which returns to the caller

; tcp_timeout: the deadline of the connection R7, due. At the end of
; FIN-WAIT-2, a RST, and the handle freed. Else, unless the sends have
; given up, which ends the connection in E_TTIMEOUT, the timeout doubled,
; up to TCP_RTOMAX, the congestion window one segment, no segment timed,
; and from SND.UNA one segment sent again by tcp_out: the SYN, data, the
; FIN, or, when the peer's window is 0, one byte, the probe. The sends
; give up TCP_GIVEUP after the first timeout with no new data
; acknowledged, or, for the SYN, TCP_SYNTIME after it was first sent.
; Uses R1-R6.
tcp_timeout
                MOVE    R3, @CB_FLAGS[R7]
                AND[M]  R0, R3, TF_FW2
        ?Z      JMP     :+
                CALL    tcp_rst
                JMP     tcp_drop        ; which returns to the caller
:
                CALL    net_clock
                AND[M]  R0, R3, TF_GIVEUP
        ?Z      JMP     :+
                SUB[M]  R0, R1, @CB_GIVEUP[R7]
        ?N      JMP     :++
                MOVE    R1, E_TTIMEOUT
                JMP     tcp_fail        ; which returns to the caller
:
                ADD     @CB_GIVEUP[R7], R1, TCP_GIVEUP
                OR      R3, R3, TF_GIVEUP
:
                AND     R3, R3, 0xFFFFFFFF-TF_RTT-TF_ARM
                TST     @CB_WND[R7]
        ?Z      OR      R3, R3, TF_PROBE
                MOVE    @CB_FLAGS[R7], R3
                SHL     R1, @CB_RTO[R7], 1
                CMP     R1, TCP_RTOMAX
        ?!C     MOVE    R1, TCP_RTOMAX
                MOVE    @CB_RTO[R7], R1
                MOVE    @CB_CWND[R7], @CB_MSS[R7]
                MOVE    @CB_NXT[R7], @CB_UNA[R7]
                CALL    tcp_out
                AND     @CB_FLAGS[R7], @CB_FLAGS[R7], 0xFFFFFFFF-TF_PROBE
                RET

; tcp_out: what the connection R7 has to send, sent: in SYN-SENT the SYN,
; and in SYN-RECEIVED the SYN-ACK, unless it is in flight; from ESTABLISHED to LAST-ACK, the bytes of the
; ring not sent, in segments of up to the peer's MSS, as far as the
; smaller of its window and the congestion window lets them go from
; SND.UNA, then after tcp_close the FIN; and when none of those went, a
; pure ACK if one is owed, or if the window would open by tcp_wcalc's
; least. Then tcp_arm. Uses R1-R6, and R8-R10 across the calls, saved: the
; bytes, and the segments sent.
tcp_out
                PUSH    R8
                PUSH    R9
                PUSH    R10
                MOVE    R10, 0
                MOVE    R1, @CB_STATE[R7]
                MOVE    R4, TH_SYN
                CMP     R1, TS_SYNSENT
        ?Z      JMP     :+
                MOVE    R4, TH_SYN+TH_ACK
                CMP     R1, TS_SYNRCVD
        ?!Z     JMP     tout_data
:
                CMP     @CB_NXT[R7], @CB_UNA[R7]
        ?!Z     JMP     tout_end        ; the SYN in flight
                MOVE    R2, @CB_UNA[R7]
                MOVE    R5, 0
                CALL    tout_seg
                JMP     tout_end
tout_data
                SUB     R1, R1, TS_ESTAB
                CMP     R1, TS_LASTACK-TS_ESTAB+1
        ?!C     JMP     tout_end        ; neither ESTABLISHED to LAST-ACK
tout_loop
                SUB     R8, @CB_NXT[R7], @CB_SEQ0[R7]
                SUB[M]  R8, @CB_TXLEN[R7], R8  ; the bytes not sent
        ?N      JMP     tout_ack        ; and the FIN sent
        ?Z      JMP     tout_fin
                MOVE[M] R2, @CB_WND[R7]
        ?!Z     JMP     :+
                AND[M]  R0, @CB_FLAGS[R7], TF_PROBE
        ?!Z     MOVE    R2, 1
:
                CMP     R2, @CB_CWND[R7]
        ?!C     MOVE    R2, @CB_CWND[R7]
                ADD     R2, R2, @CB_UNA[R7]
                SUB[M]  R2, R2, @CB_NXT[R7]  ; the room in the windows
        ?N      JMP     tout_ack
        ?Z      JMP     tout_ack
                CMP     R8, R2
        ?!C     MOVE    R8, R2
                CMP     R8, @CB_MSS[R7]
        ?!C     MOVE    R8, @CB_MSS[R7]
                MOVE    R2, @CB_NXT[R7]
                MOVE    R4, TH_ACK+TH_PSH
                MOVE    R5, R8
                CALL    tout_seg
                JMP     tout_loop
tout_fin
                AND[M]  R0, @CB_FLAGS[R7], TF_FIN
        ?Z      JMP     tout_ack
                MOVE    R2, @CB_NXT[R7]
                MOVE    R4, TH_ACK+TH_FIN
                MOVE    R5, 0
                CALL    tout_seg
tout_ack
                TST     R10
        ?!Z     JMP     tout_end        ; which carried the ACK
                AND[M]  R0, @CB_FLAGS[R7], TF_ACK
        ?!Z     JMP     :+
                CALL    tcp_wcalc
                SUB     R1, R1, @CB_EDGE[R7]
                SUB[M]  R0, R1, R2
        ?N      JMP     tout_end        ; no update of the window
:
                MOVE    R2, @CB_NXT[R7]
                MOVE    R4, TH_ACK
                MOVE    R5, 0
                CALL    tcp_seg
tout_end
                CALL    tcp_arm
                POP     R10
                POP     R9
                POP     R8
                RET

; tout_seg: for tcp_out, the segment of tcp_seg sent from the sequence
; number R2, with the flags R4 and R5 bytes, counted in R10. SND.NXT moves
; past it, and CB_MAX with it; a segment from CB_MAX is timed, if none is.
; Uses R1-R6, and R9.
tout_seg
                ADD     R10, R10, 1
                ADD     R9, R2, R5
                AND[M]  R0, R4, TH_SYN+TH_FIN
        ?!Z     ADD     R9, R9, 1
                CMP     R2, @CB_MAX[R7]
        ?!Z     JMP     :+              ; sent again
                AND[M]  R0, @CB_FLAGS[R7], TF_RTT
        ?!Z     JMP     :+
                MOVE    @CB_RTTSEQ[R7], R2
                CALL    net_clock
                MOVE    @CB_RTTT[R7], R1
                OR      @CB_FLAGS[R7], @CB_FLAGS[R7], TF_RTT
:
                MOVE    @CB_NXT[R7], R9
                SUB[M]  R0, R9, @CB_MAX[R7]
        ?!N     MOVE    @CB_MAX[R7], R9
                JMP     tcp_seg         ; which returns to the caller

; tcp_arm: the deadline of the connection R7, which tcp_rearm then takes:
; armed, TF_ARM, if it is not, at the timeout from now, or when the sends
; give up if that comes first, while a segment is in flight, or bytes wait
; for the peer's window to open; and else not.
; The deadline of FIN-WAIT-2, TF_FW2, stays. Uses R1-R3.
tcp_arm
                MOVE    R3, @CB_FLAGS[R7]
                AND[M]  R0, R3, TF_FW2
        ?!Z     RET
                MOVE    R1, @CB_STATE[R7]
                SUB     R1, R1, TS_SYNSENT
                CMP     R1, TS_SYNRCVD
        ?!C     JMP     tarm_off        ; no connection
                CMP     @CB_NXT[R7], @CB_UNA[R7]
        ?!Z     JMP     tarm_on         ; in flight
                SUB     R1, @CB_NXT[R7], @CB_SEQ0[R7]
                SUB[M]  R0, @CB_TXLEN[R7], R1
        ?N      JMP     tarm_off
        ?Z      JMP     tarm_off        ; no bytes wait
tarm_on
                AND[M]  R0, R3, TF_ARM
        ?!Z     RET                     ; armed already
                OR      @CB_FLAGS[R7], R3, TF_ARM
                CALL    net_clock
                ADD     R1, R1, @CB_RTO[R7]
                AND[M]  R0, R3, TF_GIVEUP
        ?Z      JMP     :+
                SUB[M]  R0, R1, @CB_GIVEUP[R7]
        ?!N     MOVE    R1, @CB_GIVEUP[R7]  ; giving up comes first
:
                MOVE    @CB_DUE[R7], R1
                RET
tarm_off
                AND     @CB_FLAGS[R7], R3, 0xFFFFFFFF-TF_ARM
                RET

; tcp_rst: a RST of the connection R7, with SND.NXT, and the ACK of
; RCV.NXT. Uses R1-R6.
tcp_rst
                MOVE    R2, @CB_NXT[R7]
                MOVE    R4, TH_RST+TH_ACK
                MOVE    R5, 0
; tcp_seg: a segment of the connection R7 sent by tcp_emit, from the
; sequence number R2, with the flags R4, TH_, and R5 bytes of the ring
; to send; with ACK, the acknowledgment RCV.NXT, which clears TF_ACK. The
; window is tcp_win's. Uses R1-R6.
tcp_seg
                PUSH    R2
                PUSH    R4
                PUSH    R5
                CALL    tcp_win
                POP     R5
                POP     R4
                POP     R2
                MOVE    R3, 0
                AND[M]  R0, R4, TH_ACK
        ?!Z     MOVE    R3, @CB_RNXT[R7]
        ?!Z     AND     @CB_FLAGS[R7], @CB_FLAGS[R7], 0xFFFFFFFF-TF_ACK
                SHL     R4, R4, 16
                OR      R4, R4, R1
                MOVE    R1, R7
                JMP     tcp_emit        ; which returns to the caller

; tcp_win: R1 = the window that the connection R7 announces, from
; RCV.NXT up to CB_EDGE, which moves to tcp_wcalc's edge only when that
; is at least its least move further on, against the silly window
; syndrome (RFC 9293 §3.8.6.2.2), and never moves left. Uses R1-R4.
tcp_win
                CALL    tcp_wcalc
                SUB     R3, R1, @CB_EDGE[R7]
                SUB[M]  R0, R3, R2
        ?!N     MOVE    @CB_EDGE[R7], R1
                SUB[M]  R1, @CB_EDGE[R7], @CB_RNXT[R7]
        ?N      MOVE    @CB_EDGE[R7], @CB_RNXT[R7]  ; bytes dropped after tcp_close passed it
        ?N      MOVE    R1, 0
                RET

; tcp_wcalc: R1 = the right edge of the window that the connection R7
; could announce: RCV.NXT, plus the free room of the ring received, at most
; its share of the budget, T_SHARE of the connections, and 65535; R2 =
; the least move of the edge, the smaller of half the ring and TCP_MSS.
; Uses R1-R4.
tcp_wcalc
                CALL    tcp_count
                MOVE    R2, @T_SHARE[R1]
                SUB     R1, @CB_RXSZ[R7], @CB_RXLEN[R7]
                CMP     R1, R2
        ?!C     MOVE    R1, R2
                CMP     R1, 0x10000
        ?!C     MOVE    R1, 0xFFFF
                ADD     R1, R1, @CB_RNXT[R7]
                SHR     R2, @CB_RXSZ[R7], 1
                CMP     R2, TCP_MSS
        ?!C     MOVE    R2, TCP_MSS
                RET

; tcp_count: R1 = the connections, the handles in SYN-SENT to
; SYN-RECEIVED, and not those in LISTEN.
; Uses R1-R3.
tcp_count
                MOVE    R1, 0
                MOVE    R2, V_TCB
:
                MOVE[M] R3, @R2++
        ?Z      JMP     :+
                MOVE    R3, @CB_STATE[R3]
                SUB     R3, R3, TS_SYNSENT
                CMP     R3, TS_SYNRCVD
        ?C      ADD     R1, R1, 1
:
                CMP     R2, V_TCB+TCP_HANDLES
        ?!Z     JMP     :--
                RET

; tcp_emit: a segment sent, to the block at R1, a control block or V_TCR,
; of which it reads the ports, the remote IP address, and the next hop's
; MAC address: from the sequence number R2, with the acknowledgment R3,
; the flags in bits 23..16 of R4 and the window in bits 15..0, and R5
; bytes of data from the ring to send of the control block R1, from the
; byte of the sequence number R2. A SYN has one option, the MSS, the
; smaller of TCP_MSS and the ring received. IPv4 from E_IP, with no
; options, TTL 64, DF clear, and the identification of ip_ident. The
; headers are built at V_TCH, then written with the data to the send
; buffer, after the frame before has gone, with the TCP checksum summed
; in R12 on the way. Uses R1-R6, and R7-R12 across the calls, saved: the
; block, the bytes, the words of the headers, the word written, the TCP
; length, and the sum.
tcp_emit
                PUSH    R7
                PUSH    R8
                PUSH    R9
                PUSH    R10
                PUSH    R11
                PUSH    R12
                MOVE    R7, R1
                MOVE    R8, R5
                MOVE    @V_TCH+10, R2
                MOVE    @V_TCH+11, R3
                MOVE    R9, 14
                MOVE    R10, 0x50000000  ; the data offset, 5 words
                AND[M]  R0, R4, TH_SYN*0x10000
        ?Z      JMP     :+
                MOVE    R9, 15
                MOVE    R10, 0x60000000
                MOVE    R1, @CB_RXSZ[R7]
                CMP     R1, TCP_MSS
        ?!C     MOVE    R1, TCP_MSS
                OR      @V_TCH+14, R1, 0x02040000  ; the MSS, kind 2, 4 bytes
:
                OR      @V_TCH+12, R4, R10
                MOVE    @V_TCH+13, 0
                MOVE    @V_TCH, @CB_MACH[R7]
                MOVE    @V_TCH+1, @CB_MACL[R7]
                SHL     R1, @E_MACH, 16
                SHR     R2, @E_MACL, 16
                OR      @V_TCH+2, R1, R2
                SHL     R1, @E_MACL, 16
                OR      @V_TCH+3, R1, 0x0800
                SUB     R11, R9, 9
                SHL     R11, R11, 2
                ADD     R11, R11, R8    ; the TCP length
                ADD     R1, R11, 20
                OR      @V_TCH+4, R1, 0x45000000  ; IPv4, a header of 5 words, and the length
                CALL    ip_ident
                MOVE    @V_TCH+5, R1
                MOVE    @V_TCH+6, 0x40060000  ; the TTL 64, TCP
                MOVE    @V_TCH+7, @E_IP
                MOVE    @V_TCH+8, @CB_RIP[R7]
                SHL     R1, @CB_LPORT[R7], 16
                OR      @V_TCH+9, R1, @CB_RPORT[R7]
                MOVE    R1, V_TCH
                CALL    ip_csum
                ADD     R12, R11, 6     ; the pseudo-header: the protocol, the length,
                MOVE    R10, 7          ; and the addresses, then the TCP header
:
                MOVE    R2, @V_TCH[R10]
                CALL    tcp_sum16
                ADD     R10, R10, 1
                CMP     R10, R9
        ?!Z     JMP     :-
:
                AND[M]  R0, @ETH_CSR, ETH_BUSY
        ?!Z     JMP     :-              ; as the send buffer takes no write while busy
                MOVE    R10, 0
:
                MOVE    R2, @V_TCH[R10]
                CALL    tx_word
                CMP     R10, R9
        ?!Z     JMP     :-
                TST     R8
        ?Z      JMP     temit_sum
; The data, 4 bytes to a word, from the ring: R3 the bytes left, R4 the
; ring's byte address, R5 the address of the next byte, and R6 the ring's
; end
                CALL    tcp_txb
                MOVE    R4, R1
                ADD     R6, R4, @CB_TXSZ[R7]
                SUB     R5, @V_TCH+10, @CB_SEQ0[R7]
                ADD     R5, R5, @CB_TXHEAD[R7]
                CMP     R5, @CB_TXSZ[R7]
        ?!C     SUB     R5, R5, @CB_TXSZ[R7]
                ADD     R5, R5, R4
                MOVE    R3, R8
temit_word
                MOVE    R2, 0
                MOVE    R11, 4
:
                SHL     R2, R2, 8
                TST     R3
        ?Z      JMP     :+
                OR      R2, R2, @R5++
                CMP     R5, R6
        ?Z      MOVE    R5, R4
                SUB     R3, R3, 1
:
                SUB[M]  R11, R11, 1
        ?!Z     JMP     :--
                CALL    tcp_sum16
                CALL    tx_word
                TST     R3
        ?!Z     JMP     temit_word
temit_sum
                CALL    tcp_fold
                XOR     R2, R12, 0xFFFF
                SHL     R2, R2, 16
                MOVE    @ETH_CHUNK, ETH_TXBUF+1
                MOVE    @ETH_BUF+5, R2  ; word 13, the checksum
                SHL     R1, R9, 2
                SUB     R1, R1, 2
                ADD     @ETH_TX_LEN, R1, R8
                POP     R12
                POP     R11
                POP     R10
                POP     R9
                POP     R8
                POP     R7
                RET

; tx_word: the word R2 written to word R10 of the send buffer, and R10 the
; next. Uses R1.
tx_word
                SHR     R1, R10, 3
                OR      @ETH_CHUNK, R1, ETH_TXBUF
                AND     R1, R10, 7
                MOVE    @ETH_BUF[R1], R2
                ADD     R10, R10, 1
                RET

; tcp_sum16: the two halves of R2 added to R12. Uses R1.
tcp_sum16
                SHR     R1, R2, 16
                ADD     R12, R12, R1
                AND     R1, R2, 0xFFFF
                ADD     R12, R12, R1
                RET

; tcp_fold: R12 folded to 16 bits, with the carries added back in. Uses
; R1.
tcp_fold
                SHR     R1, R12, 16
                AND     R12, R12, 0xFFFF
                ADD     R12, R12, R1
                SHR     R1, R12, 16
                AND     R12, R12, 0xFFFF
                ADD     R12, R12, R1
                RET

; tcp_input: for net_frames, the TCP segment of R1 bytes at the head of
; the queue, whose headers are at V_NHDR, taken in place, and left there
; for net_frames to release. A segment that is not to E_IP, is shorter
; than its lengths say, or has a bad checksum, is passed over. One that
; fits a connection, by its addresses and ports, goes to it, as RFC 9293
; §3.10.7 says for its state. A SYN without an ACK that fits none goes to
; the first handle in LISTEN on its port, and is passed over when the port
; has handles of tcp_listen, but none in LISTEN. Any other segment that
; fits none gets a RST, unless it is a RST (§3.10.7.1). R8 is the segment's flags, R9 its sequence number,
; R10 its bytes of data, R11 the window announced, and R12 the sequence
; number less RCV.NXT. Uses R1-R6, and R7-R12 across the calls, saved.
tcp_input
                PUSH    R7
                PUSH    R8
                PUSH    R9
                PUSH    R10
                PUSH    R11
                PUSH    R12
                TST     @E_IP
        ?Z      JMP     tin_end
                CMP     @V_NHDR+8, @E_IP
        ?!Z     JMP     tin_end         ; not ours
                AND     R11, @V_NHDR+4, 0xFFFF  ; the IP length
                ADD     R2, R11, 14
                CMP     R1, R2
        ?C      JMP     tin_end         ; a frame shorter than that
                SUB     R11, R11, 20    ; the TCP length
                SHR     R10, @V_NHDR+12, 28
                SHL     R10, R10, 2     ; the TCP header's bytes
                CMP     R10, 20
        ?C      JMP     tin_end
                CMP     R11, R10
        ?C      JMP     tin_end
                CALL    tcp_rxsum
        ?!Z     JMP     tin_end
                SHR     R1, R10, 2
                ADD     @V_SDATA, R1, 9  ; the word of the data
                SUB     R10, R11, R10   ; the bytes of data
                SHR     R8, @V_NHDR+12, 16
                AND     R8, R8, 0x1F    ; FIN, SYN, RST, PSH, and ACK
                MOVE    R9, @V_NHDR+10
                CALL    tcp_find
        ?Z      JMP     tin_none
                MOVE    R1, @CB_STATE[R7]
                CMP     R1, TS_SYNSENT
        ?Z      JMP     tin_synsent
                CMP     R1, TS_SYNRCVD
        ?Z      JMP     tin_synrcvd
; ESTABLISHED to LAST-ACK (RFC 9293 §3.10.7.4). A RST in the window ends
; the connection, or brings one in SYN-RECEIVED back to LISTEN. A segment
; with data is acceptable when it starts at RCV.NXT, and there is room, or
; after tcp_close, which drops its bytes; one without, when it starts in
; the window, or at RCV.NXT. Else it is answered with an ACK, and passed
; over.
tin_est
                SUB     R11, @CB_EDGE[R7], @CB_RNXT[R7]
                SUB     R12, R9, @CB_RNXT[R7]
                AND[M]  R0, R8, TH_RST
        ?Z      JMP     tin_acc
                MOVE    R1, R11
                CMP     R1, 1
        ?C      MOVE    R1, 1
                CMP     R12, R1
        ?!C     JMP     tin_end         ; outside the window
                MOVE    R1, E_TRESET
                CALL    tcp_fail
                JMP     tin_work
tin_acc
                TST     R10
        ?Z      JMP     :+
                TST     R12
        ?!Z     JMP     tin_unacc
                AND[M]  R0, @CB_FLAGS[R7], TF_FIN
        ?!Z     JMP     tin_ok          ; after tcp_close
                TST     R11
        ?Z      JMP     tin_unacc       ; no room
                JMP     tin_ok
:
                TST     R12
        ?Z      JMP     tin_ok
                CMP     R12, R11
        ?C      JMP     tin_ok
tin_unacc
                OR      @CB_FLAGS[R7], @CB_FLAGS[R7], TF_ACK
                JMP     tin_work
tin_ok
                AND[M]  R0, R8, TH_SYN
        ?!Z     JMP     tin_unacc       ; a SYN: an ACK, and passed over
                AND[M]  R0, R8, TH_ACK
        ?Z      JMP     tin_end
; The ACK: of what was not sent, answered with an ACK and passed over; of
; new data, taken by tcp_acked; with the window taken, unless it is older
; than SND.UNA. A window of 0 is an answer to the probes, so their sends
; do not give up.
                MOVE    R1, @V_NHDR+11
                SUB[M]  R0, R1, @CB_MAX[R7]
        ?N      JMP     :+
        ?!Z     JMP     tin_unacc
:
                SUB[M]  R2, R1, @CB_UNA[R7]
        ?N      JMP     tin_data        ; an old one
                AND[M]  @CB_WND[R7], @V_NHDR+12, 0xFFFF
        ?Z      AND     @CB_FLAGS[R7], @CB_FLAGS[R7], 0xFFFFFFFF-TF_GIVEUP
                TST     R2
        ?Z      JMP     tin_data
                CALL    tcp_acked
                TST     @CB_CHECK[R7]
        ?Z      JMP     tin_work        ; freed
; The data: in ESTABLISHED, as much as the window holds, into the ring;
; after tcp_close, all of it, dropped; after the peer's FIN, none
tin_data
                TST     R10
        ?Z      JMP     tin_fin
                OR      @CB_FLAGS[R7], @CB_FLAGS[R7], TF_ACK
                AND[M]  R0, @CB_FLAGS[R7], TF_FIN
        ?!Z     JMP     :+
                CMP     @CB_STATE[R7], TS_ESTAB
        ?!Z     JMP     tin_work
                MOVE    R12, R10
                CMP     R12, R11
        ?!C     MOVE    R12, R11
                CALL    tcp_take
                ADD     @CB_RXLEN[R7], @CB_RXLEN[R7], R12
                ADD     @CB_RNXT[R7], @CB_RNXT[R7], R12
                JMP     tin_fin
:
                ADD     @CB_RNXT[R7], @CB_RNXT[R7], R10
; The FIN, once every byte before it is taken, in ESTABLISHED,
; FIN-WAIT-1, and FIN-WAIT-2, which ends with the ACK sent at once, and the
; handle freed
tin_fin
                AND[M]  R0, R8, TH_FIN
        ?Z      JMP     tin_work
                ADD     R1, R9, R10
                CMP     R1, @CB_RNXT[R7]
        ?!Z     JMP     tin_work        ; not every byte taken
                MOVE    R1, @CB_STATE[R7]
                MOVE    R2, TS_CWAIT
                CMP     R1, TS_ESTAB
        ?Z      JMP     :+
                MOVE    R2, TS_CLOSING
                CMP     R1, TS_FINW1
        ?Z      JMP     :+
                CMP     R1, TS_FINW2
        ?!Z     JMP     tin_work
                ADD     @CB_RNXT[R7], @CB_RNXT[R7], 1
                MOVE    R2, @CB_NXT[R7]
                MOVE    R4, TH_ACK
                MOVE    R5, 0
                CALL    tcp_seg
                CALL    tcp_drop
                JMP     tin_work
:
                MOVE    @CB_STATE[R7], R2
                ADD     @CB_RNXT[R7], @CB_RNXT[R7], 1
                OR      @CB_FLAGS[R7], @CB_FLAGS[R7], TF_ACK
                JMP     tin_work
; SYN-SENT (RFC 9293 §3.10.7.3): an ACK of anything but our SYN gets a RST
; with its number, unless it is a RST; a RST with the ACK of our SYN
; ends the connection in E_TREFUSED, and one without it is passed over;
; a SYN with the ACK opens the connection; anything else is passed over.
tin_synsent
                AND[M]  R0, R8, TH_ACK
        ?Z      JMP     tin_noack
                ADD     R1, @CB_UNA[R7], 1
                CMP     @V_NHDR+11, R1
        ?Z      JMP     tin_noack
                AND[M]  R0, R8, TH_RST
        ?!Z     JMP     tin_end
tin_ackrst
                MOVE    R1, R7
                MOVE    R2, @V_NHDR+11
                MOVE    R3, 0
                MOVE    R4, TH_RST*0x10000
                MOVE    R5, 0
                CALL    tcp_emit
                JMP     tin_end
tin_noack
                AND[M]  R0, R8, TH_RST
        ?Z      JMP     :+
                AND[M]  R0, R8, TH_ACK
        ?Z      JMP     tin_end         ; a RST without the ACK of our SYN
                MOVE    R1, E_TREFUSED
                CALL    tcp_fail
                JMP     tin_work
:
                AND     R1, R8, TH_SYN+TH_ACK
                CMP     R1, TH_SYN+TH_ACK
        ?!Z     JMP     tin_end         ; a SYN alone, or no SYN
                ADD     R1, R9, 1
                MOVE    @CB_RNXT[R7], R1
                MOVE    @CB_EDGE[R7], R1
                CALL    tcp_optmss
                MOVE    @CB_MSS[R7], R1
                AND     @CB_WND[R7], @V_NHDR+12, 0xFFFF
                MOVE    R1, @V_NHDR+11
                CALL    tcp_acked
                SHL     @CB_CWND[R7], @CB_MSS[R7], 1
                MOVE    @CB_STATE[R7], TS_ESTAB
                OR      @CB_FLAGS[R7], @CB_FLAGS[R7], TF_ACK
                JMP     tin_work
; SYN-RECEIVED (RFC 9293 §3.10.7.4): a RST goes to tin_est, which takes
; one in the window; the SYN again, with the same sequence number, gets
; the SYN-ACK again, and any other SYN is passed over; the ACK of our SYN
; opens the connection, and its data and FIN go on in tin_est; any other
; ACK gets a RST with its number; a segment without an ACK is passed over.
tin_synrcvd
                AND[M]  R0, R8, TH_RST
        ?!Z     JMP     tin_est
                AND[M]  R0, R8, TH_SYN
        ?Z      JMP     :+
                ADD     R1, R9, 1
                CMP     R1, @CB_RNXT[R7]
        ?!Z     JMP     tin_end
                MOVE    @CB_NXT[R7], @CB_UNA[R7]  ; for tcp_out, from tcp_work
                JMP     tin_work
:
                AND[M]  R0, R8, TH_ACK
        ?Z      JMP     tin_end
                ADD     R1, @CB_UNA[R7], 1
                CMP     @V_NHDR+11, R1
        ?!Z     JMP     tin_ackrst
                MOVE    @CB_STATE[R7], TS_ESTAB
                CALL    tcp_acked
                SHL     @CB_CWND[R7], @CB_MSS[R7], 1
                JMP     tin_est
; A segment that fits no connection. A SYN without an ACK goes to the
; first handle in LISTEN on its port, tin_listen, or is passed over when
; the port has handles of tcp_listen, but none in LISTEN. Any other gets a
; RST, unless it is one, to the source of the frame, unless that is 0,
; ours, a broadcast, or multicast. With an ACK, the RST has its number;
; else the ACK of the segment.
tin_none
                AND     R1, R8, TH_SYN+TH_ACK+TH_RST
                CMP     R1, TH_SYN
        ?!Z     JMP     tin_rst
                AND     R5, @V_NHDR+9, 0xFFFF
                CALL    tcp_lfind
        ?!Z     JMP     tin_listen
                TST     R6
        ?!Z     JMP     tin_end         ; every handle of the port busy
tin_rst
                AND[M]  R0, R8, TH_RST
        ?!Z     JMP     tin_end
                MOVE    R1, V_TCR
                CALL    tcp_peer
        ?Z      JMP     tin_end
                AND[M]  R0, R8, TH_ACK
        ?Z      JMP     :+
                MOVE    R2, @V_NHDR+11
                MOVE    R3, 0
                MOVE    R4, TH_RST*0x10000
                JMP     :++
:
                ADD     R3, R9, R10
                AND[M]  R0, R8, TH_SYN
        ?!Z     ADD     R3, R3, 1
                AND[M]  R0, R8, TH_FIN
        ?!Z     ADD     R3, R3, 1
                MOVE    R2, 0
                MOVE    R4, TH_RST*0x10000+TH_ACK*0x10000
:
                MOVE    R1, V_TCR
                MOVE    R5, 0
                CALL    tcp_emit
                JMP     tin_end
; LISTEN (RFC 9293 §3.10.7.2): the SYN taken by the handle R7, with the
; peer's address, port, and MAC address, so no ARP, its MSS and window,
; and RCV.NXT past its SYN; its data, if any, is not taken. SYN-RECEIVED
; then, and tcp_work sends the SYN-ACK, which goes for TCP_SYNTIME.
tin_listen
                MOVE    R1, R7
                CALL    tcp_peer
        ?Z      JMP     tin_end
                CALL    tcp_isn
                ADD     R1, R9, 1
                MOVE    @CB_RNXT[R7], R1
                MOVE    @CB_EDGE[R7], R1
                CALL    tcp_optmss
                MOVE    @CB_MSS[R7], R1
                SHL     @CB_CWND[R7], R1, 1
                AND     @CB_WND[R7], @V_NHDR+12, 0xFFFF
                MOVE    @CB_STATE[R7], TS_SYNRCVD
                CALL    net_clock
                ADD     @CB_GIVEUP[R7], R1, TCP_SYNTIME
                MOVE    @CB_FLAGS[R7], TF_PASSIVE+TF_GIVEUP
tin_work
                MOVE    @V_TCWORK, 1
tin_end
                POP     R12
                POP     R11
                POP     R10
                POP     R9
                POP     R8
                POP     R7
                RET

; tcp_rxsum: Z set when the TCP checksum of the segment at the head of the
; queue, of R11 bytes from word 9, is right, with the pseudo-header of its
; IP header at V_NHDR. Uses R1-R4, and R12.
tcp_rxsum
                ADD     R12, R11, 6
                MOVE    R2, @V_NHDR+7
                CALL    tcp_sum16
                MOVE    R2, @V_NHDR+8
                CALL    tcp_sum16
                MOVE    R3, 9           ; the word
                MOVE    R4, R11         ; the bytes left
:
                SHR     R1, R3, 3
                MOVE    @ETH_CHUNK, R1
                AND     R1, R3, 7
                MOVE    R2, @ETH_BUF[R1]
                ADD     R3, R3, 1
                CMP     R4, 4
        ?!C     JMP     :+
                SUB     R1, 4, R4       ; the last word, its bytes past the segment left out
                SHL     R1, R1, 3
                SHL     R1, 0xFFFFFFFF, R1
                AND     R2, R2, R1
                MOVE    R4, 4
:
                CALL    tcp_sum16
                SUB[M]  R4, R4, 4
        ?!Z     JMP     :--
                CALL    tcp_fold
                CMP     R12, 0xFFFF
                RET

; tcp_find: R7 = the control block of the connection, in SYN-SENT to
; SYN-RECEIVED, that the segment at V_NHDR fits by its source's address and
; port and its destination port, with Z clear, or 0, with Z set. Uses
; R1-R6.
tcp_find
                SHR     R4, @V_NHDR+9, 16  ; the source port
                AND     R5, @V_NHDR+9, 0xFFFF  ; the destination port
                MOVE    R6, @V_NHDR+7   ; the source's address
                MOVE    R2, V_TCB
tfind_next
                MOVE[M] R7, @R2++
        ?Z      JMP     tfind_skip
                MOVE    R1, @CB_STATE[R7]
                SUB     R1, R1, TS_SYNSENT
                CMP     R1, TS_SYNRCVD
        ?!C     JMP     tfind_skip
                CMP     @CB_LPORT[R7], R5
        ?!Z     JMP     tfind_skip
                CMP     @CB_RPORT[R7], R4
        ?!Z     JMP     tfind_skip
                CMP     @CB_RIP[R7], R6
        ?!Z     JMP     tfind_skip
                MOVE[M] R7, R7
                RET
tfind_skip
                CMP     R2, V_TCB+TCP_HANDLES
        ?!Z     JMP     tfind_next
                MOVE[M] R7, R0
                RET

; tcp_lfind: R7 = the first handle in LISTEN on the port R5, with Z
; clear; or 0, with Z set, and R6 not 0 when the port has handles of
; tcp_listen in other states. Uses R2, R6, and R7.
tcp_lfind
                MOVE    R6, 0
                MOVE    R2, V_TCB
tlfind_next
                MOVE[M] R7, @R2++
        ?Z      JMP     tlfind_skip
                AND[M]  R0, @CB_FLAGS[R7], TF_PASSIVE
        ?Z      JMP     tlfind_skip
                CMP     @CB_LPORT[R7], R5
        ?!Z     JMP     tlfind_skip
                MOVE    R6, 1
                CMP     @CB_STATE[R7], TS_LISTEN
        ?!Z     JMP     tlfind_skip
                MOVE[M] R7, R7
                RET
tlfind_skip
                CMP     R2, V_TCB+TCP_HANDLES
        ?!Z     JMP     tlfind_next
                MOVE[M] R7, R0
                RET

; tcp_peer: the block R1, a control block or V_TCR, given the peer of the
; segment at V_NHDR: its address, its port, the local port, and the MAC
; address of the frame's source, with Z clear; or with Z set, and nothing
; written, when the source address is 0, ours, a broadcast, or multicast.
; Uses R1-R3.
tcp_peer
                MOVE    R2, @V_NHDR+7
                ADD     R3, R2, 1
                CMP     R3, 2
        ?C      JMP     tpeer_no        ; 0 or 255.255.255.255
                SHR     R3, R2, 28
                CMP     R3, 14
        ?!C     JMP     tpeer_no        ; 224.0.0.0 and up
                CMP     R2, @E_IP
        ?Z      RET                     ; ours, with Z set
                MOVE    @CB_RIP[R1], R2
                SHR     @CB_RPORT[R1], @V_NHDR+9, 16
                AND     @CB_LPORT[R1], @V_NHDR+9, 0xFFFF
                SHR     @CB_MACH[R1], @V_NHDR+2, 16
                SHL     R2, @V_NHDR+2, 16
                SHR     R3, @V_NHDR+3, 16
                OR      @CB_MACL[R1], R2, R3
                MOVE[M] R1, R1          ; not 0, with Z clear
                RET
tpeer_no
                MOVE[M] R1, R0
                RET

; tcp_acked: the ACK R1 of new data, up to CB_MAX, taken by the connection
; R7: the bytes it acknowledges leave the ring, SND.UNA moves to it, and
; SND.NXT with it if it was behind; the segment timed gives its round
; trip, if the ACK covers it; the deadline starts again, and the sends no
; longer give up; the congestion window grows by one segment, up to the
; larger of the peer's window and its MSS (RFC 5681). The ACK of our FIN
; takes FIN-WAIT-1 to FIN-WAIT-2, whose deadline is TCP_FW2TIME away, and
; frees the handle in CLOSING and LAST-ACK. Uses R1-R6.
tcp_acked
                MOVE    R6, R1
                SUB[M]  R2, R6, @CB_SEQ0[R7]
        ?N      JMP     tack_una
        ?Z      JMP     tack_una        ; only the SYN
                CMP     R2, @CB_TXLEN[R7]
        ?!C     MOVE    R2, @CB_TXLEN[R7]
                ADD     @CB_SEQ0[R7], @CB_SEQ0[R7], R2
                SUB     @CB_TXLEN[R7], @CB_TXLEN[R7], R2
                ADD     R3, @CB_TXHEAD[R7], R2
                CMP     R3, @CB_TXSZ[R7]
        ?!C     SUB     R3, R3, @CB_TXSZ[R7]
                MOVE    @CB_TXHEAD[R7], R3
tack_una
                MOVE    @CB_UNA[R7], R6
                SUB[M]  R0, @CB_NXT[R7], R6
        ?N      MOVE    @CB_NXT[R7], R6
                AND[M]  R0, @CB_FLAGS[R7], TF_RTT
        ?Z      JMP     :+
                SUB[M]  R0, R6, @CB_RTTSEQ[R7]
        ?N      JMP     :+
        ?Z      JMP     :+
                AND     @CB_FLAGS[R7], @CB_FLAGS[R7], 0xFFFFFFFF-TF_RTT
                CALL    net_clock
                SUB     R1, R1, @CB_RTTT[R7]
                CALL    tcp_rtt
:
                AND     @CB_FLAGS[R7], @CB_FLAGS[R7], 0xFFFFFFFF-TF_ARM-TF_GIVEUP
                ADD     R1, @CB_CWND[R7], @CB_MSS[R7]
                MOVE    R2, @CB_WND[R7]
                CMP     R2, @CB_MSS[R7]
        ?C      MOVE    R2, @CB_MSS[R7]
                CMP     R1, R2
        ?!C     MOVE    R1, R2
                MOVE    @CB_CWND[R7], R1
                AND[M]  R0, @CB_FLAGS[R7], TF_FIN
        ?Z      RET
                SUB     R1, R6, @CB_SEQ0[R7]
                CMP     R1, 1
        ?!Z     RET                     ; not the FIN's
                CMP     @CB_STATE[R7], TS_FINW1
        ?!Z     JMP     tcp_drop        ; CLOSING or LAST-ACK, which returns to the caller
                MOVE    @CB_STATE[R7], TS_FINW2
                OR      @CB_FLAGS[R7], @CB_FLAGS[R7], TF_FW2
                CALL    net_clock
                ADD     @CB_DUE[R7], R1, TCP_FW2TIME
                RET

; tcp_rtt: the round trip R1, in microseconds, measured on the
; connection R7, taken into its timeout as RFC 6298 says, with shifts:
; the first gives SRTT R and RTTVAR R/2, each next one moves SRTT by 1/8
; and RTTVAR by 1/4 of their differences, and the timeout is SRTT plus
; 4 RTTVAR, from TCP_RTOMIN to TCP_RTOMAX. Uses R1-R4.
tcp_rtt
                MOVE[M] R2, @CB_SRTT[R7]
        ?!Z     JMP     :+
                MOVE    @CB_SRTT[R7], R1
                SHR     @CB_RTTVAR[R7], R1, 1
                JMP     :++
:
                SUB     R3, R1, R2      ; the difference
                C<0[M]  R0, R3, 1
                C>0     R4, R3, 3       ; an eighth, with its sign
                ADD     @CB_SRTT[R7], R2, R4
                TST     R3
        ?N      SUB     R3, R0, R3
                SUB     R3, R3, @CB_RTTVAR[R7]
                C<0[M]  R0, R3, 1
                C>0     R3, R3, 2       ; a quarter, with its sign
                ADD     @CB_RTTVAR[R7], @CB_RTTVAR[R7], R3
:
                SHL     R1, @CB_RTTVAR[R7], 2
                ADD     R1, R1, @CB_SRTT[R7]
                CMP     R1, TCP_RTOMIN
        ?C      MOVE    R1, TCP_RTOMIN
                CMP     R1, TCP_RTOMAX
        ?!C     MOVE    R1, TCP_RTOMAX
                MOVE    @CB_RTO[R7], R1
                RET

; tcp_take: R12 bytes of the segment's data, from word V_SDATA of the
; queue's buffer, copied to the end of the ring received of R7: R3 the
; word, R4 the ring's byte address, R5 the address of the next byte, R6
; the ring's end, and R11 the bytes left. Uses R1-R6, and R11.
tcp_take
                MOVE[M] R11, R12
        ?Z      RET
                MOVE    R4, @CB_RXB[R7]
                ADD     R6, R4, @CB_RXSZ[R7]
                ADD     R5, @CB_RXHEAD[R7], @CB_RXLEN[R7]
                CMP     R5, @CB_RXSZ[R7]
        ?!C     SUB     R5, R5, @CB_RXSZ[R7]
                ADD     R5, R5, R4
                MOVE    R3, @V_SDATA
ttake_word
                SHR     R1, R3, 3
                MOVE    @ETH_CHUNK, R1
                AND     R1, R3, 7
                MOVE    R2, @ETH_BUF[R1]
                ADD     R3, R3, 1
                MOVE    R1, 4
:
                ROL     R2, R2, 8       ; the next byte, big-endian, to bits 7..0
                MOVE    @R5++, R2       ; which the byte window writes
                CMP     R5, R6
        ?Z      MOVE    R5, R4
                SUB[M]  R11, R11, 1
        ?Z      RET
                SUB[M]  R1, R1, 1
        ?!Z     JMP     :-
                JMP     ttake_word

; tcp_optmss: R1 = the MSS of the option of the segment at the head of the
; queue, TCP_MSS0 without one, and TCP_MSS at most. The options are walked
; from byte 56 of the buffer, R4, up to the end of the header, R5. Uses
; R1-R6.
tcp_optmss
                MOVE    R6, TCP_MSS0
                SHR     R5, @V_NHDR+12, 28
                SHL     R5, R5, 2
                ADD     R5, R5, 36
                MOVE    R4, 56
topt_next
                CMP     R4, R5
        ?!C     JMP     topt_end
                MOVE    R1, R4
                CALL    q_byte
                TST     R1
        ?Z      JMP     topt_end        ; the end of the options
                CMP     R1, 1
        ?Z      ADD     R4, R4, 1       ; a NOP
        ?Z      JMP     topt_next
                MOVE    R3, R1          ; the kind
                ADD     R1, R4, 1
                CALL    q_byte          ; the length
                CMP     R1, 2
        ?C      JMP     topt_end
                CMP     R3, 2
        ?!Z     JMP     :+
                CMP     R1, 4
        ?!Z     JMP     :+
                ADD     R1, R4, 2
                CALL    q_byte
                SHL     R6, R1, 8
                ADD     R1, R4, 3
                CALL    q_byte
                OR      R6, R6, R1
                MOVE    R1, 4
:
                ADD     R4, R4, R1
                JMP     topt_next
topt_end
                CMP     R6, TCP_MSS
        ?!C     MOVE    R6, TCP_MSS
                TST     R6
        ?Z      MOVE    R6, TCP_MSS0
                MOVE    R1, R6
                RET

; q_byte: R1 = the byte at R1 of the queue's buffer, counted from its
; start, 2 bytes before the frame. Uses R1 and R2.
q_byte
                SHR     R2, R1, 5
                MOVE    @ETH_CHUNK, R2
                SHR     R2, R1, 2
                AND     R2, R2, 7
                MOVE    R2, @ETH_BUF[R2]
                AND     R1, R1, 3
                XOR     R1, R1, 3
                SHL     R1, R1, 3
                SHR     R1, R2, R1
                AND     R1, R1, 0xFF
                RET

; The states of tcp_state, by the states of a block, and the share of the
; window budget, 4096 bytes, of each connection, by their number
T_TCPST         .DAT    0, 1, 2, 3, 4, 4, 4, 4, 1, 5
T_SHARE         .DAT    4096, 4096, 2048, 1365, 1024
