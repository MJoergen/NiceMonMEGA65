; The routines of BASIC's statements that replace the monitor's commands
; (issue #112, doc/BASIC.md, "The main loop"), which the Makefile joins
; after basic.nasm (its header). basic.nasm scans a line, and calls
; each with its arguments in R1-R3: the numbers, and the word addresses of
; the strings, each ended by a 0. A routine here uses any register but
; SP, as BASIC's main loop starts again after it, and returns with RET.
; Its errors are a line it prints. The variables are in basic.nasm.
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
; .bin file from it as LOAD reads lines, SAVE writes one, LOAD "NAME"
; and SAVE "NAME" read and write a program's text (issue #60), and
; DELETE deletes a file, with monitor_fat.nasm, whose routines are also the
; entries 9 to 15, fs_mount, fs_open, fs_read, fs_readdir,
; fs_close, fs_write, and fs_delete (issues #58 and #59). TIME, the
; clock of the time of day, is clock_cmd of basic_time.nasm, which
; basic.nasm calls itself (issue #109). DIS, DHCP, NTP, and LOAD and DIR
; from a TFTP server are in basic_dis.nasm and basic_net.nasm, and use
; the routines of this file. All of them reach the monitor through the
; entries of the dispatch table alone (issue #152).

UART_BAUD       .EQU    0xFFFFFF9F      ; the UART's baud rate in bit/s, memory in niceemu
DUMP_WORDS      .EQU    32              ; the words that DUMP shows without a count
DIR_NAME        .EQU    24              ; DIR's column of the sizes
FBUF_BYTES      .EQU    128             ; the bytes of a read of LOAD, the words of V_FBUF
ROW_WORDS       .EQU    4               ; the words of a row of DUMP

; CLS: scr_cls, entry 5. VER: the versions of the monitor and BASIC, and that of
; the table, major.minor, from mon_version, entry 2.
st_ver
                CALL    versions
                MOVE    R1, S_TABLE
                CALL    puts_b
                CALL    MON_VERSION
                MOVE    R7, R1
                SHR     R1, R7, 16
                CALL    _io_putdec
                MOVE    R1, 0x2E        ; .
                CALL    MON_PUTC
                AND     R1, R7, 0xFFFF
                CALL    _io_putdec
                JMP     _io_crlf        ; which returns to the caller

; versions: the monitor's version, from mon_build, entry 37, and BASIC's,
; as the banner shows them: NiceMon V2.3.1, BASIC V2.3.2 (issue #153).
; Uses R1-R6.
versions
                MOVE    R1, S_NAME
                CALL    puts_b
                CALL    MON_BUILD
                CALL    puts_b
                MOVE    R1, S_BASIC
                CALL    puts_b
                MOVE    R1, VERSION
                JMP     puts_b          ; which returns to the caller

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
                CALL    MON_PUTC
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
; no address, which is not written. The address is written with
; net_set, entry 22, with no mask, no gateway, and no DNS server, and so
; with no lease, which only DHCP gives.
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
                MOVE    R1, V_NET
                MOVE    @R1++, R7
                CLR     @R1++
                CLR     @R1++
                CLR     @R1
                MOVE    R1, V_NET
                CALL    NET_SET
ip_show         MOVE    R1, S_IP
                MOVE    R2, @E_IP
                JMP     show_ip         ; which returns to the caller
ip_bad          MOVE    R1, S_BADIP
                JMP     puts_b_crlf     ; which returns to the caller

; show_ip: the string at R1, the IP address R2 in decimal with dots, and
; CR LF, with put_ip. Uses R1-R4, and R7 and R8 across the calls, saved.
show_ip
                CALL    put_ip
                JMP     _io_crlf        ; which returns to the caller

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
; string it is only shown; an empty one is no address, as for IP. Blanks may come
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
                CALL    MON_PUTC
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
                JMP     MON_PUTC        ; which returns to the caller

; LOAD with no name: words into the memory from lines of ADDR WORD, two
; hex numbers of 1 to 8 digits with blanks between them and around them,
; as a .bin file has them (nice_cpu's ISA.md §10.4), which bin_line,
; entry 33, parses and writes, up to an empty line or CTRL-C, which
; also drops the line it is in. CR, LF, and CR LF end a line, so a
; terminal's lines and a file's both serve; V_LEND starts as a CR, so
; that the LF of a terminal that ends the LOAD line itself with CR LF is
; the LF of that CR LF, not an empty line. A TAB is a blank, as niceemu
; takes it. A line of blanks only is passed over, as niceemu passes it,
; and counted as a line and not as skipped. A line with anything else, or
; with ADDR outside a program's RAM, is skipped. A line with more than
; blanks after its LINE_MAX characters is skipped too: the blanks after
; LINE_MAX are dropped, and the first key that is no blank is kept as
; 0x7F, which no line parses, at LINE_MAX, and not shown; a DEL takes it
; back, and the other keys after it are dropped. A second line for an
; address writes its word over the first's, where niceemu rejects the
; file. The count of the words written and the lowest and highest
; address are shown at the end, and the count of the skipped lines, the
; number of the first, and the last address that a line may have. DEL
; and BS delete the character before the cursor; the other control codes,
; the bytes from 0x80, and the escape sequences of the cursor and function
; keys are dropped. The lines are shown in row R7, which the hint leaves
; the cursor in, and only on the screen: each line clears the row, and its
; end is not shown, so the screen never scrolls. The counts are
; bin_line's, at V_LSTATS, and R6 is the next free word of the line.
st_lines
                MOVE    R1, S_LHINT
                CALL    puts_b_crlf
                MOVE    R1, MON_OUT_SCREEN
                CALL    MON_OUT
                MOVE    @V_LOUT, R1
                CALL    bin_init
                MOVE    @V_LEND, 0x0D   ; as after the CR of the LOAD line
                CALL    SCR_GETXY
                MOVE    R7, R2          ; the row
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
                CALL    MON_PUTC
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
                CALL    bin_call
                JMP     load_line

; bin_call: the line at V_LINE to bin_line, entry 33, with the counts at
; V_LSTATS. Uses R1-R6.
bin_call
                MOVE    R1, V_LINE
                MOVE    R2, V_LSTATS
                JMP     BIN_LINE        ; which returns to the caller

; bin_init: the 7 counts of bin_line at V_LSTATS cleared, the line at
; V_LBEG, V_LINE, or V_BLINE for a program's text, with its limit at
; V_LLIM, V_LPOS at it, and V_LEND 0. Uses R1 and R2.
bin_init
                MOVE    R1, V_LSTATS
                MOVE    R2, 7
:
                CLR     @R1++
                SUB[M]  R2, R2, 1
        ?!Z     JMP     :-
                MOVE    R1, V_LINE
                MOVE    R2, V_LINE+LINE_MAX
                TST     @V_LBAS
        ?!Z     MOVE    R1, V_BLINE
        ?!Z     MOVE    R2, V_BLINE+BLINE_MAX
                MOVE    @V_LBEG, R1
                MOVE    @V_LLIM, R2
                MOVE    @V_LPOS, R1
                CLR     @V_LEND
                RET

; bin_char: the byte R1 of a file, from the card or a TFTP server, into
; the line at V_LPOS. CR, LF, or CR LF ends a line, which bin_eol takes.
; TAB is a blank, and a byte that is no character, any other control
; code, DEL, or one from 0x80, is kept as 0x7F, so that bin_line skips
; its line, as niceemu rejects it, and the tokenizer fails it. The blanks
; after the line's limit, V_LLIM, are dropped, as niceemu ignores them,
; and the first other byte after it is kept as 0x7F at the limit, and
; the rest dropped. V_LEND is the byte before. A listing of TFTP, when
; V_TLIST is not 0, is shown and not parsed, so it has no 0x7F, which a
; terminal on the line may take as a DEL: a byte that is no character is
; dropped, and the line keeps one character at the limit, LINE_MAX + 1
; in all, and no more. Uses R1-R6.
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
        ?C      JMP     :+              ; a character
                TST     @V_TLIST
        ?!Z     RET                     ; none, of a listing: dropped
                MOVE    R1, 0x7F        ; no character: the line skipped
:
                MOVE    R6, @V_LPOS
                MOVE    R3, @V_LLIM
                CMP     R6, R3
        ?C      JMP     :+              ; room
        ?!Z     RET                     ; the limit's word is taken already
                TST     @V_TLIST
        ?!Z     JMP     :+              ; a listing: one more, as it is
                CMP     R1, 0x20
        ?Z      RET                     ; a blank after LINE_MAX, dropped
                MOVE    R1, 0x7F        ; more after LINE_MAX: skipped
:
                MOVE    @R6++, R1
                MOVE    @V_LPOS, R6
                RET
; bin_last: the last line of a file, when it has no end, to bin_eol
bin_last
                CMP     @V_LPOS, @V_LBEG
        ?Z      RET
; bin_eol: the line at V_LBEG, up to V_LPOS, stored by bas_eol for a
; program's text, shown for a listing of TFTP, when V_TLIST is not 0, or
; else to bin_line, or counted and passed over when it is empty. Uses
; R1-R6, and keeps the others.
bin_eol
                MOVE    R6, @V_LPOS
                MOVE    @V_LPOS, @V_LBEG
                CLR     @R6
                TST     @V_LBAS
        ?!Z     JMP     bas_eol
                MOVE    R1, V_LINE
                TST     @V_TLIST
        ?!Z     JMP     puts_crlf       ; a line of a listing, shown
                CMP     R6, V_LINE
        ?!Z     JMP     bin_call        ; which returns to the caller
                ADD     @V_LSTATS+5, @V_LSTATS+5, 1  ; an empty line, passed over
                RET

; The end of the load: the row blank again, the outputs back, the words
; written, and the lines skipped
load_done
                CALL    load_row
                MOVE    R1, @V_LOUT
                CALL    MON_OUT
load_summary
                TST     @V_LBAS
        ?!Z     RET                     ; a program's text: no summary
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
                SUB     R1, @V_LSTATS+6, 1
                CALL    _io_puthex
                JMP     _io_crlf        ; which returns to the caller

; load_part: the summary of a LOAD from a file that an error ends, when
; it read a line, so that the words that it wrote are known, but not for
; a listing of TFTP; R1 kept, for the error that follows.
load_part
                CALL    load_new
                TST     @V_LSTATS+5
        ?Z      RET
                TST     @V_TLIST
        ?!Z     RET
                PUSH    R1
                CALL    load_summary
                POP     R1
                RET

; DIR [SLOT] and DIR "PATH": R1 the slot, or one from 2^31 without it,
; and R4 the path, or 0. The folder NICE of the card in SLOT, mounted
; first with fs_mount, entry 9, or of the card mounted, or its folder
; PATH (issue #168), opened with fs_open, entry 10, in mode 2, and read
; with fs_readname, entry 20: a row with its name, NICE/ and the path
; without a leading /, and the slot, then a row for each file,
; its name, the long name or the 8.3 name, in DIR_NAME columns and its
; size in decimal in 12, and for each directory, its name and <DIR>,
; then the numbers of both. A name of DIR_NAME characters or more has a
; row of its own. R8 is the folder's handle, and R9 and R10 count the
; files and the directories.
st_dir
                PUSH    R4              ; the path
                TST     R1
        ?N      JMP     :+
                CALL    FS_MOUNT
                TST     R1
        ?N      JMP     io_fail
:
                MOVE[M] R1, @SP
        ?Z      MOVE    R1, V_ENT
        ?Z      CLR     @R1             ; the folder's name, empty
                MOVE    R2, 2
                CALL    FS_OPEN
                TST     R1
        ?N      JMP     io_fail
                MOVE    R8, R1
                CLR     R9
                CLR     R10
                MOVE    R1, S_DIROF
                CALL    puts_b
                POP     R7
                TST     R7
        ?Z      JMP     :++
                CMP     @R7, 0x2F
        ?Z      ADD     R7, R7, 1       ; without a leading /
                TST     @R7
        ?Z      JMP     :++
                MOVE    R1, 0x2F
:
                CALL    MON_PUTC
                MOVE[M] R1, @R7++
        ?!Z     JMP     :-
:
                MOVE    R1, S_INSLOT
                CALL    puts_b
                MOVE    R1, @SD_SELECT  ; the mounted slot, as a mount is
                CALL    _io_putdec      ; dropped when another is selected
                CALL    _io_crlf
dir_row
                MOVE    R1, R8
                MOVE    R2, V_ENT
                MOVE    R3, V_NAME
                CALL    FS_READNAME
                TST     R1
        ?N      JMP     fs_close_fail
        ?Z      JMP     dir_end
                MOVE    R7, V_NAME
:               MOVE[M] R1, @R7++
        ?Z      JMP     :+
                CALL    MON_PUTC
                JMP     :-
:               SUB     R7, R7, V_NAME+1
                CMP     R7, DIR_NAME
        ?!C     CLR     R7
        ?!C     CALL    _io_crlf
:               CMP     R7, DIR_NAME
        ?Z      JMP     :+
                MOVE    R1, 0x20
                CALL    MON_PUTC
                MOVE    R7++, R7
                JMP     :-
:               SHR     R1, @V_ENT+2, 24  ; the attributes
                AND[M]  R0, R1, 0x10
        ?Z      JMP     :+
                MOVE    R1, S_DIRTAG
                CALL    puts_b
                MOVE    R10++, R10
                JMP     :++
:               MOVE    R1, @V_ENT+3    ; the size
                CALL    decimal
                MOVE    R9++, R9
:               CALL    _io_crlf
                JMP     dir_row
dir_end
                MOVE    R1, R8
                CALL    FS_CLOSE
                MOVE    R1, S_FILES
                CALL    puts_b
                MOVE    R1, R9
                CALL    _io_putdec
                MOVE    R1, S_DIRS
                CALL    puts_b
                MOVE    R1, R10
                CALL    _io_putdec
                JMP     _io_crlf        ; which returns to the caller

; fs_close_fail: the handle R8 closed, and the error R1 raised with
; io_fail (basic_trap.nasm)
fs_close_fail
                MOVE    R7, R1
                MOVE    R1, R8
                CALL    FS_CLOSE
                MOVE    R1, R7
                JMP     io_fail

; decimal: R1 in decimal, unsigned, right-aligned in 12 columns. Uses R1-R6.
decimal
                MOVE    R5, R1
                MOVE    R6, 12
                MOVE    @io.mpu_b, 10
:               MOVE    @io.mpu_a, R1
                SUB     R6, R6, 1
                MOVE[M] R1, @io.mpu_udivq
        ?!Z     JMP     :-
:               TST     R6
        ?Z      JMP     :+
                MOVE    R1, 0x20
                CALL    MON_PUTC
                SUB     R6, R6, 1
                JMP     :-
:               MOVE    R1, R5
                JMP     _io_putdec

; LOAD "NAME.BIN": R1 the name. The .bin file NAME.BIN of the card's
; folder NICE, opened with fs_open, entry 10, and read with fs_read,
; entry 11, FBUF_BYTES bytes at a time into V_FBUF, whose bytes go to
; bin_char, up to its end, and its last line to bin_last, so that its
; lines of ADDR WORD are written and counted as LOAD with no name writes
; them, but that an empty line is passed over, the end of the file ends
; the load, and a line with a byte that is no character is skipped. They
; are shown as st_lines shows its lines; an error after a line shows
; them before it, with load_part, and leaves the words of the lines
; before it written. The reads start at 0 and a sector has 512 bytes,
; so an error of a sector or a cluster comes at the start of a read, and
; no byte before it is lost. basic.nasm has checked the name's .BIN,
; or set V_LBAS for a program's text, whose lines bas_eol stores. R8 is
; the handle, R9 the bytes left of a read, and R10 the next.
st_load
                CLR     R2              ; to read
                CALL    FS_OPEN
                TST     R1
        ?N      JMP     io_fail
                MOVE    R8, R1          ; the handle
                ADD     @V_OPEN, R1, 1  ; for files_end, at an error of a line
                CALL    bin_init
                CLR     @V_TLIST        ; no listing
load_read
                MOVE    R1, R8
                MOVE    R2, V_FBUF
                MOVE    R3, FBUF_BYTES
                CALL    FS_READ
                MOVE[M] R9, R1
        ?N      JMP     :++             ; an error
        ?Z      JMP     :+              ; the end
                MOVE    R10, V_FBUF
load_byte
                MOVE    R1, @R10++
                CALL    bin_char
                SUB[M]  R9, R9, 1
        ?!Z     JMP     load_byte
                JMP     load_read
:
                CALL    bin_last
                CLR     R9
:
                CLR     @V_OPEN
                MOVE    R1, R8
                CALL    FS_CLOSE
                MOVE    R1, R9
                TST     R1
        ?!N     JMP     load_summary
                CALL    load_part
                JMP     io_fail

; BSAVE "NAME", ADDR, N [, "IP"]: R1 the name, R2 ADDR, R3 N, and R4 the
; string of the TFTP server, or 0. The N words from ADDR written with
; out_file, to the file NAME of the card's folder or to the server, as a
; .bin file: lines of ADDR WORD in 8 hex digits each, in lower case,
; ended by LF, as niceasm writes a .bin file, and the words saved shown
; as LOAD shows those loaded. When the card fills up, the file keeps
; what fitted, and the error is 30. basic.nasm has added .BIN to a name
; without an extension. R9 is ADDR and R10 N.
st_save
                MOVE    R9, R2
                MOVE    R10, R3
                MOVE    R2, R4
                MOVE    R12, save_lines
                CALL    out_file
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

; save_lines: the lines of st_save, the words R10 from R9, 18 bytes each,
; into V_FBUF from V_SPOS, which flush writes when another line would
; not fit there, up to the first error of a write. Keeps R9 and R10.
; Uses R1-R7 and R12.
save_lines
                MOVE    R12, R9
                MOVE    R7, R10
:
                TST     R7
        ?Z      RET
                MOVE    R2, @V_SPOS
                MOVE    R1, R12
                CALL    hex8
                MOVE    @R2++, 0x20
                MOVE    R1, @R12
                CALL    hex8
                MOVE    @R2++, 0x0A
                MOVE    @V_SPOS, R2
                MOVE    R12++, R12
                SUB     R7, R7, 1
                CMP     R2, V_FBUF+FBUF_BYTES-17
        ?!C     CALL    flush           ; no room for 18 bytes more
                TST     @V_SERR
        ?Z      JMP     :-
                RET

; bas_eol: a line of a program's text, at V_BLINE up to R6, from LOAD
; "NAME" or RUN "NAME". A line of blanks only is passed over, and one that
; starts with a number is stored, with enter_store (basic_prog.nasm), as
; a line typed in is, after a NEW at the first. Any other line, one with
; a 0x7F of bin_char, and one that cannot be stored, is an error, which
; ends the load: err shows the line after the error, and main closes the
; file with files_end. The lines before it stay. From the NEW on, the
; load is no running program (bas_load), so that no TRAP takes its
; errors; before it the program is whole, and the line that runs stays,
; also over a line of blanks and a first line that is an error. Keeps
; R7-R12, which st_load and st_tftp use.
bas_eol
                MOVE    R5, V_BLINE
:
                MOVE[M] R1, @R5++
        ?Z      JMP     :+
                CMP     R1, 0x7F
        ?!Z     JMP     :-
                CMP     R5, V_BLINE+BLINE_MAX+1
        ?Z      JMP     err_long        ; the 0x7F after the limit
                JMP     err_char
:
                MOVE    R5, V_BLINE
:
                CMP     @R5, 0x20
        ?Z      MOVE    R5++, R5
        ?Z      JMP     :-
                TST     @R5
        ?Z      RET                     ; blanks only
                SUB     R1, @R5, 0x30
                CMP     R1, 10
        ?!C     JMP     err_nonum
                CMP     @V_LBAS, 1      ; the first line:
        ?Z      CLR     @V_CUR          ; direct mode, which keeps the flags,
        ?Z      CALL    new_prog        ; and NEW
                MOVE    @V_LBAS, 2
                PUSH    R7
                PUSH    R8
                PUSH    R9
                PUSH    R10
                PUSH    R11
                PUSH    R12
                CALL    enter_store
                POP     R12
                POP     R11
                POP     R10
                POP     R9
                POP     R8
                POP     R7
                RET

; show_bline: the line of a program's text that an error ended LOAD at,
; at V_BLINE, without its 0x7F, and CR LF. Uses R1-R4, and R7, saved.
show_bline
                PUSH    R7
                MOVE    R7, V_BLINE
:
                MOVE[M] R1, @R7++
        ?Z      JMP     :+
                CMP     R1, 0x7F
        ?!Z     CALL    MON_PUTC
                JMP     :-
:
                POP     R7
                JMP     _io_crlf        ; which returns to the caller

; SAVE "NAME" [, "IP"]: R1 the name, with .BAS when it had no dot, and
; R2 the string of the TFTP server, or 0. The program written with
; out_file, to the file NAME of the card's folder or to the server, as
; the text that LIST gives, each line ended by LF, as niceasm's .bin
; files are. The break key ends the SAVE at its line, and main closes
; the file with files_end.
st_text
                MOVE    R12, text_lines
                JMP     out_file        ; which returns to the caller
text_lines
                CLR     R10             ; from the first line
                MOVE    R11, LINE_LAST  ; to the last
                JMP     list_from       ; which returns to the caller

; out_file: R1 the name, and R2 the string of a TFTP server, or 0. The
; bytes that the routine R12 writes with putc, or into V_FBUF from V_SPOS
; and with flush, written to the file R1 of the card's folder, which
; fs_open, entry 10, makes or truncates, or with R2 to the server, with
; tput_open and tput_close of basic_net.nasm (issue #155). V_FBUF goes to
; the file with flush, when it is full, and at the end. The first error
; of a write is kept in V_SERR, and raised at the end, after the close,
; with io_fail; a write that does not fit on the card is error 30. The
; routine keeps R9 and R10 for the caller, as out_file does.
out_file
                TST     R2
        ?!Z     JMP     :+
                MOVE    R2, 1           ; to write
                CALL    FS_OPEN
                TST     R1
        ?N      JMP     io_fail
                ADD     @V_OPEN, R1, 1
                JMP     :++
:
                CALL    tput_open
:
                CLR     @V_SERR
                MOVE    @V_SPOS, V_FBUF
                CALL    R12
                CALL    flush
                CLR     @V_SPOS
                TST     @V_OPEN
        ?N      JMP     tput_close      ; which returns to the caller
                SUB     R1, @V_OPEN, 1
                CLR     @V_OPEN
                CALL    FS_CLOSE
                MOVE[M] R2, @V_SERR
        ?!Z     MOVE    R1, R2          ; the error of a write, before the close's
                TST     R1
        ?N      JMP     io_fail
                RET

; flush: the bytes in V_FBUF up to V_SPOS written to the file of SAVE,
; or to its TFTP server with tput_bytes, unless a write failed before,
; and V_SPOS at V_FBUF again. A write that fails, or writes fewer bytes,
; sets V_SERR. Uses R1-R4.
flush
                SUB[M]  R3, @V_SPOS, V_FBUF
        ?Z      RET
                MOVE    @V_SPOS, V_FBUF
                TST     @V_SERR
        ?!Z     RET
                TST     @V_OPEN
        ?N      JMP     tput_bytes      ; which returns to the caller
                PUSH    R5
                PUSH    R6
                PUSH    R3
                SUB     R1, @V_OPEN, 1
                MOVE    R2, V_FBUF
                CALL    FS_WRITE
                POP     R3
                TST     R1
        ?N      JMP     :+
                CMP     R1, R3
        ?Z      JMP     :++
                MOVE    R1, -30         ; the card is full
:
                MOVE    @V_SERR, R1
:
                POP     R6
                POP     R5
                RET

; putc: the character R1 to mon_putc, entry 3, or into V_FBUF while SAVE
; writes a program's text, and V_FBUF to the file when it is full. LIST
; and the numbers of PRINT write with it. Uses R1-R4, as mon_putc does.
putc
                MOVE[M] R2, @V_SPOS
        ?Z      JMP     MON_PUTC
                MOVE    @R2++, R1
                MOVE    @V_SPOS, R2
                CMP     R2, V_FBUF+FBUF_BYTES
        ?C      RET
                JMP     flush

; putdec: R1 in decimal, unsigned, with putc, as _io_putdec writes it
; with mon_putc. Uses R1-R4, and R7 across the calls, saved.
putdec
                PUSH    R7
                CLR     R7              ; the digits pushed
                MOVE    @io.mpu_b, 10
:
                MOVE    @io.mpu_a, R1
                PUSH    @io.mpu_udivr
                ADD     R7, R7, 1
                MOVE[M] R1, @io.mpu_udivq
        ?!Z     JMP     :-
:
                ADD     R1, @R13++, 0x30
                CALL    putc
                SUB[M]  R7, R7, 1
        ?!Z     JMP     :-
                POP     R7
                RET

; files_end: the file of LOAD or SAVE, or TFTP's endpoint, that an error
; or the break key left open, closed, and the load and the save of a
; program's text ended, for main. The lines that SAVE has in V_FBUF are
; written first to the card, and dropped for a TFTP server, which gets an
; ERROR instead, with tput_abort, so that it drops the file. Uses R1-R6.
files_end
                CLR     @V_LBAS
                CMP     @V_OPEN, 0xFFFFFFFE
        ?Z      CLR     @V_SPOS         ; a write of TFTP
                TST     @V_SPOS
        ?!Z     CALL    flush
                CLR     @V_SPOS
                MOVE[M] R1, @V_OPEN
        ?Z      RET
                CLR     @V_OPEN
                CMP     R1, 0xFFFFFFFE
        ?Z      JMP     tput_abort      ; which returns to the caller
                TST     R1
        ?N      JMP     UDP_CLOSE       ; which returns to the caller
                SUB     R1, R1, 1
                JMP     FS_CLOSE        ; which returns to the caller

; hex8: R1 in 8 hex digits in lower case at R2, one a word, which moves
; on. Uses R1, R3, and R4.
hex8
                MOVE    R4, 8
:               ROL     R1, R1, 4
                AND     R3, R1, 0xF
                ADD     R3, R3, 0x30
                CMP     R3, 0x3A
        ?!C     ADD     R3, R3, 0x27
                MOVE    @R2++, R3
                SUB[M]  R4, R4, 1
        ?!Z     JMP     :-
                RET

; DELETE "NAME": R1 the name. The file NAME of the card's folder deleted,
; with fs_delete of monitor_fat.nasm.
st_delete
                MOVE    R7, R1          ; the name
                CALL    FS_DELETE
                TST     R1
        ?N      JMP     io_fail
                MOVE    R1, S_DELETED
                CALL    puts_b
                MOVE    R1, R7
                JMP     puts_crlf       ; which returns to the caller

; load_row: row R7 blank in the current color, which scr_color, entry 8,
; gives, and the cursor at its column 0, with scr_moveto, entry 6. Uses
; R1-R6.
load_row
                CLR     R1
                CALL    SCR_COLOR
                MOVE    R3, R1          ; the color, which scr_color uses not
                CALL    SCR_COLOR       ; back
                OR      R3, R3, 0x20
                SHL     R2, R7, 6
                SHL     R1, R7, 4
                ADD     R1, R1, R2
                ADD     R1, R1, SCREEN
                MOVE    R2, 80
:
                MOVE    @R1++, R3
                SUB[M]  R2, R2, 1
        ?!Z     JMP     :-
                CLR     R1
                MOVE    R2, R7
                JMP     SCR_MOVETO      ; which returns to the caller

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

; sys_end: for SYS at a program's return, with R1 the status: the state
; after a program, with mon_restore, entry 36, and sys_status. Uses
; R1-R6.
sys_end
                PUSH    R1
                CALL    MON_RESTORE
                POP     R1
; sys_status: the status R1 of a program that returned, or left through
; mon_exit, which restored the state itself: a new line if the cursor,
; which scr_getxy gives, is not in column 0, and the status printed.
; Uses R1-R6.
sys_status
                PUSH    R1
                CALL    SCR_GETXY
                TST     R1
        ?!Z     CALL    _io_crlf
                MOVE    R1, S_RETURN
                CALL    puts_b
                POP     R1
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

S_RETURN
                .ASCII_B 'Returned '
S_NAME          .ASCII_B 'NiceMon '
                .DAT    0
S_TABLE         .ASCII_B ', dispatch table '
S_BASIC         .ASCII_B ', BASIC '
                .DAT    0
S_HALTED
                .ASCII_B 'Halted'
S_NOPROG
                .ASCII_B 'No program at '
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
S_DIRTAG
                .ASCII_B '       <DIR>'
                .DAT    0
S_FILES         .ASCII_B 'Files: '
S_DIRS          .ASCII_B ', directories: '
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
E_FS22          .ASCII_B 'a directory, or a file used as one'
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
S_SDERR         .ASCII_B 'SD error '
S_INSLOT
                .ASCII_B ' in slot '
; The meanings of the errors 1 to SD_ERRS of SD_ERROR
SD_ERRORS
                .DAT    E_SD1, E_SD2, E_SD3, E_SD4, E_SD5, E_SD6, E_SD7, E_SD8
SD_ERRS         .EQU    8
E_SD1           .ASCII_B 'no card'
E_SD2           .ASCII_B 'the card is not ready'
E_SD3           .ASCII_B 'timeout, the card did not answer'
                .DAT    0
E_SD4           .ASCII_B 'CRC, the data from the card was corrupted'
E_SD5           .ASCII_B 'the card reported an error'
E_SD6           .ASCII_B 'the card is write-protected'
E_SD7           .ASCII_B 'the sector is after the last, '
E_SD8           .ASCII_B 'Init failed'
