-- The font RAM of the text display (font.vhd): 256 glyphs of 32 rows of 16
-- pixels, 8192 words of 16 bits in block RAM, written and read on one
-- clock and read on another.
--
-- THEORY OF OPERATION
-- Port A is in the system clock domain: a write sets the word at a_addr_i,
-- and a read gives the word at a_addr_i in the cycle after, as block RAM
-- does. Port B is read in the VGA clock domain, for the display, likewise.
-- So the memory is the crossing between the clock domains, as the copy of
-- the screen in scr_ram.vhd is. Both reads are 0 before the first one.
--
-- The memory is in an entity of its own because Vivado makes LUTRAM of a
-- memory on two clocks inside a larger entity (scr_ram.vhd says more).
--
-- RESET
-- None. The RAM starts as zeros, and nicemon.vhd's clear zeros it.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity font_ram is
   port (
      a_clk_i   : in  std_logic;
      a_we_i    : in  std_logic;
      a_addr_i  : in  std_logic_vector(12 downto 0);
      a_wdata_i : in  std_logic_vector(15 downto 0);
      a_rdata_o : out std_logic_vector(15 downto 0) := (others => '0');

      b_clk_i   : in  std_logic;
      b_addr_i  : in  std_logic_vector(12 downto 0);
      b_rdata_o : out std_logic_vector(15 downto 0) := (others => '0')
   );
end entity font_ram;

architecture synthesis of font_ram is

   type t_mem is array (0 to 8191) of std_logic_vector(15 downto 0);

   signal mem : t_mem := (others => (others => '0'));

   attribute ram_style : string;
   attribute ram_style of mem : signal is "block";

begin

   p_a : process (a_clk_i)
   begin
      if rising_edge(a_clk_i) then
         if a_we_i = '1' then
            mem(to_integer(a_addr_i)) <= a_wdata_i;
         end if;
         a_rdata_o <= mem(to_integer(a_addr_i));
      end if;
   end process p_a;

   p_b : process (b_clk_i)
   begin
      if rising_edge(b_clk_i) then
         b_rdata_o <= mem(to_integer(b_addr_i));
      end if;
   end process p_b;

end architecture synthesis;
