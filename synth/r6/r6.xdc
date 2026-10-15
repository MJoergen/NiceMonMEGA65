## Pins of the MEGA65 R6 board, as in MiSTer2MEGA65 (M2M/MEGA65-R6.xdc).

set_property -dict {PACKAGE_PIN V13  IOSTANDARD LVCMOS33} [get_ports {clk_i}];          # CLOCK_FPGA_MRCC
set_property -dict {PACKAGE_PIN J19  IOSTANDARD LVCMOS33} [get_ports {reset_button_i}]; # RESET
set_property -dict {PACKAGE_PIN L14  IOSTANDARD LVCMOS33} [get_ports {uart_rxd_i}];     # DBG_UART_RX
set_property -dict {PACKAGE_PIN L13  IOSTANDARD LVCMOS33} [get_ports {uart_txd_o}];     # DBG_UART_TX
set_property -dict {PACKAGE_PIN U22  IOSTANDARD LVCMOS33} [get_ports {led_o}];          # ULED

set_false_path -from [get_ports {reset_button_i}]
