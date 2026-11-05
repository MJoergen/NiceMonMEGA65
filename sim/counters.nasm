; Reads through the core's data bus what the other programs leave to the
; debug link: the fetch statistics (MICROARCH.md §8.1), the microsecond
; counter of SYSTEM.md §3, the board's registers, and the fonts of SYSTEM.md
; §1.8. It leaves the results in memory at RESULT, where tb_nicemon reads
; them over the link.
;
; It writes a row of the glyph of 0x80 in the font RAM and reads it at once,
; reads a row of Spleen's A in the character ROM, writes it, which is
; dropped, and reads it again, and selects the font RAM with the font base.
;
; A start of the core clears the fetch statistics, and the program stops
; them first, so FS_CYCLES holds the few cycles before the stop, and the
; FS_HIST words sum to it. The loop that sums them takes more than a
; microsecond, so the microsecond counter is not 0 when it is read, right
; after the cycle counter.
FS_CTRL         .EQU    0xFFFFFF50
FS_CYCLES       .EQU    0xFFFFFF51
FS_HIST         .EQU    0xFFFFFF60
CYCLE_LO        .EQU    0xFFFFFF40
TIME_LO         .EQU    0xFFFFFF44
TIME_HI         .EQU    0xFFFFFF45
BRD_LED         .EQU    0xFFFFFF90
BRD_BTN         .EQU    0xFFFFFF95
BRD_SW          .EQU    0xFFFFFF96
GLYPH           .EQU    0xFFFE1005      ; row 5 of 0x80 in the font RAM
ROM_A           .EQU    0xFFFE2829      ; row 9 of A in the character ROM
FONT_BASE       .EQU    0xFFFFFF86
RESULT          .EQU    0x100

                MOVE    @FS_CTRL, 0     ; stop the fetch statistics
                MOVE    @RESULT, @FS_CYCLES  ; the cycles before the stop
                MOVE    @0x101, @FS_HIST  ; those with no word in the buffer
                MOVE    R2, FS_HIST
                MOVE    R3, 32
SUM             ADD     R1, R1, @R2++
                SUB[M]  R3, R3, 1
        ?!Z     JMP     SUM
                MOVE    @0x102, R1      ; the sum of FS_HIST
                MOVE    @0x103, @FS_CTRL  ; 0, stopped
                MOVE    @0x104, @CYCLE_LO
                MOVE    @0x105, @TIME_LO
                MOVE    @0x106, @TIME_HI  ; 0
                MOVE    @BRD_LED, 0x5A5A  ; the LEDs
                MOVE    @0x107, @BRD_LED
                MOVE    @0x108, @BRD_BTN  ; the buttons
                MOVE    @0x109, @BRD_SW  ; the switches
                MOVE    @GLYPH, 0xABCD1234  ; bits 31..16 are dropped
                MOVE    @0x10A, @GLYPH  ; 0x1234
                MOVE    @0x10B, @ROM_A  ; Spleen's row
                MOVE    @ROM_A, 0       ; dropped
                MOVE    @0x10C, @ROM_A  ; Spleen's row still
                MOVE    @FONT_BASE, 0xFFFE0000  ; the font RAM shown
                MOVE    @0x10D, @FONT_BASE
                HALT
