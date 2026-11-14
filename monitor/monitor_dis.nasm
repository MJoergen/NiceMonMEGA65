; The monitor's disassembler, u, which the Makefile joins after
; monitor.nasm (its header). u disassembles instructions, a row each, in
; the text of nice_cpu's nicedis.py, with the pairs of a call shown as
; CALL, the return as RET, and the words of NOP, JMP, PUSH, POP, CLR, TST,
; and CMP as those, the pseudo-instructions of nice_cpu's ISA.md §10.1
; (README.md, "The disassembler"). Its variables, V_UNEXT, V_UF, V_UC,
; and V_UNOPS, are in monitor.nasm, with the others, and so are the two
; texts that it shares with the other commands, S_UCOMMA and S_UGAP.

DIS_ROWS        .EQU    20              ; the instructions that u shows without a count

; u [ADDR] [N]: N instructions from ADDR, disassembled, a row each: the
; address, the instruction's words, 1 to 4, and its text, as nicedis.py
; shows it (README.md). Without ADDR, the instructions after the last
; shown; without N, DIS_ROWS. ADD @--R13, n, R15 and MOVE R15, target,
; with the same condition, no modifier, and n the words of the MOVE, are
; one row, CALL target, MOVE R15, @R13++ is RET, and the other
; pseudo-instructions of nice_cpu's ISA.md §10.1 are those of U_PSEUDO,
; the first that matches. R7 is the address of the instruction, R8 counts
; the rows left, R9 is the instruction word, R10 its kind, an index of
; DIS_KINDS, and R12 the address after it. The fields are at V_UF, their
; constants at V_UC, and the operands of the mnemonic at V_UNOPS.
cmd_dis
                MOVE    R1, R2
                CALL    _io_gethex      ; R1 the address, R2 its digits, R3 after it
                TST     R2
        ?!Z     MOVE    @V_UNEXT, R1
                MOVE    R1, R3
                CALL    _io_gethex      ; R1 the count
                TST     R2
        ?Z      MOVE    R1, DIS_ROWS
                MOVE[M] R8, R1
        ?Z      JMP     main
                MOVE    R7, @V_UNEXT
dis_row
                MOVE    R9, @R7
                ADD     R12, R7, 1
                AND     R1, R9, 0x0C000000
                CMP     R1, 0x0C000000
        ?Z      JMP     dis_ctrl
; An ALU or SHIFT instruction: its fields, and the constant words that
; follow it, in field order dest, s0, s1
                SHR     R1, R9, 14
                AND     @V_UF, R1, 0x7F
                SHR     R1, R9, 7
                AND     @V_UF+1, R1, 0x7F
                AND     @V_UF+2, R9, 0x7F
                MOVE    R11, 0
:
                AND     R1, @V_UF[R11], 0x30
                CMP     R1, 0x30
        ?Z      MOVE    @V_UC[R11], @R12++
                ADD     R11, R11, 1
                CMP     R11, 3
        ?!Z     JMP     :-
; RET, the first half of a CALL, another pseudo-instruction, or another
; instruction
                AND     R1, R9, 0x0FFFFFFF  ; without the condition
                MOVE    R10, 2
                CMP     R1, 0x0003F680  ; MOVE R15, @R13++
        ?Z      JMP     dis_print
                CMP     R1, 0x0077580F  ; ADD @--R13, n, R15
        ?!Z     JMP     dis_find
                MOVE    R2, @R12        ; the word after it
                XOR     R3, R2, R9
                AND[M]  R0, R3, 0xF0000000
        ?!Z     JMP     dis_find        ; another condition
                AND     R3, R2, 0x0FFFC07F
                CMP     R3, 0x0003C000  ; MOVE R15, s0
        ?!Z     JMP     dis_find
                MOVE    R4, 1           ; the words of the MOVE
                SHR     R3, R2, 7
                AND     R3, R3, 0x30
                CMP     R3, 0x30
        ?Z      MOVE    R4, 2
                CMP     R4, @V_UC+1
        ?!Z     JMP     dis_find        ; n is not their number
                ADD     R12, R12, R4
                MOVE    R10, 3
                JMP     dis_print
; The first entry of U_PSEUDO whose mask and value match, kind 5 for the
; first, or kind 0, a plain instruction
dis_find
                MOVE    R10, 5
                MOVE    R2, U_PSEUDO
