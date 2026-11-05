-- The fonts of the text display (text.vhd): the font RAM at 0xFFFE0000-1FFF
-- and the character ROM at 0xFFFE2000-3FFF of src/nicemon.vhd, with a port
-- for the bus in the system clock domain and one for the display in the VGA
-- clock domain (nice_cpu's doc/SYSTEM.md §1.8).
--
-- THEORY OF OPERATION
-- Each font is 256 glyphs of 32 rows of 16 pixels: the word at code * 32 +
-- row is that row of the glyph of code, the top row first, with the
-- leftmost pixel in bit 15. The RAM is font_ram.vhd, and the ROM,
-- font_rom.vhd, holds Spleen (font_pkg.vhd).
--
-- The bus port takes the offset of a word from 0xFFFE0000 in addr_i, in
-- every cycle: bit 13 is 0 for the RAM and 1 for the ROM. A write with
-- we_i sets a word of the RAM, and one to the ROM is dropped. rdata_o is
-- the word at the address of the cycle before, from the font that bit 13
-- named then, as block RAM reads.
--
-- The display port reads the row at vga_addr_i in each VGA cycle, from the
-- RAM while vga_ram_i is '1' and from the ROM otherwise, and gives it on
-- vga_row_o in the next cycle. Both fonts are read in every cycle, and the
-- choice is made after them.
--
-- RESET
-- None. The RAM starts as zeros, and nicemon.vhd's clear zeros it.

library ieee;
   use ieee.std_logic_1164.all;

entity font is
   port (
      -- The bus, in the system clock domain
      clk_i      : in  std_logic;
      we_i       : in  std_logic;
      addr_i     : in  std_logic_vector(13 downto 0);
      wdata_i    : in  std_logic_vector(15 downto 0);
      rdata_o    : out std_logic_vector(15 downto 0);

      -- The display, in the VGA clock domain
      vga_clk_i  : in  std_logic;
      vga_addr_i : in  std_logic_vector(12 downto 0);
      vga_ram_i  : in  std_logic;
      vga_row_o  : out std_logic_vector(15 downto 0)
   );
end entity font;

architecture synthesis of font is

   signal ram_we    : std_logic;
   signal ram_rdata : std_logic_vector(15 downto 0);
   signal rom_rdata : std_logic_vector(15 downto 0);
   signal rd_rom    : std_logic := '0';
   signal ram_row   : std_logic_vector(15 downto 0);
   signal rom_row   : std_logic_vector(15 downto 0);
   signal vga_ram_r : std_logic := '0';

begin

   ram_we <= we_i and not addr_i(13);

   i_font_ram : entity work.font_ram
      port map (
         a_clk_i   => clk_i,
         a_we_i    => ram_we,
         a_addr_i  => addr_i(12 downto 0),
         a_wdata_i => wdata_i,
         a_rdata_o => ram_rdata,
         b_clk_i   => vga_clk_i,
         b_addr_i  => vga_addr_i,
         b_rdata_o => ram_row
      ); -- i_font_ram

   i_font_rom : entity work.font_rom
      port map (
         a_clk_i  => clk_i,
         a_addr_i => addr_i(12 downto 0),
         a_data_o => rom_rdata,
         b_clk_i  => vga_clk_i,
         b_addr_i => vga_addr_i,
         b_data_o => rom_row
      ); -- i_font_rom

   p_bus : process (clk_i)
   begin
      if rising_edge(clk_i) then
         rd_rom <= addr_i(13);
      end if;
   end process p_bus;

   rdata_o <= rom_rdata when rd_rom = '1' else
              ram_rdata;

   p_vga : process (vga_clk_i)
   begin
      if rising_edge(vga_clk_i) then
         vga_ram_r <= vga_ram_i;
      end if;
   end process p_vga;

   vga_row_o <= ram_row when vga_ram_r = '1' else
                rom_row;

end architecture synthesis;
