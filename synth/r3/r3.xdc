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
## synchronized to the system clock in clk_rst.vhd, so its paths are not
## timed.
set_false_path -from [get_cells i_max10/reset_button_reg]

## The outputs to the MAX10 are plain registers in max10.vhd, so they are
## placed in the I/O tiles.
set_property IOB TRUE [get_ports {max10_clkandsync_o max10_rx_o}]

## The timing of the link to the MAX10 is fragile, so the link is placed close
## to its pins, in the region of slices X0Y150 to X7Y174, as in the
## C64MEGA65 core (MEGA65-R3.xdc).
create_pblock pblock_max10
add_cells_to_pblock pblock_max10 [get_cells [list i_max10]]
resize_pblock pblock_max10 -add {SLICE_X0Y150:SLICE_X7Y174}

## The video DAC (U3 = ADV7125BCPZ170) and the HDMI output, as in
## MandelbrotMEGA65 (mega65-r3.xdc).
set_property -dict {PACKAGE_PIN W11  IOSTANDARD LVCMOS33} [get_ports {vdac_blank_n_o}];         # VDAC_BLANK_N
set_property -dict {PACKAGE_PIN AA9  IOSTANDARD LVCMOS33} [get_ports {vdac_clk_o}];             # VDAC_CLK
set_property -dict {PACKAGE_PIN V10  IOSTANDARD LVCMOS33} [get_ports {vdac_sync_n_o}];          # VDAC_SYNC_N
set_property -dict {PACKAGE_PIN W10  IOSTANDARD LVCMOS33} [get_ports {vga_blue_o[0]}];          # B0
set_property -dict {PACKAGE_PIN Y12  IOSTANDARD LVCMOS33} [get_ports {vga_blue_o[1]}];          # B1
set_property -dict {PACKAGE_PIN AB12 IOSTANDARD LVCMOS33} [get_ports {vga_blue_o[2]}];          # B2
set_property -dict {PACKAGE_PIN AA11 IOSTANDARD LVCMOS33} [get_ports {vga_blue_o[3]}];          # B3
set_property -dict {PACKAGE_PIN AB11 IOSTANDARD LVCMOS33} [get_ports {vga_blue_o[4]}];          # B4
set_property -dict {PACKAGE_PIN Y11  IOSTANDARD LVCMOS33} [get_ports {vga_blue_o[5]}];          # B5
set_property -dict {PACKAGE_PIN AB10 IOSTANDARD LVCMOS33} [get_ports {vga_blue_o[6]}];          # B6
set_property -dict {PACKAGE_PIN AA10 IOSTANDARD LVCMOS33} [get_ports {vga_blue_o[7]}];          # B7
set_property -dict {PACKAGE_PIN Y14  IOSTANDARD LVCMOS33} [get_ports {vga_green_o[0]}];         # G0
set_property -dict {PACKAGE_PIN W14  IOSTANDARD LVCMOS33} [get_ports {vga_green_o[1]}];         # G1
set_property -dict {PACKAGE_PIN AA15 IOSTANDARD LVCMOS33} [get_ports {vga_green_o[2]}];         # G2
set_property -dict {PACKAGE_PIN AB15 IOSTANDARD LVCMOS33} [get_ports {vga_green_o[3]}];         # G3
set_property -dict {PACKAGE_PIN Y13  IOSTANDARD LVCMOS33} [get_ports {vga_green_o[4]}];         # G4
set_property -dict {PACKAGE_PIN AA14 IOSTANDARD LVCMOS33} [get_ports {vga_green_o[5]}];         # G5
set_property -dict {PACKAGE_PIN AA13 IOSTANDARD LVCMOS33} [get_ports {vga_green_o[6]}];         # G6
set_property -dict {PACKAGE_PIN AB13 IOSTANDARD LVCMOS33} [get_ports {vga_green_o[7]}];         # G7
set_property -dict {PACKAGE_PIN W12  IOSTANDARD LVCMOS33} [get_ports {vga_hs_o}];               # HSYNC
set_property -dict {PACKAGE_PIN U15  IOSTANDARD LVCMOS33} [get_ports {vga_red_o[0]}];           # R0
set_property -dict {PACKAGE_PIN V15  IOSTANDARD LVCMOS33} [get_ports {vga_red_o[1]}];           # R1
set_property -dict {PACKAGE_PIN T14  IOSTANDARD LVCMOS33} [get_ports {vga_red_o[2]}];           # R2
set_property -dict {PACKAGE_PIN Y17  IOSTANDARD LVCMOS33} [get_ports {vga_red_o[3]}];           # R3
set_property -dict {PACKAGE_PIN Y16  IOSTANDARD LVCMOS33} [get_ports {vga_red_o[4]}];           # R4
set_property -dict {PACKAGE_PIN AB17 IOSTANDARD LVCMOS33} [get_ports {vga_red_o[5]}];           # R5
set_property -dict {PACKAGE_PIN AA16 IOSTANDARD LVCMOS33} [get_ports {vga_red_o[6]}];           # R6
set_property -dict {PACKAGE_PIN AB16 IOSTANDARD LVCMOS33} [get_ports {vga_red_o[7]}];           # R7
set_property -dict {PACKAGE_PIN V14  IOSTANDARD LVCMOS33} [get_ports {vga_vs_o}];               # VSYNC
set_property -dict {PACKAGE_PIN Y1   IOSTANDARD TMDS_33}  [get_ports {tmds_clk_n_o}];           # HDMI_TXC_N
set_property -dict {PACKAGE_PIN W1   IOSTANDARD TMDS_33}  [get_ports {tmds_clk_p_o}];           # HDMI_TXC_P
set_property -dict {PACKAGE_PIN AB1  IOSTANDARD TMDS_33}  [get_ports {tmds_data_n_o[0]}];       # HDMI_TX0_N
set_property -dict {PACKAGE_PIN AB2  IOSTANDARD TMDS_33}  [get_ports {tmds_data_n_o[1]}];       # HDMI_TX1_N
set_property -dict {PACKAGE_PIN AB5  IOSTANDARD TMDS_33}  [get_ports {tmds_data_n_o[2]}];       # HDMI_TX2_N
set_property -dict {PACKAGE_PIN AA1  IOSTANDARD TMDS_33}  [get_ports {tmds_data_p_o[0]}];       # HDMI_TX0_P
set_property -dict {PACKAGE_PIN AB3  IOSTANDARD TMDS_33}  [get_ports {tmds_data_p_o[1]}];       # HDMI_TX1_P
set_property -dict {PACKAGE_PIN AA5  IOSTANDARD TMDS_33}  [get_ports {tmds_data_p_o[2]}];       # HDMI_TX2_P
set_property -dict {PACKAGE_PIN M15  IOSTANDARD LVCMOS33} [get_ports {hdmi_ct_hpd_o}];          # CT_HPD
set_property -dict {PACKAGE_PIN AB8  IOSTANDARD LVCMOS33} [get_ports {hdmi_ls_oe_o}];           # LS_OE
