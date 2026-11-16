; The clock of the time of day, which the Makefile joins after monitor.nasm
; (its header): TIME, the dates of FAT's entries for monitor_fat.nasm, the
; clock set from the MEGA65's real-time clock at the cold start, which
; TIME sets (issue #105), and the time of an SNTP answer, which NTP sets
; (issues #127 and #148).
;
; The clock (nice_cpu's DEVICES.md §10) counts seconds since 1970-01-01
; 00:00:00, and keeps local time, as the MEGA65's real-time clock does
; (issue #105, nice_cpu#158): there are no time zones here, so a date and
; a time convert to the seconds of the clock and back as if they were UTC.
; It reads 32 bits of the seconds, up to 2106-02-07 06:28:15, and TIME
; sets the years 1970 to 2105.
;
; The fields of a date and a time are six words: the year, the month, the
; day, the hours, the minutes, and the seconds. clk_fields splits the
; seconds of the clock into the fields at V_F. A date and a time to set
; are read into the fields at V_I, and clk_valid sets the clock to them
; when they are one: it converts them to seconds, splits the seconds
; again, and compares, so that a month, a day, or a time out of its range
; never gives the same fields back. Both conversions walk the months from
; 1970, with the leap years of 1970 to 2106: every fourth, but 2100.
;
; The routines take and return their values in registers, as each one's
; comment says, and change only the registers that it names.

CLOCK_USEC      .EQU    0xFFFFFF46      ; the microseconds, and a read takes a snapshot of the seconds
CLOCK_SEC_LO    .EQU    0xFFFFFF47      ; the seconds since 1970, bits 31..0
CLOCK_SEC_HI    .EQU    0xFFFFFF48      ; and bits 63..32
CLOCK_STATUS    .EQU    0xFFFFFF49      ; bit 0 "set", which a write of CLOCK_USEC sets
CLK_UMUL        .EQU    0xFFFFFF24      ; the math unit's A * B, bits 31..0, unsigned

; The I2C master of the board (doc/SYSTEM.md): its command, its status,
; and its data, 4 bytes in a word. A command is the count of bytes in bits
; 20..16, the chip's first register in bits 15..8, bit 7 for a read, and
; the chip's address in bits 6..0.
I2C_CMD         .EQU    0xFFFFFF97
I2C_STATUS      .EQU    0xFFFFFF98
I2C_DATA        .EQU    0xFFFFFF99
I2C_PRESENT     .EQU    1
I2C_BUSY        .EQU    2
I2C_FAIL        .EQU    12              ; NACK or timeout

; The real-time clocks: the R6's RV-3032-C7 at 0x51, and the R3's
; ISL12020M at 0x6F. Both keep the local time in BCD, and the years 2000
; to 2099. The RV-3032-C7 keeps the hundredths of a second, the seconds,
; the minutes, the hours, the weekday, the date, the month, and the year
; from register 0, and its status at 0x0D, whose VLF and PORF, bits 0 and
; 1, say that it lost its time. The ISL12020M keeps the seconds, the
; minutes, the hours, the date, the month, the year, and the weekday from
; register 0, and its status at 7, whose RTCF, bit 0, says that it lost
; its time. Its hours have bit 7 set in 24-hour mode, and else bit 5 for
; PM, and 1 to 12, with 12 for 0. WRTC, bit 6 of its register 8, allows a
; write of the time.
RTC_RVREAD      .EQU    0x000E00D1      ; the RV-3032-C7's 14 bytes from register 0
RTC_ISLREAD     .EQU    0x000800EF      ; the ISL12020M's 8 bytes from register 0
RTC_RVTIME      .EQU    0x00070151      ; 7 bytes to the RV-3032-C7's register 1
RTC_RVSTAT      .EQU    0x00010D51      ; 1 byte to its status
RTC_ISLTIME     .EQU    0x0007006F      ; 7 bytes to the ISL12020M's register 0
RTC_ISLCTL      .EQU    0x0001086F      ; 1 byte to its register 8

NTP_UNIX        .EQU    2208988800      ; the seconds from 1900, NTP's era 0, to 1970
CLK_2106        .EQU    4291747200      ; the seconds of 2106-01-01 00:00:00

; clock_cmd: TIME ["YYYY-MM-DD HH:MM:SS"], R1 the string, or the end of the
; line without one, one character a word. With a date and a time as the
; pattern of S_CBAD has them, with blanks before and after, the clock is set
; to them, at 0 microseconds, which sets "set", and so is the MEGA65's
; real-time clock, in the years 2000 to 2099; anything else that is not
; blank is no time, and sets nothing. Then the clock is shown, or that it
; is not set, or past 2106. Uses R1-R7.
clock_cmd
                MOVE    R3, R1
                CALL    rest_blank
        ?Z      JMP     :+              ; only blanks: the clock shown
                MOVE    R2, TEXT_B+4*S_CBAD+22  ; YYYY-MM-DD HH:MM:SS
                MOVE    R4, V_I
                CALL    clk_parse
        ?Z      CLR     R7
        ?Z      CALL    clk_valid
                MOVE    R1, S_CBAD
        ?!Z     JMP     puts_b_crlf     ; which returns to the caller
                CALL    rtc_write
:               CALL    clk_split
        ?!C     JMP     :+
                CALL    clk_show
                JMP     _io_crlf        ; which returns to the caller
:               MOVE    R1, S_CNOTSET
                AND[M]  R0, @CLOCK_STATUS, 1
        ?!Z     MOVE    R1, S_CPAST
                JMP     puts_b_crlf     ; which returns to the caller

; clock_fat: R1 = FAT's date of the clock's time, and R2 its time in bits
; 15..0, in steps of two seconds, and the hundredths of a second over them,
; 0 to 199, in bits 23..16, as an entry's creation time has them in byte
; 13. R1 = 0 when the clock is not set, or past 2106, or its year is
; before 1980, FAT's first. Uses R1-R7.
clock_fat
                CALL    clk_split
                SUB     R1, @V_F, 1980
        ?C      CMP     R1, 127         ; not before 1980
        ?!C     CLR     R1
        ?!C     RET
                SHL     R1, R1, 4
                OR      R1, R1, @V_F+1
                SHL     R1, R1, 5
                OR      R1, R1, @V_F+2
                SHL     R2, @V_F+3, 6
                OR      R2, R2, @V_F+4
                SHL     R2, R2, 5
                0>C[M]  R3, @V_F+5, 1   ; and C the odd second
                OR      R2, R2, R3
                MOVE    @io.mpu_a, R7
                MOVE    @io.mpu_b, 10000
                MOVE    R3, @io.mpu_udivq
        ?C      ADD     R3, R3, 100
                SHL     R3, R3, 16
                OR      R2, R2, R3
                RET

; clock_rtc: the clock from the MEGA65's real-time clock, at the cold start
; (issue #105), unless it is set already, by a program, by TIME, or by an
; earlier start, or the board has no I2C master, as in niceemu, where the
; master's status is plain memory, 0. The clock is not set when no chip
; answers, it lost its time, or it holds no date and time, as with a digit
; over 9. The bytes of the date and the time go to V_I+6, the hundredths,
; down to V_I, the year, through R2 and then R3, with the masks of
; RTC_MASKS. R8 has bit 7 clear for the ISL12020M's 12-hour mode, whose
; hours RTC_H12 turns into 0 to 23, or 255. Uses R1-R8.
clock_rtc
                0>C[M]  R0, @CLOCK_STATUS, 1
        ?C      RET                     ; set already
                AND[M]  R0, @I2C_STATUS, I2C_PRESENT
        ?Z      RET                     ; no master
                MOVE    R1, RTC_RVREAD
                CALL    i2c
        ?!Z     JMP     :+
                AND[M]  R0, @I2C_DATA+3, 0x300  ; VLF and PORF
        ?!Z     RET
                MOVE    R2, @I2C_DATA   ; the hundredths, the seconds, the minutes, and the hours
                SHR     R3, @I2C_DATA+1, 8  ; the date, the month, and the year
                NOT     R8, R0          ; 24-hour mode
                JMP     rtc_bytes
:               MOVE    R1, RTC_ISLREAD
                CALL    i2c
        ?!Z     RET                     ; no chip answers
                AND[M]  R0, @I2C_DATA+1, 0x01000000  ; RTCF
        ?!Z     RET
                MOVE    R4, @I2C_DATA
                SHL     R2, R4, 8       ; 0, the seconds, the minutes, and the hours
                SHR     R3, R4, 24
                SHL     R5, @I2C_DATA+1, 8
                OR      R3, R3, R5      ; the date, the month, and the year
                SHR     R8, R4, 16      ; the hours
rtc_bytes
                MOVE    R4, V_I+7
:               AND     R1, R2, @TEXT_B+4*RTC_MASKS-V_I-1[R4]
                SHR     R2, R2, 8
                AND     R5, R1, 15
                CMP     9, R5
                SHR     R5, R1, 4
        ?!C     CMP     9, R5
        ?C      RET                     ; a digit over 9
                ADD     R6, R5, R5
                ADD     R6, R6, R5
                ADD     R6, R6, R6
                SUB     @--R4, R1, R6   ; 16 tens less 6 tens
                CMP     R4, V_I+3
        ?Z      MOVE    R2, R3
                CMP     R4, V_I
        ?!Z     JMP     :-
                AND[M]  R0, R8, 0x80
        ?Z      MOVE    R1, @V_I+3
        ?Z      MOVE    @V_I+3, @TEXT_B+4*RTC_H12[R1]
                MOVE    @io.mpu_a, @V_I+6
                MOVE    @io.mpu_b, 10000
                MOVE    R7, @CLK_UMUL
                ADD     @V_I, @V_I, 2000
                JMP     clk_valid       ; which returns to the caller

; The masks of the bytes of clock_rtc, of the year at V_I to the hundredths
; at V_I+6
RTC_MASKS
                .DAT    0x3F3F1FFF, 0x00FF7F7F
; The hours of the ISL12020M's 12-hour mode, from the number of their
; bits 5..0: 1 to 12 for AM, 21 to 32 for PM, with bit 5 as 20; 255 for
; none
RTC_H12         .DAT    0x030201FF, 0x07060504, 0x0B0A0908, 0xFFFFFF00, 0xFFFFFFFF
                .DAT    0x0F0E0DFF, 0x13121110, 0x17161514, 0xFFFFFF0C, 0xFFFFFFFF

; rtc_write: the MEGA65's real-time clock set to the date and the time at
; V_F, and the weekday of V_DAYS, 0 for Sunday, as the MEGA65 core counts
; them, when the year is one that the chip holds, 2000 to 2099 (issue
; #105). The RV-3032-C7 takes the seconds to the year from register 1,
; which also clears its hundredths, and then 0 in its status, which clears
; VLF and PORF, so that the next cold start trusts it. The ISL12020M takes
; them from register 0, in another order, with bit 7 of the hours for
; 24-hour mode, while WRTC allows the write, as the MEGA65 core writes it;
; the write clears RTCF. Nothing answers on the Nexys4DDR, which has no
; real-time clock, and nothing is written without an I2C master, as in
; niceemu, where its words are plain memory. R6 is the BCD of the hours,
; the minutes, and the seconds, R5 of the year, the month, and the date,
; and R4 the weekday in bits 23..16. Uses R1-R6.
rtc_write
                SUB     R1, @V_F, 2000
                CMP     R1, 100
        ?!C     RET                     ; a year that the chip does not hold
                AND[M]  R0, @I2C_STATUS, I2C_PRESENT
        ?Z      RET                     ; no master
                MOVE    R4, V_F
                CALL    clk_bcd
                SUB     R5, R6, 0x0C800000  ; the century, 0xC80 in BCD's places
                CALL    clk_bcd
                ADD     @io.mpu_a, @V_DAYS, 4
                MOVE    @io.mpu_b, 7
                SHL     R4, @io.mpu_udivr, 16
                SHL     R2, R4, 8
                OR      R2, R2, R6
                MOVE    R3, R5
                MOVE    R1, RTC_RVTIME
                CALL    i2c_w
        ?!Z     JMP     :+
                MOVE    R1, RTC_RVSTAT
                CLR     R2
                JMP     i2c_w1          ; which returns to the caller
:               MOVE    R1, RTC_ISLCTL
                MOVE    R2, 0x41        ; WRTC
                CALL    i2c_w1
        ?!Z     RET
                SHL     R2, R5, 24
                OR      R2, R2, R6
                OR      R2, R2, 0x800000  ; 24-hour mode
                SHR     R3, R5, 8
                OR      R3, R3, R4
                MOVE    R1, RTC_ISLTIME
                CALL    i2c_w
                MOVE    R1, RTC_ISLCTL
                MOVE    R2, 1
                JMP     i2c_w1          ; which returns to the caller

; clk_bcd: R6 = the three fields from R4 in BCD, a byte each, the first in
; bits 23..16. R4 = the word after them. Uses R1-R4 and R6.
clk_bcd
                MOVE    @io.mpu_b, 10
                CLR     R6
                MOVE    R3, 3
:               MOVE    @io.mpu_a, @R4++
                SHL     R6, R6, 8
                SHL     R1, @io.mpu_udivq, 4
                OR      R6, R6, R1
                OR      R6, R6, @io.mpu_udivr
                SUB[M]  R3, R3, 1
        ?!Z     JMP     :-
                RET

; i2c_w1: a write of the byte R2 with the command R1. i2c_w: a write of the
; bytes of R2 and R3, the first in bits 7..0 of R2. i2c: a transaction
; with the command R1, after the master is no longer busy. i2c_wait: the
; end of the transaction. Each: Z when the chip answered every byte. Uses
; R2, and R3 for i2c_w1.
i2c_w1          CLR     R3
i2c_w           MOVE    @I2C_DATA, R2
                MOVE    @I2C_DATA+1, R3
i2c             CALL    i2c_wait
                MOVE    @I2C_CMD, R1
i2c_wait
                MOVE    R2, @I2C_STATUS
                AND[M]  R0, R2, I2C_BUSY
        ?!Z     JMP     i2c_wait
                AND[M]  R0, R2, I2C_FAIL
                RET

; clock_zone: the offset of NTP, +HH:MM or -HH:MM, local time less UTC,
; from R1, with blanks after it to the end of the string (issue #127).
; R1 = its seconds, from -12:00 to +14:00, and Z, or Z clear when it is
; none. The sign's index, its code less '+' turned right by one, is 0 for
; '+' and 1 for '-', and too large for any other. Uses R1-R6.
clock_zone
                MOVE    R3, R1
                PUSH    @R3++           ; the sign
                MOVE    R2, TEXT_B+4*S_BADNTP+17  ; HH:MM
                MOVE    R4, V_I+3
                CALL    clk_parse
                POP     R5
        ?!Z     RET
                CLR     @V_I+5
                CLR     R1
                MOVE    R4, V_I+3
                CALL    clk_secs
                SUB     R5, R5, 0x2B
                ROR     R5, R5, 1
                CMP     1, R5
        ?!C     CMP     @ZONE_MAX[R5], R1
        ?!C     CMP     59, @V_I+4
        ?C      RET                     ; the sign, the offset, or the minutes
                TST     R5
        ?!Z     SUB     R1, R0, R1      ; west
                CMP     R0, R0
                RET
ZONE_MAX
                .DAT    14*3600, 12*3600  ; east and west

; clock_ntp: NTP's answer, R1 the seconds of its transmit timestamp since
; 1900 and R2 their fraction, plus the offset R8, in seconds, for st_ntp
; of the server R9. The clock is set to it, as TIME sets it, with the
; MEGA65's real-time clock, or the error E_NTPBAD when the time is none
; that the clock takes, before 1970 or after 2105, at ntp_bad_time. A time
; below 2^31 is of era 1, from 2036 on (RFC 4330 §3), which the 32 bits of
; the seconds since 1970 take, as do those of era 0 from 1970 on, with the
; same subtraction. The fraction gives the microseconds: 1000000 / 65536
; is 15625 / 1024. Then the time set is shown, the server, and how far the
; clock was off, in whole seconds, when it was set. R8 is the time, R10
; the text after the seconds, R11 the clock's old seconds, and R12 1 when
; it was set. Uses R1-R12.
clock_ntp
                SUB     R1, R1, NTP_UNIX
                CMP     R1, 0x80000000-NTP_UNIX  ; not of era 0 before 1970
                ADD     R8, R1, R8
        ?C      CMP     R8, CLK_2106
        ?!C     JMP     ntp_bad_time
                SHR     R10, R2, 16
                CALL    clk_split
                ADD[C]  R12, R0, R0
                MOVE    R11, R1
                MOVE    @io.mpu_a, R10
                MOVE    @io.mpu_b, 15625
                SHR     R7, @CLK_UMUL, 10
                MOVE    R1, R8
                CALL    clk_fields
                CALL    clk_put
                CALL    rtc_write
                MOVE    R1, S_CSET
                CALL    puts_b
                CALL    clk_show
                MOVE    R1, S_CFROM
                MOVE    R2, R9
                CALL    put_ip
                TST     R12
        ?Z      JMP     _io_crlf        ; which returns to the caller
                MOVE    R1, S_CWAS
                CALL    puts_b
                SUB[M]  R1, R8, R11
                MOVE    R10, S_CBEHIND
        ?Z      MOVE    R10, S_COFF
        ?C      MOVE    R10, S_CAHEAD
        ?C      SUB     R1, R0, R1
                CALL    _io_putdec
                MOVE    R1, R10
                JMP     puts_b_crlf     ; which returns to the caller

; clk_parse: the line from R3 as the pattern from the byte address R2 has
; it, up to the pattern's '"': a digit for each letter, and the same
; character for any other, with blanks after it to the end of the line.
; The number of each run of letters goes to the words from R4. Z when the
; line has the pattern. Uses R1-R6.
clk_parse
                CLR     R6              ; the number
:               MOVE    R5, @R2++
                CMP     R5, 0x41
        ?!C     JMP     :+              ; a letter: a digit
                MOVE    @R4++, R6       ; the number before it
                CLR     R6
                CMP     R5, 0x22
        ?Z      JMP     rest_blank      ; the end of the pattern, which returns to the caller
                CMP     @R3++, R5
        ?Z      JMP     :-
                RET                     ; not that character
:               SUB     R1, @R3++, 0x30
                CMP     9, R1
        ?C      RET                     ; no digit
                SHL     R5, R6, 2
                ADD     R6, R6, R5
                ADD     R6, R6, R6
                ADD     R6, R6, R1
                JMP     :--

; clk_show: the date and the time at V_F, as YYYY-MM-DD HH:MM:SS. R5 is the
; field. Uses R1-R5.
clk_show
                MOVE    R1, @V_F
                CALL    _io_putdec
                MOVE    R5, V_F+1
:               MOVE    R1, @TEXT_B+4*CLK_SEPS-V_F-1[R5]
                CALL    mon_putc
                CMP     @R5, 10
                MOVE    R1, 0x30
        ?C      CALL    mon_putc        ; the tens' 0
                MOVE    R1, @R5++
                CALL    _io_putdec
                CMP     R5, V_F+6
        ?!Z     JMP     :-
                RET
CLK_SEPS
                .ASCII_B '-- ::'

; clk_valid: the clock set to the date and the time at V_I, at R7
; microseconds, which sets "set", when they are one of the years 1970 to
; 2105, and clk_put: to the seconds R1 and R7 microseconds. The days of the
; months walked from 1970 up to the one at V_I+1 of the year at V_I, and
; the day at V_I+2 less 1, are the days since 1970; with the time they are
; the seconds, which clk_fields splits into V_F, and the fields must be the
; same. A year before 1970 walks no month, and splits into 1970. Z when it
; is set, and R1 = the seconds. Uses R1-R6.
clk_valid
                CMP     2105, @V_I
        ?C      RET                     ; after 2105
                SHL     R6, @V_I, 4
                ADD     R6, R6, @V_I+1
                SUB     R3, R0, @V_I+2
                CALL    clk_walk
                NOT     R1, R3          ; the days walked, and the day less 1
                MOVE    R4, V_I+3
                CALL    clk_secs
                CALL    clk_fields
                MOVE    R4, V_I
:               CMP     @R4++, @5[R4]   ; V_I against V_F
        ?!Z     RET
                CMP     R4, V_F
        ?!Z     JMP     :-
clk_put
                MOVE    @CLOCK_SEC_LO, R1
                CLR     @CLOCK_SEC_HI
                MOVE    @CLOCK_USEC, R7
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

; clk_split: the clock's time at V_F, R1 its seconds, and R7 its
; microseconds, and C, or C clear when it is not set, or past 32 bits of
; seconds; uses R1-R7. clk_fields: the seconds R1 at V_F, and their days
; at V_DAYS, and C; uses R2-R6.
clk_split
                0>C[M]  R0, @CLOCK_STATUS, 1
        ?!C     RET
                MOVE    R7, @CLOCK_USEC  ; and the snapshot of the seconds
                MOVE    R1, @CLOCK_SEC_LO
                CMP     @CLOCK_SEC_HI, 1
        ?!C     RET
clk_fields
                MOVE    @io.mpu_a, R1
                MOVE    R4, V_F+6
                MOVE    R2, CLK_RADIX
:               MOVE    @io.mpu_b, @R2++
                MOVE    @--R4, @io.mpu_udivr
                MOVE    @io.mpu_a, @io.mpu_udivq
                CMP     R4, V_F+3
        ?!Z     JMP     :-
                MOVE    R3, @io.mpu_a
                MOVE    @V_DAYS, R3
                NOT     R6, R0
                CALL    clk_walk
                SHR     @V_F, R2, 4
                AND     @V_F+1, R2, 15
                ADD     @V_F+2, R3, 1
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

; The pattern that clock_cmd gives clk_parse is in this text, from byte 22
; up to the quote after it, so a change of the text before it moves it
S_CBAD
                .ASCII_B 'Not a date and time: "YYYY-MM-DD HH:MM:SS", such as "2026-11-11 14:30:00"'
S_CPAST         .ASCII_B 'Clock past 2106'
S_CNOTSET
                .ASCII_B 'Clock not set'
S_CSET          .ASCII_B 'Clock set '
S_CFROM         .ASCII_B ' from '
S_CWAS          .ASCII_B ', was '
S_CBEHIND
                .ASCII_B ' s behind'
S_CAHEAD
                .ASCII_B ' s ahead'
                .DAT    0
S_COFF          .ASCII_B ' s off'
