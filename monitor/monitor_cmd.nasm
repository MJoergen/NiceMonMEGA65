; The routines of BASIC's statements that replace the monitor's commands
; (issue #112, doc/BASIC.md, "The main loop"), which the Makefile joins
; after monitor.nasm (its header). basic.nasm scans a line, and calls
; each with its arguments in R1-R3: the numbers, and the word addresses of
; the strings, each ended by a 0. A routine here uses any register but
; SP, as BASIC's main loop starts again after it, and returns with RET.
; Its errors are a line it prints. The variables are in monitor.nasm,
; with the others.
;
; LOAD with no name, st_lines, writes words into the RAM from lines of
; ADDR WORD in hex, as a .bin file has them, typed or pasted, up to an
; empty line, so that a program is loaded with no host's tools and no
; storage. Each line is shown in one row of the screen, which the next
; line clears, and not on the line, so that no line scrolls the screen
; and a paste at 2 Mbaud keeps up. SYS, st_sys, calls a program at its
; address as a subroutine, with R1 = the entry of mon_putc, R2 = 0, R3 =
; 0, and E = 0 (ABI.md, "Programs under a monitor"), and at its return
; restores what mon_exit restores and shows the status. DIR lists the
; folder NICE of an SD card's FAT32 file system, LOAD "NAME.BIN" reads a
; .bin file from it as LOAD reads lines, SAVE writes one, and DELETE
; deletes a file, with monitor_fat.nasm, whose routines are also the
; entries 9 to 15, fs_mount, fs_open, fs_read, fs_readdir,
; fs_close, fs_write, and fs_delete (issues #58 and #59). TIME, the
; clock of the time of day, is clock_cmd of monitor_clock.nasm, which
; basic.nasm calls itself (issue #109). DIS, DHCP, NTP, and LOAD and DIR
; from a TFTP server are in monitor_dis.nasm and monitor_eth.nasm, and use
; the routines of this file.

RAM_WORDS       .EQU    0xFFFFFF9E      ; the words of the RAM, 0 in niceemu, where there is no limit
UART_BAUD       .EQU    0xFFFFFF9F      ; the UART's baud rate in bit/s, memory in niceemu
DUMP_WORDS      .EQU    32              ; the words that DUMP shows without a count
ROW_WORDS       .EQU    4               ; the words of a row of DUMP

; CLS: st_cls is scr_cls. VER: the version of the monitor, and that of
; the table, major.minor.
st_ver
                MOVE    R1, S_NAME
                CALL    puts_b
                MOVE    R1, VERSION
                CALL    puts_b
                MOVE    R1, S_TABLE
                CALL    puts_b
                SHR     R1, TABLE_VERSION, 16
                CALL    _io_putdec
                MOVE    R1, 0x2E        ; .
                CALL    mon_putc
                AND     R1, TABLE_VERSION, 0xFFFF
                CALL    _io_putdec
                JMP     _io_crlf        ; which returns to the caller

; HALT: the core halted, until the reset button, or a host starts it
st_halt
                MOVE    R1, S_HALTED
                CALL    puts_b_crlf
                HALT

; DUMP [ADDR] [, N]: R1 ADDR, R2 N, and R3 which of them were given, bit
; 0 for ADDR and bit 1 for N. N words from ADDR, in hex, ROW_WORDS to a
; row, each row with its address first. Without ADDR, the words after
; the last shown; without N, DUMP_WORDS. An N of 0 only moves the next
; DUMP to ADDR.
st_dump
                AND[M]  R0, R3, 1
        ?!Z     MOVE    @V_NEXT, R1
                AND[M]  R0, R3, 2
        ?Z      MOVE    R2, DUMP_WORDS
                MOVE[M] R8, R2          ; the words left
        ?Z      RET
                MOVE    R7, @V_NEXT     ; the next word
dump_row
                MOVE    R1, R7
                CALL    _io_puthex
                MOVE    R9, ROW_WORDS   ; the words left in the row
:
                MOVE    R1, 0x20
                CALL    mon_putc
                MOVE    R1, @R7++
                CALL    _io_puthex
                SUB[M]  R8, R8, 1
        ?Z      JMP     :+
                SUB[M]  R9, R9, 1
        ?!Z     JMP     :-
                CALL    _io_crlf
                JMP     dump_row
:
                MOVE    @V_NEXT, R7
                JMP     _io_crlf        ; which returns to the caller

; IP ["A.B.C.D"]: R1 the string, or 0. The Ethernet station's IP
; address (doc/SYSTEM.md, "The Ethernet station"), written from four
; decimal numbers of 0 to 255 with dots between them, and shown, in
; decimal with dots. Without the string it is only shown. Blanks may come
; before and after the address in the string, and anything else makes it
; no address, which is not written. A written address has no mask, no
; gateway, no DNS server, and no lease, which only DHCP gives.
st_ip
                TST     R1
        ?Z      JMP     ip_show         ; no address
:
                CMP     @R1, 0x20
        ?Z      ADD     R1, R1, 1
        ?Z      JMP     :-
                CALL    get_ip
                TST     R2
        ?Z      JMP     ip_bad
                MOVE    R7, R1
                CALL    rest_blank
        ?!Z     JMP     ip_bad
                MOVE    @E_IP, R7
                CLR     @V_MASK
                CLR     @V_GW
                CLR     @V_DNS
                CLR     @V_NTP
                CLR     @V_BSTATE       ; no DHCP in the background
                CALL    lease_forget
ip_show         MOVE    R1, S_IP
                MOVE    R2, @E_IP
                JMP     show_ip         ; which returns to the caller
ip_bad          MOVE    R1, S_BADIP
                JMP     puts_b_crlf     ; which returns to the caller

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

; show_ip: the string at R1, the IP address R2 in decimal with dots, and
; CR LF, with put_ip. Uses R1-R4, and R7 and R8 across the calls, saved.
show_ip
                CALL    put_ip
                JMP     _io_crlf        ; which returns to the caller

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
                CALL    mon_putc
                JMP     :-
:               POP     R8
                POP     R7
                RET

; BAUD [RATE]: R1 RATE, and R2 not 0 when it was given. The UART's baud
; rate (doc/DEBUG_LINK.md, "The baud rate"), written when RATE is one of
; the rates of BAUD_RATES, and shown. Without RATE it is only shown. A
; rate not in the list is not written. The monitor checks the list
; itself, as niceemu has memory at UART_BAUD. The UART takes the new rate
; once it has sent nothing for 1 ms, so what the monitor prints after the
; write, and READY., still go out at the old rate.
st_baud
                TST     R2
        ?Z      JMP     baud_show       ; no rate
                MOVE    R2, BAUD_RATES
:
                MOVE[M] R3, @R2++
        ?Z      JMP     baud_bad        ; not in the list
                CMP     R3, R1
        ?!Z     JMP     :-
                MOVE    @UART_BAUD, R1
baud_show
                MOVE    R1, S_BAUD
                CALL    puts_b
                MOVE    R1, @UART_BAUD
                CALL    _io_putdec
                JMP     _io_crlf        ; which returns to the caller
baud_bad
                MOVE    R1, S_BADBAUD
                JMP     puts_b_crlf     ; which returns to the caller

; MAC ["MAC"]: R1 the string, or 0. The Ethernet station's MAC address
; (doc/SYSTEM.md, "The Ethernet station"), written from six bytes of one
; or two hex digits, in either case, with colons between them, and shown,
; two hex digits a byte with colons. The first byte must be even, as bit
; 0 of it marks a group address, which is no station's. Without the
; string, or with blanks only in it, it is only shown. Blanks may come
; before and after the address in the string, and anything else makes it
; no address, which is not written. R7:R8 gather the address, a byte at a
; time, R9 counts the bytes left, and R10 points into the string.
st_mac
                MOVE[M] R2, R1
        ?Z      JMP     mac_show        ; no string
                CLR     R7
                CLR     R8
                MOVE    R9, 6
:
                CMP     @R2, 0x20
        ?Z      ADD     R2, R2, 1
        ?Z      JMP     :-
                TST     @R2
        ?Z      JMP     mac_show        ; no address
                MOVE    R10, R2
mac_byte
                CMP     @R10, 0x20      ; no blank inside the address
        ?Z      JMP     mac_bad
                MOVE    R1, R10
                CALL    _io_gethex
                MOVE    R10, R3
                SUB     R2, R2, 1
                CMP     R2, 2
        ?!C     JMP     mac_bad         ; no digit, or more than two
                SHR     R4, R8, 24      ; R7:R8 shifted by a byte, and R1 in
                SHL     R7, R7, 8
                OR      R7, R7, R4
                SHL     R8, R8, 8
                OR      R8, R8, R1
                SUB[M]  R9, R9, 1
        ?Z      JMP     :+
                CMP     @R10, 0x3A      ; :
        ?!Z     JMP     mac_bad
                ADD     R10, R10, 1
                JMP     mac_byte
:
                CMP     @R10, 0x20      ; blanks, then the end of the line
        ?Z      ADD     R10, R10, 1
        ?Z      JMP     :-
                TST     @R10
        ?!Z     JMP     mac_bad
                AND[M]  R0, R7, 0x100   ; bit 0 of the first byte: a group address
        ?!Z     JMP     mac_bad
                MOVE    @E_MACH, R7
                MOVE    @E_MACL, R8
; The bytes go out from the top of R7, and R8 fills R7 from below.
mac_show
                MOVE    R1, S_MAC
                CALL    puts_b
                AND     R7, @E_MACH, 0xFFFF
                SHL     R7, R7, 16
                MOVE    R8, @E_MACL
                SHR     R1, R8, 16
                OR      R7, R7, R1
                SHL     R8, R8, 16
                MOVE    R9, 6           ; the bytes left
:               SHR     R1, R7, 28      ; the top byte, a digit at a time
                CALL    mac_digit
                SHR     R1, R7, 24
                CALL    mac_digit
                SUB[M]  R9, R9, 1
        ?Z      JMP     :+
                SHR     R4, R8, 24
                SHL     R7, R7, 8
                OR      R7, R7, R4
                SHL     R8, R8, 8
                MOVE    R1, 0x3A        ; :
                CALL    mon_putc
                JMP     :-
:
                JMP     _io_crlf        ; which returns to the caller
mac_bad         MOVE    R1, S_BADMAC
                JMP     puts_b_crlf     ; which returns to the caller

; mac_digit: bits 3..0 of R1 as a hex digit
mac_digit
                AND     R1, R1, 0xF
                ADD     R1, R1, 0x30
                CMP     R1, 0x3A
        ?!C     ADD     R1, R1, 7       ; A to F
                JMP     mon_putc        ; which returns to the caller

; LOAD with no name: words into the memory from lines of ADDR WORD, two hex numbers of 1 to
; 8 digits with blanks between them and around them, as a .bin file has
; them (nice_cpu's ISA.md §10.4), up to an empty line or CTRL-C, which
; also drops the line it is in. CR, LF, and CR LF end a line, so a
; terminal's lines and a file's both serve; V_LEND starts as a CR, so
; that the LF of a terminal that ends the LOAD line itself with CR LF is
; the LF of that CR LF, not an empty line. A TAB is a blank, as niceemu
; takes it. A line of blanks only is passed over, as niceemu passes it,
; and counted as a line and not as skipped. A line with anything else, or
; with ADDR outside a program's RAM, PROGRAM up to V_PEND, is skipped:
; the RAM of a board repeats every RAM_WORDS words, so an address past it
; could reach the ROM or the monitor's variables and stack, which are at
; RAM_WORDS - VARS_WORDS and up of the RAM, 0x1F000 on the MEGA65 and
; 0xF000 on the Nexys4DDR. V_PEND is that address, or the screen where
; RAM_WORDS reads 0, as in niceemu. A line with more than blanks after
; its LINE_MAX characters is skipped too: the blanks after LINE_MAX are
; dropped, and the first key that is no blank is kept as 0x7F, which no
; line parses, at LINE_MAX, and not shown; a DEL takes it back, and the
; other keys after it are dropped. A second line for an address
; writes its word over the first's, where niceemu rejects the file. The
; count of the words written and the lowest and highest address are
; shown at the end, and the count of the skipped lines, the number of the
; first, and the last address that a line may have. DEL
; and BS delete the character before the cursor; the other control codes,
; the bytes from 0x80, and the escape sequences of the cursor and function
; keys are dropped. The lines are shown in row R7, which the hint leaves
; the cursor in, and only on the screen: each line clears the row, and its
; end is not shown, so the screen never scrolls. The counts are
; bin_line's, and R6 is the next free word of the line.
st_lines
                MOVE    R1, S_LHINT
                CALL    puts_b_crlf
                MOVE    @V_LOUT, @V_OUT
                MOVE    @V_OUT, OUT_SCREEN
                CALL    bin_init
                MOVE    @V_LEND, 0x0D   ; as after the CR of the LOAD line
                MOVE    R7, @V_ROW
load_line
                CALL    load_row
                MOVE    R6, V_LINE
load_key
                CALL    _io_getc
                MOVE    R2, @V_LEND
                MOVE    @V_LEND, R1
                CMP     R1, 0x0A
        ?!Z     JMP     :+
                CMP     R2, 0x0D
        ?Z      JMP     load_key        ; the LF of a CR LF
                JMP     load_end
:
                CMP     R1, 0x0D
        ?Z      JMP     load_end
                CMP     R1, 0x7F
        ?Z      JMP     load_del
                CMP     R1, 0x08
        ?Z      JMP     load_del
                CMP     R1, 0x03
        ?Z      JMP     load_done       ; CTRL-C
                CMP     R1, 0x1B
        ?Z      JMP     load_esc
                CMP     R1, 0x09
        ?Z      MOVE    R1, 0x20        ; a TAB is a blank
                CMP     R1, 0x20
        ?C      JMP     load_key        ; another control code
                CMP     R1, 0x80
        ?!C     JMP     load_key        ; 0x80 and above
                CMP     R6, V_LINE+LINE_MAX
        ?!C     JMP     :+              ; the line is full
                MOVE    @R6++, R1
                CALL    mon_putc
                JMP     load_key
:
                CMP     R1, 0x20
        ?Z      JMP     load_key        ; a blank after LINE_MAX, dropped
                MOVE    R6, V_LINE+LINE_MAX
                MOVE    @R6++, 0x7F     ; more after LINE_MAX: skipped
                JMP     load_key
load_del
                CMP     R6, V_LINE
        ?Z      JMP     load_key        ; nothing before the cursor
                SUB     R6, R6, 1
                CMP     R6, V_LINE+LINE_MAX
        ?Z      JMP     load_key        ; the 0x7F, which is not shown
                MOVE    R1, _io_gets.rub
                CALL    _io_puts
                JMP     load_key
; An ESC: with a [ or an O within io.t_esc, a sequence, whose bytes up to
; its final one, 0x40 to 0x7E, are dropped; another byte is dropped with
; the ESC.
load_esc
                CALL    _io_getc.soon
        ?Z      JMP     load_key
                CMP     R1, 0x5B        ; [
        ?Z      JMP     :+
                CMP     R1, 0x4F        ; O
        ?!Z     JMP     load_key
:
                CALL    _io_getc.soon
        ?Z      JMP     load_key
                CMP     R1, 0x40
        ?C      JMP     :-              ; a parameter byte
                JMP     load_key        ; the final byte
; The end of a line: an empty one ends the load, and another goes to
; bin_line
load_end
                CLR     @R6
                CMP     R6, V_LINE
        ?Z      JMP     load_done
                CALL    bin_line
                JMP     load_line

; bin_init: the counts of bin_line at V_LSTATS cleared, the lowest
; address 0xFFFFFFFF, V_LPOS at V_LINE, V_LEND 0, and V_PEND set with
; load_pend. Uses R1.
bin_init
                MOVE    R1, V_LSTATS
                CLR     @R1++
                NOT     @R1++, R0
                CLR     @R1++
                CLR     @R1++
                CLR     @R1++
                CLR     @R1++
                MOVE    @V_LPOS, V_LINE
                CLR     @V_LEND
                JMP     load_pend       ; which returns to the caller

; bin_char: the byte R1 of a file, from the card or a TFTP server, into
; the line at V_LPOS. CR, LF, or CR LF ends a line, which bin_eol takes.
; TAB is a blank, and a byte that is no character, any other control
; code, DEL, or one from 0x80, is kept as 0x7F, so that bin_line skips
; its line, as niceemu rejects it. The blanks after LINE_MAX are dropped,
; as niceemu ignores them, and the first other byte after it is kept as
; 0x7F at LINE_MAX, and the rest dropped. V_LEND is the byte before.
; Uses R1-R6.
bin_char
                MOVE    R2, @V_LEND
                MOVE    @V_LEND, R1
                CMP     R1, 0x0A
        ?!Z     JMP     :+
                CMP     R2, 0x0D
        ?Z      RET                     ; the LF of a CR LF
                JMP     bin_eol
:
                CMP     R1, 0x0D
        ?Z      JMP     bin_eol
                CMP     R1, 0x09
        ?Z      MOVE    R1, 0x20
                SUB     R2, R1, 0x20
                CMP     R2, 0x5F
        ?!C     MOVE    R1, 0x7F        ; no character: the line skipped
                MOVE    R6, @V_LPOS
                CMP     R6, V_LINE+LINE_MAX
        ?C      JMP     :+              ; room
                CMP     R6, V_LINE+LINE_MAX+1
        ?Z      RET                     ; the 0x7F is there already
                CMP     R1, 0x20
        ?Z      RET                     ; a blank after LINE_MAX, dropped
                MOVE    R1, 0x7F        ; more after LINE_MAX: skipped
:
                MOVE    @R6++, R1
                MOVE    @V_LPOS, R6
                RET
; bin_last: the last line of a file, when it has no end, to bin_eol
bin_last
                CMP     @V_LPOS, V_LINE
        ?Z      RET
; bin_eol: the line at V_LINE, up to V_LPOS, shown for a listing of
; TFTP, when V_TLIST is not 0, or else to bin_line, or counted and passed
; over when it is empty. Uses R1-R6.
bin_eol
                MOVE    R6, @V_LPOS
                MOVE    @V_LPOS, V_LINE
                CLR     @R6
                MOVE    R1, V_LINE
                TST     @V_TLIST
        ?!Z     JMP     puts_crlf       ; a line of a listing, shown
                CMP     R6, V_LINE
        ?!Z     JMP     bin_line        ; which returns to the caller
                ADD     @V_LSTATS+5, @V_LSTATS+5, 1  ; an empty line, passed over
                RET

; bin_line: the line at V_LINE, which ends at R6 with a 0, of LOAD, with
; 0x7F at LINE_MAX when it had more than blanks after LINE_MAX
; characters, so that it is skipped: counted at V_LSTATS+5, passed over
; when it has blanks only, or else parsed, and its word written, counted
; at V_LSTATS, with the lowest and highest address at V_LSTATS+1 and +2,
; or skipped, counted at V_LSTATS+3, with the number of the first at
; V_LSTATS+4. Uses R1-R6.
bin_line
                ADD     @V_LSTATS+5, @V_LSTATS+5, 1
                MOVE    R1, V_LINE
                CALL    _io_gethex      ; R1 the address, R2 its digits, R3 after it
                TST     R2
        ?!Z     JMP     :+
                TST     @R3
        ?Z      RET                     ; blanks only
:
                SUB     R4, R2, 1
                CMP     R4, 8
        ?!C     JMP     bin_bad         ; no digit, or more than 8
                CMP     R1, PROGRAM
        ?C      JMP     bin_bad         ; in the ROM
                CMP     R1, @V_PEND
        ?!C     JMP     bin_bad         ; the variables, or past the RAM
                MOVE    R6, R1
                MOVE    R1, R3
                CALL    _io_gethex      ; R1 the word
                SUB     R4, R2, 1
                CMP     R4, 8
        ?!C     JMP     bin_bad
:
                CMP     @R3, 0x20
        ?Z      ADD     R3, R3, 1
        ?Z      JMP     :-
                TST     @R3
        ?!Z     JMP     bin_bad         ; more after the word
                MOVE    @R6, R1
                ADD     @V_LSTATS, @V_LSTATS, 1
                CMP     R6, @V_LSTATS+1
        ?C      MOVE    @V_LSTATS+1, R6  ; a lower address
                CMP     @V_LSTATS+2, R6
        ?C      MOVE    @V_LSTATS+2, R6  ; a higher one
                RET
bin_bad
                TST     @V_LSTATS+3
        ?Z      MOVE    @V_LSTATS+4, @V_LSTATS+5
                ADD     @V_LSTATS+3, @V_LSTATS+3, 1
                RET
; The end of the load: the row blank again, the outputs back, the words
; written, and the lines skipped
load_done
                CALL    load_row
                MOVE    @V_OUT, @V_LOUT
load_summary
                MOVE    R1, S_LOADED
                CALL    puts_b
                MOVE    R1, @V_LSTATS
                CALL    _io_putdec
                TST     @V_LSTATS
        ?Z      JMP     :+
                MOVE    R1, S_LFROM
                CALL    puts_b
                MOVE    R1, @V_LSTATS+1
                CALL    _io_puthex
                MOVE    R1, S_LTO
                CALL    puts_b
                MOVE    R1, @V_LSTATS+2
                CALL    _io_puthex
:
                CALL    _io_crlf
                TST     @V_LSTATS+3
        ?Z      RET
                MOVE    R1, S_SKIPPED
                CALL    puts_b
                MOVE    R1, @V_LSTATS+3
                CALL    _io_putdec
                MOVE    R1, S_FIRST
                CALL    puts_b
                MOVE    R1, @V_LSTATS+4
                CALL    _io_putdec
                MOVE    R1, S_LFORM
                CALL    puts_b
                SUB     R1, @V_PEND, 1
                CALL    _io_puthex
                JMP     _io_crlf        ; which returns to the caller

; load_pend: V_PEND, the end of a program's RAM, where the variables
; start, from the size of the RAM, or the screen in niceemu. Uses R1.
load_pend
                MOVE[M] R1, @RAM_WORDS
        ?Z      MOVE    R1, SCREEN+VARS_WORDS  ; no limit
                SUB     @V_PEND, R1, VARS_WORDS
                RET

; DIR [SLOT]: R1 the slot, or 0xFFFFFFFF without it. The folder NICE of
; the card in SLOT, mounted first, or of the card mounted, with fat_dir of
; monitor_fat.nasm.
st_dir
                CALL    fat_dir
                TST     R1
        ?N      JMP     fs_fail
                RET

; LOAD "NAME.BIN": R1 the name. The .bin file NAME.BIN of the card's
; folder NICE, read with fat_load of monitor_fat.nasm, whose bytes go to
; bin_char, and shown as st_lines shows its lines. basic.nasm has
; checked the name's .BIN.
st_load
                CLR     R2              ; to read
                CALL    fs_open
                TST     R1
        ?N      JMP     fs_fail
                MOVE    R8, R1          ; the handle
                CALL    bin_init
                CLR     @V_TLIST        ; no listing
                MOVE    R1, R8
                CALL    fat_load
                MOVE    R9, R1
                MOVE    R1, R8
                CALL    fs_close
                MOVE    R1, R9
                TST     R1
        ?N      JMP     fs_fail
                JMP     load_summary

; SAVE "NAME", ADDR, N: R1 the name, R2 ADDR, and R3 N. The N words from
; ADDR written to the file NAME of the card's folder, which is made or
; truncated, as a .bin file, with fat_save of monitor_fat.nasm, and the words saved
; shown as LOAD shows those loaded. basic.nasm has added .BIN to a name
; without an extension.
st_save
                MOVE    R7, R1          ; the name
                MOVE    R9, R2
                MOVE    R10, R3
                MOVE    R2, 1           ; to write
                CALL    fs_open
                TST     R1
        ?N      JMP     fs_fail
                MOVE    R8, R1          ; the handle
                MOVE    R2, R9
                MOVE    R3, R10
                CALL    fat_save
                MOVE    R11, R1
                MOVE    R1, R8
                CALL    fs_close
                TST     R11
        ?N      MOVE    R1, R11         ; the error of the save, before the close's
                TST     R1
        ?N      JMP     fs_fail
                MOVE    R1, S_SAVED
                CALL    puts_b
                MOVE    R1, R10
                CALL    _io_putdec
                TST     R10
        ?Z      JMP     :+
                MOVE    R1, S_LFROM
                CALL    puts_b
                MOVE    R1, R9
                CALL    _io_puthex
                MOVE    R1, S_LTO
                CALL    puts_b
                ADD     R1, R9, R10
                SUB     R1, R1, 1
                CALL    _io_puthex
:
                JMP     _io_crlf        ; which returns to the caller

; DELETE "NAME": R1 the name. The file NAME of the card's folder deleted,
; with fs_delete of monitor_fat.nasm.
st_delete
                MOVE    R7, R1          ; the name
                CALL    fs_delete
                TST     R1
        ?N      JMP     fs_fail
                MOVE    R1, S_DELETED
                CALL    puts_b
                MOVE    R1, R7
                JMP     puts_crlf       ; which returns to the caller

; complete: TAB on the line, for _io_gets: R1 the line, R2 the cursor, R3
; the word after the last, and R1 = the new cursor, with fat_complete of
; monitor_fat.nasm (issue #137). When it lists the matches, the line is shown
; again. Uses R1-R6, and R7 and R8 across the calls, saved.
complete
                PUSH    R7
                PUSH    R8
                MOVE    R7, R1          ; the line
                MOVE    R8, R2          ; the cursor
                CALL    fat_complete
                TST     R1
        ?!Z     JMP     complete_end
:
                CMP     R7, R8
        ?Z      JMP     :+
                MOVE    R1, @R7++
                CALL    _mon_putc
                JMP     :-
:
                MOVE    R1, R8
complete_end
                POP     R8
                POP     R7
                RET

; rest_blank: Z when the line from R3 has only blanks. Uses R3.
rest_blank
                CMP     @R3, 0x20
        ?Z      ADD     R3, R3, 1
        ?Z      JMP     rest_blank
                TST     @R3
                RET

; fs_fail: an error of monitor_fat.nasm, R1 its negative: one of the SD controller's
; as sd_fail shows it, with the selected slot, or a file error, its number and
; its meaning
fs_fail
                CMP     R1, 0xFFFFFFF8  ; -8
        ?C      JMP     :+              ; below -8
                MOVE    R7, @SD_SELECT
                JMP     sd_fail
:
                SUB     R8, R0, R1      ; the error
                MOVE    R1, S_FSERR
                CALL    puts_b
                MOVE    R1, R8
                CALL    _io_putdec
                SUB     R1, R8, FS_ERR0
                CMP     R1, FS_ERRS
        ?!C     JMP     :+              ; an error without a meaning here
                ADD     R1, R1, FS_ERRORS
                MOVE    R7, @R1
                MOVE    R1, S_UCOMMA
                CALL    puts_b
                MOVE    R1, R7
                CALL    puts_b
:
                JMP     _io_crlf        ; which returns to the caller

; load_row: row R7 blank in the current color, and the cursor at its column
; 0. Uses R1-R3.
load_row
                SHL     R2, R7, 6
                SHL     R1, R7, 4
                ADD     R1, R1, R2
                ADD     R1, R1, SCREEN
                OR      R3, @V_COLOR, 0x20
                MOVE    R2, 80
:
                MOVE    @R1++, R3
                SUB[M]  R2, R2, 1
        ?!Z     JMP     :-
                CLR     @V_COL
                MOVE    @V_ROW, R7
                JMP     putc_cur

; SYS ADDR: R1 ADDR. The program at ADDR called as ABI.md says, on this
; stack: the return address is pushed, and the program returns with RET
; and its status in R1, which is shown, with what mon_exit restores
; restored. A word of 0 at ADDR is no program: it is NOP, which no
; start-up code begins with. SYS 0 is entry 0 of the dispatch table, the
; cold start. A program that ends with mon_exit goes back to READY. from
; there.
st_sys
                MOVE    R7, R1
                TST     @R7
        ?Z      JMP     :+
                MOVE    R1, MON_PUTC    ; the entry of mon_putc (mon.nasm)
                CLR     R2              ; argc
                CLR     R3              ; argv
                CALL    R7
                JMP     sys_end         ; with the status in R1
:
                MOVE    R1, S_NOPROG
                CALL    puts_b
                MOVE    R1, R7
                CALL    _io_puthex
                JMP     _io_crlf        ; which returns to the caller

; puts_lines: the strings of the table at R1, each with CR LF after it, up
; to a 0 word. Uses R7 across the calls, saved.
puts_lines
                PUSH    R7
                MOVE    R7, R1
lines           MOVE[M] R1, @R7++
        ?Z      POP     R7
        ?Z      RET
                CALL    puts_b_crlf
                JMP     lines

S_NAME          .ASCII_B 'NiceMon '
                .DAT    0
S_TABLE         .ASCII_B ', dispatch table '
S_HALTED
                .ASCII_B 'Halted'
S_NOPROG
                .ASCII_B 'No program at '
S_IP            .ASCII_B 'IP address '
S_MAC           .ASCII_B 'MAC address '
                .DAT    0
S_BAUD          .ASCII_B 'Baud rate '
S_LHINT         .ASCII_B 'ADDR WORD in hex on each line, as in a .bin file; an empty line ends'
                .DAT    0
S_LOADED
                .ASCII_B 'Words loaded: '
S_LFROM         .ASCII_B ', '
S_LTO           .ASCII_B ' to '
                .DAT    0
S_SKIPPED
                .ASCII_B 'Lines skipped: '
S_FIRST         .ASCII_B ', first line '
S_LFORM         .ASCII_B '; ADDR WORD in hex, ADDR 00008000 to '
S_BADIP         .ASCII_B 'Not an IP address: four numbers from 0 to 255, with dots between them'
S_BADMAC
                .ASCII_B 'Not a MAC address: six bytes in hex with colons, the first one even'
S_BADBAUD
                .ASCII_B 'Not a baud rate: 115200, 230400, 460800, 921600, 1000000, 1500000, or 2000000'
; The rates that UART_BAUD takes, and a 0
BAUD_RATES
                .DAT    115200, 230400, 460800, 921600, 1000000, 1500000, 2000000, 0
S_FSERR         .ASCII_B 'File error '
S_SAVED         .ASCII_B 'Words saved: '
S_DELETED
                .ASCII_B 'Deleted '
                .DAT    0
; The meanings of monitor_fat.nasm's errors FS_ERR0 to FS_ERR0 + FS_ERRS - 1.
; E_FS29 names the folder of the build, so the Makefile writes it, in
; build/folder.nasm.
FS_ERRORS
                .DAT    E_FS16, E_FS17, E_FS18, E_FS19, E_FS20, E_FS21, E_FS22
                .DAT    E_FS23, E_FS24, E_FS25, E_FS26, E_FS27, E_FS28, E_FS29
                .DAT    E_FS30, E_FS31, E_FS32
FS_ERR0         .EQU    16
FS_ERRS         .EQU    17
E_FS16          .ASCII_B 'no FAT32 file system'
                .DAT    0
E_FS17          .ASCII_B 'FAT12, which is not supported'
E_FS18          .ASCII_B 'FAT16, which is not supported'
E_FS19          .ASCII_B 'exFAT, which is not supported'
E_FS20          .ASCII_B 'not a valid name'
                .DAT    0
E_FS21          .ASCII_B 'no such file'
                .DAT    0
E_FS22          .ASCII_B 'a directory'
E_FS23          .ASCII_B 'too many open files'
E_FS24          .ASCII_B 'not an open file'
                .DAT    0
E_FS25          .ASCII_B 'no such mode'
                .DAT    0
E_FS26          .ASCII_B 'the FAT is damaged'
E_FS27          .ASCII_B 'no such slot'
                .DAT    0
E_FS28          .ASCII_B 'the card has changed'
                .DAT    0
E_FS30          .ASCII_B 'the card or the folder is full'
E_FS31          .ASCII_B 'the file is open'
                .DAT    0
E_FS32          .ASCII_B 'the file is read-only'
