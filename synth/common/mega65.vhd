-- The part of the top level that is the same on all MEGA65 boards: the clock
-- and reset, the UART pins, the keyboard, the NiceMon system, and the video
-- output of its screen. The keyboard types into the same input as the UART.
-- Its power LED is green, and its drive LED is green while the core runs,
-- like the user LED.
--
-- The screen is shown as 80x25 characters (src/video/text.vhd) at 1280x1024
-- @ 60 Hz, on the VGA connector and on the HDMI connector. The video, the
-- video DAC, and the HDMI output are as in MandelbrotMEGA65's mega65.vhd:
-- * The VGA output goes through a video DAC with 8 bits per colour. The DAC
--   samples on the rising edge of its clock, which is the VGA clock
--   inverted, so in the middle of each pixel. The colour and the sync
--   signals are registered in the IOBs, so they all change at the same time,
--   half a clock cycle (4.6 ns) before the DAC samples them.
-- * The HDMI output is in DVI mode (no audio and no InfoFrames), because
--   1280x1024 is not a CEA-861 video mode. vga_to_hdmi.vhd (in hdmi/, from
--   The Tyto Project) encodes the picture to TMDS symbols, and the
--   serialisers send them with the TMDS clock (540 MHz, on both edges).
-- The clocks of the video come from their own MMCM (video_clk.vhd).

library ieee;
   use ieee.std_logic_1164.all;

library unisim;
   use unisim.vcomponents.all;

library work;
   use work.video_pkg.all;
   use work.types_pkg.all;

entity mega65 is
   generic (
      -- The ROM with the monitor, a .bin file, or "" for a build without a
      -- ROM, whose core waits for the command line (see src/nicemon.vhd)
      G_ROM_FILE : string := ""
   );
   port (
      clk_i          : in  std_logic; -- 100 MHz
      reset_button_i : in  std_logic; -- active high
      uart_rxd_i     : in  std_logic;
      uart_txd_o     : out std_logic;
      kb_io0_o       : out std_logic; -- clock to the keyboard
      kb_io1_o       : out std_logic; -- data to the keyboard
      kb_io2_i       : in  std_logic; -- data from the keyboard
      led_o          : out std_logic; -- on while the core runs

      -- VGA via the video DAC
      vga_red_o      : out std_logic_vector(7 downto 0);
      vga_green_o    : out std_logic_vector(7 downto 0);
      vga_blue_o     : out std_logic_vector(7 downto 0);
      vga_hs_o       : out std_logic;
      vga_vs_o       : out std_logic;
      vdac_clk_o     : out std_logic;
      vdac_sync_n_o  : out std_logic;
      vdac_blank_n_o : out std_logic;

      -- HDMI
      tmds_data_p_o  : out std_logic_vector(2 downto 0);
      tmds_data_n_o  : out std_logic_vector(2 downto 0);
      tmds_clk_p_o   : out std_logic;
      tmds_clk_n_o   : out std_logic
   );
end entity mega65;

architecture synthesis of mega65 is

   constant C_CLOCK_HZ : natural := 50_000_000;

   signal clk     : std_logic;
   signal rst     : std_logic;
   signal rxd     : std_logic_vector(1 downto 0) := "11";
   attribute async_reg : string;
   attribute async_reg of rxd : signal is "TRUE";
   signal txd     : std_logic;
   signal running : std_logic;

   constant C_GREEN : std_logic_vector(23 downto 0) := X"00FF00";

   signal kbd_matrix : std_logic_vector(79 downto 0);
   signal kbd_valid  : std_logic;
   signal kbd_ready  : std_logic;
   signal kbd_data   : std_logic_vector(7 downto 0);
   signal drive_rgb  : std_logic_vector(23 downto 0);

   -- The output registers start at the idle level of their pins. A flip-flop
   -- with no initial value configures as 0, which would hold the UART output
   -- low, a break, until the MMCM locks and the clock runs.
   signal txd_reg : std_logic := '1';
   signal led_reg : std_logic := '0';

   constant C_VIDEO : t_video_mode := C_VIDEO_1280X1024;

   -- The screen's size, and the writes to it and its registers, in the
   -- system clock domain
   constant C_SCR_ADDR_BITS : natural := 15;

   signal scr_we       : std_logic;
   signal scr_addr     : std_logic_vector(C_SCR_ADDR_BITS - 1 downto 0);
   signal scr_data     : std_logic_vector(31 downto 0);
   signal scr_ctl_we   : std_logic;
   signal scr_cur_x    : std_logic_vector(6 downto 0);
   signal scr_cur_y    : std_logic_vector(4 downto 0);
   signal scr_cur_mode : std_logic_vector(2 downto 0);
   signal scr_offs     : std_logic_vector(C_SCR_ADDR_BITS - 1 downto 0);

   signal vga_clk   : std_logic;
   signal vga_rst   : std_logic;
   signal tmds_clk  : std_logic;
   signal vga_hs    : std_logic;
   signal vga_vs    : std_logic;
   signal vga_de    : std_logic;
   signal vga_red   : std_logic_vector(7 downto 0);
   signal vga_green : std_logic_vector(7 downto 0);
   signal vga_blue  : std_logic_vector(7 downto 0);

   -- The sync signals, active high, for vga_to_hdmi
   signal hdmi_hs : std_logic;
   signal hdmi_vs : std_logic;
   -- The TMDS symbols of the three HDMI data channels
   signal hdmi_tmds : slv_9_0_t(0 to 2);

   -- The registers of the outputs to the DAC, in the IOBs (IOB TRUE on their
   -- ports, in common.xdc). keep stops synthesis from merging equal colour
   -- registers, which could then not all be in the IOBs.
   signal vdac_red_r   : std_logic_vector(7 downto 0);
   signal vdac_green_r : std_logic_vector(7 downto 0);
   signal vdac_blue_r  : std_logic_vector(7 downto 0);
   signal vdac_hs_r    : std_logic;
   signal vdac_vs_r    : std_logic;

   attribute keep : string;
   attribute keep of vdac_red_r   : signal is "true";
   attribute keep of vdac_green_r : signal is "true";
   attribute keep of vdac_blue_r  : signal is "true";

