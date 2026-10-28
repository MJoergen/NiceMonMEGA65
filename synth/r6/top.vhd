-- The top level for the MEGA65 R6 board. The reset button is wired to the
-- FPGA, so it resets the system. This module also drives the pins of the
-- video that the R3 does not have, as MandelbrotMEGA65's mega65_r6.vhd does:
-- * The video DAC has a power save input. It is switched off.
-- * The HDMI outputs can be 50 ohm terminated (HIZ_EN low), and the level
--   shifter (U10 = PTN3363) has an active low output enable. Both are
--   switched on.

library ieee;
   use ieee.std_logic_1164.all;

entity top is
   generic (
      -- The ROM that the core boots from, or "" for a build without one (mega65.vhd)
      G_ROM_FILE : string := ""
   );
   port (
      clk_i          : in  std_logic; -- 100 MHz
      reset_button_i : in  std_logic; -- active high
      uart_rxd_i     : in  std_logic;
      uart_txd_o     : out std_logic;
      kb_io0_o       : out std_logic;
      kb_io1_o       : out std_logic;
      kb_io2_i       : in  std_logic;
      led_o          : out std_logic;

      -- VGA via the video DAC
      vga_red_o      : out std_logic_vector(7 downto 0);
      vga_green_o    : out std_logic_vector(7 downto 0);
      vga_blue_o     : out std_logic_vector(7 downto 0);
      vga_hs_o       : out std_logic;
      vga_vs_o       : out std_logic;
      vdac_clk_o     : out std_logic;
      vdac_sync_n_o  : out std_logic;
      vdac_blank_n_o : out std_logic;
      vdac_psave_n_o : out std_logic;

      -- HDMI
      tmds_data_p_o  : out std_logic_vector(2 downto 0);
      tmds_data_n_o  : out std_logic_vector(2 downto 0);
      tmds_clk_p_o   : out std_logic;
      tmds_clk_n_o   : out std_logic;
      hdmi_hiz_en_o  : out std_logic;
      hdmi_ls_oe_n_o : out std_logic;

      -- Ethernet, RMII
      eth_clk_o      : out std_logic;
      eth_rst_n_o    : out std_logic;
      eth_rxd_i      : in  std_logic_vector(1 downto 0);
      eth_crs_dv_i   : in  std_logic;
      eth_rxer_i     : in  std_logic;
      eth_txd_o      : out std_logic_vector(1 downto 0);
      eth_tx_en_o    : out std_logic
   );
end entity top;

architecture synthesis of top is

begin

   i_mega65 : entity work.mega65
      generic map (
         G_ROM_FILE => G_ROM_FILE
      )
      port map (
         clk_i          => clk_i,
         reset_button_i => reset_button_i,
         uart_rxd_i     => uart_rxd_i,
         uart_txd_o     => uart_txd_o,
         kb_io0_o       => kb_io0_o,
         kb_io1_o       => kb_io1_o,
         kb_io2_i       => kb_io2_i,
         led_o          => led_o,
         vga_red_o      => vga_red_o,
         vga_green_o    => vga_green_o,
         vga_blue_o     => vga_blue_o,
         vga_hs_o       => vga_hs_o,
         vga_vs_o       => vga_vs_o,
         vdac_clk_o     => vdac_clk_o,
         vdac_sync_n_o  => vdac_sync_n_o,
         vdac_blank_n_o => vdac_blank_n_o,
         tmds_data_p_o  => tmds_data_p_o,
         tmds_data_n_o  => tmds_data_n_o,
         tmds_clk_p_o   => tmds_clk_p_o,
         tmds_clk_n_o   => tmds_clk_n_o,
         eth_clk_o      => eth_clk_o,
         eth_rst_n_o    => eth_rst_n_o,
         eth_rxd_i      => eth_rxd_i,
         eth_crs_dv_i   => eth_crs_dv_i,
         eth_rxer_i     => eth_rxer_i,
         eth_txd_o      => eth_txd_o,
         eth_tx_en_o    => eth_tx_en_o
      ); -- i_mega65

   vdac_psave_n_o <= '1';  -- Power on
   hdmi_hiz_en_o  <= '0';  -- The HDMI outputs are 50 ohm terminated
   hdmi_ls_oe_n_o <= '0';  -- Enable the HDMI level shifter

end architecture synthesis;
