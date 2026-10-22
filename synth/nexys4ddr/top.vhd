-- The top level for the Digilent Nexys4DDR board (also sold as the Nexys
-- A7-100T). It has the clock and reset (clk_rst.vhd), the system
-- (src/system.vhd), and the VGA output. The UART is the board's USB-UART,
-- and LED0 is on while the core runs. The board's keyboard input, LEDs,
-- seven-segment display, buttons, and switches are not used (see TODO.md).
--
-- The board differs from the MEGA65 in three ways that matter here:
-- * Its FPGA, an XC7A100T, has 135 block RAMs of 36 Kbit, where the MEGA65's
--   has 365. So the screen is 8K words (G_SCR_ADDR_BITS = 13), not 32K: with
--   its copy in text.vhd it takes 16 block RAMs, and the RAM and the ROM,
--   the same as on the MEGA65, take 96.
-- * Its FPGA is speed grade -1, where the MEGA65's is -2, so the system
--   clock is 90 MHz, not 100 MHz. At 100 MHz the pipelined core misses
--   timing by a few tenths of a nanosecond or less, which placement
--   changes from run to run.
-- * The VGA output is a resistor DAC with 4 bits per colour, and no HDMI.
--   The screen's colours have 4 bits per colour (text.vhd), so the
--   top 4 bits of each lose nothing. The colour and sync outputs are
--   registered in the IOBs (nexys4ddr.xdc), so they all change at the same
--   time.
-- The reset button, CPU_RESETN, is active low.

library ieee;
   use ieee.std_logic_1164.all;

library work;
   use work.video_pkg.all;

entity top is
   generic (
      -- The ROM with the monitor, a .bin file, or "" for a build without a
      -- ROM, whose core waits for the command line (see src/nicemon.vhd)
      G_ROM_FILE : string := ""
   );
   port (
      clk_i       : in  std_logic; -- 100 MHz
      reset_n_i   : in  std_logic; -- active low
      uart_rxd_i  : in  std_logic;
      uart_txd_o  : out std_logic;
      led_o       : out std_logic; -- on while the core runs

      -- VGA, 4 bits per colour
      vga_red_o   : out std_logic_vector(3 downto 0);
      vga_green_o : out std_logic_vector(3 downto 0);
      vga_blue_o  : out std_logic_vector(3 downto 0);
      vga_hs_o    : out std_logic;
      vga_vs_o    : out std_logic
   );
end entity top;

architecture synthesis of top is

   constant C_CLOCK_HZ : natural      := 90_000_000;
   constant C_VIDEO    : t_video_mode := C_VIDEO_1280X1024;

   signal clk     : std_logic;
   signal rst     : std_logic;
   signal running : std_logic;
   signal led_reg : std_logic := '0';

   signal vga_clk   : std_logic;
   signal vga_hs    : std_logic;
   signal vga_vs    : std_logic;
   signal vga_red   : std_logic_vector(7 downto 0);
   signal vga_green : std_logic_vector(7 downto 0);
   signal vga_blue  : std_logic_vector(7 downto 0);

   -- The registers of the VGA outputs, in the IOBs (IOB TRUE on their ports,
   -- in nexys4ddr.xdc). keep stops synthesis from merging equal colour
   -- registers, which could then not all be in the IOBs.
   signal vga_red_r   : std_logic_vector(3 downto 0);
   signal vga_green_r : std_logic_vector(3 downto 0);
   signal vga_blue_r  : std_logic_vector(3 downto 0);
   signal vga_hs_r    : std_logic;
   signal vga_vs_r    : std_logic;

   attribute keep : string;
   attribute keep of vga_red_r   : signal is "true";
   attribute keep of vga_green_r : signal is "true";
   attribute keep of vga_blue_r  : signal is "true";

begin

   i_clk_rst : entity work.clk_rst
      generic map (
         G_MULTIPLY => 9.0,
         G_DIVIDE   => 10.0
      )
      port map (
         sys_clk_i      => clk_i,
         reset_button_i => not reset_n_i,
         clk_o          => clk,
         rst_o          => rst
      ); -- i_clk_rst


   p_led : process (clk)
   begin
      if rising_edge(clk) then
         led_reg <= running;
      end if;
   end process p_led;

   led_o <= led_reg;


   -- The video has no reset (text.vhd), and the TMDS clock is for HDMI,
   -- which this board does not have.
   i_video_clk : entity work.video_clk
      port map (
         sys_clk_i  => clk_i,
         vga_clk_o  => vga_clk,
         vga_rst_o  => open,
         tmds_clk_o => open
      ); -- i_video_clk


   -- There is no keyboard, so nothing is typed into the console but the
   -- UART.
   i_system : entity work.system
      generic map (
         G_CLOCK_HZ      => C_CLOCK_HZ,
         G_ROM_FILE      => G_ROM_FILE,
         G_SCR_ADDR_BITS => 13,
         G_VIDEO         => C_VIDEO
      )
      port map (
         clk_i       => clk,
         rst_i       => rst,
         uart_rxd_i  => uart_rxd_i,
         uart_txd_o  => uart_txd_o,
         kbd_valid_i => '0',
         kbd_ready_o => open,
         kbd_data_i  => X"00",
         running_o   => running,
         vga_clk_i   => vga_clk,
         vga_hs_o    => vga_hs,
         vga_vs_o    => vga_vs,
         vga_de_o    => open,
         vga_red_o   => vga_red,
         vga_green_o => vga_green,
         vga_blue_o  => vga_blue
      ); -- i_system


   p_vga : process (vga_clk)
   begin
      if rising_edge(vga_clk) then
         vga_red_r   <= vga_red(7 downto 4);
         vga_green_r <= vga_green(7 downto 4);
         vga_blue_r  <= vga_blue(7 downto 4);
         vga_hs_r    <= vga_hs;
         vga_vs_r    <= vga_vs;
      end if;
   end process p_vga;

   vga_red_o   <= vga_red_r;
   vga_green_o <= vga_green_r;
   vga_blue_o  <= vga_blue_r;
   vga_hs_o    <= vga_hs_r;
   vga_vs_o    <= vga_vs_r;

end architecture synthesis;
