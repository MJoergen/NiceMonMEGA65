; A program for the monitor (README.md, "Programs"), at 0x8000: the
; Makefile joins nice_cpu's start_mon.nasm before it, and monlib.nasm,
; mon.nasm, and nice_cpu's lib.nasm after it. main prints through
; nice_print, so through the putc vector, which start_mon.nasm set to the
; monitor's mon_putc entry, and through the HAL: the version of the table,
; a text at column 40 of the next row in yellow, and a line on the line
; only. It returns 42, with VBASE 0x80 in R14, which the monitor clears
; at the return. The test runs it with the input test/run.txt.

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
                MOVE    R14, 0x80       ; VBASE 0x80, and E 0
                MOVE    R1, 42
                RET
hello.text
                .ASCII_L 'Hello from 00008000, table '
hello.right
                .ASCII_L 'at column 40'
hello.line
                .ASCII_L 'on the line only'
