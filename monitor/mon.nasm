; The entries of the monitor's ROM for programs (README.md, "The dispatch
; table"): the address of each entry as an .EQU, and a stub for each by its
; C name, which a program calls as it calls any routine. The entries follow
; the C ABI of nice_cpu/runtime/ABI.md. This file is joined after a
; program, and nicebuild.py --monitor --asm mon.nasm joins it to a C
; program, which declares the routines with mon.h. _scr_getx and _scr_gety
; are for C, which takes one result: the column, or the row, of scr_getxy.
; The monitor joins this file too, for the routines of monlib.nasm.

MON_RESET       .EQU    0x00
MON_EXIT        .EQU    0x02
MON_VERSION     .EQU    0x04
MON_PUTC        .EQU    0x06
MON_OUT         .EQU    0x08
SCR_CLS         .EQU    0x0A
SCR_MOVETO      .EQU    0x0C
SCR_GETXY       .EQU    0x0E
SCR_COLOR       .EQU    0x10

_mon_reset
                MOVE    R15, MON_RESET
_mon_exit
                MOVE    R15, MON_EXIT
_mon_version
                MOVE    R15, MON_VERSION
_mon_putc
                MOVE    R15, MON_PUTC
_mon_out
                MOVE    R15, MON_OUT
_scr_cls
                MOVE    R15, SCR_CLS
_scr_moveto
                MOVE    R15, SCR_MOVETO
_scr_getxy
                MOVE    R15, SCR_GETXY
_scr_color
                MOVE    R15, SCR_COLOR
_scr_getx
                MOVE    R15, SCR_GETXY
_scr_gety
                ADD     @--R13, 2, R15
                MOVE    R15, SCR_GETXY
                MOVE    R1, R2
                MOVE    R15, @R13++
