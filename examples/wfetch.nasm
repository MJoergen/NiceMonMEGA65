; WFETCH.BIN: one fetch over HTTP, in machine code that the BASIC program
; weather.bas calls with SYS, beside it in the RAM, as sieve.bas calls
; SIEVE.BIN (basic/README.md, "Machine code beside a program"). BASIC
; has no statements for DNS and TCP, so this routine does the network,
; and the program does the rest: the request, the parse of the answer,
; and the screen.
;
; The program sets HIMEM = 0xD000 and loads this file, all of whose words
; are at 0xD000 or above, so the program goes on after the LOAD. It
; POKEs the server's name to WF_HOST and the request to WF_REQ, a
; character to a word, each ended by a 0, and the port to WF_PORT, and
; calls SYS 0xD002. Then WF_RES holds the bytes of the answer, at WF_ANS
; a byte to a word, or an error of the monitor, below 0.
;
; It is one call from the start of the fetch to its end, as SYS ends
; with mon_restore, which closes the network (monitor/README.md, entry
; 36): an open connection could not wait in between. It packs the name
; and the request into bytes, gets an IP address by DHCP when the board
; has none, and a DNS server the same way when the lookup finds none,
; as weather.c does, looks the name up, opens the connection, and sends
; the request and reads the answer in a loop, whose calls of tcp_send and
; tcp_recv poll the network, until the server closes, or ANS_MAX bytes
; have come, or TIMEOUT microseconds have passed, after which it gives
; MON_E_TTIMEOUT. The network's entries take byte addresses of the byte
; window, 0x20000000 + 4*W for word W.
;
; It returns 0 with RET, so that SYS prints Returned 00000000 and the
; program goes on, and keeps R7 to R13, as the C ABI asks, as BASIC's
; own registers are there. Uses R1-R6 freely, and R7 the request's
; length, R8 the handle, R9 the bytes sent, R10 the bytes received, and
; R11 the start's time, saved.

NET_CONFIG      .EQU    0x2A            ; the entries of the dispatch table (monitor/mon.nasm)
NET_DHCP        .EQU    0x2E
DNS_LOOKUP      .EQU    0x32
TCP_OPEN        .EQU    0x34
TCP_SEND        .EQU    0x38
TCP_RECV        .EQU    0x3A
TCP_CLOSE       .EQU    0x3C
MON_E_NODNS     .EQU    -46
MON_E_TTIMEOUT  .EQU    -55
MON_E_TEOF      .EQU    -57
TIME_LO         .EQU    0xFFFFFF44      ; the microsecond counter, bits 31..0

TIMEOUT         .EQU    20000000        ; 20 s for the whole answer
ANS_MAX         .EQU    2048            ; the bytes of the answer, at most
RX              .EQU    512             ; the rings of the connection
TX              .EQU    256

WF_HOST         .EQU    0xD100          ; the name, 64 words
WF_REQ          .EQU    0xD140          ; the request, 512 words
WF_ANS          .EQU    0xD400          ; the answer, ANS_MAX words
WF_PHOST        .EQU    0xDC00          ; the name packed, 16 words
WF_PREQ         .EQU    0xDC10          ; the request packed, 128 words
WF_PANS         .EQU    0xDC90          ; the answer packed, ANS_MAX/4 words
WF_CFG          .EQU    0xDE90          ; net_config's 4 words
WF_IP           .EQU    0xDE94          ; the server's IP address
WF_CB           .EQU    0xDEA0          ; the control block, 32 + RX/4 + TX/4 words, to 0xDF80

                .ORG    0xD000
WF_RES          .DAT    0               ; 0xD000: the bytes of the answer, or an error
WF_PORT         .DAT    80              ; 0xD001: the server's port, which the program POKEs
wfetch                                  ; 0xD002, which SYS calls
                PUSH    R7
                PUSH    R8
                PUSH    R9
                PUSH    R10
                PUSH    R11
                MOVE    R1, WF_HOST
                MOVE    R2, 0x20000000+4*WF_PHOST
                CALL    pack
                MOVE    R1, WF_REQ
                MOVE    R2, 0x20000000+4*WF_PREQ
                CALL    pack
                MOVE    R7, R1          ; the request's bytes
