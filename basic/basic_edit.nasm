; BASIC's screen editor (issue #118, doc/BASIC.md, "The screen editor"),
; which the Makefile joins after basic_dis.nasm (basic.nasm's header).
; getline reads BASIC's line from the screen: the cursor keys move over
; it, typing inserts, DEL deletes to the left, and RETURN takes the
; logical line that the cursor is in, the rows that go on from the row
; above, as scr_links has them, up to EDIT_MAX characters. A position in
; a logical line is its offset from the line's first row, 80 a row, as
; the screen's words of the rows follow each other. Its variables,
; V_ECOL, V_ESR, V_ESC, V_EMOV, and V_EKEY, are in basic.nasm.

PAGE            .EQU    24              ; the rows of Page Up and Page Down, as the monitor's
SCR_LAST        .EQU    0xFFFF0780      ; the screen's row 24, the last

; getline: the line of BASIC at V_LINE, up to EDIT_MAX characters and a
; 0, from the screen, with the keys typed ahead first. RETURN takes the
; logical line of the cursor, from the position where the first key came
; when it is that line, as after INPUT's prompt, else from its start.
; The cursor keys and HOME, ESC [ H, move the cursor, and the cursor key
; down scrolls at the last row; DEL and BS delete to the left within the
; line; TAB completes the name of a file of the card (fs_complete) at
; the end of the line's text or after it; and CTRL-C empties the line, or is a break
; at INPUT when R1 is not 0. Page Up and Page Down show the scrollback a
; page back or forward (scr_back), until another key; an ESC with
; another sequence, or alone, is dropped. A key typed at the end of the
; line's text goes to the line as well, as before; after any other key,
; or when the line had text after the cursor at the first key, the line
; is sent again at RETURN, and only the screen shows the moves.
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
                MOVE    R1, 1           ; wait,
                TST     @V_EKEY
        ?Z      MOVE    R1, 3           ; and show what DHCP gets before a key
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
; first row; and the cursor to the row after the line's last
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
                JMP     _io_crlf        ; which returns to the caller
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
                CMP     R2, 25
        ?C      JMP     gl_at
                PUSH    R1
                CALL    ed_scroll
                POP     R1
                MOVE    R2, 24
                JMP     gl_at
gl_right
                CALL    gl_leave
                CALL    SCR_GETXY
                ADD     R1, R1, 1
                CMP     R1, 80
        ?C      JMP     gl_at
                CMP     R2, 24
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
                CMP     R1, 25
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
; first key came, when it came in that line, else 0. Uses R1 and R2.
ed_floor
                CLR     R9
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
; word of the 0. Uses R1, R2, and R5.
ed_copy
                MOVE    R1, R3
                CALL    ed_row
                ADD     R2, R1, R9
                MOVE    R1, V_LINE
                SUB[M]  R5, R6, R9      ; the characters
        ?C      JMP     :++             ; none
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
                CMP     R4, 24
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
                MOVE    R2, 24
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
