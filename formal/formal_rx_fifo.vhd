-- The core's input FIFO (src/rx_fifo.vhd), with its properties, for
-- SymbiYosys. Every input is free, so the solver sends bytes, ends the
-- input, and takes bytes at any time. The FIFO has 4 bytes, so that the
-- solver soon fills it and wraps its pointers around; the properties do not
-- depend on the size.
--
-- RESET
-- The first cycle is a reset.

library ieee;
   use ieee.std_logic_1164.all;

entity formal_rx_fifo is
   port (
      clk_i     : in  std_logic;
      rst_i     : in  std_logic;
      wr_en_i   : in  std_logic;
      wr_data_i : in  std_logic_vector(7 downto 0);
      end_i     : in  std_logic;
      rd_en_i   : in  std_logic
   );
end entity formal_rx_fifo;

architecture synthesis of formal_rx_fifo is

   signal full    : std_logic;
   signal ended   : std_logic;
   signal empty   : std_logic;
   signal rd_data : std_logic_vector(7 downto 0);

begin

   -- psl default clock is rising_edge(clk_i);
   -- psl f_initial_reset : assume rst_i;


   i_rx_fifo : entity work.rx_fifo
      generic map (
         G_ADDR_BITS => 2,
         G_FORMAL    => true
      )
      port map (
         clk_i     => clk_i,
         rst_i     => rst_i,
         wr_en_i   => wr_en_i,
         wr_data_i => wr_data_i,
         full_o    => full,
         free_o    => open,
         end_i     => end_i,
         ended_o   => ended,
         rd_en_i   => rd_en_i,
         empty_o   => empty,
         rd_data_o => rd_data
      ); -- i_rx_fifo

end architecture synthesis;
