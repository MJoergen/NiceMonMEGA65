; A program for the monitor (README.md, "Programs"), at 0x8000: the
; Makefile joins nice_cpu's start_mon.nasm before it, and monlib.nasm,
; mon.nasm, and nice_cpu's lib.nasm after it. main prints through
; nice_print, so through the putc vector, which start_mon.nasm set to the
; monitor's mon_putc entry, and through the HAL: the version of the table,
; a text at column 40 of the next row in yellow, followed by 0x80 on the
; screen only, and a line on the line only. Before it returns it draws a row of the glyph of
; 0x80 in the font RAM and selects that font with the font base, which the
; monitor puts back to 0 at the return, while the glyph stays (nice_cpu's
; SYSTEM.md §1.8), and hides the cursor, which the monitor shows again,
; blinking, at the return, as nice_chess hides it. It returns 42, with VBASE 0x80 in R14, which the
; monitor clears at the return. The test runs it with the input test/run.txt.

_main           MOVE    R1, hello.text
                CALL    _nice_print
                CALL    _mon_version
                CALL    _io_puthex
                CALL    _io_crlf
                CALL    _scr_getxy      ; R1 the column, R2 the row
                MOVE    R1, 40
                CALL    _scr_moveto
                MOVE    R1, 0x000FF000  ; yellow on black
                CALL    _scr_color
                PUSH    R1              ; the old color
                MOVE    R1, hello.right
                CALL    _io_puts
                MOVE    R1, 2           ; the screen only
                CALL    _mon_out
                MOVE    R1, 0x80        ; as any character
                CALL    _mon_putc
                MOVE    R1, 3           ; both again
                CALL    _mon_out
                POP     R1
                CALL    _scr_color
                CALL    _io_crlf
                MOVE    R1, 1           ; the line only
                CALL    _mon_out
                MOVE    R1, hello.line
                CALL    _io_puts
                CALL    _io_crlf
                MOVE    R1, 3           ; both again
                CALL    _mon_out
                MOVE    @0xFFFE1000, 0xFFFF  ; row 0 of 0x80, a line
                MOVE    @0xFFFFFF86, 0xFFFE0000  ; the font RAM shown
                MOVE    @0xFFFFFF80, 0  ; the cursor hidden
                MOVE    R14, 0x80       ; VBASE 0x80, and E 0
                MOVE    R1, 42
                RET
hello.text
                .ASCII_L 'Hello from 00008000, table '
hello.right
                .ASCII_L 'at column 40'
hello.line
                .ASCII_L 'on the line only'
