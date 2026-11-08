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
FS_MOUNT        .EQU    0x12
FS_OPEN         .EQU    0x14
FS_READ         .EQU    0x16
FS_READDIR      .EQU    0x18
FS_CLOSE        .EQU    0x1A
FS_WRITE        .EQU    0x1C
FS_DELETE       .EQU    0x1E
UDP_OPEN        .EQU    0x20
UDP_SEND        .EQU    0x22
UDP_RECV        .EQU    0x24
UDP_CLOSE       .EQU    0x26

_mon_reset
                JMP     MON_RESET
_mon_exit
                JMP     MON_EXIT
_mon_version
                JMP     MON_VERSION
_mon_putc
                JMP     MON_PUTC
_mon_out
                JMP     MON_OUT
_scr_cls
                JMP     SCR_CLS
_scr_moveto
                JMP     SCR_MOVETO
_scr_getxy
                JMP     SCR_GETXY
_scr_color
                JMP     SCR_COLOR
_fs_mount
                JMP     FS_MOUNT
_fs_open
                JMP     FS_OPEN
_fs_read
                JMP     FS_READ
_fs_readdir
                JMP     FS_READDIR
_fs_close
                JMP     FS_CLOSE
_fs_write
                JMP     FS_WRITE
_fs_delete
                JMP     FS_DELETE
_udp_open
                JMP     UDP_OPEN
_udp_send
                JMP     UDP_SEND
_udp_recv
                JMP     UDP_RECV
_udp_close
                JMP     UDP_CLOSE
_scr_getx
                JMP     SCR_GETXY
_scr_gety
                CALL    SCR_GETXY
                MOVE    R1, R2
                RET
