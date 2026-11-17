; FAT32 in the ROM, which the Makefile joins after monitor.nasm (its
; header): the file entries fs_mount, fs_open, fs_read, fs_readdir,
; fs_close, fs_write, fs_delete, and fs_readname of the dispatch table,
; and fat_dir, fat_load, fat_save, and fat_complete for BASIC's DIR, LOAD,
; SAVE, and the TAB key (issues #58, #59, #91, #102, #137, and #149,
; doc/SDCARD.md, "The file system").
;
; Names are long names (VFAT) of up to 255 characters, matched in either
; case, or 8.3 names. A long name is read from the long-name entries
; before an 8.3 entry, when their numbers, their last-entry bit, and their
; checksum check; a set that does not is passed over, and the 8.3 name
; stands, with the lower-case flags of byte 12. A character outside ASCII
; is ?, and such a name is reached by its 8.3 name only. A new file whose
; name is not an 8.3 name in upper case, or in lower case in either part,
; which byte 12 keeps, gets long-name entries and an 8.3 alias, with a
; tail ~1, ~2, and on when the name does not fit, as mtools makes them.
;
; The card is the one in the slot of the last mount. A card is FAT32 when
; its sector 0 is a FAT32 boot sector, or an MBR whose first partition of
; type 0x0B or 0x0C has one. A FAT12, FAT16, or exFAT boot sector, by the
; count of clusters of Microsoft's specification, or exFAT's name, gives
; an error of its own. The mount is dropped, and with it the open files,
; when the selected slot is no longer the mounted one, or its card is not
; ready or has changed. fs_open mounts again when it finds no mount: the
; slot of the last mount, or after the cold start slot 0, or slot 1 when
; slot 0 has no card and the board has a slot 1.
;
; The files are those of the folder FOLDER of the root directory, NICE
; unless the build sets another (make FOLDER=NAME), as a card may be
; shared by several cores. A mount looks the folder up, and fails without
; it, so nothing reaches the root's files or another core's.
;
; The state is in the monitor's RAM (monitor.nasm, from FAT_RAM): the
; volume's fields, a cache of one sector of the FAT, FATBUF, the two file
; structures, FILE0 and FILE1, and DIRF, the folder that the lookups,
; DIR, and TAB read, each with its sector, and SEC, a sector for FSInfo,
; an entry, or a new cluster's zeros. A sector is 128 words, 4 bytes a
; word, little-endian, as the SD controller has it. The cold start clears
; the mount and the handles, with fat_reset; a program's return keeps
; them. Errors are negative: those of the SD controller, -1 to -8, and
; those below, from -16.
;
; Writing keeps to an order in which a reset at any point leaves the card
; no worse than with lost clusters, which fsck.fat frees. A file opened
; to write gets its directory entry at once, empty, with no clusters, and
; an existing file is truncated so: the entry first, then its clusters
; freed. The file's clusters are taken from the FAT as its data reaches
; them, each marked as the end of the chain in every copy of the FAT
; before the one before it is linked to it, and its data written; only
; fs_close puts the first cluster, the size, and the date into the entry.
; A deletion marks the long-name entries, then the entry, then frees the
; clusters. A new entry's long-name entries are written before its 8.3
; entry. A new cluster is searched from FSInfo's next-free hint, and the
; first change of the FAT after a mount sets FSInfo's free count to
; unknown, 0xFFFFFFFF, before it; the hint is written after each change.
; The FAT's cache and the folder's are written through; a file's sector
; is written when it is full, and at fs_close. No sector outside the
; partition is ever written, nor its boot sector: wr checks each.
;
; The routines of the entries run in fat_call, which keeps R7-R12 for the
; caller, as the C ABI does, and saves SP in V_FSP. An error goes to
; fat_fail with R1 the error, which takes SP back from V_FSP, and so
; returns from the entry from any depth, with the state as it stands. The
; routines inside take and return their values in registers and flags, as
; each one's comment says. R12 is the file structure that seek, entry,
; getc, and put work on, and R10 the directory entry that entry, find,
; and at give, the word address of its 8 words.
;
; A byte of the monitor's RAM, where the sectors are, is reached by a byte
; pointer, 4 times the word's address plus the byte's number, modulo
; 2^32, with ldb and stb: the RAM is from 0xC0000000 up, so the word is
; the pointer shifted right by 2, plus 0xC0000000. The byte window of
; DEVICES.md §9 does not reach it.

; The fields of a file structure, FILE0, FILE1, and DIRF
F_POS           .EQU    0               ; the byte offset of the next byte
F_CPOS          .EQU    1               ; the byte offset of the start of F_CLUS
F_DONE          .EQU    2               ; a folder's end was found
F_LBA           .EQU    3               ; the sector in F_BUF, ~0 for none
F_SIZE          .EQU    4               ; a file's size, to read
F_FIRST         .EQU    5               ; the first cluster, 0 for an empty file
F_CLUS          .EQU    6               ; the cluster that holds the byte at F_CPOS
F_KIND          .EQU    7               ; 0 for closed, or the kind + 1: K_READ, K_WRITE, or K_DIR
F_ELBA          .EQU    8               ; a file's entry: its sector,
F_EOFF          .EQU    9               ; and its word in that sector
F_LFN           .EQU    10              ; a folder's: the offset of the long name before the entry that entry gave, or ~0
F_BUF           .EQU    11              ; the sector, 128 words
F_WORDS         .EQU    139
K_READ          .EQU    1               ; the kinds + 1, as F_KIND has them
K_WRITE         .EQU    2
K_DIR           .EQU    3
FAT_END         .EQU    0x0FFFFFF8      ; a FAT entry from here ends a chain
FAT_EOC         .EQU    0x0FFFFFFF      ; the FAT entry written at the end of a chain
DIR_MAX         .EQU    65536*32        ; the bytes of a folder at most
FAT_DATE        .EQU    0x5C21          ; the date of an entry, 2026-01-01, while the clock is not set
DIR_NAME        .EQU    24              ; DIR's column of the sizes

; The entries: each runs its routine in fat_call
fs_mount
                MOVE    R6, mount
                JMP     fat_call
fs_open         MOVE    R6, open_b
                JMP     fat_call
fs_read         MOVE    R6, read_b
                JMP     fat_call
fs_readdir
                CLR     R4
                JMP     :+
fs_readname
                ONE     R4
:               MOVE    R6, rdn_b
                JMP     fat_call
fs_close
                MOVE    R6, close_b
                JMP     fat_call
fs_write
                MOVE    R6, write_b
                JMP     fat_call
fs_delete
                MOVE    R6, delete_b
                JMP     fat_call
fat_dir         MOVE    R6, dir_b
                JMP     fat_call
fat_load
                MOVE    R6, load_b
                JMP     fat_call
fat_save
                MOVE    R6, save_b
; fat_call: the routine at R6 called with R1-R4, and R7-R12 kept. Its
; return, or fat_fail, gives R1. When a mount stood and no file was open,
; an SD error that drops the mount (chk) runs the routine once more, on a
; new mount: the card in the R3's slot 1, which has no card detect, may
; be another than the mount's, and starts up only then.
fat_call
                PUSH    R7
                PUSH    R8
                PUSH    R9
                PUSH    R10
                PUSH    R11
                PUSH    R12
                OR[M]   R0, @FILE0+F_KIND, @FILE1+F_KIND
        ?Z      MOVE    R5, @V_MOUNTED  ; the retry allowed, when not 0
        ?!Z     CLR     R5
call_again
                PUSH    R5
                PUSH    R6
                PUSH    R1
                PUSH    R2
                PUSH    R3
                PUSH    R4
                ADD     @--SP, 3, PC    ; the return address, after JMP R6
                MOVE    @V_FSP, SP
                JMP     R6
                MOVE    R5, R1
                POP     R4
                POP     R3
                POP     R2
                POP     R1
                POP     R6
                POP     R8              ; the retry allowed
                TST     R8
        ?Z      JMP     :+
                CMP     R5, -8
        ?C      JMP     :+              ; not an SD error, -8 to -1
                CMP     R5, -6
        ?!Z     CMP     R5, -7
        ?Z      JMP     :+              ; 6 and 7 keep the mount
                CLR     R5              ; once
                JMP     call_again
:               MOVE    R1, R5
                POP     R12
                POP     R11
                POP     R10
                POP     R9
                POP     R8
                POP     R7
                RET

; The errors, R1, and fat_fail: back to the return address that V_FSP
; points at, with R1
fail16          MOVE    R1, -16
                JMP     fat_fail
fail20          MOVE    R1, -20
                JMP     fat_fail
fail24          MOVE    R1, -24
                JMP     fat_fail
fail30          MOVE    R1, -30
                JMP     fat_fail
fail26          MOVE    R1, -26
fat_fail
                MOVE    SP, @V_FSP
                RET

