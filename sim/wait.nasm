; WAIT, and the hidden state of an interrupt routine, for tb_nicemon
; (debug link version 7, DEBUG.md §6). The program sets the timer to
; raise IRQ 0x41 after PERIOD cycles, sets the SR to E and the bit 24 of
; reset, and waits. The wait ends at the timer's request, which saves the
; SR and PC = AFTER, the word after the WAIT. The routine never returns,
; so the core stays in service, and the timer's next request stays
; pending. tools/hwtest.py writes a longer period over the constant word
; of SET_PERIOD, for the slower link of the board.
TIMER_PERIOD    .EQU    0xFFFFFF10
TIMER_VECTOR    .EQU    0xFFFFFF12
PERIOD          .EQU    50000
                MOVE    @TIMER_VECTOR, 0x41
SET_PERIOD
                MOVE    @TIMER_PERIOD, PERIOD
                MOVE    R14, 0x41000000
                WAIT
AFTER           HALT
                .ORG    0x41
                .DAT    on_timer
on_timer
                JMP     on_timer
