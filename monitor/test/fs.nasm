; The test of the file entries that read, fs_mount, fs_open, fs_read,
; fs_readdir, and fs_close, of table 1.1, and fs_readname of table 1.4
; (README.md, "Files"), a program
; at 0x8000 that calls them through the stubs of mon.nasm, which the
; Makefile joins after it; test/fsw.nasm tests those that write. Slot 0
; has test/fat_image.py's fat32.img, and slot 1 its super.img. The
; program stores the result of each call at FST_RESULTS, which the test
; dumps, with the bytes that fs_read wrote at FST_BUF, the entry that
; fs_readdir wrote at FST_ENTRY, and the entry and the names that
; fs_readname wrote at FST_ENTRY2, FST_NAME, and FST_NAME2:
;
;  0  mon_version, 0x00010004, table 1.4
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
; 20  fs_open of TOOLONGNAME, -21, which may be a long name
; 21  fs_open of A.B.C, -21
; 22  fs_open with mode 3, -25, no such mode
; 23  fs_mount of slot 1, 0, which closes the files
; 24  fs_close of handle 0, -24
; 25  fs_open of HELLO.BIN on super.img, 0
; 26  fs_read of 9 bytes, 9, its first line's address, 00008000 and a blank
; 27  fs_mount of slot 2, -27, no such slot
; 28  fs_read of 1 byte of handle 0, 1, as a mount of no slot changes nothing
; 29  fs_mount of slot 0, 0
; 30  fs_open of the folder, 0
; 31  fs_readname of the third entry, 1, with ALONGN~1.TXT's entry at
;     FST_ENTRY2 and its long name, A long name.txt, at FST_NAME
; 32  fs_readname of the fourth, 1, with readme.txt, the 8.3 name README.TXT
;     in the lower case of its byte 12, at FST_NAME2
; 33  fs_close of the folder, 0
; 34  fs_open of a LONG name.TXT, its long name in another case, 0
; 35  fs_close of it, 0
;
; It returns the number of results, 36.

                .ORG    0x8000
FST_RESULTS     .EQU    0x9100
FST_ENTRY       .EQU    0x9180
FST_BUF         .EQU    0x9200
FST_ENTRY2      .EQU    0x9184
FST_NAME        .EQU    0x9280
FST_NAME2       .EQU    0x92A0

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
:
                MOVE    R1, R8
                MOVE    R2, FST_BUF
                CALL    _fs_readdir
                CMP     R1, 1
        ?!Z     JMP     :+
                ADD     R9, R9, 1
                JMP     :-
:
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
; Long names
                MOVE    R1, FST_ROOT
                MOVE    R2, 2
                CALL    _fs_open
                MOVE    @R7++, R1
                MOVE    R8, R1          ; the folder's handle
                MOVE    R2, FST_BUF+64
                MOVE    R3, FST_NAME
                CALL    _fs_readname    ; HELLO.BIN
                MOVE    R1, R8
                MOVE    R2, FST_BUF+64
                MOVE    R3, FST_NAME
                CALL    _fs_readname    ; SUB
                MOVE    R1, R8
                MOVE    R2, FST_ENTRY2
                MOVE    R3, FST_NAME
                CALL    _fs_readname    ; A long name.txt
                MOVE    @R7++, R1
                MOVE    R1, R8
                MOVE    R2, FST_BUF+64
                MOVE    R3, FST_NAME2
                CALL    _fs_readname    ; readme.txt
                MOVE    @R7++, R1
                MOVE    R1, R8
                CALL    _fs_close
                MOVE    @R7++, R1
                MOVE    R1, FST_LNAME
                MOVE    R2, 0
                CALL    _fs_open
                MOVE    @R7++, R1
                CALL    _fs_close
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
FST_LNAME
                .ASCII_L 'a LONG name.TXT'
