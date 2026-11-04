-- The protocol engine of the SD card controller (src/sd/sd_spi.vhd), with
-- its properties, for SymbiYosys. Every input is free but for the
-- contracts that sd_spi assumes, so the solver starts and aborts commands,
-- and the card answers anything at any time. The clocks are a few cycles,
-- and a millisecond is 1, so that the solver soon gets through the steps;
-- the properties do not depend on them. Slot 0's power is switched, as on
-- the Nexys4DDR.
--
-- RESET
-- The first cycle is a reset.

library ieee;
   use ieee.std_logic_1164.all;

entity formal_sd_spi is
   port (
      clk_i      : in  std_logic;
      rst_i      : in  std_logic;
      start_i    : in  std_logic;
      abort_i    : in  std_logic;
      cmd_i      : in  std_logic_vector(1 downto 0);
      lba_i      : in  std_logic_vector(31 downto 0);
      buf_data_i : in  std_logic_vector(7 downto 0);
      miso_i     : in  std_logic
   );
end entity formal_sd_spi;

architecture synthesis of formal_sd_spi is

begin

   -- psl default clock is rising_edge(clk_i);
   -- psl f_initial_reset : assume rst_i;


   i_sd_spi : entity work.sd_spi
      generic map (
         G_CLOCK_HZ => 8,
         G_SLOW_HZ  => 2,
         G_FAST_HZ  => 2,
         G_POWER    => true,
         G_MS       => 1,
         G_FORMAL   => true
      )
      port map (
         clk_i      => clk_i,
         rst_i      => rst_i,
         start_i    => start_i,
         abort_i    => abort_i,
         cmd_i      => cmd_i,
         lba_i      => lba_i,
         done_o     => open,
         error_o    => open,
         last_o     => open,
         type_o     => open,
         buf_addr_o => open,
         buf_we_o   => open,
         buf_data_o => open,
         buf_data_i => buf_data_i,
         cs_n_o     => open,
         pwr_n_o    => open,
         sclk_o     => open,
         mosi_o     => open,
         miso_i     => miso_i
      ); -- i_sd_spi

end architecture synthesis;
