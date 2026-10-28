## Constraints shared by the MEGA65 boards.

## The board clock, 100 MHz. Vivado derives the 100 MHz MMCM clock from it.
create_clock -period 10.000 -name sys_clk [get_ports {clk_i}]

## The video clocks come from an MMCM of their own (video_clk.vhd). What
## crosses between them and the system clock is the copy of the screen in
## src/video/scr_ram.vhd, a block RAM written on the system clock and read on
## the VGA clock, and the screen's registers, through a handshake in
## src/video/text.vhd, whose values are held while they cross. The handshake
## is correct by design, but its multi-bit data paths (cur_x_r, cur_y_r,
## cur_mode_r, offs_r to the *_vga registers) would show a slow route only as
## a wrong offset for one frame. So the relation between the clocks is
## ignored, and each path only has to be shorter than 10 ns, in both
## directions. That is one period of the 100 MHz system clock, and a little
## more than one of the 108 MHz VGA clock (9.26 ns).
set_max_delay -datapath_only \
   -from [get_clocks -of_objects [get_pins i_mega65/i_clk_rst/i_mmcm/CLKOUT0]] \
   -to   [get_clocks -of_objects [get_pins {i_mega65/i_video_clk/i_mmcm/CLKOUT0 i_mega65/i_video_clk/i_mmcm/CLKOUT1}]] 10.000
set_max_delay -datapath_only \
   -from [get_clocks -of_objects [get_pins {i_mega65/i_video_clk/i_mmcm/CLKOUT0 i_mega65/i_video_clk/i_mmcm/CLKOUT1}]] \
   -to   [get_clocks -of_objects [get_pins i_mega65/i_clk_rst/i_mmcm/CLKOUT0]] 10.000

## The color and sync outputs to the video DAC are registered in the IOBs
## (p_vdac in mega65.vhd), so they all change at the same time, half a VGA
## clock cycle before the DAC samples them. The HDMI outputs are OSERDES and
## the DAC clock an ODDR, which are in the IOBs anyway.
set_property IOB TRUE [get_ports {vga_red_o[*] vga_green_o[*] vga_blue_o[*] vga_hs_o vga_vs_o}]

## The UART, the LED, and the reset button are slow, and synchronized or
## registered in the design.
set_false_path -from [get_ports {uart_rxd_i}]
set_false_path -to   [get_ports {uart_txd_o}]
set_false_path -to   [get_ports {led_o}]

## The keyboard, on the same pins on all boards (M2M/MEGA65-R3.xdc and
## MEGA65-R6.xdc). Its clock is 312.5 kHz, and its input is synchronized.
set_property -dict {PACKAGE_PIN A14  IOSTANDARD LVCMOS33} [get_ports {kb_io0_o}];  # KB_IO1
set_property -dict {PACKAGE_PIN A13  IOSTANDARD LVCMOS33} [get_ports {kb_io1_o}];  # KB_IO2
set_property -dict {PACKAGE_PIN C13  IOSTANDARD LVCMOS33} [get_ports {kb_io2_i}];  # KB_IO3
set_false_path -to   [get_ports {kb_io0_o kb_io1_o}]
set_false_path -from [get_ports {kb_io2_i}]

## The Ethernet PHY (U4 = KSZ8081RNDCA), on the same pins on the R3 and R6
## (M2M/MEGA65-R3.xdc and MEGA65-R6.xdc). It is RMII, clocked by 50 MHz from
## the FPGA on ETH_CLK. MDC and MDIO are left out, as no PHY register needs
## reading or writing, and so are ETH_INT and ETH_LED2. Until there is a MAC,
## top.vhd holds the PHY in reset, so these pins are not timed yet.
set_property -dict {PACKAGE_PIN L4   IOSTANDARD LVCMOS33} [get_ports {eth_clk_o}];    # ETH_CLK
set_property -dict {PACKAGE_PIN K6   IOSTANDARD LVCMOS33} [get_ports {eth_rst_n_o}];  # ETH-RST
set_property -dict {PACKAGE_PIN P4   IOSTANDARD LVCMOS33} [get_ports {eth_rxd_i[0]}]; # ETH_RX_D0
set_property -dict {PACKAGE_PIN L1   IOSTANDARD LVCMOS33} [get_ports {eth_rxd_i[1]}]; # ETH_RX_D1
set_property -dict {PACKAGE_PIN K4   IOSTANDARD LVCMOS33} [get_ports {eth_crs_dv_i}]; # ETH_CRS_DV
set_property -dict {PACKAGE_PIN M6   IOSTANDARD LVCMOS33} [get_ports {eth_rxer_i}];   # ETH_RXER
set_property -dict {PACKAGE_PIN L3   IOSTANDARD LVCMOS33} [get_ports {eth_txd_o[0]}]; # ETH_TX_D0
set_property -dict {PACKAGE_PIN K3   IOSTANDARD LVCMOS33} [get_ports {eth_txd_o[1]}]; # ETH_TX_D1
set_property -dict {PACKAGE_PIN J4   IOSTANDARD LVCMOS33} [get_ports {eth_tx_en_o}];  # ETH_TX_EN
set_property -dict {SLEW SLOW DRIVE 4} [get_ports {eth_txd_o[*] eth_tx_en_o}]
set_property -dict {SLEW FAST}         [get_ports {eth_clk_o}]

## The registers on the slow pins live in the I/O tiles, so that their
## timing does not depend on placement.
set_property IOB TRUE [get_ports {kb_io0_o kb_io1_o kb_io2_i uart_txd_o uart_rxd_i led_o}]

## Configuration from the board's quad SPI flash. CONFIGRATE is the
## configuration clock in MHz, and SPI_32BIT_ADDR makes the FPGA address the
## flash with 32 bits, as a flash of more than 16 MB needs.
set_property CONFIG_VOLTAGE                  3.3   [current_design]
set_property CFGBVS                          VCCO  [current_design]
set_property BITSTREAM.GENERAL.COMPRESS      TRUE  [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE     66    [current_design]
set_property CONFIG_MODE                     SPIx4 [current_design]
set_property BITSTREAM.CONFIG.SPI_32BIT_ADDR YES   [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH   4     [current_design]
