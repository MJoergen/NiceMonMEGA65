; Reads the word at WORD for good, for tb_dbg with G_WATCH: a watchpoint
; on the reads of that word stops the core after the read, and the state
; is WCH n, with the PC at the JMP after the read.
WORD            .EQU    0x800

                MOVE    R13, WORD
LOOP            MOVE    R1, @R13
                JMP     LOOP
