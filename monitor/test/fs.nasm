; The test of the file entries that read, fs_mount, fs_open, fs_read,
; fs_readdir, and fs_close, of table 1.1 (README.md, "Files"), a program
; at 0x8000 that calls them through the stubs of mon.nasm, which the
; Makefile joins after it; test/fsw.nasm tests those that write. Slot 0
; has test/fat_image.py's fat32.img, and slot 1 its super.img. The
; program stores the result of each call at FST_RESULTS, which the test
; dumps, with the bytes that fs_read wrote at FST_BUF and the entry that
; fs_readdir wrote at FST_ENTRY:
;
;  0  mon_version, 0x00010003, table 1.3
;  1  fs_open of HELLO.BIN, 0, which mounts slot 0
;  2  fs_open of frag.bin, in lower case, 1
;  3  fs_open of NOFILE with both handles in use, -21, no such file,
;     which comes before too many open files
;  4  fs_open of KEEP.TXT, -23, too many open files
;  5  fs_read of 40 bytes of FRAG.BIN to FST_BUF, 40
;  6  fs_read of the rest, from FST_BUF + 40, 1904, across its fragments
;  7  fs_read at the end, 0
;  8  the last word that fs_read wrote, the LF of FRAG.BIN's last line, 0x0A
;  9  fs_close of FRAG.BIN, 0
; 10  fs_close of it again, -24, not an open file
; 11  fs_open of the root, the name /, with mode 2, 1
; 12  fs_readdir, 1, with HELLO.BIN's entry at FST_ENTRY
; 13  fs_read of the directory's handle, -24
; 14  fs_readdir of HELLO.BIN's handle, -24
; 15  the entries of the root that fs_readdir gives after the first, 25
; 16  fs_readdir at the end, 0
; 17  fs_close of the root, 0
; 18  fs_open of SUB, -22, a directory
; 19  fs_open of NOFILE, -21, no such file
; 20  fs_open of TOOLONGNAME, -20, not an 8.3 name
; 21  fs_open of A.B.C, -20
; 22  fs_open with mode 3, -25, no such mode
; 23  fs_mount of slot 1, 0, which closes the files
; 24  fs_close of handle 0, -24
; 25  fs_open of HELLO.BIN on super.img, 0
; 26  fs_read of 9 bytes, 9, its first line's address, 00008000 and a blank
; 27  fs_mount of slot 2, -27, no such slot
; 28  fs_read of 1 byte of handle 0, 1, as a mount of no slot changes nothing
; 29  fs_mount of slot 0, 0
;
; It returns the number of results, 30.

                .ORG    0x8000
FST_RESULTS     .EQU    0x9100
FST_ENTRY       .EQU    0x9180
FST_BUF         .EQU    0x9200

fst_main
                MOVE    R7, FST_RESULTS
                CALL    _mon_version
                MOVE    @R7++, R1
                MOVE    R1, FST_HELLO
                MOVE    R2, 0
                CALL    _fs_open
                MOVE    @R7++, R1
                MOVE    R1, FST_FRAG
                MOVE    R2, 0
                CALL    _fs_open
                MOVE    @R7++, R1
                MOVE    R8, R1          ; FRAG.BIN's handle
                MOVE    R1, FST_NOFILE
                MOVE    R2, 0
                CALL    _fs_open
                MOVE    @R7++, R1
                MOVE    R1, FST_KEEP
                MOVE    R2, 0
                CALL    _fs_open
                MOVE    @R7++, R1
                MOVE    R1, R8
                MOVE    R2, FST_BUF
                MOVE    R3, 40
                CALL    _fs_read
                MOVE    @R7++, R1
                MOVE    R1, R8
                MOVE    R2, FST_BUF+40
                MOVE    R3, 5000
                CALL    _fs_read
                MOVE    @R7++, R1
                ADD     R9, R1, FST_BUF+39  ; the last word written
                MOVE    R1, R8
                MOVE    R2, FST_BUF
                MOVE    R3, 10
                CALL    _fs_read
                MOVE    @R7++, R1
                MOVE    @R7++, @R9
                MOVE    R1, R8
                CALL    _fs_close
                MOVE    @R7++, R1
                MOVE    R1, R8
                CALL    _fs_close
                MOVE    @R7++, R1
; The root directory
                MOVE    R1, FST_ROOT
                MOVE    R2, 2
                CALL    _fs_open
                MOVE    @R7++, R1
                MOVE    R8, R1          ; the root's handle
                MOVE    R2, FST_ENTRY
                CALL    _fs_readdir
                MOVE    @R7++, R1
                MOVE    R1, R8
                MOVE    R2, FST_BUF
                MOVE    R3, 1
                CALL    _fs_read
                MOVE    @R7++, R1
                MOVE    R1, 0
                MOVE    R2, FST_BUF
                CALL    _fs_readdir
                MOVE    @R7++, R1
                MOVE    R9, 0           ; the entries
fst_dir
                MOVE    R1, R8
                MOVE    R2, FST_BUF
                CALL    _fs_readdir
                CMP     R1, 1
        ?!Z     JMP     fst_dir_end
                ADD     R9, R9, 1
                JMP     fst_dir
fst_dir_end
                MOVE    @R7++, R9
                MOVE    @R7++, R1
                MOVE    R1, R8
                CALL    _fs_close
                MOVE    @R7++, R1
; Errors of fs_open
                MOVE    R1, FST_SUB
                MOVE    R2, 0
                CALL    _fs_open
                MOVE    @R7++, R1
                MOVE    R1, FST_NOFILE
                MOVE    R2, 0
                CALL    _fs_open
                MOVE    @R7++, R1
                MOVE    R1, FST_LONG
                MOVE    R2, 0
                CALL    _fs_open
                MOVE    @R7++, R1
                MOVE    R1, FST_DOTS
                MOVE    R2, 0
                CALL    _fs_open
                MOVE    @R7++, R1
                MOVE    R1, FST_HELLO
                MOVE    R2, 3
                CALL    _fs_open
                MOVE    @R7++, R1
; Mounts
                MOVE    R1, 1
                CALL    _fs_mount
                MOVE    @R7++, R1
                MOVE    R1, 0
                CALL    _fs_close
                MOVE    @R7++, R1
                MOVE    R1, FST_HELLO
                MOVE    R2, 0
                CALL    _fs_open
                MOVE    @R7++, R1
                MOVE    R8, R1
                MOVE    R2, FST_BUF
                MOVE    R3, 9
                CALL    _fs_read
                MOVE    @R7++, R1
                MOVE    R1, 2
                CALL    _fs_mount
                MOVE    @R7++, R1
                MOVE    R1, R8
                MOVE    R2, FST_BUF
                MOVE    R3, 1
                CALL    _fs_read
                MOVE    @R7++, R1
                MOVE    R1, 0
                CALL    _fs_mount
                MOVE    @R7++, R1
                SUB     R1, R7, FST_RESULTS
                RET

FST_HELLO
                .ASCII_L 'HELLO.BIN'
FST_FRAG
                .ASCII_L 'frag.bin'
FST_KEEP
                .ASCII_L 'KEEP.TXT'
FST_ROOT
                .ASCII_L '/'
FST_SUB         .ASCII_L 'SUB'
FST_NOFILE
                .ASCII_L 'NOFILE'
FST_LONG
                .ASCII_L 'TOOLONGNAME'
FST_DOTS
                .ASCII_L 'A.B.C'
