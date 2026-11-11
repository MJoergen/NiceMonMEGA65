-- The top level for the Digilent Nexys4DDR board (also sold as the Nexys
-- A7-100T). It has the clock and reset (clk_rst.vhd), the system
-- (src/system.vhd), the keyboard, and the VGA output. The UART is the
-- board's USB-UART, and LED0 is on while the core runs, or while the program
-- sets it. A USB keyboard in the board's USB HID port types into the same
-- input as the UART: the board's PIC24 turns it into PS/2, which
-- kbd_ps2.vhd receives and kbd_ps2_ascii.vhd turns into ASCII. Scroll Lock
-- toggles the on-board debugger (kbd_ps2_toggle.vhd, doc/DEBUGGER.md), as
-- the board has no MEGA key. The board's 16 LEDs, two RGB LEDs,
-- seven-segment display, five buttons, and 16 switches are registers of
-- the system, in 0xFFFFFF90-96 (src/nicemon.vhd). The RGB LEDs are driven
-- by rgb_pwm.vhd, and the display by seg7.vhd. The buttons and the
-- switches are slow, and synchronized in the system.
--
-- The board differs from the MEGA65 in three ways that matter here:
-- * Its FPGA, an XC7A100T, has 135 block RAMs of 36 Kbit, where the MEGA65's
--   has 365. So the screen is 8K words (G_SCR_ADDR_BITS = 13), not 32K: with
--   its copy in text.vhd it takes 16 block RAMs, and the RAM of 64K words
--   (G_RAM_ADDR_BITS = 16, half the MEGA65's) and the ROM take 96.
-- * Its FPGA is speed grade -1, where the MEGA65's is -2, so the system
--   clock is 90 MHz, not 100 MHz. At 100 MHz the pipelined core misses
--   timing by a few tenths of a nanosecond or less, which placement
--   changes from run to run.
-- * The VGA output is a resistor DAC with 4 bits per color, and no HDMI.
--   The VGA outputs take the top 4 of the 8 bits of each color, which
--   loses nothing, as the screen's colors have only 4 bits (text.vhd).
--   The color and sync outputs are registered in the IOBs (nexys4ddr.xdc),
--   so they all change at the same time.
-- The reset button, CPU_RESETN, is active low.
--
-- The Ethernet PHY, an SMSC LAN8720A, gets its 50 MHz clock and its reset
-- from the FPGA, as on the MEGA65 (synth/mega65/mega65.vhd). Its RMII
-- pins go to system.vhd, to the Ethernet station there (src/eth/eth.vhd).
--
-- The microSD slot is the system's SD slot 0, whose power the system
-- switches with SD_RESET (src/system.vhd).
--
-- The I2C bus of the temperature sensor, an ADT7420 at 0x4B, goes to the
-- I2C master of system.vhd (src/i2c.vhd), open drain: a pin is low while
-- the master's output is 0, and released while it is 1 (#105).

library ieee;
   use ieee.std_logic_1164.all;

library unisim;
   use unisim.vcomponents.all;

library work;
   use work.video_pkg.all;

entity top is
   generic (
      -- The ROM that the core boots from, a .bin file, or "" for a build without a
      -- ROM, whose core waits for the debug link (see src/nicemon.vhd)
      G_ROM_FILE : string := ""
   );
   port (
      clk_i        : in  std_logic; -- 100 MHz
      reset_n_i    : in  std_logic; -- active low
      uart_rxd_i   : in  std_logic;
      uart_txd_o   : out std_logic;
      -- LED0 is on while the core runs
      led_o        : out std_logic_vector(15 downto 0);

      -- The RGB LEDs: bit 2 red, bit 1 green, bit 0 blue
      rgb0_o       : out std_logic_vector(2 downto 0);
      rgb1_o       : out std_logic_vector(2 downto 0);

      -- The seven-segment display, active low
      seg_an_o     : out std_logic_vector(7 downto 0);
      seg_ca_o     : out std_logic_vector(7 downto 0);

      -- Center, up, left, right, and down, and the switches
      btn_i        : in  std_logic_vector(4 downto 0);
      sw_i         : in  std_logic_vector(15 downto 0);

      -- The keyboard, as PS/2 from the PIC24
      ps2_clk_i    : in  std_logic;
      ps2_data_i   : in  std_logic;

      -- VGA, 4 bits per color
      vga_red_o    : out std_logic_vector(3 downto 0);
      vga_green_o  : out std_logic_vector(3 downto 0);
      vga_blue_o   : out std_logic_vector(3 downto 0);
      vga_hs_o     : out std_logic;
      vga_vs_o     : out std_logic;

      -- Ethernet, RMII
      eth_clk_o    : out std_logic;
      eth_rst_n_o  : out std_logic;
      eth_rxd_i    : in  std_logic_vector(1 downto 0);
      eth_crs_dv_i : in  std_logic;
      eth_rxer_i   : in  std_logic;
      eth_txd_o    : out std_logic_vector(1 downto 0);
      eth_tx_en_o  : out std_logic;

      -- The microSD slot in SPI mode (src/system.vhd), and its power, on
      -- while SD_RESET is low
      sd_pwr_n_o   : out std_logic;
      sd_clk_o     : out std_logic;
      sd_cmd_o     : out std_logic;
      sd_dat3_o    : out std_logic;
      sd_dat0_i    : in  std_logic;
      sd_cd_n_i    : in  std_logic;

      -- The I2C bus of the temperature sensor, TMP_SCL and TMP_SDA, open
      -- drain
      i2c_scl_io   : inout std_logic;
      i2c_sda_io   : inout std_logic
   );
end entity top;

architecture synthesis of top is

   constant C_CLOCK_HZ : natural      := 90_000_000;
   constant C_VIDEO    : t_video_mode := C_VIDEO_1280X1024;

   signal clk     : std_logic;
   signal rst     : std_logic;
   signal running : std_logic;
   signal led_reg : std_logic_vector(15 downto 0) := (others => '0');

   signal brd_led  : std_logic_vector(15 downto 0);
   signal brd_rgb0 : std_logic_vector(11 downto 0);
   signal brd_rgb1 : std_logic_vector(11 downto 0);
   signal brd_seg  : std_logic_vector(63 downto 0);

   signal ps2_valid  : std_logic;
   signal ps2_code   : std_logic_vector(7 downto 0);
   signal kbd_valid  : std_logic;
   signal kbd_ready  : std_logic;
   signal kbd_data   : std_logic_vector(7 downto 0);
   signal dbg_toggle : std_logic;

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

   signal eth_clk     : std_logic;
   signal eth_pin_clk : std_logic;
   signal eth_rst     : std_logic;

   -- The PHY's reset, in the IOB (IOB TRUE on its port, in nexys4ddr.xdc)
   signal eth_rst_n_r : std_logic := '0';

   -- The SD card's slots, of which the board has slot 0
   signal sd_clk  : std_logic_vector(1 downto 0);
   signal sd_cmd  : std_logic_vector(1 downto 0);
   signal sd_dat3 : std_logic_vector(1 downto 0);

   -- The I2C master's outputs: 0 pulls a pin low, 1 releases it
   signal i2c_scl : std_logic;
   signal i2c_sda : std_logic;
   -- The pins' levels
   signal i2c_scl_in : std_logic;
   signal i2c_sda_in : std_logic;

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
         rst_o          => rst,
         eth_clk_o      => eth_clk,
         eth_pin_clk_o  => eth_pin_clk,
         eth_rst_o      => eth_rst
      ); -- i_clk_rst


   p_led : process (clk)
   begin
      if rising_edge(clk) then
         led_reg    <= brd_led;
         led_reg(0) <= running or brd_led(0);
      end if;
   end process p_led;

   led_o <= led_reg;


   i_rgb_pwm0 : entity work.rgb_pwm
      port map (
         clk_i   => clk,
         red_i   => brd_rgb0(11 downto 8),
         green_i => brd_rgb0(7 downto 4),
         blue_i  => brd_rgb0(3 downto 0),
         rgb_o   => rgb0_o
      ); -- i_rgb_pwm0


   i_rgb_pwm1 : entity work.rgb_pwm
      port map (
         clk_i   => clk,
         red_i   => brd_rgb1(11 downto 8),
         green_i => brd_rgb1(7 downto 4),
         blue_i  => brd_rgb1(3 downto 0),
         rgb_o   => rgb1_o
      ); -- i_rgb_pwm1


   i_seg7 : entity work.seg7
      generic map (
         G_CLOCK_HZ => C_CLOCK_HZ
      )
      port map (
         clk_i => clk,
         seg_i => brd_seg,
         an_o  => seg_an_o,
         ca_o  => seg_ca_o
      ); -- i_seg7


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


   i_kbd_ps2_toggle : entity work.kbd_ps2_toggle
      port map (
         clk_i        => clk,
         rst_i        => rst,
         code_valid_i => ps2_valid,
         code_i       => ps2_code,
         toggle_o     => dbg_toggle
      ); -- i_kbd_ps2_toggle


   i_system : entity work.system
      generic map (
         G_CLOCK_HZ      => C_CLOCK_HZ,
         G_ROM_FILE      => G_ROM_FILE,
         G_RAM_ADDR_BITS => 16,
         G_SCR_ADDR_BITS => 13,
         G_VIDEO         => C_VIDEO,
         G_BOARD_IO      => true,
         G_TOGGLE_KEY    => "Scroll Lock",
         G_SD_SLOTS      => 1,
         G_SD_POWER      => true,
         G_I2C           => true
      )
      port map (
         clk_i        => clk,
         rst_i        => rst,
         uart_rxd_i   => uart_rxd_i,
         uart_txd_o   => uart_txd_o,
         kbd_valid_i  => kbd_valid,
         kbd_ready_o  => kbd_ready,
         kbd_data_i   => kbd_data,
         running_o    => running,
         dbg_toggle_i => dbg_toggle,
         brd_led_o    => brd_led,
         brd_rgb0_o   => brd_rgb0,
         brd_rgb1_o   => brd_rgb1,
         brd_seg_o    => brd_seg,
         brd_btn_i    => btn_i,
         brd_sw_i     => sw_i,
         eth_clk_i    => eth_clk,
         eth_rst_i    => eth_rst,
         eth_rxd_i    => eth_rxd_i,
         eth_crs_dv_i => eth_crs_dv_i,
         eth_rx_er_i  => eth_rxer_i,
         eth_txd_o    => eth_txd_o,
         eth_tx_en_o  => eth_tx_en_o,
         sd_clk_o     => sd_clk,
         sd_cmd_o     => sd_cmd,
         sd_dat3_o    => sd_dat3,
         sd_dat0_i    => '1' & sd_dat0_i,
         sd_cd_n_i    => '1' & sd_cd_n_i,
         sd_pwr_n_o   => sd_pwr_n_o,
         i2c_scl_o    => i2c_scl,
         i2c_sda_o    => i2c_sda,
         i2c_scl_i    => i2c_scl_in,
         i2c_sda_i    => i2c_sda_in,
         vga_clk_i    => vga_clk,
         vga_hs_o     => vga_hs,
         vga_vs_o     => vga_vs,
         vga_de_o     => open,
         vga_red_o    => vga_red,
         vga_green_o  => vga_green,
         vga_blue_o   => vga_blue
      ); -- i_system

   sd_clk_o  <= sd_clk(0);
   sd_cmd_o  <= sd_cmd(0);
   sd_dat3_o <= sd_dat3(0);

   -- The pins are open drain: each buffer drives 0 while the master's
   -- register, its enable, is 0. The buffers are instantiated with their
   -- data tied to 0, as an inferred one takes the register for its data
   -- too, and then the register cannot be in the I/O tile. IOBUF is a
   -- Xilinx primitive, named as in Xilinx's documentation.
