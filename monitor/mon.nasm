; The entries of the monitor's ROM for programs (README.md, "The dispatch
; table"): the address of each entry as an .EQU, and a stub for each by its
; C name, which a program calls as it calls any routine. The entries follow
; the C ABI of nice_cpu/runtime/ABI.md. This file is joined after a
; program, and nicebuild.py --monitor --asm mon.nasm joins it to a C
; program, which declares the routines with mon.h. Every stub starts with
; _mon_, so that it clashes with none of the program's labels: the entry
; scr_cls is _mon_scr_cls. The names of the stubs before V2.1, such as
; _scr_cls, are labels of the same stubs, for the programs that use them.
; _mon_scr_getx and _mon_scr_gety are for C, which takes one result: the
; column, or the row, of scr_getxy.
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
FS_READNAME     .EQU    0x28
NET_CONFIG      .EQU    0x2A
NET_SET         .EQU    0x2C
NET_DHCP        .EQU    0x2E
NET_POLL        .EQU    0x30
DNS_LOOKUP      .EQU    0x32
TCP_OPEN        .EQU    0x34
TCP_STATE       .EQU    0x36
TCP_SEND        .EQU    0x38
TCP_RECV        .EQU    0x3A
TCP_CLOSE       .EQU    0x3C
TCP_LISTEN      .EQU    0x3E
CON_GETLINE     .EQU    0x40
BIN_LINE        .EQU    0x42
CLOCK_SET       .EQU    0x44
NET_SERVERS     .EQU    0x46
MON_RESTORE     .EQU    0x48
MON_ENTRIES     .EQU    37              ; the number of the entries above, in BASIC's header

; The outputs of mon_out, as in mon.h
MON_OUT_LINE    .EQU    1
MON_OUT_SCREEN  .EQU    2

; The errors of the network's entries, as in mon.h
MON_E_NOIP      .EQU    -40
MON_E_PORT      .EQU    -41
MON_E_UCLOSED   .EQU    -42
MON_E_ULONG     .EQU    -43
MON_E_NOROUTE   .EQU    -44
MON_E_NODHCP    .EQU    -45
MON_E_NODNS     .EQU    -46
MON_E_DNSTIME   .EQU    -47
MON_E_DNSNAME   .EQU    -48
MON_E_DNSFAIL   .EQU    -49
MON_E_THANDLE   .EQU    -50
MON_E_TFULL     .EQU    -51
MON_E_TSIZE     .EQU    -52
MON_E_TREFUSED  .EQU    -53
MON_E_TRESET    .EQU    -54
MON_E_TTIMEOUT  .EQU    -55
MON_E_TCLOSED   .EQU    -56
MON_E_TEOF      .EQU    -57

; Colors for scr_color, as in mon.h: a foreground and a background,
; added, with no blanks, such as MON_FG_YELLOW+MON_BG_BLUE. A color left
; out is black.
MON_FG_BLACK    .EQU    0x00000000
MON_FG_RED      .EQU    0x000F0000
MON_FG_GREEN    .EQU    0x0000F000
MON_FG_YELLOW   .EQU    0x000FF000
MON_FG_BLUE     .EQU    0x00000F00
MON_FG_MAGENTA  .EQU    0x000F0F00
MON_FG_CYAN     .EQU    0x0000FF00
MON_FG_WHITE    .EQU    0x000FFF00
MON_FG_GRAY     .EQU    0x00088800
MON_FG_LIGHT_RED .EQU   0x000F6600
MON_FG_LIGHT_GREEN .EQU 0x0008E800
MON_FG_LIGHT_BLUE .EQU  0x0000DF00
MON_FG_DARK_BLUE .EQU   0x00003600

MON_BG_BLACK    .EQU    0x00000000
MON_BG_RED      .EQU    0xF0000000
MON_BG_GREEN    .EQU    0x0F000000
MON_BG_YELLOW   .EQU    0xFF000000
MON_BG_BLUE     .EQU    0x00F00000
MON_BG_MAGENTA  .EQU    0xF0F00000
MON_BG_CYAN     .EQU    0x0FF00000
MON_BG_WHITE    .EQU    0xFFF00000
MON_BG_GRAY     .EQU    0x88800000
MON_BG_LIGHT_RED .EQU   0xF6600000
MON_BG_LIGHT_GREEN .EQU 0x8E800000
MON_BG_LIGHT_BLUE .EQU  0x0DF00000
MON_BG_DARK_BLUE .EQU   0x03600000

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
_mon_scr_cls
_scr_cls
                JMP     SCR_CLS
_mon_scr_moveto
_scr_moveto
                JMP     SCR_MOVETO
_mon_scr_getxy
_scr_getxy
                JMP     SCR_GETXY
_mon_scr_color
_scr_color
                JMP     SCR_COLOR
_mon_fs_mount
_fs_mount
                JMP     FS_MOUNT
_mon_fs_open
_fs_open
                JMP     FS_OPEN
_mon_fs_read
_fs_read
                JMP     FS_READ
_mon_fs_readdir
_fs_readdir
                JMP     FS_READDIR
_mon_fs_close
_fs_close
                JMP     FS_CLOSE
_mon_fs_write
_fs_write
                JMP     FS_WRITE
_mon_fs_delete
_fs_delete
                JMP     FS_DELETE
_mon_udp_open
_udp_open
                JMP     UDP_OPEN
_mon_udp_send
_udp_send
                JMP     UDP_SEND
_mon_udp_recv
_udp_recv
                JMP     UDP_RECV
_mon_udp_close
_udp_close
                JMP     UDP_CLOSE
_mon_fs_readname
_fs_readname
                JMP     FS_READNAME
_mon_net_config
_net_config
                JMP     NET_CONFIG
_mon_net_set
_net_set
                JMP     NET_SET
_mon_net_dhcp
_net_dhcp
                JMP     NET_DHCP
_mon_net_poll
_net_poll
                JMP     NET_POLL
_mon_dns_lookup
_dns_lookup
                JMP     DNS_LOOKUP
_mon_tcp_open
_tcp_open
                JMP     TCP_OPEN
_mon_tcp_state
_tcp_state
                JMP     TCP_STATE
_mon_tcp_send
_tcp_send
                JMP     TCP_SEND
_mon_tcp_recv
_tcp_recv
                JMP     TCP_RECV
_mon_tcp_close
_tcp_close
                JMP     TCP_CLOSE
_mon_tcp_listen
_tcp_listen
                JMP     TCP_LISTEN
_mon_con_getline
                JMP     CON_GETLINE
_mon_bin_line
                JMP     BIN_LINE
_mon_clock_set
                JMP     CLOCK_SET
_mon_net_servers
                JMP     NET_SERVERS
_mon_restore
                JMP     MON_RESTORE
_mon_scr_getx
_scr_getx
                JMP     SCR_GETXY
_mon_scr_gety
_scr_gety
                CALL    SCR_GETXY
                MOVE    R1, R2
                RET
