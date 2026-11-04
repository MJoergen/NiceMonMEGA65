; The words that test/dis.py disassembles with the monitor's u, at 0x8000,
; to compare its rows with nicedis.py's text, and its rows of
; pseudo-instructions with niceasm. It is never run. It has every ALU and
; SHIFT opcode, every operand mode in each field, every condition, the
; modifiers, the control instructions, the reserved control words, unused
; fields that are not R0, the pairs that are CALL and RET and those that
; are not, and the words of the other pseudo-instructions, NOP, JMP, PUSH,
; POP, CLR, TST, and CMP, and those that are not. They are written as
; instructions, as the words are what u is tested on.

                .ORG    0x8000
; The ALU opcodes
target          MOVE    R1, R2
                SUB     R3, R4, R5
                MDBL    R6, R7, R8
                ADD     R9, R10, R11
                DBL     R12, R13
                DEC     R14, R15
                NOT     R0, R1
                NOR     R1, R2, R3
                IAND    R1, R2, R3
                NAND    R1, R2, R3
                XOR     R1, R2, R3
                IOR     R1, R2, R3
                XNOR    R1, R2, R3
                AND     R1, R2, R3
                ONE     R1
                OR      R1, R2, R3
; The SHIFT opcodes, with the aliases, and counts in each mode
                SHL     R1, R2, 1
                0<1     R1, R2, R3
                0<C     R1, R2, R3
                C<0     R1, R2, R3
                C<1     R1, R2, R3
                C<C     R1, R2, R3
                ROL     R1, R2, 0x1F
                BPL     R1, R2, R3
                SHR     R1, R2, 31
                1>0     R1, R2, @R3
                C>0     R1, R2, --R3
                0>C     R1, R2, R3++
                1>C     R1, R2, @--R3
                C>C     R1, R2, @R3++
                ROR     R1, R2, 4[R3]
                BPR     R1, R2, @4[R3]
; The modes of dest
                MOVE    R1, R2
                MOVE    R1--, R2
                MOVE    R1++, R2
                MOVE    0x10[R1], R2
                MOVE    @R1, R2
                MOVE    @--R1, R2
                MOVE    @R1++, R2
                MOVE    @0x10[R1], R2
                MOVE    @0x0, R2
; The modes of s0, with the constants in hex without leading zeros
                MOVE    R1, R2
                MOVE    R1, --R2
                MOVE    R1, R2++
                MOVE    R1, 0x12345678[R2]
                MOVE    R1, @R2
                MOVE    R1, @--R2
                MOVE    R1, @R2++
                MOVE    R1, @0xABCDEF[R2]
                MOVE    R1, 0
                MOVE    R1, 0xFFFFFFFF
; The modes of s1, and the registers R10 to R15
                ADD     R10, R11, R12
                ADD     R13, R14, --R15
                ADD     R1, R2, R3++
                ADD     R1, R2, 0x100[R13]
                ADD     R1, R2, @R14
                ADD     R1, R2, @--R13
                ADD     R1, R2, @R15++
                ADD     R1, R2, @0x7FFF[R12]
; Four words: constants for dest, s0, and s1
                ADD     @0x100[R1], 0x12345678[R2], @0xABC
                SUB     @0xFFFFFF00, @0xFFFFFF01, 3
; The conditions
        ?1      MOVE    R1, R2
        ?X      MOVE    R1, R2
        ?C      MOVE    R1, R2
        ?Z      MOVE    R1, R2
        ?N      MOVE    R1, R2
        ?V      MOVE    R1, R2
        ?E      MOVE    R1, R2
        ?I      MOVE    R1, R2
        ?!1     MOVE    R1, R2
        ?!X     MOVE    R1, R2
        ?!C     MOVE    R1, R2
        ?!Z     MOVE    R1, R2
        ?!N     MOVE    R1, R2
        ?!V     MOVE    R1, R2
        ?!E     MOVE    R1, R2
        ?!I     MOVE    R1, R2
; The modifiers
                ADD[C]  R1, R2, R3
                SUB[M]  R0, R1, 0x20
                ADD[CM] R1, R2, R3
        ?!C     SUB[CM] R1, R2, R3
                SHL[M]  R1, R2, 1
                MOVE[M] R0, @R1
; The control instructions
                HALT
                RTI
                INT     0
                INT     255
        ?Z      INT     7
        ?!E     HALT
; The reserved control words: a command past INT, a bit of 20..8, a
; vector of HALT and of RTI, and command 31 with a condition
                .DAT    0x0C600000
                .DAT    0x0C000100
                .DAT    0x0C000005
                .DAT    0x0C200001
                .DAT    0x8FE00000
