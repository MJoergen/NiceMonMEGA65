; The monitor's SD cards below the file system, which the Makefile joins
; after monitor.nasm (its header): the sector routines sd_init, sd_read,
; and sd_write, the ROM's own, with no entries in the dispatch table
; (doc/SDCARD.md, "The ROM"), which monitor_fat.nasm calls.
; The file statements of monitor_cmd.nasm show the errors of the controller
; with sd_fail.

SD_CSR          .EQU    0xFFFFFFA0      ; the SD card's status, and a write starts a command (nice_cpu's DEVICES.md §5)
SD_LBA          .EQU    0xFFFFFFA1      ; the sector of a Read or Write
SD_CHUNK        .EQU    0xFFFFFFA2      ; the 8 words of the buffer at SD_BUF
SD_ERROR        .EQU    0xFFFFFFA3      ; the error of the last command, 0 for none
SD_SLOTS        .EQU    0xFFFFFFA6      ; the slots of the system
SD_BUF          .EQU    0xFFFFFFA8      ; SD_BUF0 to SD_BUF7, the words of the chunk
SD_INIT         .EQU    0               ; the commands of SD_CSR
SD_RD           .EQU    1
SD_WR           .EQU    2
SD_BUSY         .EQU    0x01            ; the bits of its status
SD_READY        .EQU    0x08
SD_CHANGED      .EQU    0x10

; The sector routines, the ROM's own, with no entries in the dispatch table
; (doc/SDCARD.md, "The ROM"). They follow the C ABI, wait for busy before
; the command and after it, as nice_cpu's DEVICES.md §5 asks, and return 0,
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
                CLR     R3              ; the chunk
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
                CLR     R3
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
