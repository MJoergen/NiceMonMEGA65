## Pins of the MEGA65 R3 and R3A boards, as in MiSTer2MEGA65 (M2M/MEGA65-R3.xdc).

set_property -dict {PACKAGE_PIN V13  IOSTANDARD LVCMOS33} [get_ports {clk_i}];              # CLOCK_FPGA_MRCC
set_property -dict {PACKAGE_PIN L14  IOSTANDARD LVCMOS33} [get_ports {uart_rxd_i}];         # DBG_UART_RX
set_property -dict {PACKAGE_PIN L13  IOSTANDARD LVCMOS33} [get_ports {uart_txd_o}];         # DBG_UART_TX
set_property -dict {PACKAGE_PIN U22  IOSTANDARD LVCMOS33} [get_ports {led_o}];              # ULED

## The MAX10 FPGA, which reads the reset button
set_property -dict {PACKAGE_PIN L16  IOSTANDARD LVCMOS33} [get_ports {max10_clkandsync_o}]; # FPGA_TX
set_property -dict {PACKAGE_PIN K16  IOSTANDARD LVCMOS33} [get_ports {max10_rx_o}];         # FPGA_RX
set_property -dict {PACKAGE_PIN M13  IOSTANDARD LVCMOS33} [get_ports {max10_tx_i}];         # FPGA_RESET_N

## The data from the MAX10 is sampled half a cycle (20 ns) after the edge of
## the 25 MHz clock that the FPGA sends to it, so it is not timed.
set_false_path -from [get_ports {max10_tx_i}]

## The reset from the MAX10 is a register clocked by the board clock. It is
## synchronised to the system clock in clk_rst.vhd, so its paths are not
## timed.
set_false_path -from [get_cells i_max10/reset_button_reg]

## The timing of the link to the MAX10 is fragile, so the link is placed close
## to its pins, as in the C64MEGA65 core (MEGA65-R3.xdc).
create_pblock pblock_max10
add_cells_to_pblock pblock_max10 [get_cells [list i_max10]]
resize_pblock pblock_max10 -add {SLICE_X0Y150:SLICE_X7Y174}
