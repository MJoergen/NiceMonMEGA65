-- The FIFO of Ethernet frames to send (src/eth/eth_tx_fifo.vhd), with its
-- properties, for SymbiYosys with its two clocks. A step of the solver is
-- half a cycle of the write clock, the system clock, which changes in
-- every step, and the read clock, the PHY's, changes at least every third
-- step, as the solver likes, so that the write clock is at most three
-- times as fast, as contract a) of the FIFO needs. The other inputs are
-- free but for the FIFO's contracts, which eth_tx_fifo.vhd assumes
-- itself, with one reset of both sides, at the start. The FIFO has 4
-- bytes, so that the solver soon wraps the pointers around; the
-- properties do not depend on the size.
--
-- RESET
-- Both sides are reset at the start, until each clock has risen four
-- times, and never again (eth_tx_fifo.vhd assumes it).

library ieee;
   use ieee.std_logic_1164.all;

entity formal_eth_tx_fifo is
   port (
      wr_clk_i   : in  std_logic;
      rd_clk_i   : in  std_logic;
      rst_i      : in  std_logic;
      wr_data_i  : in  std_logic_vector(7 downto 0);
      wr_last_i  : in  std_logic;
      wr_valid_i : in  std_logic;
      rd_ready_i : in  std_logic
   );
end entity formal_eth_tx_fifo;

architecture synthesis of formal_eth_tx_fifo is

   -- The solver's time, the clocks in the step before, and the steps that
   -- the read clock has kept its value, as far as 2
   signal f_gclk   : std_logic;
   signal f_wr_clk : std_logic            := '0';
   signal f_rd_clk : std_logic            := '0';
   signal f_kept   : natural range 0 to 2 := 0;

   signal wr_ready : std_logic;
   signal rd_data  : std_logic_vector(7 downto 0);
   signal rd_last  : std_logic;
   signal rd_valid : std_logic;

   attribute gclk : boolean;
   attribute gclk of f_gclk : signal is true;

begin

   p_steps : process (f_gclk)
   begin
      if rising_edge(f_gclk) then
         f_wr_clk <= wr_clk_i;
         f_rd_clk <= rd_clk_i;
         f_kept   <= 0;
         if rd_clk_i = f_rd_clk and f_kept < 2 then
            f_kept <= f_kept + 1;
         end if;
      end if;
   end process p_steps;

   -- psl default clock is rising_edge(f_gclk);
   -- psl f_wr_clk_step : assume always wr_clk_i /= f_wr_clk;
   -- psl f_rd_clk_step : assume always f_kept = 2 -> rd_clk_i /= f_rd_clk;


   i_eth_tx_fifo : entity work.eth_tx_fifo
      generic map (
         G_ADDR_BITS => 2,
         G_FORMAL    => true
      )
      port map (
         wr_clk_i   => wr_clk_i,
         wr_rst_i   => rst_i,
         wr_data_i  => wr_data_i,
         wr_last_i  => wr_last_i,
         wr_valid_i => wr_valid_i,
         wr_ready_o => wr_ready,
         rd_clk_i   => rd_clk_i,
         rd_rst_i   => rst_i,
         rd_data_o  => rd_data,
         rd_last_o  => rd_last,
         rd_valid_o => rd_valid,
         rd_ready_i => rd_ready_i
      ); -- i_eth_tx_fifo

end architecture synthesis;
