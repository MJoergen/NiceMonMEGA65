; The test of the file entries that write, fs_write and fs_delete, and of
; fs_open with mode 1, of table 1.2 (README.md, "Files"), a program at
; 0x8000 that calls them through the stubs of mon.nasm, which the
; Makefile joins after it, as test/fs.nasm does. Slot 0 has a copy of
; test/fat_image.py's fat32.img, in which KEEP.TXT is read-only, and
; slot 1 a copy of its super.img that cannot be written, so that niceemu
; makes the card write-protected. The program stores the result of each
; call at FSW_RESULTS, which the test dumps; the Makefile then checks the
; card with fsck.fat -n, and lists it and shows its files with mtools.
; The bytes written are FSW_TEXT's: 1000 of them, digits from 0 to 9 and
; round again, with an LF after every 49.
;
;  0  mon_version, 0x00010005, table 1.5
;  1  fs_open of NEW.TXT with mode 1, 0, which mounts slot 0 and makes it
;  2  fs_write of 600 bytes, 600, which take two clusters of one sector
;  3  fs_write of 0 bytes, 0
;  4  fs_write of 100 bytes more, 100
;  5  fs_read of the handle, -24, which is opened to write
;  6  fs_open of NEW.TXT to read, -31, as it is open to write
;  7  fs_open of new.txt to write, -31
;  8  fs_close, 0, which writes its last sector and its entry
;  9  fs_open of NEW.TXT to read, 0
; 10  fs_write of the handle, -24, which is opened to read
; 11  fs_read of up to 1000 bytes to FSW_READ, 700
; 12  the bytes read that are not those written, 0
; 13  fs_open of NEW.TXT to write, -31, as it is open to read
; 14  fs_delete of NEW.TXT, -31
; 15  fs_close, 0
; 16  fs_open of HELLO.BIN with mode 1, 0, which truncates it
; 17  fs_write of 50 bytes, 50, its new first line
; 18  fs_close, 0
; 19  fs_open of BIG.BIN with mode 1, 0
; 20  five fs_writes of 1000 bytes, 5000 in all, across 10 clusters
; 21  fs_close, 0
; 22  fs_delete of ALONGN~1.TXT, 0, with its long-name entries
; 23  fs_delete of FILE01.TXT, 0
; 24  fs_open of FILE01.TXT to read, -21, no such file
; 25  fs_delete of NOFILE, -21
; 26  fs_delete of SUB, -22, a directory
; 27  fs_delete of KEEP.TXT, -32, read-only
; 28  fs_open of KEEP.TXT with mode 1, -32
; 29  fs_delete of TOOLONGNAME, -21, which may be a long name
; 30  fs_open with mode 3, -25, no such mode
; 31  the files E00.TXT to E23.TXT made empty with fs_open and fs_close,
;     24, which fill the folder's free entries and take a new cluster
; 32  fs_open of DROP.TXT with mode 1, 0
; 33  fs_mount of slot 1, 0, which closes DROP.TXT, empty
; 34  fs_write of DROP.TXT's handle, -24
; 35  fs_close of it, -24
; 36  fs_open of W.TXT with mode 1 on the write-protected card, -6
; 37  fs_delete of HELLO.BIN there, -6
; 38  fs_mount of slot 0, 0
; 39  fs_open of DROP.TXT to read, 0
; 40  fs_read of it, 0, as it is empty
; 41  fs_close, 0
;
; It returns the number of results, 42.

                .ORG    0x8000
FSW_RESULTS     .EQU    0x9100
FSW_NAME        .EQU    0x9180          ; E00.TXT to E23.TXT, a character per word
FSW_TEXT        .EQU    0x9200          ; the 1000 bytes written
FSW_READ        .EQU    0x9600          ; the bytes read back

fsw_main
                MOVE    R7, FSW_RESULTS
; FSW_TEXT: the digits, with an LF after every 49
                MOVE    R1, FSW_TEXT
                MOVE    R2, 0x30        ; the next digit
                MOVE    R3, 0           ; the digits of the line
