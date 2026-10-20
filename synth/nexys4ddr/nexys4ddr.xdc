## Constraints of the Digilent Nexys4DDR board. The pins are those of
## Digilent's Nexys-4-DDR-Master.xdc (github.com/Digilent/digilent-xdc).

set_property -dict {PACKAGE_PIN E3   IOSTANDARD LVCMOS33} [get_ports {clk_i}];      # CLK100MHZ
set_property -dict {PACKAGE_PIN C12  IOSTANDARD LVCMOS33} [get_ports {reset_n_i}];  # CPU_RESETN
set_property -dict {PACKAGE_PIN C4   IOSTANDARD LVCMOS33} [get_ports {uart_rxd_i}]; # UART_TXD_IN
set_property -dict {PACKAGE_PIN D4   IOSTANDARD LVCMOS33} [get_ports {uart_txd_o}]; # UART_RXD_OUT
set_property -dict {PACKAGE_PIN H17  IOSTANDARD LVCMOS33} [get_ports {led_o}];      # LED[0]
set_property -dict {PACKAGE_PIN F4   IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {ps2_clk_i}];  # PS2_CLK
set_property -dict {PACKAGE_PIN B2   IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {ps2_data_i}]; # PS2_DATA

set_property -dict {PACKAGE_PIN A3   IOSTANDARD LVCMOS33} [get_ports {vga_red_o[0]}];   # VGA_R[0]
set_property -dict {PACKAGE_PIN B4   IOSTANDARD LVCMOS33} [get_ports {vga_red_o[1]}];   # VGA_R[1]
set_property -dict {PACKAGE_PIN C5   IOSTANDARD LVCMOS33} [get_ports {vga_red_o[2]}];   # VGA_R[2]
set_property -dict {PACKAGE_PIN A4   IOSTANDARD LVCMOS33} [get_ports {vga_red_o[3]}];   # VGA_R[3]
set_property -dict {PACKAGE_PIN C6   IOSTANDARD LVCMOS33} [get_ports {vga_green_o[0]}]; # VGA_G[0]
set_property -dict {PACKAGE_PIN A5   IOSTANDARD LVCMOS33} [get_ports {vga_green_o[1]}]; # VGA_G[1]
set_property -dict {PACKAGE_PIN B6   IOSTANDARD LVCMOS33} [get_ports {vga_green_o[2]}]; # VGA_G[2]
set_property -dict {PACKAGE_PIN A6   IOSTANDARD LVCMOS33} [get_ports {vga_green_o[3]}]; # VGA_G[3]
set_property -dict {PACKAGE_PIN B7   IOSTANDARD LVCMOS33} [get_ports {vga_blue_o[0]}];  # VGA_B[0]
set_property -dict {PACKAGE_PIN C7   IOSTANDARD LVCMOS33} [get_ports {vga_blue_o[1]}];  # VGA_B[1]
set_property -dict {PACKAGE_PIN D7   IOSTANDARD LVCMOS33} [get_ports {vga_blue_o[2]}];  # VGA_B[2]
set_property -dict {PACKAGE_PIN D8   IOSTANDARD LVCMOS33} [get_ports {vga_blue_o[3]}];  # VGA_B[3]
set_property -dict {PACKAGE_PIN B11  IOSTANDARD LVCMOS33} [get_ports {vga_hs_o}];       # VGA_HS
set_property -dict {PACKAGE_PIN B12  IOSTANDARD LVCMOS33} [get_ports {vga_vs_o}];       # VGA_VS

## The board clock, 100 MHz. Vivado derives the MMCM clocks from it.
create_clock -period 10.000 -name sys_clk [get_ports {clk_i}]

## The system clock and the video clocks cross only through the screen's
## copy and the handshake of src/video/text.vhd, as on the MEGA65
## (mega65.xdc), so there is no path between them to time.
set_clock_groups -asynchronous \
   -group [get_clocks -of_objects [get_pins i_clk_rst/i_mmcm/CLKOUT0]] \
   -group [get_clocks -of_objects [get_pins i_video_clk/i_mmcm/CLKOUT0]]

## The colour and sync outputs are registered in the IOBs (p_vga in
## top.vhd), so they all change at the same time.
set_property IOB TRUE [get_ports {vga_red_o[*] vga_green_o[*] vga_blue_o[*] vga_hs_o vga_vs_o}]

## The UART, the LED, the keyboard, and the reset button are slow, and
## synchronised or registered in the design. The registers of the UART, the
## LED, and the keyboard are in the I/O tiles, so that their timing does not
## depend on placement; that of the button is not, as the button is inverted
## first.
set_false_path -from [get_ports {uart_rxd_i reset_n_i ps2_clk_i ps2_data_i}]
set_false_path -to   [get_ports {uart_txd_o led_o}]
set_property IOB TRUE [get_ports {uart_txd_o uart_rxd_i led_o ps2_clk_i ps2_data_i}]

## Configuration from the board's quad SPI flash
set_property CONFIG_VOLTAGE                3.3   [current_design]
set_property CFGBVS                        VCCO  [current_design]
set_property BITSTREAM.GENERAL.COMPRESS    TRUE  [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE   33    [current_design]
set_property CONFIG_MODE                   SPIx4 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4     [current_design]
