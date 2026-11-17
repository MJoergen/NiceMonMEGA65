; The test of the entries of table 1.6 (README.md, "The dispatch table",
; issue #152), con_getline, bin_line, clock_set, net_servers, and
; mon_restore, a program at 0x8000 that calls them through the stubs of
; mon.nasm, which the Makefile joins after it, as test/fs.nasm does. It
; runs with --step-time, so that the clock starts at 0 and not set, and
; with the line 12, DEL, 345678x9, and TAB typed after sys 0x8000. The
; program stores the result of each call at H16_RESULTS, which the test
; dumps, with the line that con_getline wrote at H16_LINE, the counts of
; bin_line at H16_COUNTS, the words that it wrote at H16_WORDS, and the
; servers of net_servers at H16_SRV:
;
;  0  mon_version, 0x00010006, table 1.6
;  1  con_getline of up to 8 characters, 8: 1345678x, as the DEL took
;     back the 2, the 9 did not fit, and TAB with no card added nothing
;  2  bin_line of H16_WORDS+1 12345678, 1, written
;  3  bin_line of blanks, 0
;  4  bin_line of an address in the ROM, -1, skipped, the third line
;  5  bin_line of three numbers, -1
;  6  bin_line of H16_WORDS ABCDEF01 with blanks around, 1, the lowest
;  7  clock_set of 2026-11-14 12:34:57 and 5 microseconds, 0
;  8  the clock's seconds after it, from the snapshot, 0x6AF85571
;  9  the clock's "set", 1
; 10  net_servers, 0, with none at H16_SRV
; 11  mon_restore, 0, after the program stopped the cursor and set the
;     timer, and put the cursor at column 85 and row 30
; 12  the timer after it, 0
; 13  the screen's control word after it, 0x60
; 14  scr_getxy after it, the column, 79
; 15  and the row, 24
;
; The counts are 2 words written, from H16_WORDS to H16_WORDS+1, 2 lines
; skipped, the first the third, 5 lines, and the end of a program's RAM,
; the screen in niceemu. It returns the number of results, 16.

                .ORG    0x8000
H16_RESULTS     .EQU    0x9100
H16_LINE        .EQU    0x9180
H16_COUNTS      .EQU    0x9190
H16_SRV         .EQU    0x9198
H16_WORDS       .EQU    0x9200
H16_SECS        .EQU    0x6AF85571      ; 2026-11-14 12:34:57
H16_USEC        .EQU    0xFFFFFF46      ; the clock's microseconds, whose read takes a snapshot
H16_CLOCK       .EQU    0xFFFFFF47      ; of the seconds, bits 31..0
H16_STATUS      .EQU    0xFFFFFF49      ; and its "set"
H16_TIMER       .EQU    0xFFFFFF10
H16_CTL         .EQU    0xFFFFFF80
H16_X           .EQU    0xFFFFFF81
H16_Y           .EQU    0xFFFFFF82

h16_main
                MOVE    R7, H16_RESULTS
                CALL    _mon_version
                MOVE    @R7++, R1
                MOVE    R1, H16_LINE
                MOVE    R2, 8
                CALL    _mon_con_getline
                MOVE    @R7++, R1
; bin_line, with the counts cleared
                MOVE    R1, H16_COUNTS
                MOVE    R2, 7
:
                MOVE    @R1++, 0
                SUB[M]  R2, R2, 1
        ?!Z     JMP     :-
                MOVE    R8, H16_LINES
:
                MOVE    R1, R8
                MOVE    R2, H16_COUNTS
                CALL    _mon_bin_line
                MOVE    @R7++, R1
:
                MOVE[M] R1, @R8++       ; to the next line
        ?!Z     JMP     :-
                TST     @R8
        ?!Z     JMP     :--
; clock_set
                MOVE    R1, H16_SECS
                MOVE    R2, 5
                CALL    _mon_clock_set
                MOVE    @R7++, R1
                MOVE    R1, @H16_USEC   ; the snapshot of the seconds
                MOVE    @R7++, @H16_CLOCK
                MOVE    @R7++, @H16_STATUS
; net_servers
                MOVE    R1, H16_SRV
                CALL    _mon_net_servers
                MOVE    @R7++, R1
; mon_restore
                MOVE    @H16_CTL, 0
                MOVE    @H16_TIMER, 1000
                MOVE    @H16_X, 85
                MOVE    @H16_Y, 30
                CALL    _mon_restore
                MOVE    @R7++, R1
                MOVE    @R7++, @H16_TIMER
                MOVE    @R7++, @H16_CTL
                CALL    _mon_scr_getxy
                MOVE    @R7++, R1
                MOVE    @R7++, R2
                SUB     R1, R7, H16_RESULTS
                RET

; The lines of bin_line, each up to a 0 word, and a second 0 after the
; last
H16_LINES
                .ASCII_L '9201 12345678'
                .ASCII_L '   '
                .ASCII_L '100 5'
                .ASCII_L '9201 5 6'
                .ASCII_L ' 9200 ABCDEF01 '
                .DAT    0
