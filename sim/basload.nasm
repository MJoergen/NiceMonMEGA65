; A BASIC image for a card, as tb_basload loads it with the ROM's
; monitor (issue #153): its header, with the version, the flags, the
; length, and the checksum filled in by tools/basic_rom.py, and a cold
; start that counts its runs at T_COUNT, above the staging area, which
; the cold start leaves alone, and prints T and the count. The first run
; jumps to 0, the monitor's cold start again, which must find BASIC's
; part of the ROM locked and so load nothing; the second halts.

                .ORG    0x3000
T_COUNT         .EQU    0xE000
MON_PUTC        .EQU    0x06            ; entry 3

                MOVE    R15, t_cold     ; 0x3000, the cold start, two words
                MOVE    R15, t_cold     ; 0x3002, the warm start
                .DAT    0x5341424E      ; 0x3004, NBAS
                .DAT    0x00030025      ; 0x3005, layout 3, 37 entries
                .DAT    0               ; 0x3006, the length
                .DAT    0               ; 0x3007, the checksum
                .DAT    T_TEXT          ; 0x3008, the version's text
                .DAT    0               ; 0x3009, the version
                .DAT    0               ; 0x300A, the flags
                .DAT    2048            ; 0x300B, the words of BASIC's RAM

t_cold
                ADD     R7, @T_COUNT, 1
                MOVE    @T_COUNT, R7
                MOVE    R1, 0x54        ; T
                CALL    MON_PUTC
                ADD     R1, R7, 0x30
                CALL    MON_PUTC
                MOVE    R1, 0x0D
                CALL    MON_PUTC
                MOVE    R1, 0x0A
                CALL    MON_PUTC
                CMP     R7, 1
        ?Z      JMP     0               ; the monitor's cold start again
                HALT

T_TEXT          .ASCII_B 'T'
