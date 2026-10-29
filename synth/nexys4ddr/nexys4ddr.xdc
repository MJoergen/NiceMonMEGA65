## Constraints of the Digilent Nexys4DDR board. The pins are those of
## Digilent's Nexys-4-DDR-Master.xdc (github.com/Digilent/digilent-xdc).

set_property -dict {PACKAGE_PIN E3   IOSTANDARD LVCMOS33} [get_ports {clk_i}];      # CLK100MHZ
set_property -dict {PACKAGE_PIN C12  IOSTANDARD LVCMOS33} [get_ports {reset_n_i}];  # CPU_RESETN
set_property -dict {PACKAGE_PIN C4   IOSTANDARD LVCMOS33} [get_ports {uart_rxd_i}]; # UART_TXD_IN
set_property -dict {PACKAGE_PIN D4   IOSTANDARD LVCMOS33} [get_ports {uart_txd_o}]; # UART_RXD_OUT
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

## The LEDs, the RGB LEDs, the seven-segment display, the buttons, and
## the switches
set_property -dict {PACKAGE_PIN H17  IOSTANDARD LVCMOS33} [get_ports {led_o[0]}];  # LED[0]
set_property -dict {PACKAGE_PIN K15  IOSTANDARD LVCMOS33} [get_ports {led_o[1]}];  # LED[1]
set_property -dict {PACKAGE_PIN J13  IOSTANDARD LVCMOS33} [get_ports {led_o[2]}];  # LED[2]
set_property -dict {PACKAGE_PIN N14  IOSTANDARD LVCMOS33} [get_ports {led_o[3]}];  # LED[3]
set_property -dict {PACKAGE_PIN R18  IOSTANDARD LVCMOS33} [get_ports {led_o[4]}];  # LED[4]
set_property -dict {PACKAGE_PIN V17  IOSTANDARD LVCMOS33} [get_ports {led_o[5]}];  # LED[5]
set_property -dict {PACKAGE_PIN U17  IOSTANDARD LVCMOS33} [get_ports {led_o[6]}];  # LED[6]
set_property -dict {PACKAGE_PIN U16  IOSTANDARD LVCMOS33} [get_ports {led_o[7]}];  # LED[7]
set_property -dict {PACKAGE_PIN V16  IOSTANDARD LVCMOS33} [get_ports {led_o[8]}];  # LED[8]
set_property -dict {PACKAGE_PIN T15  IOSTANDARD LVCMOS33} [get_ports {led_o[9]}];  # LED[9]
set_property -dict {PACKAGE_PIN U14  IOSTANDARD LVCMOS33} [get_ports {led_o[10]}];  # LED[10]
set_property -dict {PACKAGE_PIN T16  IOSTANDARD LVCMOS33} [get_ports {led_o[11]}];  # LED[11]
set_property -dict {PACKAGE_PIN V15  IOSTANDARD LVCMOS33} [get_ports {led_o[12]}];  # LED[12]
set_property -dict {PACKAGE_PIN V14  IOSTANDARD LVCMOS33} [get_ports {led_o[13]}];  # LED[13]
set_property -dict {PACKAGE_PIN V12  IOSTANDARD LVCMOS33} [get_ports {led_o[14]}];  # LED[14]
set_property -dict {PACKAGE_PIN V11  IOSTANDARD LVCMOS33} [get_ports {led_o[15]}];  # LED[15]
set_property -dict {PACKAGE_PIN R12  IOSTANDARD LVCMOS33} [get_ports {rgb0_o[0]}];  # LED16_B
set_property -dict {PACKAGE_PIN M16  IOSTANDARD LVCMOS33} [get_ports {rgb0_o[1]}];  # LED16_G
set_property -dict {PACKAGE_PIN N15  IOSTANDARD LVCMOS33} [get_ports {rgb0_o[2]}];  # LED16_R
set_property -dict {PACKAGE_PIN G14  IOSTANDARD LVCMOS33} [get_ports {rgb1_o[0]}];  # LED17_B
set_property -dict {PACKAGE_PIN R11  IOSTANDARD LVCMOS33} [get_ports {rgb1_o[1]}];  # LED17_G
set_property -dict {PACKAGE_PIN N16  IOSTANDARD LVCMOS33} [get_ports {rgb1_o[2]}];  # LED17_R
set_property -dict {PACKAGE_PIN T10  IOSTANDARD LVCMOS33} [get_ports {seg_ca_o[0]}];  # CA
set_property -dict {PACKAGE_PIN R10  IOSTANDARD LVCMOS33} [get_ports {seg_ca_o[1]}];  # CB
set_property -dict {PACKAGE_PIN K16  IOSTANDARD LVCMOS33} [get_ports {seg_ca_o[2]}];  # CC
set_property -dict {PACKAGE_PIN K13  IOSTANDARD LVCMOS33} [get_ports {seg_ca_o[3]}];  # CD
set_property -dict {PACKAGE_PIN P15  IOSTANDARD LVCMOS33} [get_ports {seg_ca_o[4]}];  # CE
set_property -dict {PACKAGE_PIN T11  IOSTANDARD LVCMOS33} [get_ports {seg_ca_o[5]}];  # CF
set_property -dict {PACKAGE_PIN L18  IOSTANDARD LVCMOS33} [get_ports {seg_ca_o[6]}];  # CG
set_property -dict {PACKAGE_PIN H15  IOSTANDARD LVCMOS33} [get_ports {seg_ca_o[7]}];  # DP
set_property -dict {PACKAGE_PIN J17  IOSTANDARD LVCMOS33} [get_ports {seg_an_o[0]}];  # AN[0]
set_property -dict {PACKAGE_PIN J18  IOSTANDARD LVCMOS33} [get_ports {seg_an_o[1]}];  # AN[1]
set_property -dict {PACKAGE_PIN T9   IOSTANDARD LVCMOS33} [get_ports {seg_an_o[2]}];  # AN[2]
set_property -dict {PACKAGE_PIN J14  IOSTANDARD LVCMOS33} [get_ports {seg_an_o[3]}];  # AN[3]
set_property -dict {PACKAGE_PIN P14  IOSTANDARD LVCMOS33} [get_ports {seg_an_o[4]}];  # AN[4]
set_property -dict {PACKAGE_PIN T14  IOSTANDARD LVCMOS33} [get_ports {seg_an_o[5]}];  # AN[5]
set_property -dict {PACKAGE_PIN K2   IOSTANDARD LVCMOS33} [get_ports {seg_an_o[6]}];  # AN[6]
set_property -dict {PACKAGE_PIN U13  IOSTANDARD LVCMOS33} [get_ports {seg_an_o[7]}];  # AN[7]
set_property -dict {PACKAGE_PIN N17  IOSTANDARD LVCMOS33} [get_ports {btn_i[0]}];  # BTNC
set_property -dict {PACKAGE_PIN M18  IOSTANDARD LVCMOS33} [get_ports {btn_i[1]}];  # BTNU
set_property -dict {PACKAGE_PIN P17  IOSTANDARD LVCMOS33} [get_ports {btn_i[2]}];  # BTNL
set_property -dict {PACKAGE_PIN M17  IOSTANDARD LVCMOS33} [get_ports {btn_i[3]}];  # BTNR
set_property -dict {PACKAGE_PIN P18  IOSTANDARD LVCMOS33} [get_ports {btn_i[4]}];  # BTND
set_property -dict {PACKAGE_PIN J15  IOSTANDARD LVCMOS33} [get_ports {sw_i[0]}];  # SW[0]
set_property -dict {PACKAGE_PIN L16  IOSTANDARD LVCMOS33} [get_ports {sw_i[1]}];  # SW[1]
set_property -dict {PACKAGE_PIN M13  IOSTANDARD LVCMOS33} [get_ports {sw_i[2]}];  # SW[2]
set_property -dict {PACKAGE_PIN R15  IOSTANDARD LVCMOS33} [get_ports {sw_i[3]}];  # SW[3]
set_property -dict {PACKAGE_PIN R17  IOSTANDARD LVCMOS33} [get_ports {sw_i[4]}];  # SW[4]
set_property -dict {PACKAGE_PIN T18  IOSTANDARD LVCMOS33} [get_ports {sw_i[5]}];  # SW[5]
set_property -dict {PACKAGE_PIN U18  IOSTANDARD LVCMOS33} [get_ports {sw_i[6]}];  # SW[6]
set_property -dict {PACKAGE_PIN R13  IOSTANDARD LVCMOS33} [get_ports {sw_i[7]}];  # SW[7]
set_property -dict {PACKAGE_PIN T8   IOSTANDARD LVCMOS33} [get_ports {sw_i[8]}];  # SW[8]
set_property -dict {PACKAGE_PIN U8   IOSTANDARD LVCMOS33} [get_ports {sw_i[9]}];  # SW[9]
set_property -dict {PACKAGE_PIN R16  IOSTANDARD LVCMOS33} [get_ports {sw_i[10]}];  # SW[10]
set_property -dict {PACKAGE_PIN T13  IOSTANDARD LVCMOS33} [get_ports {sw_i[11]}];  # SW[11]
set_property -dict {PACKAGE_PIN H6   IOSTANDARD LVCMOS33} [get_ports {sw_i[12]}];  # SW[12]
set_property -dict {PACKAGE_PIN U12  IOSTANDARD LVCMOS33} [get_ports {sw_i[13]}];  # SW[13]
set_property -dict {PACKAGE_PIN U11  IOSTANDARD LVCMOS33} [get_ports {sw_i[14]}];  # SW[14]
set_property -dict {PACKAGE_PIN V10  IOSTANDARD LVCMOS33} [get_ports {sw_i[15]}];  # SW[15]

