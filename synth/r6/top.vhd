-- The top level for the MEGA65 R6 board. The reset button is wired to the
-- FPGA, so it resets the system.

library ieee;
   use ieee.std_logic_1164.all;

entity top is
   port (
      clk_i          : in  std_logic; -- 100 MHz
      reset_button_i : in  std_logic; -- active high
      uart_rxd_i     : in  std_logic;
      uart_txd_o     : out std_logic;
      led_o          : out std_logic
   );
end entity top;

architecture synthesis of top is
begin

   i_mega65 : entity work.mega65
      port map (
         clk_i          => clk_i,
         reset_button_i => reset_button_i,
         uart_rxd_i     => uart_rxd_i,
         uart_txd_o     => uart_txd_o,
         led_o          => led_o
      ); -- i_mega65

end architecture synthesis;
