; BASIC's statement TIME, and the clock's side of NTP, which the Makefile
; joins after monitor.nasm (its header) (issues #105, #127, and #148).
; They read the clock (nice_cpu's DEVICES.md §10) at its registers, as a
; program may, and set it with clock_set, entry 34, which sets the
; MEGA65's real-time clock too (issue #152). The conversions of a date
; and a time, clk_check, clk_split, and clk_fields, are in common.nasm,
; whose header has the fields at V_I and V_F.

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
        ?Z      CALL    clk_check
        ?!Z     MOVE    R1, S_CBAD
        ?!Z     JMP     puts_b_crlf     ; which returns to the caller
                CLR     R2
                CALL    CLOCK_SET       ; at 0 microseconds
:               CALL    clk_split
        ?!C     JMP     :+
                CALL    clk_show
                JMP     _io_crlf        ; which returns to the caller
:               MOVE    R1, S_CNOTSET
                AND[M]  R0, @CLOCK_STATUS, 1
        ?!Z     MOVE    R1, S_CPAST
                JMP     puts_b_crlf     ; which returns to the caller

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
                MOVE    R2, R7
                CALL    CLOCK_SET
                MOVE    R1, R8
                CALL    clk_fields
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
                CALL    MON_PUTC
                CMP     @R5, 10
                MOVE    R1, 0x30
        ?C      CALL    MON_PUTC        ; the tens' 0
                MOVE    R1, @R5++
                CALL    _io_putdec
                CMP     R5, V_F+6
        ?!Z     JMP     :-
                RET
CLK_SEPS
                .ASCII_B '-- ::'

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
