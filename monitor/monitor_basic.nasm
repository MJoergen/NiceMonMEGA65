; The loader of BASIC's image from a card, which the Makefile joins after
; monitor_clock.nasm (issue #153, doc/BASIC_ROM.md, "The cold start").
; mon_reset calls bas_load at its end, before the lock and the jump to
; BASIC's cold start.
;
; BASIC's half of the ROM, BASIC_BASE to PROGRAM - 1, takes the core's
; writes from the FPGA's configuration until the core writes to the
; monitor's half, which mon_reset does right before BAS_COLD (src/mem.vhd).
; So the first cold start after a configuration may put another BASIC
; there: a file of the card's folder whose name matches BASIC*.ROM, in
; either case, such as BASIC-V2.3.2.ROM, a .bin file whose addresses are
; in BASIC's half and rise from line to line, with the header of
; common.nasm's BAS_H_ words.
;
; bas_load does nothing when the ROM is locked, which it finds out by
; writing the complement of BASIC's last word and reading it back, nor
; when the BASIC in the ROM has the flag "keep", as an image that a tool
; loaded into the RAM has, where the ROM is RAM.
;
; Nor does it load over a program. It stages a file in the program's RAM
; from PROGRAM, the staging area, as many words as BASIC's half, which is
; all zeros after a configuration. When it is not, a host has loaded a
; program there while the ROM was still open, and the BASIC in the ROM
; runs it, when that BASIC is whole, with its header and its checksum
; right (bl_whole); the cards' BASIC then waits for the next
; configuration. A load of its own that a reset broke off is not a
; program: BL_BUSY is not 0 from before the first write to the staging
; area until that area is zeroed for the last time, and the monitor's RAM
; keeps it over a reset, which a host's clear does not, so that load
; starts again, with the staging area zeroed.
;
; Else it lists the folder of slot 0, then of slot 1, and reads the first
; BAS_H_WORDS lines of each BASIC*.ROM, its header, which bl_check
; checks: a file whose header does not fit is passed over, with its
; reason on a line of its own. Of the others it takes the one with the
; highest version, and of two with the same version the first, slot 0
; before slot 1, and in a folder the one that comes first. It reads that
; file into the staging area, BASIC_BASE words higher than each line's
; address, and checks it there: its lines, its header, and its checksum.
; Only a file that passes is copied into the ROM, over its length, and
; the rest of BASIC's half zeroed; else its reason is shown, and the next
; one is taken, the one with the highest version below it. The staging
; area is zeroed before each file and after the last, as the RAM is at
; the configuration, the only cold start that loads.
;
; The order is by a key, the version and the ordinal of the file, its
; slot in bits 31..16 and its number in the folder in 15..0: a key is
; higher than another with a higher version, or with the same version
; and a lower ordinal. Each choice lists the folders again, and takes the
; highest key below that of the file that failed, BL_LV and BL_LO, so
; that no list of the files is kept. The reasons of the headers are
; shown on the first listing only.
;
; The registers R7 to R12 are saved by bas_load, and used inside: R7 to
; R9 by bl_choose and bl_header, R8 by bl_stage, and R10 and R11 by
; bl_getline.

; The loader's RAM, in the monitor's, which nothing else uses
BL_LINE         .EQU    0xFFFFF400      ; a line of the file, one character a word, BL_LMAX and a 0 word
BL_BUF          .EQU    0xFFFFF460      ; the bytes of fs_read, one a word, BL_BUFN words
BL_ENT          .EQU    0xFFFFF4E0      ; an entry of fs_readname, 4 words
BL_HDR          .EQU    0xFFFFF4E4      ; the header of a file, BAS_H_WORDS words
BL_NAME         .EQU    0xFFFFF500      ; the name of an entry, 256 words
BL_BEST         .EQU    0xFFFFF600      ; and of the file chosen, 256 words
BL_H            .EQU    0xFFFFF700      ; the handle of the file read,
BL_N            .EQU    0xFFFFF701      ; the bytes of BL_BUF left,
BL_P            .EQU    0xFFFFF702      ; and the next of them
BL_DIR          .EQU    0xFFFFF703      ; the handle of the folder
BL_SLOT         .EQU    0xFFFFF704      ; the slot listed
BL_ORD          .EQU    0xFFFFF705      ; the ordinal of the entry
BL_TRIED        .EQU    0xFFFFF706      ; not 0 once a file failed, whose key is
BL_LV           .EQU    0xFFFFF707      ; its version
BL_LO           .EQU    0xFFFFF708      ; and its ordinal
BL_FOUND        .EQU    0xFFFFF709      ; not 0 when a file was chosen, whose key is
BL_BV           .EQU    0xFFFFF70A      ; its version
BL_BO           .EQU    0xFFFFF70B      ; and its ordinal,
BL_BSLOT        .EQU    0xFFFFF70C      ; in the slot BL_BSLOT
BL_BUSY         .EQU    0xFFFFF70D      ; not 0 while the staging area or the ROM has part of a load
BL_LMAX         .EQU    76              ; the characters of a line, as LOAD's
BL_BUFN         .EQU    128             ; the bytes of a read
BL_STAGE        .EQU    PROGRAM-BASIC_BASE  ; a word's offset in the staging area
BAS_LAST        .EQU    PROGRAM-1       ; the last word of BASIC's half

; The reasons of a file that is not taken
BL_E_IMAGE      .EQU    1               ; no header: no magic word, or its lines out of place
BL_E_IFACE      .EQU    2               ; for another monitor
BL_E_HEADER     .EQU    3               ; the length, the text, or the RAM out of range
BL_E_ADDR       .EQU    4               ; an address out of BASIC's half, or not above the one before
BL_E_LINE       .EQU    5               ; a line that is not ADDR WORD
BL_E_SUM        .EQU    6               ; the checksum
BL_E_READ       .EQU    7               ; an error of the card

; bas_load: BASIC from a card, as the header says. Uses R1-R6, and R7 to
; R12 across the calls, saved.
bas_load
                PUSH    R7
                PUSH    R8
                PUSH    R9
                PUSH    R10
                PUSH    R11
                PUSH    R12
; Is the ROM still open? A write that sticks says so.
                MOVE    R1, @BAS_LAST
                NOT     R2, R1
                MOVE    @BAS_LAST, R2
                MOVE    R3, @BAS_LAST
                MOVE    @BAS_LAST, R1
                CMP     R3, R2
        ?!Z     JMP     bl_end          ; locked
; Is the BASIC in the ROM to be kept?
                CMP     @BAS_H_MAGIC, BAS_MAGIC
        ?!Z     JMP     :+
                AND[M]  R0, @BAS_H_FLAGS, BAS_KEEP
        ?!Z     JMP     bl_end
:
; A load that a reset broke off starts again, over what it left
                TST     @BL_BUSY
        ?Z      JMP     :+
                CALL    bl_zero
                JMP     bl_load
; Has a host loaded a program? It stays, with a whole BASIC in the ROM
:
                CALL    bl_empty
        ?Z      JMP     bl_load
                CLR     R1
                CALL    bl_whole
                TST     R1
        ?Z      JMP     bl_end
bl_load
                CLR     @BL_TRIED
bl_next
                CALL    bl_choose
                TST     @BL_FOUND
        ?Z      JMP     bl_done         ; none: the bitstream's BASIC
                MOVE    @BL_BUSY, 1
                CALL    bl_stage
                TST     R1
        ?Z      JMP     bl_ok
                MOVE    R7, R1          ; the reason
                MOVE    R1, S_BL_ON
                MOVE    R2, BL_BEST
                MOVE    R3, @BL_BSLOT
                CALL    bl_say
                MOVE    R1, R7
                CALL    bl_reason
                CALL    bl_zero
                MOVE    @BL_TRIED, 1
                MOVE    @BL_LV, @BL_BV
                MOVE    @BL_LO, @BL_BO
                JMP     bl_next
; The file passed: its line, with the notice when its version is below
; that of the BASIC in the ROM, whose text goes with the copy, then the
; copy, and the rest of BASIC's half zeroed
bl_ok
                MOVE    R1, S_BL_FROM
                MOVE    R2, BL_BEST
                MOVE    R3, @BL_BSLOT
                CALL    bl_say
                CMP     @BAS_H_MAGIC, BAS_MAGIC
        ?!Z     JMP     :+
                CMP     @BL_BV, @BAS_H_VERSION
        ?!C     JMP     :+              ; not below it
                MOVE    R1, S_BL_OLDER
                CALL    puts_b
                MOVE    R1, @BAS_H_TEXT
                CALL    puts_b
:
                CALL    _io_crlf
                MOVE    R2, @BL_STAGE+BAS_H_LENGTH
                MOVE    R3, BL_STAGE+BASIC_BASE
                MOVE    R4, BASIC_BASE
:
                MOVE    @R4++, @R3++
                SUB[M]  R2, R2, 1
        ?!Z     JMP     :-
:
                CMP     R4, PROGRAM
        ?Z      JMP     :+
                CLR     @R4++
                JMP     :-
:
                CALL    bl_zero
bl_done
                CLR     @BL_BUSY        ; the staging area is all zeros
                CALL    fat_reset       ; no mount, and no file open
bl_end
                POP     R12
                POP     R11
                POP     R10
                POP     R9
                POP     R8
                POP     R7
                RET

; bl_choose: the file with the highest key below BL_LV and BL_LO, or the
; highest when BL_TRIED is 0: BL_FOUND not 0, its name in BL_BEST, its
; slot in BL_BSLOT, and its key in BL_BV and BL_BO. Uses R1-R9.
bl_choose
                CLR     @BL_FOUND
                CLR     @BL_SLOT
ch_slot
                MOVE    R1, @BL_SLOT
                CALL    fs_mount
                TST     R1
        ?N      JMP     ch_next_slot    ; no card, or no folder
                MOVE    R1, BL_ZERO     ; the folder
                MOVE    R2, 2
                CALL    fs_open
                TST     R1
        ?N      JMP     ch_next_slot
                MOVE    @BL_DIR, R1
                SHL     @BL_ORD, @BL_SLOT, 16
ch_entry
                MOVE    R1, @BL_DIR
                MOVE    R2, BL_ENT
                MOVE    R3, BL_NAME
                CALL    fs_readname
                CMP     R1, 1
        ?!Z     JMP     ch_close        ; the end, or an error
                ADD     @BL_ORD, @BL_ORD, 1
                AND[M]  R0, @BL_ENT+2, 0x18000000
        ?!Z     JMP     ch_entry        ; a folder, or a volume's label
                CALL    bl_match
        ?!Z     JMP     ch_entry
                CALL    bl_header
                TST     R1
        ?Z      JMP     ch_key
                TST     @BL_TRIED
        ?!Z     JMP     ch_entry        ; shown on the first listing
                MOVE    R7, R1
                MOVE    R1, S_BL_ON
                MOVE    R2, BL_NAME
                MOVE    R3, @BL_SLOT
                CALL    bl_say
                MOVE    R1, R7
                CALL    bl_reason
                JMP     ch_entry
; Its key, R8 and R9: below the last tried's, and above the best's
ch_key
                MOVE    R8, @BL_HDR+BAS_H_VERSION-BASIC_BASE
                MOVE    R9, @BL_ORD
                TST     @BL_TRIED
        ?Z      JMP     :+
                CMP     R8, @BL_LV
        ?C      JMP     :+              ; a lower version
        ?!Z     JMP     ch_entry        ; a higher one
                CMP     @BL_LO, R9
        ?!C     JMP     ch_entry        ; not after it
:
                TST     @BL_FOUND
        ?Z      JMP     ch_take
                CMP     @BL_BV, R8
        ?C      JMP     ch_take         ; a higher version
        ?!Z     JMP     ch_entry        ; a lower one
                CMP     R9, @BL_BO
        ?!C     JMP     ch_entry        ; not before it
ch_take
                MOVE    @BL_FOUND, 1
                MOVE    @BL_BV, R8
                MOVE    @BL_BO, R9
                MOVE    @BL_BSLOT, @BL_SLOT
                MOVE    R1, BL_NAME
                MOVE    R2, BL_BEST
:
                MOVE[M] @R2++, @R1++
        ?!Z     JMP     :-
                JMP     ch_entry
ch_close
                MOVE    R1, @BL_DIR
                CALL    fs_close
ch_next_slot
                ADD     R1, @BL_SLOT, 1
                MOVE    @BL_SLOT, R1
                CMP     R1, 2
        ?!Z     JMP     ch_slot
                RET

; bl_match: Z when the name at BL_NAME matches BASIC*.ROM, in either
; case. Uses R1-R4.
bl_match
                MOVE    R1, BL_NAME
                MOVE    R2, S_BL_BASIC
:
                MOVE[M] R3, @R2++
        ?Z      JMP     :+              ; BASIC matched
                OR      R3, R3, 0x20
                OR      R4, @R1++, 0x20
                CMP     R3, R4
        ?!Z     RET
                JMP     :-
:
                TST     @R1++
        ?!Z     JMP     :-              ; to its end
                SUB     R1, R1, 5       ; its last four characters
                CMP     R1, BL_NAME+5
        ?C      RET                     ; too short: Z clear
                MOVE    R2, S_BL_ROM
:
                MOVE[M] R3, @R2++
        ?Z      RET                     ; .ROM matched: Z set
                OR      R3, R3, 0x20
                OR      R4, @R1++, 0x20
                CMP     R3, R4
        ?!Z     RET
                JMP     :-

; bl_header: the header of the file BL_NAME, its first BAS_H_WORDS lines
; that are not blank, each of the address of its word, into BL_HDR, and
; bl_check on it. R1 = 0, or the reason. Uses R1-R7, and R10 and R11.
bl_header
                MOVE    R1, BL_NAME
                CALL    bl_open
                TST     R1
        ?N      JMP     bh_read
                CLR     R7
bh_line
                CALL    bl_getline
                CMP     R1, -2
        ?Z      JMP     bh_close_read
                CMP     R1, 1
        ?!Z     JMP     bh_bad          ; the end, or a line that is not one
                MOVE    R1, BL_LINE
                CALL    bin_parse
                TST     R1
        ?Z      JMP     bh_line         ; blanks only
        ?N      JMP     bh_bad
                ADD     R3, R7, BASIC_BASE
                CMP     R6, R3
        ?!Z     JMP     bh_bad          ; out of place
                MOVE    @BL_HDR[R7], R2
                ADD     R7, R7, 1
                CMP     R7, BAS_H_WORDS
        ?!Z     JMP     bh_line
                CALL    bl_close
                MOVE    R1, BL_HDR-BASIC_BASE
                JMP     bl_check        ; which returns to the caller
bh_bad
                CALL    bl_close
                MOVE    R1, BL_E_IMAGE
                RET
bh_close_read
                CALL    bl_close
bh_read
                MOVE    R1, BL_E_READ
                RET

; bl_check: the header whose word BASIC_BASE + i is at R1 + BASIC_BASE + i
; checked: the magic word, the interface, the length, the text, and the
; words of BASIC's RAM. R1 = 0, or the reason. Uses R1-R3.
bl_check
                CMP     @BAS_H_MAGIC[R1], BAS_MAGIC
        ?!Z     JMP     ck_image
                SHR     R2, @BAS_H_IFACE[R1], 16
                CMP     R2, MON_LAYOUT
        ?!Z     JMP     ck_iface
                AND     R2, @BAS_H_IFACE[R1], 0xFFFF
                CMP     R2, MON_ENTRIES+1
        ?!C     JMP     ck_iface        ; more entries than the table has
                MOVE    R2, @BAS_H_LENGTH[R1]
                SUB     R3, R2, BAS_H_WORDS
                CMP     R3, PROGRAM-BASIC_BASE-BAS_H_WORDS+1
        ?!C     JMP     ck_header       ; shorter than the header, or longer than BASIC's half
                SUB     R3, @BAS_H_TEXT[R1], BASIC_BASE+BAS_H_WORDS
                SUB     R2, R2, BAS_H_WORDS
                CMP     R3, R2
        ?!C     JMP     ck_header       ; the text outside the image
                SUB     R3, @BAS_H_RAM[R1], BAS_RAM_MIN
                CMP     R3, BAS_RAM_MAX-BAS_RAM_MIN+1
        ?!C     JMP     ck_header
                CLR     R1
                RET
ck_image
                MOVE    R1, BL_E_IMAGE
                RET
ck_iface
                MOVE    R1, BL_E_IFACE
                RET
ck_header
                MOVE    R1, BL_E_HEADER
                RET

; bl_stage: the file BL_BEST of the slot BL_BSLOT read into the staging
; area, zeroed first, and checked there: each line ADDR WORD, ADDR in
; BASIC's half and above the line's before, and then the header and the
; checksum, with bl_whole. R1 = 0, or the reason. Uses R1-R6, R8, R10,
; and R11.
bl_stage
                CALL    bl_zero
                MOVE    R1, @BL_BSLOT
                CALL    fs_mount
                TST     R1
        ?N      JMP     bs_read
                MOVE    R1, BL_BEST
                CALL    bl_open
                TST     R1
        ?N      JMP     bs_read
                MOVE    R8, BASIC_BASE-1  ; the address before the first
bs_line
                CALL    bl_getline
                TST     R1
        ?Z      JMP     bs_end
                CMP     R1, -2
        ?Z      JMP     bs_close_read
                CMP     R1, 1
        ?!Z     JMP     bs_bad_line
                MOVE    R1, BL_LINE
                CALL    bin_parse
                TST     R1
        ?Z      JMP     bs_line         ; blanks only
        ?N      JMP     bs_bad_line
                CMP     R8, R6
        ?!C     JMP     bs_bad_addr     ; not above the one before
                CMP     R6, PROGRAM
        ?!C     JMP     bs_bad_addr     ; past BASIC's half
                MOVE    R8, R6
                MOVE    @BL_STAGE[R6], R2
                JMP     bs_line
bs_end
                CALL    bl_close
                MOVE    R1, BL_STAGE
                JMP     bl_whole        ; which returns to the caller
bs_bad_line
                CALL    bl_close
                MOVE    R1, BL_E_LINE
                RET
bs_bad_addr
                CALL    bl_close
                MOVE    R1, BL_E_ADDR
                RET
bs_close_read
                CALL    bl_close
bs_read
                MOVE    R1, BL_E_READ
                RET

; bl_whole: the image whose word BASIC_BASE + i is at R1 + BASIC_BASE + i
; checked, the staged one with R1 = BL_STAGE, and the BASIC in the ROM
; with R1 = 0: its header, with bl_check, and its checksum, the sum over
; its length, which is 0. R1 = 0, or the reason. Uses R1-R4.
bl_whole
                MOVE    R4, R1
                CALL    bl_check
                TST     R1
        ?!Z     RET
                MOVE    R2, @BAS_H_LENGTH[R4]
                ADD     R3, R4, BASIC_BASE
:
                ADD     R1, R1, @R3++
                SUB[M]  R2, R2, 1
        ?!Z     JMP     :-
                TST     R1
        ?!Z     MOVE    R1, BL_E_SUM
                RET

; bl_empty: Z when the staging area is all zeros, as the configuration
; left it, and as bl_zero leaves it. Uses R1.
bl_empty
                MOVE    R1, PROGRAM
:
                TST     @R1++
        ?!Z     RET
                CMP     R1, PROGRAM+PROGRAM-BASIC_BASE
        ?!Z     JMP     :-
                RET

; bl_zero: the staging area, the program's RAM from PROGRAM, as many words
; as BASIC's half, zeroed. Uses R1.
bl_zero
                MOVE    R1, PROGRAM
:
                CLR     @R1++
                CMP     R1, PROGRAM+PROGRAM-BASIC_BASE
        ?!Z     JMP     :-
                RET

; bl_open: the file of the name at R1 opened to read, BL_H its handle,
; with BL_BUF empty. R1 = the handle, or an error. Uses R1-R6.
bl_open
                CLR     R2
                CALL    fs_open
                MOVE    @BL_H, R1
                CLR     @BL_N
                TST     R1
                RET

; bl_close: the file BL_H closed. Uses R1-R6.
bl_close
                MOVE    R1, @BL_H
                JMP     fs_close        ; which returns to the caller

; bl_getc: R1 = the next byte of the file BL_H, -1 at its end, or -2 on
; an error. Uses R1-R6.
bl_getc
                TST     @BL_N
        ?!Z     JMP     :+
                MOVE    R1, @BL_H
                MOVE    R2, BL_BUF
                MOVE    R3, BL_BUFN
                CALL    fs_read
                TST     R1
        ?N      MOVE    R1, -2
        ?N      RET
        ?Z      NOT     R1, R0          ; -1: the end
        ?Z      RET
                MOVE    @BL_N, R1
                MOVE    @BL_P, BL_BUF
:
                SUB     @BL_N, @BL_N, 1
                MOVE    R1, @BL_P
                ADD     @BL_P, R1, 1
                MOVE    R1, @R1
                RET

; bl_getline: the next line of the file BL_H that is not empty, up to a
; CR, an LF, or the end, into BL_LINE, with a 0 word after it, a TAB as
; a blank. R1 = 1 for a line, -1 for one with a byte that is not
; printable ASCII or more than BL_LMAX characters, 0 at the end of the
; file, or -2 on an error. Uses R1-R6, R10 the next word of the line, and
; R11 not 0 for a line that is not one.
bl_getline
                MOVE    R10, BL_LINE
                CLR     R11
gl_byte
                CALL    bl_getc
                CMP     R1, -2
        ?Z      RET
                CMP     R1, -1
        ?Z      JMP     gl_eof
                CMP     R1, 0x0A
        ?Z      JMP     gl_eol
                CMP     R1, 0x0D
        ?Z      JMP     gl_eol
                CMP     R1, 0x09
        ?Z      MOVE    R1, 0x20        ; a TAB is a blank
                CMP     R1, 0x20
        ?C      JMP     gl_bad          ; a control code
                CMP     R1, 0x7F
        ?!C     JMP     gl_bad          ; DEL, or 0x80 and above
                CMP     R10, BL_LINE+BL_LMAX
        ?!C     JMP     gl_bad          ; too long
                MOVE    @R10++, R1
                JMP     gl_byte
gl_bad
                ONE     R11
                JMP     gl_byte
gl_eol
                CMP     R10, BL_LINE
        ?!Z     JMP     gl_end
                TST     R11
        ?Z      JMP     gl_byte         ; an empty line
gl_end
                CLR     @R10
                ONE     R1
                TST     R11
        ?!Z     NOT     R1, R0          ; -1
                RET
gl_eof
                CMP     R10, BL_LINE
        ?!Z     JMP     gl_end
                TST     R11
        ?!Z     JMP     gl_end
                CLR     R1
                RET

; bl_say: the name at R2, one character a word, the packed text R1, and
; the slot R3: NAME on card 0, or NAME from card 0. Uses R1-R6.
bl_say
                PUSH    R1
                PUSH    R3
                MOVE    R1, R2
                CALL    _io_puts
                POP     R3
                POP     R1
                PUSH    R3
                CALL    puts_b
                POP     R1
                JMP     _io_putdec      ; which returns to the caller

; bl_reason: ": " and the text of the reason R1, and CR LF. Uses R1-R6.
bl_reason
                PUSH    R1
                MOVE    R1, S_BL_COLON
                CALL    puts_b
                POP     R1
                ADD     R1, R1, BL_REASONS-1
                MOVE    R1, @R1
                JMP     puts_b_crlf     ; which returns to the caller

BL_ZERO         .DAT    0               ; the empty name of the folder
S_BL_BASIC
                .ASCII_L 'basic'        ; the start and the end of the names taken
S_BL_ROM
                .ASCII_L '.rom'
S_BL_ON         .ASCII_B ' on card '
S_BL_FROM
                .ASCII_B ' from card '
S_BL_OLDER
                .ASCII_B ", older than the core's "
                .DAT    0
S_BL_COLON
                .ASCII_B ': '
BL_REASONS
                .DAT    S_BL_E1, S_BL_E2, S_BL_E3, S_BL_E4, S_BL_E5, S_BL_E6, S_BL_E7
S_BL_E1         .ASCII_B 'not a BASIC image'
S_BL_E2         .ASCII_B 'for another monitor'
S_BL_E3         .ASCII_B 'bad header'
S_BL_E4         .ASCII_B 'bad address'
S_BL_E5         .ASCII_B 'bad line'
                .DAT    0
S_BL_E6         .ASCII_B 'bad checksum'
                .DAT    0
S_BL_E7         .ASCII_B 'card error'