:
                AND     R3, R1, @R2++   ; the mask
                CMP     R3, @R2++       ; the value
        ?Z      JMP     dis_print
                ADD     R2, R2, 3
                ADD     R10, R10, 1
                CMP     R10, 5+U_PSEUDOS
        ?!Z     JMP     :-
                MOVE    R10, 0
                JMP     dis_print
; A control instruction, which is reserved with a command past WAIT, a bit
; of 20..8 set, or a vector but for INT
dis_ctrl
                MOVE    R10, 1
                SHR     R1, R9, 21
                AND     R1, R1, 0x1F
                CMP     R1, 4
        ?!C     MOVE    R10, 4
                AND[M]  R0, R9, 0x001FFF00
        ?!Z     MOVE    R10, 4
                CMP     R1, 2
        ?Z      JMP     dis_print
                AND[M]  R0, R9, 0xFF
        ?!Z     MOVE    R10, 4
; The address, the words, blanks for the words that the instruction does
; not have, and the text of its kind
dis_print
                MOVE    R1, R7
                MOVE    R2, 8
                CALL    u_hex
                MOVE    R11, R7
:
                CMP     R11, R12
        ?Z      JMP     :+
                MOVE    R1, 0x20
                CALL    mon_putc
                MOVE    R1, @R11++
                MOVE    R2, 8
                CALL    u_hex
                JMP     :-
:               SUB     R1, R11, R7
                CMP     R1, 4
        ?Z      JMP     :+
                MOVE    R1, S_UBLANK
                CALL    puts_b
                ADD     R11, R11, 1
                JMP     :-
:
                MOVE    R1, S_UGAP
                CALL    puts_b
                JMP     @DIS_KINDS[R10]
; Kind 0, an ALU or SHIFT instruction, which is a .DAT if a field that its
; mnemonic does not use is not R0
dis_insn
                SHR     R1, R9, 21
                AND     R1, R1, 0xF     ; the opcode
                MOVE    R2, 3
                AND[M]  R0, R9, 0x08000000
        ?Z      MOVE    R2, @U_NOPS[R1]  ; an ALU instruction's
                MOVE    @V_UNOPS, R2
                MOVE    R3, 0
:
                CMP     R2, 3
        ?Z      JMP     :+
                OR      R3, R3, @V_UF[R2]
                ADD     R2, R2, 1
                JMP     :-
:
                TST     R3
        ?Z      JMP     :+
                CALL    u_dat
                CALL    u_stmt
                CALL    u_unused
                JMP     dis_end
:
                CALL    u_stmt
                JMP     dis_end
; Kind 1, HALT, RTI, INT, with its vector in decimal, or WAIT
dis_cmd         MOVE    R1, R9
                CALL    u_cond
                SHR     R1, R9, 21
                AND     R11, R1, 0x1F
                MOVE    R1, @U_CTRL[R11]
                CALL    puts_b
                CMP     R11, 2
        ?!Z     JMP     dis_end
                MOVE    R1, 0x20
                CALL    mon_putc
                AND     R1, R9, 0xFF
                CALL    _io_putdec
                JMP     dis_end
; Kind 2, RET
dis_ret         MOVE    R1, R9
                CALL    u_cond
                MOVE    R1, S_URET
                CALL    puts_b
                JMP     dis_end
; Kind 3, CALL, with the operand of the MOVE, the third word, whose
; constant is the fourth
dis_call
                MOVE    R1, R9
                CALL    u_cond
                MOVE    R1, S_UCALL
                CALL    puts_b
                ADD     R1, R7, 2
                SHR     R1, @R1, 7
                AND     R1, R1, 0x7F
                ADD     R2, R7, 3
                MOVE    R2, @R2
                MOVE    R3, 0
                CALL    u_op
                JMP     dis_end
; Kind 4, a reserved control word
dis_rsvd
                CALL    u_dat
                MOVE    R1, S_URSVD
                CALL    puts_b
                JMP     dis_end
; Kinds 5 and up, the pseudo-instruction of entry R10 - 5 of U_PSEUDO,
; with its fields, from its first, as u_stmt writes them
dis_pseudo
                MOVE    R1, R9
                CALL    u_cond
                SUB     R1, R10, 5
                SHL     R2, R1, 2
                ADD     R2, R2, R1
                ADD     R11, R2, U_PSEUDO+2  ; the name, the first field, and their number
                MOVE    R1, @R11++
                CALL    puts_b
                MOVE    R10, @R11++
                ADD[M]  @V_UNOPS, R10, @R11
        ?Z      JMP     dis_end         ; NOP
                MOVE    R1, 0x20
                CALL    mon_putc
                CALL    u_stmt_op
