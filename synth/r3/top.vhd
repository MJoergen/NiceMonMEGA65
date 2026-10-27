-- The top level for the MEGA65 R3 and R3A boards. On these boards the reset
-- button is not wired to the FPGA, but to the MAX10, a small FPGA on the
-- board, which sends it to the FPGA over a serial link. max10.vhd drives the
-- link, clocked by the 100 MHz board clock. Its reset output is low (active)
-- only once the button has been pressed for 256 clock cycles. clk_rst.vhd
-- synchronizes it, so the button resets the system as on the R6.
--
-- The HDMI level shifter (U10 = TPD12S016) differs from the R6's: the +5V
-- supply of the HDMI connector (CT_HPD) and the output enable of the level
-- shifter (LS_OE, active high) are switched on, as in MandelbrotMEGA65's
-- mega65_r3.vhd and the MiSTer2MEGA65 framework.

library ieee;
   use ieee.std_logic_1164.all;

entity top is
   generic (
      -- The ROM that the core boots from, or "" for a build without one (mega65.vhd)
      G_ROM_FILE : string := ""
   );
   port (
      clk_i              : in  std_logic; -- 100 MHz

      -- The serial link to the MAX10, which reads the reset button
      max10_tx_i         : in  std_logic;
      max10_rx_o         : out std_logic;
      max10_clkandsync_o : out std_logic;

      uart_rxd_i         : in  std_logic;
      uart_txd_o         : out std_logic;
      kb_io0_o           : out std_logic;
      kb_io1_o           : out std_logic;
      kb_io2_i           : in  std_logic;
      led_o              : out std_logic;

      -- VGA via the video DAC
      vga_red_o          : out std_logic_vector(7 downto 0);
      vga_green_o        : out std_logic_vector(7 downto 0);
      vga_blue_o         : out std_logic_vector(7 downto 0);
      vga_hs_o           : out std_logic;
      vga_vs_o           : out std_logic;
      vdac_clk_o         : out std_logic;
      vdac_sync_n_o      : out std_logic;
      vdac_blank_n_o     : out std_logic;

      -- HDMI
      tmds_data_p_o      : out std_logic_vector(2 downto 0);
      tmds_data_n_o      : out std_logic_vector(2 downto 0);
      tmds_clk_p_o       : out std_logic;
      tmds_clk_n_o       : out std_logic;
      hdmi_ct_hpd_o      : out std_logic;
      hdmi_ls_oe_o       : out std_logic
   );
end entity top;

architecture synthesis of top is

   signal reset_button_n : std_logic;

begin

   i_max10 : entity work.max10
      port map (
         pixelclock        => clk_i,
         cpuclock          => clk_i,
         led               => open,
         max10_rx          => max10_rx_o,
         max10_tx          => max10_tx_i,
         max10_clkandsync  => max10_clkandsync_o,
         max10_fpga_commit => open,
         max10_fpga_date   => open,
         reset_button      => reset_button_n,
         dipsw             => open,
         j21in             => open,
         j21ddr            => (others => '0'),
         j21out            => (others => '0')
      ); -- i_max10

   i_mega65 : entity work.mega65
      generic map (
         G_ROM_FILE => G_ROM_FILE
      )
      port map (
         clk_i          => clk_i,
         reset_button_i => not reset_button_n,
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
         tmds_clk_n_o   => tmds_clk_n_o
      ); -- i_mega65

   hdmi_ct_hpd_o <= '1';  -- Supply +5V to the HDMI connector
   hdmi_ls_oe_o  <= '1';  -- Enable the HDMI level shifter

end architecture synthesis;
