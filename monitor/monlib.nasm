; The routines that the monitor's commands share with programs (README.md,
; "The dispatch table"): the console's input, and strings and numbers on
; the monitor's outputs. They are not in the dispatch table: this file is
; joined after a program, with mon.nasm, whose stubs they call, and the
; monitor joins it too. The routines follow the C ABI of
; nice_cpu/runtime/ABI.md: the arguments in R1-R4, the result in R1, R1-R6
; changed, and R7-R13 kept. Their names start with _io_, so that they do
; not clash with nice_cpu's runtime or C library, and the .EQU names with
; io., so that they do not clash with a program's.

io.console      .EQU    0xFFFFFF00      ; a read: bit 8 and the byte, 0x200 at the end, or 0
io.us           .EQU    0xFFFFFF44      ; the microseconds since reset
io.mpu_a        .EQU    0xFFFFFF20      ; the math unit's A and B,
io.mpu_b        .EQU    0xFFFFFF21
io.mpu_udivq    .EQU    0xFFFFFF28      ; and A / B and A mod B, unsigned
io.mpu_udivr    .EQU    0xFFFFFF29
io.t_esc        .EQU    10000           ; the longest wait for the byte after an ESC, in microseconds

; _io_puts: the string at R1, one character per word up to a 0 word, through
; mon_putc. Uses R1, and R7 across the calls, saved.
_io_puts
                MOVE    @--R13, R7
                MOVE    R7, R1
_io_puts.loop
                MOVE[M] R1, @R7++
        ?Z      MOVE    R7, @R13++
        ?Z      MOVE    R15, @R13++
                ADD     @--R13, 2, R15
                MOVE    R15, _mon_putc
                MOVE    R15, _io_puts.loop

; _io_crlf: CR LF, which ends a line on the screen and on the line
_io_crlf
                MOVE    R1, _io_crlf.s
                MOVE    R15, _io_puts
_io_crlf.s
                .DAT    13, 10, 0

; _io_puthex: R1 in hex, 8 digits. Uses R1, and R7 and R8 across the calls,
; saved.
_io_puthex
                MOVE    @--R13, R7
                MOVE    @--R13, R8
                MOVE    R7, R1
                MOVE    R8, 8
_io_puthex.loop
                ROL     R7, R7, 4       ; the top digit to the bottom
                AND     R1, R7, 0xF
                ADD     R1, R1, 0x30
                SUB[M]  R0, R1, 0x3A
        ?!C     ADD     R1, R1, 7       ; A to F
                ADD     @--R13, 2, R15
                MOVE    R15, _mon_putc
                SUB[M]  R8, R8, 1
        ?!Z     MOVE    R15, _io_puthex.loop
                MOVE    R8, @R13++
                MOVE    R7, @R13++
                MOVE    R15, @R13++

; _io_putdec: R1 in decimal, unsigned, without leading zeros, with the math
; unit (nice_cpu's SYSTEM.md §2). The digits are pushed last first. Uses
; R1, and R7 across the calls, saved.
_io_putdec
                MOVE    @--R13, R7
                MOVE    R7, 0           ; the digits pushed
                MOVE    @io.mpu_b, 10
_io_putdec.div
                MOVE    @io.mpu_a, R1
                MOVE    @--R13, @io.mpu_udivr
                ADD     R7, R7, 1
                MOVE[M] R1, @io.mpu_udivq
        ?!Z     MOVE    R15, _io_putdec.div
_io_putdec.put
                ADD     R1, @R13++, 0x30
                ADD     @--R13, 2, R15
                MOVE    R15, _mon_putc
                SUB[M]  R7, R7, 1
        ?!Z     MOVE    R15, _io_putdec.put
                MOVE    R7, @R13++
                MOVE    R15, @R13++

; _io_gethex: a hex number in the string at R1, after any blanks, in either
; case. R1 = its value, R2 = the number of its digits, 0 if there is none,
; and R3 = the address of the word after it. More than 8 digits keep the
; last 8. Uses R1-R5.
_io_gethex
                MOVE    R3, R1
                MOVE    R1, 0
                MOVE    R2, 0
_io_gethex.skip
                SUB[M]  R0, @R3, 0x20
        ?Z      ADD     R3, R3, 1
        ?Z      MOVE    R15, _io_gethex.skip
_io_gethex.loop
                MOVE    R4, @R3
                SUB     R5, R4, 0x30
                SUB[M]  R0, R5, 10
        ?C      MOVE    R15, _io_gethex.digit  ; 0 to 9
                OR      R4, R4, 0x20    ; A to F as a to f
                SUB     R5, R4, 0x61
                SUB[M]  R0, R5, 6
        ?!C     MOVE    R15, @R13++     ; no digit: the end
                ADD     R5, R5, 10
_io_gethex.digit
                SHL     R1, R1, 4
                OR      R1, R1, R5
                ADD     R2, R2, 1
                ADD     R3, R3, 1
                MOVE    R15, _io_gethex.loop

; _io_getc: R1 = the next byte of the console, which it waits for. A read
; of 0x200, the end of the line's input, is no byte: on a board the
; keyboard's bytes still come (nice_cpu's SYSTEM.md §5), and in niceemu
; the input file has ended. Uses R1.
_io_getc
                MOVE    R1, @io.console
                AND[M]  R0, R1, 0x100
        ?Z      MOVE    R15, _io_getc
                AND     R1, R1, 0xFF
                MOVE    R15, @R13++

