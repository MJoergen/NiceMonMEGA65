-- The part of every board's top level that does not depend on the board: the
-- NiceMon system (nicemon.vhd) and the text display of its screen
-- (video/text.vhd), with the UART pins synchronized and registered. The
-- board level makes the clocks and resets, drives the keyboard, if the board
-- has one, and turns the video output into the board's VGA or HDMI signals.
--
-- THEORY OF OPERATION
-- The UART input passes through two registers, a synchronizer, and the UART
-- output through one, so that it changes only on the clock edge. The UART
-- runs at 2 Mbaud, a bit of 50 cycles at 100 MHz and of 45 at 90 MHz, the
-- clocks of the MEGA65 and the Nexys4DDR. The FT2232H USB chip on the
-- other end of both boards makes exactly 2 Mbaud from its 12 MHz clock.
-- The link sends every word as 8 hex digits, so a load at 2 Mbaud takes
-- about a seventeenth of the time it takes at 115200 baud. The video
-- output is that of text.vhd, in the VGA clock domain: 8 bits per color,
-- the two sync signals with the polarity of G_VIDEO, and vga_de_o, which is
-- '1' in the visible area. A board with fewer bits per color takes the top
-- ones. The keyboard input is a stream of ASCII bytes, as kbd_m65_ascii.vhd
-- sends them; a board without a keyboard holds kbd_valid_i at '0'. A board
-- with LEDs, a seven-segment display, buttons, and switches sets G_BOARD_IO
-- and connects the brd_* ports (board_io.vhd has their registers); the other
-- boards leave them open.
-- The Ethernet PHY's receive pins go to the RMII receiver (eth/rmii_rx.vhd)
-- in the PHY's 50 MHz clock domain, and its bytes to the check of the frame
-- check sequence (eth/rx_fcs.vhd), and the good frames go through the FIFO
-- of received frames (eth/eth_rx_fifo.vhd) to clk_i. Nothing reads the
-- frames yet: the FIFO's output is always taken, and each frame that comes
-- out counts in eth_rx. Each bad frame, and each good one that found the
-- FIFO full, flips eth_toggle in the PHY's clock domain; two registers
-- synchronize it to clk_i, where each change counts in eth_rx_bad. A frame
-- takes more than 100 cycles of the PHY's clock, so no change is lost. The
-- core and the link read the counts at 0xFFFFFF98 and 0xFFFFFF99.
--
-- With a ROM the core boots from it at reset; without one it waits, held,
-- for a host on the debug link (nicemon.vhd).
--
-- INTERFACE CONTRACTS -- these are requirements on the environment:
-- a) vga_clk_i is the pixel clock of G_VIDEO.
-- b) clk_i runs at G_CLOCK_HZ, as the UART's bit time depends on it.
-- c) eth_clk_i is the PHY's 50 MHz reference clock, and eth_rst_i is
--    synchronous to it.
--
-- RESET
-- Synchronous to clk_i, by rst_i, as nicemon.vhd describes, and in the
-- Ethernet clock domain by eth_rst_i. rst_i clears the counts of frames.
-- The video has no reset of its own (text.vhd).

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

library work;
   use work.video_pkg.all;

