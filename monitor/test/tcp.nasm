; The test of TCP, the entries 26 to 31 (issue #111), which
; tools/tcptest.py runs under the monitor of the tests in niceemu with
; --eth-udp, against tools/tcppeer.py, the host 10.0.0.2. The Makefile
; assembles it after the monitor's sources, as for dns.nasm, so that it
; reaches the monitor's names. Each case connects to a port of its own,
; whose Script in tcptest.py decides what the peer does, and stores its
; results from TT_RES on, which tcptest.py dumps and checks, with what the
; peer saw. In the cases of tcp_listen, from R on, the peer connects to
; the board, when a datagram from the program says which case listens.

                .ORG    0x8000
TT_RES          .EQU    0x9100          ; the results, a word each
TT_CB0          .EQU    0xA000          ; the control blocks, 4096 words apart
TT_CB1          .EQU    0xB000
TT_CB2          .EQU    0xC000
TT_CB3          .EQU    0xD000
TT_CB4          .EQU    0xE000
TT_TX           .EQU    0x10000         ; the bytes to send, packed
TT_RX           .EQU    0x14000         ; the bytes received, packed
TT_TXB          .EQU    0x20000000+4*TT_TX
TT_RXB          .EQU    0x20000000+4*TT_RX
TT_PEER         .EQU    0x0A000002      ; tcppeer.py's address
TT_SEC          .EQU    1000000
TT_SIG          .EQU    7000            ; the UDP port of the signals, the program's and the peer's
TT_SIGW         .EQU    0x9000          ; the word of a signal's byte

tt_main
                MOVE    R7, TT_RES
; The errors before a connection: no IP address, E_NOIP, of tcp_open and
; tcp_listen; then, with
; 10.0.0.9 set, the ports 0 and 65536, E_PORT; a ring of 63 bytes to
; receive, and to send, a block at a word-window address that is not
; aligned, and one below 0x8000, E_TSIZE; an address that answers no
; ARP, after 3 seconds, and 255.255.255.255, E_NOROUTE; and the handles
; 4 and -1, a free one, and the entries with a handle, E_THANDLE.
                MOVE    R1, TT_CB0
                MOVE    R2, 2001
                MOVE    R3, 0x04000400
                CALL    tt_open
                MOVE    R1, TT_CB0
                MOVE    R2, 3000
                MOVE    R3, 0x04000400
                CALL    _tcp_listen
                MOVE    @R7++, R1       ; E_NOIP
                MOVE    R1, TT_SET
                CALL    _net_set
                MOVE    R8, TT_BAD
:
                MOVE[M] R1, @R8++
        ?Z      JMP     :+
                MOVE    R2, @R8++
                MOVE    R3, @R8++
                MOVE    R4, @R8++
                CALL    _tcp_open
                MOVE    @R7++, R1
                JMP     :-
:
                MOVE    R1, 4
                CALL    _tcp_state
                MOVE    @R7++, R1       ; E_THANDLE
                MOVE    R1, -1
                CALL    _tcp_state
                MOVE    @R7++, R1       ; E_THANDLE
                MOVE    R1, 0
                CALL    _tcp_state
                MOVE    @R7++, R1       ; 0, TCP_FREE
                MOVE    R1, 0
                MOVE    R2, TT_TXB
                MOVE    R3, 1
                CALL    _tcp_send
                MOVE    @R7++, R1       ; E_THANDLE
                MOVE    R1, 1
                MOVE    R2, TT_RXB
                MOVE    R3, 1
                CALL    _tcp_recv
                MOVE    @R7++, R1       ; E_THANDLE
                MOVE    R1, 3
                MOVE    R2, 0
                CALL    _tcp_close
                MOVE    @R7++, R1       ; E_THANDLE
; Case N, port 2014: a connection opened alone, with a ring of 4096 bytes
; to receive, so a window of 4096, which stays open, idle, across the
; wrap of the fine clock, 4 seconds after the start, until case P. Its
; handle is 0 throughout.
                MOVE    R1, TT_CB4
                MOVE    R2, 2014
                MOVE    R3, 0x10000400
                CALL    tt_open
                MOVE    R1, 0
                MOVE    R2, 2
                CALL    tt_wait
                MOVE    @R7++, R1       ; 2
; Case A, port 2001, the echo: the control block at a word-window
; address; 3000 bytes echoed, through rings of 1024; a close, then
; tcp_recv and tcp_send give E_TCLOSED, and the handle frees itself
                MOVE    R1, 3000
                MOVE    R2, 0
                MOVE    R3, 7
                CALL    tt_fill
                MOVE    R1, 0x10000000+4*TT_CB0
                MOVE    R2, 2001
                MOVE    R3, 0x04000400
                CALL    tt_open
                MOVE    R1, 3000
                MOVE    R2, 3000
                CALL    tt_echo
                MOVE    R1, R8
                MOVE    R2, 0
                CALL    _tcp_close
                MOVE    @R7++, R1       ; 0
                MOVE    R1, R8
                CALL    _tcp_state
                MOVE    @R7++, R1       ; 4, TCP_CLOSING
                MOVE    R1, R8
                MOVE    R2, TT_RXB
                MOVE    R3, 10
                CALL    _tcp_recv
                MOVE    @R7++, R1       ; E_TCLOSED
                MOVE    R1, R8
                MOVE    R2, TT_TXB
                MOVE    R3, 10
                CALL    _tcp_send
                MOVE    @R7++, R1       ; E_TCLOSED
                CALL    tt_free
; Case B, port 2002, the peer closes first: 3 bytes sent; the peer's 700
; and its FIN read to E_TEOF; TCP_PEER_CLOSED; 100 bytes sent after it,
; and the close
                MOVE    R1, TT_CB0
                MOVE    R2, 2002
                MOVE    R3, 0x02000100
                CALL    tt_open
                CALL    tt_waitopen
                MOVE    R1, 100
                MOVE    R2, 5
                MOVE    R3, 3
                CALL    tt_fill
                MOVE    R1, 3
                MOVE    R2, 4000
                CALL    tt_echo
                MOVE    @R7++, R3       ; E_TEOF
                MOVE    R1, R8
                CALL    _tcp_state
                MOVE    @R7++, R1       ; 3, TCP_PEER_CLOSED
                MOVE    R1, R8
                MOVE    R2, 100
                CALL    tt_sendall
                MOVE    @R7++, R1       ; 100
                CALL    tt_close
; Case C, port 2003: the peer refuses, E_TREFUSED
                MOVE    R1, TT_CB0
                MOVE    R2, 2003
                MOVE    R3, 0x04000400
                CALL    tt_open
                MOVE    R1, R8
                MOVE    R2, 99
                CALL    tt_wait
                MOVE    @R7++, R1       ; E_TREFUSED
                CALL    tt_close
; Case D, port 2004: 10 bytes, and the peer's 50 and a RST: E_TRESET from
; tcp_state, tcp_recv, and tcp_send
                MOVE    R1, TT_CB0
                MOVE    R2, 2004
                MOVE    R3, 0x04000400
                CALL    tt_open
                CALL    tt_waitopen
                MOVE    R1, R8
                MOVE    R2, 10
                CALL    tt_sendall
                MOVE    R1, R8
                MOVE    R2, 99
                CALL    tt_wait
                MOVE    @R7++, R1       ; E_TRESET
                MOVE    R1, R8
                MOVE    R2, TT_RXB
                MOVE    R3, 10
                CALL    _tcp_recv
                MOVE    @R7++, R1       ; E_TRESET
                MOVE    R1, R8
                MOVE    R2, TT_TXB
                MOVE    R3, 10
                CALL    _tcp_send
                MOVE    @R7++, R1       ; E_TRESET
                CALL    tt_close
; Case E, port 2005: the peer's 100 bytes and its FIN at the open, while
; 2000 go the other way
                MOVE    R1, 2000
                MOVE    R2, 9
                MOVE    R3, 11
                CALL    tt_fill
                MOVE    R1, TT_CB0
                MOVE    R2, 2005
                MOVE    R3, 0x04000800
                CALL    tt_open
                CALL    tt_waitopen
                MOVE    R1, 2000
                MOVE    R2, 4000
                CALL    tt_echo
                MOVE    @R7++, R3       ; E_TEOF
                CALL    tt_close
; Case F, port 2006, in TCP_CONNECTING: the peer answers the SYN with a
; RST without an ACK and a SYN without one, both passed over, and an ACK
; of an old connection, which gets a RST; the next SYN, a second later,
; opens. The tenths of a second to the open, then an abort, which frees
; the handle at once
                MOVE    R9, @io.us
                MOVE    R1, TT_CB0
                MOVE    R2, 2006
                MOVE    R3, 0x04000400
                CALL    tt_open
                CALL    tt_waitopen
                SUB     R1, @io.us, R9
                MOVE    R2, 100000
                CALL    tt_div
                MOVE    @R7++, R1       ; about 10
                MOVE    R1, R8
                MOVE    R2, 1
                CALL    _tcp_close
                MOVE    @R7++, R1       ; 0
                MOVE    R1, R8
                CALL    _tcp_state
                MOVE    @R7++, R1       ; 0, TCP_FREE
; Case G, port 2007: a close with the peer's 500 bytes not read, which
; drops them; the peer's 300 after our FIN, ACKed and dropped, then its
; FIN
                MOVE    R1, TT_CB0
                MOVE    R2, 2007
                MOVE    R3, 0x04000400
                CALL    tt_open
                CALL    tt_waitopen
                MOVE    R1, 300000
                CALL    tt_sleep
                MOVE    R1, R8
                MOVE    R2, 0
                CALL    _tcp_close
                MOVE    @R7++, R1       ; 0
                MOVE    R1, R8
                MOVE    R2, TT_RXB
                MOVE    R3, 10
                CALL    _tcp_recv
                MOVE    @R7++, R1       ; E_TCLOSED
                CALL    tt_free
; Case H, port 2008: an abort during a close, whose FIN the peer never
; takes
                MOVE    R1, TT_CB0
                MOVE    R2, 2008
                MOVE    R3, 0x04000400
                CALL    tt_open
                CALL    tt_waitopen
                MOVE    R1, R8
                MOVE    R2, 0
                CALL    _tcp_close
                MOVE    R1, 200000
                CALL    tt_sleep
                MOVE    R1, R8
                CALL    _tcp_state
                MOVE    @R7++, R1       ; 4, TCP_CLOSING
                MOVE    R1, R8
                MOVE    R2, 1
                CALL    _tcp_close
                MOVE    @R7++, R1       ; 0
                MOVE    R1, R8
                CALL    _tcp_state
                MOVE    @R7++, R1       ; 0
; Cases I, J, and K, ports 2009 to 2011: 2000 bytes sent to a peer with
; no MSS option, to one with an MSS of 100 and a window of 300, and to one
; whose window is 0 for a while, which the board probes
                MOVE    R1, 2000
                MOVE    R2, 1
                MOVE    R3, 13
                CALL    tt_fill
                MOVE    R9, 2009
:
                MOVE    R1, TT_CB0
                MOVE    R2, R9
                MOVE    R3, 0x04000800
                CALL    tt_open
                CALL    tt_waitopen
                MOVE    R1, R8
                MOVE    R2, 2000
                CALL    tt_sendall
                MOVE    @R7++, R1       ; 2000
                CALL    tt_close
                ADD     R9, R9, 1
                CMP     R9, 2012
        ?!Z     JMP     :-
; Case L, port 2012: a ring of 256 bytes, which the peer fills: its zero
; window, the peer's probe and keepalive answered, its pure ACK not; then
; the program reads the 1000 bytes, and the window opens
                MOVE    R1, TT_CB0
                MOVE    R2, 2012
                MOVE    R3, 0x01000100
                CALL    tt_open
                CALL    tt_waitopen
                MOVE    R1, 2*TT_SEC
                CALL    tt_sleep
                MOVE    R1, 0
                MOVE    R2, 1000
                CALL    tt_echo
                CALL    tt_close
; Case M, port 2013: 3000 bytes from the peer out of order, duplicated,
; dropped, with a bad checksum, among broadcasts, and in a burst of 20
; that the queue cannot hold, which ETH_DROPPED counts
                MOVE    R1, TT_CB0
                MOVE    R2, 2013
                MOVE    R3, 0x10000100
                CALL    tt_open
                CALL    tt_waitopen
                MOVE    R1, 0
                MOVE    R2, 3000
                CALL    tt_echo
                MOVE    @R7++, @ETH_CSR+4  ; ETH_DROPPED, not 0
                CALL    tt_close
; Case O, port 2015: with N open, three more, four in all, and a fifth,
; E_TFULL; then the three closed
                MOVE    R9, 0
:
                MOVE    R1, @TT_CBS[R9]
                MOVE    R2, 2015
                MOVE    R3, 0x01000100
                CALL    tt_open
                CALL    tt_waitopen
                ADD     R9, R9, 1
                CMP     R9, 3
        ?!Z     JMP     :-
                MOVE    R1, TT_CB3
                MOVE    R2, 2015
                MOVE    R3, 0x01000100
                CALL    tt_open         ; E_TFULL
                MOVE    R8, 1
:
                CALL    tt_close
                ADD     R8, R8, 1
                CMP     R8, 4
        ?!Z     JMP     :-
; Case P, port 2016, the window budget: with N, a second connection, whose
; window is half the budget; a byte on N, whose answer, 4096 bytes, uses
; N's window from before; N's window then shrinks to its half, as the
; program reads them. Then P closed
                MOVE    R1, TT_CB0
                MOVE    R2, 2016
                MOVE    R3, 0x10000100
                CALL    tt_open
                CALL    tt_waitopen
                MOVE    R10, R8
                MOVE    R8, 0           ; N
                MOVE    R1, @io.us
                MOVE    @R7++, R1       ; the microseconds since the start, past 4 seconds
                MOVE    R1, 1
                MOVE    R2, 4096
                CALL    tt_echo
                MOVE    R1, 200000
                CALL    tt_sleep
                MOVE    R8, R10
                CALL    tt_close
; Case N, its end, and case Q, port 2017: a new IP address ends a
; connection in E_TRESET
                MOVE    R8, 0
                CALL    tt_close
                MOVE    R1, TT_CB0
                MOVE    R2, 2017
                MOVE    R3, 0x01000100
                CALL    tt_open
                CALL    tt_waitopen
                MOVE    R1, TT_CB1      ; and a handle that listens, which stays
                MOVE    R2, 3005
                MOVE    R3, 0x01000100
                CALL    _tcp_listen
                MOVE    R10, R1
                MOVE    @R7++, R1       ; 1
                MOVE    @TT_SET, 0x0A00000A
                MOVE    R1, TT_SET
                CALL    _net_set
                MOVE    R1, R8
                CALL    _tcp_state
                MOVE    @R7++, R1       ; E_TRESET
                CALL    tt_close
                MOVE    R1, R10
                CALL    _tcp_state
                MOVE    @R7++, R1       ; 5, TCP_LISTEN
                MOVE    R1, R10
                MOVE    R2, 0
                CALL    _tcp_close
                MOVE    @R7++, R1       ; 0
                MOVE    @TT_SET, 0x0A000009
                MOVE    R1, TT_SET
                CALL    _net_set
; The cases of tcp_listen. The UDP endpoint stays open on TT_SIG through
; them, which keeps the network on, and tt_signal tells the peer which
; case listens.
                MOVE    R1, TT_SIG
                CALL    _udp_open
                MOVE    @R7++, R1       ; TT_SIG
; Case R: the errors of tcp_listen: E_PORT for the ports 0, 65536, and
; 4510, the station's, and E_TSIZE for a ring of 63 bytes, and a block not
; aligned
                MOVE    R8, TL_BAD
:
                MOVE[M] R1, @R8++
        ?Z      JMP     :+
                MOVE    R2, @R8++
                MOVE    R3, @R8++
                CALL    _tcp_listen
                MOVE    @R7++, R1
                JMP     :-
:
; Case S, port 3000: a handle that listens takes bytes to send, has none
; to read, and closes at once, with nothing sent
                MOVE    R1, TT_CB0
                MOVE    R2, 3000
                MOVE    R3, 0x01000100
                CALL    tl_listen
                MOVE    R1, R8
                CALL    _tcp_state
                MOVE    @R7++, R1       ; 5, TCP_LISTEN
                MOVE    R1, R8
                MOVE    R2, TT_TXB
                MOVE    R3, 5
                CALL    _tcp_send
                MOVE    @R7++, R1       ; 5
                MOVE    R1, R8
                MOVE    R2, TT_RXB
                MOVE    R3, 5
                CALL    _tcp_recv
                MOVE    @R7++, R1       ; 0
                MOVE    R1, R8
                MOVE    R2, 0
                CALL    _tcp_close
                MOVE    @R7++, R1       ; 0
                MOVE    R1, R8
                CALL    _tcp_state
                MOVE    @R7++, R1       ; 0, TCP_FREE
; Case T, port 3001: 5 bytes taken while listening, signal 1; the peer
; sends an ACK to the port, which gets a RST, and a SYN to port 3099,
; where nothing listens, which gets one too; then it connects, with data
; in the ACK that opens, 1000 bytes, and its FIN; the 5 bytes go after
; the handshake
                MOVE    R1, 5
                MOVE    R2, 0x41
                MOVE    R3, 1
                CALL    tt_fill
                MOVE    R1, TT_CB0
                MOVE    R2, 3001
                MOVE    R3, 0x08000100
                CALL    tl_listen
                MOVE    R1, R8
                MOVE    R2, TT_TXB
                MOVE    R3, 5
                CALL    _tcp_send
                MOVE    @R7++, R1       ; 5
                MOVE    R1, 1
                CALL    tl_signal
                CALL    tl_waitopen
                CALL    tl_recveof
                MOVE    R1, R8
                CALL    _tcp_state
                MOVE    @R7++, R1       ; 3, TCP_PEER_CLOSED
                CALL    tt_close
; Case U, port 3002: the board closes first, after 100 bytes; the peer's
; FIN again, after the board's last ACK, gets a RST, while the program
; polls
                MOVE    R1, TT_CB0
                MOVE    R2, 3002
                MOVE    R3, 0x01000100
                CALL    tl_listen
                MOVE    R1, 2
                CALL    tl_signal
                CALL    tt_waitopen
                MOVE    R1, 100
                MOVE    R2, 9
                MOVE    R3, 1
                CALL    tt_fill
                MOVE    R1, R8
                MOVE    R2, 100
                CALL    tt_sendall
                MOVE    @R7++, R1       ; 100
                CALL    tt_close
                MOVE    R1, TT_SEC
                CALL    tt_sleep
; Case V, port 3003: two handles take two peers; a third peer's SYNs are
; passed over while both are busy, and taken once the first handle
; listens again
                MOVE    R1, TT_CB0
                MOVE    R2, 3003
                MOVE    R3, 0x01000100
                CALL    tl_listen
                MOVE    R10, R8
                MOVE    R1, TT_CB1
                MOVE    R2, 3003
                MOVE    R3, 0x01000100
                CALL    tl_listen
                MOVE    R11, R8
                MOVE    R1, 3
                CALL    tl_signal
                MOVE    R8, R10
                CALL    tt_waitopen
                MOVE    R8, R11
                CALL    tt_waitopen
                MOVE    R8, R10
                CALL    tl_recveof      ; the first peer's 10 bytes
                CALL    tt_close
                MOVE    R1, TT_CB0
                MOVE    R2, 3003
                MOVE    R3, 0x01000100
                CALL    tl_listen       ; the handle again
                CALL    tl_waitopen
                CALL    tl_recveof      ; the third peer's 30
                CALL    tt_close
                MOVE    R8, R11
                CALL    tl_recveof      ; the second's 20
                CALL    tt_close
; Case W, port 3004: in SYN-RECEIVED, the SYN again gets the SYN-ACK
; again, a wrong ACK gets a RST, and a RST brings the handle back to
; LISTEN, with no error; then another peer connects, and sends 40 bytes
                MOVE    R1, TT_CB0
                MOVE    R2, 3004
                MOVE    R3, 0x04000100
                CALL    tl_listen
                MOVE    R1, 4
                CALL    tl_signal
                CALL    tl_waitopen
                CALL    tl_recveof
                CALL    tt_close
                CALL    _udp_close
                MOVE    @R7++, @ETH_CSR  ; 0, the port disabled
                SUB     R1, R7, TT_RES
                RET

TT_SET          .DAT    0x0A000009, 0xFFFFFF00, 0, 0
; The calls of tcp_open that fail: the block, the address, the port, and
; the sizes, up to a 0
TT_BAD          .DAT    TT_CB0, TT_PEER, 0, 0x04000400
                .DAT    TT_CB0, TT_PEER, 0x10000, 0x04000400
                .DAT    TT_CB0, TT_PEER, 2001, 0x003F0400
                .DAT    TT_CB0, TT_PEER, 2001, 0x0400003F
                .DAT    0x10000002+4*TT_CB0, TT_PEER, 2001, 0x04000400
                .DAT    0x100, TT_PEER, 2001, 0x04000400
                .DAT    TT_CB0, 0x0A00004D, 2001, 0x04000400
                .DAT    TT_CB0, 0xFFFFFFFF, 2001, 0x04000400
                .DAT    0
TT_CBS          .DAT    TT_CB0, TT_CB1, TT_CB2

; The calls of tcp_listen that fail: the block, the port, and the sizes,
; up to a 0
TL_BAD          .DAT    TT_CB0, 0, 0x01000100
                .DAT    TT_CB0, 0x10000, 0x01000100
                .DAT    TT_CB0, 4510, 0x01000100
                .DAT    TT_CB0, 3000, 0x003F0100
                .DAT    0x10000001+4*TT_CB0, 3000, 0x01000100
                .DAT    0

; tl_listen: tcp_listen of the block R1 on the port R2, with the sizes R3.
; R8 = the handle, which is stored. Uses R1-R6.
tl_listen
                CALL    _tcp_listen
                MOVE    R8, R1
                MOVE    @R7++, R1
                RET

; tl_signal: a datagram of the byte R1 to the peer's port TT_SIG, which
; starts its side of a case. Uses R1-R6.
tl_signal
                MOVE    @TT_SIGW, R1
                MOVE    R1, TT_PEER
                MOVE    R2, TT_SIG
                MOVE    R3, TT_SIGW
                MOVE    R4, 1
                JMP     _udp_send

; tl_waitopen: polls R8 with tcp_state until it leaves the handshake and
; TCP_LISTEN, or 20 seconds passed, and stores the state: TCP_OPEN, or
; TCP_PEER_CLOSED when the peer's FIN came first. Uses R1-R6, and R9,
; saved.
tl_waitopen
                PUSH    R9
                MOVE    R9, @io.us
:
                MOVE    R1, R8
                CALL    _tcp_state
                CMP     R1, 1
        ?Z      JMP     :+
                CMP     R1, 5
        ?!Z     JMP     :++
:
                SUB     R2, @io.us, R9
                CMP     R2, 20*TT_SEC
        ?C      JMP     :--
:
                MOVE    @R7++, R1
                POP     R9
                RET

; tl_recveof: tt_recvall of R8 up to 4096 bytes, with the bytes, their
; hash, and the last result of tcp_recv stored. Uses R1-R6.
tl_recveof
                MOVE    R1, R8
                MOVE    R2, 4096
                CALL    tt_recvall
                MOVE    @R7++, R1
                MOVE    @R7++, R2
                MOVE    @R7++, R3
                RET

; tt_open: tcp_open of the block R1 to the port R2 of tcppeer.py, with the
; sizes R3. R8 = the result, which is stored. Uses R1-R6.
tt_open
                MOVE    R4, R3
                MOVE    R3, R2
                MOVE    R2, TT_PEER
                CALL    _tcp_open
                MOVE    R8, R1
                MOVE    @R7++, R1
                RET

; tt_waitopen: tt_wait of R8 for TCP_OPEN, with the state stored. Uses
; R1-R6.
tt_waitopen
                MOVE    R1, R8
                MOVE    R2, 2
                CALL    tt_wait
                MOVE    @R7++, R1
                RET

; tt_echo: R1 bytes of TT_TX sent on R8, then up to R2 received, with the
; bytes sent, the bytes received, and their hash stored. R3 = the last
; result of tcp_recv. Uses R1-R6, and R9, saved.
tt_echo
                PUSH    R9
                MOVE    R9, R2
                MOVE    R2, R1
                MOVE    R1, R8
                CALL    tt_sendall
                MOVE    @R7++, R1
                MOVE    R1, R8
                MOVE    R2, R9
                CALL    tt_recvall
                MOVE    @R7++, R1
                MOVE    @R7++, R2
                POP     R9
                RET

; tt_close: tcp_close of R8, and tt_free. Uses R1-R6.
tt_close
                MOVE    R1, R8
                MOVE    R2, 0
                CALL    _tcp_close
                MOVE    @R7++, R1
; tt_free: tt_wait of R8 for TCP_FREE, with the state stored. Uses R1-R6.
tt_free
                MOVE    R1, R8
                MOVE    R2, 0
                CALL    tt_wait
                MOVE    @R7++, R1
                RET

; tt_div: R1 = R1 / R2, by subtraction. Uses R1-R3.
tt_div
                MOVE    R3, 0
:
                CMP     R1, R2
        ?C      JMP     :+
                SUB     R1, R1, R2
                ADD     R3, R3, 1
                JMP     :-
:
                MOVE    R1, R3
                RET

; tt_fill: R1 bytes at TT_TX, the byte i being R2 + i R3, modulo 256.
; Uses R1-R4.
tt_fill
                MOVE    R4, TT_TXB
:
                SUB[M]  R1, R1, 1
        ?C      RET
                MOVE    @R4++, R2
                ADD     R2, R2, R3
                JMP     :-

; tt_wait: R1 a handle, R2 a state. Polls with tcp_state until the state
; is R2, or negative, or 20 seconds passed. R1 = the last state. Uses
; R1-R6, and R8-R10, saved.
tt_wait
                PUSH    R8
                PUSH    R9
                PUSH    R10
                MOVE    R8, R1
                MOVE    R9, R2
                MOVE    R10, @io.us
:
                MOVE    R1, R8
                CALL    _tcp_state
                CMP     R1, R9
        ?Z      JMP     :+
                TST     R1
        ?N      JMP     :+
                SUB     R2, @io.us, R10
                CMP     R2, 20*TT_SEC
        ?C      JMP     :-
:
                POP     R10
                POP     R9
                POP     R8
                RET

; tt_sendall: R1 a handle, R2 a number of bytes, sent from TT_TX with
; tcp_send, polling, until all are taken, an error, or 20 seconds. R1 =
; the bytes taken, or the error. Uses R1-R6, and R8-R11, saved.
tt_sendall
                PUSH    R8
                PUSH    R9
                PUSH    R10
                PUSH    R11
                MOVE    R8, R1
                MOVE    R9, R2
                MOVE    R10, 0          ; taken
                MOVE    R11, @io.us
:
                CMP     R10, R9
        ?Z      JMP     :+
                MOVE    R1, R8
                ADD     R2, R10, TT_TXB
                SUB     R3, R9, R10
                CALL    _tcp_send
                TST     R1
        ?N      JMP     :++
                ADD     R10, R10, R1
                CALL    _net_poll
                SUB     R2, @io.us, R11
                CMP     R2, 20*TT_SEC
        ?C      JMP     :-
:
                MOVE    R1, R10
:
                POP     R11
                POP     R10
                POP     R9
                POP     R8
                RET

; tt_recvall: R1 a handle, R2 a number of bytes, received to TT_RX with
; tcp_recv, polling, until that many came, E_TEOF or another error, or 20
; seconds. R1 = the bytes received, R2 their hash, tt_hash, and R3 the
; last result of tcp_recv. Uses R1-R6, and R8-R12, saved.
tt_recvall
                PUSH    R8
                PUSH    R9
                PUSH    R10
                PUSH    R11
                PUSH    R12
                MOVE    R8, R1
                MOVE    R9, R2
                MOVE    R10, 0          ; received
                MOVE    R11, @io.us
                MOVE    R12, 0
:
                CMP     R10, R9
        ?Z      JMP     :+
                MOVE    R1, R8
                ADD     R2, R10, TT_RXB
                SUB     R3, R9, R10
                CALL    _tcp_recv
                MOVE    R12, R1
                TST     R1
        ?N      JMP     :+
                ADD     R10, R10, R1
                SUB     R2, @io.us, R11
                CMP     R2, 20*TT_SEC
        ?C      JMP     :-
:
                MOVE    R1, R10
                CALL    tt_hash
                MOVE    R2, R1
                MOVE    R1, R10
                MOVE    R3, R12
                POP     R12
                POP     R11
                POP     R10
                POP     R9
                POP     R8
                RET

; tt_hash: R1 = the hash of the R1 bytes at TT_RX, h = 31 h + b from 0.
; Uses R1-R4.
tt_hash
                MOVE    R2, 0
                MOVE    R3, TT_RXB
:
                SUB[M]  R1, R1, 1
        ?C      JMP     :+
                SHL     R4, R2, 5
                SUB     R2, R4, R2
                ADD     R2, R2, @R3++
                JMP     :-
:
                MOVE    R1, R2
                RET

; tt_sleep: R1 microseconds, polling. Uses R1-R6, and R8, saved.
tt_sleep
                PUSH    R8
                PUSH    R9
                MOVE    R8, R1
                MOVE    R9, @io.us
:
                CALL    _net_poll
                SUB     R1, @io.us, R9
                CMP     R1, R8
        ?C      JMP     :-
                POP     R9
                POP     R8
                RET