-- vsg_off
   i_scl_iobuf : IOBUF
      port map (
         I  => '0',
         T  => i2c_scl,
         O  => i2c_scl_in,
         IO => i2c_scl_io
      ); -- i_scl_iobuf

   i_sda_iobuf : IOBUF
      port map (
         I  => '0',
         T  => i2c_sda,
         O  => i2c_sda_in,
         IO => i2c_sda_io
      ); -- i_sda_iobuf
-- vsg_on


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

   -- The PHY's clock is the early copy of the Ethernet clock (clk_rst.vhd),
   -- forwarded through an ODDR, so it leaves the clock network only in the
   -- IOB.
-- vsg_off
   i_eth_clk : ODDR
      generic map (
         DDR_CLK_EDGE => "SAME_EDGE",
         INIT         => '0',
         SRTYPE       => "SYNC"
      )
      port map (
         Q  => eth_clk_o,
         C  => eth_pin_clk,
         CE => '1',
         D1 => '1',
         D2 => '0',
         R  => '0',
         S  => '0'
      ); -- i_eth_clk
-- vsg_on

   p_eth_rst : process (eth_clk)
   begin
      if rising_edge(eth_clk) then
         eth_rst_n_r <= not eth_rst;
      end if;
   end process p_eth_rst;

   eth_rst_n_o <= eth_rst_n_r;

end architecture synthesis;