; _io_getc.soon: the next byte of the console if one comes within io.t_esc
; microseconds: R1 = the byte, and Z is clear; or R1 = 0, and Z is set.
; Uses R1 and R2.
_io_getc.soon
                ADD     R2, @io.us, io.t_esc  ; the deadline
_io_getc.poll
                MOVE    R1, @io.console
                AND[M]  R0, R1, 0x100
        ?!Z     AND     R1, R1, 0xFF
        ?!Z     OR[M]   R0, R1, 0x100   ; Z clear, also for a byte of 0
        ?!Z     MOVE    R15, @R13++
                SUB[M]  R0, @io.us, R2
        ?N      MOVE    R15, _io_getc.poll
                MOVE[M] R1, 0
                MOVE    R15, @R13++

; _io_gets: a line into the buffer at R1, up to R2 characters, one per
; word, and a 0 word after them, so the buffer has R2 + 1 words. R1 = the
; number of characters. CR ends the line; DEL and BS delete the character
; before the cursor; CTRL-C empties the line; the other control codes, the
; bytes 0x80 to 0x9F, and the escape sequences of the cursor and function
; keys are dropped, and so is an ESC alone. Each character is echoed
; through mon_putc, and CR as CR LF. Uses R1-R4, and R7-R9 across the
; calls, saved.
_io_gets
                MOVE    @--R13, R7
                MOVE    @--R13, R8
                MOVE    @--R13, R9
                MOVE    R7, R1          ; the first word
                ADD     R8, R1, R2      ; the word after the last
                MOVE    R9, R1          ; the next free word
_io_gets.next
                ADD     @--R13, 2, R15
                MOVE    R15, _io_getc
_io_gets.have
                SUB[M]  R0, R1, 0x0D
        ?Z      MOVE    R15, _io_gets.end
                SUB[M]  R0, R1, 0x7F
        ?Z      MOVE    R15, _io_gets.del
                SUB[M]  R0, R1, 0x08
        ?Z      MOVE    R15, _io_gets.del
                SUB[M]  R0, R1, 0x03
        ?Z      MOVE    R15, _io_gets.cancel
                SUB[M]  R0, R1, 0x1B
        ?Z      MOVE    R15, _io_gets.esc
                SUB[M]  R0, R1, 0x20
        ?C      MOVE    R15, _io_gets.next  ; another control code
                SUB[M]  R0, R1, 0xA0
        ?!C     MOVE    R15, _io_gets.put  ; 0xA0 and above
                SUB[M]  R0, R1, 0x80
        ?!C     MOVE    R15, _io_gets.next  ; 0x80 to 0x9F
_io_gets.put
                SUB[M]  R0, R9, R8
        ?Z      MOVE    R15, _io_gets.next  ; the line is full
                MOVE    @R9++, R1
                ADD     @--R13, 2, R15
                MOVE    R15, _mon_putc
                MOVE    R15, _io_gets.next
_io_gets.del
                SUB[M]  R0, R9, R7
        ?Z      MOVE    R15, _io_gets.next  ; nothing before the cursor
                SUB     R9, R9, 1
                MOVE    R1, _io_gets.rub
                ADD     @--R13, 2, R15
                MOVE    R15, _io_puts
                MOVE    R15, _io_gets.next
_io_gets.cancel
                MOVE    R9, R7
                MOVE    R1, _io_gets.cc
                ADD     @--R13, 2, R15
                MOVE    R15, _io_puts
_io_gets.end
                MOVE    @R9, 0
                ADD     @--R13, 2, R15
                MOVE    R15, _io_crlf
                SUB     R1, R9, R7
                MOVE    R9, @R13++
                MOVE    R8, @R13++
                MOVE    R7, @R13++
                MOVE    R15, @R13++
; An ESC: with a [ or an O within io.t_esc, a sequence, whose bytes up to
; its final one, 0x40 to 0x7E, are dropped; with another byte in time,
; that byte stands on its own; with none, nothing.
_io_gets.esc
                ADD     @--R13, 2, R15
                MOVE    R15, _io_getc.soon
        ?Z      MOVE    R15, _io_gets.next
                SUB[M]  R0, R1, 0x5B    ; [
        ?Z      MOVE    R15, _io_gets.csi
                SUB[M]  R0, R1, 0x4F    ; O
        ?!Z     MOVE    R15, _io_gets.have
_io_gets.csi
                ADD     @--R13, 2, R15
                MOVE    R15, _io_getc.soon
        ?Z      MOVE    R15, _io_gets.next
                SUB[M]  R0, R1, 0x40
        ?C      MOVE    R15, _io_gets.csi  ; a parameter byte
                MOVE    R15, _io_gets.next  ; the final byte
_io_gets.rub
                .DAT    8, 0x20, 8, 0   ; BS, a blank, BS
_io_gets.cc
                .DAT    0x5E, 0x43, 0   ; ^C
