-- A wrapper of the text display (src/video/text.vhd) in the video mode of
-- the boards, for the GHDL synthesis check of the Makefile: GHDL cannot take
-- the record generic G_MODE on the command line.

library ieee;
   use ieee.std_logic_1164.all;

library work;
   use work.video_pkg.all;

entity text_synth is
   port (
      clk_i       : in  std_logic;
      scr_we_i    : in  std_logic;
      scr_addr_i  : in  std_logic_vector(10 downto 0);
      scr_data_i  : in  std_logic_vector(31 downto 0);
      vga_clk_i   : in  std_logic;
      vga_hs_o    : out std_logic;
      vga_vs_o    : out std_logic;
      vga_de_o    : out std_logic;
      vga_red_o   : out std_logic_vector(7 downto 0);
      vga_green_o : out std_logic_vector(7 downto 0);
      vga_blue_o  : out std_logic_vector(7 downto 0)
   );
end entity text_synth;

architecture synthesis of text_synth is

begin

   i_text : entity work.text
      generic map (
         G_MODE => C_VIDEO_1280X1024
      )
      port map (
         clk_i       => clk_i,
         scr_we_i    => scr_we_i,
         scr_addr_i  => scr_addr_i,
         scr_data_i  => scr_data_i,
         vga_clk_i   => vga_clk_i,
         vga_hs_o    => vga_hs_o,
         vga_vs_o    => vga_vs_o,
         vga_de_o    => vga_de_o,
         vga_red_o   => vga_red_o,
         vga_green_o => vga_green_o,
         vga_blue_o  => vga_blue_o
      ); -- i_text

end architecture synthesis;