begin

   i_clk_rst : entity work.clk_rst
      port map (
         sys_clk_i      => clk_i,
         reset_button_i => reset_button_i,
         clk_o          => clk,
         rst_o          => rst
      ); -- i_clk_rst

   -- Synchronise the UART input, and register the outputs.
   p_io : process (clk)
   begin
      if rising_edge(clk) then
         rxd     <= rxd(0) & uart_rxd_i;
         txd_reg <= txd;
         led_reg <= running;
      end if;
   end process p_io;

   uart_txd_o <= txd_reg;
   led_o      <= led_reg;

   drive_rgb <= C_GREEN when running = '1' else X"000000";

   i_kbd_m65 : entity work.kbd_m65
      generic map (
         G_CLOCK_HZ => C_CLOCK_HZ
      )
      port map (
         clk_i       => clk,
         rst_i       => rst,
         matrix_o    => kbd_matrix,
         power_rgb_i => C_GREEN,
         drive_rgb_i => drive_rgb,
         kb_clk_o    => kb_io0_o,
         kb_data_o   => kb_io1_o,
         kb_data_i   => kb_io2_i
      ); -- i_kbd_m65

   i_kbd_ascii : entity work.kbd_ascii
      generic map (
         G_CLOCK_HZ => C_CLOCK_HZ
      )
      port map (
         clk_i        => clk,
         rst_i        => rst,
         matrix_i     => kbd_matrix,
         data_valid_o => kbd_valid,
         data_ready_i => kbd_ready,
         data_o       => kbd_data
      ); -- i_kbd_ascii

   -- With a ROM the core boots from it at reset; without one it waits for
   -- the command line.
   i_nicemon : entity work.nicemon
      generic map (
         G_CLOCK_HZ         => C_CLOCK_HZ,
         G_UART_BAUDRATE    => 115_200,
         G_RAM_ADDR_BITS    => 16,
         G_SCR_ADDR_BITS    => C_SCR_ADDR_BITS,
         G_ROM_FILE         => G_ROM_FILE,
         G_ROM_ADDR_BITS    => 15,
         G_CPU_RUN_AT_RESET => G_ROM_FILE /= ""
      )
      port map (
         clk_i          => clk,
         rst_i          => rst,
         uart_rxd_i     => rxd(1),
         uart_txd_o     => txd,
         kbd_valid_i    => kbd_valid,
         kbd_ready_o    => kbd_ready,
         kbd_data_i     => kbd_data,
         running_o      => running,
         scr_we_o       => scr_we,
         scr_addr_o     => scr_addr,
         scr_data_o     => scr_data,
         scr_ctl_we_o   => scr_ctl_we,
         scr_cur_x_o    => scr_cur_x,
         scr_cur_y_o    => scr_cur_y,
         scr_cur_mode_o => scr_cur_mode,
         scr_offs_o     => scr_offs
      ); -- i_nicemon


   ---------------------------------------------------------------------------
   -- The video: the screen as text
   ---------------------------------------------------------------------------

   i_video_clk : entity work.video_clk
      port map (
         sys_clk_i  => clk_i,
         vga_clk_o  => vga_clk,
         vga_rst_o  => vga_rst,
         tmds_clk_o => tmds_clk
      ); -- i_video_clk

   i_text : entity work.text
      generic map (
         G_MODE          => C_VIDEO,
         G_SCR_ADDR_BITS => C_SCR_ADDR_BITS
      )
      port map (
         clk_i       => clk,
         scr_we_i    => scr_we,
         scr_addr_i  => scr_addr,
         scr_data_i  => scr_data,
         ctl_we_i    => scr_ctl_we,
         cur_x_i     => scr_cur_x,
         cur_y_i     => scr_cur_y,
         cur_mode_i  => scr_cur_mode,
         offs_i      => scr_offs,
         vga_clk_i   => vga_clk,
         vga_hs_o    => vga_hs,
         vga_vs_o    => vga_vs,
         vga_de_o    => vga_de,
         vga_red_o   => vga_red,
         vga_green_o => vga_green,
         vga_blue_o  => vga_blue
      ); -- i_text


   ---------------------------------------------------------------------------
   -- The video DAC
   ---------------------------------------------------------------------------

   p_vdac : process (vga_clk)
   begin
      if rising_edge(vga_clk) then
         vdac_red_r   <= vga_red;
         vdac_green_r <= vga_green;
         vdac_blue_r  <= vga_blue;
         vdac_hs_r    <= vga_hs;
         vdac_vs_r    <= vga_vs;
      end if;
   end process p_vdac;

   vga_red_o   <= vdac_red_r;
   vga_green_o <= vdac_green_r;
   vga_blue_o  <= vdac_blue_r;
   vga_hs_o    <= vdac_hs_r;
   vga_vs_o    <= vdac_vs_r;

   -- The DAC's clock is low in the first half of the VGA clock cycle and high
   -- in the second, the VGA clock inverted. ODDR is a Xilinx primitive, named
   -- as in Xilinx's documentation.
