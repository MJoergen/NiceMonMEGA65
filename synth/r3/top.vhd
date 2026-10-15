-- The top level for the MEGA65 R3 and R3A boards. On these boards the reset
-- button is not wired to the FPGA, but to the MAX10, a small FPGA on the
-- board, which sends it to the FPGA over a serial link. max10.vhd drives the
-- link, clocked by the 100 MHz board clock. Its reset output is low (active)
-- only once the button has been pressed for 256 clock cycles. clk_rst.vhd
-- synchronises it, so the button resets the system as on the R6.

library ieee;
   use ieee.std_logic_1164.all;

entity top is
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
      led_o              : out std_logic
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
      port map (
         clk_i          => clk_i,
         reset_button_i => not reset_button_n,
         uart_rxd_i     => uart_rxd_i,
         uart_txd_o     => uart_txd_o,
         kb_io0_o       => kb_io0_o,
         kb_io1_o       => kb_io1_o,
         kb_io2_i       => kb_io2_i,
         led_o          => led_o
      ); -- i_mega65

end architecture synthesis;