:
                CMP     R3, 49
        ?Z      MOVE    @R1++, 0x0A
        ?Z      MOVE    R3, 0
        ?Z      JMP     :+
                MOVE    @R1++, R2
                ADD     R2, R2, 1
                CMP     R2, 0x3A
        ?Z      MOVE    R2, 0x30
                ADD     R3, R3, 1
:
                CMP     R1, FSW_TEXT+1000
        ?!Z     JMP     :--
                CALL    _mon_version
                MOVE    @R7++, R1
; NEW.TXT, written in three pieces, and read back
                MOVE    R1, FSW_NEW
                MOVE    R2, 1
                CALL    _fs_open
                MOVE    @R7++, R1
                MOVE    R8, R1          ; its handle
                MOVE    R2, FSW_TEXT
                MOVE    R3, 600
                CALL    _fs_write
                MOVE    @R7++, R1
                MOVE    R1, R8
                MOVE    R2, FSW_TEXT+600
                MOVE    R3, 0
                CALL    _fs_write
                MOVE    @R7++, R1
                MOVE    R1, R8
                MOVE    R2, FSW_TEXT+600
                MOVE    R3, 100
                CALL    _fs_write
                MOVE    @R7++, R1
                MOVE    R1, R8
                MOVE    R2, FSW_READ
                MOVE    R3, 1
                CALL    _fs_read
                MOVE    @R7++, R1
                MOVE    R1, FSW_NEW
                MOVE    R2, 0
                CALL    _fs_open
                MOVE    @R7++, R1
                MOVE    R1, FSW_NEWLC
                MOVE    R2, 1
                CALL    _fs_open
                MOVE    @R7++, R1
                MOVE    R1, R8
                CALL    _fs_close
                MOVE    @R7++, R1
                MOVE    R1, FSW_NEW
                MOVE    R2, 0
                CALL    _fs_open
                MOVE    @R7++, R1
                MOVE    R8, R1
                MOVE    R2, FSW_TEXT
                MOVE    R3, 1
                CALL    _fs_write
                MOVE    @R7++, R1
                MOVE    R1, R8
                MOVE    R2, FSW_READ
                MOVE    R3, 1000
                CALL    _fs_read
                MOVE    @R7++, R1
                MOVE    R1, 0           ; the bytes that differ
                MOVE    R2, 0
:
                CMP     @FSW_TEXT[R2], @FSW_READ[R2]
        ?!Z     ADD     R1, R1, 1
                ADD     R2, R2, 1
                CMP     R2, 700
        ?!Z     JMP     :-
                MOVE    @R7++, R1
                MOVE    R1, FSW_NEW
                MOVE    R2, 1
                CALL    _fs_open
                MOVE    @R7++, R1
                MOVE    R1, FSW_NEW
                CALL    _fs_delete
                MOVE    @R7++, R1
                MOVE    R1, R8
                CALL    _fs_close
                MOVE    @R7++, R1
; HELLO.BIN truncated, and BIG.BIN written
                MOVE    R1, FSW_HELLO
                MOVE    R2, 1
                CALL    _fs_open
                MOVE    @R7++, R1
                MOVE    R8, R1
                MOVE    R2, FSW_TEXT
                MOVE    R3, 50
                CALL    _fs_write
                MOVE    @R7++, R1
                MOVE    R1, R8
                CALL    _fs_close
                MOVE    @R7++, R1
                MOVE    R1, FSW_BIG
                MOVE    R2, 1
                CALL    _fs_open
                MOVE    @R7++, R1
                MOVE    R8, R1
                MOVE    R9, 5           ; the writes left
                MOVE    R10, 0          ; the bytes written
:
                MOVE    R1, R8
                MOVE    R2, FSW_TEXT
                MOVE    R3, 1000
                CALL    _fs_write
                ADD     R10, R10, R1
                SUB[M]  R9, R9, 1
        ?!Z     JMP     :-
                MOVE    @R7++, R10
                MOVE    R1, R8
                CALL    _fs_close
                MOVE    @R7++, R1
