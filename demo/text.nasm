; The text of nice_cpu's demo on the boards of NiceMonMEGA65: the name in
; the title bar, the welcome, the keys in its bar, and the note on the
; clock under the counters. The Makefile gives this file to the demo's
; Makefile in nice_cpu/demo with TEXT=, which joins it after demo.nasm.
; Each string fits its row: NAME 13 characters, from column 1, before
; VERSION at column 15, and the others 76, from column 2.

NAME            .ASCII_L 'NiceMonMEGA65'
T1              .ASCII_L 'This is the demo of the ROM, which the monitor starts with x. What you type'
T2              .ASCII_L 'on the keyboard, or send to the console, appears below the blue bar.'
T3              .ASCII_L 'To run your programs, give the board an IP address with i in the monitor,'
T4              .ASCII_L 'then load and debug them over Ethernet with tools/mon.py --eth. More is at'
URL             .ASCII_L 'https://github.com/MJoergen/NiceMonMEGA65'
KEYS            .ASCII_L 'RETURN new line   DEL delete   cursor keys move   CTRL-L clear   F12 monitor'
P3              .ASCII_L 'On the board, the time is real, and the clock is 100 MHz, or 90 MHz on the'
P4              .ASCII_L 'Nexys4DDR. In niceemu, each step counts as a cycle and as a microsecond.'
