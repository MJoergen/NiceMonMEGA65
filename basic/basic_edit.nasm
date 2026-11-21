; BASIC's screen editor (issue #118, doc/BASIC.md, "The screen editor"),
; which the Makefile joins after basic_dis.nasm (basic.nasm's header).
; getline reads BASIC's line from the screen: the cursor keys move over
; it, typing inserts, DEL deletes to the left, and RETURN takes the
; logical line that the cursor is in, the rows that go on from the row
; above, as scr_links has them, up to EDIT_MAX characters. A position in
; a logical line is its offset from the line's first row, 80 a row, as
; the screen's words of the rows follow each other. Its variables,
; V_ECOL, V_ESR, V_ESC, V_EMOV, and V_EKEY, are in basic.nasm.

PAGE            .EQU    ROWS-1          ; the rows of Page Up and Page Down, as the monitor's
SCR_LAST        .EQU    SCREEN+SCR_WORDS-80  ; the screen's last row

; getline: the line of BASIC at V_LINE, up to EDIT_MAX characters and a
; 0, from the screen, with the keys typed ahead first. RETURN takes the
; logical line of the cursor, from the position where the first key came
; when it is that line, as after INPUT's prompt, else from its start. A
; line of more than EDIT_MAX characters, as LIST may show one, is a Line
; too long, err_long, as it is for LOAD, and is not taken shortened.
; The cursor keys and HOME, ESC [ H, move the cursor, and the cursor key
; down scrolls at the last row; DEL and BS delete to the left within the
; line; TAB completes the name of a file of the card (fs_complete) at
; the end of the line's text or after it; and CTRL-C empties the line, or is a break
; at INPUT when R1 is not 0. Page Up and Page Down show the scrollback a
; page back or forward (scr_back), until another key; an ESC with
; another sequence, or alone, is dropped. A key typed at the end of the
; line's text goes to the line as well, as before; after any other key,
; or when the line had text after the cursor at the first key, the line
; is sent again at RETURN, and only the screen shows the moves. While it
; waits for the first key, the address that DHCP gets in the background
; is shown, but only in a line with no text: not after AUTO's number,
; INPUT's prompt, or the line that ed_redo shows again, nor on a row with
; text from before, which it would go over. The line starts on blanks
; after READY., AUTO's number, INPUT's prompt, and the line that ed_redo
; shows again (ed_fresh), so only the row after a line that was stored
; keeps its text, the next line of a listing, which RETURN enters again.
; Uses R1-R10.
getline
                MOVE    R10, R1         ; INPUT's
                CLR     R7              ; the rows shown back
                CLR     @V_EKEY
                CLR     @V_EMOV
                CLR     R1              ; the color, from scr_color
                CALL    SCR_COLOR
                MOVE    @V_ECOL, R1
                CALL    SCR_COLOR
gl_key
                TST     @V_EKEY
        ?!Z     JMP     :+
                CALL    ed_ext          ; before the line's first key, and with
                MOVE    R1, 3           ; no text in the line: wait, and show
                TST     R6              ; what DHCP gets, which goes over the
        ?Z      JMP     :++             ; line from its start (con_key)
:
                MOVE    R1, 1           ; wait
:
                CALL    key
                TST     @V_EKEY
        ?!Z     JMP     gl_have
                PUSH    R1              ; where the line starts: at the first key
                CALL    SCR_GETXY
                MOVE    @V_ESC, R1
                MOVE    @V_ESR, R2
                ONE     @V_EKEY
                CALL    ed_ext          ; text after the cursor, which the
                CMP     R5, R6          ; line has not seen: sent at RETURN
        ?C      ONE     @V_EMOV
                POP     R1
gl_have
                CMP     R1, 0x1B
        ?Z      JMP     gl_esc
                PUSH    R1
                CALL    gl_leave
                POP     R1
                CMP     R1, 0x0D
        ?Z      JMP     gl_end
                CMP     R1, 0x7F
        ?!Z     CMP     R1, 0x08
        ?Z      JMP     gl_del
                CMP     R1, 0x03
        ?Z      JMP     gl_cc
                CMP     R1, 0x09
        ?Z      JMP     gl_tab
                CMP     R1, 0x20
        ?C      JMP     gl_key          ; another control code
                CMP     R1, 0xA0
        ?!C     JMP     gl_ins          ; 0xA0 and above
                CMP     R1, 0x80
        ?!C     JMP     gl_key          ; 0x80 to 0x9F
; R1 inserted at the cursor: the text from the cursor moves on by one,
; with a row added to the line when it would fill its last, unless the
; line would have more than EDIT_MAX characters
gl_ins
                MOVE    R8, R1
                CALL    ed_ext
                MOVE    R1, R6          ; the text's end after the key, less 1:
                CMP     R1, R5          ; the end, or the cursor past it
        ?C      MOVE    R1, R5
                CMP     R1, EDIT_MAX
        ?!C     JMP     gl_key          ; the line is full
                CMP     R5, R6
        ?C      ONE     @V_EMOV         ; within the text, not at its end
                ADD     R1, R1, 1
                SUB     R2, R4, R3
                ADD     R2, R2, 1
                CALL    ed_x80
                CMP     R1, R2
        ?!C     CALL    ed_grow         ; the last row would be full
                MOVE    R1, R3
                CALL    ed_row
                ADD     R1, R1, R5      ; the cursor's word
                ADD     R2, R1, R6
                SUB     R2, R2, R5      ; the word after the text
:
                CMP     R2, R1
        ?C      JMP     :+
        ?Z      JMP     :+
                MOVE    @R2, @-1[R2]
                SUB     R2, R2, 1
                JMP     :-
:
                OR      @R1, R8, @V_ECOL
                TST     @V_EMOV
        ?!Z     JMP     :+
                MOVE    R1, R8          ; at the end, to the line as well
                CALL    ed_line
:
                ADD     R1, R5, 1
                CALL    ed_to
                JMP     gl_key
; DEL and BS: the character left of the cursor deleted, and the text
; after it moved back by one, but not at the line's start
gl_del
                CALL    ed_ext
                CALL    ed_floor
                CMP     R9, R5
        ?!C     JMP     gl_key          ; at the start
                CMP     R6, R5
        ?C      JMP     :+++            ; past the text: the cursor alone
                MOVE    R1, R3
                CALL    ed_row
                ADD     R1, R1, R5      ; the cursor's word
                ADD     R2, R1, R6
                SUB     R2, R2, R5      ; the word after the text
:
                CMP     R1, R2
        ?Z      JMP     :+
                MOVE    @-1[R1], @R1
                ADD     R1, R1, 1
                JMP     :-
:
                OR      @-1[R2], @V_ECOL, 0x20
:
                CMP     R5, R6
        ?C      ONE     @V_EMOV         ; within the text, not at its end
                TST     @V_EMOV
        ?!Z     JMP     :+
                MOVE    R1, 0x08        ; at the end, BS, a blank, BS to the line
                CALL    ed_line
                MOVE    R1, 0x20
                CALL    ed_line
                MOVE    R1, 0x08
                CALL    ed_line
:
                SUB     R1, R5, 1
                CALL    ed_to
                JMP     gl_key
; CTRL-C: a break at INPUT, else ^C after the line's text, or at the
; cursor past it, and an empty line
gl_cc
                TST     R10
        ?!Z     JMP     in_break
                CALL    ed_ext
                MOVE    R1, R6          ; after the text, or at the cursor past it
                CMP     R1, R5
        ?C      MOVE    R1, R5
                CALL    ed_to
                MOVE    R1, GL_CC
                CALL    _io_puts
                CLR     @V_LINE
                JMP     _io_crlf        ; which returns to the caller
; TAB at the end of the line's text, or after it: the text to the
; cursor to V_LINE, fs_complete on
; it, and the line's start from where the cursor ends, as fs_complete
; may show the line again on a row of its own
gl_tab
                CALL    ed_ext
                CMP     R5, R6
        ?C      JMP     gl_key          ; within the text
                MOVE    R6, R5          ; the text to the cursor, with its blanks
                CALL    ed_floor
                CALL    ed_copy
                MOVE    R2, R1
                MOVE    R1, V_LINE
                MOVE    R3, V_LINE+EDIT_MAX
                CALL    FS_COMPLETE
                SUB     R8, R1, V_LINE  ; the characters before the cursor
                CALL    SCR_GETXY
                CALL    ed_x80
                ADD     R1, R1, R2
                SUB[M]  R1, R1, R8      ; the start, 80 a row from row 0
        ?C      CLR     R1
                CLR     R2
:
                CMP     R1, 80
        ?C      JMP     :+
                SUB     R1, R1, 80
                ADD     R2, R2, 1
                JMP     :-
:
                MOVE    @V_ESC, R1
                MOVE    @V_ESR, R2
                JMP     gl_key
; RETURN: the logical line from its start, or from where the first key
; came, to V_LINE; again to the line, after a move, from the line's
; first row; and the cursor to the row after the line's last. Then, when
; the line had more than EDIT_MAX characters, a Line too long.
gl_end
                CALL    ed_ext
                CALL    ed_floor
                CALL    ed_copy
                PUSH    R4
                TST     @V_EMOV
        ?Z      JMP     :++
                MOVE    R1, R3
                CALL    ed_row
                MOVE    R9, R1
                ADD     R8, R1, R6      ; the word after the text
                MOVE    R1, 0x0D
                CALL    ed_line
:
                CMP     R9, R8
        ?Z      JMP     :+
                AND     R1, @R9++, 0xFF
                CALL    ed_line
                JMP     :-
:
                POP     R2
                CLR     R1
                CALL    SCR_MOVETO      ; the line's last row
                CALL    _io_crlf
                TST     R5              ; the characters that ed_copy left out
        ?!Z     JMP     err_long
                RET
; An ESC: with [ or O within io.t_esc a sequence, else the byte after it
; on its own, or nothing. ESC [ A to D move the cursor, ESC [ H to the
; top left, and ESC [ 5 ~ and 6 ~ show the scrollback; the bytes of any
; other sequence, up to its final byte, are dropped.
gl_esc
                CALL    key_soon
        ?Z      JMP     gl_drop
                CMP     R1, 0x4F        ; O: one more byte
        ?Z      JMP     gl_ss3
                CMP     R1, 0x5B        ; [
        ?!Z     JMP     gl_have
                CALL    key_soon
        ?Z      JMP     gl_drop
                MOVE    R8, R1
                CMP     R1, 0x41        ; A
        ?Z      JMP     gl_up
                CMP     R1, 0x42        ; B
        ?Z      JMP     gl_down
                CMP     R1, 0x43        ; C
        ?Z      JMP     gl_right
                CMP     R1, 0x44        ; D
        ?Z      JMP     gl_left
                CMP     R1, 0x48        ; H
        ?Z      JMP     gl_home
:
                CMP     R1, 0x40
        ?!C     JMP     :+              ; the final byte
                CALL    key_soon
        ?Z      JMP     gl_drop
                JMP     :-
:
                CMP     R1, 0x7E        ; ~, after 5 or 6
        ?!Z     JMP     gl_drop
                CMP     R8, 0x35        ; 5
        ?Z      MOVE    R1, PAGE
        ?Z      JMP     gl_back
                CMP     R8, 0x36        ; 6
        ?Z      MOVE    R1, -PAGE
        ?Z      JMP     gl_back
                JMP     gl_drop
gl_ss3
                CALL    key_soon
gl_drop
                CALL    gl_leave
                JMP     gl_key
; R1 rows back, or -R1 forward
gl_back
                CALL    SCR_BACK
                MOVE    R7, R1
                JMP     gl_key
; The cursor keys: up and down a row, the last row scrolled for down,
; left and right a column, to the row before or after at the ends
gl_up
                CALL    gl_leave
                CALL    SCR_GETXY
                SUB[M]  R2, R2, 1
        ?C      JMP     gl_key          ; at the top
                JMP     gl_at
gl_down
                CALL    gl_leave
                CALL    SCR_GETXY
                ADD     R2, R2, 1
                CMP     R2, ROWS
        ?C      JMP     gl_at
                PUSH    R1
                CALL    ed_scroll
                POP     R1
                MOVE    R2, ROWS-1
                JMP     gl_at
gl_right
                CALL    gl_leave
                CALL    SCR_GETXY
                ADD     R1, R1, 1
                CMP     R1, 80
        ?C      JMP     gl_at
                CMP     R2, ROWS-1
        ?Z      JMP     gl_key          ; at the bottom right
                CLR     R1
                ADD     R2, R2, 1
                JMP     gl_at
gl_left
                CALL    gl_leave
                CALL    SCR_GETXY
                SUB[M]  R1, R1, 1
        ?!C     JMP     gl_at
                SUB[M]  R2, R2, 1
        ?C      JMP     gl_key          ; at the top left
                MOVE    R1, 79
                JMP     gl_at
gl_home
                CALL    gl_leave
                CLR     R1
                CLR     R2
gl_at
                CALL    SCR_MOVETO
                ONE     @V_EMOV
                JMP     gl_key

; gl_leave: the screen again, after the rows shown back. Uses R1-R6.
gl_leave
                TST     R7
        ?Z      RET
                CLR     R1
                CLR     R7
                JMP     SCR_BACK

; ed_redo: the check at entry (issue #118, step 3): after an error of
; the tokenizer in the line typed, which stores no line, the line again
; after READY., on the screen and the line, with the cursor at the error
; for the fix, at the word of V_LINE where the tokenizer stopped, which
; err kept in V_EPOS. Only when no key waits, in the ring or at the
; console, as a person types: the lines that a host pastes come one
; after the other, and the next would go into this one. A key that
; waits goes into the ring. Uses R1-R8.
ed_redo
                MOVE    R2, @V_RTAIL
                CMP     R2, @V_RHEAD
        ?!Z     JMP     :++             ; keys typed ahead
                CLR     R1
                CALL    CON_KEY
                TST     R1
        ?N      JMP     :+              ; none
                CALL    ring_put
                JMP     :++
:
                SUB     R8, @V_EPOS, V_LINE  ; the error's position
                CMP     R8, EDIT_MAX+1
        ?C      JMP     :++
:
                CLR     @V_EPOS
                RET
:
                CLR     @V_EPOS
                MOVE    R7, V_LINE
:
                MOVE[M] R1, @R7++
        ?Z      JMP     :+
                CALL    MON_PUTC
                JMP     :-
:
                CALL    ed_fresh        ; no text from before after it
                SUB     R7, R7, V_LINE+1  ; the characters
                CALL    SCR_GETXY
                CALL    ed_x80
                ADD     R1, R1, R2
                SUB     R1, R1, R7      ; the line's start, 80 a row from row 0,
                ADD     R1, R1, R8      ; and its error
                CLR     R3
                JMP     ed_to

; ed_fresh: blanks from the cursor to the end of its row, in the current
; color, and the row after it a line of its own, its bit of scr_links
; cleared, for the line that is typed next: what a program, a POKE, or a
; line from before left there would be part of it at RETURN, which takes
; the line from the screen. Uses R1-R6.
ed_fresh
                CALL    SCR_GETXY
                MOVE    R5, R1
                MOVE    R6, R2
                CLR     R1
                CALL    SCR_COLOR
                MOVE    R3, R1          ; the color, which scr_color uses not
                CALL    SCR_COLOR       ; back
                OR      R3, R3, 0x20
                MOVE    R1, R6
                CALL    ed_row
                ADD     R2, R1, 80      ; the word after the row
                ADD     R1, R1, R5
:
                MOVE    @R1++, R3
                CMP     R1, R2
        ?!Z     JMP     :-
                NOT     R1, R0
                CALL    SCR_LINKS
                MOVE    R2, 2
                SHL     R2, R2, R6
                NOT     R2, R2
                AND     R1, R1, R2
                JMP     SCR_LINKS

; ed_ext: the logical line of the cursor's row, from scr_links: R3 its
; first row, R4 its last, R5 the cursor's position in it, and R6 the end
; of its text, the position after its last character that is no blank,
; or 0. Uses R1-R6.
ed_ext
                NOT     R1, R0
                CALL    SCR_LINKS
                MOVE    R6, R1
                CALL    SCR_GETXY
                MOVE    R5, R1
                MOVE    R3, R2
:
                SHR     R4, R6, R3      ; up while a row goes on from the row above
                AND[M]  R0, R4, 1
        ?Z      JMP     :+
                SUB     R3, R3, 1
                ADD     R5, R5, 80
                JMP     :-
:
                MOVE    R4, R2
:
                ADD     R1, R4, 1       ; down while the next goes on from it
                CMP     R1, ROWS
        ?Z      JMP     :+
                SHR     R1, R6, R1
                AND[M]  R0, R1, 1
        ?Z      JMP     :+
                ADD     R4, R4, 1
                JMP     :-
:
                MOVE    R1, R3
                CALL    ed_row
                MOVE    R6, R1          ; the line's first word
                ADD     R1, R4, 1
                CALL    ed_row          ; the word after the line
:
                CMP     R1, R6
        ?Z      JMP     :+
                SUB     R1, R1, 1
                AND     R2, @R1, 0xFF
                CMP     R2, 0x21
        ?C      JMP     :-              ; a blank, or a control code's
                ADD     R1, R1, 1
:
                SUB     R6, R1, R6
                RET

; ed_floor: R9 the position in the line of the rows R3 to R4 where the
; first key came, in INPUT's line, R10 not 0, when it came in that line,
; else 0, as a line typed for the main loop starts at its row's start.
; Uses R1 and R2.
ed_floor
                CLR     R9
                TST     R10
        ?Z      RET                     ; not INPUT's line
                MOVE    R1, @V_ESR
                CMP     R1, R3
        ?C      RET                     ; above the line, or none
                CMP     R4, R1
        ?C      RET                     ; below it
                SUB     R2, R1, R3
                CALL    ed_x80
                ADD     R9, R2, @V_ESC
                RET

; ed_copy: the text of the line from row R3, from position R9 to R6, but
; at most EDIT_MAX characters, to V_LINE, with a 0 after it. R1 = the
; word of the 0, and R5 = the characters after EDIT_MAX, which it left
; out, 0 for a line that fits. Uses R1, R2, and R5.
ed_copy
                MOVE    R1, R3
                CALL    ed_row
                ADD     R2, R1, R9
                MOVE    R1, V_LINE
                SUB[M]  R5, R6, R9      ; the characters
        ?C      CLR     R5              ; none
        ?C      JMP     :++
        ?Z      JMP     :++
:
                CMP     R1, V_LINE+EDIT_MAX
        ?Z      JMP     :+
                AND     @R1++, @R2++, 0xFF
                SUB[M]  R5, R5, 1
        ?!Z     JMP     :-
:
                CLR     @R1
                RET

; ed_grow: a row added after the line of the rows R3 to R4, which goes on
; from its last: at the last row, the screen scrolls, and the line moves
; up; else the rows below move down, the last lost, with their bits of
; scr_links, and the new row is blank. R3 and R4 = the line's rows. Uses
; R1 and R2.
ed_grow
                CMP     R4, ROWS-1
        ?!Z     JMP     :+
                CALL    ed_scroll
                SUB     R3, R3, 1
                JMP     eg_link
:
                PUSH    R5
                PUSH    R6
                ADD     R1, R4, 1
                CALL    ed_row
                MOVE    R5, R1          ; the new row's first word
                MOVE    R6, SCR_LAST
:
                CMP     R6, R5          ; the rows from it down by one
        ?Z      JMP     :+
                SUB     R6, R6, 1
                MOVE    @80[R6], @R6
                JMP     :-
:
                OR      R1, @V_ECOL, 0x20
                MOVE    R2, 80
:
                MOVE    @R5++, R1       ; the new row blank
                SUB[M]  R2, R2, 1
        ?!Z     JMP     :-
                NOT     R1, R0
                CALL    SCR_LINKS
                MOVE    R5, 2
                SHL     R5, R5, R4
                SUB     R5, R5, 1
                AND     R6, R1, R5      ; the bits of the rows to R4,
                ADD     R2, R4, 1
                SHR     R1, R1, R2
                ADD     R2, R2, 1
                SHL     R1, R1, R2      ; and those below, a row down
                OR      R1, R1, R6
                CALL    SCR_LINKS
                POP     R6
                POP     R5
                ADD     R4, R4, 1
; eg_link: the bit of row R4 set, which goes on from the row above. Uses
; R1 and R2.
eg_link
                NOT     R1, R0
                CALL    SCR_LINKS
                MOVE    R2, 1
                SHL     R2, R2, R4
                OR      R1, R1, R2
                JMP     SCR_LINKS

; ed_scroll: the screen up by a row, as a LF at the last row moves it on
; the screen alone, with the scrollback and scr_links, and the row where
; the first key came with it. The cursor at column 0 of the last row.
; Uses R1 and R2.
ed_scroll
                PUSH    R3
                PUSH    R4
                CLR     R1
                MOVE    R2, ROWS-1
                CALL    SCR_MOVETO
                MOVE    R1, MON_OUT_SCREEN
                CALL    MON_OUT
                PUSH    R1
                MOVE    R1, 0x0A
                CALL    MON_PUTC
                POP     R1
                CALL    MON_OUT
                SUB     @V_ESR, @V_ESR, 1
                POP     R4
                POP     R3
                RET

; ed_line: R1 to the line alone, as mon_putc puts it. Uses R1-R4.
ed_line
                PUSH    R1
                MOVE    R1, MON_OUT_LINE
                CALL    MON_OUT
                MOVE    R2, R1
                POP     R1
                PUSH    R2
                CALL    MON_PUTC
                POP     R1
                JMP     MON_OUT

; ed_to: the cursor to position R1 of the line from row R3. Uses R1 and
; R2.
ed_to
                MOVE    R2, R3
:
                CMP     R1, 80
        ?C      JMP     SCR_MOVETO
                SUB     R1, R1, 80
                ADD     R2, R2, 1
                JMP     :-

; ed_row: R1 = the word of the screen of column 0 of row R1. Uses R2.
ed_row
                SHL     R2, R1, 6
                SHL     R1, R1, 4
                ADD     R1, R1, R2
                ADD     R1, R1, SCREEN
                RET

; ed_x80: R2 = 80 R2. Uses no other register.
ed_x80
                PUSH    R1
                SHL     R1, R2, 6
                SHL     R2, R2, 4
                ADD     R2, R2, R1
                POP     R1
                RET

GL_CC           .DAT    0x5E, 0x43, 0   ; ^C

; The statements of the editor (issue #118, step 4): DELETE of lines,
; RENUMBER, and AUTO. Each ends at READY., as NEW does, so that a program
; that runs one stops there.

; del_kind: for run, DELETE "NAME", a file, keeps its routine, R3; with
; no string after it, its routine is st_dellines, which reads its own
; items, as R2 = I_PRINT says. Uses R4.
del_kind
                MOVE    R4, @R8
                SHR     R4, R4, 24
                SHR     R4, STR_KINDS, R4
                AND[M]  R0, R4, 1
        ?!Z     RET                     ; a string
                MOVE    R3, st_dellines
                MOVE    R2, I_PRINT
                RET

; DELETE N [- M], DELETE N -, and DELETE - M: the lines from N to M
; deleted, the range as LIST takes it, and main. Uses R1-R12.
st_dellines
                MOVE    R9, R8
                CALL    get_range
                CMP     R8, R9
        ?Z      JMP     err_syntax      ; no range
                CALL    stmt_end
                CALL    drop_run
                ADD     R3, R11, 1
                CALL    find_line
                MOVE    R12, R1         ; the first line after M
                MOVE    R3, R10
                CALL    find_line       ; the first line from N
                CMP     R1, R12
        ?!C     JMP     main            ; none
                SUB     R2, R1, R12
                MOVE    R1, R12
                CALL    shift
                CALL    clear_cache
                JMP     main

; get_ns: [N] [, S] at R8, as RENUMBER and AUTO take them: R10 = N and
; R11 = S, 10 each when not given, and R8 after them, at the statement's
; end. An S of 0, or an N past LINE_LAST, is an Illegal quantity. Uses R1
; and R2.
get_ns
                MOVE    R10, 10
                MOVE    R11, 10
                MOVE    R1, @R8
                SHR     R2, R1, 24
                CMP     R2, K_SMALL
        ?!Z     JMP     :+
                AND     R10, R1, 0xFFFFFF
                MOVE    R8++, R8
                MOVE    R1, @R8
:
                CMP     R1, T_COMMA
        ?!Z     JMP     :+
                MOVE    R8++, R8
                MOVE    R1, @R8
                SHR     R2, R1, 24
                CMP     R2, K_SMALL
        ?!Z     JMP     err_syntax
                AND     R11, R1, 0xFFFFFF
                MOVE    R8++, R8
:
                CALL    stmt_end
                TST     R11
        ?Z      JMP     err_quant
                CMP     R10, LINE_LAST+1
        ?!C     JMP     err_quant
                RET

; RENUMBER [N] [, S]: the lines numbered from N, by S, and the line
; numbers after GOTO, GOSUB, RUN, THEN, and ELSE with them; a number of
; no line is kept. When the last number would be past LINE_LAST, nothing
; changes, and it is an Illegal quantity. Then main. Uses R1-R11.
st_renum
                CALL    get_ns
                CLR     R9              ; the lines
                MOVE    R1, PROGRAM
:
                CMP     R1, @V_PEND
        ?!C     JMP     :+
                ADD     R9, R9, 1
                ADD     R1, R1, @R1
                JMP     :-
:
                MOVE    R1, R10         ; the last number
:
                SUB[M]  R9, R9, 1
        ?C      JMP     :+              ; no line, or the last
        ?Z      JMP     :+
                ADD     R1, R1, R11
                CMP     R1, LINE_LAST+1
        ?!C     JMP     err_quant
                JMP     :-
:
                CALL    drop_run
                MOVE    R7, PROGRAM     ; first the line numbers of the jumps,
rn_line
                CMP     R7, @V_PEND
        ?!C     JMP     rn_nums
                ADD     R8, R7, 2
rn_tok
                MOVE[M] R2, @R8
        ?Z      JMP     rn_next
                SHR     R2, R2, 24
                CMP     R2, K_LINE
        ?!Z     JMP     rn_skip
                AND     R3, @R8, 0xFFFFFF  ; the line jumped to,
                MOVE    R1, PROGRAM     ; its new number from its place
                MOVE    R4, R10
:
                CMP     R1, @V_PEND
        ?!C     JMP     rn_skip         ; no such line: kept
                CMP     @1[R1], R3
        ?Z      JMP     :+
                ADD     R4, R4, R11
                ADD     R1, R1, @R1
                JMP     :-
:
                OR      @R8, R4, K_LINE*K
rn_skip
                CALL    tok_skip
                JMP     rn_tok
rn_next
                ADD     R7, R7, @R7
                JMP     rn_line
rn_nums
                MOVE    R1, PROGRAM     ; then those of the lines
                MOVE    R4, R10
:
                CMP     R1, @V_PEND
        ?!C     JMP     :+
                MOVE    @1[R1], R4
                ADD     R4, R4, R11
                ADD     R1, R1, @R1
                JMP     :-
:
                CALL    clear_cache
                JMP     main

; AUTO [N] [, S]: main_line types the number of each line, N first, then
; the number of the line stored last plus S. A line of a number alone, or
; of nothing, ends AUTO, and stores and deletes no line, and so does
; any READY., after a statement, an error, or CTRL-C at the line.
st_auto
                CALL    get_ns
                MOVE    @V_AUTO, R11
                SUB     @V_LNUM, R10, R11
                JMP     main_auto

; auto_put: the next line's number and a blank, for AUTO, on a row of
; blanks (ed_fresh), or AUTO off past LINE_LAST. Uses R1-R7.
auto_put
                ADD     R1, @V_LNUM, @V_AUTO
                CMP     R1, LINE_LAST+1
        ?!C     CLR     @V_AUTO
        ?!C     RET
                PUSH    R1
                CALL    ed_fresh
                POP     R1
                CALL    putdec
                JMP     put_blank

; auto_end: for AUTO, the line at R5 after its blanks: main, with no
; line stored, when it has nothing after a number, else back. Uses R1
; and R6.
auto_end
                MOVE    R6, R5
:
                SUB     R1, @R6, 0x30
                CMP     R1, 10
        ?C      MOVE    R6++, R6
        ?C      JMP     :-
:
                CMP     @R6, 0x20
        ?Z      MOVE    R6++, R6
        ?Z      JMP     :-
                TST     @R6
        ?Z      JMP     main
                RET
