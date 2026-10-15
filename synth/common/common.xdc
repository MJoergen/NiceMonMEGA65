## Constraints shared by the MEGA65 boards.

## The board clock, 100 MHz. Vivado derives the 50 MHz MMCM clock from it.
create_clock -period 10.000 -name sys_clk [get_ports {clk_i}]

## The UART, the LED, and the reset button are slow, and synchronised or
## registered in the design.
set_false_path -from [get_ports {uart_rxd_i}]
set_false_path -to   [get_ports {uart_txd_o}]
set_false_path -to   [get_ports {led_o}]

## Configuration from the board's quad SPI flash
set_property CONFIG_VOLTAGE                  3.3   [current_design]
set_property CFGBVS                          VCCO  [current_design]
set_property BITSTREAM.GENERAL.COMPRESS      TRUE  [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE     66    [current_design]
set_property CONFIG_MODE                     SPIx4 [current_design]
set_property BITSTREAM.CONFIG.SPI_32BIT_ADDR YES   [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH   4     [current_design]
