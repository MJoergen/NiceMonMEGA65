-- A wrapper of the text display (src/video/text.vhd) in the video mode of
-- the boards, for the GHDL synthesis check of the Makefile: GHDL cannot take
-- the record generic G_MODE on the command line. The Makefile sets
-- G_SCR_ADDR_BITS to 15 (the MEGA65) and to 13 (the Nexys4DDR).

library ieee;
   use ieee.std_logic_1164.all;

library work;
   use work.video_pkg.all;

entity text_synth is
   generic (
      G_SCR_ADDR_BITS : natural := 15
   );
   port (
      clk_i       : in  std_logic;
      scr_we_i    : in  std_logic;
      scr_addr_i  : in  std_logic_vector(G_SCR_ADDR_BITS - 1 downto 0);
      scr_data_i  : in  std_logic_vector(31 downto 0);
      ctl_we_i    : in  std_logic;
      cur_x_i     : in  std_logic_vector(6 downto 0);
      cur_y_i     : in  std_logic_vector(4 downto 0);
      cur_mode_i  : in  std_logic_vector(2 downto 0);
      offs_i      : in  std_logic_vector(G_SCR_ADDR_BITS - 1 downto 0);
      ovl_we_i    : in  std_logic;
      ovl_addr_i  : in  std_logic_vector(11 downto 0);
      ovl_data_i  : in  std_logic_vector(31 downto 0);
      strip_i     : in  std_logic;
      page_i      : in  std_logic;
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
         G_MODE          => C_VIDEO_1280X1024,
         G_SCR_ADDR_BITS => G_SCR_ADDR_BITS
      )
      port map (
         clk_i       => clk_i,
         scr_we_i    => scr_we_i,
         scr_addr_i  => scr_addr_i,
         scr_data_i  => scr_data_i,
         ctl_we_i    => ctl_we_i,
         cur_x_i     => cur_x_i,
         cur_y_i     => cur_y_i,
         cur_mode_i  => cur_mode_i,
         offs_i      => offs_i,
         ovl_we_i    => ovl_we_i,
         ovl_addr_i  => ovl_addr_i,
         ovl_data_i  => ovl_data_i,
         strip_i     => strip_i,
         page_i      => page_i,
         vga_clk_i   => vga_clk_i,
         vga_hs_o    => vga_hs_o,
         vga_vs_o    => vga_vs_o,
         vga_de_o    => vga_de_o,
         vga_red_o   => vga_red_o,
         vga_green_o => vga_green_o,
         vga_blue_o  => vga_blue_o
      ); -- i_text

end architecture synthesis;