; fat_complete: TAB on BASIC's line, from line R1 to the cursor R2, with
; room up to R3 (issue #137). R1 = the new cursor, or 0 when the matches
; were listed, and the cursor R2 when nothing matches, the line is full,
; or on an error. R7-R12 kept.
fat_complete
                PUSH    R2
                MOVE    R6, comp_b
                CALL    fat_call
                POP     R2
                CMP     R1, -32
        ?!C     MOVE    R1, R2          ; an error, -32 to -1, never a line's address
                RET

; ldb: R1 = the byte at the byte pointer R2, and R2 moved on. Uses R3
; and R4.
ldb
                SHR     R3, R2, 2
                AND     R4, R2++, 3
                SHL     R4, R4, 3
                SHR     R1, @0xC0000000[R3], R4
                AND     R1, R1, 0xFF
                RET

; ld16: R1 = the 16 bits at the byte pointer R2, little-endian, and R2
; moved on. Uses R3 and R4.
ld16
                CALL    ldb
                PUSH    R1
                CALL    ldb
                SHL     R1, R1, 8
                OR      R1, R1, @SP++
                RET

; ini, rd: sd_init of the slot R1, and sd_read of the sector R1 into the
; 128 words at R2, which fail with the controller's error. Use R1-R4.
; chk: an error but 6, write-protected, and 7, a sector after the last,
; leaves the card in a state that is not known, so it drops the mount, and
; the next command starts the card up again. The R3's slot 1 has no card
; detect, so a card put in there is not "changed", and the controller
; stays "ready" for the card before it, which does not answer (error 3).
ini
                CALL    sd_init
                JMP     chk
rd
                CALL    sd_read
chk
        ?Z      RET
                CMP     R1, -6
        ?!Z     CMP     R1, -7
        ?!Z     CALL    drop
                JMP     fat_fail

; fat_reset: no mount, and no file open, at the cold start, and then
; drop: no mount, no sector in FATBUF, and the files closed. Use no
; register.
fat_reset
                CLR     @V_EVER
drop
                CLR     @V_MOUNTED
                NOT     @V_FATLBA, R0
                CLR     @FILE0+F_KIND
                CLR     @FILE1+F_KIND
                RET

; valid: Z when the mount stands: the mounted slot is selected, and its
; card is ready and has not changed. Otherwise the mount is dropped, and Z
; is clear. Uses R1.
valid
                TST     @V_MOUNTED
        ?Z      NOT[M]  R0, R0          ; Z clear, X set: no mount
        ?X      RET
                AND     R1, @SD_CSR, SD_READY+SD_CHANGED
                CMP     @SD_SELECT, @V_SLOT
        ?Z      CMP     R1, SD_READY
        ?Z      RET
                JMP     drop            ; with Z clear

; mounted: a mount, the one that stands, or a new one of the slot of the
; last, or after the cold start of slot 0, or of slot 1 when slot 0 has no
; card and the board has a slot 1. Uses R1-R12.
mounted
                CALL    valid
        ?Z      RET
                MOVE    R1, @V_SLOT
                TST     @V_EVER
        ?!Z     JMP     mount
                PUSH    @V_FSP          ; mount(0), with its errors caught
                CLR     R1
                ADD     @--SP, 4, PC
                MOVE    @V_FSP, SP
                JMP     mount
                POP     @V_FSP
                TST     R1
        ?!X     JMP     :+              ; not -1
                CMP     @SD_SLOTS, 2
        ?!C     ONE     R1
        ?!C     JMP     mount
:               TST     R1
        ?N      JMP     fat_fail
                RET

; kind: the kind of the sector in FATBUF: Z for a FAT32 boot sector, Z
; clear for none, or none with the 55 AA signature; another file system
; fails with its error. V_LOG = log2 of its sectors per cluster. Uses
; R1-R9.
kind
                SHR     R1, @FATBUF, 24  ; exFAT's name, at bytes 3 to 10
                CMP     R1, 0x45
        ?Z      CMP     @FATBUF+1, 0x54414658
        ?Z      AND     R1, @FATBUF+2, 0xFFFFFF
        ?Z      CMP     R1, 0x202020
        ?Z      MOVE    R1, -19
        ?Z      JMP     fat_fail
                MOVE    R1, @FATBUF+3
                SHR     R5, R1, 8
                AND     R5, R5, 0xFF    ; spc
                SHR     R6, R1, 16      ; rsvd
                AND     R7, @FATBUF+4, 0xFF  ; nfats
                SHR[M]  R8, @FATBUF+5, 16  ; fatsz, 16 bits
        ?Z      MOVE    R8, @FATBUF+9   ; or 32
                MOVE    R2, 4*FATBUF+19
                CALL    ld16
                MOVE[M] R9, R1          ; total, 16 bits
        ?Z      MOVE    R9, @FATBUF+8   ; or 32
                AND     R1, @FATBUF, 0xFF
                CMP     R1, 0xEB
        ?!Z     CMP     R1, 0xE9
        ?!Z     JMP     kind_no
                MOVE    R2, 4*FATBUF+11
                CALL    ld16
                CMP     R1, 512
        ?!Z     JMP     kind_no
                SUB     R1, R5, 1
                AND[M]  R0, R1, R5
        ?!Z     JMP     kind_no         ; not a power of 2
                CMP     R5, 1
        ?C      JMP     kind_no         ; no sector per cluster
                CMP     R6, 1
        ?!C     CMP     R7, 1
        ?!C     CMP     R8, 1
        ?C      JMP     kind_no
                SHR     R1, @FATBUF+127, 16
                CMP     R1, 0xAA55
        ?!Z     JMP     kind_no
; The sectors before the data, the reserved ones, the FATs, and FAT12 and
; FAT16's root directory, must leave room for the data. A damaged sector
; can say FATs of billions of sectors, so the FATs are checked against
; the room before their size is summed.
                SHR     R1, @FATBUF+4, 8
                AND     R1, R1, 0xFFFF  ; the root directory's entries
                SHL     R2, R1, 5
                ADD     R2, R2, 511
                SHR     R2, R2, 9
                ADD     R2, R2, R6      ; fixed
                CMP     R2, R9
        ?!C     JMP     fail16          ; total <= fixed
                SUB     R3, R9, R2
                MOVE    @io.mpu_a, R3
                MOVE    @io.mpu_b, R7
                CMP     @io.mpu_udivq, R8
        ?C      JMP     fail16          ; fatsz > (total - fixed) / nfats
:               ADD     R2, R2, R8
                SUB[M]  R7, R7, 1
        ?!Z     JMP     :-
                CMP     R2, R9
        ?!C     JMP     fail16          ; total <= meta
                SUB     R3, R9, R2
                CLR     R4              ; log2 spc
:               SHR[M]  R5, R5, 1
        ?Z      JMP     :+
                MOVE    R4++, R4
                JMP     :-
:               MOVE    @V_LOG, R4
                SHR     R3, R3, R4      ; the clusters
                CMP     R3, 4085
        ?C      MOVE    R1, -17
        ?C      JMP     fat_fail
                CMP     R3, 65525
        ?C      MOVE    R1, -18
        ?C      JMP     fat_fail
                SHR     R2, @FATBUF+5, 16
                OR[M]   R0, R1, R2      ; FAT16's fields, R1 the root's entries
        ?!Z     JMP     fail16
                RET                     ; Z
kind_no
                NOT[M]  R0, R0
                RET

; mount: the card in the slot R1 mounted; a slot that the system does not
; have changes nothing. R1 = 0. Uses R1-R12.
mount
                CMP     R1, @SD_SLOTS
        ?!C     MOVE    R1, -27
        ?!C     JMP     fat_fail
                MOVE    R11, R1
                CALL    drop
                ONE     @V_EVER
                MOVE    @V_SLOT, R11
                CLR     @V_HINT
                CLR     @V_UNKNOWN
                CLR     @V_CHANGED
                MOVE    R1, R11
                CALL    ini
                CLR     R1
                MOVE    R2, FATBUF
                CALL    rd
                CLR     R10             ; the partition's first sector
                CALL    kind
        ?Z      JMP     mount_fat
                SHR     R1, @FATBUF+127, 16
                CMP     R1, 0xAA55
        ?!Z     JMP     fail16
; The first FAT32 partition, or else the first partition, whose boot
; sector says what it is: R10 and R9. An entry's type is byte 4, and its
; first sector bytes 8 to 11, at 446 + 16 i.
                CLR     R9
                MOVE    R8, FATBUF+112
:               SHR     R1, @R8, 16
                AND     R1, R1, 0xFF
                SHR     R2, @1[R8], 16
                SHL     R3, @2[R8], 16
                OR      R2, R2, R3
                CMP     R1, 0x0B
        ?!Z     CMP     R1, 0x0C
        ?Z      MOVE    R10, R2
        ?Z      JMP     :+
                TST     R1
        ?Z      JMP     :+
                TST     R9
        ?Z      MOVE    R9, R2
:               ADD     R8, R8, 4
                TST     R10
        ?!Z     JMP     :+
                CMP     R8, FATBUF+128
        ?!Z     JMP     :--
:               OR[M]   R0, R10, R9
        ?Z      JMP     fail16
                MOVE[M] R1, R10
        ?Z      MOVE    R1, R9
                MOVE    R2, FATBUF
                CALL    rd
                CALL    kind
        ?!Z     JMP     fail16
                TST     R10
        ?Z      JMP     fail16          ; FAT32 in a partition of another type
mount_fat
                SHL     @V_BYTES, 512, @V_LOG
                SHR     R1, @FATBUF+3, 16
                ADD     R1, R1, R10
                MOVE    @V_FAT, R1
                AND     R2, @FATBUF+4, 0xFF
                MOVE    @V_NFATS, R2
                MOVE    R3, @FATBUF+9
                MOVE    @V_FATSZ, R3
:               ADD     R1, R1, R3
                SUB[M]  R2, R2, 1
        ?!Z     JMP     :-
                MOVE    @V_DATA, R1
                MOVE    @V_ROOT, @FATBUF+11
                ADD     R2, R10, @FATBUF+8
                MOVE    @V_END, R2
                SUB     R2, R2, R1
                SHR     R2, R2, @V_LOG
                ADD     R2, R2, 2
                SHL     R3, R3, 7       ; FAT32's FATs may have more entries than the volume has clusters
                CMP     R3, R2
        ?C      MOVE    R2, R3
                MOVE    @V_TOP, R2
                AND     R1, @FATBUF+12, 0xFFFF  ; FSInfo, from 1 to below rsvd
                SHR     R2, @FATBUF+3, 16
                SUB     R2, R2, 1
                SUB     R3, R1, 1
                CLR     R4
                CMP     R3, R2
        ?C      ADD     R4, R1, R10
                MOVE    @V_FSINFO, R4
                MOVE    R1, @V_ROOT
                CALL    clok
        ?!C     JMP     fail26
; The folder: FOLDER padded with blanks, a directory of the root
                MOVE    @V_N, @FOLDER_N
                MOVE    @V_N+1, @FOLDER_N+1
                MOVE    @V_N+2, @FOLDER_N+2
                CLR     @V_BYLONG
                CALL    find
        ?!Z     SHR     R1, @2[R10], 24
        ?!Z     AND[M]  R0, R1, 0x10
        ?Z      MOVE    R1, -29         ; no folder, or a file of its name
        ?Z      JMP     fat_fail
                CALL    cluster
                CALL    clok
        ?!C     JMP     fail26
                MOVE    @V_DIR, R1
                ONE     @V_MOUNTED
                CLR     R1
                RET

; clok: C when the cluster R1 is in the volume, 2 to V_TOP - 1, so for
; none when V_TOP is below 2, as a boot sector may make it. Uses no
; register.
clok
                CMP     1, R1           ; C from 2 on,
        ?C      CMP     R1, @V_TOP      ; and then C below V_TOP
                RET

; cache: the sector R1 into the 128 words at R2, unless the word at R3,
; the sector that they hold, is R1 already. That word is ~0 while the
; sector is read, and R1 after. C clear. Uses R1-R4.
cache
                CMP     R1, @R3
        ?Z      RET
                NOT     @R3, R0
                PUSH    R3
                PUSH    R1
                CALL    rd
                POP     R1
                POP     R3
                MOVE    @R3, R1
                RET

; fatsec: R1 = the address in FATBUF of the FAT's entry of cluster R1,
; whose sector of the first FAT is read. Uses R1-R4.
fatsec
                PUSH    R1
                SHR     R1, R1, 7
                ADD     R1, R1, @V_FAT
                MOVE    R2, FATBUF
                MOVE    R3, V_FATLBA
                CALL    cache
                POP     R1
                AND     R1, R1, 127
                ADD     R1, R1, FATBUF
                RET

; next: R1 = the FAT's entry of cluster R1, its bits 27..0. Uses R1-R4.
next
                CALL    fatsec
                AND     R1, @R1, 0x0FFFFFFF
                RET

; seek: the sector of the file R12 that holds the byte at F_POS in its
; F_BUF, along the chain of clusters: C clear, or C at the end of the
; chain. seekx: the same, but the end of the chain fails 26. Use R1-R4.
seekx
                CALL    seek
        ?C      JMP     fail26
                RET
seek
                SUB     R1, @R12, @F_CPOS[R12]
                CMP     R1, @V_BYTES
        ?C      JMP     :+
                MOVE    R1, @F_CLUS[R12]
                CALL    next
                CMP     FAT_END-1, R1
        ?C      RET                     ; the end
                CALL    clok
        ?!C     JMP     fail26
                MOVE    @F_CLUS[R12], R1
                ADD     @F_CPOS[R12], @F_CPOS[R12], @V_BYTES
                JMP     seek
:               CALL    clba
                ADD     R2, R12, F_BUF
                ADD     R3, R12, F_LBA
                JMP     cache

; clba: R1 = the sector of the file R12 that holds the byte at F_POS, in
; the cluster F_CLUS. Uses R1 and R2.
clba
                SUB     R1, @R12, @F_CPOS[R12]
                SHR     R1, R1, 9
                SUB     R2, @F_CLUS[R12], 2
                SHL     R2, R2, @V_LOG
                ADD     R1, R1, R2
                ADD     R1, R1, @V_DATA
                RET

; fbyte: R2 = the byte pointer of the byte at F_POS of the file R12 in
; its F_BUF. Uses R3.
fbyte
                AND     R2, @R12, 511
                ADD     R3, R12, F_BUF
                SHL     R3, R3, 2
                ADD     R2, R2, R3
                RET

; ep: R10 = the entry at F_POS of the folder R12 in its F_BUF
ep
                AND     R10, @R12, 511
                SHR     R10, R10, 2
                ADD     R10, R10, R12
                ADD     R10, R10, F_BUF
                RET

; sdir: the folder FOLDER at R12 from its start. startd: the folder from
; the cluster R1. start: the file R12 from the cluster R1, of the kind R2
; and the size R3, open. Use R1-R4.
sdir
                MOVE    R1, @V_DIR
startd
                MOVE    R2, K_DIR
                CLR     R3
start
                MOVE    R4, R12
                CLR     @R4++           ; F_POS
                CLR     @R4++           ; F_CPOS
                CLR     @R4++           ; F_DONE
                NOT     @R4++, R0       ; F_LBA
                MOVE    @R4++, R3       ; F_SIZE
                MOVE    @R4++, R1       ; F_FIRST
                MOVE    @R4++, R1       ; F_CLUS
                MOVE    @R4++, R2       ; F_KIND
                RET

; fileh: R12 = the file structure of the handle R1, 0 or 1
fileh
                MOVE    R12, FILE0
                TST     R1
        ?!Z     MOVE    R12, FILE1
                RET

; handle: R12 = the open file of the handle R1 of the kind R5, which
; fails 24 for no such handle, and 28 when the mount was dropped, which
; closes all. Uses R1, and keeps R2-R4.
handle
                CMP     R1, 2
        ?!C     JMP     fail24
                CALL    fileh
                CMP     @F_KIND[R12], R5
        ?!Z     JMP     fail24
                CALL    valid
        ?Z      RET
fail28          MOVE    R1, -28
                JMP     fat_fail

; cluster: R1 = the first cluster of the entry R10. Uses R2.
cluster
                SHL     R1, @5[R10], 16
                SHR     R2, @6[R10], 16
                OR      R1, R1, R2
                RET

; isdir: fails 22 when the entry R10 is a directory, Z clear; and
; returns Z when it is not. R1 = its attribute.
isdir
                SHR     R1, @2[R10], 24
                AND[M]  R0, R1, 0x10
        ?Z      RET
                MOVE    R1, -22
                JMP     fat_fail

; sum: R6 = the checksum of the 11 bytes of an 8.3 name at the byte
; pointer R2, that its long-name entries hold. Uses R1-R5.
sum
                CLR     R6
                MOVE    R5, 11
:               CALL    ldb
                0>C[M]  R6, R6, 1
        ?C      OR      R6, R6, 0x80
                ADD     R6, R6, R1
                AND     R6, R6, 0xFF
                SUB[M]  R5, R5, 1
        ?!Z     JMP     :-
                RET

; ucmp: Z when the characters at R4 and R3 are the same but that a letter
; matches either case, R4 and R3 moved on, and R1 = the second's upper
; case. upper: R1 in upper case, and compared with R2. Use R1, R2, and R5.
ucmp
                MOVE    R1, @R4++
                CALL    upper
                MOVE    R2, R1
                MOVE    R1, @R3++
upper
                SUB     R5, R1, 0x61
                CMP     R5, 26
        ?C      SUB     R1, R1, 0x20
                CMP     R1, R2
                RET

; inset: C when the character R1, 0 to 0xFF, is in the set of the 8 words
; at R3, a bit for each. isbad: in SET_BAD, which no name may have: the
; control codes, the bytes from 0x7F, and "*/:<>?\|. isu: in SET_U,
; SET_BAD with the blank and +,.;=[], which a long name may have, but an
; 8.3 name not. Use R3 and R4.
isu
                MOVE    R3, SET_U
                JMP     inset
isbad
                MOVE    R3, SET_BAD
inset
                SHR     R4, R1, 5
                ADD     R4, R4, R3
                BPR[M]  R0, @R4, 1[R1]  ; C = bit R1 mod 32 of the word
                RET
SET_BAD
                .DAT    0xFFFFFFFF, 0xD4008404, 0x10000000, 0x90000000
                .DAT    0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
SET_U
                .DAT    0xFFFFFFFF, 0xFC00DC05, 0x38000000, 0x90000000
                .DAT    0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF

; The bytes of a long-name entry that hold its 13 characters, UTF-16:
; 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, and 30, read in the byte
; window
LFNAT
                .DAT    0x07050301, 0x12100E09, 0x1C181614, 0x0000001E

; getname: the name at the word address R1, one character per word up to
; a 0 word, in WANT, with a 0 after it, and V_WLEN its length. Fails 20
; when it is empty or longer than 255, or has a character outside bits
; 7..0. Uses R1-R4.
getname
                MOVE    R2, WANT
                CLR     R3
:               MOVE[M] R4, @R1++
        ?Z      JMP     :+
                CMP     R3, 255
        ?Z      JMP     fail20
                CMP     R4, 0x100
        ?!C     JMP     fail20
                MOVE    @R2++, R4
                MOVE    R3++, R3
                JMP     :-
:               CLR     @R2
                MOVE    @V_WLEN, R3
                TST     R3
        ?Z      JMP     fail20
                RET

; blankn: V_N 11 blanks, as an entry's words 0 to 2 have an 8.3 name.
; Uses R1.
blankn
                MOVE    R1, 0x20202020
                MOVE    @V_N, R1
                MOVE    @V_N+1, R1
                SHR     @V_N+2, R1, 8
                RET

; name83: WANT as an 8.3 name in upper case in V_N, and V_LOWER the flags
; of byte 12 for a part in lower case, 0x08 the base and 0x10 the
; extension, or ~0 for a part in mixed case: C clear; or C when it is no
; 8.3 name. A dot is the separator once, after a character. R8 has the
; flags, the lower case's in bits 4..3 and the upper case's in bits
; 12..11, and R9 the flag of the part. Uses R1-R10.
name83
                CALL    blankn
                MOVE    R2, 4*V_N
                MOVE    R10, R2         ; the part's start
                MOVE    R7, 4*V_N+8     ; and its end
                MOVE    R9, 0x08
                CLR     R8
                MOVE    R5, WANT
                MOVE    R6, @V_WLEN
n83_char
                MOVE    R1, @R5++
                CMP     R1, 0x2E
        ?Z      CMP     R9, 0x08
        ?!Z     JMP     :+              ; no dot, or in the extension
                CMP     R2, R10
        ?Z      JMP     :+              ; a dot first
                MOVE    R2, 4*V_N+8
                MOVE    R10, R2
                MOVE    R7, 4*V_N+11
                MOVE    R9, 0x10
                JMP     n83_next
:               SUB     R3, R1, 0x41
                CMP     R3, 26
        ?C      SHL     R3, R9, 8
        ?C      OR      R8, R8, R3      ; upper case
                SUB     R3, R1, 0x61
                CMP     R3, 26
        ?C      OR      R8, R8, R9      ; lower case
        ?C      SUB     R1, R1, 0x20
                CALL    isu
        ?C      JMP     n83_no
                CMP     R2, R7
        ?Z      JMP     n83_no          ; too long
                CALL    stb
n83_next
                SUB[M]  R6, R6, 1
        ?!Z     JMP     n83_char
                CMP     R2, R10
        ?Z      JMP     n83_no          ; the part is empty
                SHR     R3, R8, 8
                AND[M]  R0, R3, R8      ; C clear
                AND     R8, R8, 0x18
        ?!Z     NOT     R8, R0          ; mixed case
                MOVE    @V_LOWER, R8
                RET
n83_no
                CMP     R0, 1           ; C
                RET

; stb: bits 7..0 of R1 at the byte pointer R2, and R2 moved on. Uses R1,
; R3, and R4.
stb
                SHR     R3, R2, 2
                ADD     R3, R3, 0xC0000000
                AND     R4, R2++, 3
                SHL     R4, R4, 3
                AND     R1, R1, 0xFF
                SHL     R1, R1, R4
                SHL     R4, 0xFF, R4
                IAND    R4, R4, @R3
                OR      @R3, R4, R1
                RET

; short_name: the 8.3 name of the entry R10 in LNAME as a name: the base,
; then a dot and the extension if it has one, without their blanks, each
; part in lower case when byte 12 says so, and V_LASCII 0 when it has a ?
; for a character outside ASCII. Uses R1-R6.
short_name
                ONE     @V_LASCII
                MOVE    R6, LNAME
                SHL     R2, R10, 2
                CLR     R5              ; k
sn_char
                CALL    ldb
                TST     R5
        ?Z      CMP     R1, 0x05
        ?Z      MOVE    R1, 0xE5
                CMP     R5, 8
        ?!Z     JMP     :+
                CMP     R1, 0x20
        ?!Z     MOVE    @R6++, 0x2E     ; the dot of an extension
:               CMP     R1, 0x20
        ?Z      JMP     sn_next
                SUB     R3, R1, 0x41
                CMP     R3, 26
        ?!C     JMP     :+
                AND     R3, @3[R10], 0xFF  ; byte 12
                CMP     R5, 8
        ?!C     SHR     R3, R3, 1       ; the extension's flag 0x10
                AND[M]  R0, R3, 0x08
        ?!Z     ADD     R1, R1, 0x20
:               SUB     R3, R1, 0x20
                CMP     R3, 0x5F
        ?!C     MOVE    R1, 0x3F
        ?!C     CLR     @V_LASCII
                MOVE    @R6++, R1
sn_next
                MOVE    R5++, R5
                CMP     R5, 11
        ?!Z     JMP     sn_char
                CLR     @R6
                RET

; entry: the next entry of the folder R12 that is a file or a directory,
; at R10, with F_LFN the offset of the long-name entries right before it,
; or ~0, and its name in LNAME: Z clear; or Z at the end. The long-name
; entries are checked as they come: the first holds the last part, its
; number with bit 6 set, and the checksum, and each after it the number
; one less and the same checksum, down to 1. Their characters go to LNAME
; as they come, at the offsets of their numbers. R7 is the offset of the
; first long-name entry, R8 the length of the long name, R9 the number of
; the entry due, 0 after 1, ~0 for none, and R11 the checksum; V_LASCII
; is 0 when the long name has a ? for a character outside ASCII. Uses
; R1-R11.
entry
                NOT     R7, R0
                CLR     R8
                NOT     R9, R0
                CLR     R11
entry_next
                TST     @F_DONE[R12]
        ?!Z     JMP     entry_end
                CALL    seek
        ?C      JMP     entry_end
                CALL    ep
                ADD     @R12, @R12, 32
                AND[M]  R1, @R10, 0xFF
        ?Z      JMP     entry_end       ; the end of the folder
                CMP     R1, 0xE5
        ?Z      JMP     entry_skip      ; free
                SHR     R2, @2[R10], 24
                CMP     R2, 0x0F
        ?!Z     JMP     entry_83
; A long-name entry, of the number k, R3
                TST     R7
        ?X      SUB     R7, @R12, 32
                AND     R3, R1, 0x1F
                SHR     R4, @3[R10], 8
                AND     R4, R4, 0xFF    ; its checksum
                AND[M]  R0, R1, 0x40
        ?!Z     MOVE    R9, R3
        ?!Z     MOVE    R11, R4
        ?!Z     ONE     @V_LASCII
        ?!Z     SHL     R8, R3, 4
        ?!Z     SUB     R8, R8, R3
        ?!Z     SUB     R8, R8, R3
        ?!Z     SUB     R8, R8, R3      ; 13 k
                SUB     R5, R3, 1
                CMP     R5, 20
        ?!C     MOVE    R3, R12         ; k from 1 to 20, or one no R9 is
                CMP     R3, R9
        ?Z      CMP     R4, R11
        ?!Z     NOT     R9, R0
        ?!Z     JMP     entry_next
                PUSH    R12
                SHL     R12, R10, 2
                SHL     R6, R9, 4
                SUB     R6, R6, R9
                SUB     R6, R6, R9
                SUB     R6, R6, R9
                SUB     R6, R6, 13      ; the offset in the name, 13 (k - 1)
                CLR     R5
:               CMP     R6, R8
        ?!C     JMP     :+
                ADD     R2, R12, @TEXT_B+4*LFNAT[R5]
                CALL    ld16
                TST     R1
        ?Z      MOVE    R8, R6
        ?Z      JMP     :+
                SUB     R2, R1, 0x20
                CMP     R2, 0x5F
        ?!C     MOVE    R1, 0x3F
        ?!C     CLR     @V_LASCII
                CMP     R6, 255
        ?C      MOVE    @LNAME[R6], R1
                MOVE    R6++, R6
                MOVE    R5++, R5
                CMP     R5, 13
        ?!Z     JMP     :-
:               POP     R12
                SUB     R9, R9, 1
                JMP     entry_next
entry_83
                AND[M]  R0, R2, 0x08
        ?!Z     JMP     entry_skip      ; a label
                CMP     R1, 0x2E
        ?Z      JMP     entry_skip      ; . or ..
                TST     R9
        ?!Z     JMP     :+
                SHL     R2, R10, 2
                CALL    sum
                CMP     R6, R11
        ?!Z     JMP     :+
                SUB     R1, R8, 1
                CMP     R1, 255
        ?!C     JMP     :+
                CLR     @LNAME[R8]
                JMP     :++
:               CALL    short_name
:               MOVE    @F_LFN[R12], R7
                NOT[M]  R0, R0          ; Z clear
                RET
entry_skip
                NOT     R7, R0
                NOT     R9, R0
                JMP     entry_next
entry_end
                ONE     @F_DONE[R12]
                TST     R0              ; Z
                RET

; find: the entry of the folder from the cluster R1 whose 8.3 name is
; V_N, unless V_N is 0, or, when V_BYLONG is not 0, whose long name is
; WANT's in either case, at R10 in DIRF's buffer: Z clear; or Z when there
; is none. R12 = DIRF. Uses R1-R12.
find
                MOVE    R12, DIRF
                CALL    startd
find_next
                CALL    entry
        ?Z      RET
                MOVE    R1, @R10
                AND     R2, R1, 0xFF
                CMP     R2, 0x05
        ?Z      XOR     R1, R1, 0xE0    ; 0x05 for 0xE5
                CMP     R1, @V_N
        ?Z      CMP     @1[R10], @V_N+1
        ?Z      AND     R1, @2[R10], 0xFFFFFF
        ?Z      CMP     R1, @V_N+2
        ?Z      JMP     find_yes
                TST     @V_BYLONG
        ?!Z     TST     @V_LASCII
        ?Z      JMP     find_next
; same: LNAME and WANT the same name, but that a letter matches either case
                MOVE    R3, LNAME
                MOVE    R4, WANT
:               CALL    ucmp
        ?!Z     JMP     find_next
                TST     R1
        ?!Z     JMP     :-
find_yes
                NOT[M]  R0, R0          ; Z clear
                RET

; lookup: the entry of the name in WANT, as find gives it: by its 8.3
; name, when WANT is one, and by its long name. Uses R1-R12.
lookup
                CALL    name83
        ?C      CLR     @V_N
                ONE     @V_BYLONG
                MOVE    R1, @V_DIR
                JMP     find

; busy: fails 31 when a file is open whose entry is the entry R10 of
; DIRF's sector, and is open to write, or of any kind when R5 is 1. Uses
; R1-R4.
busy
                SUB     R2, R10, DIRF+F_BUF
                MOVE    R3, FILE0
:               SUB     R4, @F_KIND[R3], K_READ
                CMP     R4, 2
        ?!C     JMP     :+              ; closed, or a folder
                CMP     @F_ELBA[R3], @DIRF+F_LBA
        ?Z      CMP     @F_EOFF[R3], R2
        ?!Z     JMP     :+
                OR[M]   R0, R4, R5      ; written, or any
        ?!Z     MOVE    R1, -31
        ?!Z     JMP     fat_fail
:               ADD     R3, R3, F_WORDS
                CMP     R3, FILE0+2*F_WORDS
        ?!Z     JMP     :--
                RET

; fs_open: R1 the name, R2 the mode. The handle's lack, E_TOOMANY, is
; given after the errors of the name and the file, and before the entry
; is changed, so that a full table leaves the file as it was; the handle
; is on the stack, or -23.
open_b
                CMP     R2, 3
        ?!C     MOVE    R1, -25
        ?!C     JMP     fat_fail
                PUSH    R1
                PUSH    R2
                CALL    mounted
                POP     R8              ; the mode
                POP     R9              ; the name
                CLR     R1
                TST     @FILE0+F_KIND
        ?!Z     ONE     R1
        ?!Z     TST     @FILE1+F_KIND
        ?!Z     MOVE    R1, -23
                PUSH    R1              ; the handle
                CMP     R8, 2
        ?!Z     JMP     :+
; The folder, the only directory: an empty name, or /
                MOVE[M] R1, @R9
        ?Z      JMP     open_dir
                CMP     R1, 0x2F
        ?Z      TST     @1[R9]
        ?!Z     JMP     fail20
open_dir
                MOVE[M] R1, @SP
        ?N      JMP     fat_fail
                CALL    fileh
                CALL    sdir
                MOVE    R1, @SP
                JMP     fat_fail        ; the handle
:               MOVE    R1, R9
                CALL    getname
                TST     R8
        ?!Z     JMP     open_write
                CALL    lookup
        ?Z      MOVE    R1, -21
        ?Z      JMP     fat_fail
                CALL    isdir
                CLR     R5
                CALL    busy
                CALL    cluster
                MOVE    R7, R1          ; the first cluster
                MOVE[M] R6, @7[R10]     ; the size
        ?Z      JMP     :+
                CALL    clok
        ?!C     JMP     fail26
:               MOVE    R8, K_READ
open_file
                MOVE[M] R1, @SP
        ?N      JMP     fat_fail
                CALL    fileh
                MOVE    R1, R7
                MOVE    R2, R8
                MOVE    R3, R6
                CALL    start
                MOVE    @F_ELBA[R12], @DIRF+F_LBA
                SUB     @F_EOFF[R12], R10, DIRF+F_BUF
                MOVE    R1, @SP
                JMP     fat_fail        ; the handle
open_write
                CALL    lookup
        ?Z      JMP     open_new
                CALL    writable
                MOVE[M] R1, @SP
        ?N      JMP     fat_fail
; Truncated: the entry emptied, then its clusters freed
                CALL    cluster
                MOVE    R7, R1
                AND     @5[R10], @5[R10], 0xFFFF0000
                AND     @6[R10], @6[R10], 0xFFFF
                CLR     @7[R10]
                CALL    wrd
                MOVE    R1, R7
                CALL    release
                JMP     :+
open_new
                CALL    newname
                MOVE[M] R1, @SP
        ?N      JMP     fat_fail
                CALL    make
:               CALL    infodone
                CLR     R7
                CLR     R6
                MOVE    R8, K_WRITE
                JMP     open_file

; writable: fails 22 for a directory, 32 for a read-only file, and 31 for
; a file that is open, the entry R10. Uses R1-R5.
writable
                CALL    isdir
                AND[M]  R0, R1, 0x01
        ?!Z     MOVE    R1, -32
        ?!Z     JMP     fat_fail
                ONE     R5
                JMP     busy

; wr: the 128 words at R2 to the sector R1, which fails with the
; controller's error; but no sector outside the partition, nor below its
; first FAT but FSInfo, so never the MBR or the boot sector: those fail
; 26. Uses R1-R4.
wr
                CMP     R1, @V_END
        ?!C     JMP     fail26
                CMP     R1, @V_FAT
        ?!C     JMP     :+
                CMP     R1, @V_FSINFO
        ?!Z     JMP     fail26
                TST     R1
        ?Z      JMP     fail26
:               CALL    sd_write
                JMP     chk

; mark: the entry R10 free, 0xE5 in its byte 0, and then wrd: DIRF's
; sector written. Use R1-R4.
mark
                OR      @R10, @R10, 0xFF
                XOR     @R10, @R10, 0x1A
wrd
                MOVE    R1, @DIRF+F_LBA
                MOVE    R2, DIRF+F_BUF
                JMP     wr

; info: FSInfo with the free count unknown and the next-free hint V_HINT,
; which it gives when V_HINT is 0. A sector without FSInfo's signatures is
; left alone. infodone: info after a change of the FAT. Use R1-R4.
infodone
                TST     @V_CHANGED
        ?Z      RET
info
                MOVE[M] R1, @V_FSINFO
        ?Z      RET
                MOVE    R2, SEC
                CALL    rd
                CMP     @SEC, 0x41615252
        ?Z      CMP     @SEC+121, 0x61417272
        ?Z      CMP     @SEC+127, 0xAA550000
        ?!Z     RET
                TST     @V_HINT
        ?Z      MOVE    @V_HINT, @SEC+123
                NOT     @SEC+122, R0
                MOVE    @SEC+123, @V_HINT
                MOVE    R1, @V_FSINFO
                MOVE    R2, SEC
                CALL    wr
                ONE     @V_UNKNOWN
                CLR     @V_CHANGED
                RET

; set: the FAT's entry of the cluster R1 set to R2, in every copy of the
; FAT, after FSInfo's free count is unknown; its top 4 bits are kept.
; V_FATLBA is ~0 while the copies are written, as the card may not hold
; what FATBUF does after an error. Uses R1-R6.
set
                PUSH    R2
                PUSH    R1
                TST     @V_UNKNOWN
        ?Z      CALL    info
                POP     R1
                CALL    fatsec
                AND     R3, @R1, 0xF0000000
                OR      @R1, R3, @SP++
                ONE     @V_CHANGED
                MOVE    R5, @V_FATLBA
                PUSH    R5
                NOT     @V_FATLBA, R0
                MOVE    R6, @V_NFATS
:               MOVE    R1, R5
                MOVE    R2, FATBUF
                CALL    wr
                ADD     R5, R5, @V_FATSZ
                SUB[M]  R6, R6, 1
        ?!Z     JMP     :-
                POP     @V_FATLBA
                RET

; search: R1 = a free cluster, searched from the hint up to the last and
; then from 2, a sector of the FAT at a time, but not taken: C clear; or C
; when there is none. R5 is the cluster, and R6 the clusters left. Uses
; R1-R6.
search
                TST     @V_HINT
        ?Z      CALL    info            ; for its hint
                MOVE    R1, @V_HINT
                CALL    clok
                MOVE    R5, R1
        ?!C     MOVE    R5, 2
                SUB     R6, @V_TOP, 2
search_sec
                CMP     R6, 1
        ?C      RET                     ; none
                MOVE    R1, R5
                CALL    fatsec
                OR      R2, R5, 127
                ADD     R2, R2, 1       ; the end of the sector,
                CMP     @V_TOP, R2
        ?C      MOVE    R2, @V_TOP      ; or of the volume,
                SUB     R3, R2, R5
                CMP     R6, R3
        ?C      ADD     R2, R5, R6      ; or of the clusters left
                SUB     R6, R6, R2
                ADD     R6, R6, R5
:               AND[M]  R0, @R1++, 0x0FFFFFFF
        ?Z      JMP     :+
                MOVE    R5++, R5
                CMP     R5, R2
        ?!Z     JMP     :-
                CMP     R5, @V_TOP
        ?Z      MOVE    R5, 2
                JMP     search_sec
:               MOVE    R1, R5          ; C clear
                RET

; take: the free cluster R2 taken as the end of a chain, and linked after
; R1, unless R1 is 0. Uses R1-R6.
take
                PUSH    R2
                PUSH    R1
                MOVE    R1, R2
                MOVE    R2, FAT_EOC
                CALL    set
                POP     R1
                MOVE    R2, @SP
                TST     R1
        ?!Z     CALL    set
                POP     R1
                ADD     R1, R1, 1
                CMP     R1, @V_TOP
        ?!C     MOVE    R1, 2
                MOVE    @V_HINT, R1
                RET

; release: the chain from the cluster R1 freed, up to its end, or a
; cluster outside the volume; a free one, as a chain with a loop in it
; comes back to one, fails 26. The hint goes back to the first freed
; below it. Uses R1-R6.
release
                CALL    clok
        ?!C     RET
                PUSH    R1
                CALL    next
                TST     R1
        ?Z      JMP     fail26
                MOVE    R2, @SP
                MOVE    @SP, R1
                PUSH    R2
                MOVE    R1, R2
                CLR     R2
                CALL    set
                POP     R1
                CMP     R1, @V_HINT
        ?C      MOVE    @V_HINT, R1
                POP     R1
                JMP     release

; longok: fails 20 unless WANT is a name that a new file may have: a long
; name of characters that isbad lets through, which does not end in a
; blank or a dot, as Windows drops those. Uses R1-R6.
longok
                MOVE    R5, WANT
                MOVE    R6, @V_WLEN
:               MOVE    R1, @R5++
                CALL    isbad
        ?C      JMP     fail20
                SUB[M]  R6, R6, 1
        ?!Z     JMP     :-
                CMP     R1, 0x20
        ?!Z     CMP     R1, 0x2E
        ?Z      JMP     fail20
                RET

; basis: the basis of WANT's 8.3 alias in V_N, as Windows makes it, in
; upper case: the base from the characters before the last dot, and the
; extension from those after it, without blanks and dots, and with _ for
; +,;=[]: Z clear when that lost a character, or cut a part, so that the
; alias needs a tail; or Z. A name whose dots are all at its start has no
; extension. R5 is the character's index, R6 the length, R7 the dot's
; index, R8 1 after a character other than a blank or a dot, R9 the
; part's end, and R10 1 when something was lost. Uses R1-R10.
basis
                MOVE    R6, @V_WLEN
                MOVE    R7, R6
                CLR     R8
                CLR     R5
:               MOVE    R1, @WANT[R5]
                CMP     R1, 0x2E
        ?!Z     JMP     :+
                MOVE    R7, R6
                TST     R8
        ?!Z     MOVE    R7, R5
:               CMP     R1, 0x20
        ?!Z     CMP     R1, 0x2E
        ?!Z     ONE     R8
                MOVE    R5++, R5
                CMP     R5, R6
        ?!Z     JMP     :--
                CALL    blankn
                MOVE    R2, 4*V_N
                MOVE    R9, 4*V_N+8
                CLR     R10
                CLR     R5
basis_char
                CMP     R5, R7
        ?!Z     JMP     :+
                MOVE    R2, 4*V_N+8
                MOVE    R9, 4*V_N+11
                JMP     basis_next
:               MOVE    R1, @WANT[R5]
                SUB     R3, R1, 0x61
                CMP     R3, 26
        ?C      SUB     R1, R1, 0x20
                CMP     R1, 0x20
        ?!Z     CMP     R1, 0x2E
        ?!Z     CMP     R2, R9
        ?Z      ONE     R10
        ?Z      JMP     basis_next
                CALL    isu             ; not83, as isbad let it through
        ?C      MOVE    R1, 0x5F
        ?C      ONE     R10
                CALL    stb
basis_next
                MOVE    R5++, R5
                CMP     R5, R6
        ?!Z     JMP     basis_char
                TST     R10
                RET

; newname: the 8.3 name of a new file of the name in WANT in V_N, the
; flags of byte 12 in V_LOWER, and the number of its long-name entries in
; V_NL: WANT itself when it is an 8.3 name in upper case, or in lower case
; in a part, with no long-name entries; or else WANT's basis, with the
; first tail ~1, ~2, and on that no entry of the folder has, when it
; needs one. Fails 20 for a name that a new file may not have. R7 is the
; length of the base, R8 the tail's number, and R9 its digits. Uses
; R1-R12.
newname
                CLR     @V_NL
                CALL    name83
        ?C      JMP     :+
                TST     @V_LOWER
        ?!X     RET
:               CALL    longok
                CLR     @V_LOWER
                ADD     R1, @V_WLEN, 12
                CLR     R2
:               SUB[M]  R1, R1, 13
        ?!C     MOVE    R2++, R2
        ?!C     JMP     :-
                MOVE    @V_NL, R2
                CALL    basis
        ?Z      RET                     ; free, as the lookup found no file of this 8.3 name
                MOVE    R2, 4*V_N
                CLR     R7
:               CALL    ldb
                CMP     R1, 0x20
        ?Z      JMP     :+
                MOVE    R7++, R7
                CMP     R7, 8
        ?!Z     JMP     :-
:               ONE     R8
nn_tail
                MOVE    R1, R8
                CLR     R9
                MOVE    @io.mpu_b, 10
:               MOVE    @io.mpu_a, R1
                PUSH    @io.mpu_udivr
                MOVE    R9++, R9
                MOVE[M] R1, @io.mpu_udivq
        ?!Z     JMP     :-
                SUB     R1, 7, R9
                CMP     R7, R1
        ?C      MOVE    R1, R7
                ADD     R2, R1, 4*V_N
                MOVE    R1, 0x7E
                CALL    stb
:               POP     R1
                ADD     R1, R1, 0x30
                CALL    stb
                SUB[M]  R9, R9, 1
        ?!Z     JMP     :-
:               CMP     R2, 4*V_N+8
        ?Z      JMP     :+
                MOVE    R1, 0x20
                CALL    stb
                JMP     :-
:               PUSH    R7
                PUSH    R8
                CLR     @V_BYLONG
                MOVE    R1, @V_DIR
                CALL    find
                POP     R8
                POP     R7
        ?Z      RET
                MOVE    R8++, R8
                JMP     nn_tail

; st16: the 16 bits of R1 at the byte pointer R2, little-endian, and R2
; moved on. Uses R1, R3, and R4.
st16
                PUSH    R1
                CALL    stb
                POP     R1
                SHR     R1, R1, 8
                JMP     stb

; zero: the 128 words from R1 0. zeron: the R2 words from R1. Use R1 and
; R2.
zero
                MOVE    R2, 128
zeron
                CLR     @R1++
                SUB[M]  R2, R2, 1
        ?!Z     JMP     zeron
                RET

; make: a new entry of the 8.3 name V_N in the folder, empty, with the
; flags V_LOWER in byte 12, and V_NL long-name entries of the name in
; WANT before it, in the first run of V_NL + 1 free entries, which may go
; on into a new cluster of zeros added to the folder. The long-name
; entries are written first, then the 8.3 entry, a sector at a time. It
; is at R10 in DIRF's buffer. R7 is the run's length, R8 its offset, R9
; the entry written, and R11 the checksum. Uses R1-R12.
make
                MOVE    R12, DIRF
                CALL    sdir
                CLR     R7
                CLR     R8
make_run
                CMP     @V_NL, R7
        ?C      JMP     make_write
                CMP     @R12, DIR_MAX
        ?!C     JMP     fail30
                CALL    seek
        ?!C     JMP     :+
; The end of the chain, F_CLUS its last cluster: a new one, its zeros
; written before it is taken and linked
                CALL    search
        ?C      JMP     fail30
                MOVE    R11, R1
                MOVE    R1, SEC
                CALL    zero
                SUB     R9, R11, 2
                SHL     R9, R9, @V_LOG
                ADD     R9, R9, @V_DATA
                SHR     R10, @V_BYTES, 9
make_zero
                MOVE    R1, R9
                MOVE    R2, SEC
                CALL    wr
                MOVE    R9++, R9
                SUB[M]  R10, R10, 1
        ?!Z     JMP     make_zero
                MOVE    R1, @F_CLUS[R12]
                MOVE    R2, R11
                CALL    take
                JMP     make_run
:               CALL    ep
                AND[M]  R1, @R10, 0xFF
        ?!Z     CMP     R1, 0xE5
        ?!Z     CLR     R7              ; used
        ?!Z     JMP     :+
                TST     R7
        ?Z      MOVE    R8, @R12
                MOVE    R7++, R7
:               ADD     @R12, @R12, 32
                JMP     make_run
make_write
                MOVE    R2, 4*V_N
                CALL    sum
                MOVE    R11, R6
                CLR     R9
make_entry
                SHL     R1, R9, 5
                ADD     R1, R1, R8
                CALL    at
                MOVE    R1, R10
                MOVE    R2, 8
                CALL    zeron
                CMP     R9, @V_NL
        ?!C     JMP     make_83
; The long-name entry of the number V_NL - R9, its 13 characters from
; WANT, then a 0 after the name, and 0xFFFF after that
                SUB     R5, @V_NL, R9
                MOVE    R1, R5
                TST     R9
        ?Z      OR      R1, R1, 0x40    ; the first written, the last part
                MOVE    @R10, R1
                MOVE    @2[R10], 0x0F000000
                SHL     @3[R10], R11, 8
                SHL     R6, R5, 4
                SUB     R6, R6, R5
                SUB     R6, R6, R5
                SUB     R6, R6, R5
                SUB     R6, R6, 13
                CLR     R5
:               MOVE    R1, 0xFFFF
                CMP     R6, @V_WLEN
        ?Z      CLR     R1
        ?C      MOVE    R1, @WANT[R6]
                SHL     R2, R10, 2
                ADD     R2, R2, @TEXT_B+4*LFNAT[R5]
                CALL    st16
                MOVE    R6++, R6
                MOVE    R5++, R5
                CMP     R5, 13
        ?!Z     JMP     :-
                JMP     make_wr
make_83
                MOVE    @R10, @V_N
                MOVE    @1[R10], @V_N+1
                OR      @2[R10], @V_N+2, 0x20000000  ; archive
                MOVE    @3[R10], @V_LOWER
                CALL    stampc
make_wr
                SHL     R1, R9, 5
                ADD     R1, R1, R8
                ADD     R1, R1, 32
                AND[M]  R0, R1, 511
        ?!Z     CMP     R9, @V_NL
        ?Z      CALL    wrd             ; at the sector's end, and after the last
                MOVE    R9++, R9
                CMP     @V_NL, R9
        ?!C     JMP     make_entry
                RET

; at: R10 = the entry of the folder at the offset R1, in DIRF's buffer,
; which is read from the start of the folder when R1 is before DIRF's
; cluster. R12 = DIRF. Uses R1-R5.
at
                MOVE    R12, DIRF
                MOVE    R5, R1
                CMP     R1, @F_CPOS[R12]
        ?C      CALL    sdir
                MOVE    @R12, R5
                CALL    seekx
                JMP     ep

; stampc and stamp: the date and the time of the entry R10 written, and
; for stampc, a new entry, created too: from the clock, with clock_fat,
; or FAT_DATE at 00:00:00 while the clock is not set. A read keeps the date
; of the write, as it writes nothing. Use R1-R7.
stampc
                CALL    dtime
                AND     R3, @3[R10], 0xFF  ; byte 12
                SHR     R4, R2, 8
                AND     R4, R4, 0xFF00
                OR      R3, R3, R4      ; byte 13, the hundredths
                SHL     R4, R2, 16
                OR      @3[R10], R3, R4  ; the creation time
                SHL     R4, R1, 16
                OR      @4[R10], R4, R1  ; the dates of the creation and the access
                JMP     :+
stamp
                CALL    dtime
                AND     R3, @4[R10], 0xFFFF
                SHL     R4, R1, 16
                OR      @4[R10], R3, R4  ; the access
:               AND     R3, @5[R10], 0xFFFF
                SHL     R4, R2, 16
                OR      @5[R10], R3, R4  ; the time of the write
                AND     R3, @6[R10], 0xFFFF0000
                OR      @6[R10], R3, R1  ; and its date
                RET
; dtime: R1 = the date, and R2 the time, of clock_fat. Uses R1-R7.
dtime
                CALL    clock_fat
                TST     R1
        ?Z      MOVE    R1, FAT_DATE
        ?Z      CLR     R2
                RET

; getc: R1 = the next byte of the file R12, and C; or C clear at its end.
; The end of the chain before the size fails 26. Uses R1-R4.
getc
                CMP     @R12, @F_SIZE[R12]
        ?!C     RET
                CALL    seekx
                CALL    fbyte
                ADD     @R12, @R12, 1
                CALL    ldb
                CMP     R1, 256         ; C
                RET

; fs_read: R1 the handle, R2 the buffer, R3 the number of bytes. R1 =
; the bytes read, one per word.
read_b
                MOVE    R5, K_READ
                CALL    handle
                MOVE    R8, R2
                MOVE    R9, R3
                CLR     R7
:               CMP     R7, R9
        ?!C     JMP     :+
                CALL    getc
        ?!C     JMP     :+
                MOVE    @R8++, R1
                MOVE    R7++, R7
                JMP     :-
:               MOVE    R1, R7
                RET

; fs_readdir and fs_readname: R1 the handle, R2 the 4 words of the entry,
; R3 the name, which R4 1 asks for. R1 = 1, or 0 at the end.
rdn_b
                PUSH    R4
                PUSH    R3
                PUSH    R2
                MOVE    R5, K_DIR
                CALL    handle
                CALL    entry
        ?Z      CLR     R1
        ?Z      JMP     fat_fail        ; 0
                POP     R2
                MOVE    R1, @R10
                AND     R3, R1, 0xFF
                CMP     R3, 0x05
        ?Z      XOR     R1, R1, 0xE0
                MOVE    @R2, R1
                MOVE    @1[R2], @1[R10]
                MOVE    @2[R2], @2[R10]
                MOVE    @3[R2], @7[R10]
                POP     R3
                POP     R4
                MOVE    R2, LNAME
                TST     R4
        ?Z      JMP     :++
:               MOVE[M] @R3++, @R2++
        ?!Z     JMP     :-
:               ONE     R1
                RET

; fs_close: R1 the handle, closed also after an error. A file open to
; write is finished: its last sector, then its first cluster, its size,
; and the date and the time of the write in its entry, then FSInfo. R1 =
; 0.
close_b
                CMP     R1, 2
        ?!C     JMP     fail24
                CALL    fileh
                MOVE[M] R5, @F_KIND[R12]
        ?Z      JMP     fail24
                CLR     @F_KIND[R12]
                CLR     R1
                CMP     R5, K_WRITE
        ?!Z     RET
                CALL    valid
        ?!Z     JMP     fail28
                MOVE    R1, @F_LBA[R12]
                ADD     R2, R12, F_BUF
                TST     R1
        ?!X     CALL    wr
                MOVE    R1, @F_ELBA[R12]
                MOVE    R2, SEC
                CALL    rd
                ADD     R10, @F_EOFF[R12], SEC
                SHR     R1, @F_FIRST[R12], 16
                AND     R2, @5[R10], 0xFFFF0000
                OR      @5[R10], R2, R1
                SHL     R1, @F_FIRST[R12], 16
                AND     R2, @6[R10], 0xFFFF
                OR      @6[R10], R2, R1
                MOVE    @7[R10], @R12   ; the size: the position
                CALL    stamp
                MOVE    R1, @F_ELBA[R12]
                MOVE    R2, SEC
                CALL    wr
                CALL    infodone
                CLR     R1
                RET

; fs_write: R1 the handle, R2 the words, R3 their number. R1 = the bytes
; written.
write_b
                MOVE    R5, K_WRITE
                CALL    handle
; put: R3 bytes written to the file R12, open to write, from the words at
; R2, bits 7..0 of each. A cluster is taken when the first byte of it is
; written, and a sector written when it is full. R1 = the bytes written;
; a full card fails 30 only when none was. R9 is the source, R10 the
; bytes, R11 those written, R5 the byte's offset in the sector, and R6
; the bytes of this sector. Uses R1-R6 and R9-R11.
put
                MOVE    R9, R2
                MOVE    R10, R3
                CLR     R11
put_sec
                CMP     R11, R10
        ?!C     JMP     put_end
                AND[M]  R5, @R12, 511
        ?!Z     JMP     put_copy
                TST     @F_LBA[R12]
        ?!X     JMP     put_copy
; A new sector, in a new cluster at the start of one
                TST     @F_CLUS[R12]
        ?Z      JMP     :+
                SUB     R1, @R12, @F_CPOS[R12]
                CMP     R1, @V_BYTES
        ?!Z     JMP     put_lba
:               CALL    search
        ?C      JMP     put_full
                PUSH    R1
                MOVE    R2, R1
                MOVE    R1, @F_CLUS[R12]
                CALL    take
                POP     R1
                TST     @F_CLUS[R12]
        ?Z      MOVE    @F_FIRST[R12], R1
        ?!Z     ADD     @F_CPOS[R12], @F_CPOS[R12], @V_BYTES
                MOVE    @F_CLUS[R12], R1
put_lba
                CALL    clba
                MOVE    @F_LBA[R12], R1
                ADD     R1, R12, F_BUF
                CALL    zero
put_copy
                AND     R5, @R12, 511
                CALL    fbyte
                SUB     R6, 512, R5
                SUB     R1, R10, R11
                CMP     R1, R6
        ?C      MOVE    R6, R1
                PUSH    R6
:               MOVE    R1, @R9++
                CALL    stb
                SUB[M]  R6, R6, 1
        ?!Z     JMP     :-
                POP     R6
                ADD     R5, R5, R6
                CMP     R5, 512
        ?!Z     JMP     :+
                MOVE    R1, @F_LBA[R12]
                ADD     R2, R12, F_BUF
                CALL    wr
                NOT     @F_LBA[R12], R0
:               ADD     @R12, @R12, R6
                ADD     R11, R11, R6
                JMP     put_sec
put_full
                TST     R11
        ?Z      JMP     fail30
put_end
                MOVE    R1, R11
                RET

; fs_delete: R1 the name. The file deleted: its long-name entries marked
; free, then its entry, each sector written as it changes, then its
; clusters freed, then FSInfo. R1 = 0. R7 is the offset of a long-name
; entry, R8 the entry's, and R9 its checksum.
delete_b
                PUSH    R1
                CALL    mounted
                POP     R1
                CALL    getname
                CALL    lookup
        ?Z      MOVE    R1, -21
        ?Z      JMP     fat_fail
                CALL    writable
                CALL    cluster
                PUSH    R1              ; the first cluster
                MOVE    R7, @DIRF+F_LFN
                SUB     R8, @DIRF+F_POS, 32
                SHL     R2, R10, 2
                CALL    sum
                MOVE    R9, R6
                TST     R7
        ?X      JMP     delete_e        ; no long name
:               CMP     R7, R8
        ?!C     JMP     delete_e
                MOVE    R1, R7
                CALL    at
                SHR     R1, @2[R10], 24
                CMP     R1, 0x0F
        ?!Z     JMP     :+
                SHR     R1, @3[R10], 8
                AND     R1, R1, 0xFF
                CMP     R1, R9
        ?Z      CALL    mark
:               ADD     R7, R7, 32
                JMP     :--
delete_e
                MOVE    R1, R8
                CALL    at
                CALL    mark
                POP     R1
                CALL    release
                CALL    infodone
                CLR     R1
                RET

; fat_save: R1 the handle of a file open to write, R2 the address, R3 the
; number of words. The words written as lines of ADDR WORD in 8 hex digits
; each, in lower case, ended by LF, as niceasm writes a .bin file, each
; line made in V_T. R1 = 0; fails 30 when the card filled up. R7 is the
; address, and R8 the words left.
save_b
                MOVE    R7, R2
                MOVE    R8, R3
                MOVE    R5, K_WRITE
                CALL    handle
:               TST     R8
        ?Z      CLR     R1
        ?Z      RET
                MOVE    R2, V_T
                MOVE    R1, R7
                CALL    hex8
                MOVE    @R2++, 0x20
                MOVE    R1, @R7
                CALL    hex8
                MOVE    @R2++, 0x0A
                MOVE    R2, V_T
                MOVE    R3, 18
                CALL    put
                CMP     R1, 18
        ?!Z     JMP     fail30
                MOVE    R7++, R7
                SUB     R8, R8, 1
                JMP     :-

; hex8: R1 in 8 hex digits in lower case at R2, one a word, which moves
; on. Uses R1, R3, and R4.
hex8
                MOVE    R4, 8
:               ROL     R1, R1, 4
                AND     R3, R1, 0xF
                ADD     R3, R3, 0x30
                CMP     R3, 0x3A
        ?!C     ADD     R3, R3, 0x27
                MOVE    @R2++, R3
                SUB[M]  R4, R4, 1
        ?!Z     JMP     :-
                RET

; fat_dir: R1 a slot, or one from 2^31 for none. The folder FOLDER of the
; card, for BASIC's DIR: a row with its name, then a row for each file,
; its name, the long name or the 8.3 name, in DIR_NAME columns and its
; size in decimal in 12, and for each directory, its name and <DIR>, then
; the numbers of both. A name of DIR_NAME characters or more has a row of
; its own. With a slot, the card in it is mounted first. R1 = 0. V_T and
; V_T+1 count the files and the directories.
dir_b
                MOVE    R6, mount
                TST     R1
        ?N      MOVE    R6, mounted
                CALL    R6
                MOVE    R12, DIRF
                CALL    sdir
                CLR     @V_T
                CLR     @V_T+1
                MOVE    R1, S_DIROF
                CALL    puts_b_crlf
dir_row
                CALL    entry
        ?Z      JMP     dir_end
                MOVE    R8, LNAME
:               MOVE[M] R1, @R8++
        ?Z      JMP     :+
                CALL    mon_putc
                JMP     :-
:               SUB     R8, R8, LNAME+1
                CMP     R8, DIR_NAME
        ?!C     CLR     R8
        ?!C     CALL    _io_crlf
:               CMP     R8, DIR_NAME
        ?Z      JMP     :+
                MOVE    R1, 0x20
                CALL    mon_putc
                MOVE    R8++, R8
                JMP     :-
:               SHR     R1, @2[R10], 24
                AND[M]  R0, R1, 0x10
        ?Z      JMP     :+
                MOVE    R1, S_DIRTAG
                CALL    puts_b
                ADD     @V_T+1, @V_T+1, 1
                JMP     :++
:               MOVE    R1, @7[R10]
                CALL    decimal
                ADD     @V_T, @V_T, 1
:               CALL    _io_crlf
                JMP     dir_row
dir_end
                MOVE    R1, S_FILES
                CALL    puts_b
                MOVE    R1, @V_T
                CALL    _io_putdec
                MOVE    R1, S_DIRS
                CALL    puts_b
                MOVE    R1, @V_T+1
                CALL    _io_putdec
                CALL    _io_crlf
                CLR     R1
                RET

; decimal: R1 in decimal, unsigned, right-aligned in 12 columns. Uses R1-R6.
decimal
                MOVE    R5, R1
                MOVE    R6, 12
                MOVE    @io.mpu_b, 10
:               MOVE    @io.mpu_a, R1
                SUB     R6, R6, 1
                MOVE[M] R1, @io.mpu_udivq
        ?!Z     JMP     :-
:               TST     R6
        ?Z      JMP     :+
                MOVE    R1, 0x20
                CALL    mon_putc
                SUB     R6, R6, 1
                JMP     :-
:               MOVE    R1, R5
                JMP     _io_putdec

; fat_complete: R1 the line, R2 the cursor, R3 the end (its header
; above). The word before the cursor, from the last blank outside quotes,
; and after an opening quote, is the start of a name. Unless it is the
; first word, the statement, the files of the folder whose names start
; with it, in either case, are its matches: directories, and names with a
; ? for a character outside ASCII, are left out. With one match, the rest
; of its name goes onto the line, then the closing quote, and a blank;
; with several, the rest of the start that they share. The start typed
; takes the case of the first match, and a start that is not in quotes
; gets an opening quote before it, as BASIC takes a name as a string, so
; that the word is typed again after BS. The new cursor, or 0 when
; several matches add nothing: then they are listed, a name to a row, and
; the line is shown again. The start that the matches share is the first
; match's characters in SEC, one a word. V_T is the cursor, then the end,
; p, the start's address, its length, q, 1 after an opening quote, the
; matches, the length of their shared start, and 1 for the list.
comp_b
                MOVE    @V_T, R2
                MOVE    @V_T+1, R3
                MOVE    R4, R1          ; w
                CLR     R5              ; q
                CLR     R6              ; cmd
                MOVE    R7, R1          ; k
:               CMP     R7, R2
        ?!C     JMP     :++
                MOVE    R1, @R7
                CMP     R1, 0x22
        ?Z      XOR     R5, R5, 1
                CMP     R1, 0x20
        ?Z      TST     R5
        ?!Z     JMP     :+
                CMP     R4, R7
        ?C      ONE     R6              ; a word before the blank
                ADD     R4, R7, 1
:               MOVE    R7++, R7
                JMP     :--
:               ADD     R4, R4, R5      ; p
                MOVE    @V_T+2, R4
                SUB     R3, R2, R4
                MOVE    @V_T+3, R3      ; plen
                MOVE    @V_T+4, R5
                TST     R6
        ?Z      JMP     comp_cur
                CMP     R3, 256
        ?!C     JMP     comp_cur
                CALL    mounted
                MOVE    R1, @V_T+2
                MOVE    R2, WANT
                MOVE    R3, @V_T+3
:               TST     R3
        ?Z      JMP     :+
                MOVE    R4, @R1++
                CMP     R4, 0x100
        ?!C     JMP     comp_cur
                MOVE    @R2++, R4
                SUB     R3, R3, 1
                JMP     :-
:               CLR     @V_T+5
                CLR     @V_T+6
                CLR     @V_T+7
comp_pass
                MOVE    R12, DIRF
                CALL    sdir
comp_entry
                CALL    entry
        ?Z      JMP     comp_end
                SHR     R1, @2[R10], 24
                AND[M]  R0, R1, 0x10
        ?!Z     JMP     comp_entry      ; a directory
                TST     @V_LASCII
        ?Z      JMP     comp_entry
                MOVE    R3, LNAME
                MOVE    R4, WANT
                MOVE    R6, @V_T+3
:               TST     R6
        ?Z      JMP     :+
                CALL    ucmp
        ?!Z     JMP     comp_entry
                SUB     R6, R6, 1
                JMP     :-
:               TST     @V_T+7
        ?Z      JMP     :+
                MOVE    R1, LNAME
                CALL    puts_crlf
                JMP     comp_entry
:               TST     @V_T+5
        ?!Z     JMP     :++
                MOVE    R1, LNAME       ; the first match
                MOVE    R2, SEC
:               MOVE[M] @R2++, @R1++
        ?!Z     JMP     :-
                SUB     @V_T+6, R2, SEC+1
                JMP     comp_more
:               MOVE    R6, @V_T+3      ; k from plen, while the start is shared
                ADD     R3, R6, LNAME
                ADD     R4, R6, SEC
:               CMP     R6, @V_T+6
        ?!C     JMP     :+
                CALL    ucmp
        ?!Z     JMP     :+
                MOVE    R6++, R6
                JMP     :-
:               MOVE    @V_T+6, R6
comp_more
                ADD     @V_T+5, @V_T+5, 1
                JMP     comp_entry
comp_end
                TST     @V_T+5
        ?Z      JMP     comp_cur        ; no match
                TST     @V_T+7
        ?!Z     CLR     R1
        ?!Z     RET                     ; listed
                CMP     @V_T+5, 2
        ?C      JMP     :+              ; one match
                CMP     @V_T+6, @V_T+3
        ?!Z     JMP     :+
                CALL    _io_crlf
                ONE     @V_T+7
                JMP     comp_pass
; The new word, from the start typed, or from the cursor, R7: an opening
; quote when it has none, R5, the start in the case of the first match,
; the rest, and after one match a closing quote and a blank. What is
; typed again is first rubbed out with BS.
:               XOR     R5, @V_T+4, 1
                MOVE    R7, @V_T
                TST     R5
        ?!Z     MOVE    R7, @V_T+2
                MOVE    R6, @V_T+3
                MOVE    R3, SEC
                MOVE    R4, WANT
:               TST     R6
        ?Z      JMP     :+
                CMP     @R3++, @R4++
        ?!Z     MOVE    R7, @V_T+2
                SUB     R6, R6, 1
                JMP     :-
:               ADD     R1, @V_T, R5
                ADD     R1, R1, @V_T+6
                SUB     R1, R1, @V_T+3
                CMP     @V_T+5, 1
        ?Z      ADD     R1, R1, 2
                CMP     @V_T+1, R1
        ?C      JMP     comp_cur        ; no room
                MOVE    R6, R7
:               CMP     R6, @V_T
        ?!C     JMP     :+
                MOVE    R1, 8
                CALL    mon_putc
                MOVE    R6++, R6
                JMP     :-
:               SUB     R6, R7, @V_T+2  ; i
                MOVE    R1, 0x22
                TST     R5
        ?!Z     CALL    type
:               CMP     R6, @V_T+6
        ?!C     JMP     :+
                MOVE    R1, @SEC[R6]
                CALL    type
                MOVE    R6++, R6
                JMP     :-
:               CMP     @V_T+5, 1
        ?!Z     JMP     :+
                MOVE    R1, 0x22
                CALL    type
                MOVE    R1, 0x20
                CALL    type
:               MOVE    R1, R7
                RET
comp_cur
                MOVE    R1, @V_T
                RET
; type: R1 at R7, which moves on, and on the monitor's outputs
type
                MOVE    @R7++, R1
                JMP     mon_putc

; fat_load: R1 the handle of a file open to read, R2 the end of the RAM
; that it may write, and R3 the 5 words of its summary. The lines of the
; file, ADDR WORD in hex, written as LOAD with no name writes them, but
; that an empty line is passed over and the end of the file ends the
; load. A line is skipped when it has no address or word of 1 to 8
; digits, has more after the word than blanks, has a byte that is not
; printable ASCII, has more than blanks after its LINE_MAX characters, or
; its address is below 0x8000 or not below the end. TAB is a blank, and
; CR, LF, or CR LF ends a line. A byte that is no character, any other
; control code, DEL, or one from 0x80, is kept as 0x7F, which no line
; parses; so is the first character after LINE_MAX that is no blank, at
; SEC[LINE_MAX], and the blanks after LINE_MAX are dropped, as niceemu
; ignores them. The 5 words get the words written, the lowest
; and the highest address, the lines skipped, and the number of the
; first, counted from 1, only at the end; V_T has them until then. R1 =
; 0. The line is in SEC, one character a word, R10 long; R7 is the end,
; R8 the summary, R9 the number of the line, and R11 the last byte.
load_b
                MOVE    R7, R2
                MOVE    R8, R3
                MOVE    R5, K_READ
                CALL    handle
                MOVE    R1, V_T
                CLR     @R1++
                NOT     @R1++, R0
                CLR     @R1++
                CLR     @R1++
                CLR     @R1++
                CLR     R9
                CLR     R10
                CLR     R11
fload_byte
                CALL    getc
        ?!C     MOVE    R1, 256         ; the end
                CMP     R1, 0x0A
        ?Z      CMP     R11, 0x0D
        ?Z      CLR     R11
        ?Z      JMP     fload_byte      ; the LF of a CR LF
                MOVE    R11, R1
                CMP     R1, 0x0D
        ?!Z     CMP     R1, 0x0A
        ?!Z     CMP     R1, 256
        ?Z      JMP     :+
                CMP     R1, 0x09
        ?Z      MOVE    R1, 0x20
                SUB     R2, R1, 0x20
                CMP     R2, 0x5F
        ?!C     MOVE    R1, 0x7F        ; no character: the line skipped
                CMP     R10, LINE_MAX
        ?C      JMP     fload_put       ; room
                CMP     R1, 0x20
        ?Z      JMP     fload_byte      ; a blank after LINE_MAX, dropped
                MOVE    R10, LINE_MAX
                MOVE    R1, 0x7F        ; more after LINE_MAX: skipped
fload_put
                MOVE    @SEC[R10], R1
                MOVE    R10++, R10
                JMP     fload_byte
:               TST     R10
        ?Z      CMP     R1, 256
        ?Z      JMP     fload_end
                PUSH    R1
                MOVE    R9++, R9
                CLR     @SEC[R10]
                MOVE    R2, SEC
:               CMP     @R2, 0x20
        ?Z      MOVE    R2++, R2
        ?Z      JMP     :-
                TST     @R2
        ?Z      JMP     fload_next      ; blanks only
                MOVE    R1, SEC
                CALL    _io_gethex
                SUB     R2, R2, 1
                CMP     R2, 8
        ?!C     JMP     fload_bad
                PUSH    R1              ; the address
                MOVE    R1, R3
                CALL    _io_gethex
                POP     R6
                SUB     R2, R2, 1
                CMP     R2, 8
        ?!C     JMP     fload_bad
:               CMP     @R3, 0x20
        ?Z      MOVE    R3++, R3
        ?Z      JMP     :-
                TST     @R3
        ?!Z     JMP     fload_bad
                CMP     R6, PROGRAM
        ?C      JMP     fload_bad
                CMP     R6, R7
        ?!C     JMP     fload_bad
                MOVE    @R6, R1
                ADD     @V_T, @V_T, 1
                CMP     R6, @V_T+1
        ?C      MOVE    @V_T+1, R6
                CMP     @V_T+2, R6
        ?C      MOVE    @V_T+2, R6
                JMP     fload_next
fload_bad
                TST     @V_T+3
        ?Z      MOVE    @V_T+4, R9
                ADD     @V_T+3, @V_T+3, 1
fload_next
                CLR     R10
                POP     R1
                CMP     R1, 256
        ?!Z     JMP     fload_byte
fload_end
                MOVE    R1, V_T
                MOVE    R2, 5
:               MOVE    @R8++, @R1++
                SUB[M]  R2, R2, 1
        ?!Z     JMP     :-
                CLR     R1
                RET

S_DIRTAG
                .ASCII_B '       <DIR>'
                .DAT    0
S_FILES         .ASCII_B 'Files: '
S_DIRS          .ASCII_B ', directories: '
