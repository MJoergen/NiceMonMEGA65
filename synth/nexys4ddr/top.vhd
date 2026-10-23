-- The top level for the Digilent Nexys4DDR board (also sold as the Nexys
-- A7-100T). It has the clock and reset (clk_rst.vhd), the system
-- (src/system.vhd), the keyboard, and the VGA output. The UART is the
-- board's USB-UART, and LED0 is on while the core runs. A USB keyboard in
-- the board's USB HID port types into the same input as the UART: the
-- board's PIC24 turns it into PS/2, which kbd_ps2.vhd receives and
-- kbd_ps2_ascii.vhd turns into ASCII. The board's other LEDs, its
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
-- * The VGA output is a resistor DAC with 4 bits per color, and no HDMI.
--   The screen's colors have 4 bits per color (text.vhd), so the
--   top 4 bits of each lose nothing. The color and sync outputs are
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

      -- The keyboard, as PS/2 from the PIC24
      ps2_clk_i   : in  std_logic;
      ps2_data_i  : in  std_logic;

      -- VGA, 4 bits per color
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

   signal ps2_valid : std_logic;
   signal ps2_code  : std_logic_vector(7 downto 0);
   signal kbd_valid : std_logic;
   signal kbd_ready : std_logic;
   signal kbd_data  : std_logic_vector(7 downto 0);

   signal vga_clk   : std_logic;
   signal vga_hs    : std_logic;
   signal vga_vs    : std_logic;
   signal vga_red   : std_logic_vector(7 downto 0);
   signal vga_green : std_logic_vector(7 downto 0);
   signal vga_blue  : std_logic_vector(7 downto 0);

   -- The registers of the VGA outputs, in the IOBs (IOB TRUE on their ports,
   -- in nexys4ddr.xdc). keep stops synthesis from merging equal color
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
         G_MULTIPLY     => 9.0,
         G_DIVIDE       => 10.0,
         G_BUTTON_LEVEL => '0'
      )
      port map (
         sys_clk_i      => clk_i,
         reset_button_i => reset_n_i,
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


   i_kbd_ps2 : entity work.kbd_ps2
      generic map (
         G_CLOCK_HZ => C_CLOCK_HZ
      )
      port map (
         clk_i        => clk,
         rst_i        => rst,
         ps2_clk_i    => ps2_clk_i,
         ps2_data_i   => ps2_data_i,
         data_valid_o => ps2_valid,
         data_o       => ps2_code
      ); -- i_kbd_ps2


   i_kbd_ps2_ascii : entity work.kbd_ps2_ascii
      port map (
         clk_i        => clk,
         rst_i        => rst,
         code_valid_i => ps2_valid,
         code_i       => ps2_code,
         data_valid_o => kbd_valid,
         data_ready_i => kbd_ready,
         data_o       => kbd_data
      ); -- i_kbd_ps2_ascii


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
         kbd_valid_i => kbd_valid,
         kbd_ready_o => kbd_ready,
         kbd_data_i  => kbd_data,
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
