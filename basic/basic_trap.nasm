; BASIC's errors in a program (stage 9, issue #120, doc/BASIC.md,
; "Errors"): TRAP, RESUME, ER, EL, and ERR$, with BASIC 65's names and,
; where BASIC 65 has the error, its number.
;
; err (basic_expr.nasm) calls trap with the error's message. trap sets
; ER, the error's number from ERRS, and EL, the number of the line that
; ran, or -1 in direct mode. While a program runs with a TRAP, and no
; error waits for its RESUME, the error is trapped: the frames that the
; statement made go, unwound as RETURN unwinds them, the frames before
; it stay, and the program goes on at the TRAP's line. Else trap
; returns, and err prints the message, drops the frames, and goes back
; to READY., as with no TRAP. An error while one waits for its RESUME
; is not trapped, so a handler that fails stops the program. The break
; key is no error, and stops the program with a TRAP too.
;
; run keeps the statement that runs, its first token at V_STMT, and V_FP
; at its start at V_SFP, which trap unwinds to. In a FN over lines, a
; statement runs on the processor's stack of the expression that called
; the FN. That expression cannot go on, so trap goes back to the
; statement of the program's own level that called the outermost FN,
; which its FN frame keeps (basic_struct.nasm): RESUME runs that
; statement again, and RESUME NEXT goes on after it. EL is still the
; line in the FN where the error came.
;
; V_RTOK is the statement that RESUME goes back to, and V_RLINE its
; line, while an error waits for its RESUME; else V_RTOK is 0. TRAP ends
; the wait too, so that a handler that goes on with GOTO and a TRAP
; traps the next error again. drop_run, which RUN, CLR, NEW, an edit,
; and an error that is not trapped call, ends the TRAP and the wait.
;
; A failure of the card, the files, or the network is an error too
; (issue #158): io_fail keeps its number in DS and its text in DS$, as
; BASIC 65's disk status, and raises one of four errors, File not found,
; Device not present, File error, or Network error, whose ERR$ is a
; fixed text. When it is not trapped, err shows the text of DS$ in the
; place of the error's message, as the statement showed it before.

V_TRAP          .EQU    0xFFFFEFE2      ; the K_LINE token of TRAP's line, or 0 for no TRAP
V_ER            .EQU    0xFFFFEFE3      ; ER, the last error's number, or 0
V_EL            .EQU    0xFFFFEFE4      ; EL, its line's number, or -1
V_RTOK          .EQU    0xFFFFEFE5      ; the statement that RESUME goes back to, or 0,
V_RLINE         .EQU    0xFFFFEFE6      ; and its line
V_STMT          .EQU    0xFFFFEFE7      ; the first token of the statement that runs,
V_SFP           .EQU    0xFFFFEFE8      ; and V_FP at its start
V_DS            .EQU    0xFFFFEFE9      ; DS, the last failure's number, or 0,
V_DSS           .EQU    0xFFFFEFEA      ; and DS$, its text, packed, DSS_WORDS words, to 0xFFFFEFFF
DSS_WORDS       .EQU    22
DSS_MAX         .EQU    4*DSS_WORDS-1   ; the characters of DS$ at most
T_ER            .EQU    K_FN*K+0x200000  ; ER's token,
T_EL            .EQU    K_FN*K+0x200001  ; EL's,
T_DS            .EQU    K_FN*K+0x200002  ; DS's,
T_ERRS          .EQU    K_SFN*K+7       ; ERR$'s,
T_DSS           .EQU    K_SFN*K+8       ; and DS$'s
E_TBAD          .EQU    -65             ; BASIC's failures that no entry returns, after those of
E_NTPOFF        .EQU    -66             ; basic_net.nasm: no TFTP server, and no offset of NTP
N_TAG           .EQU    0x4E            ; N, a FN frame's letter

; trap: for the error of the message R7, ER and EL, and the error
; trapped, which goes on at the TRAP's line and does not return; or the
; return, when it is not trapped. Keeps R7. Uses R1-R12.
trap
                MOVE    R1, ERRS
:
                MOVE[M] R2, @R1++
        ?Z      JMP     :+              ; none: ER 0
                AND     R3, R2, 0xFFFF
                CMP     R3, R7
        ?!Z     JMP     :-
                SHR     R2, R2, 16
:
                MOVE    @V_ER, R2
                MOVE[M] R1, @V_CUR
        ?!Z     MOVE    R1, @1[R1]      ; the line's number
        ?Z      NOT     R1, R0          ; -1 in direct mode
                MOVE    @V_EL, R1
                TST     @V_CUR
        ?Z      RET                     ; direct mode
                TST     @V_RTOK
        ?!Z     RET                     ; a handler's error
                MOVE[M] R3, @V_TRAP
        ?Z      RET                     ; no TRAP
                AND     R3, R3, 0xFFFFFF
                CALL    find_line
        ?!Z     RET                     ; no such line
                MOVE    R10, R1         ; the TRAP's line
                MOVE    R9, @V_CUR      ; the line of the statement
                CMP     @V_SBASE, STACK
        ?Z      JMP     tr_unwind
                CALL    himem           ; in a FN over lines: the last FN frame,
                MOVE    R4, @V_FP       ; the outermost
                CLR     R5
:
                CMP     R4, R2
        ?!C     JMP     :+
                SHR     R6, @R4, 24
                CMP     R6, N_TAG
        ?Z      MOVE    R5, R4
                SHR     R6, @R4, 16
                AND     R6, R6, 0xFF
                ADD     R4, R4, R6
                JMP     :-
:
                TST     R5
        ?Z      RET                     ; none, which cannot be
                MOVE    R9, @2[R5]      ; the call's line,
                MOVE    @V_SSB, @3[R5]  ; its strings,
                MOVE    @V_STMT, @6[R5]  ; its statement,
                MOVE    @V_SFP, @7[R5]  ; and its frames
                MOVE    @V_SBASE, STACK
                MOVE    @V_ELIM, STACK-EXPR_ROOM
tr_unwind
                MOVE    R1, @V_SFP
                CMP     @V_FP, R1
        ?C      CALL    unwind          ; the statement's frames
                MOVE    @V_RTOK, @V_STMT
                MOVE    @V_RLINE, R9
                CALL    files_end       ; what the statement left open
                MOVE    SP, STACK
                MOVE    @V_SSP, @V_SSB
                MOVE    @V_CUR, R10
                ADD     R8, R10, 2
                JMP     run

; TRAP N: an error while the program runs goes on at line N; TRAP alone:
; none does. Either ends the wait of an error for its RESUME.
st_trap
                CLR     R3
                SHR     R2, @R8, 24
                CMP     R2, K_LINE
        ?Z      MOVE    R3, @R8
        ?Z      ADD     R8, R8, 2
                CALL    stmt_end
                MOVE    @V_TRAP, R3
                CLR     @V_RTOK
                RET

; RESUME: the statement of the error again; RESUME NEXT: on after it, or
; after the line of an IF; RESUME N: on at line N. Can't resume when no
; error waits for its RESUME. The error waits until RESUME has found its
; place, so that a line N that is not there is an error of the handler,
; which stops the program, and not one that the TRAP takes again.
st_resume
                MOVE[M] R9, @V_RTOK
        ?Z      JMP     err_resume
                SHR     R2, @R8, 24
                CMP     R2, K_LINE
        ?!Z     JMP     :+
                CALL    st_goto         ; which checks the statement's end, and the line
                CLR     @V_RTOK
                RET
:
                AND     R10, @R8, 0xFFFFFF00
                CMP     R10, K_KW*K+I_NEXT*0x100
        ?Z      MOVE    R8++, R8
                CALL    stmt_end
                CLR     @V_RTOK
                MOVE    @V_CUR, @V_RLINE
                MOVE    R8, R9
                CMP     R10, K_KW*K+I_NEXT*0x100
        ?!Z     JMP     rs_go
                AND     R1, @R8, 0xFFFFFF00
                CMP     R1, K_KW*K+I_IF*0x100
        ?Z      JMP     rs_eol
:
                CALL    tok_skip        ; the statement passed over
                CALL    at_end
        ?!Z     JMP     :-
                JMP     rs_go
rs_eol
                CALL    tok_skip        ; an IF: its whole line
                TST     @R8
        ?!Z     JMP     rs_eol
rs_go
                MOVE    @V_TP, R8
                RET

; ER, EL, and DS, which primary's p_fn comes to with R1 the token
p_er
                MOVE    R2, @V_DS
                CMP     R1, T_EL
        ?Z      MOVE    R2, @V_EL
                CMP     R1, T_ER
        ?Z      MOVE    R2, @V_ER
                MOVE    @FPU_X_W, R2
                RET

; DS$: the text of the last failure, or an empty string before the first
f_ds
                CLR     R2
                TST     @V_DS
        ?Z      JMP     s_push
                CALL    ds_get
                JMP     s_text

; io_fail: the failure R1, a negative number, the error of an entry or
; one of BASIC's own, E_*, raised as an error. DS is its number, -R1,
; and DS$ its text, which io_text writes with putc into V_FBUF and
; ds_pack packs. The error is File not found for the file error 21, and
; for the TFTP error 1; Device not present for those of NODEVS; else
; File error below 40, and Network error from 40 on. The load of a
; program's text ends here, so that err shows no line of it. R7 is the
; failure, R8 its number, and R9 the code of a TFTP server's ERROR.
io_fail
                MOVE    R7, R1
                SUB     R8, R0, R1
                MOVE    @V_DS, R8
                CLR     @V_LBAS
                CLR     R9
                MOVE    @V_SPOS, V_FBUF
                CALL    io_text
                MOVE    R1, @V_SPOS
                CLR     @R1
                CLR     @V_SPOS
                CALL    ds_pack
                MOVE    R1, S_NOFILE
                CMP     R8, 21
        ?!Z     CMP     R9, 1
        ?Z      JMP     err
                MOVE    R1, S_NODEV
                MOVE    R2, NODEVS
:
                MOVE[M] R3, @R2++
        ?Z      JMP     :+
                CMP     R3, R8
        ?!Z     JMP     :-
                JMP     err
:
                MOVE    R1, S_FILE
                CMP     R8, 40
        ?!C     MOVE    R1, S_NET
                JMP     err

; The failures that are Device not present: no card, no such slot, no
; IP address, no answer to ARP, from a DHCP server, from a DNS server,
; or from the time server, no DNS server, and no answer from the TFTP
; server
NODEVS
                .DAT    1, 27, 40, 44, 45, 46, 47, 60, 63, 0

; io_text: the text of the failure R7, of the number R8, with putc: of
; the SD controller, 1 to SD_ERRS, its number, the slot, its meaning,
; and the sector after error 7; a file error, below 40, its number and
; its meaning; one of IO_TEXTS (basic_net.nasm), its text, with the
; server's code for a kiss-o'-death of NTP and the code and the message
; of a TFTP server's ERROR, R9 its code; and any other, Network error and
; its number. Keeps R7 and R8. Uses R1-R6 and R9.
io_text
                CMP     R8, SD_ERRS+1
        ?!C     JMP     :+
                MOVE    R1, S_SDERR
                CALL    io_num
                MOVE    R1, S_INSLOT
                CALL    io_b
                MOVE    R1, @SD_SELECT
                CALL    putdec
                ADD     R1, R8, SD_ERRORS-1
                MOVE    R6, @R1
                CALL    io_comma
                CMP     R8, 7
        ?!Z     RET
                MOVE    R6, @SD_LAST
                MOVE    R5, 8
io_hex
                ROL     R6, R6, 4
                AND     R1, R6, 0xF
                ADD     R1, R1, 0x30
                CMP     R1, 0x3A
        ?!C     ADD     R1, R1, 7       ; A to F
                CALL    putc
                SUB[M]  R5, R5, 1
        ?!Z     JMP     io_hex
                RET
:
                CMP     R8, 40
        ?!C     JMP     :+
                MOVE    R1, S_FSERR
                CALL    io_num
                SUB     R1, R8, FS_ERR0
                CMP     R1, FS_ERRS
        ?!C     RET                     ; an error without a meaning here
                ADD     R1, R1, FS_ERRORS
                MOVE    R6, @R1
                JMP     io_comma        ; which returns to the caller
:
                MOVE    R2, IO_TEXTS
:
                MOVE[M] R1, @R2++
        ?Z      JMP     io_other        ; none
                MOVE    R3, @R2++
                CMP     R1, R7
        ?!Z     JMP     :-
                MOVE    R1, R3
                CALL    io_b
                CMP     R7, E_NTPKOD
        ?Z      JMP     io_kod
                CMP     R7, E_HSTATUS
        ?Z      JMP     io_http
                CMP     R7, E_TERROR
        ?!Z     RET
                MOVE    R5, V_TBUF      ; the ERROR
                CMP     @V_TOP, 1
        ?!Z     MOVE    R5, V_TPKT
                ADD     R6, R5, @V_TEND
                SHL     R9, @2[R5], 8
                OR      R9, R9, @3[R5]
                MOVE    R1, R9
                CALL    putdec
                MOVE    R1, S_UCOMMA
                CALL    io_b
                ADD     R5, R5, 4
io_chars
                CMP     R5, R6
        ?!C     RET
                MOVE[M] R1, @R5++
        ?Z      RET
                CMP     @V_SPOS, V_FBUF+DSS_MAX
        ?!C     RET                     ; no more fits in DS$
                SUB     R2, R1, 0x20
                CMP     R2, 0x5F
        ?!C     JMP     io_chars        ; a control code
                CALL    putc
                JMP     io_chars
; HTTP$'s status, File not found for 404, as the TFTP error 1, and the
; Location or the first line of the body, if there is one
io_http
                MOVE    R1, @V_HSTAT
                CMP     R1, 404
        ?Z      ONE     R9
                CALL    putdec
                MOVE[M] R6, @V_HDS
        ?Z      RET
                MOVE    R1, S_UCOMMA
                CALL    io_b
                MOVE    R5, V_HDST
                ADD     R6, R6, R5
                JMP     io_chars
io_other
                MOVE    R1, S_NET
                CALL    io_b
                CALL    put_blank
                MOVE    R1, R8
                JMP     putdec          ; which returns to the caller
; The 4 characters of the reference ID, with ? for one that does not print
io_kod
                MOVE    R1, V_NTPA+12
                CALL    get32
                MOVE    R6, R1
                MOVE    R5, 4
:
                ROL     R6, R6, 8
                AND     R1, R6, 0xFF
                SUB     R2, R1, 0x20
                CMP     R2, 0x5F
        ?!C     MOVE    R1, 0x3F        ; ?
                CALL    putc
                SUB[M]  R5, R5, 1
        ?!Z     JMP     :-
                RET

; io_num: the packed text R1 and the number R8, with putc. io_comma:
; a comma, a blank, and the packed text R6. io_b: the packed text R1.
; Use R1-R4.
io_num
                CALL    io_b
                MOVE    R1, R8
                JMP     putdec          ; which returns to the caller
io_comma
                MOVE    R1, S_UCOMMA
                CALL    io_b
                MOVE    R1, R6
io_b
                PUSH    R5
                SHL     R5, R1, 2
                ADD     R5, R5, TEXT_B
:
                MOVE[M] R1, @R5++
        ?Z      JMP     :+
                CALL    putc
                JMP     :-
:
                POP     R5
                RET

; ds_pack: the characters at V_FBUF, up to a 0, packed into V_DSS, four
; a word, the first in bits 31..24, up to DSS_MAX of them, and 0 bytes
; after them. Uses R1-R6.
ds_pack
                MOVE    R5, V_FBUF
                MOVE    R6, V_DSS
:
                CLR     R1
                MOVE    R4, 4
:
                SHL     R1, R1, 8
                MOVE[M] R2, @R5
        ?!Z     ADD     R5, R5, 1       ; which stays at the 0
                OR      R1, R1, R2
                SUB[M]  R4, R4, 1
        ?!Z     JMP     :-
                MOVE    @R6++, R1
                CMP     R6, V_DSS+DSS_WORDS
        ?!Z     JMP     :--
                AND     @V_DSS+DSS_WORDS-1, @V_DSS+DSS_WORDS-1, 0xFFFFFF00
                RET

; ds_get: the characters of DS$ at V_FBUF, and a 0: R1 V_FBUF and R2
; their number. Uses R1-R6.
ds_get
                MOVE    R5, V_DSS
                MOVE    R6, V_FBUF
:
                MOVE    R1, @R5++
                MOVE    R4, 4
:
                ROL     R1, R1, 8
                AND[M]  R2, R1, 0xFF
        ?Z      JMP     :+
                MOVE    @R6++, R2
                SUB[M]  R4, R4, 1
        ?!Z     JMP     :-
                JMP     :--
:
                CLR     @R6
                MOVE    R1, V_FBUF
                SUB     R2, R6, V_FBUF
                RET

; msg_text: for put_msg, the packed text R1, with puts_b, or for the
; error of a failure the text of DS$. Uses R1-R6.
msg_text
                CMP     R1, S_NOFILE
        ?!Z     CMP     R1, S_NODEV
        ?!Z     CMP     R1, S_FILE
        ?!Z     CMP     R1, S_NET
        ?!Z     JMP     puts_b          ; which returns to the caller
                CALL    ds_get
                MOVE    R5, R1
:
                MOVE[M] R1, @R5++
        ?Z      RET
                CALL    MON_PUTC
                JMP     :-

; ERR$(N): the message of the error number N, as err prints it, or an
; empty string for 0; any other N is an Illegal quantity
f_err
                CALL    paren_word
                CLR     R2
                TST     R1
        ?Z      JMP     s_push          ; the empty string, at 0
                MOVE    R4, R1
                MOVE    R2, ERRS
:
                MOVE[M] R1, @R2++
        ?Z      JMP     err_quant
                SHR     R3, R1, 16
                CMP     R3, R4
        ?!Z     JMP     :-
                AND     R1, R1, 0xFFFF  ; the message, packed,
                SHL     R5, R1, 2       ; through the byte window
                ADD     R5, R5, TEXT_B
                MOVE    R4, V_SCR
:
                MOVE[M] R1, @R5++
        ?Z      JMP     :+
                MOVE    @R4++, R1
                JMP     :-
:
                SUB     R2, R4, V_SCR
                MOVE    R1, V_SCR
                JMP     s_text

err_resume
                MOVE    R1, S_RESUME
                JMP     err

; The errors' numbers, a word each: the message in bits 15..0, and its
; number in bits 31..16, BASIC 65's for the errors that it has, and from
; 100 on for those that it has not. ERR$ takes the first of a number.
ERRS
                .DAT    S_NOFILE+65536*4, S_NODEV+65536*5
                .DAT    S_NEXT+65536*10, S_SYNTAX+65536*11, S_UNKNOWN+65536*11
                .DAT    S_RETNG+65536*12, S_DATA+65536*13, S_QUANT+65536*14
                .DAT    S_OVERFLOW+65536*15, S_MEMORY+65536*16, S_LINE+65536*17
                .DAT    S_SUBSCR+65536*18, S_REDIM+65536*19, S_DIVZERO+65536*20
                .DAT    S_TYPE+65536*22, S_STRLONG+65536*23, S_COMPLEX+65536*25
                .DAT    S_CONT+65536*26, S_FN+65536*27, S_RESUME+65536*31
                .DAT    S_NOLOOP+65536*32, S_LOOP+65536*33
                .DAT    S_UNDEF+65536*100, S_ARRAY+65536*101, S_PROC+65536*102
                .DAT    S_FNRET+65536*103, S_NOEQ+65536*104, S_ENDPROC+65536*105
                .DAT    S_LOCAL+65536*106, S_EXIT+65536*107, S_ENDIF+65536*108
                .DAT    S_LONG+65536*109, S_NONUM+65536*110, S_CHAR+65536*111
                .DAT    S_FILE+65536*112, S_NET+65536*113
                .DAT    0

S_NOFILE
                .ASCII_B 'File not found'
S_NODEV         .ASCII_B 'Device not present'
S_FILE          .ASCII_B 'File error'
S_NET           .ASCII_B 'Network error'

S_RESUME
                .ASCII_B "Can't resume"
                .DAT    0
