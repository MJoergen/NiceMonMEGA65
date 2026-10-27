; Reads through the core's data bus what the other programs leave to the
; debug link: the fetch statistics (MICROARCH.md §8.1), the microsecond
; counter of SYSTEM.md §3, and the board's registers. It leaves the results
; in memory at RESULT, where tb_nicemon reads them over the link.
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
RESULT          .EQU    0x100

                MOVE    @FS_CTRL, 0     ; stop the fetch statistics
                MOVE    @RESULT, @FS_CYCLES  ; the cycles before the stop
                MOVE    @0x101, @FS_HIST  ; those with no word in the buffer
                MOVE    R2, FS_HIST
                MOVE    R3, 32
SUM             ADD     R1, R1, @R2++
                SUB[M]  R3, R3, 1
        ?!Z     MOVE    R15, SUM
                MOVE    @0x102, R1      ; the sum of FS_HIST
                MOVE    @0x103, @FS_CTRL  ; 0, stopped
                MOVE    @0x104, @CYCLE_LO
                MOVE    @0x105, @TIME_LO
                MOVE    @0x106, @TIME_HI  ; 0
                MOVE    @BRD_LED, 0x5A5A  ; the LEDs
                MOVE    @0x107, @BRD_LED
                MOVE    @0x108, @BRD_BTN  ; the buttons
                MOVE    @0x109, @BRD_SW  ; the switches
                HALT
