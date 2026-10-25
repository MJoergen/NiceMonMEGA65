-- The screen's registers (src/scr_regs.vhd), with their properties, for
-- SymbiYosys. Every input is free, so the solver writes and reads any word,
-- and clears the registers, at any time. The screen has 2^11 words, the
-- fewest that nicemon allows; the properties do not depend on the size.
--
-- RESET
-- The first cycle is a reset.

library ieee;
   use ieee.std_logic_1164.all;

entity formal_scr_regs is
   port (
      clk_i   : in  std_logic;
      rst_i   : in  std_logic;
      clear_i : in  std_logic;
      stb_i   : in  std_logic;
      we_i    : in  std_logic;
      addr_i  : in  std_logic_vector(3 downto 0);
      wdata_i : in  std_logic_vector(31 downto 0)
   );
end entity formal_scr_regs;

architecture synthesis of formal_scr_regs is

   signal rdata : std_logic_vector(31 downto 0);

begin

   -- psl default clock is rising_edge(clk_i);
   -- psl f_initial_reset : assume rst_i;


   i_scr_regs : entity work.scr_regs
      generic map (
         G_SCR_ADDR_BITS => 11,
         G_FORMAL        => true
      )
      port map (
         clk_i      => clk_i,
         rst_i      => rst_i,
         clear_i    => clear_i,
         stb_i      => stb_i,
         we_i       => we_i,
         addr_i     => addr_i,
         wdata_i    => wdata_i,
         rdata_o    => rdata,
         ctl_we_o   => open,
         cur_x_o    => open,
         cur_y_o    => open,
         cur_mode_o => open,
         offs_o     => open
      ); -- i_scr_regs

end architecture synthesis;
