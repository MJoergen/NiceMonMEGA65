; BASIC's assembly in the ROM (issue #54, doc/BASIC.md), which the
; Makefile joins after monitor_cmd.nasm: the main loop, the stubs through
; which basic.c calls the routines of the statements, and BASIC's
; keywords, messages, and help, packed with .ASCII_B, which basic.c reads
; through the byte window, so that they take no RAM. Stage 1 (issue #112)
; is the shell: the monitor's commands as statements, on the routines
; that the commands had, in monitor_cmd.nasm, monitor_dis.nasm, and
; monitor_eth.nasm.
;
; The cold start ends at bas_start, which prints the banner and goes to
; main. main is where BASIC starts again, from the cold start, mon_exit,
; and mon_trap: it sets SP to STACK, and the C code's stack pointer to
; V_CSP, so that it leaves the C code from any depth, prints READY., and
; reads lines, which basic_line of basic.c runs. An empty line, or one of
; blanks only, runs nothing and prints no READY.
;
; basic.c calls a statement's routine through its stub, _st_NAME, as a
; function of the C ABI with its arguments in R1-R4. The routines were
; the monitor's commands, which use R7-R12 freely, so the stub keeps
; them: it puts the routine in R6 and goes to bas_enter, which pushes
; R7-R12, calls the routine, and pops them.

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

; main: READY., and the lines, each run by basic_line, with a fresh SP and
; C stack pointer after each that ran
main            MOVE    SP, STACK
                MOVE    @WASM_RAM, @V_CSP
                MOVE    R1, S_READY
                CALL    puts_b_crlf
main_line
                MOVE    R1, V_LINE
                MOVE    R2, LINE_MAX
                CALL    getline
                MOVE    R1, V_LINE
                CALL    _basic_line     ; 0 for an empty line
                TST     R1
        ?Z      JMP     main_line
                JMP     main

; The stubs of the statements, by the names that basic.c imports, with
; the routine in R6 for bas_enter
_st_sys         MOVE    R6, st_sys
                JMP     bas_enter
_st_lines
                MOVE    R6, st_lines
                JMP     bas_enter
_st_load
                MOVE    R6, st_load
                JMP     bas_enter
_st_tftp
                MOVE    R6, st_tftp
                JMP     bas_enter
_st_save
                MOVE    R6, st_save
                JMP     bas_enter
_st_delete
                MOVE    R6, st_delete
                JMP     bas_enter
_st_dir         MOVE    R6, st_dir
                JMP     bas_enter
_st_ip          MOVE    R6, st_ip
                JMP     bas_enter
_st_dhcp
                MOVE    R6, st_dhcp
                JMP     bas_enter
_st_mac         MOVE    R6, st_mac
                JMP     bas_enter
_st_ntp         MOVE    R6, st_ntp
                JMP     bas_enter
_st_baud
                MOVE    R6, st_baud
                JMP     bas_enter
_st_dump
                MOVE    R6, st_dump
                JMP     bas_enter
_st_dis         MOVE    R6, st_dis
                JMP     bas_enter
_st_cls         MOVE    R6, scr_cls
                JMP     bas_enter
_st_ver         MOVE    R6, st_ver
                JMP     bas_enter
_st_help
                MOVE    R6, st_help
                JMP     bas_enter
_st_halt
                MOVE    R6, st_halt
                JMP     bas_enter
; _bas_msg: message R1 of BAS_MSGS, and CR LF. _bas_puts: the packed text
; at the word address R1, and CR LF.
_bas_msg
                MOVE    R6, bas_msg
                JMP     bas_enter
_bas_puts
                MOVE    R6, puts_b_crlf
                JMP     bas_enter

; bas_enter: the routine R6 called with R1-R4, and R7-R12 kept
bas_enter
                PUSH    R7
                PUSH    R8
                PUSH    R9
                PUSH    R10
                PUSH    R11
                PUSH    R12
                CALL    R6
                POP     R12
                POP     R11
                POP     R10
                POP     R9
                POP     R8
                POP     R7
                RET

; _bas_words: R1 = the keywords, KEYWORDS, in the byte window.
; _bas_help: R1 = the table of the help's lines, HELP.
_bas_words
                MOVE    R1, TEXT_B+4*KEYWORDS
                RET
_bas_help
                MOVE    R1, HELP
                RET

; HELP: the lines of the statements
st_help         MOVE    R1, HELP
                JMP     puts_lines      ; which returns to the caller

; bas_msg: message R1 of BAS_MSGS, and CR LF
bas_msg
                ADD     R1, R1, BAS_MSGS
                MOVE    R1, @R1
                JMP     puts_b_crlf     ; which returns to the caller

; The keywords, each in upper case and a blank after it, in the order of
; basic.c's K_ numbers
KEYWORDS
                .ASCII_B 'SYS LOAD SAVE DELETE DIR IP DHCP MAC TIME NTP BAUD DUMP DIS CLS VER HELP HALT'
; The messages of basic.c, in the order of its M_ numbers
BAS_MSGS
                .DAT    S_SYNTAX, S_UNKNOWN, S_QUANT, S_NOTBIN, S_TFTPSAVE

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

; The lines of HELP, which basic.c also prints after Syntax error, those
; that start with the statement's keyword and a blank
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
