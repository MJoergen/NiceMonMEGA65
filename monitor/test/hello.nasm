; A program for the monitor (README.md, "Programs"), at 0x8000: the
; Makefile joins nice_cpu's start_mon.nasm before it, and monlib.nasm,
; mon.nasm, and nice_cpu's lib.nasm after it. main prints through
; nice_print, so through the putc vector, which start_mon.nasm set to the
; monitor's mon_putc entry, and through the HAL: the version of the table,
; a text at column 40 of the next row in yellow, and a line on the line
; only. It returns 42. The test runs it with the input test/run.txt.

_main           MOVE    R1, hello.text
                ADD     @--R13, 2, R15
                MOVE    R15, _nice_print
                ADD     @--R13, 2, R15
                MOVE    R15, _mon_version
                ADD     @--R13, 2, R15
                MOVE    R15, _io_puthex
                ADD     @--R13, 2, R15
                MOVE    R15, _io_crlf
                ADD     @--R13, 2, R15
                MOVE    R15, _scr_getxy  ; R1 the column, R2 the row
                MOVE    R1, 40
                ADD     @--R13, 2, R15
                MOVE    R15, _scr_moveto
                MOVE    R1, 0x000FF000  ; yellow on black
                ADD     @--R13, 2, R15
                MOVE    R15, _scr_color
                MOVE    @--R13, R1      ; the old color
                MOVE    R1, hello.right
                ADD     @--R13, 2, R15
                MOVE    R15, _io_puts
                MOVE    R1, @R13++
                ADD     @--R13, 2, R15
                MOVE    R15, _scr_color
                ADD     @--R13, 2, R15
                MOVE    R15, _io_crlf
                MOVE    R1, 1           ; the line only
                ADD     @--R13, 2, R15
                MOVE    R15, _mon_out
                MOVE    R1, hello.line
                ADD     @--R13, 2, R15
                MOVE    R15, _io_puts
                ADD     @--R13, 2, R15
                MOVE    R15, _io_crlf
                MOVE    R1, 3           ; both again
                ADD     @--R13, 2, R15
                MOVE    R15, _mon_out
                MOVE    R1, 42
                MOVE    R15, @R13++
hello.text
                .ASCII_L 'Hello from 00008000, table '
hello.right
                .ASCII_L 'at column 40'
hello.line
                .ASCII_L 'on the line only'