; The unused fields that are not R0: s1 of MOVE, with and without a
; constant, s1 of DEC, s0 and s1 of ONE, and s1 of NOT after a constant of
; dest
                .DAT    0x00000001
                .DAT    0x00000030, 5
                .DAT    0x00A00053
                .DAT    0x01C04082
                .DAT    0x00DFC030, 0x10, 0x20
; CALL and RET
                CALL    target
        ?Z      CALL    target
        ?!N     CALL    R7
                CALL    @R7
                CALL    @0x10[R3]
                CALL    0x12345678[R1]
                RET
        ?C      RET
        ?!1     RET
; Pairs that are no CALL: another condition; ADD with [M], with [C]; an n
; that is not the words of the MOVE, both ways; a MOVE with [M], one to
; R14, and one with s1 not R0, which is a .DAT
        ?Z      ADD     @--R13, 2, R15
        ?!Z     MOVE    R15, target
                ADD[M]  @--R13, 2, R15
                MOVE    R15, target
                ADD[C]  @--R13, 2, R15
                MOVE    R15, target
                ADD     @--R13, 1, R15
                MOVE    R15, 0x8123
                ADD     @--R13, 2, R15
                MOVE    R15, R7
                ADD     @--R13, 2, R15
                MOVE[M] R15, target
                ADD     @--R13, 2, R15
                MOVE    R14, target
                ADD     @--R13, 2, R15
                .DAT    0x0003D801, target
; Words that are no RET: MOVE with [M], and with s0 @R12++
                MOVE[M] R15, @R13++
                MOVE    R15, @R12++
; The other pseudo-instructions, with a register, a constant, a memory
; operand, and a condition each
                MOVE    R0, R0          ; NOP, the word 0
        ?Z      MOVE    R0, R0
                MOVE    R15, R3         ; JMP
                MOVE    R15, @R3++
                MOVE    R15, @0x10[R3]
        ?!C     MOVE    R15, 0x8000
                MOVE    @--R13, R1      ; PUSH
                MOVE    @--R13, 0x12345678
                MOVE    @--R13, @0x10[R3]
        ?N      MOVE    @--R13, @R2
                MOVE    R1, @R13++      ; POP
                MOVE    @R2++, @R13++
                MOVE    @0x10[R3], @R13++
        ?!V     MOVE    @R2, @R13++
                MOVE    R1, R0          ; CLR
                MOVE    @R2++, R0
                MOVE    @0x10[R3], R0
        ?X      MOVE    R1--, R0
                MOVE[M] R0, R1          ; TST
                MOVE[M] R0, 0x12345678
                MOVE[M] R0, @0x10[R3]
        ?!Z     MOVE[M] R0, @--R2
                SUB[M]  R0, R1, R2      ; CMP
                SUB[M]  R0, R1, 0x20
                SUB[M]  R0, 0x12345678, @0x10[R3]
        ?C      SUB[M]  R0, @R1++, @R2
; The words of two forms, which are the first in the order of the README:
; NOP, not CLR R0; RET, not POP R15 or JMP @R13++; JMP R0, not CLR R15;
; PUSH R0, not CLR @--R13; and PUSH @R13++, not POP @--R13
                MOVE    R0, R0
                MOVE    R15, @R13++
                MOVE    R15, R0
                MOVE    @--R13, R0
                MOVE    @--R13, @R13++
; Near-misses, which stay instructions: [C], [M], and [CM] on the MOVE and
; SUB of each; TST and CMP with a dest that is not R0; and unused fields
; that are not R0, which are a .DAT
                MOVE[C] R15, R1
                MOVE[M] R15, R1
                MOVE[C] @--R13, R1
                MOVE[M] R1, @R13++
                MOVE[CM] R1, R0
                MOVE[C] R0, R0
                MOVE[C] R0, R1
                MOVE[CM] R0, R1
                SUB[C]  R0, R1, R2
                SUB[CM] R0, R1, R2
                SUB     R0, R1, R2
                MOVE[M] R1, R2
                MOVE[M] @R0, R2
                SUB[M]  R1, R2, R3
                SUB[M]  @R0, R2, R3
                .DAT    0x0003C001      ; MOVE R15, R0 with s1 R1
                .DAT    0x00174081      ; MOVE @--R13, R1 with s1 R1
                .DAT    0x00003681      ; MOVE R0, @R13++ with s1 R1
                .DAT    0x00004002      ; MOVE R1, R0 with s1 R2
                .DAT    0x00000003      ; MOVE R0, R0 with s1 R3
                .DAT    0x02000101      ; MOVE[M] R0, R2 with s1 R1
; A CALL whose MOVE is the last instruction
                ADD     @--R13, 2, R15
                MOVE    R15, target
