; The monitor's main loop and its commands, which the Makefile joins after
; monitor.nasm (its header). The BASIC interpreter of issue #54 is to
; replace them, so this file has the main loop, the commands, and the
; routines and texts that only they use, and monitor.nasm the rest: the
; HAL, the screen, and the line with its scrollback, getline. Their
; variables are in monitor.nasm, with the others.
;
; The cold start, mon_reset, ends at cmd_start, which prints the banner and
; runs the main loop, main. A command is a line: a letter, and after d and
; u a hex address and a hex count, and after r a hex address. l writes
; words into the RAM from lines of ADDR WORD in hex, as a .bin file has
; them, typed or pasted, up to an empty line, so that a program is loaded
; with no host's tools and no storage. Each line is shown in one row of
; the screen, which the next line clears, and not on the line, so that no
; line scrolls the screen and a paste at 2 Mbaud keeps up. r runs the
; program at its address, or at 0x8000, as a subroutine, with R1 = the
; entry of mon_putc, R2 = 0, R3 = 0, and E = 0 (ABI.md, "Programs under a
; monitor"), and at its return goes to mon_exit, which goes back to main.
; dir lists the folder NICE of an SD card's FAT32 file system, load NAME
; reads a .bin file from it as l reads lines, save NAME ADDR N writes one,
; and del NAME deletes a file, with fat32.c, the ROM's C code, whose
; functions are also the entries 9 to 15, fs_mount, fs_open, fs_read,
; fs_readdir, fs_close, fs_write, and fs_delete (issues #58 and #59). time
; shows the clock of the time of day, or sets it, with clock.c (issue
; #109). The commands u, i dhcp, and tftp are in monitor_dis.nasm and
; monitor_eth.nasm, and use the routines of this file.

RAM_WORDS       .EQU    0xFFFFFF9E      ; the words of the RAM, 0 in niceemu, where there is no limit
UART_BAUD       .EQU    0xFFFFFF9F      ; the UART's baud rate in bit/s, memory in niceemu
DUMP_WORDS      .EQU    32              ; the words that d shows without a count
ROW_WORDS       .EQU    4               ; the words of a row of d

; cmd_start: where the cold start goes, at its end: the banner, and d and u
; at 0x8000, and then the main loop
cmd_start
                MOVE    @V_NEXT, PROGRAM
                MOVE    @V_UNEXT, PROGRAM
                MOVE    R1, S_NAME
                CALL    puts_b
                MOVE    R1, VERSION
                CALL    puts_b_crlf
                MOVE    R1, S_HINT
                CALL    puts_b_crlf

; main: the prompt, a line, and its command. SP is fresh for each line, and
; a command jumps back here when it is done. The first character of the
; line that is no blank is the command, A to Z as a to z, looked up in
; COMMANDS; R2 points after it for the command's arguments.
main            MOVE    SP, STACK
                MOVE    R1, S_PROMPT
                CALL    puts_b
                MOVE    R1, V_LINE
                MOVE    R2, LINE_MAX
                CALL    getline
                MOVE    R2, V_LINE
:               MOVE[M] R1, @R2++
        ?Z      JMP     main            ; an empty line
                CMP     R1, 0x20
        ?Z      JMP     :-
                SUB     R3, R1, 0x41
                CMP     R3, 26
        ?C      OR      R1, R1, 0x20    ; A to Z folded to a to z
                MOVE    R3, COMMANDS
:               MOVE[M] R4, @R3++       ; a letter, or 0 at the end
        ?Z      JMP     unknown
                CMP     R4, R1
        ?Z      JMP     @R3             ; the command
                ADD     R3, R3, 1
                JMP     :-
unknown         MOVE    R1, S_UNKNOWN
                CALL    puts_b_crlf
                JMP     main

; ?: the commands, a line each
cmd_help
                MOVE    R1, HELP
                CALL    puts_lines
                JMP     main

; c: the screen cleared
cmd_cls         CALL    scr_cls
                JMP     main

; v: the version of the monitor, and that of the table, major.minor
cmd_version
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
                CALL    _io_crlf
                JMP     main

; h: the core halted, until the reset button, or a host starts it
cmd_halt
                MOVE    R1, S_HALTED
                CALL    puts_b_crlf
                HALT

; d [ADDR] [N]: N words from ADDR, in hex, ROW_WORDS to a row, each row
; with its address first. Without ADDR, the words after the last shown;
; without N, DUMP_WORDS. A d with ir after it is dir, and one with el
; and a blank or nothing after it del.
cmd_dump
                OR      R1, @R2, 0x20   ; I as i
                CMP     R1, 0x69        ; i
        ?Z      JMP     cmd_dir
                CMP     R1, 0x65        ; e
        ?Z      JMP     cmd_del
dump_args
                MOVE    R1, R2
                CALL    _io_gethex      ; R1 the address, R2 its digits, R3 after it
                TST     R2
        ?!Z     MOVE    @V_NEXT, R1
                MOVE    R1, R3
                CALL    _io_gethex      ; R1 the count
                TST     R2
        ?Z      MOVE    R1, DUMP_WORDS
                MOVE[M] R8, R1          ; the words left
        ?Z      JMP     main
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
                CALL    _io_crlf
                JMP     main

; i [A.B.C.D | dhcp]: the Ethernet station's IP address (doc/SYSTEM.md,
; "The Ethernet station"), written from four decimal numbers of 0 to 255
; with dots between them, or from DHCP with the word dhcp, in either
; case, and shown, in decimal with dots. Without an address it is only
; shown. Blanks may come before and after the address, and anything else
; makes it no address, which is not written. A written address has no
; mask, no gateway, no DNS server, and no lease, which only i dhcp gives.
cmd_ip
                CMP     @R2, 0x20
        ?Z      ADD     R2, R2, 1
        ?Z      JMP     cmd_ip
                TST     @R2
        ?Z      JMP     ip_show         ; no address
                OR      R1, @R2, 0x20
                SUB     R1, R1, 0x61
                CMP     R1, 26
        ?C      JMP     ip_word         ; a letter
                MOVE    R1, R2
                CALL    get_ip
                TST     R2
        ?Z      JMP     ip_bad
                MOVE    R7, R1
                CALL    rest_blank
        ?!Z     JMP     ip_bad
                MOVE    @E_IP, R7
                MOVE    @V_MASK, 0
                MOVE    @V_GW, 0
                MOVE    @V_DNS, 0
                MOVE    @V_NTP, 0
                MOVE    @V_BSTATE, 0    ; no DHCP in the background
                CALL    lease_forget
ip_show         MOVE    R1, S_IP
                MOVE    R2, @E_IP
                CALL    show_ip
                JMP     main
ip_bad          MOVE    R1, S_BADIP
                CALL    puts_b_crlf
                JMP     main
; The word after i, which must be dhcp, and blanks after it
ip_word
                MOVE    R3, TEXT_B+4*S_DHCPW
:
                MOVE[M] R4, @R3++
        ?Z      JMP     :+
                OR      R1, @R2++, 0x20  ; A to Z as a to z
                CMP     R1, R4
        ?Z      JMP     :-
                JMP     ip_bad
:
                CMP     @R2, 0x20
        ?Z      ADD     R2, R2, 1
        ?Z      JMP     :-
                TST     @R2
        ?!Z     JMP     ip_bad
                JMP     ip_dhcp

; get_ip: the IP address at R1, four decimal numbers of 0 to 255 with dots
; between them: R1 the address, R2 = 1, and R3 after it, or R2 = 0 when
; there is none. Uses R1-R6.
get_ip
                MOVE    R3, R1          ; the next character
                MOVE    R1, 0           ; the address
                MOVE    R6, 4           ; the numbers left
get_ip_num
                MOVE    R4, 0           ; the number
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
                MOVE    R2, 0
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

; baud [RATE]: the UART's baud rate (doc/DEBUG_LINK.md, "The baud rate"),
; written from a decimal number that is one of the rates of BAUD_RATES,
; and shown. Without a rate it is only shown. Blanks may come before and
; after the rate, and anything else, or a rate not in the list, makes it
; no rate, which is not written. The monitor checks the list itself, as
; niceemu has memory at UART_BAUD. The UART takes the new rate once it
; has sent nothing for 1 ms, so what the monitor prints after the write,
; and its prompt, still go out at the old rate. R2 points after the b, R7
; gathers the rate, and R3 points into the line.
cmd_baud
                MOVE    R1, R2
                MOVE    R2, TEXT_B+4*S_AUD
                CALL    match           ; R1 after aud, or 0
                TST     R1
        ?Z      JMP     unknown
                MOVE    R3, R1
                TST     @R3
        ?Z      JMP     baud_show       ; baud alone
                CMP     @R3, 0x20
        ?!Z     JMP     unknown         ; baudx
:
                CMP     @R3, 0x20
        ?Z      ADD     R3, R3, 1
        ?Z      JMP     :-
                TST     @R3
        ?Z      JMP     baud_show       ; no rate
                MOVE    R7, 0
:
                SUB     R2, @R3, 0x30
                CMP     R2, 10
        ?!C     JMP     :+              ; no digit
                CMP     R7, 10000000
        ?!C     JMP     baud_bad        ; too many digits for a rate
                ADD     R7, R7, R7      ; R7 is 10 * R7 + the digit
                ADD     R2, R2, R7
                SHL     R7, R7, 2
                ADD     R7, R7, R2
                ADD     R3, R3, 1
                JMP     :-
:
                CALL    rest_blank      ; also no digit at all
        ?!Z     JMP     baud_bad
                MOVE    R1, BAUD_RATES
:
                MOVE[M] R2, @R1++
        ?Z      JMP     baud_bad        ; not in the list
                CMP     R2, R7
        ?!Z     JMP     :-
                MOVE    @UART_BAUD, R7
baud_show
                MOVE    R1, S_BAUD
                CALL    puts_b
                MOVE    R1, @UART_BAUD
                CALL    _io_putdec
                CALL    _io_crlf
                JMP     main
baud_bad
                MOVE    R1, S_BADBAUD
                CALL    puts_b_crlf
                JMP     main

; m [MAC]: the Ethernet station's MAC address (doc/SYSTEM.md, "The
; Ethernet station"), written from six bytes of one or two hex digits, in
; either case, with colons between them, and shown, two hex digits a byte
; with colons. The first byte must be even, as bit 0 of it marks a group
; address, which is no station's. Without an address it is only shown.
; Blanks may come before and after the address, and anything else makes it
; no address, which is not written. R7:R8 gather the address, a byte at a
; time, R9 counts the bytes left, and R10 points into the line.
cmd_mac
                MOVE    R7, 0
                MOVE    R8, 0
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
                CALL    _io_crlf
                JMP     main
mac_bad         MOVE    R1, S_BADMAC
                CALL    puts_b_crlf
                JMP     main

; mac_digit: bits 3..0 of R1 as a hex digit
mac_digit
                AND     R1, R1, 0xF
                ADD     R1, R1, 0x30
                CMP     R1, 0x3A
        ?!C     ADD     R1, R1, 7       ; A to F
                JMP     mon_putc        ; which returns to the caller

; l: words into the memory from lines of ADDR WORD, two hex numbers of 1 to
; 8 digits with blanks between them and around them, as a .bin file has
; them (nice_cpu's ISA.md §10.4), up to an empty line or CTRL-C, which
; also drops the line it is in. CR, LF, and CR LF end a line, so a
; terminal's lines and a file's both serve; V_LEND starts as a CR, so
; that the LF of a terminal that ends the l line itself with CR LF is
; the LF of that CR LF, not an empty line. A TAB is a blank, as niceemu
; takes it. A line of blanks only is passed over, as niceemu passes it,
; and counted as a line and not as skipped. A line with anything else, or
; with ADDR outside a program's RAM, PROGRAM up to V_PEND, is skipped:
; the RAM of a board repeats every RAM_WORDS words, so an address past it
; could reach the ROM or the monitor's variables and stack, which are at
; RAM_WORDS - VARS_WORDS and up of the RAM, 0x1F000 on the MEGA65 and
; 0xF000 on the Nexys4DDR. V_PEND is that address, or the screen where
; RAM_WORDS reads 0, as in niceemu. A line of more than LINE_MAX
; characters is skipped too: LINE_MAX + 1 of them are kept, which tells
; it from a full line, and the rest dropped. A second line for an address
; writes its word over the first's, where niceemu rejects the file. The
; count of the words written and the lowest and highest address are
; shown at the end, and the count of the skipped lines, the number of the
; first, and the last address that a line may have. DEL
; and BS delete the character before the cursor; the other control codes,
; the bytes from 0x80, and the escape sequences of the cursor and function
; keys are dropped. The lines are shown in row R7, which the hint leaves
; the cursor in, and only on the screen: each line clears the row, and its
; end is not shown, so the screen never scrolls. R8 counts the words
; written, R9 and R10 are the lowest and highest address written, R11
; counts the lines, R12 the lines skipped, and R6 is the next free word of
; the line. An l with oad after it is load NAME.
cmd_load
                OR      R1, @R2, 0x20   ; O as o
                CMP     R1, 0x6F        ; o
        ?Z      JMP     cmd_fload
                MOVE    R1, S_LHINT
                CALL    puts_b_crlf
                MOVE    @V_LOUT, @V_OUT
                MOVE    @V_OUT, OUT_SCREEN
                MOVE    @V_LEND, 0x0D   ; as after the CR of the l line
                MOVE    R7, @V_ROW
                MOVE    R8, 0
                MOVE    R9, 0xFFFFFFFF
                MOVE    R10, 0
                MOVE    R11, 0
                MOVE    R12, 0
                CALL    load_pend
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
                CMP     R6, V_LINE+LINE_MAX+1
        ?Z      JMP     load_key        ; the line is over full
                MOVE    @R6++, R1
                CALL    mon_putc
                JMP     load_key
load_del
                CMP     R6, V_LINE
        ?Z      JMP     load_key        ; nothing before the cursor
                SUB     R6, R6, 1
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
                MOVE    @R6, 0
                CMP     R6, V_LINE
        ?Z      JMP     load_done
                CALL    bin_line
                JMP     load_line

; bin_line: the line at V_LINE, which ends at R6 with a 0, LINE_MAX + 1
; characters when it was longer, of l and tftp: counted in R11, passed
; over when it has blanks only, or else parsed, and its word written,
; counted in R8, with the lowest and highest address in R9 and R10, or
; skipped, counted in R12, with the number of the first in V_LBAD. Uses
; R1-R6.
bin_line
                ADD     R11, R11, 1
                CMP     R6, V_LINE+LINE_MAX+1
        ?Z      JMP     bin_bad         ; longer than LINE_MAX
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
                ADD     R8, R8, 1
                CMP     R6, R9
        ?C      MOVE    R9, R6          ; a lower address
                CMP     R10, R6
        ?C      MOVE    R10, R6         ; a higher one
                RET
bin_bad
                ADD     R12, R12, 1
                CMP     R12, 1
        ?Z      MOVE    @V_LBAD, R11
                RET
; The end of the load: the row blank again, the outputs back, the words
; written, and the lines skipped
load_done
                CALL    load_row
                MOVE    @V_OUT, @V_LOUT
load_summary
                MOVE    R1, S_LOADED
                CALL    puts_b
                MOVE    R1, R8
                CALL    _io_putdec
                TST     R8
        ?Z      JMP     :+
                MOVE    R1, S_LFROM
                CALL    puts_b
                MOVE    R1, R9
                CALL    _io_puthex
                MOVE    R1, S_LTO
                CALL    puts_b
                MOVE    R1, R10
                CALL    _io_puthex
:
                CALL    _io_crlf
                TST     R12
        ?Z      JMP     main
                MOVE    R1, S_SKIPPED
                CALL    puts_b
                MOVE    R1, R12
                CALL    _io_putdec
                MOVE    R1, S_FIRST
                CALL    puts_b
                MOVE    R1, @V_LBAD
                CALL    _io_putdec
                MOVE    R1, S_LFORM
                CALL    puts_b
                SUB     R1, @V_PEND, 1
                CALL    _io_puthex
                CALL    _io_crlf
                JMP     main

; load_pend: V_PEND, the end of a program's RAM, where the variables
; start, from the size of the RAM, or the screen in niceemu. Uses R1.
load_pend
                MOVE[M] R1, @RAM_WORDS
        ?Z      MOVE    R1, SCREEN+VARS_WORDS  ; no limit
                SUB     @V_PEND, R1, VARS_WORDS
                RET

; dir [SLOT]: the folder NICE of the card in SLOT, in hex, mounted first,
; or of the card mounted, with fat_dir of fat32.c. R2 points after the d.
cmd_dir
                MOVE    R1, @R2++
                OR      R1, @R2++, 0x20  ; R as r
                CMP     R1, 0x72        ; r
        ?!Z     JMP     unknown
                MOVE    R1, @R2
                CMP     R1, 0x20
        ?Z      JMP     :+
                TST     R1
        ?!Z     JMP     unknown         ; dirx
:
                MOVE    R1, R2
                CALL    _io_gethex      ; R1 the slot, R2 its digits, R3 after it
                MOVE    R7, R1
                CMP     R2, 9
        ?!C     JMP     :+              ; more than 8 digits
                TST     R2
        ?Z      MOVE    R7, 0xFFFFFFFF  ; no slot: the card mounted
                CALL    rest_blank
        ?!Z     JMP     :+
                MOVE    R1, R7
                CALL    _fat_dir
                TST     R1
        ?N      JMP     fs_fail
                JMP     main
:
                MOVE    R1, S_BADDIR
                CALL    puts_b_crlf
                JMP     main

; load NAME: the .bin file NAME of the card's folder NICE, read with
; fat_load of fat32.c, which writes its words as l does, and shown as l
; shows its lines. R2 points after the l.
cmd_fload
                MOVE    R1, R2
                MOVE    R2, TEXT_B+4*S_OAD
                CALL    match           ; R1 after oad, or 0
                TST     R1
        ?Z      JMP     unknown
                TST     @R1
        ?Z      JMP     fload_bad       ; load alone
                CMP     @R1, 0x20
        ?!Z     JMP     unknown         ; loadx
                CALL    fs_name
                TST     R1
        ?Z      JMP     fload_bad       ; no name
                MOVE    R7, R1          ; the name
                CALL    rest_blank
        ?!Z     JMP     fload_bad       ; a second word
                MOVE    R1, R7
                MOVE    R2, 0           ; to read
                CALL    _fat_open
                TST     R1
        ?N      JMP     fs_fail
                MOVE    R8, R1          ; the handle
                CALL    load_pend
                MOVE    R1, R8
                MOVE    R2, @V_PEND
                MOVE    R3, V_LSTATS
                CALL    _fat_load
                MOVE    R9, R1
                MOVE    R1, R8
                CALL    _fat_close
                MOVE    R1, R9
                TST     R1
        ?N      JMP     fs_fail
                MOVE    R8, @V_LSTATS
                MOVE    R9, @V_LSTATS+1
                MOVE    R10, @V_LSTATS+2
                MOVE    R12, @V_LSTATS+3
                MOVE    @V_LBAD, @V_LSTATS+4
                JMP     load_summary
fload_bad
                MOVE    R1, S_BADLOAD
                CALL    puts_b_crlf
                JMP     main

; save NAME ADDR N: the N words from ADDR, both in hex, written to the
; file NAME of the card's folder, which is made or truncated, as a .bin
; file, with fat_save of fat32.c, and the words saved shown as load shows
; those loaded. R2 points after the s.
cmd_save
                MOVE    R1, R2
                MOVE    R2, TEXT_B+4*S_AVE
                CALL    match           ; R1 after ave, or 0
                TST     R1
        ?Z      JMP     unknown
                TST     @R1
        ?Z      JMP     save_bad        ; save alone
                CMP     @R1, 0x20
        ?!Z     JMP     unknown         ; savex
                CALL    fs_name
                TST     R1
        ?Z      JMP     save_bad        ; no name
                MOVE    R7, R1          ; the name
                MOVE    R1, R3
                CALL    _io_gethex      ; R1 the address, R2 its digits, R3 after it
                SUB     R4, R2, 1
                CMP     R4, 8
        ?!C     JMP     save_bad        ; no digit, or more than 8
                MOVE    R9, R1
                MOVE    R1, R3
                CALL    _io_gethex      ; R1 the count
                SUB     R4, R2, 1
                CMP     R4, 8
        ?!C     JMP     save_bad
                MOVE    R10, R1
                CALL    rest_blank
        ?!Z     JMP     save_bad        ; a fourth word
                MOVE    R1, R7
                MOVE    R2, 1           ; to write
                CALL    _fat_open
                TST     R1
        ?N      JMP     fs_fail
                MOVE    R8, R1          ; the handle
                MOVE    R2, R9
                MOVE    R3, R10
                CALL    _fat_save
                MOVE    R11, R1
                MOVE    R1, R8
                CALL    _fat_close
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
                CALL    _io_crlf
                JMP     main
save_bad
                MOVE    R1, S_BADSAVE
                CALL    puts_b_crlf
                JMP     main

; del NAME: the file NAME of the card's folder deleted, with fat_delete of
; fat32.c. R2 points after the d, at the e; a d with e and no l after it,
; such as de 10, is d.
cmd_del
                MOVE    R7, R2
                MOVE    R1, R2
                MOVE    R2, TEXT_B+4*S_EL
                CALL    match           ; R1 after el, or 0
                TST     R1
        ?Z      JMP     del_dump
                TST     @R1
        ?Z      JMP     del_bad         ; del alone
                CMP     @R1, 0x20
        ?!Z     JMP     unknown         ; delx
                CALL    fs_name
                TST     R1
        ?Z      JMP     del_bad         ; no name
                MOVE    R7, R1          ; the name
                CALL    rest_blank
        ?!Z     JMP     del_bad         ; a second word
                MOVE    R1, R7
                CALL    _fat_delete
                TST     R1
        ?N      JMP     fs_fail
                MOVE    R1, S_DELETED
                CALL    puts_b
                MOVE    R1, R7
                CALL    puts_crlf
                JMP     main
del_dump
                MOVE    R2, R7
                JMP     dump_args
del_bad
                MOVE    R1, S_BADDEL
                CALL    puts_b_crlf
                JMP     main

; fs_name: the name of a file in the line from R1, after blanks, ended in
; the line with a 0 at the first blank after it, or in quotes, "my
; prog.bin", with blanks in it, ended with a 0 at the closing quote: R1
; the name, and R3 the rest of the line, or R1 = 0 when the line has no
; more, or no closing quote. Uses R1-R3.
fs_name
                CMP     @R1, 0x20
        ?Z      ADD     R1, R1, 1
        ?Z      JMP     fs_name
                TST     @R1
        ?Z      MOVE    R1, 0
        ?Z      RET
                CMP     @R1, 0x22       ; "
        ?Z      JMP     fs_quoted
                MOVE    R3, R1
:
                ADD     R3, R3, 1
                TST     @R3
        ?Z      RET
                CMP     @R3, 0x20
        ?!Z     JMP     :-
                MOVE    @R3++, 0
                RET
fs_quoted
                ADD     R1, R1, 1
                MOVE    R3, R1
:
                TST     @R3
        ?Z      MOVE    R1, 0           ; no closing quote
        ?Z      RET
                CMP     @R3, 0x22
        ?Z      JMP     :+
                ADD     R3, R3, 1
                JMP     :-
:
                MOVE    @R3++, 0
                RET

; match: Z clear and R1 after the string at R2 when the line at R1 starts
; with it, in either case, or R1 = 0. Uses R1-R4.
match
                MOVE[M] R3, @R2++
        ?Z      RET
                OR      R3, R3, 0x20
                OR      R4, @R1++, 0x20
                CMP     R3, R4
        ?Z      JMP     match
                MOVE    R1, 0
                RET

; rest_blank: Z when the line from R3 has only blanks. Uses R3.
rest_blank
                CMP     @R3, 0x20
        ?Z      ADD     R3, R3, 1
        ?Z      JMP     rest_blank
                TST     @R3
                RET

; fs_fail: an error of fat32.c, R1 its negative: one of the SD controller's
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
                CALL    _io_crlf
                JMP     main

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
                MOVE    @V_COL, 0
                MOVE    @V_ROW, R7
                JMP     putc_cur

; r [ADDR]: the program at ADDR, 0x8000 without it, called as ABI.md
; says, on this stack: the return address is pushed, and the program
; returns with RET and its status in R1. A word of 0 at ADDR is no
; program: it is NOP, which no start-up code begins with. r 0 is entry 0
; of the dispatch table, the cold start. At the program's return, its
; status goes to mon_exit. run_at is the call, with R7 the address.
cmd_run
                MOVE    R1, R2
                CALL    _io_gethex      ; R1 the address, R2 its digits
                MOVE    R7, R1
                TST     R2
        ?Z      MOVE    R7, PROGRAM     ; no address
run_at          TST     @R7
        ?Z      JMP     no_prog
                MOVE    R1, MON_PUTC    ; the entry of mon_putc (mon.nasm)
                MOVE    R2, 0           ; argc
                MOVE    R3, 0           ; argv
                CALL    R7
                JMP     mon_exit        ; with the status in R1
no_prog         MOVE    R1, S_NOPROG
                CALL    puts_b
                MOVE    R1, R7
                CALL    _io_puthex
                CALL    _io_crlf
                JMP     main

; t: time, when an i follows the t, or else tftp. R2 points after the t.
cmd_t
                OR      R1, @R2, 0x20   ; I as i
                CMP     R1, 0x69        ; i
        ?!Z     JMP     cmd_tftp

; time [YYYY-MM-DD HH:MM:SS]: the clock of the time of day (nice_cpu's
; SYSTEM.md §10), which keeps local time, set first when a date and a time
; follow, and shown, with clock_cmd of clock.c. time ntp sets it from a
; time server, with time_ntp of monitor_eth.nasm. R2 points after the t.
cmd_time
                MOVE    R1, R2
                MOVE    R2, TEXT_B+4*S_IME
                CALL    match           ; R1 after ime, or 0
                TST     R1
        ?Z      JMP     unknown
                TST     @R1
        ?Z      JMP     :+++            ; time alone
                CMP     @R1, 0x20
        ?!Z     JMP     unknown         ; timex
                MOVE    R7, R1
:
                CMP     @R1, 0x20
        ?Z      ADD     R1, R1, 1
        ?Z      JMP     :-
                MOVE    R2, TEXT_B+4*S_NTPW
                CALL    match           ; R1 after ntp, or 0
                TST     R1
        ?Z      JMP     :+
                TST     @R1
        ?Z      JMP     time_ntp
                CMP     @R1, 0x20
        ?Z      JMP     time_ntp
:
                MOVE    R1, R7
:
                CALL    _clock_cmd
                JMP     main

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

; The commands: the letter, and the routine, which main jumps to. A 0 ends
; the table.
COMMANDS
                .DAT    0x3F, cmd_help  ; ?
                .DAT    0x62, cmd_baud  ; b, for baud
                .DAT    0x63, cmd_cls   ; c
                .DAT    0x64, cmd_dump  ; d
                .DAT    0x68, cmd_halt  ; h
                .DAT    0x69, cmd_ip    ; i
                .DAT    0x6C, cmd_load  ; l
                .DAT    0x6D, cmd_mac   ; m
                .DAT    0x72, cmd_run   ; r
                .DAT    0x73, cmd_save  ; s, for save
                .DAT    0x74, cmd_t     ; t, for time and tftp
                .DAT    0x75, cmd_dis   ; u
                .DAT    0x76, cmd_version  ; v
                .DAT    0

S_NAME          .ASCII_B 'NiceMon '
                .DAT    0
S_HINT          .ASCII_B '? lists the commands'
                .DAT    0
S_PROMPT
                .ASCII_B '> '
S_UNKNOWN
                .ASCII_B 'Unknown command; ? lists them'
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
S_DHCPW         .ASCII_B 'dhcp'
                .DAT    0
S_BADMAC
                .ASCII_B 'Not a MAC address: six bytes in hex with colons, the first one even'
S_BADBAUD
                .ASCII_B 'Not a baud rate: 115200, 230400, 460800, 921600, 1000000, 1500000, or 2000000'
; The rates that UART_BAUD takes, and a 0
BAUD_RATES
                .DAT    115200, 230400, 460800, 921600, 1000000, 1500000, 2000000, 0
S_FSERR         .ASCII_B 'File error '
S_OAD           .ASCII_B 'oad'
S_BADDIR
                .ASCII_B 'dir [SLOT]: the slot in hex, such as dir 1'
S_BADLOAD
                .ASCII_B 'load NAME: the name of a file, such as load hello.bin, or load "my prog.bin"'
                .DAT    0
S_AVE           .ASCII_B 'ave'
S_AUD           .ASCII_B 'aud'
S_EL            .ASCII_B 'el'
S_IME           .ASCII_B 'ime'
S_NTPW          .ASCII_B 'ntp'
S_SAVED         .ASCII_B 'Words saved: '
S_BADSAVE
                .ASCII_B 'save NAME ADDR N: a name, and the address and the count in hex'
S_DELETED
                .ASCII_B 'Deleted '
                .DAT    0
S_BADDEL
                .ASCII_B 'del NAME: the name of a file, such as del hello.bin, or del "my prog.bin"'
; The meanings of fat32.c's errors FS_ERR0 to FS_ERR0 + FS_ERRS - 1.
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

HELP            .DAT    H_R, H_L, H_LOAD, H_SAVE, H_DEL, H_TFTP, H_TFTPL, H_D, H_U
                .DAT    H_DIR, H_I, H_ID, H_M, H_B, H_T, H_TN, H_C, H_V, H_H, H_Q, H_P, H_PG, 0
H_R             .ASCII_B 'r [ADDR]      run the program at ADDR, or at 00008000; r 0 restarts'
H_L             .ASCII_B 'l             enter lines of ADDR WORD in hex, as a .bin file has them'
H_LOAD          .ASCII_B 'load NAME     load the .bin file NAME of the SD card, as l loads lines'
H_SAVE          .ASCII_B 'save NAME A N save N words from A, both in hex, as the .bin file NAME'
H_DEL           .ASCII_B 'del NAME      delete the file NAME of the SD card'
H_TFTP          .ASCII_B 'tftp IP NAME  load the .bin file NAME from the TFTP server at IP'
                .DAT    0
H_TFTPL         .ASCII_B 'tftp IP [PAT] list the files of tools/tftpd.py at IP, or those of PAT'
H_D             .ASCII_B 'd [ADDR] [N]  show N words from ADDR, in hex, or the next ones'
H_U             .ASCII_B 'u [ADDR] [N]  disassemble N instructions from ADDR, or the next ones'
                .DAT    0
H_DIR           .ASCII_B 'dir [SLOT]    list the files of the SD card in SLOT, or of the card mounted'
H_I             .ASCII_B 'i [A.B.C.D]   show the IP address, or set it, such as 192.168.1.65'
H_ID            .ASCII_B 'i dhcp        get the IP address from a DHCP server'
H_M             .ASCII_B 'm [MAC]       show the MAC address, or set it, such as 02:4E:49:43:45:01'
                .DAT    0
H_B             .ASCII_B 'baud [RATE]   show the UART baud rate, or set it, such as 921600'
                .DAT    0
H_T             .ASCII_B 'time [D T]    show the local time, or set it, such as 2026-11-11 14:30:00'
H_TN            .ASCII_B 'time ntp [S Z] set it from the time server S, Z local time less UTC, +01:00'
H_C             .ASCII_B 'c             clear the screen'
H_V             .ASCII_B 'v             the version'
H_H             .ASCII_B 'h             halt the core'
H_Q             .ASCII_B '?             the commands'
H_P             .ASCII_B 'CRSR up down  scroll back a row, before a command'
H_PG            .ASCII_B 'PgUp PgDn     a page; on the MEGA65 CTRL and MEGA with CRSR up or down'