entity system is
   generic (
      G_CLOCK_HZ      : natural;
      -- The ROM that the core boots from, a .bin file, or "" for a build without one
      G_ROM_FILE      : string       := "";
      -- The screen has 2^G_SCR_ADDR_BITS words, 32K on the MEGA65.
      G_SCR_ADDR_BITS : natural      := 15;
      G_VIDEO         : t_video_mode := C_VIDEO_1280X1024;
      G_BOARD_IO      : boolean      := false;
      -- The number of breakpoints of the debug link (DEBUG.md §6)
      G_BREAKS        : natural      := 4
   );
   port (
      clk_i        : in  std_logic;
      rst_i        : in  std_logic;
      uart_rxd_i   : in  std_logic;
      uart_txd_o   : out std_logic;
      kbd_valid_i  : in  std_logic;
      kbd_ready_o  : out std_logic;
      kbd_data_i   : in  std_logic_vector(7 downto 0);
      running_o    : out std_logic;

      -- The board's devices, in the system clock domain (G_BOARD_IO)
      brd_led_o    : out std_logic_vector(15 downto 0);
      brd_rgb0_o   : out std_logic_vector(11 downto 0);
      brd_rgb1_o   : out std_logic_vector(11 downto 0);
      brd_seg_o    : out std_logic_vector(63 downto 0);
      brd_btn_i    : in  std_logic_vector(4 downto 0)  := (others => '0');
      brd_sw_i     : in  std_logic_vector(15 downto 0) := (others => '0');

      -- The Ethernet PHY's receive pins, in its clock domain
      eth_clk_i    : in  std_logic                    := '0';
      eth_rst_i    : in  std_logic                    := '1';
      eth_rxd_i    : in  std_logic_vector(1 downto 0) := "00";
      eth_crs_dv_i : in  std_logic                    := '0';

      -- The video, in the VGA clock domain
      vga_clk_i    : in  std_logic;
      vga_hs_o     : out std_logic;
      vga_vs_o     : out std_logic;
      vga_de_o     : out std_logic;
      vga_red_o    : out std_logic_vector(7 downto 0);
      vga_green_o  : out std_logic_vector(7 downto 0);
      vga_blue_o   : out std_logic_vector(7 downto 0)
   );
end entity system;

architecture synthesis of system is

   signal rxd : std_logic_vector(1 downto 0) := "11";
   attribute async_reg : string;
   attribute async_reg of rxd : signal is "TRUE";
   signal txd : std_logic;

   -- The output register starts at the idle level of the pin. A flip-flop
   -- with no initial value configures as 0, which would hold the UART output
   -- low, a break, until the MMCM locks and the clock runs.
   signal txd_reg : std_logic := '1';

   -- The writes to the screen and its registers, in the system clock domain
   signal scr_we       : std_logic;
   signal scr_addr     : std_logic_vector(G_SCR_ADDR_BITS - 1 downto 0);
   signal scr_data     : std_logic_vector(31 downto 0);
   signal scr_ctl_we   : std_logic;
   signal scr_cur_x    : std_logic_vector(6 downto 0);
   signal scr_cur_y    : std_logic_vector(4 downto 0);
   signal scr_cur_mode : std_logic_vector(2 downto 0);
   signal scr_offs     : std_logic_vector(G_SCR_ADDR_BITS - 1 downto 0);

   -- The frames received, in the Ethernet clock domain
   signal eth_data  : std_logic_vector(7 downto 0);
   signal eth_valid : std_logic;
   signal eth_eof   : std_logic;
   signal eth_err   : std_logic;
   signal eth_ok    : std_logic;
   signal eth_bad   : std_logic;
   signal eth_drop  : std_logic;
   -- Flips at each bad or dropped frame
   signal eth_toggle : std_logic := '0';
   -- The good frames, in the system clock domain
   signal eth_last : std_logic;
   signal eth_out  : std_logic;
   -- eth_toggle synchronized to clk_i, its value before, and the counts
   signal eth_sync     : std_logic_vector(1 downto 0)  := "00";
   signal eth_toggle_d : std_logic                     := '0';
   signal eth_rx       : std_logic_vector(31 downto 0) := (others => '0');
   signal eth_rx_bad   : std_logic_vector(31 downto 0) := (others => '0');
   attribute async_reg of eth_sync : signal is "TRUE";

