-- The I2C master (src/i2c.vhd), with its properties, for SymbiYosys. Every
-- input is free, so the solver writes and reads any word at any time, and
-- the chips drive the lines as they please. A quarter of the bus's clock
-- is a cycle, and the timeout two, so that the solver soon gets through a
-- transaction; the properties do not depend on them.
--
-- RESET
-- The first cycle is a reset.

library ieee;
   use ieee.std_logic_1164.all;

entity formal_i2c is
   port (
      clk_i   : in  std_logic;
      rst_i   : in  std_logic;
      stb_i   : in  std_logic;
      we_i    : in  std_logic;
      addr_i  : in  std_logic_vector(3 downto 0);
      wdata_i : in  std_logic_vector(31 downto 0);
      scl_i   : in  std_logic;
      sda_i   : in  std_logic
   );
end entity formal_i2c;

architecture synthesis of formal_i2c is

begin

   -- psl default clock is rising_edge(clk_i);
   -- psl f_initial_reset : assume rst_i;


   i_i2c : entity work.i2c
      generic map (
         G_CLOCK_HZ   => 8,
         G_BUS_HZ     => 2,
         G_TIMEOUT_US => 1,
         G_FORMAL     => true
      )
      port map (
         clk_i   => clk_i,
         rst_i   => rst_i,
         stb_i   => stb_i,
         we_i    => we_i,
         addr_i  => addr_i,
         wdata_i => wdata_i,
         rdata_o => open,
         scl_o   => open,
         sda_o   => open,
         scl_i   => scl_i,
         sda_i   => sda_i
      ); -- i_i2c

end architecture synthesis;
