-- The character ROM of the text display (font.vhd): the Spleen font of
-- font_pkg.vhd, 256 glyphs of 32 rows of 16 pixels, in block RAM, read on
-- two clocks.
--
-- THEORY OF OPERATION
-- The word at code * 32 + row is that row of the glyph of code, as in
-- C_FONT. Port A is read in the system clock domain, for the bus, and port
-- B in the VGA clock domain, for the display. Each read gives the row in
-- the cycle after the address, as block RAM does, and is 0 before the
-- first read.
--
-- The ROM is an entity of its own for the same reason as scr_ram.vhd: a
-- memory read on two clocks inside text.vhd may not become block RAM.
-- Without rom_style, Vivado (2025.1) makes a ROM of LUTs of it on the
-- Nexys4DDR, about 1100 LUTs (issue #70).
--
-- RESET
-- None. The ROM does not change.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

library work;
   use work.font_pkg.all;

entity font_rom is
   port (
      a_clk_i  : in  std_logic;
      a_addr_i : in  std_logic_vector(12 downto 0);
      a_data_o : out std_logic_vector(15 downto 0);

      b_clk_i  : in  std_logic;
      b_addr_i : in  std_logic_vector(12 downto 0);
      b_data_o : out std_logic_vector(15 downto 0)
   );
end entity font_rom;

architecture synthesis of font_rom is

   signal a_data : std_logic_vector(15 downto 0) := (others => '0');
   signal b_data : std_logic_vector(15 downto 0) := (others => '0');

   attribute rom_style : string;
   attribute rom_style of a_data : signal is "block";
   attribute rom_style of b_data : signal is "block";

begin

   p_a : process (a_clk_i)
   begin
      if rising_edge(a_clk_i) then
         a_data <= C_FONT(to_integer(a_addr_i));
      end if;
   end process p_a;

   p_b : process (b_clk_i)
   begin
      if rising_edge(b_clk_i) then
         b_data <= C_FONT(to_integer(b_addr_i));
      end if;
   end process p_b;

   a_data_o <= a_data;
   b_data_o <= b_data;

end architecture synthesis;
