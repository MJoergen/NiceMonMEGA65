; The clock of the time of day, which the Makefile joins after monitor.nasm
; (its header): clock_set, entry 34, which BASIC's TIME and NTP call
; (basic_time.nasm), the dates of FAT's entries for monitor_fat.nasm, and
; the clock set from the MEGA65's real-time clock at the cold start, which
; clock_set writes (issues #105, #127, #148, and #152).
;
; The clock (nice_cpu's DEVICES.md §10) counts seconds since 1970-01-01
; 00:00:00, and keeps local time, as the MEGA65's real-time clock does
; (issue #105, nice_cpu#158): there are no time zones here, so a date and
; a time convert to the seconds of the clock and back as if they were UTC.
; It reads 32 bits of the seconds, up to 2106-02-07 06:28:15, and TIME
; sets the years 1970 to 2105.
;
; The fields of a date and a time, at V_F and V_I, and their conversions
; are in common.nasm, whose header has them. clk_valid sets the clock to
; the date and the time at V_I when clk_check takes them.
;
; The routines take and return their values in registers, as each one's
; comment says, and change only the registers that it names.

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

; clock_set: entry 34. The clock set to R1 seconds since 1970-01-01
; 00:00:00, in local time, and R2 microseconds, which sets "set", as
; TIME and NTP set it; 1000000 or more sets 999999, as the clock does
; (nice_cpu's DEVICES.md §10). On the MEGA65, a time in the years 2000 to
; 2099 sets the real-time clock too, with rtc_write. R1 = 0. Uses R1-R6,
; and R7 and R8 across the calls, saved: the microseconds, and the
; monitor's block of the conversions, V_I.
clock_set
                PUSH    R7
                PUSH    R8
                MOVE    R7, R2
                MOVE    R8, V_I
                CALL    clk_put
                CALL    clk_fields
                CALL    rtc_write
                POP     R8
                POP     R7
                CLR     R1
                RET

; clock_fat: R1 = FAT's date of the clock's time, and R2 its time in bits
; 15..0, in steps of two seconds, and the hundredths of a second over them,
; 0 to 199, in bits 23..16, as an entry's creation time has them in byte
; 13. R1 = 0 when the clock is not set, or past 2106, or its year is
; before 1980, FAT's first. Uses R1-R7, and R8 across the call, saved:
; the monitor's block of the conversions, V_I.
clock_fat
                PUSH    R8
                MOVE    R8, V_I
                CALL    clk_split
                POP     R8
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
                MOVE    R8, V_I         ; the monitor's block of the conversions
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

; clk_valid: the clock set to the date and the time at V_I, R8, at R7
; microseconds, which sets "set", when clk_check takes them, and clk_put:
; to the seconds R1 and R7 microseconds. Z when it is set, and R1 = the
; seconds. Uses R1-R6.
clk_valid
                CALL    clk_check
        ?!Z     RET
                JMP     clk_put

clk_put
                MOVE    @CLOCK_SEC_LO, R1
                CLR     @CLOCK_SEC_HI
                MOVE    @CLOCK_USEC, R7
                RET
