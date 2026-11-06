; The test of the sector routines, sd_init, sd_read, and sd_write, which
; have no entries in the dispatch table (README.md). The Makefile
; assembles this program after the sources of the monitor, so that it calls
; them by their labels, and keeps only its words, from 0x8000, which r runs
; under the monitor of the tests. The image of slot 0, from test/sd_image.py,
; has 4 sectors, the bytes 0 to 255 twice in sector 1, and no slot 1. The
; program stores the result of each call at SDT_RESULTS, which the test
; dumps: sd_init of the empty slot 1, -1; sd_init of slot 0, 0; sd_read of
; sector 1, 0; sd_write of it to sector 2 with ABCD in its first word, 0;
; and sd_write and sd_read of sector 4, after the last, -7. Then sd 2 shows
; sector 2, and the Makefile compares the image with the one that
; sd_image.py --written makes.

                .ORG    0x8000
SDT_BUF         .EQU    0x9000          ; a sector, 128 words
SDT_RESULTS     .EQU    0x9100

sdt_main
                MOVE    R7, SDT_RESULTS
                MOVE    R1, 1
                CALL    sd_init
                MOVE    @R7++, R1
                MOVE    R1, 0
                CALL    sd_init
                MOVE    @R7++, R1
                MOVE    R1, 1
                MOVE    R2, SDT_BUF
                CALL    sd_read
                MOVE    @R7++, R1
                MOVE    @SDT_BUF, 0x44434241  ; ABCD, little-endian
                MOVE    R1, 2
                MOVE    R2, SDT_BUF
                CALL    sd_write
                MOVE    @R7++, R1
                MOVE    R1, 4
                MOVE    R2, SDT_BUF
                CALL    sd_write
                MOVE    @R7++, R1
                MOVE    R1, 4
                MOVE    R2, SDT_BUF
                CALL    sd_read
                MOVE    @R7++, R1
                MOVE    R1, 0
                RET