-- vsg_off
   i_vdac_clk : ODDR
      generic map (
         DDR_CLK_EDGE => "SAME_EDGE",
         INIT         => '0',
         SRTYPE       => "SYNC"
      )
      port map (
         Q  => vdac_clk_o,
         C  => vga_clk,
         CE => '1',
         D1 => '0',
         D2 => '1',
         R  => '0',
         S  => '0'
      ); -- i_vdac_clk
-- vsg_on

   vdac_sync_n_o  <= '0';  -- No sync on green
   vdac_blank_n_o <= '1';  -- The colour is black outside the visible area


   ---------------------------------------------------------------------------
   -- HDMI, in DVI mode
   ---------------------------------------------------------------------------

   hdmi_hs <= vga_hs xnor C_VIDEO.sync_active;
   hdmi_vs <= vga_vs xnor C_VIDEO.sync_active;

   -- vic is 0, as 1280x1024 is not a CEA-861 video mode, and aspect is "00",
   -- no data.
   i_vga_to_hdmi : entity work.vga_to_hdmi
      port map (
         select_44100 => '0',
         dvi          => '1',
         vic          => X"00",
         aspect       => "00",
         pix_rep      => '0',
         vs_pol       => C_VIDEO.sync_active,
         hs_pol       => C_VIDEO.sync_active,
         vga_rst      => vga_rst,
         vga_clk      => vga_clk,
         vga_vs       => hdmi_vs,
         vga_hs       => hdmi_hs,
         vga_de       => vga_de,
         vga_r        => vga_red,
         vga_g        => vga_green,
         vga_b        => vga_blue,
         pcm_rst      => vga_rst,
         pcm_clk      => vga_clk,
         pcm_clken    => '0',
         pcm_l        => (others => '0'),
         pcm_r        => (others => '0'),
         pcm_acr      => '0',
         pcm_n        => (others => '0'),
         pcm_cts      => (others => '0'),
         tmds         => hdmi_tmds
      ); -- i_vga_to_hdmi

   gen_hdmi_data : for i in 0 to 2 generate

      i_hdmi_data : entity work.serialiser_10to1_selectio
         port map (
            rst    => vga_rst,
            clk    => vga_clk,
            clk_x5 => tmds_clk,
            d      => hdmi_tmds(i),
            out_p  => tmds_data_p_o(i),
            out_n  => tmds_data_n_o(i)
         ); -- i_hdmi_data

   end generate gen_hdmi_data;

   -- The HDMI clock is the VGA clock: five ones and five zeros per pixel.
   i_hdmi_clk : entity work.serialiser_10to1_selectio
      port map (
         rst    => vga_rst,
         clk    => vga_clk,
         clk_x5 => tmds_clk,
         d      => "0000011111",
         out_p  => tmds_clk_p_o,
         out_n  => tmds_clk_n_o
      ); -- i_hdmi_clk

end architecture synthesis;
