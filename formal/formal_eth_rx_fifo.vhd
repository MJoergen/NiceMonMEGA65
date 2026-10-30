-- The FIFO of received Ethernet frames (src/eth/eth_rx_fifo.vhd), with
-- its properties, for SymbiYosys with its two clocks. A step of the
-- solver is half a cycle of the read clock, which changes in every step,
-- and the write clock changes whenever the solver likes, so that it is
-- never faster than the read clock, as the PHY's 50 MHz is slower than
-- the system clock. The other inputs are free but for the FIFO's
-- contracts, which eth_rx_fifo.vhd assumes itself, with one reset of
-- both sides, at the start. The FIFO has 8 bytes, so that a frame of 5
-- bytes, its check sequence and one more, fits, and the solver soon
-- wraps the pointers around; the properties do not depend on the size.
--
-- RESET
-- Both sides are reset at the start, until each clock has risen four
-- times, and never again (eth_rx_fifo.vhd assumes it).

library ieee;
   use ieee.std_logic_1164.all;

entity formal_eth_rx_fifo is
   port (
      wr_clk_i   : in  std_logic;
      rd_clk_i   : in  std_logic;
      rst_i      : in  std_logic;
      wr_data_i  : in  std_logic_vector(7 downto 0);
      wr_valid_i : in  std_logic;
      wr_ok_i    : in  std_logic;
      wr_bad_i   : in  std_logic;
      rd_ready_i : in  std_logic
   );
end entity formal_eth_rx_fifo;

architecture synthesis of formal_eth_rx_fifo is

   -- The solver's time, and the read clock in the step before
   signal f_gclk   : std_logic;
   signal f_rd_clk : std_logic := '0';

   signal wr_drop  : std_logic;
   signal rd_data  : std_logic_vector(7 downto 0);
   signal rd_last  : std_logic;
   signal rd_valid : std_logic;

   attribute gclk : boolean;
   attribute gclk of f_gclk : signal is true;

begin

   p_steps : process (f_gclk)
   begin
      if rising_edge(f_gclk) then
         f_rd_clk <= rd_clk_i;
      end if;
   end process p_steps;

   -- psl default clock is rising_edge(f_gclk);
   -- psl f_rd_clk_step : assume always rd_clk_i /= f_rd_clk;


   i_eth_rx_fifo : entity work.eth_rx_fifo
      generic map (
         G_ADDR_BITS => 3,
         G_FORMAL    => true
      )
      port map (
         wr_clk_i   => wr_clk_i,
         wr_rst_i   => rst_i,
         wr_data_i  => wr_data_i,
         wr_valid_i => wr_valid_i,
         wr_ok_i    => wr_ok_i,
         wr_bad_i   => wr_bad_i,
         wr_drop_o  => wr_drop,
         rd_clk_i   => rd_clk_i,
         rd_rst_i   => rst_i,
         rd_data_o  => rd_data,
         rd_last_o  => rd_last,
         rd_valid_o => rd_valid,
         rd_ready_i => rd_ready_i
      ); -- i_eth_rx_fifo

end architecture synthesis;