## The Ethernet PHY, an SMSC LAN8720A. It is RMII, clocked by 50 MHz from
## the FPGA on ETH_REFCLK, as on the MEGA65 (mega65.xdc). MDC and MDIO are
## left out, as no PHY register needs reading or writing, and so is ETH_INTN.
## top.vhd drives the clock and the reset, src/eth/rmii_rx.vhd takes RXD,
## CRS_DV, and RXERR, and src/eth/rmii_tx.vhd drives TXD and TXEN.
set_property -dict {PACKAGE_PIN D5   IOSTANDARD LVCMOS33} [get_ports {eth_clk_o}];    # ETH_REFCLK
set_property -dict {PACKAGE_PIN B3   IOSTANDARD LVCMOS33} [get_ports {eth_rst_n_o}];  # ETH_RSTN
set_property -dict {PACKAGE_PIN C11  IOSTANDARD LVCMOS33} [get_ports {eth_rxd_i[0]}]; # ETH_RXD[0]
set_property -dict {PACKAGE_PIN D10  IOSTANDARD LVCMOS33} [get_ports {eth_rxd_i[1]}]; # ETH_RXD[1]
set_property -dict {PACKAGE_PIN D9   IOSTANDARD LVCMOS33} [get_ports {eth_crs_dv_i}]; # ETH_CRSDV
set_property -dict {PACKAGE_PIN C10  IOSTANDARD LVCMOS33} [get_ports {eth_rxer_i}];   # ETH_RXERR
set_property -dict {PACKAGE_PIN A10  IOSTANDARD LVCMOS33} [get_ports {eth_txd_o[0]}]; # ETH_TXD[0]
set_property -dict {PACKAGE_PIN A8   IOSTANDARD LVCMOS33} [get_ports {eth_txd_o[1]}]; # ETH_TXD[1]
set_property -dict {PACKAGE_PIN B9   IOSTANDARD LVCMOS33} [get_ports {eth_tx_en_o}];  # ETH_TXEN
set_property -dict {SLEW FAST} [get_ports {eth_clk_o}]

