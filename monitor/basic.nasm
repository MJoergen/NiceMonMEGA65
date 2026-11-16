; BASIC's assembly in the ROM (issue #54, doc/BASIC.md), which the
; Makefile joins after monitor_cmd.nasm: the main loop, the scanner of a
; line, and BASIC's keywords, messages, and help, packed with .ASCII_B and
; read through the byte window, so that they take no RAM. Stage 1 (issue
; #112) is the shell: the monitor's commands as statements, on the
; routines that the commands had, in monitor_cmd.nasm, monitor_dis.nasm,
; and monitor_eth.nasm, with the scanner of issue #115.
;
; The cold start ends at bas_start, which prints the banner and goes to
; main. main is where BASIC starts again, from the cold start, mon_exit,
; and mon_trap: it sets SP to STACK, and the C code's stack pointer to
; V_CSP, so that it leaves the C code from any depth, prints READY., and
; reads lines. An empty line, or one of blanks only, runs nothing and
; prints no READY.
;
; The scanner. R8 is the next character of the line, which is a word of
; V_LINE, and R9 is not 0 once a number did not fit a word, which makes a
; statement that fails an Illegal quantity, not a Syntax error. A keyword
; is matched in either case, and no letter or digit may follow it. The
; byte after each keyword, below "A", gives its program: the offset of
; its first op in OPS, plus 0x20. An op is a byte, with the kind of the
; item in bits 2..1: a number (OP_N), in decimal or in hex after 0x, a
; string in quotes (OP_S), a comma (OP_C), or the end of the line
; (OP_E). Blanks before each item are passed over. When the item is
; there, the next op follows, and the end of the line runs the statement.
; When it is not there, the op says what follows: with OP_F the statement
; fails, with OP_SKIP the next op is passed over, and with neither the
; next op follows, unless a number did not fit. A statement that fails
; prints Syntax error and the lines of HELP that start with its keyword.
;
; The values of the items go to the slots at V_ARGS, slot 1 first, and a
; comma moves to the next, slot 2, then slot 4: R12 has the slot's
; number, and its value is at V_ARGS-1 + R12. R11 has the bits of the
; slots that got a number. When the line ends, R1, R2, and R3 are slots
; 1, 2, and 4, and the statement's routine of ACTS runs, with R11 and
; with R8 at the end of the line, and returns to main. The routines use
; any register, as main starts again after each. Slots 1 and 2 are 0
; for a statement that has no string or number there.

; bas_start: where the cold start goes, at its end: the banner, and DUMP
; and DIS at 0x8000, and then the main loop
bas_start
                MOVE    @V_NEXT, PROGRAM
                MOVE    @V_UNEXT, PROGRAM
                MOVE    R1, S_NAME
                CALL    puts_b
                MOVE    R1, VERSION
                CALL    puts_b_crlf
                MOVE    R1, S_HINT
                CALL    puts_b_crlf

; main: READY., and the lines, each run with a fresh SP and C stack
; pointer after each that ran
main            MOVE    SP, STACK
                MOVE    @WASM_RAM, @V_CSP
                MOVE    R1, S_READY
                CALL    puts_b_crlf
main_line
                MOVE    R1, V_LINE
                MOVE    R2, LINE_MAX
                CALL    getline
                MOVE    R8, V_LINE
:
                CMP     @R8, 0x20
        ?Z      MOVE    R8++, R8
        ?Z      JMP     :-
                TST     @R8
        ?Z      JMP     main_line       ; blanks only
                PUSH    main            ; where each statement returns
                CLR     R9
                MOVE    @V_ARGS, R0
                MOVE    @V_ARGS+1, R0
; The keyword: R7 its first byte, R11 its routine's halfword in ACTS
                MOVE    R3, TEXT_B+4*OPS+KEYWORDS
                MOVE    R11, H_ACTS
:
                MOVE    R7, R3
                MOVE    R5, R8
                CALL    match
        ?Z      JMP     :+
                ADD     R11, R11, 2
                TST     @R3
        ?!Z     JMP     :-
                MOVE    R1, S_UNKNOWN
                JMP     puts_b_crlf     ; which returns to main
:
                MOVE    R8, R5
                PUSH    @R11            ; the routine, which k_end returns to
                ADD     R10, R4, TEXT_B+4*OPS-0x20
                CLR     R11
                ONE     R12
; The ops, from R10
bas_op
                CMP     @R8, 0x20
        ?Z      MOVE    R8++, R8
        ?Z      JMP     bas_op
                MOVE    R3, @R10++
                AND     R5, R3, 6
                MOVE    R5, @H_KINDS[R5]
                CALL    R5
        ?!Z     JMP     :+
                MOVE    @V_ARGS-1[R12], R1
                JMP     bas_op
:
                AND[M]  R0, R3, OP_SKIP
        ?!Z     MOVE    R10++, R10
        ?!Z     JMP     bas_op
                AND[M]  R0, R3, OP_F
        ?Z      TST     R9
        ?Z      JMP     bas_op
; The statement failed: Illegal quantity, or Syntax error and the lines
; of HELP that start with the keyword at R7 and a blank
                POP     R0              ; the routine
                MOVE    R1, S_QUANT
                TST     R9
        ?!Z     JMP     puts_b_crlf     ; which returns to main
                MOVE    R1, S_SYNTAX
                CALL    puts_b_crlf
                MOVE    R10, HELP
:
                MOVE[M] R12, @R10++
        ?Z      RET                     ; to main
                DBL     R5, R12
                DBL     R5, R5
                ADD     R5, R5, TEXT_B
                MOVE    R3, R7
                CALL    match
        ?!Z     JMP     :-
                MOVE    R1, R12
                CALL    puts_b_crlf
                JMP     :-

; match: Z when the text at R5 starts with the keyword at R3, in either
; case, and no letter or digit follows it. R3 is then after the byte that
; ends the keyword, R4 that byte, and R5 after the keyword's length in
; the text. Uses R1, R2, and R6.
match
                CLR     R6
:
                MOVE    R4, @R3++
                CMP     R4, 0x41        ; A
        ?C      JMP     :+
                AND     R1, @R5++, 0xDF  ; in upper case, for a letter
                CMP     R1, R4
        ?!Z     ONE     R6
                JMP     :-
:
                MOVE    R1, @R5
                CALL    dval
        ?C      ONE     R6
                TST     R6
                RET

; dval: the character R1 as a digit: R2 0 to 9, or 10 to 35 for a letter
; in either case, and C; or R2 0xFFFFFFFF, and no C, for any other
dval
                SUB     R2, R1, 0x30
                CMP     R2, 10
        ?C      RET
                AND     R2, R1, 0xDF
                SUB     R2, R2, 0x41
                CMP     R2, 26
                ADD     R2, R2, 10
        ?!C     NOT     R2, R0
                RET

; The items, each called by bas_op with R8 at its first character, after
; the blanks: Z when it is there, with R1 its value and R8 after it.

; k_number: a number in decimal, or in hex after 0x or 0X, of one digit
; or more, with no letter or digit after it, and less than 2^32, else R9
; is 1. It sets the bit of the slot R12 in R11. 0x without digits leaves
; R8 after the 0x. Uses R2, R4-R6.
k_number
                CLR     R4              ; the number
                ONE     R6              ; not 0 before the first digit
                MOVE    R5, 10          ; the base
                CMP     @R8, 0x30
        ?!Z     JMP     :+
                AND     R1, @1[R8], 0xDF
                CMP     R1, 0x58        ; X
        ?Z      MOVE    R5, 16
        ?Z      ADD     R8, R8, 2
:
                MOVE    @io.mpu_b, R5
:
                MOVE    R1, @R8
                CALL    dval
                CMP     R2, R5
        ?!C     JMP     :+
                CLR     R6
                MOVE    @io.mpu_a, R4   ; R4 is R4 * R5 + R2, with R9 1 on a carry
                ADD[M]  R4, @CLK_UMUL, R2
                ADD[CM] R0, @CLK_UMUL+1, R0
        ?!Z     ONE     R9
                MOVE    R8++, R8
                JMP     :-
:
                XNOR[M] R0, R2, R9      ; Z for no letter or digit, and R9 0
        ?Z      TST     R6
        ?Z      OR      R11, R11, R12
                MOVE    R1, R4
                RET

; k_string: a string in quotes: R1 its first character. A 0 replaces its
; closing quote, and a string without one ends with the line. Uses R2.
k_string
                CMP     @R8, 0x22       ; "
        ?!Z     RET
                MOVE    R8++, R8
                MOVE    R1, R8
:
                MOVE[M] R2, @R8++
        ?Z      MOVE    R8--, R8
        ?Z      RET
                CMP     R2, 0x22
        ?!Z     JMP     :-
                MOVE    @--R8, R0
                MOVE    R8++, R8
                RET

; k_comma: a comma, after which the values go to the next slot
k_comma
                CMP     @R8, 0x2C       ; ,
        ?Z      MOVE    R8++, R8
        ?Z      ADD     R12, R12, R12
                RET

; k_end: the end of the line, which runs the statement: it returns to the
; routine, with R1-R3 the slots, instead of to bas_op
k_end
                TST     @R8
        ?!Z     RET
                POP     R0
                MOVE    R1, @V_ARGS
                MOVE    R2, @V_ARGS+1
                MOVE    R3, @V_ARGS+3
                RET

; The routines of the statements that are not those of monitor_cmd.nasm,
; monitor_dis.nasm, or monitor_eth.nasm alone

; TIME ["D T"]: clock_cmd with the string, or the end of the line
bas_time
                TST     R1
        ?Z      MOVE    R1, R8
                JMP     clock_cmd

; NTP ["S"] [, "Z"]: an empty S is none
bas_ntp
                TST     R1
        ?!Z     TST     @R1
        ?Z      CLR     R1
                JMP     st_ntp

; BAUD [RATE], DUMP [A] [, N], and DIS [A] [, N], with the bits of the
; numbers given
bas_baud
                MOVE    R2, R11
                JMP     st_baud
bas_dump
                MOVE    R3, R11
                JMP     st_dump
bas_dis
                MOVE    R3, R11
                JMP     st_dis

; DIR, DIR SLOT, and DIR "IP" [, "PAT"]
bas_dir
                TST     R11
        ?!Z     JMP     st_dir          ; the slot
                TST     R1
        ?Z      NOT     R1, R0          ; the card mounted
        ?Z      JMP     st_dir
                ONE     R3
                JMP     st_tftp

; LOAD, LOAD "NAME.BIN", and LOAD "N.BIN", "IP": the name must end with
; .BIN, in either case
bas_load
                TST     R1
        ?Z      JMP     st_lines
                MOVE    R4, R1
:
                TST     @R4++
        ?!Z     JMP     :-
                SUB     R4, R4, 5       ; the name's last four characters
                CMP     R4, R1
        ?C      JMP     :++             ; fewer than four
                MOVE    R5, TEXT_B+4*S_DOTBIN
:
                MOVE[M] R6, @R5++
        ?Z      JMP     :++
                XOR     R6, R6, @R4++
                AND[M]  R0, R6, 0xDF
        ?Z      JMP     :-
:
                MOVE    R1, S_NOTBIN
                JMP     puts_b_crlf
:
                TST     R2
        ?Z      JMP     st_load
                MOVE    R3, R1          ; st_tftp: the server, the name, 0
                MOVE    R1, R2
                MOVE    R2, R3
                CLR     R3
                JMP     st_tftp

; SAVE "NAME", A, N, in which a name without a dot gets .BIN, and SAVE
; "NAME", "IP", which TFTP cannot. The .BIN and its 0 go from the closing
; quote, over the address and the count, which take four characters at
; least, so they stay in the line.
bas_save
                TST     R11
        ?Z      MOVE    R1, S_TFTPSAVE
        ?Z      JMP     puts_b_crlf
                MOVE    R4, R1
:
                MOVE[M] R5, @R4++
        ?!Z     CMP     R5, 0x2E        ; .
        ?!Z     JMP     :-
                TST     R5
        ?!Z     JMP     st_save         ; a dot
                MOVE    R4--, R4
                MOVE    R5, TEXT_B+4*S_DOTBIN
:
                MOVE[M] @R4++, @R5++
        ?!Z     JMP     :-
                JMP     st_save

; HELP: the lines of the statements
st_help         MOVE    R1, HELP
                JMP     puts_lines      ; which returns to the caller

; The routines of the statements, a halfword each, in the order of
; KEYWORDS, which the halfword window reads
ACTS
                .DAT    st_sys+65536*bas_load, bas_save+65536*st_delete
                .DAT    bas_dir+65536*st_ip, st_dhcp+65536*st_mac
                .DAT    bas_time+65536*bas_ntp, bas_baud+65536*bas_dump
                .DAT    bas_dis+65536*scr_cls, st_ver+65536*st_help, st_halt
H_ACTS          .EQU    0x40000000+4*ACTS
; The routines of the items, by the kind of an op, which bas_op calls
KINDS
                .DAT    k_number+65536*k_string, k_comma+65536*k_end
H_KINDS         .EQU    0x40000000+4*KINDS

; The ops, a letter each, and the keywords, each in upper case and the
; byte of its program after it. The bits of an op: 0x40, so that it is a
; letter; the kind in bits 2..1, OP_N, OP_S, OP_C, or OP_E; OP_SKIP, and
; OP_F. The programs, at the offset in OPS that a keyword's byte less
; 0x20 gives:
;
;   0  IP, MAC, TIME  F J N    the end, or a string and the end
;   1  DELETE         J N      a string and the end
;   2  DHCP, CLS, VER, HELP, HALT   N   the end
;   3  DIR            F A N J E J N    the end, a number and the end, or
;                                      a string, a comma and a string or
;                                      not, and the end
;  10  LOAD, NTP      F J E J N        the end, or the strings of DIR
;  15  SAVE           J L C N H L H N  a string, a comma, and a string
;                                      and the end, or a number, a comma,
;                                      a number, and the end
;  21  SYS            H N      a number and the end
;  23  BAUD           @ N      a number or not, and the end
;  25  DUMP, DIS      @ E H N  a number or not, a comma and a number or
;                              not, and the end
OP_N            .EQU    0
OP_S            .EQU    2
OP_C            .EQU    4
OP_E            .EQU    6
OP_SKIP         .EQU    1
OP_F            .EQU    8
KEYWORDS        .EQU    29              ; the first keyword's byte in OPS
OPS
                .ASCII_B 'FJNFANJEJNFJEJNJLCNHLHN@N@EHNSYS5LOAD*SAVE/DELETE!DIR#IP DHCP"MAC TIME NTP*BAUD7DUMP9DIS9CLS"VER"HELP"HALT"'

S_HINT          .ASCII_B 'HELP lists the statements'
S_READY         .ASCII_B 'READY.'
S_SYNTAX
                .ASCII_B 'Syntax error'
                .DAT    0
S_UNKNOWN
                .ASCII_B 'Syntax error; HELP lists the statements'
S_QUANT         .ASCII_B 'Illegal quantity'
                .DAT    0
S_NOTBIN
                .ASCII_B 'LOAD takes a .BIN file, such as LOAD "HELLO.BIN"'
                .DAT    0
S_TFTPSAVE
                .ASCII_B 'SAVE writes to the SD card: TFTP only loads'
S_DOTBIN
                .ASCII_B '.BIN'
                .DAT    0

; The lines of HELP, which a Syntax error also prints, those that start
; with the statement's keyword and a blank
HELP            .DAT    H_SYS, H_L, H_LOAD, H_TFTP, H_SAVE, H_DEL, H_DIR, H_TFTPL, H_D, H_U
                .DAT    H_I, H_ID, H_M, H_B, H_T, H_TN, H_C, H_V, H_H, H_Q, H_P, H_PG, 0
H_SYS           .ASCII_B 'SYS A               call the program at A, such as SYS 0x8000; SYS 0 restarts'
H_L             .ASCII_B 'LOAD                enter lines of ADDR WORD in hex, as a .bin file has them'
                .DAT    0
H_LOAD          .ASCII_B 'LOAD "NAME.BIN"     load the .bin file NAME.BIN of the SD card'
H_TFTP          .ASCII_B 'LOAD "N.BIN", "IP"  load the .bin file N.BIN from the TFTP server at IP'
H_SAVE          .ASCII_B 'SAVE "NAME", A, N   save N words from A as the .bin file NAME'
H_DEL           .ASCII_B 'DELETE "NAME"       delete the file NAME of the SD card'
H_DIR           .ASCII_B 'DIR [SLOT]          list the files of the card in SLOT, or of the card mounted'
H_TFTPL         .ASCII_B 'DIR "IP" [, "PAT"]  list the files of tools/tftpd.py at IP, or those of PAT'
H_D             .ASCII_B 'DUMP [A] [, N]      show N words from A, in hex, or the next ones'
H_U             .ASCII_B 'DIS [A] [, N]       disassemble N instructions from A, or the next ones'
H_I             .ASCII_B 'IP ["A.B.C.D"]      show the IP address, or set it, such as "192.168.1.65"'
H_ID            .ASCII_B 'DHCP                get the IP address from a DHCP server'
H_M             .ASCII_B 'MAC ["MAC"]         show the MAC address, or set it, "02:4E:49:43:45:01"'
                .DAT    0
H_B             .ASCII_B 'BAUD [RATE]         show the UART baud rate, or set it, such as 921600'
H_T             .ASCII_B 'TIME ["D T"]        show the local time, or set it, "2026-11-11 14:30:00"'
H_TN            .ASCII_B 'NTP ["S"] [, "Z"]   set it from time server S, Z local time less UTC, "+01:00"'
H_C             .ASCII_B 'CLS                 clear the screen'
                .DAT    0
H_V             .ASCII_B 'VER                 the version'
H_H             .ASCII_B 'HALT                halt the core'
H_Q             .ASCII_B 'HELP                the statements'
H_P             .ASCII_B 'CRSR up down        scroll back a row, before a statement'
H_PG            .ASCII_B 'PgUp PgDn           a page; on the MEGA65 CTRL and MEGA with CRSR up or down'
                .DAT    0
