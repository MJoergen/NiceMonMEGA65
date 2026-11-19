; BASIC in the ROM (issue #54, doc/BASIC.md), an image of its own at
; BASIC_BASE, 0x4000, assembled apart from the monitor's (issue #152).
; It calls the monitor through the entries of the dispatch table alone,
; their .EQUs in ../monitor/mon.nasm, as a program does. The Makefile of
; ../monitor joins this file first, then basic_expr.nasm, basic_prog.nasm,
; basic_cmd.nasm, basic_net.nasm, basic_time.nasm, and basic_dis.nasm,
; and the monitor's common.nasm, monlib.nasm, and mon.nasm, of which
; BASIC has copies of its own.
;
; This file has the main loop, the scanner of a statement's items, and
; BASIC's keywords, messages, and help, packed with .ASCII_B and read
; through the byte window, so that they take no RAM. Stage 1 (issue #112)
; is the shell: the monitor's commands as statements, on the routines
; that the commands had, in basic_cmd.nasm, basic_dis.nasm,
; basic_net.nasm, and basic_time.nasm, with the scanner of issue #115.
; Stage 2 (issue #113) has the numbers, in basic_expr.nasm: the
; tokenizer, the expressions, the variables, the errors, and PRINT, LET,
; and POKE. Stage 3 (issue #114) has the programs, in basic_prog.nasm.
; Stage 4 (issue #60) has the programs' texts on a card and from a TFTP
; server: SAVE "NAME", LOAD "NAME", and RUN "NAME", in basic_cmd.nasm.
;
; The image starts with two vectors, which the monitor jumps to: at
; BAS_COLD, the end of its cold start, which goes to bas_start, and at
; BAS_WARM, mon_exit, which goes to bas_warm. bas_start prints the
; banner and goes to main, and bas_warm prints the status and goes to
; main. main is where BASIC starts again: it sets SP to STACK, prints
; READY., and reads lines with getline (basic_prog.nasm). A line that starts
; with a number is stored (basic_prog.nasm), and any other is made tokens
; by tokenize (basic_expr.nasm) and run. An empty line, or one of blanks
; only, runs nothing and prints no READY. run runs the statements of the
; line, with colons between them, and then those of the next line while
; a program runs.
;
; The scanner. R8 is the next token of the statement. A keyword is a
; whole name, in either case. The byte after each keyword, below "A",
; gives its program: the offset of its first op in OPS, plus 0x20. An op
; is a byte, with the kind of the item in bits 2..1: a number (OP_N),
; which is an expression, a string in quotes (OP_S), a comma (OP_C), or
; the end of the statement (OP_E). When the item is there, the next op
; follows, and the end of the statement runs it. When it is not there,
; the op says what follows: with OP_F the statement fails, with OP_SKIP
; the next op is passed over, and with neither the next op follows. A
; statement that fails prints Syntax error and the lines of HELP that
; start with its keyword, as err does for every Syntax error in a
; statement. An item that is not there leaves R8 where it was, so that
; the next op looks at the same token. The scan goes from the left, and
; the first item that fails decides: SAVE "X", "Y", 1/0 is a Syntax
; error at its second comma, before its number is computed.
;
; The values of the items go to the slots at V_ARGS, slot 1 first, and a
; comma moves to the next, slot 2, then slot 4: R12 has the slot's
; number, and its value is at V_ARGS-1 + R12. R11 has the bits of the
; slots that got a number. When the statement ends, R1, R2, and R3 are
; slots 1, 2, and 4, and the statement's routine of ACTS runs, with R11
; and with R8 at the end of the statement, and returns to run_next. The
; routines use any register, as run_next takes the end from V_TP. Slots
; 1 and 2 are 0 for a statement that has no string or number there.

; BASIC's RAM, BASIC_WORDS words from STACK (common.nasm), below the
; monitor's, which BASIC reaches through the entries alone (issue #152)
V_NEXT          .EQU    0xFFFFE800      ; the address that the next DUMP goes on at
V_UNEXT         .EQU    0xFFFFE801      ; the address that the next DIS goes on at
V_LOUT          .EQU    0xFFFFE802      ; the outputs of mon_out while LOAD reads its lines
V_LEND          .EQU    0xFFFFE803      ; the last byte that LOAD read, for the LF of a CR LF
V_LPOS          .EQU    0xFFFFE804      ; for LOAD from a file: the next free word of V_LINE
V_TLIST         .EQU    0xFFFFE805      ; not 0 for a listing of TFTP, of DIR, which bin_eol shows
V_LBAS          .EQU    0xFFFFE806      ; while LOAD reads a program's text: 1 before its first line, 2 after, else 0
V_OPEN          .EQU    0xFFFFE807      ; the file that LOAD or SAVE has open, its handle plus 1, -1 for TFTP's endpoint, or 0
V_ARGS          .EQU    0xFFFFE808      ; the values of a statement, 4 words, slots 1, 2, and 4 at V_ARGS, +1, and +3
V_LSTATS        .EQU    0xFFFFE80C      ; for LOAD: the counts of bin_line, 7 words
V_NET           .EQU    0xFFFFE818      ; for IP, DHCP, and NTP: the words of net_config and net_servers, 6 words
V_BI            .EQU    0xFFFFE820      ; for the clock, BASIC's block of common.nasm's conversions: the fields of a date and a time to set, and a 7th word,
V_BF            .EQU    0xFFFFE826      ; the fields of the clock's time, which is the 7th of V_BI, and its days since 1970
V_UF            .EQU    0xFFFFE830      ; for DIS: the fields dest, s0, and s1,
V_UC            .EQU    0xFFFFE833      ; their constant words,
V_UNOPS         .EQU    0xFFFFE836      ; and the operands of the mnemonic
V_LINE          .EQU    0xFFFFE840      ; the line, LINE_MAX words, one over for LOAD, and a 0
LINE_MAX        .EQU    76              ; as the monitor's line had, after a prompt of 2
V_TSRV          .EQU    0xFFFFE8A0      ; for TFTP: the server's IP address,
V_TTID          .EQU    0xFFFFE8A1      ; its port, its TID, 0 before its first DATA,
V_TBLK          .EQU    0xFFFFE8A2      ; the block waited for,
V_TLEN          .EQU    0xFFFFE8A3      ; the bytes of the packet at V_TPKT,
V_TTIME         .EQU    0xFFFFE8A4      ; the microseconds when it was sent,
V_TEND          .EQU    0xFFFFE8A5      ; the bytes of the DATA's block,
V_TPORT         .EQU    0xFFFFE8A6      ; the server's port for the RRQ,
V_TPKT          .EQU    0xFFFFE8B0      ; and the packet sent, a byte per word, up to TFTP_PKT
V_NTPIP         .EQU    0xFFFFE910      ; for NTP: the server's IP address, which dns_lookup writes
V_ENT           .EQU    0xFFFFE920      ; for DIR: an entry of fs_readname, 4 words,
V_NAME          .EQU    0xFFFFE924      ; and its name, 256 words
V_BLINE         .EQU    0xFFFFE924      ; for LOAD and SAVE of a program's text: the name, then a line of the file, in V_NAME
BLINE_MAX       .EQU    254             ; the characters of that line, with one over and a 0
V_FBUF          .EQU    0xFFFFEA24      ; for LOAD and SAVE: the bytes of fs_read and fs_write, FBUF_BYTES words
V_TBUF          .EQU    0xFFFFEAA4      ; for TFTP: a packet that udp_recv copied, TFTP_MAX words,
V_TSRC          .EQU    0xFFFFECA8      ; and its source's IP address and port, 2 words, to 0xFFFFECA9
V_LBEG          .EQU    0xFFFFECAA      ; for LOAD from a file: the line, V_LINE or V_BLINE,
V_LLIM          .EQU    0xFFFFECAB      ; and the word after its last character
V_SPOS          .EQU    0xFFFFECAC      ; while SAVE writes a program's text: the next free word of V_FBUF, else 0,
V_SERR          .EQU    0xFFFFECAD      ; and the error of a write, or 0
V_RUNF          .EQU    0xFFFFECAE      ; not 0 for RUN "NAME", which runs what LOAD loads
V_TLIM          .EQU    0xFFFFECAF      ; for the tokenizer: the last word of its tokens less 6, which a token starts below
V_NTPQ          .EQU    0xFFFFEAA4      ; for NTP, in V_TBUF: the query, 48 words,
V_NTPA          .EQU    0xFFFFEAD4      ; and the answer, 48 words

; The vectors, at BAS_COLD and BAS_WARM (common.nasm), which the monitor
; jumps to, and the header (issue #153, doc/BASIC_ROM.md, "The image").
; The words that are 0 here, the length, the checksum, the version as a
; number, and the flags, ../tools/basic_rom.py fills in after assembly.
                .ORG    BASIC_BASE
                JMP     bas_start
                JMP     bas_warm
                .DAT    BAS_MAGIC       ; 0x4004: the magic word, NBAS in packed ASCII
                .DAT    65536*MON_LAYOUT+MON_ENTRIES  ; 0x4005: the interface
                .DAT    0               ; 0x4006: the length in words, from BASIC_BASE
                .DAT    0               ; 0x4007: the checksum, the sum over the length is 0
                .DAT    VERSION         ; 0x4008: the version text, as the banner shows it
                .DAT    0               ; 0x4009: the version as a number
                .DAT    0               ; 0x400A: the flags, bit 0 "keep"
                .DAT    BASIC_WORDS     ; 0x400B: the words of BASIC's RAM, from STACK

; bas_warm: where mon_exit goes, with R1 the status of the program that
; left: the status shown, as SYS shows it, and then the main loop
bas_warm
                MOVE    SP, STACK
                CALL    sys_status
                JMP     main

; bas_start: where the cold start goes, at its end: the banner, and DUMP
; and DIS at 0x8000, and then the main loop
bas_start
                CLR     @V_HIMEM        ; the RAM's top
                CALL    new_prog        ; no program, and no variables
                CLR     @V_RHEAD        ; no keys typed ahead
                CLR     @V_RTAIL
                MOVE    @V_POLL, POLL_EVERY
                MOVE    @V_NEXT, PROGRAM
                MOVE    @V_UNEXT, PROGRAM
                CALL    versions
                CALL    _io_crlf
                MOVE    R1, S_HINT
                CALL    puts_b_crlf

; main: READY., on a row of its own, and the lines, each tokenized and
; run with a fresh SP
main            MOVE    SP, STACK
                CALL    files_end       ; what an error or the break key left open
                CLR     @V_CUR          ; direct mode
                CLR     @V_STORE
                CLR     @V_REDO
                CALL    SCR_GETXY
                TST     R1
        ?!Z     CALL    _io_crlf        ; after PRINT with ; or , at its end
                MOVE    R1, S_READY
                CALL    puts_b_crlf
main_line
                CLR     R1              ; CTRL-C empties the line
                CALL    getline
                MOVE    R5, V_LINE
:
                CMP     @R5, 0x20
        ?Z      MOVE    R5++, R5
        ?Z      JMP     :-
                SUB     R1, @R5, 0x30
                CMP     R1, 10
        ?C      JMP     enter_line      ; a number: a line to store
                CALL    tokenize
                MOVE    R8, V_TOK
                TST     @R8
        ?Z      JMP     main_line       ; blanks only
; run: the statements from R8, with colons between them. A statement is
; a keyword, or a variable and =. Each returns to run_next, with the end
; of the statement at V_TP. At the end of a line, the next line of the
; program runs, while one runs, and an ELSE at a statement's start, after
; the statements of THEN, ends the line.
run
                MOVE    @V_KW, R0
                MOVE    R1, @R8
                CMP     R1, T_COLON
        ?Z      MOVE    R8++, R8
        ?Z      JMP     run
                TST     R1
        ?Z      JMP     run_eol
                CMP     R1, T_ELSE
        ?Z      JMP     run_else
                SUB[M]  @V_POLL, @V_POLL, 1
        ?Z      CALL    poll            ; the break key
                MOVE    R1, @R8
                PUSH    run_next
                SHR     R2, R1, 24
                CMP     R2, K_VAR
        ?!Z     CMP     R2, K_ARR
        ?Z      JMP     st_assign
                CMP     R2, K_KW
        ?!Z     JMP     err_unknown
                MOVE    R8++, R8
                SHR     R2, R1, 8
                AND     R2, R2, 0xFF    ; the index of the keyword
                ADD     @V_KW, R2, 1
                DBL     R3, R2
                MOVE    R3, @H_ACTS[R3]  ; its routine
                CMP     R2, I_PRINT
        ?!C     JMP     R3              ; PRINT and LET read their own items
                PUSH    R3              ; the routine, which k_end returns to
                AND     R1, R1, 0xFF
                ADD     R10, R1, TEXT_B+4*OPS-0x20
                CLR     R11
                ONE     R12
                MOVE    @V_ARGS, R0
                MOVE    @V_ARGS+1, R0
; The ops, from R10
bas_op
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
        ?Z      JMP     bas_op
                JMP     err_syntax      ; with the lines of HELP of the statement
run_next
                MOVE    R8, @V_TP
                JMP     run
run_else
                CALL    tok_skip
                TST     @R8
        ?!Z     JMP     run_else
run_eol
                MOVE[M] R1, @V_CUR
        ?Z      JMP     main            ; direct mode
                ADD     R1, R8, 1       ; the next line
                CMP     R1, @V_PEND
        ?!C     JMP     main            ; the program's end
                MOVE    @V_CUR, R1
                ADD     R8, R1, 2
                JMP     run

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

; kw_addr: R3 the byte address of the keyword of index R1. Uses R1, R3,
; and R4.
kw_addr
                MOVE    R3, TEXT_B+4*OPS+KEYWORDS
:
                TST     R1
        ?Z      RET
:
                MOVE    R4, @R3++
                CMP     R4, 0x41        ; A
        ?!C     JMP     :-
                SUB     R1, R1, 1
                JMP     :--

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

; The items, each called by bas_op with R8 at its token: Z when it is
; there, with R1 its value and R8 after it.

; k_number: an expression, as a signed word, which sets the bit of the
; slot R12 in R11. It is not there at the end of the statement, a comma,
; or a string. Keeps R3 and R10-R12.
k_number
                MOVE    R1, @R8
                TST     R1
        ?!Z     CMP     R1, T_COLON
        ?!Z     CMP     R1, T_COMMA
        ?!Z     CMP     R1, T_ELSE
        ?Z      JMP     k_no
                SHR     R2, R1, 24
                CMP     R2, K_STR
        ?Z      JMP     k_no
                PUSH    R3
                PUSH    R10
                PUSH    R11
                PUSH    R12
                CALL    eval_word
                POP     R12
                POP     R11
                POP     R10
                POP     R3
                OR      R11, R11, R12
                CMP     R0, R0          ; Z
                RET
k_no
                CMP     R0, 1           ; not Z
                RET

; k_string: a string: R1 its first character, and a 0 after its last
k_string
                SHR     R2, @R8, 24
                CMP     R2, K_STR
        ?!Z     RET
                AND     R2, @R8, 0xFFFFFF
                ADD     R1, R8, 1
                ADD     R8, R8, R2
                ADD     R8, R8, 2
                CMP     R0, R0          ; Z
                RET

; k_comma: a comma, after which the values go to the next slot
k_comma
                CMP     @R8, T_COMMA
        ?Z      MOVE    R8++, R8
        ?Z      ADD     R12, R12, R12
                RET

; k_end: the end of the statement, a colon or the end of the line, which
; runs it: it returns to the routine, with R1-R3 the slots, instead of
; to bas_op, and the end at V_TP
k_end
                CALL    at_end
        ?!Z     RET
                POP     R0
                MOVE    @V_TP, R8
                MOVE    R1, @V_ARGS
                MOVE    R2, @V_ARGS+1
                MOVE    R3, @V_ARGS+3
                RET

; The routines of the statements that are not those of basic_cmd.nasm,
; basic_dis.nasm, basic_net.nasm, or basic_time.nasm alone

; TIME ["D T"]: clock_cmd with the string, or the end of the line
bas_time
                TST     R1
        ?Z      MOVE    R1, ZERO        ; an empty string
                JMP     clock_cmd
ZERO            .DAT    0

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

; DIR, DIR SLOT, and DIR "IP" [, "PAT"]. A negative SLOT, which st_dir
; would take as none, is one that no board has.
bas_dir
                TST     R11
        ?Z      JMP     :+
                TST     R1
        ?N      MOVE    R1, 0x7FFFFFFF  ; no such slot
                JMP     st_dir          ; the slot
:
                TST     R1
        ?Z      NOT     R1, R0          ; the card mounted
        ?Z      JMP     st_dir
                ONE     R3
                JMP     st_tftp

; LOAD, LOAD "NAME", and LOAD "NAME", "IP". A name that ends with .BIN,
; in either case, is a .bin file. A load that wrote a word below HIMEM,
; which may be over the program or its variables, ends with NEW, and at
; READY., and one that wrote no word ends the line; one that wrote above
; HIMEM alone goes on. Any other name is a program's text, NAME.BAS
; when NAME has no dot, which is copied to V_BLINE, as the statements
; after it may go. Its lines are stored as lines typed in, after a NEW
; at the first (basic_cmd.nasm, bas_eol), so that a file that is not
; there keeps the program; then READY. RUN "NAME" comes to bas_lrun,
; with V_RUNF set, and load_fin runs what was loaded.
bas_load
                CLR     @V_RUNF
bas_lrun
                CLR     @V_LSTATS       ; no word written yet
                PUSH    load_fin        ; where the load returns
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
        ?Z      JMP     load_go
                XOR     R6, R6, @R4++
                AND[M]  R0, R6, 0xDF
        ?Z      JMP     :-
:
                MOVE    R3, TEXT_B+4*S_DOTBAS
                CALL    name_copy
                CLR     @V_CUR
                ONE     @V_LBAS         ; NEW at the first line
load_go
                TST     R2
        ?Z      JMP     st_load
                MOVE    R3, R1          ; st_tftp: the server, the name, 0
                MOVE    R1, R2
                MOVE    R2, R3
                CLR     R3
                JMP     st_tftp

; name_copy: the name R1 copied to V_BLINE, with the extension at the
; byte address R3 after it when it has no dot, and R1 = V_BLINE. Keeps
; R2. Uses R1, R3, R4, and R5.
name_copy
                MOVE    R4, V_BLINE
                CLR     R5              ; no dot
:
                MOVE[M] @R4++, @R1++
        ?Z      JMP     :+
                CMP     @-1[R4], 0x2E   ; .
        ?Z      ONE     R5
                JMP     :-
:
                MOVE    R1, V_BLINE
                TST     R5
        ?!Z     RET
                SUB     R4, R4, 1       ; over the 0
:
                MOVE[M] @R4++, @R3++
        ?!Z     JMP     :-
                RET

; SAVE "NAME", the program's text, with .BAS added when the name has no
; dot (basic_cmd.nasm, st_text); SAVE "NAME", A, N, the words, with .BIN
; added; and SAVE "NAME", "IP", which TFTP cannot.
bas_save
                TST     R11
        ?!Z     JMP     :+
                TST     R2
        ?!Z     MOVE    R1, S_TFTPSAVE
        ?!Z     JMP     puts_b_crlf
                MOVE    R3, TEXT_B+4*S_DOTBAS
                CALL    name_copy
                JMP     st_text
:
                PUSH    R3              ; N, which name_copy uses
                MOVE    R3, TEXT_B+4*S_DOTBIN
                CALL    name_copy
                POP     R3
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
                .DAT    bas_dis+65536*SCR_CLS, st_ver+65536*st_help
                .DAT    st_halt+65536*bas_poke, st_new+65536*st_clr
                .DAT    st_end+65536*st_stop, st_cont+65536*st_return
                .DAT    st_print+65536*st_let, st_run+65536*st_list
                .DAT    st_goto+65536*st_gosub, st_if+65536*st_for
                .DAT    st_next+65536*st_rem, st_input+65536*st_get
                .DAT    st_dim+65536*st_himem
I_PRINT         .EQU    24              ; the index of PRINT, the first statement without ops,
I_LET           .EQU    25              ; of LET,
I_RUN           .EQU    26              ; of RUN,
I_GOTO          .EQU    28              ; of GOTO,
I_GOSUB         .EQU    29              ; of GOSUB,
I_IF            .EQU    30              ; of IF,
I_FOR           .EQU    31              ; of FOR,
I_REM           .EQU    33              ; of REM,
I_INPUT         .EQU    34              ; of INPUT,
I_GET           .EQU    35              ; of GET,
I_DIM           .EQU    36              ; of DIM,
I_HIMEM         .EQU    37              ; of HIMEM, which is also a number,
T_HIMEM         .EQU    K_KW*K+I_HIMEM*0x100+0x22  ; whose token this is,
N_STMT          .EQU    38              ; and of AND, the first keyword that is no statement
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
;  15  SAVE           J F L C N H L H N  a string, and the end, or a
;                                        comma, and a string and the
;                                        end, or a number, a comma, a
;                                        number, and the end
;  20  POKE           H L H N  a number, a comma, a number, and the end
;  22  SYS            H N      a number and the end
;  24  BAUD           @ N      a number or not, and the end
;  26  DUMP, DIS      @ E H N  a number or not, a comma and a number or
;                              not, and the end
;
; A number is an expression, which must fit a signed word. PRINT and LET
; read their own items, and their byte is that of the end, 2, as is that
; of each keyword that is no statement, whose token is in KW_TOK.
OP_N            .EQU    0
OP_S            .EQU    2
OP_C            .EQU    4
OP_E            .EQU    6
OP_SKIP         .EQU    1
OP_F            .EQU    8
KEYWORDS        .EQU    30              ; the first keyword's byte in OPS
OPS
                .ASCII_B 'FJNFANJEJNFJEJNJFLCNHLHN@N@EHNSYS6LOAD*SAVE/DELETE!DIR#IP DHCP"MAC TIME NTP*BAUD8DUMP:DIS:CLS"VER"HELP"HALT"POKE4NEW"CLR"END"STOP"CONT"RETURN"PRINT"LET"RUN"LIST"GOTO"GOSUB"IF"FOR"NEXT"REM"INPUT"GET"DIM"HIMEM"AND"OR"XOR"NOT"DIV"MOD"ABS"SGN"INT"SQR"PEEK"TAB"SPC"THEN"ELSE"TO"STEP"'

S_HINT          .ASCII_B 'HELP lists the statements'
S_READY         .ASCII_B 'READY.'
S_SYNTAX
                .ASCII_B 'Syntax error'
                .DAT    0
S_UNKNOWN
                .ASCII_B 'Syntax error; HELP lists the statements'
S_QUANT         .ASCII_B 'Illegal quantity'
                .DAT    0
S_TFTPSAVE
                .ASCII_B 'SAVE writes to the SD card: TFTP only loads'
S_DOTBIN
                .ASCII_B '.BIN'
                .DAT    0
S_DOTBAS
                .ASCII_B '.BAS'
                .DAT    0

; The lines of HELP, which a Syntax error also prints, those that start
; with the statement's keyword and a blank
HELP            .DAT    H_SYS, H_L, H_LOAD, H_TFTP, H_SAVET, H_SAVE, H_DEL, H_DIR, H_TFTPL, H_D, H_U
                .DAT    H_I, H_ID, H_M, H_B, H_T, H_TN, H_C, H_V, H_H, H_Q, H_PR, H_LET
                .DAT    H_POKE, H_RUN, H_RUNF, H_LIST, H_NEW, H_CLR, H_GOTO, H_GOSUB, H_RET, H_IF
                .DAT    H_FOR, H_NEXT, H_END, H_STOP, H_CONT, H_REM, H_INPUT, H_GET, H_DIM, H_HIMEM, H_P, H_PG, 0
H_SYS           .ASCII_B 'SYS A               call the program at A, such as SYS 0x8000; SYS 0 restarts'
H_L             .ASCII_B 'LOAD                enter lines of ADDR WORD in hex, as a .bin file has them'
                .DAT    0
H_LOAD          .ASCII_B 'LOAD "NAME"         load the program NAME.BAS, or NAME.BIN, from the SD card'
                .DAT    0
H_TFTP          .ASCII_B 'LOAD "NAME", "IP"   load it from the TFTP server at IP'
H_SAVET         .ASCII_B 'SAVE "NAME"         save the program as the text NAME.BAS'
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
H_PR            .ASCII_B 'PRINT X; "T", ...   print numbers and strings, ; and , between them; ? is PRINT'
H_LET           .ASCII_B 'LET V = X           set the variable V to the number X; LET may be left out'
H_POKE          .ASCII_B 'POKE A, X           write X to the word at A, which PEEK(A) reads'
H_RUN           .ASCII_B 'RUN [N]             run the program, from line N or its first, after CLR'
                .DAT    0
H_RUNF          .ASCII_B 'RUN "NAME" [, "IP"] load NAME and run it; NAME.BIN at 0x8000'
                .DAT    0
H_LIST          .ASCII_B 'LIST [N] [- M]      list the lines of the program, those from N to M'
                .DAT    0
H_NEW           .ASCII_B 'NEW                 delete the program and its variables'
                .DAT    0
H_CLR           .ASCII_B 'CLR                 clear the variables'
H_GOTO          .ASCII_B 'GOTO N              go on at line N'
H_GOSUB         .ASCII_B 'GOSUB N             go on at line N, and back after it at RETURN'
                .DAT    0
H_RET           .ASCII_B 'RETURN              go back after the last GOSUB'
                .DAT    0
H_IF            .ASCII_B 'IF X THEN S ELSE T  S when X is not 0, else T; each statements or a line N'
H_FOR           .ASCII_B 'FOR V = A TO B      V from A to B, by 1 or by STEP C after B, up to NEXT'
                .DAT    0
H_NEXT          .ASCII_B 'NEXT [V]            the loop of FOR again, or its end'
H_END           .ASCII_B 'END                 end the program'
H_STOP          .ASCII_B 'STOP                stop the program, which CONT goes on with'
H_CONT          .ASCII_B 'CONT                go on after STOP, END, or the break key'
H_REM           .ASCII_B 'REM TEXT            a remark, the rest of the line'
H_INPUT         .ASCII_B 'INPUT ["P";] V, ... the numbers of a line typed into V, ..., after the prompt P'
H_GET           .ASCII_B 'GET V               V the code of the next key typed, 0 when none, with no wait'
H_DIM           .ASCII_B 'DIM A(N), B(N, M)   the arrays A of N + 1 elements, B of N + 1 rows of M + 1'
                .DAT    0
H_HIMEM         .ASCII_B 'HIMEM = A           the top of the program, its variables, and arrays; and CLR'
H_P             .ASCII_B 'CRSR up down        scroll back a row, before a statement'
H_PG            .ASCII_B 'PgUp PgDn           a page; on the MEGA65 CTRL and MEGA with CRSR up or down'
                .DAT    0
