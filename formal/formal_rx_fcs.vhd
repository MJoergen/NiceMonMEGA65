-- The check of a received frame's frame check sequence
-- (src/eth/rx_fcs.vhd), with its properties, for SymbiYosys. Every input
-- is free: the bytes, their valid, the end of a frame, and its error, in
-- any cycle, together or not.
--
-- RESET
-- The first cycle is a reset.

library ieee;
   use ieee.std_logic_1164.all;

entity formal_rx_fcs is
   port (
      clk_i   : in  std_logic;
      rst_i   : in  std_logic;
      data_i  : in  std_logic_vector(7 downto 0);
      valid_i : in  std_logic;
      eof_i   : in  std_logic;
      err_i   : in  std_logic
   );
end entity formal_rx_fcs;

architecture synthesis of formal_rx_fcs is

   signal ok  : std_logic;
   signal bad : std_logic;

begin

   -- psl default clock is rising_edge(clk_i);
   -- psl f_initial_reset : assume rst_i;


   i_rx_fcs : entity work.rx_fcs
      generic map (
         G_FORMAL => true
      )
      port map (
         clk_i   => clk_i,
         rst_i   => rst_i,
         data_i  => data_i,
         valid_i => valid_i,
         eof_i   => eof_i,
         err_i   => err_i,
         ok_o    => ok,
         bad_o   => bad
      ); -- i_rx_fcs

end architecture synthesis;