; An IP address, by DHCP when there is none
                MOVE    R1, WF_CFG
                CALL    NET_CONFIG
                TST     @WF_CFG
        ?!Z     JMP     wf_lookup
                CALL    NET_DHCP
                TST     R1
        ?N      JMP     wf_end
wf_lookup
                MOVE    R1, 0x20000000+4*WF_PHOST
                MOVE    R2, WF_IP
                CALL    DNS_LOOKUP
                CMP     R1, MON_E_NODNS
        ?!Z     JMP     :+
                CALL    NET_DHCP        ; a DNS server, by DHCP
                TST     R1
        ?N      JMP     wf_end
                MOVE    R1, 0x20000000+4*WF_PHOST
                MOVE    R2, WF_IP
                CALL    DNS_LOOKUP
:
                TST     R1
        ?N      JMP     wf_end
                MOVE    R1, WF_CB
                MOVE    R2, @WF_IP
                MOVE    R3, @WF_PORT
                MOVE    R4, RX*65536+TX
                CALL    TCP_OPEN
                TST     R1
        ?N      JMP     wf_end
                MOVE    R8, R1          ; the handle
                CLR     R9
                CLR     R10
                MOVE    R11, @TIME_LO
; The request, and the answer, until the server closes
wf_loop
                CMP     R9, R7
        ?!C     JMP     wf_recv         ; all of the request is sent
                MOVE    R1, R8
                ADD     R2, R9, 0x20000000+4*WF_PREQ
                SUB     R3, R7, R9
                CALL    TCP_SEND
                TST     R1
        ?N      JMP     wf_abort
                ADD     R9, R9, R1
wf_recv
                MOVE    R1, R8
                ADD     R2, R10, 0x20000000+4*WF_PANS
                MOVE    R3, ANS_MAX
                SUB     R3, R3, R10
                CALL    TCP_RECV
                CMP     R1, MON_E_TEOF
        ?Z      JMP     wf_close        ; the server closed: the whole answer
                TST     R1
        ?N      JMP     wf_abort
                ADD     R10, R10, R1
                CMP     R10, ANS_MAX
        ?!C     JMP     wf_full         ; as much as there is room for
                MOVE    R1, @TIME_LO
                SUB     R1, R1, R11
                CMP     R1, TIMEOUT
        ?C      JMP     wf_loop
                MOVE    R1, MON_E_TTIMEOUT
wf_abort
                PUSH    R1              ; the error
                MOVE    R1, R8
                MOVE    R2, 1
                CALL    TCP_CLOSE
                POP     R1
                JMP     wf_end
wf_full
                MOVE    R1, R8
                MOVE    R2, 1           ; an abort, as weather.c does
                CALL    TCP_CLOSE
                JMP     wf_unpack
wf_close
                MOVE    R1, R8
                CLR     R2
                CALL    TCP_CLOSE
; The answer, a byte to a word, for PEEK
wf_unpack
                MOVE    R1, 0x20000000+4*WF_PANS
                MOVE    R2, WF_ANS
                MOVE    R3, R10
:
                SUB[M]  R3, R3, 1
        ?N      JMP     :+
                MOVE    R4, @R1++
                MOVE    @R2++, R4
                JMP     :-
:
                MOVE    R1, R10
wf_end
                MOVE    @WF_RES, R1
                POP     R11
                POP     R10
                POP     R9
                POP     R8
                POP     R7
                CLR     R1              ; the status of SYS
                RET

; pack: the characters at R1, a word each, up to a 0, to the bytes at the
; byte address R2, with the 0. R1 = the bytes, without the 0. Uses R1-R4.
pack
                MOVE    R4, R2
:
                MOVE[M] R3, @R1++
                MOVE    @R2++, R3
        ?!Z     JMP     :-
                SUB     R1, R2, R4
                SUB     R1, R1, 1
                RET