; The end of the row, and the next instruction
dis_end         CALL    _io_crlf
                MOVE    R7, R12
                SUB[M]  R8, R8, 1
        ?!Z     JMP     dis_row
                MOVE    @V_UNEXT, R7
                JMP     main

; u_stmt: the condition, the mnemonic with its modifiers, and the operands
; of the ALU or SHIFT instruction R9. Uses R1-R6 and R10.
u_stmt
                MOVE    R1, R9
                CALL    u_cond
                SHR     R1, R9, 21
                AND     R1, R1, 0xF
                AND[M]  R0, R9, 0x08000000
        ?!Z     ADD     R1, R1, 16      ; the SHIFT names follow the ALU's
                MOVE    R1, @U_NAMES[R1]
                CALL    puts_b
                AND[M]  R0, R9, 0x06000000
        ?Z      JMP     :+              ; no modifier
                MOVE    R1, 0x5B        ; [
                CALL    mon_putc
                AND[M]  R0, R9, 0x04000000
        ?!Z     MOVE    R1, 0x43        ; C
        ?!Z     CALL    mon_putc
                AND[M]  R0, R9, 0x02000000
        ?!Z     MOVE    R1, 0x4D        ; M
        ?!Z     CALL    mon_putc
                MOVE    R1, 0x5D        ; ]
                CALL    mon_putc
:
                MOVE    R1, 0x20
                CALL    mon_putc
                MOVE    R10, 0
u_stmt_op
                MOVE    R1, @V_UF[R10]
                MOVE    R2, @V_UC[R10]
                MOVE    R3, 0
                TST     R10
        ?Z      MOVE    R3, 1           ; the dest
                CALL    u_op
                ADD     R10, R10, 1
                CMP     R10, @V_UNOPS
        ?Z      RET
                MOVE    R1, S_UCOMMA
                CALL    puts_b
                JMP     u_stmt_op

; u_unused: the fields that the mnemonic does not use and that are not
; R0, by name, in brackets, as nicedis.py writes them after the .DAT.
; Uses R1-R6, R10, and R11.
u_unused
                MOVE    R1, S_UOPEN
                CALL    puts_b
                MOVE    R10, @V_UNOPS
                MOVE    R11, 0          ; not 0 after the first
u_unused_f
                CMP     R10, 3
        ?Z      MOVE    R1, 0x29        ; )
        ?Z      JMP     mon_putc        ; which returns to the caller
                TST     @V_UF[R10]
        ?Z      JMP     :+
                TST     R11
        ?!Z     MOVE    R1, S_UCOMMA
        ?!Z     CALL    puts_b
                MOVE    R11, 1
                MOVE    R1, @U_FIELDS[R10]
                CALL    puts_b
                MOVE    R1, @V_UF[R10]
                MOVE    R2, @V_UC[R10]
                MOVE    R3, 0
                CALL    u_op
:
                ADD     R10, R10, 1
                JMP     u_unused_f

; u_dat: .DAT, the words from R7 up to R12 in hex, and the ; of the
; comment that says what they would do. Uses R1-R6 and R11.
u_dat
                MOVE    R1, S_UDAT
                CALL    puts_b
                MOVE    R11, R7
:
                MOVE    R1, S_U0X
                CALL    puts_b
                MOVE    R1, @R11++
                MOVE    R2, 8
                CALL    u_hex
                CMP     R11, R12
        ?Z      MOVE    R1, S_USEMI
        ?Z      JMP     puts_b          ; which returns to the caller
                MOVE    R1, S_UCOMMA
                CALL    puts_b
                JMP     :-

; u_cond: the condition of the instruction word R1 and a blank, or nothing
; for "always". Uses R1-R5.
u_cond
                SHR[M]  R5, R1, 28      ; NEG and SEL
        ?Z      RET
                MOVE    R1, 0x3F        ; ?
                CALL    mon_putc
                AND[M]  R0, R5, 8
        ?Z      JMP     :+
                MOVE    R1, 0x21        ; !
                CALL    mon_putc
:
                AND     R1, R5, 7
                MOVE    R1, @TEXT_B+4*S_UFLAGS[R1]
                CALL    mon_putc
                MOVE    R1, 0x20
                JMP     mon_putc        ; which returns to the caller