begin

   -- Synchronize the UART input, and register the output.
   p_uart : process (clk_i)
   begin
      if rising_edge(clk_i) then
         rxd     <= rxd(0) & uart_rxd_i;
         txd_reg <= txd;
      end if;
   end process p_uart;

   uart_txd_o <= txd_reg;


   i_nicemon : entity work.nicemon
      generic map (
         G_CLOCK_HZ         => G_CLOCK_HZ,
         G_UART_BAUDRATE    => 2_000_000,
         G_RAM_ADDR_BITS    => 16,
         G_SCR_ADDR_BITS    => G_SCR_ADDR_BITS,
         G_ROM_FILE         => G_ROM_FILE,
         G_ROM_ADDR_BITS    => 15,
         G_CPU_RUN_AT_RESET => G_ROM_FILE /= "",
         G_BOARD_IO         => G_BOARD_IO,
         G_BREAKS           => G_BREAKS
      )
      port map (
         clk_i          => clk_i,
         rst_i          => rst_i,
         uart_rxd_i     => rxd(1),
         uart_txd_o     => txd,
         kbd_valid_i    => kbd_valid_i,
         kbd_ready_o    => kbd_ready_o,
         kbd_data_i     => kbd_data_i,
         running_o      => running_o,
         scr_we_o       => scr_we,
         scr_addr_o     => scr_addr,
         scr_data_o     => scr_data,
         scr_ctl_we_o   => scr_ctl_we,
         scr_cur_x_o    => scr_cur_x,
         scr_cur_y_o    => scr_cur_y,
         scr_cur_mode_o => scr_cur_mode,
         scr_offs_o     => scr_offs,
         brd_led_o      => brd_led_o,
         brd_rgb0_o     => brd_rgb0_o,
         brd_rgb1_o     => brd_rgb1_o,
         brd_seg_o      => brd_seg_o,
         brd_btn_i      => brd_btn_i,
         brd_sw_i       => brd_sw_i,
         eth_rx_i       => eth_rx,
         eth_rx_bad_i   => eth_rx_bad
      ); -- i_nicemon


   i_rmii_rx : entity work.rmii_rx
      port map (
         clk_i    => eth_clk_i,
         rst_i    => eth_rst_i,
         rxd_i    => eth_rxd_i,
         crs_dv_i => eth_crs_dv_i,
         data_o   => eth_data,
         valid_o  => eth_valid,
         eof_o    => eth_eof,
         err_o    => eth_err
      ); -- i_rmii_rx

   i_rx_fcs : entity work.rx_fcs
      port map (
         clk_i   => eth_clk_i,
         rst_i   => eth_rst_i,
         data_i  => eth_data,
         valid_i => eth_valid,
         eof_i   => eth_eof,
         err_i   => eth_err,
         ok_o    => eth_ok,
         bad_o   => eth_bad
      ); -- i_rx_fcs

   i_eth_rx_fifo : entity work.eth_rx_fifo
      port map (
         wr_clk_i   => eth_clk_i,
         wr_rst_i   => eth_rst_i,
         wr_data_i  => eth_data,
         wr_valid_i => eth_valid,
         wr_ok_i    => eth_ok,
         wr_bad_i   => eth_bad,
         wr_drop_o  => eth_drop,
         rd_clk_i   => clk_i,
         rd_rst_i   => rst_i,
         rd_data_o  => open,
         rd_last_o  => eth_last,
         rd_valid_o => eth_out,
         rd_ready_i => '1'
      ); -- i_eth_rx_fifo

   p_eth_toggle : process (eth_clk_i)
   begin
      if rising_edge(eth_clk_i) then
         if eth_bad = '1' or eth_drop = '1' then
            eth_toggle <= not eth_toggle;
         end if;
      end if;
   end process p_eth_toggle;

   p_eth_rx : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if eth_out = '1' and eth_last = '1' then
            eth_rx <= eth_rx + 1;
         end if;

         eth_sync     <= eth_sync(0) & eth_toggle;
         eth_toggle_d <= eth_sync(1);
         if eth_sync(1) /= eth_toggle_d then
            eth_rx_bad <= eth_rx_bad + 1;
         end if;

         if rst_i = '1' then
            eth_rx     <= (others => '0');
            eth_rx_bad <= (others => '0');
         end if;
      end if;
   end process p_eth_rx;


   i_text : entity work.text
      generic map (
         G_MODE          => G_VIDEO,
         G_SCR_ADDR_BITS => G_SCR_ADDR_BITS
      )
      port map (
         clk_i       => clk_i,
         scr_we_i    => scr_we,
         scr_addr_i  => scr_addr,
         scr_data_i  => scr_data,
         ctl_we_i    => scr_ctl_we,
         cur_x_i     => scr_cur_x,
         cur_y_i     => scr_cur_y,
         cur_mode_i  => scr_cur_mode,
         offs_i      => scr_offs,
         vga_clk_i   => vga_clk_i,
         vga_hs_o    => vga_hs_o,
         vga_vs_o    => vga_vs_o,
         vga_de_o    => vga_de_o,
         vga_red_o   => vga_red_o,
         vga_green_o => vga_green_o,
         vga_blue_o  => vga_blue_o
      ); -- i_text

end architecture synthesis;
