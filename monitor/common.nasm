; What the monitor and BASIC share, which the Makefile joins into each
; of the two images, the monitor's and BASIC's (monitor.nasm's header): the addresses of the devices that both use,
; the packed texts of puts_b, the IP addresses of get_ip and put_ip,
; rest_blank, and the conversions of a date and a time of the clock
; (issue #152). Its routines call the monitor through the entries of the
; dispatch table, and monlib.nasm, as a program does, so that each side
; may take them as they are.
;
; The fields of a date and a time are six words: the year, the month, the
; day, the hours, the minutes, and the seconds. The conversions work on a
; block of CLK_WORDS words of the caller's, whose address is in R8, so
; that the monitor and BASIC each have their own in their RAM: V_I of
; monitor.nasm, and V_BI of ../basic/basic.nasm. clk_fields splits the seconds of
; the clock into the fields at CLK_F of the block. A date and a time to
; set are read into the fields at CLK_I, and clk_check takes them when
; they are one: it converts them to seconds, splits the seconds again,
; and compares, so that a month, a day, or a time out of its range never
; gives the same fields back. Both conversions walk the months from
; 1970, with the leap years of 1970 to 2106: every fourth, but 2100.

SP              .EQU    R13
SCREEN          .EQU    0xFFFF0000      ; 80 x ROWS words, the character in bits 7..0
ROWS            .EQU    28              ; the screen's rows, as nice_cpu's NICE_SCREEN_ROWS
SCR_WORDS       .EQU    80*ROWS         ; the screen's words, from SCREEN
TEXT_B          .EQU    0x20000000      ; the byte window: byte A of the memory at TEXT_B+A
E_IP            .EQU    0xFFFFFFB0      ; the network station's IP address, NET_IP, the first byte in bits 31..24
E_MACH          .EQU    0xFFFFFFB1      ; the first two bytes of its MAC address, in bits 15..0
E_MACL          .EQU    0xFFFFFFB2      ; the last four bytes of its MAC address
STACK           .EQU    0xFFFFE800      ; the variables, which end a program's RAM: BASIC's, BASIC_WORDS words, where SP starts, down,
BASIC_WORDS     .EQU    0x800           ; as this BASIC's header has them, which the monitor takes SP from (bas_ram)
MON_RAM         .EQU    0xFFFFF000      ; and the monitor's, to 0xFFFFFEFF, below the devices,
MON_VARS        .EQU    0x1000          ; MON_VARS words, with the I/O page
STACK_ROOM      .EQU    0x400           ; the stack's first words, down from SP's start, which no load writes, and HIMEM leaves
MON_LAYOUT      .EQU    3               ; the version of the layout of the monitor's RAM, of the screen's ROWS, and of the jumps, in BASIC's header
BASIC_BASE      .EQU    0x3000          ; BASIC's image, above the monitor's, to PROGRAM:
BAS_COLD        .EQU    BASIC_BASE      ; its cold start, where mon_reset goes at its end,
BAS_WARM        .EQU    BASIC_BASE+2    ; and its warm start, where mon_exit goes, R1 the status,
BAS_H_MAGIC     .EQU    BASIC_BASE+4    ; and its header (issue #153, doc/BASIC_ROM.md, "The image"): the magic word,
BAS_H_IFACE     .EQU    BASIC_BASE+5    ; the interface, MON_LAYOUT in bits 31..16 and the entries it calls in 15..0,
BAS_H_LENGTH    .EQU    BASIC_BASE+6    ; the words of the image,
BAS_H_SUM       .EQU    BASIC_BASE+7    ; the checksum, the sum over the length is 0,
BAS_H_TEXT      .EQU    BASIC_BASE+8    ; the address of the version text,
BAS_H_VERSION   .EQU    BASIC_BASE+9    ; the version as a number,
BAS_H_FLAGS     .EQU    BASIC_BASE+10   ; the flags,
BAS_H_RAM       .EQU    BASIC_BASE+11   ; and the words of BASIC's RAM,
BAS_H_WORDS     .EQU    12              ; the words of the vectors and the header
BAS_MAGIC       .EQU    0x5341424E      ; NBAS in packed ASCII
BAS_KEEP        .EQU    1               ; the flag "keep": the monitor does not replace this BASIC
BAS_RAM_MIN     .EQU    0x400           ; the words of BASIC's RAM that the monitor takes, from 1K
BAS_RAM_MAX     .EQU    0x2000          ; to 8K
PROGRAM         .EQU    0x8000          ; where a program is, above the ROM
RAM_WORDS       .EQU    0xFFFFFF9E      ; the words of the RAM, 0 in niceemu, where there is no limit
CLOCK_USEC      .EQU    0xFFFFFF46      ; the microseconds, and a read takes a snapshot of the seconds
CLOCK_SEC_LO    .EQU    0xFFFFFF47      ; the seconds since 1970, bits 31..0
CLOCK_SEC_HI    .EQU    0xFFFFFF48      ; and bits 63..32
CLOCK_STATUS    .EQU    0xFFFFFF49      ; bit 0 "set", which a write of CLOCK_USEC sets
CLK_UMUL        .EQU    0xFFFFFF24      ; the math unit's A * B, bits 31..0, unsigned

CLK_I           .EQU    0               ; a block of the conversions of dates: the fields to set, and a 7th word,
CLK_F           .EQU    6               ; the fields of a time,
CLK_DAYS        .EQU    12              ; and its days since 1970
CLK_WORDS       .EQU    13

SD_SELECT       .EQU    0xFFFFFFA4      ; the selected slot
SD_LAST         .EQU    0xFFFFFFA5      ; the card's last sector, while it is ready

; puts_crlf: the string at R1, one character a word, and CR LF
puts_crlf
                CALL    _io_puts
                JMP     _io_crlf        ; which returns to the caller

; puts_b: the packed text at the word address R1, up to its 0 byte, as
; _io_puts reads it in the byte window. Uses R1.
puts_b
                SHL     R1, R1, 2
                ADD     R1, R1, TEXT_B
                JMP     _io_puts        ; which returns to the caller

; puts_b_crlf: the packed text at R1, and CR LF
puts_b_crlf
                CALL    puts_b
                JMP     _io_crlf        ; which returns to the caller

S_UCOMMA
                .ASCII_B ', '
S_UGAP          .ASCII_B '  '

; get_ip: the IP address at R1, four decimal numbers of 0 to 255 with dots
; between them: R1 the address, R2 = 1, and R3 after it, or R2 = 0 when
; there is none. Uses R1-R6.
get_ip
                MOVE    R3, R1          ; the next character
                CLR     R1              ; the address
                MOVE    R6, 4           ; the numbers left
get_ip_num
                CLR     R4              ; the number
                MOVE    R5, R3          ; where it starts
:
                SUB     R2, @R3, 0x30
                CMP     R2, 10
        ?!C     JMP     :+              ; no digit
                ADD     R4, R4, R4      ; R4 is 10 * R4 + the digit
                ADD     R2, R2, R4
                SHL     R4, R4, 2
                ADD     R4, R4, R2
                CMP     R4, 256
        ?!C     JMP     get_ip_bad
                ADD     R3, R3, 1
                JMP     :-
:
                CMP     R3, R5
        ?Z      JMP     get_ip_bad      ; a number without digits
                SHL     R1, R1, 8
                OR      R1, R1, R4
                SUB[M]  R6, R6, 1
        ?Z      MOVE    R2, 1
        ?Z      RET
                CMP     @R3, 0x2E       ; .
        ?!Z     JMP     get_ip_bad
                ADD     R3, R3, 1
                JMP     get_ip_num
get_ip_bad
                CLR     R2
                RET

; put_ip: the string at R1, and the IP address R2 in decimal with dots.
; Uses R1-R4, and R7 and R8 across the calls, saved.
put_ip
                PUSH    R7
                PUSH    R8
                MOVE    R8, R2
                CALL    puts_b
                MOVE    R7, 4           ; the bytes left
:               ROL     R8, R8, 8       ; the top byte to the bottom
                AND     R1, R8, 0xFF
                CALL    _io_putdec
                SUB[M]  R7, R7, 1
        ?Z      JMP     :+
                MOVE    R1, 0x2E
                CALL    MON_PUTC
                JMP     :-
:               POP     R8
                POP     R7
                RET

; rest_blank: Z when the line from R3 has only blanks. Uses R3.
rest_blank
                CMP     @R3, 0x20
        ?Z      ADD     R3, R3, 1
        ?Z      JMP     rest_blank
                TST     @R3
                RET

; clk_check: Z when the date and the time at CLK_I of the block R8 are
; one of the years 1970 to 2105, and R1 = their seconds. The days of the
; months walked from 1970 up to the one at CLK_I+1 of the year at CLK_I,
; and the day at CLK_I+2 less 1, are the days since 1970; with the time
; they are the seconds, which clk_fields splits into CLK_F, and the
; fields must be the same. A year before 1970 walks no month, and splits
; into 1970. Uses R1-R6.
clk_check
                CMP     2105, @CLK_I[R8]
        ?C      RET                     ; after 2105
                SHL     R6, @CLK_I[R8], 4
                ADD     R6, R6, @CLK_I+1[R8]
                SUB     R3, R0, @CLK_I+2[R8]
                CALL    clk_walk
                NOT     R1, R3          ; the days walked, and the day less 1
                ADD     R4, R8, CLK_I+3
                CALL    clk_secs
                CALL    clk_fields
                ADD     R4, R8, CLK_I
                ADD     R5, R8, CLK_F
:               CMP     @R4++, @CLK_F-CLK_I-1[R4]  ; CLK_I against CLK_F
        ?!Z     RET
                CMP     R4, R5
        ?!Z     JMP     :-
                RET

; clk_secs: R1 = the seconds of the days R1 and the hours, the minutes, and
; the seconds from R4. Uses R1, R2, and R4.
clk_secs
                MOVE    R2, CLK_RADIX+3
:               MOVE    @io.mpu_a, R1
                MOVE    @io.mpu_b, @--R2
                ADD     R1, @CLK_UMUL, @R4++
                CMP     R2, CLK_RADIX
        ?!Z     JMP     :-
                RET
CLK_RADIX
                .DAT    60, 60, 24

; clk_split: the clock's time at CLK_F of the block R8, R1 its seconds,
; and R7 its microseconds, and C, or C clear when it is not set, or past
; 32 bits of seconds; uses R1-R7. clk_fields: the seconds R1 at CLK_F of
; the block R8, and their days at CLK_DAYS, and C; uses R2-R6.
clk_split
                0>C[M]  R0, @CLOCK_STATUS, 1
        ?!C     RET
                MOVE    R7, @CLOCK_USEC  ; and the snapshot of the seconds
                MOVE    R1, @CLOCK_SEC_LO
                CMP     @CLOCK_SEC_HI, 1
        ?!C     RET
clk_fields
                MOVE    @io.mpu_a, R1
                ADD     R4, R8, CLK_F+6
                ADD     R5, R8, CLK_F+3
                MOVE    R2, CLK_RADIX
:               MOVE    @io.mpu_b, @R2++
                MOVE    @--R4, @io.mpu_udivr
                MOVE    @io.mpu_a, @io.mpu_udivq
                CMP     R4, R5
        ?!Z     JMP     :-
                MOVE    R3, @io.mpu_a
                MOVE    @CLK_DAYS[R8], R3
                NOT     R6, R0
                CALL    clk_walk
                SHR     @CLK_F[R8], R2, 4
                AND     @CLK_F+1[R8], R2, 15
                ADD     @CLK_F+2[R8], R3, 1
                RET

; clk_walk: the months from 1970-01 walked while the days R3 are at least
; the month's, and its key, the year times 16 plus the month, 1 to 12, is
; below R6. R2 = the key of the month reached, and R3 = the days left. C
; when it stopped on the days. The months 0 and 13 to 15 of a key have no
; days. Uses R2, R3, and R5.
clk_walk
                MOVE    R2, 1970*16+1
:               CMP     R2, R6
        ?!C     RET
                AND     R5, R2, 15
                MOVE    R5, @TEXT_B+4*CLK_MDAYS[R5]
                CMP     R5, 28
        ?Z      AND[M]  R0, R2, 0x30    ; February of a fourth year
        ?Z      MOVE    R5++, R5
                CMP     R2, 2100*16+2   ; but 2100
        ?Z      DEC     R5, R5
                CMP     R3, R5
        ?C      RET
                SUB     R3, R3, R5
                MOVE    R2++, R2
                JMP     :-
CLK_MDAYS
                .DAT    0x1F1C1F00, 0x1F1E1F1E, 0x1E1F1E1F, 0x0000001F

S_IP            .ASCII_B 'IP address '
