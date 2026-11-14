; The stubs of the entries that take a pointer, for a C program alone
; (README.md, "The dispatch table", and mon.h). A C pointer is a byte
; offset into the wasm module's memory, which starts at the word
; ___wasm_memory, so each stub adds the address of that memory in a
; window of nice_cpu's SYSTEM.md §9 to the pointer and jumps to the entry:
; 0x20000000 + 4 ___wasm_memory, of the byte window, to a pointer to
; bytes, and 0x10000000 + 4 ___wasm_memory, of the word window, to a
; pointer to words. The C code cannot name ___wasm_memory itself, as
; nicebuild.py links it with --allow-undefined, which makes the symbol 0
; with no error. mon.h gives each stub its C name, with import_name: a
; call of tcp_send is a call of _c_tcp_send.
;
; A C program is built with nicebuild.py --monitor --asm mon.nasm --asm
; mon_c.nasm. An assembly program, which has no ___wasm_memory, does not
; join this file, and calls the stubs of mon.nasm with the addresses of
; the windows.

_c_net_config
                ADD     R1, R1, 0x10000000+4*___wasm_memory
                JMP     NET_CONFIG
_c_net_set
                ADD     R1, R1, 0x10000000+4*___wasm_memory
                JMP     NET_SET
_c_dns_lookup
                ADD     R1, R1, 0x20000000+4*___wasm_memory
                ADD     R2, R2, 0x10000000+4*___wasm_memory
                JMP     DNS_LOOKUP
_c_tcp_open
                ADD     R1, R1, 0x10000000+4*___wasm_memory
                JMP     TCP_OPEN
_c_tcp_send
                ADD     R2, R2, 0x20000000+4*___wasm_memory
                JMP     TCP_SEND
_c_tcp_recv
                ADD     R2, R2, 0x20000000+4*___wasm_memory
                JMP     TCP_RECV
_c_tcp_listen
                ADD     R1, R1, 0x10000000+4*___wasm_memory
                JMP     TCP_LISTEN
