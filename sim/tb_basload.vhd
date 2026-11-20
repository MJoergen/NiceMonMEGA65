-- Tests the load of BASIC's image from a card at the cold start (issue
-- #153, doc/BASIC_ROM.md): the monitor's loader, monitor_basic.nasm, on
-- the RTL's SD card controller, ROM, and lock.
--
-- PASS AND FAIL
-- Each check is an assert with severity failure, which stops GHDL with a
-- nonzero exit status. The test ends with stop(0).
--
-- THEORY OF OPERATION
-- The system has the MEGA65's RAM and ROM, the ROM with the monitor's
-- image of the tests, G_ROM_FILE, and nothing in BASIC's part, and the
-- core runs from reset. Slot 0 holds an SDHC card, G_SECTORS sectors of
-- FAT32, whose first sectors are G_IMAGE_FILE, with NICE/BASIC-T.ROM,
-- sim/basload.nasm; slot 1 is empty. The loader finds the ROM open, takes
-- the file, and copies it into BASIC's part, and the cold start locks the
-- part and runs it. Its cold start prints T1, and jumps to 0, the
-- monitor's cold start again. That one must find the part locked, and
-- run the same image with no load, which prints T2 and halts. p_uart
-- collects the console's bytes from the UART. The checks, once the core
-- has halted:
--
-- 1. The console has the loader's line, then T1, then T2.
-- 2. The loader's line is there once: the second cold start loaded
--    nothing, as the ROM was locked.
--
-- niceemu, whose ROM is RAM, loads at both cold starts.
--
-- The clock is the MEGA65's, the UART runs at 2 Mbaud, and the card's
-- clock at Init is 4 MHz, as in tb_nicemon, so that the test is short.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

library std;
   use std.env.stop;

entity tb_basload is
   generic (
      G_ROM_FILE   : string;
      G_IMAGE_FILE : string;
      G_SECTORS    : positive
   );
end entity tb_basload;

architecture simulation of tb_basload is

   constant C_CLOCK_HZ : natural := 100_000_000;
   constant C_PERIOD   : time    := 1 sec / C_CLOCK_HZ;
   constant C_BAUDRATE : natural := 2_000_000;
   constant C_BIT_TIME : time    := (C_CLOCK_HZ / C_BAUDRATE) * C_PERIOD;
   constant C_TIMEOUT  : time    := 200 ms;
   constant C_OUT_MAX  : natural := 1024;

   signal clk     : std_logic;
   signal rst     : std_logic := '1';
   signal uart_tx : std_logic;
   signal halted  : std_logic;

   signal sd_clk  : std_logic_vector(1 downto 0);
   signal sd_cmd  : std_logic_vector(1 downto 0);
   signal sd_dat3 : std_logic_vector(1 downto 0);
   signal sd_dat0 : std_logic_vector(1 downto 0) := "11";

   -- The console's bytes, as p_uart collects them, and their number
   signal out_s : string(1 to C_OUT_MAX) := (others => ' ');
   signal len_s : natural                := 0;

   -- The position of the first text after position from in the first len
   -- characters of str, or 0
   function find (str : string; len : natural; text : string; from : natural) return natural is
   begin
      for i in from + 1 to len - text'length + 1 loop
         if str(i to i + text'length - 1) = text then
            return i;
         end if;
      end loop;
      return 0;
   end function find;

begin

   p_clk : process
   begin
      clk <= '1', '0' after C_PERIOD / 2;
      wait for C_PERIOD;
   end process p_clk;


   i_nicemon : entity work.nicemon
      generic map (
         G_CLOCK_HZ         => C_CLOCK_HZ,
         G_UART_BAUDRATE    => C_BAUDRATE,
         G_RAM_ADDR_BITS    => 16,
         G_SCR_ADDR_BITS    => 11,
         G_ROM_FILE         => G_ROM_FILE,
         G_CPU_RUN_AT_RESET => true,
         G_SD_SLOTS         => 2,
         G_SD_SLOW_HZ       => 4_000_000
      )
      port map (
         clk_i          => clk,
         rst_i          => rst,
         uart_rxd_i     => '1',
         uart_txd_o     => uart_tx,
         running_o      => open,
         halted_o       => halted,
         scr_we_o       => open,
         scr_addr_o     => open,
         scr_data_o     => open,
         scr_ctl_we_o   => open,
         scr_cur_x_o    => open,
         scr_cur_y_o    => open,
         scr_cur_mode_o => open,
         scr_offs_o     => open,
         brd_led_o      => open,
         brd_rgb0_o     => open,
         brd_rgb1_o     => open,
         brd_seg_o      => open,
         fnt_we_o       => open,
         fnt_addr_o     => open,
         fnt_wdata_o    => open,
         sd_clk_o       => sd_clk,
         sd_cmd_o       => sd_cmd,
         sd_dat3_o      => sd_dat3,
         sd_dat0_i      => sd_dat0,
         sd_cd_n_i      => "10",
         sd_wp_i        => "00"
      ); -- i_nicemon


   i_sd_card_model : entity work.sd_card_model
      generic map (
         G_FILE    => G_IMAGE_FILE,
         G_SECTORS => G_SECTORS,
         G_TYPE    => 2
      )
      port map (
         sclk_i => sd_clk(0),
         mosi_i => sd_cmd(0),
         cs_n_i => sd_dat3(0),
         miso_o => sd_dat0(0)
      ); -- i_sd_card_model


   -- The console's bytes, 8-N-1, into out_s
   p_uart : process
      variable byte_v : std_logic_vector(7 downto 0);
   begin
      wait until uart_tx = '0';
      wait for C_BIT_TIME / 2;
      for i in 0 to 7 loop
         wait for C_BIT_TIME;
         byte_v(i) := uart_tx;
      end loop;
      wait for C_BIT_TIME;
      if len_s < C_OUT_MAX then
         out_s(len_s + 1) <= character'val(to_integer(byte_v));
         len_s            <= len_s + 1;
      end if;
   end process p_uart;


   p_test : process
      constant C_LOAD : string := "BASIC-T.ROM from card 0" & CR & LF;
      constant C_T1   : string := "T1" & CR & LF;
      constant C_T2   : string := "T2" & CR & LF;
      variable load_v : natural;
      variable t1_v   : natural;
      variable t2_v   : natural;
   begin
      wait for 1 us;
      rst <= '0';
      wait until halted = '1' for C_TIMEOUT;
      wait for 100 us;              -- the last bytes out of the UART
      report "tb_basload: the console: " & out_s(1 to len_s);
      assert halted = '1'
         report "tb_basload: no halt after " & time'image(C_TIMEOUT)
         severity failure;
      load_v := find(out_s, len_s, C_LOAD, 0);
      assert load_v /= 0
         report "tb_basload: no line of the load"
         severity failure;
      t1_v   := find(out_s, len_s, C_T1, load_v);
      assert t1_v /= 0
         report "tb_basload: no T1 after the load"
         severity failure;
      t2_v   := find(out_s, len_s, C_T2, t1_v);
      assert t2_v /= 0
         report "tb_basload: no T2 after T1"
         severity failure;
      assert find(out_s, len_s, C_LOAD, load_v) = 0
         report "tb_basload: a second load, with the ROM locked"
         severity failure;
      report "tb_basload: loaded once, at " & time'image(now);
      stop(0);
   end process p_test;

end architecture simulation;
