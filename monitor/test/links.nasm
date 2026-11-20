; The test of what mon_restore does with the rows that go on from the row
; above, the word of scr_links (README.md, "The dispatch table"), after a
; program that SYS ran: two programs, which the Makefile joins with the
; stubs of mon.nasm, as test/hal18.nasm. Each prints 81 characters, which
; wrap, so that the second row goes on from the first, and returns. The
; first, at 0x8000, leaves the cursor where mon_putc put it, so the word
; keeps the row's bit, which DUMP of the word shows after it. The second,
; at 0x8020, moves the cursor to row 20 through its registers, as a
; program does that writes the screen itself: the word is 0 after it.

                .ORG    0x8000
SCR_X           .EQU    0xFFFFFF81      ; the cursor's column
SCR_Y           .EQU    0xFFFFFF82      ; the cursor's row

lk_keep
                CALL    lk_chars
                CLR     R1
                RET

; lk_chars: 81 characters x. Uses R1-R4, and R7 across the calls, saved.
lk_chars
                PUSH    R7
                MOVE    R7, 81
:
                MOVE    R1, 0x78        ; x
                CALL    _mon_putc
                SUB[M]  R7, R7, 1
        ?!Z     JMP     :-
                POP     R7
                RET

                .ORG    0x8020
lk_own
                CALL    lk_chars
                CLR     @SCR_X
                MOVE    @SCR_Y, 20
                CLR     R1
                RET
