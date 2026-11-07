; The test of the ROM's C code, test/rom.c, which the Makefile joins to the
; ROM's module in the ROM of this test only. This program is assembled
; after it and the monitor's sources, so that it calls the functions by
; their labels, and r runs it. Each run stores the results of rom_count,
; rom_count, and rom_zero at ROMT_RESULTS + 3 n, where n is the number of
; the run, from ROMT_RUNS, which no cold start clears: 7, 8, and 0 after a
; cold start, and 9, 10, and 10 after a run without one. Then rom_hello
; prints its line, and rom_trap traps, so that the monitor's mon_trap
; prints the trap and goes back to the main loop.

                .ORG    0x8000
ROMT_RUNS       .EQU    0x9100
ROMT_RESULTS    .EQU    0x9101

romt_main
                MOVE    R7, @ROMT_RUNS
                ADD     @ROMT_RUNS, @ROMT_RUNS, 1
                SHL     R8, R7, 1
                ADD     R7, R7, R8      ; 3 n
                ADD     R7, R7, ROMT_RESULTS
                CALL    _rom_count
                MOVE    @R7++, R1
                CALL    _rom_count
                MOVE    @R7++, R1
                CALL    _rom_zero
                MOVE    @R7++, R1
                CALL    _rom_hello
                CALL    _rom_trap
                HALT                    ; never reached
