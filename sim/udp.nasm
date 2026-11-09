; Answer one UDP datagram to port 4511 of the station through the port for
; Ethernet frames (nice_cpu's SYSTEM.md §7), for tools/hwtest.py, then
; halt. The station's IP address must be set. The program enables the
; port and waits for an IPv4 frame without options, to the station's IP
; address, of UDP to port 4511, and releases every other frame. It copies
; the frame to the send buffer through the RAM at SCRATCH, with the MAC
; addresses, the IP addresses, and the ports swapped, which leaves both
; checksums right, and sends it back. It waits until the frame is sent,
; disables the port, and halts.
NET_IP          .EQU    0xFFFFFFB0
ETH_CSR         .EQU    0xFFFFFFC0
ETH_RX_LEN      .EQU    0xFFFFFFC1
ETH_TX_LEN      .EQU    0xFFFFFFC2
ETH_CHUNK       .EQU    0xFFFFFFC3
ETH_BUF0        .EQU    0xFFFFFFC8
ETH_BUF1        .EQU    0xFFFFFFC9
ETH_BUF3        .EQU    0xFFFFFFCB
ETH_BUF4        .EQU    0xFFFFFFCC
ETH_BUF6        .EQU    0xFFFFFFCE
SCRATCH         .EQU    0x400           ; the frame's words, from word 0
SCRATCH7        .EQU    0x407           ; its words 7, 8, and 9
UDP_PORT        .EQU    4511

                MOVE    @ETH_CSR, 1
RXWAIT          MOVE    R1, @ETH_CSR
                AND[M]  R0, R1, 2       ; a frame waits?
        ?Z      JMP     RXWAIT
                MOVE    @ETH_CHUNK, 0
                MOVE    R1, @ETH_BUF3   ; the EtherType in bits 15..0
                AND     R1, R1, 0xFFFF
                CMP     R1, 0x0800
        ?!Z     JMP     SKIP
                MOVE    R1, @ETH_BUF4   ; version 4, a header of 20 bytes
                SHR     R1, R1, 24
                CMP     R1, 0x45
        ?!Z     JMP     SKIP
                MOVE    R1, @ETH_BUF6   ; the protocol in bits 23..16
                SHR     R1, R1, 16
                AND     R1, R1, 0xFF
                CMP     R1, 17
        ?!Z     JMP     SKIP
                MOVE    @ETH_CHUNK, 1
                MOVE    R1, @ETH_BUF0   ; word 8, the destination IP address
                MOVE    R2, @NET_IP
                CMP     R1, R2
        ?!Z     JMP     SKIP
                MOVE    R1, @ETH_BUF1   ; word 9, the destination port
                AND     R1, R1, 0xFFFF
                CMP     R1, UDP_PORT
        ?!Z     JMP     SKIP

; The frame's R12 words, from the window into SCRATCH, 8 a chunk
                MOVE    R4, @ETH_RX_LEN
                ADD     R12, R4, 5
                SHR     R12, R12, 2
                MOVE    R6, 0
                MOVE    R7, SCRATCH
COPY_IN         MOVE    @ETH_CHUNK, R6
                MOVE    R2, ETH_BUF0
                MOVE    R3, 8
COPY_IN8
                MOVE    @R7++, @R2++
                SUB[M]  R3, R3, 1
        ?!Z     JMP     COPY_IN8
                ADD     R6, R6, 1
                SHL     R1, R6, 3
                CMP     R1, R12         ; C while words remain
        ?C      JMP     COPY_IN

; Words 0 to 3: the destination, the source, and the EtherType, from
; byte 2. The source becomes the destination, and the station's MAC
; address, the destination, the source.
                MOVE    R7, SCRATCH
                MOVE    R8, @R7++
                MOVE    R9, @R7++
                MOVE    R10, @R7++
                MOVE    R11, @R7++
                SHR     R1, R10, 16
                SHL     R2, R10, 16
                SHR     R3, R11, 16
                OR      R2, R2, R3
                SHL     R5, R8, 16
                SHR     R6, R9, 16
                OR      R5, R5, R6
                SHL     R6, R9, 16
                AND     R11, R11, 0xFFFF
                OR      R6, R6, R11
                MOVE    R7, SCRATCH
                MOVE    @R7++, R1
                MOVE    @R7++, R2
                MOVE    @R7++, R5
                MOVE    @R7++, R6
; Words 7 and 8, the IP addresses, swap, and so do the halves of word 9,
; the ports.
                MOVE    R7, SCRATCH7
                MOVE    R8, @R7++
                MOVE    R9, @R7++
                MOVE    R10, @R7
                ROL     R10, R10, 16
                MOVE    @R7, R10
                MOVE    R7, SCRATCH7
                MOVE    @R7++, R9
                MOVE    @R7, R8

; SCRATCH into the send buffer, and the frame goes out.
                MOVE    R6, 0x100
                MOVE    R7, SCRATCH
COPY_OUT
                MOVE    @ETH_CHUNK, R6
                MOVE    R2, ETH_BUF0
                MOVE    R3, 8
COPY_OUT8
                MOVE    @R2++, @R7++
                SUB[M]  R3, R3, 1
        ?!Z     JMP     COPY_OUT8
                ADD     R6, R6, 1
                AND     R1, R6, 0xFF
                SHL     R1, R1, 3
                CMP     R1, R12
        ?C      JMP     COPY_OUT
                MOVE    @ETH_TX_LEN, R4
                MOVE    @ETH_RX_LEN, 0
BUSY            MOVE    R1, @ETH_CSR
                AND[M]  R0, R1, 4       ; busy while it is sent
        ?!Z     JMP     BUSY
                MOVE    @ETH_CSR, 0
                HALT

SKIP            MOVE    @ETH_RX_LEN, 0
                JMP     RXWAIT
