-- The clocks of the video output of the MEGA65 boards. A second MMCM, apart
-- from the one of the system clock (clk_rst.vhd), makes them from the
-- board's 100 MHz clock, as MandelbrotMEGA65's clk_rst.vhd does:
--   VCO       100 MHz / 5 * 54 = 1080 MHz, the only VCO frequency that
--             gives the 108 MHz of 1280x1024 @ 60 Hz exactly
--   vga_clk   1080 MHz / 10 = 108 MHz, the pixel clock
--   tmds_clk  1080 MHz / 2 = 540 MHz, five times the pixel clock, for the
--             HDMI serialisers, which send ten bits per pixel on both edges
-- The video has its own MMCM so that the system clock stays at 50 MHz,
-- which 1080 MHz does not divide to.
--
-- RESET
-- vga_rst_o is held while the MMCM is not locked, and for 8 cycles after.
-- The reset button does not reset the video.

library ieee;
   use ieee.std_logic_1164.all;

library unisim;
   use unisim.vcomponents.all;

entity video_clk is
   port (
      sys_clk_i  : in  std_logic; -- 100 MHz
      vga_clk_o  : out std_logic; -- 108 MHz
      vga_rst_o  : out std_logic; -- synchronous to vga_clk_o
      tmds_clk_o : out std_logic  -- 540 MHz
   );
end entity video_clk;

architecture synthesis of video_clk is

   signal clkfb     : std_logic;
   signal clkfb_buf : std_logic;
   signal vga_mmcm  : std_logic;
   signal tmds_mmcm : std_logic;
   signal vga_clk   : std_logic;
   signal locked    : std_logic;

   signal rst_delay : std_logic_vector(7 downto 0) := (others => '1');

begin

   -- The Xilinx primitives are components of unisim.vcomponents, and their
   -- generics and ports are named in upper case, as in Xilinx's documentation.
-- vsg_off
   i_mmcm : MMCME2_BASE
      generic map (
         CLKIN1_PERIOD    => 10.0,  -- 100 MHz
         DIVCLK_DIVIDE    => 5,
         CLKFBOUT_MULT_F  => 54.0,  -- VCO at 1080 MHz
         CLKOUT0_DIVIDE_F => 10.0,  -- 108 MHz
         CLKOUT1_DIVIDE   => 2      -- 540 MHz
      )
      port map (
         CLKIN1   => sys_clk_i,
         CLKFBIN  => clkfb_buf,
         CLKFBOUT => clkfb,
         CLKOUT0  => vga_mmcm,
         CLKOUT1  => tmds_mmcm,
         LOCKED   => locked,
         PWRDWN   => '0',
         RST      => '0'
      ); -- i_mmcm

   i_bufg_fb : BUFG
      port map (
         I => clkfb,
         O => clkfb_buf
      ); -- i_bufg_fb

   i_bufg_vga : BUFG
      port map (
         I => vga_mmcm,
         O => vga_clk
      ); -- i_bufg_vga

   i_bufg_tmds : BUFG
      port map (
         I => tmds_mmcm,
         O => tmds_clk_o
      ); -- i_bufg_tmds
-- vsg_on

   p_rst : process (vga_clk, locked)
   begin
      if locked = '0' then
         rst_delay <= (others => '1');
      elsif rising_edge(vga_clk) then
         rst_delay <= rst_delay(6 downto 0) & '0';
      end if;
   end process p_rst;

   vga_clk_o <= vga_clk;
   vga_rst_o <= rst_delay(7);

end architecture synthesis;