## The board clock, 100 MHz. Vivado derives the MMCM clocks from it.
create_clock -period 10.000 -name sys_clk [get_ports {clk_i}]

## The clock on the pin, forwarded by an ODDR from the MMCM's 50 MHz, for
## the timing of the RMII pins. The PHY's reset is slow, and its register is
## in the I/O tile.
create_generated_clock -name eth_clk_pin -divide_by 1 \
   -source [get_pins i_eth_clk/C] [get_ports {eth_clk_o}]
set_false_path -to [get_ports {eth_rst_n_o}]
set_property IOB TRUE [get_ports {eth_rst_n_o}]

## The LAN8720A, in REF_CLK In mode, drives RXD, CRS_DV, and RXER 3 to 14 ns
## after the clock's rising edge (toval and tohold, section 5.5.4.2 of its
## data sheet, DS00002165B), and the maximum has 1 ns more for the two
## traces. Their registers are in the I/O tiles.
set_input_delay -clock eth_clk_pin -max 15.000 [get_ports {eth_rxd_i[*] eth_crs_dv_i eth_rxer_i}]
set_input_delay -clock eth_clk_pin -min  3.000 [get_ports {eth_rxd_i[*] eth_crs_dv_i eth_rxer_i}]
set_property IOB TRUE [get_ports {eth_rxd_i[*] eth_crs_dv_i eth_rxer_i}]

## The clock on the pin rises 2.5 ns before the clock inside (clk_rst.vhd),
## so the data of one of its edges is sampled by the second edge inside
## after it, a cycle and 2.5 ns later, and held past the first.
set_multicycle_path -setup 2 -from [get_clocks eth_clk_pin] \
   -to [get_clocks -of_objects [get_pins i_clk_rst/i_mmcm/CLKOUT1]]

