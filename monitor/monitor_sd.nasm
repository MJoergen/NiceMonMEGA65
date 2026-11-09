; The monitor's SD cards below the file system, which the Makefile joins
; after monitor.nasm (its header): the sector routines sd_init, sd_read,
; and sd_write, the ROM's own, with no entries in the dispatch table
; (doc/SDCARD.md, "The ROM"), and the names by which fat32.c calls them.
; The file commands of monitor_cmd.nasm show the errors of the controller with
; sd_fail.

SD_CSR          .EQU    0xFFFFFFA0      ; the SD card's status, and a write starts a command (nice_cpu's SYSTEM.md §5)
SD_LBA          .EQU    0xFFFFFFA1      ; the sector of a Read or Write
SD_CHUNK        .EQU    0xFFFFFFA2      ; the 8 words of the buffer at SD_BUF
SD_ERROR        .EQU    0xFFFFFFA3      ; the error of the last command, 0 for none
SD_SELECT       .EQU    0xFFFFFFA4      ; the selected slot
SD_LAST         .EQU    0xFFFFFFA5      ; the card's last sector, while it is ready
SD_SLOTS        .EQU    0xFFFFFFA6      ; the slots of the system
SD_BUF          .EQU    0xFFFFFFA8      ; SD_BUF0 to SD_BUF7, the words of the chunk
SD_INIT         .EQU    0               ; the commands of SD_CSR
SD_RD           .EQU    1
SD_WR           .EQU    2
SD_BUSY         .EQU    0x01            ; the bits of its status
SD_READY        .EQU    0x08
SD_CHANGED      .EQU    0x10

; The sector routines for fat32.c, by the names that it imports: R2 of
; fat_sd_read and fat_sd_write is a byte address of the C code's memory,
; at a multiple of 4, so a word of it
_fat_sd_init
                JMP     sd_init
_fat_sd_read
                SHR     R2, R2, 2
                ADD     R2, R2, ___wasm_memory
                JMP     sd_read
_fat_sd_write
                SHR     R2, R2, 2
                ADD     R2, R2, ___wasm_memory
                JMP     sd_write

; An error of the controller, R1 its negative: the number, the slot, and
; the meaning, with the last sector after error 7
sd_fail
                SUB     R8, R0, R1      ; the error
                MOVE    R1, S_SDERR
                CALL    _io_puts
                MOVE    R1, R8
                CALL    _io_putdec
                MOVE    R1, S_INSLOT
                CALL    _io_puts
                MOVE    R1, R7
                CALL    _io_putdec
                MOVE    R1, S_UCOMMA
                CALL    _io_puts
                SUB     R1, R8, 1
                CMP     R1, SD_ERRS
        ?!C     JMP     :+              ; an error without a meaning here
                ADD     R1, R1, SD_ERRORS
                MOVE    R1, @R1
                CALL    _io_puts
                CMP     R8, 7
        ?!Z     JMP     :+
                MOVE    R1, @SD_LAST
                CALL    _io_puthex
:
                CALL    _io_crlf
                JMP     main

; The sector routines, the ROM's own, with no entries in the dispatch table
; (doc/SDCARD.md, "The ROM"). They follow the C ABI, wait for busy before
; the command and after it, as nice_cpu's SYSTEM.md §5 asks, and return 0,
; or the negative of SD_ERROR. sd_init selects the slot and starts its card
; up; sd_read and sd_write use the slot that is selected, which is the
; slot of the last sd_init unless a program has changed it. Their buffer is
; 128 words in RAM, 4 bytes a word, little-endian, as the controller's is,
; and is copied through SD_CHUNK and SD_BUF0-SD_BUF7, so that no sector of
; theirs is left for another to rely on in the controller's buffer.

; sd_init: R1 the slot, selected, and its card started up. Uses R1.
sd_init
                CALL    sd_wait
                MOVE    @SD_SELECT, R1
                MOVE    @SD_CSR, SD_INIT
                JMP     sd_end

; sd_read: the sector R1 into the 128 words at R2. Uses R1-R4.
sd_read
                CALL    sd_wait
                MOVE    @SD_LBA, R1
                MOVE    @SD_CSR, SD_RD
                CALL    sd_wait
                MOVE[M] R1, @SD_ERROR
        ?!Z     JMP     sd_neg
                MOVE    R3, 0           ; the chunk
:
                MOVE    @SD_CHUNK, R3
                MOVE    R4, SD_BUF
:
                MOVE    @R2++, @R4++
                CMP     R4, SD_BUF+8
        ?!Z     JMP     :-
                ADD     R3, R3, 1
                CMP     R3, 16
        ?!Z     JMP     :--
                RET                     ; R1 is 0

; sd_write: the 128 words at R2 to the sector R1. Uses R1-R4.
sd_write
                CALL    sd_wait         ; as the buffer takes no write while busy
                MOVE    R3, 0
:
                MOVE    @SD_CHUNK, R3
                MOVE    R4, SD_BUF
:
                MOVE    @R4++, @R2++
                CMP     R4, SD_BUF+8
        ?!Z     JMP     :-
                ADD     R3, R3, 1
                CMP     R3, 16
        ?!Z     JMP     :--
                MOVE    @SD_LBA, R1
                MOVE    @SD_CSR, SD_WR
; sd_end: the end of a command, R1 = 0, or the negative of SD_ERROR
sd_end
                CALL    sd_wait
                MOVE[M] R1, @SD_ERROR
        ?Z      RET
sd_neg
                SUB     R1, R0, R1
                RET

; sd_wait: until busy is 0, which every command reaches, as the controller
; has a timeout for each step. Uses no register.
sd_wait
                AND[M]  R0, @SD_CSR, SD_BUSY
        ?!Z     JMP     sd_wait
                RET

S_SDERR         .ASCII_L 'SD error '
S_INSLOT
                .ASCII_L ' in slot '
; The meanings of the errors 1 to SD_ERRS of SD_ERROR
SD_ERRORS
                .DAT    E_SD1, E_SD2, E_SD3, E_SD4, E_SD5, E_SD6, E_SD7, E_SD8
SD_ERRS         .EQU    8
E_SD1           .ASCII_L 'no card'
E_SD2           .ASCII_L 'the card is not ready'
E_SD3           .ASCII_L 'timeout, the card did not answer'
E_SD4           .ASCII_L 'CRC, the data from the card was corrupted'
E_SD5           .ASCII_L 'the card reported an error'
E_SD6           .ASCII_L 'the card is write-protected'
E_SD7           .ASCII_L 'the sector is after the last, '
E_SD8           .ASCII_L 'Init failed'
