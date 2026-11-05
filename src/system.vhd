-- The part of every board's top level that does not depend on the board: the
-- NiceMon system (nicemon.vhd) and the text display of its screen
-- (video/text.vhd), which holds the fonts that the system maps
-- (video/font.vhd), with the UART pins synchronized and registered. The
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
-- about a seventeenth of the time it takes at 115200 baud. 2 Mbaud is the
-- rate after reset; 0xFFFFFF9F sets another (board_io.vhd). The video
-- output is that of text.vhd, in the VGA clock domain: 8 bits per color,
-- the two sync signals with the polarity of G_VIDEO, and vga_de_o, which is
-- '1' in the visible area. A board with fewer bits per color takes the top
-- ones. The keyboard input is a stream of ASCII bytes, as kbd_m65_ascii.vhd
-- sends them; a board without a keyboard holds kbd_valid_i at '0'. A board
-- with LEDs, a seven-segment display, buttons, and switches sets G_BOARD_IO
-- and connects the brd_* ports (board_io.vhd has their registers); the other
-- boards leave them open.
-- The Ethernet PHY's pins go to the Ethernet station (eth/eth.vhd), whose
-- MAC and IP addresses are registers of the board (board_io.vhd), and
-- whose counts of frames the core and the link read there too. The station
-- also carries the debug link over TCP, in the UART's place while a host is
-- connected (nicemon.vhd).
-- The SD card slots go to the SD card controller of nicemon.vhd
-- (src/sd/sd.vhd), in SPI mode: per slot, the clock, CMD, the data to the
-- card, and DAT3, its chip select, go out, and DAT0, the data from the
-- card, card detect, and write protect come in. The controller registers
-- them, the first register of each in the I/O tile. A board with fewer
-- slots leaves the ports of the others open.
--
-- With a ROM the core boots from it at reset; without one it waits, held,
-- for a host on the debug link (nicemon.vhd).
--
-- The on-board debugger (dbg/dbg.vhd, doc/DEBUGGER.md) draws into the
-- overlay of the text display. dbg_toggle_i is the board's toggle key, a
-- pulse that the board makes from its keyboard, named by G_TOGGLE_KEY; a
-- board without one leaves it at '0'. While the debugger has the focus, the
-- keyboard's bytes go to it instead of the core's console FIFO. It reads
-- the core through the debug link's side port, beside the UART and TCP
-- host, which keeps its line (nicemon.vhd), and sees the core's pause and
-- halt to catch a stop. With G_BOARD_IO, the buttons are the debugger's
-- in Focus too, and the core reads them as 0, and the display shows the
-- debugger's segments.
--
-- INTERFACE CONTRACTS -- these are requirements on the environment:
-- a) vga_clk_i is the pixel clock of G_VIDEO.
-- b) clk_i runs at G_CLOCK_HZ, as the UART's bit time depends on it.
-- c) eth_clk_i is the PHY's 50 MHz reference clock, and eth_rst_i is
--    synchronous to it and held with rst_i (eth/eth.vhd).
--
-- RESET
-- Synchronous to clk_i, by rst_i, as nicemon.vhd describes, and in the
-- Ethernet clock domain by eth_rst_i. rst_i clears the counts of frames,
-- sets the MAC and IP addresses to G_ETH_MAC and G_ETH_IP, and the UART's
-- baud rate to 2 Mbaud.
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
      -- The RAM has 2^G_RAM_ADDR_BITS words, 128K on the MEGA65 and 64K on
      -- the Nexys4DDR.
      G_RAM_ADDR_BITS : natural      := 16;
      -- The screen has 2^G_SCR_ADDR_BITS words, 32K on the MEGA65.
      G_SCR_ADDR_BITS : natural      := 15;
      G_VIDEO         : t_video_mode := C_VIDEO_1280X1024;
      G_BOARD_IO      : boolean      := false;
      -- The number of breakpoints of the debug link (DEBUG.md §6)
      G_BREAKS        : natural      := 4;
      -- The Ethernet station's addresses after reset; an IP address of 0
      -- answers nothing (board_io.vhd).
      G_ETH_MAC       : std_logic_vector(47 downto 0) := X"024E49434500";
      G_ETH_IP        : std_logic_vector(31 downto 0) := X"00000000";
      -- The board's key that toggles the debugger, as its strip names it
      G_TOGGLE_KEY    : string       := "MEGA+HELP";
      -- The SD card slots, 1 or 2, or 0 for no controller (nicemon.vhd).
      -- Bit i of G_SD_DETECT is '1' when slot
      -- i's card detect and write protect are wired, which slot 1 of the R3
      -- lacks; G_SD_POWER is true when slot 0's power is switched by
      -- sd_pwr_n_o, as on the Nexys4DDR.
      G_SD_SLOTS      : natural range 0 to 2         := 0;
      G_SD_DETECT     : std_logic_vector(1 downto 0) := "11";
      G_SD_POWER      : boolean                      := false
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
      -- '1' for a cycle when the debugger's toggle key is pressed
      dbg_toggle_i : in  std_logic                     := '0';

      -- The board's devices, in the system clock domain (G_BOARD_IO)
      brd_led_o    : out std_logic_vector(15 downto 0);
      brd_rgb0_o   : out std_logic_vector(11 downto 0);
      brd_rgb1_o   : out std_logic_vector(11 downto 0);
      brd_seg_o    : out std_logic_vector(63 downto 0);
      brd_btn_i    : in  std_logic_vector(4 downto 0)  := (others => '0');
      brd_sw_i     : in  std_logic_vector(15 downto 0) := (others => '0');

      -- The Ethernet PHY's pins, in its clock domain
      eth_clk_i    : in  std_logic                    := '0';
      eth_rst_i    : in  std_logic                    := '1';
      eth_rxd_i    : in  std_logic_vector(1 downto 0) := "00";
      eth_crs_dv_i : in  std_logic                    := '0';
      eth_rx_er_i  : in  std_logic                    := '0';
      eth_txd_o    : out std_logic_vector(1 downto 0);
      eth_tx_en_o  : out std_logic;

      -- The SD card slots in SPI mode, bit i for slot i: the clock, CMD
      -- and DAT3 (chip select, low active) to the card, DAT0 from it, card
      -- detect, low with a card in, and write protect; and slot 0's power,
      -- on while sd_pwr_n_o is low
      sd_clk_o     : out std_logic_vector(1 downto 0);
      sd_cmd_o     : out std_logic_vector(1 downto 0);
      sd_dat3_o    : out std_logic_vector(1 downto 0);
      sd_dat0_i    : in  std_logic_vector(1 downto 0) := "11";
      sd_cd_n_i    : in  std_logic_vector(1 downto 0) := "11";
      sd_wp_i      : in  std_logic_vector(1 downto 0) := "00";
      sd_pwr_n_o   : out std_logic;

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
   signal scr_fnt_ram  : std_logic;
   -- The bus's port of the fonts, in the system clock domain
   signal fnt_we    : std_logic;
   signal fnt_addr  : std_logic_vector(13 downto 0);
   signal fnt_wdata : std_logic_vector(15 downto 0);
   signal fnt_rdata : std_logic_vector(15 downto 0);

   -- The Ethernet station's addresses and counts, in the system clock domain
   signal eth_mac    : std_logic_vector(47 downto 0);
   signal eth_ip     : std_logic_vector(31 downto 0);
   signal eth_rx     : std_logic_vector(31 downto 0);
   signal eth_rx_bad : std_logic_vector(31 downto 0);
   signal eth_tx     : std_logic_vector(31 downto 0);
   -- The UART's baud rate after reset, and now; and the link's TCP port
   constant C_UART_BAUDRATE : positive := 2_000_000;
   constant C_TCP_PORT      : natural  := 4510;
   signal   uart_baud       : std_logic_vector(31 downto 0);
   -- The debug link over TCP
   signal net_on       : std_logic;
   signal net_rx_data  : std_logic_vector(7 downto 0);
   signal net_rx_valid : std_logic;
   signal net_rx_ready : std_logic;
   signal net_rx_break : std_logic;
   signal net_rx_renew : std_logic;
   signal net_tx_data  : std_logic_vector(7 downto 0);
   signal net_tx_valid : std_logic;
   signal net_tx_ready : std_logic;
   -- The debugger's requests on the side port of the debug link, and the
   -- core's stops for its catch
   signal dbg_valid  : std_logic;
   signal dbg_we     : std_logic;
   signal dbg_addr   : std_logic_vector(31 downto 0);
   signal dbg_wdata  : std_logic_vector(31 downto 0);
   signal dbg_done   : std_logic;
   signal dbg_err    : std_logic;
   signal dbg_rdata  : std_logic_vector(31 downto 0);
   signal cpu_paused : std_logic;
   signal cpu_halted : std_logic;

   -- The keyboard, to the core and to the debugger
   signal sys_kbd_valid : std_logic;
   signal sys_kbd_ready : std_logic;
   signal dbg_kbd_valid : std_logic;
   signal dbg_kbd_ready : std_logic;
   signal dbg_focus     : std_logic;
   signal dbg_seg       : std_logic_vector(63 downto 0);
   signal sys_seg       : std_logic_vector(63 downto 0);
   signal sys_btn       : std_logic_vector(4 downto 0);

   -- The debugger's overlay
   signal ovl_we    : std_logic;
   signal ovl_addr  : std_logic_vector(11 downto 0);
   signal ovl_data  : std_logic_vector(31 downto 0);
   signal ovl_strip : std_logic;
   signal ovl_page  : std_logic;

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
         G_UART_BAUDRATE    => C_UART_BAUDRATE,
         G_RAM_ADDR_BITS    => G_RAM_ADDR_BITS,
         G_SCR_ADDR_BITS    => G_SCR_ADDR_BITS,
         G_ROM_FILE         => G_ROM_FILE,
         G_ROM_ADDR_BITS    => 15,
         G_CPU_RUN_AT_RESET => G_ROM_FILE /= "",
         G_BOARD_IO         => G_BOARD_IO,
         G_BREAKS           => G_BREAKS,
         G_ETH_MAC          => G_ETH_MAC,
         G_ETH_IP           => G_ETH_IP,
         G_SD_SLOTS         => G_SD_SLOTS,
         G_SD_DETECT        => G_SD_DETECT,
         G_SD_POWER         => G_SD_POWER
      )
      port map (
         clk_i          => clk_i,
         rst_i          => rst_i,
         uart_rxd_i     => rxd(1),
         uart_txd_o     => txd,
         kbd_valid_i    => sys_kbd_valid,
         kbd_ready_o    => sys_kbd_ready,
         kbd_data_i     => kbd_data_i,
         running_o      => running_o,
         paused_o       => cpu_paused,
         halted_o       => cpu_halted,
         scr_we_o       => scr_we,
         scr_addr_o     => scr_addr,
         scr_data_o     => scr_data,
         scr_ctl_we_o   => scr_ctl_we,
         scr_cur_x_o    => scr_cur_x,
         scr_cur_y_o    => scr_cur_y,
         scr_cur_mode_o => scr_cur_mode,
         scr_offs_o     => scr_offs,
         scr_fnt_ram_o  => scr_fnt_ram,
         fnt_we_o       => fnt_we,
         fnt_addr_o     => fnt_addr,
         fnt_wdata_o    => fnt_wdata,
         fnt_rdata_i    => fnt_rdata,
         brd_led_o      => brd_led_o,
         brd_rgb0_o     => brd_rgb0_o,
         brd_rgb1_o     => brd_rgb1_o,
         brd_seg_o      => sys_seg,
         brd_btn_i      => sys_btn,
         brd_sw_i       => brd_sw_i,
         eth_rx_i       => eth_rx,
         eth_rx_bad_i   => eth_rx_bad,
         eth_tx_i       => eth_tx,
         eth_mac_o      => eth_mac,
         eth_ip_o       => eth_ip,
         uart_baud_o    => uart_baud,
         net_on_i       => net_on,
         net_rx_data_i  => net_rx_data,
         net_rx_valid_i => net_rx_valid,
         net_rx_ready_o => net_rx_ready,
         net_rx_break_i => net_rx_break,
         net_rx_renew_i => net_rx_renew,
         net_tx_data_o  => net_tx_data,
         net_tx_valid_o => net_tx_valid,
         net_tx_ready_i => net_tx_ready,
         dbg_valid_i    => dbg_valid,
         dbg_we_i       => dbg_we,
         dbg_addr_i     => dbg_addr,
         dbg_wdata_i    => dbg_wdata,
         dbg_done_o     => dbg_done,
         dbg_err_o      => dbg_err,
         dbg_rdata_o    => dbg_rdata,
         sd_clk_o       => sd_clk_o,
         sd_cmd_o       => sd_cmd_o,
         sd_dat3_o      => sd_dat3_o,
         sd_dat0_i      => sd_dat0_i,
         sd_cd_n_i      => sd_cd_n_i,
         sd_wp_i        => sd_wp_i,
         sd_pwr_n_o     => sd_pwr_n_o
      ); -- i_nicemon


   i_eth : entity work.eth
      generic map (
         G_CLOCK_HZ => G_CLOCK_HZ,
         G_PORT     => C_TCP_PORT
      )
      port map (
         clk_i       => clk_i,
         rst_i       => rst_i,
         mac_i       => eth_mac,
         ip_i        => eth_ip,
         rx_o        => eth_rx,
         rx_bad_o    => eth_rx_bad,
         tx_o        => eth_tx,
         on_o        => net_on,
         lrx_data_o  => net_rx_data,
         lrx_valid_o => net_rx_valid,
         lrx_ready_i => net_rx_ready,
         lrx_break_o => net_rx_break,
         lrx_renew_o => net_rx_renew,
         ltx_data_i  => net_tx_data,
         ltx_valid_i => net_tx_valid,
         ltx_ready_o => net_tx_ready,
         eth_clk_i   => eth_clk_i,
         eth_rst_i   => eth_rst_i,
         rxd_i       => eth_rxd_i,
         crs_dv_i    => eth_crs_dv_i,
         rx_er_i     => eth_rx_er_i,
         txd_o       => eth_txd_o,
         tx_en_o     => eth_tx_en_o
      ); -- i_eth


   -- The keyboard's bytes go to the debugger while it has the focus, and to
   -- the core otherwise.
   sys_kbd_valid <= kbd_valid_i and not dbg_focus;
   dbg_kbd_valid <= kbd_valid_i and dbg_focus;
   kbd_ready_o   <= dbg_kbd_ready when dbg_focus = '1' else sys_kbd_ready;

   -- So are the board's buttons, which the core reads as 0 meanwhile, and
   -- the display shows the debugger's segments.
   sys_btn   <= brd_btn_i when dbg_focus = '0' else (others => '0');
   brd_seg_o <= dbg_seg when dbg_focus = '1' else sys_seg;


   i_dbg : entity work.dbg
      generic map (
         G_CLOCK_HZ      => G_CLOCK_HZ,
         G_TOGGLE_KEY    => G_TOGGLE_KEY,
         G_BOARD_IO      => G_BOARD_IO,
         G_TCP_PORT      => C_TCP_PORT,
         G_UART_BAUDRATE => C_UART_BAUDRATE
      )
      port map (
         clk_i       => clk_i,
         rst_i       => rst_i,
         toggle_i    => dbg_toggle_i,
         kbd_valid_i => dbg_kbd_valid,
         kbd_ready_o => dbg_kbd_ready,
         kbd_data_i  => kbd_data_i,
         lnk_valid_o => dbg_valid,
         lnk_we_o    => dbg_we,
         lnk_addr_o  => dbg_addr,
         lnk_data_o  => dbg_wdata,
         lnk_done_i  => dbg_done,
         lnk_err_i   => dbg_err,
         lnk_rdata_i => dbg_rdata,
         paused_i    => cpu_paused,
         halted_i    => cpu_halted,
         set_ip_i    => eth_ip,
         set_mac_i   => eth_mac,
         set_baud_i  => uart_baud,
         ovl_we_o    => ovl_we,
         ovl_addr_o  => ovl_addr,
         ovl_data_o  => ovl_data,
         strip_o     => ovl_strip,
         page_o      => ovl_page,
         focus_o     => dbg_focus,
         btn_i       => brd_btn_i,
         seg_o       => dbg_seg
      ); -- i_dbg


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
         fnt_ram_i   => scr_fnt_ram,
         fnt_we_i    => fnt_we,
         fnt_addr_i  => fnt_addr,
         fnt_wdata_i => fnt_wdata,
         fnt_rdata_o => fnt_rdata,
         ovl_we_i    => ovl_we,
         ovl_addr_i  => ovl_addr,
         ovl_data_i  => ovl_data,
         strip_i     => ovl_strip,
         page_i      => ovl_page,
         vga_clk_i   => vga_clk_i,
         vga_hs_o    => vga_hs_o,
         vga_vs_o    => vga_vs_o,
         vga_de_o    => vga_de_o,
         vga_red_o   => vga_red_o,
         vga_green_o => vga_green_o,
         vga_blue_o  => vga_blue_o
      ); -- i_text

end architecture synthesis;