; u_op: the operand of the field R1, with its constant R2, in the syntax
; of nice_cpu's ISA.md §10.2, as nicedis.py writes it, the constant in
; lower-case hex without leading zeros. R3 is not 0 for a dest, whose
; mode 001 is Rx--, which bit 7 of R5 marks. Uses R1-R6.
u_op
                MOVE    R5, R1          ; the field
                MOVE    R6, R2          ; the constant
                TST     R3
        ?Z      JMP     :+
                AND     R4, R1, 0x70
                CMP     R4, 0x10
        ?Z      OR      R5, R5, 0x80    ; Rx--
:
                AND[M]  R0, R5, 0x40
        ?Z      JMP     :+
                MOVE    R1, 0x40        ; @
                CALL    mon_putc
:
                AND     R4, R5, 0x30
                CMP     R4, 0x30
        ?Z      JMP     u_op_const
                CMP     R4, 0x10
        ?!Z     JMP     :+
                AND[M]  R0, R5, 0x80
        ?!Z     JMP     :+
                MOVE    R1, S_UDEC      ; --Rx
                CALL    puts_b
:
                AND     R1, R5, 0xF
                CALL    u_reg
                AND     R4, R5, 0x30
                CMP     R4, 0x20
        ?Z      MOVE    R1, S_UINC      ; Rx++
        ?Z      JMP     puts_b          ; which returns to the caller
                AND[M]  R0, R5, 0x80
        ?Z      RET
                MOVE    R1, S_UDEC      ; Rx--
                JMP     puts_b
u_op_const
                MOVE    R1, S_U0X
                CALL    puts_b
                PUSH    R5
                MOVE    R1, R6
                MOVE    R2, 1
                CALL    u_hex
                AND[M]  R1, @SP++, 0xF  ; the register
        ?Z      RET                     ; R0: the constant alone
                PUSH    R1
                MOVE    R1, 0x5B        ; [
                CALL    mon_putc
                POP     R1
                CALL    u_reg
                MOVE    R1, 0x5D        ; ]
                JMP     mon_putc

; u_reg: R and the number R1 in decimal. Uses R1-R4.
u_reg
                PUSH    R1
                MOVE    R1, 0x52        ; R
                CALL    mon_putc
                POP     R1
                JMP     _io_putdec      ; which returns to the caller

; u_hex: R1 in lower-case hex, with R2 digits, 1 to 8, or more if it needs
; them, and no other leading zeros. Uses R1-R6.
u_hex
                MOVE    R5, R1
                MOVE    R6, 8           ; the digits left
:
                CMP     R6, R2
        ?Z      JMP     :+
                AND[M]  R0, R5, 0xF0000000
        ?!Z     JMP     :+
                SHL     R5, R5, 4       ; a leading zero
                SUB     R6, R6, 1
                JMP     :-
:
                ROL     R5, R5, 4       ; the top digit to the bottom
                AND     R1, R5, 0xF
                ADD     R1, R1, 0x30
                CMP     R1, 0x3A
        ?!C     ADD     R1, R1, 0x27    ; a to f
                CALL    mon_putc
                SUB[M]  R6, R6, 1
        ?!Z     JMP     :-
                RET

; The text of u: the mnemonics of the ALU instructions by opcode, and then
; the SHIFT instructions', with the aliases, and the control commands; the
; operands of each ALU mnemonic; the names of the fields; and the pieces
; of a row
U_NAMES         .DAT    U_MOVE, U_SUB, U_MDBL, U_ADD, U_DBL, U_DEC, U_NOT, U_NOR
                .DAT    U_IAND, U_NAND, U_XOR, U_IOR, U_XNOR, U_AND, U_ONE, U_OR
                .DAT    U_SHL, U_S1, U_S2, U_S3, U_S4, U_S5, U_ROL, U_BPL
                .DAT    U_SHR, U_S9, U_S10, U_S11, U_S12, U_S13, U_ROR, U_BPR
U_CTRL          .DAT    U_HALT, U_RTI, U_INT, U_WAIT
U_NOPS          .DAT    2, 3, 3, 3, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 1, 3
U_FIELDS
                .DAT    U_FDEST, U_FS0, U_FS1
DIS_KINDS
                .DAT    dis_insn, dis_cmd, dis_ret, dis_call, dis_rsvd
                .DAT    dis_pseudo, dis_pseudo, dis_pseudo, dis_pseudo
                .DAT    dis_pseudo, dis_pseudo, dis_pseudo