; Deletions, and their errors
                MOVE    R1, FSW_LONG
                CALL    _fs_delete
                MOVE    @R7++, R1
                MOVE    R1, FSW_FILE01
                CALL    _fs_delete
                MOVE    @R7++, R1
                MOVE    R1, FSW_FILE01
                MOVE    R2, 0
                CALL    _fs_open
                MOVE    @R7++, R1
                MOVE    R1, FSW_NOFILE
                CALL    _fs_delete
                MOVE    @R7++, R1
                MOVE    R1, FSW_SUB
                CALL    _fs_delete
                MOVE    @R7++, R1
                MOVE    R1, FSW_KEEP
                CALL    _fs_delete
                MOVE    @R7++, R1
                MOVE    R1, FSW_KEEP
                MOVE    R2, 1
                CALL    _fs_open
                MOVE    @R7++, R1
                MOVE    R1, FSW_TOOLONG
                CALL    _fs_delete
                MOVE    @R7++, R1
                MOVE    R1, FSW_NEW
                MOVE    R2, 3
                CALL    _fs_open
                MOVE    @R7++, R1
; E00.TXT to E23.TXT, empty, the digits of the name in FSW_NAME+1 and +2
                MOVE    R1, FSW_NAME
                MOVE    R2, FSW_E00
:
                MOVE[M] @R1++, @R2++
        ?!Z     JMP     :-
                MOVE    R9, 0           ; the files made
fsw_e
                MOVE    R1, FSW_NAME
                MOVE    R2, 1
                CALL    _fs_open
                TST     R1
        ?N      JMP     :+
                CALL    _fs_close
                TST     R1
        ?Z      ADD     R9, R9, 1
:
                ADD     @FSW_NAME+2, @FSW_NAME+2, 1
                CMP     @FSW_NAME+2, 0x3A
        ?Z      MOVE    @FSW_NAME+2, 0x30
        ?Z      ADD     @FSW_NAME+1, @FSW_NAME+1, 1
                CMP     @FSW_NAME+2, 0x34
        ?!Z     JMP     fsw_e
                CMP     @FSW_NAME+1, 0x32
        ?!Z     JMP     fsw_e           ; up to E23.TXT
                MOVE    @R7++, R9
; A file whose mount is dropped, and the write-protected card
                MOVE    R1, FSW_DROP
                MOVE    R2, 1
                CALL    _fs_open
                MOVE    @R7++, R1
                MOVE    R8, R1
                MOVE    R1, 1
                CALL    _fs_mount
                MOVE    @R7++, R1
                MOVE    R1, R8
                MOVE    R2, FSW_TEXT
                MOVE    R3, 10
                CALL    _fs_write
                MOVE    @R7++, R1
                MOVE    R1, R8
                CALL    _fs_close
                MOVE    @R7++, R1
                MOVE    R1, FSW_W
                MOVE    R2, 1
                CALL    _fs_open
                MOVE    @R7++, R1
                MOVE    R1, FSW_HELLO
                CALL    _fs_delete
                MOVE    @R7++, R1
                MOVE    R1, 0
                CALL    _fs_mount
                MOVE    @R7++, R1
                MOVE    R1, FSW_DROP
                MOVE    R2, 0
                CALL    _fs_open
                MOVE    @R7++, R1
                MOVE    R8, R1
                MOVE    R2, FSW_READ
                MOVE    R3, 10
                CALL    _fs_read
                MOVE    @R7++, R1
                MOVE    R1, R8
                CALL    _fs_close
                MOVE    @R7++, R1
                SUB     R1, R7, FSW_RESULTS
                RET

FSW_NEW         .ASCII_L 'NEW.TXT'
FSW_NEWLC
                .ASCII_L 'new.txt'
FSW_HELLO
                .ASCII_L 'HELLO.BIN'
FSW_BIG         .ASCII_L 'BIG.BIN'
FSW_LONG
                .ASCII_L 'ALONGN~1.TXT'
FSW_FILE01
                .ASCII_L 'FILE01.TXT'
FSW_NOFILE
                .ASCII_L 'NOFILE'
FSW_SUB         .ASCII_L 'SUB'
FSW_KEEP
                .ASCII_L 'KEEP.TXT'
FSW_TOOLONG
                .ASCII_L 'TOOLONGNAME'
FSW_E00         .ASCII_L 'E00.TXT'
FSW_DROP
                .ASCII_L 'DROP.TXT'
FSW_W           .ASCII_L 'W.TXT'
