; Sums the terms (sqrt(k) * k - 1) / k for k = 1, 2, and so on, without
; end, on the floating-point unit (nice_cpu's DEVICES.md §11), for the
; checks of the FPU (tools/hwtest.py, test_fpu). As it starts, it stores
; FPU_STATUS at FIRST: a start resets the FPU, so that is 0x00080000, the
; status of an empty stack. At LOOP, R1 is the number of terms summed, and
; the FPU holds their sum and nothing else. Within the loop it holds one
; or two values more.
FPU_X_W         .EQU    0xFFFFFF8B
FPU_CMD         .EQU    0xFFFFFF8C
FPU_STATUS      .EQU    0xFFFFFF8D
FIRST           .EQU    0x100

                MOVE    @FIRST, @FPU_STATUS
                MOVE    @FPU_X_W, 0     ; the sum
                MOVE    R1, 0
LOOP            ADD     R1, R1, 1
                MOVE    @FPU_X_W, R1
                MOVE    @FPU_CMD, 0x14  ; SQRT
                MOVE    @FPU_X_W, R1
                MOVE    @FPU_CMD, 0x12  ; MUL: sqrt(k) * k
                MOVE    @FPU_X_W, 1
                MOVE    @FPU_CMD, 0x11  ; SUB: less 1
                MOVE    @FPU_X_W, R1
                MOVE    @FPU_CMD, 0x13  ; DIV: by k
                MOVE    @FPU_CMD, 0x10  ; ADD: to the sum
                JMP     LOOP
