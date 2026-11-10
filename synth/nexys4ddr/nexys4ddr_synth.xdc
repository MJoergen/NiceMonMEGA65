## The constraints of the Nexys4DDR that only synthesis reads
## (USED_IN_IMPLEMENTATION false, synth/Makefile.inc): they name cells of
## the design before synthesis, which no longer exist after it.

## Without these, Vivado (2025.1) makes distributed RAM of two memories of
## nice_cpu's devices on this board, where the MEGA65 has block RAM: the
## port for Ethernet frames' queue and send buffer (eth_regs.vhd), and the
## SD card controller's buffer (sd_regs.vhd). The local memories carry a
## ram_style attribute instead (issue #103).
set_property RAM_STYLE block [get_cells -hier -filter {NAME =~ */i_eth_regs/rx_ram_reg}]
set_property RAM_STYLE block [get_cells -hier -filter {NAME =~ */i_eth_regs/tx_ram_reg}]
set_property RAM_STYLE block [get_cells -hier -filter {NAME =~ */i_sd_regs/*lane_ram_reg}]
