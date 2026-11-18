; The test of the entries of table 1.7 (README.md, "The dispatch table",
; issue #153), mon_build, con_key, scr_back, and fs_complete, a program at
; 0x8000 that calls them through the stubs of mon.nasm, which the
; Makefile joins after it, as test/hal16.nasm does. It runs with the
; keys ab typed after sys 0x8000, and nothing after them, so that the
; program halts the core itself, and with super.img in slot 0, whose
; folder NICE has HELLO.BIN alone. The program stores the result of each
; call at H17_RESULTS, which the test dumps, with the lines that
; fs_complete completed at H17_LINE and H17_LINE2:
;
;  0  mon_version, 0x00010007, table 1.7
;  1  mon_build, the first word of its text, V9.9 packed
;  2  con_key(1), waits: 0x61, a
;  3  con_key(0): 0x62, b, typed ahead
;  4  con_key(0) with no key: -1
;  5  scr_back(3), after 40 rows printed: 3
;  6  scr_back(-1): 2
;  7  scr_back(0): 0, the screen again
;  8  scr_back(-1) at the screen: 0
;  9  scr_back(1000): the rows that the scrollback holds
; 10  scr_back(-1000): 0, the screen again
; 11  fs_complete of load "hel, the cursor after it, as TAB completes
;     no keyword: the new cursor's offset from H17_LINE, 17, past
;     HELLO.BIN, the closing quote, and a blank
; 12  the same of load he through the word window, as a C stub has it:
;     the new cursor, in the window, less the window's address of
;     H17_LINE2, 68, 4 bytes a word
;
; It halts with R1 the number of results, 13.

                .ORG    0x8000
H17_RESULTS     .EQU    0x9100
H17_LINE        .EQU    0x9180
H17_LINE2       .EQU    0x91A0
H17_END         .EQU    24              ; the words that a line may take
H17_WIN         .EQU    0x10000000      ; the word window, 4 bytes a word
H17_ROWS        .EQU    40

h17_main
                MOVE    R7, H17_RESULTS
                CALL    _mon_version
                MOVE    @R7++, R1
                CALL    _mon_build
                MOVE    @R7++, @R1
; con_key
                MOVE    R1, 1
                CALL    _mon_con_key
                MOVE    @R7++, R1
                CLR     R1
                CALL    _mon_con_key
                MOVE    @R7++, R1
                CLR     R1
                CALL    _mon_con_key
                MOVE    @R7++, R1
; scr_back, after rows that scroll off the screen
                MOVE    R8, H17_ROWS
:
                MOVE    R1, 0x78        ; x
                CALL    _mon_putc
                MOVE    R1, 0x0D
                CALL    _mon_putc
                MOVE    R1, 0x0A
                CALL    _mon_putc
                SUB[M]  R8, R8, 1
        ?!Z     JMP     :-
                MOVE    R1, 3
                CALL    _mon_scr_back
                MOVE    @R7++, R1
                MOVE    R1, -1
                CALL    _mon_scr_back
                MOVE    @R7++, R1
                CLR     R1
                CALL    _mon_scr_back
                MOVE    @R7++, R1
                MOVE    R1, -1
                CALL    _mon_scr_back
                MOVE    @R7++, R1
                MOVE    R1, 1000
                CALL    _mon_scr_back
                MOVE    @R7++, R1
                MOVE    R1, -1000
                CALL    _mon_scr_back
                MOVE    @R7++, R1
; fs_complete, plain, then through the word window
                MOVE    R1, H17_LINE
                MOVE    R2, H17_LINE+9
                MOVE    R3, H17_LINE+H17_END
                CALL    _mon_fs_complete
                SUB     @R7++, R1, H17_LINE
                MOVE    R1, H17_WIN+4*H17_LINE2
                MOVE    R2, H17_WIN+4*H17_LINE2+4*7
                MOVE    R3, H17_WIN+4*H17_LINE2+4*H17_END
                CALL    _mon_fs_complete
                SUB     @R7++, R1, H17_WIN+4*H17_LINE2
                MOVE    R1, 0x0D        ; the halt's line on a row of its own
                CALL    _mon_putc
                MOVE    R1, 0x0A
                CALL    _mon_putc
                SUB     R1, R7, H17_RESULTS
                HALT

                .ORG    H17_LINE
                .ASCII_L 'load "hel'
                .ORG    H17_LINE2
                .ASCII_L 'load he'
                .ORG    0x9200          ; mon.nasm's stubs, after the lines
