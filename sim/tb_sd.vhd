-- Tests the SD card controller (src/sd/sd.vhd) on two card models
-- (sd_card_model.vhd), through its registers, as a program would use them
-- (nice_cpu's SYSTEM.md §5).
--
-- PASS AND FAIL
-- Each check is an assert with severity failure, which stops GHDL with a
-- nonzero exit status. The test ends with stop(0).
--
-- THEORY OF OPERATION
-- Slot 0 holds an SDHC card of 1024 sectors, whose first sectors are
-- G_IMAGE_FILE, in which byte o is o mod 251 for o < 1024; slot 1 holds
-- an SDSC card of version 1 of 2048 sectors, which takes byte addresses.
-- The clock is the MEGA65's, and the card's clocks are the real ones.
-- p_lines checks, all along, that a slot that no command uses rests, with
-- its clock low and chip select high. The steps:
--
-- 1. After reset both slots show a card, "changed", and SD_SLOTS is 2.
-- 2. Init of slot 0: type 2, SD_LAST 1023. Read sector 1: the bytes of the
--    image. Write sector 5, read sector 0, then sector 5: as written. Read
--    sector 1000, which the image does not fill: zeros.
-- 3. A Read whose block comes with a bad CRC16: error 4.
-- 4. Init of slot 1: type 1, SD_LAST 2047. Write sector 2047, read sector
--    3, and sector 2047 again, which checks the byte addresses of SDSC.
-- 5. Slot 1's write protect: a Write fails with error 6.
-- 6. A start of the core, dev_rst, during a Read of slot 1 abandons it,
--    with no end reported; an Init after it starts the card again, which
--    may still be sending its block.
-- 7. A card that answers nothing: Init fails with error 3, and a Read
--    then with error 2, not ready.
-- 8. Slot 1's card taken out: after the 10 ms of the debounce, "present"
--    falls, and with it "ready".

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use std.env.all;

entity tb_sd is
   generic (
      G_IMAGE_FILE : string
   );
end entity tb_sd;

architecture simulation of tb_sd is

   constant C_CLOCK_HZ : natural := 100_000_000;
   constant C_PERIOD   : time    := 1 sec / C_CLOCK_HZ;

   signal clk     : std_logic;
   signal rst     : std_logic := '1';
   signal dev_rst : std_logic := '1';

   signal wb_cyc   : std_logic := '0';
   signal wb_stb   : std_logic := '0';
   signal wb_stall : std_logic;
   signal wb_ack   : std_logic;
   signal wb_we    : std_logic := '0';
   signal wb_addr  : std_logic_vector(3 downto 0)  := X"0";
   signal wb_wdata : std_logic_vector(31 downto 0) := (others => '0');
   signal wb_rdata : std_logic_vector(31 downto 0);
   signal busy     : std_logic;

   signal sd_clk  : std_logic_vector(1 downto 0);
   signal sd_cmd  : std_logic_vector(1 downto 0);
   signal sd_dat3 : std_logic_vector(1 downto 0);
   signal sd_dat0 : std_logic_vector(1 downto 0);
   signal sd_cd_n : std_logic_vector(1 downto 0) := "00";
   signal sd_wp   : std_logic_vector(1 downto 0) := "00";

   signal crc_err : std_logic := '0';
   signal dead    : std_logic := '0';

   constant C_CSR    : std_logic_vector(3 downto 0) := X"0";
   constant C_LBA    : std_logic_vector(3 downto 0) := X"1";
   constant C_CHUNK  : std_logic_vector(3 downto 0) := X"2";
   constant C_ERROR  : std_logic_vector(3 downto 0) := X"3";
   constant C_SELECT : std_logic_vector(3 downto 0) := X"4";
   constant C_LAST   : std_logic_vector(3 downto 0) := X"5";
   constant C_SLOTS  : std_logic_vector(3 downto 0) := X"6";
   constant C_BUF0   : std_logic_vector(3 downto 0) := X"8";

begin

   p_clk : process
   begin
      clk <= '1', '0' after C_PERIOD / 2;
      wait for C_PERIOD;
   end process p_clk;


   i_sd : entity work.sd
      generic map (
         G_CLOCK_HZ => C_CLOCK_HZ,
         G_SLOTS    => 2
      )
      port map (
         clk_i      => clk,
         rst_i      => rst,
         dev_rst_i  => dev_rst,
         wb_cyc_i   => wb_cyc,
         wb_stb_i   => wb_stb,
         wb_stall_o => wb_stall,
         wb_ack_o   => wb_ack,
         wb_we_i    => wb_we,
         wb_addr_i  => wb_addr,
         wb_data_i  => wb_wdata,
         wb_data_o  => wb_rdata,
         busy_o     => busy,
         sd_clk_o   => sd_clk,
         sd_cmd_o   => sd_cmd,
         sd_dat3_o  => sd_dat3,
         sd_dat0_i  => sd_dat0,
         sd_cd_n_i  => sd_cd_n,
         sd_wp_i    => sd_wp,
         sd_pwr_n_o => open
      ); -- i_sd

   i_card0 : entity work.sd_card_model
      generic map (
         G_FILE    => G_IMAGE_FILE,
         G_SECTORS => 1024,
         G_TYPE    => 2
      )
      port map (
         sclk_i    => sd_clk(0),
         mosi_i    => sd_cmd(0),
         cs_n_i    => sd_dat3(0),
         miso_o    => sd_dat0(0),
         crc_err_i => crc_err,
         dead_i    => dead
      ); -- i_card0

   i_card1 : entity work.sd_card_model
      generic map (
         G_SECTORS => 2048,
         G_TYPE    => 1,
         G_V1      => true
      )
      port map (
         sclk_i => sd_clk(1),
         mosi_i => sd_cmd(1),
         cs_n_i => sd_dat3(1),
         miso_o => sd_dat0(1)
      ); -- i_card1


   -- A slot that the engine does not serve rests, so the two slots are
   -- never selected or clocked at once.
   p_lines : process (clk)
   begin
      if rising_edge(clk) and rst = '0' then
         assert not (sd_dat3(0) = '0' and sd_dat3(1) = '0')
            report "tb_sd: both slots selected"
            severity failure;
         assert not (sd_clk(0) = '1' and sd_clk(1) = '1')
            report "tb_sd: both slots clocked"
            severity failure;
      end if;
   end process p_lines;


   p_main : process

      procedure wb(we : std_logic; addr : std_logic_vector(3 downto 0);
                   wdata : std_logic_vector(31 downto 0);
                   rdata : out std_logic_vector(31 downto 0)) is
      begin
         -- Away from the rising edge, after a wait for a time
         wait until falling_edge(clk);
         wb_cyc   <= '1';
         wb_stb   <= '1';
         wb_we    <= we;
         wb_addr  <= addr;
         wb_wdata <= wdata;
         wait until rising_edge(clk) and wb_stall = '0';
         wb_stb <= '0';
         while wb_ack = '0' loop
            wait until rising_edge(clk);
         end loop;
         rdata  := wb_rdata;
         wb_cyc <= '0';
      end procedure wb;

      procedure wr(addr : std_logic_vector(3 downto 0); data : std_logic_vector(31 downto 0)) is
         variable d_v : std_logic_vector(31 downto 0);
      begin
         wb('1', addr, data, d_v);
      end procedure wr;

      procedure check(addr : std_logic_vector(3 downto 0); data : std_logic_vector(31 downto 0);
                      what : string) is
         variable d_v : std_logic_vector(31 downto 0);
      begin
         wb('0', addr, X"00000000", d_v);
         assert d_v = data
            report "tb_sd: " & what & ": " & to_hstring(d_v) & ", not " & to_hstring(data)
            severity failure;
      end procedure check;

      -- Run a command and wait for its end, with a bound on the wait
      procedure run(cmd : natural; what : string) is
         variable d_v : std_logic_vector(31 downto 0);
      begin
         wr(C_CSR, to_slv(cmd, 32));
         for i in 0 to 2_000_000 loop
            wb('0', C_CSR, X"00000000", d_v);
            exit when d_v(0) = '0';
            wait for 1 us;
         end loop;
         assert d_v(0) = '0'
            report "tb_sd: " & what & " does not end"
            severity failure;
      end procedure run;

      -- The word w of the buffer, through SD_CHUNK and SD_BUF0-7
      procedure buf_rd(w : natural; data : out std_logic_vector(31 downto 0)) is
      begin
         wr(C_CHUNK, to_slv(w / 8, 32));
         wb('0', C_BUF0 + w mod 8, X"00000000", data);
      end procedure buf_rd;

      procedure buf_wr(w : natural; data : std_logic_vector(31 downto 0)) is
      begin
         wr(C_CHUNK, to_slv(w / 8, 32));
         wr(C_BUF0 + w mod 8, data);
      end procedure buf_wr;

      -- The word w of the image's sector s: byte o is o mod 251 below 1024
      function image(s : natural; w : natural) return std_logic_vector is
         variable d_v : std_logic_vector(31 downto 0);
         variable o_v : natural;
      begin
         for j in 0 to 3 loop
            o_v := s * 512 + 4 * w + j;
            if o_v < 1024 then
               d_v(8 * j + 7 downto 8 * j) := to_slv(o_v mod 251, 8);
            else
               d_v(8 * j + 7 downto 8 * j) := X"00";
            end if;
         end loop;
         return d_v;
      end function image;

      -- A pattern for the writes, from a seed
      function pattern(seed : natural; w : natural) return std_logic_vector is
      begin
         return to_slv((seed * 7919 + w * 1009) mod 65521, 16) & to_slv(w * 3 + seed, 16);
      end function pattern;

      procedure check_sector(s : natural; what : string) is
         variable d_v : std_logic_vector(31 downto 0);
      begin
         for w in 0 to 127 loop
            buf_rd(w, d_v);
            assert d_v = image(s, w)
               report "tb_sd: " & what & ", word " & integer'image(w) & ": " & to_hstring(d_v) &
                      ", not " & to_hstring(image(s, w))
               severity failure;
         end loop;
      end procedure check_sector;

      procedure check_pattern(seed : natural; what : string) is
         variable d_v : std_logic_vector(31 downto 0);
      begin
         for w in 0 to 127 loop
            buf_rd(w, d_v);
            assert d_v = pattern(seed, w)
               report "tb_sd: " & what & ", word " & integer'image(w) & ": " & to_hstring(d_v) &
                      ", not " & to_hstring(pattern(seed, w))
               severity failure;
         end loop;
      end procedure check_pattern;

      variable d_v : std_logic_vector(31 downto 0);

   begin
      wait for 10 * C_PERIOD;
      wait until rising_edge(clk);
      rst     <= '0';
      dev_rst <= '0';
      wait until rising_edge(clk);

      report "tb_sd: 1. after reset";
      check(C_SLOTS, X"00000002", "SD_SLOTS");
      check(C_CSR, X"00000014", "SD_CSR of slot 0");
      check(C_LAST, X"00000000", "SD_LAST before Init");

      report "tb_sd: 2. slot 0, SDHC";
      run(0, "Init of slot 0");
      check(C_ERROR, X"00000000", "the error of Init");
      check(C_CSR, X"0000020C", "SD_CSR after Init");
      check(C_LAST, X"000003FF", "SD_LAST");
      wr(C_LBA, X"00000001");
      run(1, "Read of sector 1");
      check(C_ERROR, X"00000000", "the error of Read");
      check_sector(1, "sector 1");
      for w in 0 to 127 loop
         buf_wr(w, pattern(1, w));
      end loop;
      wr(C_LBA, X"00000005");
      run(2, "Write of sector 5");
      check(C_ERROR, X"00000000", "the error of Write");
      wr(C_LBA, X"00000000");
      run(1, "Read of sector 0");
      check_sector(0, "sector 0");
      wr(C_LBA, X"00000005");
      run(1, "Read of sector 5");
      check_pattern(1, "sector 5 as written");
      wr(C_LBA, X"000003E8");
      run(1, "Read of sector 1000");
      check_sector(1000, "sector 1000");

      report "tb_sd: 3. a bad CRC16";
      crc_err <= '1';
      wr(C_LBA, X"00000001");
      run(1, "Read with a bad CRC");
      check(C_ERROR, X"00000004", "the error of a bad CRC");
      crc_err <= '0';
      run(1, "Read after it");
      check(C_ERROR, X"00000000", "the error of the Read after a bad CRC");
      check_sector(1, "sector 1 after a bad CRC");

      report "tb_sd: 4. slot 1, SDSC of version 1";
      wr(C_SELECT, X"00000001");
      check(C_CSR, X"00000014", "SD_CSR of slot 1");
      run(0, "Init of slot 1");
      check(C_ERROR, X"00000000", "the error of Init of slot 1");
      check(C_CSR, X"0000010C", "SD_CSR after Init of slot 1");
      check(C_LAST, X"000007FF", "SD_LAST of slot 1");
      for w in 0 to 127 loop
         buf_wr(w, pattern(2, w));
      end loop;
      wr(C_LBA, X"000007FF");
      run(2, "Write of sector 2047");
      check(C_ERROR, X"00000000", "the error of Write of sector 2047");
      wr(C_LBA, X"00000003");
      run(1, "Read of sector 3");
      check_sector(3, "sector 3 of slot 1");
      wr(C_LBA, X"000007FF");
      run(1, "Read of sector 2047");
      check_pattern(2, "sector 2047 as written");

      report "tb_sd: 5. write protect";
      sd_wp(1) <= '1';
      wait for 1 us;
      check(C_CSR, X"0000012C", "SD_CSR with write protect");
      run(2, "Write with write protect");
      check(C_ERROR, X"00000006", "the error of a write-protected Write");
      sd_wp(1) <= '0';

      report "tb_sd: 6. a start of the core during a Read";
      run(1, "Read of sector 2047");
      wr(C_CSR, X"00000001");
      wait for 20 us;
      dev_rst <= '1';
      wait until rising_edge(clk);
      dev_rst <= '0';
      wait until rising_edge(clk);
      check(C_CSR, X"00000014", "SD_CSR after the start");
      check(C_ERROR, X"00000000", "SD_ERROR after the start");
      wr(C_SELECT, X"00000001");
      run(0, "Init after the start");
      check(C_ERROR, X"00000000", "the error of Init after the start");
      wr(C_LBA, X"000007FF");
      run(1, "Read of sector 2047 after the start");
      check_pattern(2, "sector 2047 after the start");

      report "tb_sd: 7. a card that answers nothing";
      wr(C_SELECT, X"00000000");
      dead <= '1';
      run(0, "Init of a dead card");
      check(C_ERROR, X"00000003", "the error of Init of a dead card");
      run(1, "Read of a dead card");
      check(C_ERROR, X"00000002", "the error of Read after a failed Init");
      dead <= '0';

      report "tb_sd: 8. slot 1's card taken out";
      wr(C_SELECT, X"00000001");
      run(0, "Init of slot 1");
      check(C_CSR, X"0000010C", "SD_CSR of slot 1 before");
      sd_cd_n(1) <= '1';
      wait for 5 ms;
      check(C_CSR, X"0000010C", "SD_CSR of slot 1 within the debounce");
      wait for 6 ms;
      check(C_CSR, X"00000000", "SD_CSR of slot 1 taken out");
      sd_cd_n(1) <= '0';
      wait for 11 ms;
      check(C_CSR, X"00000014", "SD_CSR of slot 1 put back");

      report "tb_sd: done";
      stop(0);
   end process p_main;

end architecture simulation;