## The LAN8720A takes TXD and TXEN with a setup time of 4 ns and a hold
## time of 1.5 ns to the clock's rising edge (tsu and tihold, Table 5-11 of
## its data sheet, DS00002165C), and the setup has 1 ns more for the
## traces. Their registers are in the I/O tiles, as on the MEGA65.
set_output_delay -clock eth_clk_pin -max  5.000 [get_ports {eth_txd_o[*] eth_tx_en_o}]
set_output_delay -clock eth_clk_pin -min -1.500 [get_ports {eth_txd_o[*] eth_tx_en_o}]
set_property IOB TRUE [get_ports {eth_txd_o[*] eth_tx_en_o}]

## The system clock and the video clocks cross only through the screen's
## copy and the handshake of src/video/text.vhd, as on the MEGA65
## (mega65.xdc). The relation between the clocks is ignored, and each path
## only has to be shorter than 10 ns, in both directions. That is the period
## of the 100 MHz board clock, a little less than one of the 90 MHz system
## clock (11.1 ns), and a little more than one of the 108 MHz VGA clock
## (9.26 ns).
set_max_delay -datapath_only \
   -from [get_clocks -of_objects [get_pins i_clk_rst/i_mmcm/CLKOUT0]] \
   -to   [get_clocks -of_objects [get_pins i_video_clk/i_mmcm/CLKOUT0]] 10.000
set_max_delay -datapath_only \
   -from [get_clocks -of_objects [get_pins i_video_clk/i_mmcm/CLKOUT0]] \
   -to   [get_clocks -of_objects [get_pins i_clk_rst/i_mmcm/CLKOUT0]] 10.000

## The Ethernet clock (CLKOUT1 of the system clock's MMCM) and the system
## clock cross only through synchronizers: the PHY's reset in clk_rst.vhd,
## and in src/eth/ the toggle of the bad frames, the read pointers of the
## FIFOs in Gray code, and their committed pointers, which are stable when
## they are read. Their relation is ignored, and each path only has to be
## shorter than 10 ns, in both directions, as for the video clocks. The
## read pointer of eth_rx_fifo.vhd can change every 20 ns, a period of the
## Ethernet clock, so its Gray code relies on this bound.
set_max_delay -datapath_only \
   -from [get_clocks -of_objects [get_pins i_clk_rst/i_mmcm/CLKOUT0]] \
   -to   [get_clocks -of_objects [get_pins i_clk_rst/i_mmcm/CLKOUT1]] 10.000
set_max_delay -datapath_only \
   -from [get_clocks -of_objects [get_pins i_clk_rst/i_mmcm/CLKOUT1]] \
   -to   [get_clocks -of_objects [get_pins i_clk_rst/i_mmcm/CLKOUT0]] 10.000

## The color and sync outputs are registered in the IOBs (p_vga in
## top.vhd), so they all change at the same time.
set_property IOB TRUE [get_ports {vga_red_o[*] vga_green_o[*] vga_blue_o[*] vga_hs_o vga_vs_o}]

## The UART, the LEDs, the display, the keyboard, the buttons, the switches,
## and the reset button are slow, and synchronized or registered in the
## design. Their first registers are in the I/O tiles, so that their timing
## does not depend on placement. The reset button is not inverted before its
## first register (synth/common/clk_rst.vhd), so that register is one too.
set_false_path -from [get_ports {uart_rxd_i reset_n_i ps2_clk_i ps2_data_i btn_i[*] sw_i[*]}]
set_false_path -to   [get_ports {uart_txd_o led_o[*] rgb0_o[*] rgb1_o[*] seg_an_o[*] seg_ca_o[*]}]
## The first IOB group is the UART, the reset button, the LEDs, and the
## PS/2 keyboard, and the second is the RGB LEDs, the seven-segment display,
## the buttons, and the switches. Both are set the same way; the split is
## only in how the lines are written.
set_property IOB TRUE [get_ports {uart_txd_o uart_rxd_i reset_n_i led_o[*] ps2_clk_i ps2_data_i}]
set_property IOB TRUE [get_ports {rgb0_o[*] rgb1_o[*] seg_an_o[*] seg_ca_o[*] btn_i[*] sw_i[*]}]

## Configuration from the board's quad SPI flash. CONFIGRATE is the
## configuration clock in MHz.
set_property CONFIG_VOLTAGE                3.3   [current_design]
set_property CFGBVS                        VCCO  [current_design]
set_property BITSTREAM.GENERAL.COMPRESS    TRUE  [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE   33    [current_design]
set_property CONFIG_MODE                   SPIx4 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4     [current_design]
