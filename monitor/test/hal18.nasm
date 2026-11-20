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
;  5  scr_links(0x1000003), which drops bit 0: the old word, 0xA
;  6  after 81 characters from row 24, which scroll the word and wrap
;     to row 24: 0x1800000, row 0's bit dropped, the others moved up
;  7  after a LF at row 24, which scrolls: 0xC00000, row 24's cleared
;  8  after a TAB at column 79 of row 24, which wraps and scrolls:
;     0x1600000
;  9  scr_links(0xFE000001), all bits it drops: 0x1600000
; 10  scr_links(-1): 0
; 11  scr_links(0x10), scr_cls, scr_links(-1): 0
;
; It halts with R1 the number of results, 12.

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
                MOVE    R1, 0x1000003
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