; The pseudo-instructions of u, in the order in which they are tried, after
; RET and CALL (README.md): the mask and the value of the instruction word
; without its condition, the name, the first field shown, and the number
; of fields shown. The masks take in the opcode and the modifiers, which
; must be 0 but for the [M] of TST and CMP, and the field that is unused,
; which must be R0.
U_PSEUDO
                .DAT    0x0FFFFFFF, 0x00000000, U_NOP, 0, 0  ; MOVE R0, R0
                .DAT    0x0FFFC07F, 0x0003C000, U_JMP, 1, 1  ; MOVE R15, s0
                .DAT    0x0FFFC07F, 0x00174000, U_PUSH, 1, 1  ; MOVE @--R13, s0
                .DAT    0x0FE03FFF, 0x00003680, U_POP, 0, 1  ; MOVE dest, @R13++
                .DAT    0x0FE03FFF, 0x00000000, U_CLR, 0, 1  ; MOVE dest, R0
                .DAT    0x0FFFC07F, 0x02000000, U_TST, 1, 1  ; MOVE[M] R0, s0
                .DAT    0x0FFFC000, 0x02200000, U_CMP, 1, 2  ; SUB[M] R0, s0, s1
U_PSEUDOS       .EQU    7
U_NOP           .ASCII_B 'NOP'
U_JMP           .ASCII_B 'JMP'
U_PUSH          .ASCII_B 'PUSH'
                .DAT    0
U_POP           .ASCII_B 'POP'
U_CLR           .ASCII_B 'CLR'
U_TST           .ASCII_B 'TST'
U_CMP           .ASCII_B 'CMP'
U_MOVE          .ASCII_B 'MOVE'
                .DAT    0
U_SUB           .ASCII_B 'SUB'
U_MDBL          .ASCII_B 'MDBL'
                .DAT    0
U_ADD           .ASCII_B 'ADD'
U_DBL           .ASCII_B 'DBL'
U_DEC           .ASCII_B 'DEC'
U_NOT           .ASCII_B 'NOT'
U_NOR           .ASCII_B 'NOR'
U_IAND          .ASCII_B 'IAND'
                .DAT    0
U_NAND          .ASCII_B 'NAND'
                .DAT    0
U_XOR           .ASCII_B 'XOR'
U_IOR           .ASCII_B 'IOR'
U_XNOR          .ASCII_B 'XNOR'
                .DAT    0
U_AND           .ASCII_B 'AND'
U_ONE           .ASCII_B 'ONE'
U_OR            .ASCII_B 'OR'
U_SHL           .ASCII_B 'SHL'
U_S1            .ASCII_B '0<1'
U_S2            .ASCII_B '0<C'
U_S3            .ASCII_B 'C<0'
U_S4            .ASCII_B 'C<1'
U_S5            .ASCII_B 'C<C'
U_ROL           .ASCII_B 'ROL'
U_BPL           .ASCII_B 'BPL'
U_SHR           .ASCII_B 'SHR'
U_S9            .ASCII_B '1>0'
U_S10           .ASCII_B 'C>0'
U_S11           .ASCII_B '0>C'
U_S12           .ASCII_B '1>C'
U_S13           .ASCII_B 'C>C'
U_ROR           .ASCII_B 'ROR'
U_BPR           .ASCII_B 'BPR'
U_HALT          .ASCII_B 'HALT'
                .DAT    0
U_RTI           .ASCII_B 'RTI'
U_INT           .ASCII_B 'INT'
U_WAIT          .ASCII_B 'WAIT'
                .DAT    0
U_FDEST         .ASCII_B 'dest: '
U_FS0           .ASCII_B 's0: '
                .DAT    0
U_FS1           .ASCII_B 's1: '
                .DAT    0
S_UFLAGS
                .ASCII_B '1XCZNVEI'
                .DAT    0
S_URET          .ASCII_B 'RET'
S_UCALL         .ASCII_B 'CALL '
S_URSVD         .ASCII_B 'reserved control word'
S_UDAT          .ASCII_B '.DAT '
S_U0X           .ASCII_B '0x'
S_USEMI         .ASCII_B ' ; '
S_UOPEN         .ASCII_B ' ('
S_UDEC          .ASCII_B '--'
S_UINC          .ASCII_B '++'
S_UBLANK
                .ASCII_B '         '
