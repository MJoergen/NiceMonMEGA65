; The test of the entry of table 1.8 (README.md, "The dispatch table",
; issue #118), scr_links, and of the bits that mon_putc and scr_cls keep
; for it, a program at 0x8000 that calls them through the stubs of
; mon.nasm, which the Makefile joins after it, as test/hal17.nasm does.
; It runs after sys 0x8000, and halts the core itself. The program stores
; its results at H18_RESULTS, which the test dumps:
;
;  0  mon_version, 0x00010008, table 1.8
;  1  scr_links(-1) after scr_cls: 0
;  2  after 100 characters from row 0, which wrap to row 1: 2
;  3  after CR LF, to row 2, whose bit stays clear: 2
;  4  after 81 characters from row 2, which wrap to row 3: 0xA
;  5  scr_links(0x1000023), which drops bit 0: the old word, 0xA
;  6  after 81 characters from row 24, column 0, where scr_moveto put
;     the cursor, which scroll the word and wrap to row 24: 0x1000010,
;     row 24's bit cleared by the first, row 1's dropped, row 5's moved
;     up, and row 24's set by the wrap
;  7  after a LF at row 24, which scrolls: 0x800008, row 24's cleared
;  8  after a TAB at column 79 of row 24, which wraps and scrolls:
;     0x1400004
;  9  scr_links(0xFE000001), all bits it drops: 0x1400004
; 10  scr_links(-1): 0
; 11  scr_links(0x10), scr_cls, scr_links(-1): 0
; 12  scr_links(0x28), and a character at column 1 of row 3, after
;     scr_moveto: 0x28, as the row is not written from its start
; 13  after a CR and a character, at column 0 of row 3: 0x20, row 3 a
;     line of its own
; 14  after scr_moveto to column 0 of row 5 and a character: 0
; 15  after 79 more, which wrap to row 6, and one there: 0x40
; 16  after scr_moveto to column 0 of row 6 again, and a character: 0
; 17  after 80 characters from column 0 of row 8, which wrap to row 9,
;     scr_moveto to column 0 of row 9, where the wrap left the cursor,
;     and a character: 0, as scr_moveto forgets the wrap
;
; It halts with R1 the number of results, 18.

                .ORG    0x8000
H18_RESULTS     .EQU    0x9100

h18_main
                MOVE    R7, H18_RESULTS
                CALL    _mon_version
                MOVE    @R7++, R1
                CALL    _mon_scr_cls
                CALL    h18_links
; 100 characters from row 0, then CR LF
                MOVE    R8, 100
                CALL    h18_chars
                CALL    h18_links
                MOVE    R1, 0x0D
                CALL    _mon_putc
                MOVE    R1, 0x0A
                CALL    _mon_putc
                CALL    h18_links
                MOVE    R8, 81
                CALL    h18_chars
                CALL    h18_links
                MOVE    R1, 0x1000023
                CALL    _mon_scr_links
                MOVE    @R7++, R1
; Row 24: a wrap, a LF, and a TAB at the last column
                CLR     R1
                MOVE    R2, 24
                CALL    _mon_scr_moveto
                MOVE    R8, 81
                CALL    h18_chars
                CALL    h18_links
                MOVE    R1, 0x0A
                CALL    _mon_putc
                CALL    h18_links
                MOVE    R1, 79
                MOVE    R2, 24
                CALL    _mon_scr_moveto
                MOVE    R1, 0x09
                CALL    _mon_putc
                CALL    h18_links
                MOVE    R1, 0xFE000001
                CALL    _mon_scr_links
                MOVE    @R7++, R1
                CALL    h18_links
                MOVE    R1, 0x10
                CALL    _mon_scr_links
                CALL    _mon_scr_cls
                CALL    h18_links
; A row written from its start is a line of its own
                MOVE    R1, 0x28
                CALL    _mon_scr_links
                ONE     R1
                MOVE    R2, 3
                CALL    _mon_scr_moveto
                ONE     R8
                CALL    h18_chars
                CALL    h18_links
                MOVE    R1, 0x0D
                CALL    _mon_putc
                ONE     R8
                CALL    h18_chars
                CALL    h18_links
                CLR     R1
                MOVE    R2, 5
                CALL    _mon_scr_moveto
                ONE     R8
                CALL    h18_chars
                CALL    h18_links
                MOVE    R8, 80
                CALL    h18_chars
                CALL    h18_links
                CLR     R1
                MOVE    R2, 6
                CALL    _mon_scr_moveto
                ONE     R8
                CALL    h18_chars
                CALL    h18_links
; A wrap, and scr_moveto to where it left the cursor
                CLR     R1
                MOVE    R2, 8
                CALL    _mon_scr_moveto
                MOVE    R8, 80
                CALL    h18_chars
                CLR     R1
                MOVE    R2, 9
                CALL    _mon_scr_moveto
                ONE     R8
                CALL    h18_chars
                CALL    h18_links
                MOVE    R1, 0x0D        ; the halt's line on a row of its own
                CALL    _mon_putc
                MOVE    R1, 0x0A
                CALL    _mon_putc
                SUB     R1, R7, H18_RESULTS
                HALT

; h18_links: scr_links(-1), the word stored at R7
h18_links
                MOVE    R1, -1
                CALL    _mon_scr_links
                MOVE    @R7++, R1
                RET

; h18_chars: R8 characters x
h18_chars
                MOVE    R1, 0x78        ; x
                CALL    _mon_putc
                SUB[M]  R8, R8, 1
        ?!Z     JMP     h18_chars
                RET

                .ORG    0x9200          ; mon.nasm's stubs, after the results
