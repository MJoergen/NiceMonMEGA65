## Constraints shared by the MEGA65 boards.

## The board clock, 100 MHz. Vivado derives the 50 MHz MMCM clock from it.
create_clock -period 10.000 -name sys_clk [get_ports {clk_i}]

## The UART, the LED, and the reset button are slow, and synchronised or
## registered in the design.
set_false_path -from [get_ports {uart_rxd_i}]
set_false_path -to   [get_ports {uart_txd_o}]
set_false_path -to   [get_ports {led_o}]

## The keyboard, on the same pins on all boards (M2M/MEGA65-R3.xdc and
## MEGA65-R6.xdc). Its clock is 312.5 kHz, and its input is synchronised.
set_property -dict {PACKAGE_PIN A14  IOSTANDARD LVCMOS33} [get_ports {kb_io0_o}];  # KB_IO1
set_property -dict {PACKAGE_PIN A13  IOSTANDARD LVCMOS33} [get_ports {kb_io1_o}];  # KB_IO2
set_property -dict {PACKAGE_PIN C13  IOSTANDARD LVCMOS33} [get_ports {kb_io2_i}];  # KB_IO3
set_false_path -to   [get_ports {kb_io0_o kb_io1_o}]
set_false_path -from [get_ports {kb_io2_i}]

## Configuration from the board's quad SPI flash
set_property CONFIG_VOLTAGE                  3.3   [current_design]
set_property CFGBVS                          VCCO  [current_design]
set_property BITSTREAM.GENERAL.COMPRESS      TRUE  [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE     66    [current_design]
set_property CONFIG_MODE                     SPIx4 [current_design]
set_property BITSTREAM.CONFIG.SPI_32BIT_ADDR YES   [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH   4     [current_design]
