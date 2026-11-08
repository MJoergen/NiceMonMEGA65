; A program that has the SD card in use when tools/sdtest.py reads it with
; tools/sdcard.py: with INIT 1 it starts the card in slot 0 up, reads
; sector 5, and leaves SD_CHUNK at 3; with INIT 0 it only sets SD_LBA and
; SD_CHUNK, and the card is not ready. Then it loops, and the test checks
; that the tool left SD_LBA, SD_CHUNK, and the buffer as they were.
SD_CSR          .EQU    0xFFFFFFA0
SD_LBA          .EQU    0xFFFFFFA1
SD_CHUNK        .EQU    0xFFFFFFA2
SD_SELECT       .EQU    0xFFFFFFA4
INIT            .EQU    1

START           MOVE    @SD_SELECT, 0
                MOVE    @SD_LBA, 5
                MOVE    R1, INIT
                CMP     R1, 0
        ?Z      JMP     CHUNK
                MOVE    @SD_CSR, 0      ; Init
WAIT1           MOVE    R1, @SD_CSR
                AND[M]  R1, R1, 1       ; busy
        ?!Z     JMP     WAIT1
                MOVE    @SD_CSR, 1      ; Read sector 5
WAIT2           MOVE    R1, @SD_CSR
                AND[M]  R1, R1, 1
        ?!Z     JMP     WAIT2
CHUNK           MOVE    @SD_CHUNK, 3
LOOP            JMP     LOOP
