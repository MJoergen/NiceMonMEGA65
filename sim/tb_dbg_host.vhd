-- Tests the debugger's host in hardware (src/dbg/dbg_host.vhd), stage 2 of
-- doc/DEBUGGER.md, against the debug link itself: the whole system,
-- nicemon.vhd, with the host on its third link input, dbg_on_i.
--
-- PASS AND FAIL
-- Each check is an assert with severity failure, which stops GHDL with a
-- nonzero exit status. The test ends with stop(0).
--
-- THEORY OF OPERATION
-- p_main makes word-level requests of the host, as the debugger will, and
-- checks their answers. p_mon collects what the host gives out: the words
-- of an `r`, the notices, and the console bytes, which must be 0x00, 0x01,
-- and so on, as G_HOST_FILE writes them, 0xFF among them as the link sends
-- it, ESC ESC. p_uart checks that the UART sends nothing while the host
-- has the link. The steps:
--
-- 1. The link's `b05` after reset reaches the host, and the version
--    register reads 5.
-- 2. Hold, clear, and hide the ROM, load G_HOST_FILE with W requests, and
--    read its words back with one R.
-- 3. Start the core. Its console bytes arrive, in order, while the host
--    reads the control register, and a read of the memory gets `e02`.
-- 4. Pause: the host gets `p`, and the console bytes stop. R0-R15 read in
--    one R of 16 words: R1 is the byte at 0x100 or the one after it, and
--    R15 is in the program. A step sends `p` again, and R15 moves to the
--    next instruction, each of which is two words.
-- 5. Go on: the console bytes come again, in order.
-- 6. A packet on the UART is dropped while the host has the link, and the
--    link sends nothing on the UART.
-- 7. Hold the core. With dbg_on_i at '0', the host's request is dropped,
--    and it ends with the timeout's error code.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use std.textio.all;
   use std.env.all;

entity tb_dbg_host is
   generic (
      G_HOST_FILE : string
   );
end entity tb_dbg_host;

architecture simulation of tb_dbg_host is

   constant C_CLOCK_HZ : natural := 90_000_000;
   constant C_PERIOD   : time    := 1 sec / C_CLOCK_HZ;
   constant C_BAUDRATE : natural := 9_000_000;
   constant C_BIT_TIME : time    := (C_CLOCK_HZ / C_BAUDRATE) * C_PERIOD;
   -- The host's timeout, in cycles, longer than the clear of the memory,
   -- and the longest wait of p_main
   constant C_HOST_TIMEOUT : natural := 20_000;
   constant C_TIMEOUT      : time    := 1 ms;

   constant C_CTRL : std_logic_vector(31 downto 0) := X"FFFFFFF0";
   constant C_VER  : std_logic_vector(31 downto 0) := X"FFFFFFF2";
   constant C_REGS : std_logic_vector(31 downto 0) := X"FFFFFFE0";
   constant C_NEXT : std_logic_vector(31 downto 0) := X"00000100";

   type t_words is array (0 to 255) of std_logic_vector(31 downto 0);

   signal clk     : std_logic;
   signal rst     : std_logic := '1';
   signal uart_rx : std_logic := '1';
   signal uart_tx : std_logic;
   signal dbg_on  : std_logic := '1';

   signal req_valid : std_logic := '0';
   signal req_ready : std_logic;
   signal req_we    : std_logic := '0';
   signal req_addr  : std_logic_vector(31 downto 0) := (others => '0');
   signal req_n     : std_logic_vector(15 downto 0) := (others => '0');
   signal req_data  : std_logic_vector(31 downto 0) := (others => '0');
   signal rd_valid  : std_logic;
   signal rd_data   : std_logic_vector(31 downto 0);
   signal done      : std_logic;
   signal err       : std_logic;
   signal err_code  : std_logic_vector(7 downto 0);
   signal ntc_valid : std_logic;
   signal ntc_tag   : std_logic_vector(7 downto 0);
   signal ntc_arg   : std_logic_vector(7 downto 0);
   signal con_valid : std_logic;
   signal con_data  : std_logic_vector(7 downto 0);

   signal lrx_valid : std_logic;
   signal lrx_ready : std_logic;
   signal lrx_data  : std_logic_vector(7 downto 0);
   signal ltx_valid : std_logic;
   signal ltx_ready : std_logic;
   signal ltx_data  : std_logic_vector(7 downto 0);

   -- What p_mon collected: the words of the last `r` (rd_clr starts
   -- again), the last notice and the count of notices, and the console
   -- bytes, their count and the last one
   signal rd_clr    : std_logic := '0';
   signal rd_words  : t_words;
   signal rd_cnt    : natural   := 0;
   signal ntc_cnt   : natural   := 0;
   signal ntc_last  : std_logic_vector(15 downto 0);
   signal con_cnt   : natural   := 0;
   signal con_last  : std_logic_vector(7 downto 0);
   signal uart_sent : boolean   := false;

begin

   p_clk : process
   begin
      clk <= '1', '0' after C_PERIOD / 2;
      wait for C_PERIOD;
   end process p_clk;


   i_nicemon : entity work.nicemon
      generic map (
         G_CLOCK_HZ      => C_CLOCK_HZ,
         G_UART_BAUDRATE => C_BAUDRATE,
         G_RAM_ADDR_BITS => 12,
         G_SCR_ADDR_BITS => 11,
         G_RX_FIFO_BITS  => 4,
         G_ROM_ADDR_BITS => 11
      )
      port map (
         clk_i          => clk,
         rst_i          => rst,
         uart_rxd_i     => uart_rx,
         uart_txd_o     => uart_tx,
         dbg_on_i       => dbg_on,
         dbg_rx_data_i  => lrx_data,
         dbg_rx_valid_i => lrx_valid,
         dbg_rx_ready_o => lrx_ready,
         dbg_tx_data_o  => ltx_data,
         dbg_tx_valid_o => ltx_valid,
         dbg_tx_ready_i => ltx_ready
      ); -- i_nicemon


   i_dbg_host : entity work.dbg_host
      generic map (
         G_TIMEOUT => C_HOST_TIMEOUT
      )
      port map (
         clk_i       => clk,
         rst_i       => rst,
         req_valid_i => req_valid,
         req_ready_o => req_ready,
         req_we_i    => req_we,
         req_addr_i  => req_addr,
         req_n_i     => req_n,
         req_data_i  => req_data,
         rd_valid_o  => rd_valid,
         rd_data_o   => rd_data,
         done_o      => done,
         err_o       => err,
         err_code_o  => err_code,
         ntc_valid_o => ntc_valid,
         ntc_tag_o   => ntc_tag,
         ntc_arg_o   => ntc_arg,
         con_valid_o => con_valid,
         con_data_o  => con_data,
         lrx_valid_o => lrx_valid,
         lrx_ready_i => lrx_ready,
         lrx_data_o  => lrx_data,
         ltx_valid_i => ltx_valid,
         ltx_ready_o => ltx_ready,
         ltx_data_i  => ltx_data
      ); -- i_dbg_host


   p_mon : process (clk)
   begin
      if rising_edge(clk) then
         if rd_valid = '1' then
            rd_words(rd_cnt) <= rd_data;
            rd_cnt           <= rd_cnt + 1;
         end if;
         if rd_clr = '1' then
            rd_cnt <= 0;
         end if;

         if ntc_valid = '1' then
            ntc_last <= ntc_tag & ntc_arg;
            ntc_cnt  <= ntc_cnt + 1;
         end if;

         if con_valid = '1' then
            assert con_cnt = 0 or con_data = con_last + 1
               report "tb_dbg_host: console byte " & to_hstring(con_data) & " after " & to_hstring(con_last)
               severity failure;
            con_last <= con_data;
            con_cnt  <= con_cnt + 1;
         end if;
      end if;
   end process p_mon;


   p_uart : process (uart_tx)
   begin
      if uart_tx = '0' then
         uart_sent <= true;
      end if;
   end process p_uart;


   p_main : process
      variable first_v : std_logic_vector(31 downto 0);
      variable words_v : t_words;
      variable len_v   : natural;
      variable cnt_v   : natural;
      variable ntc_v   : natural;
      variable r15_v   : std_logic_vector(31 downto 0);
      variable next_v  : std_logic_vector(31 downto 0);

      -- Makes a request, and waits for its end. On return, err and
      -- err_code are those of the end, and rd_words has the words of an `r`.
      procedure request(we   : std_logic;
                        addr : std_logic_vector(31 downto 0);
                        n    : natural;
                        data : std_logic_vector(31 downto 0) := X"00000000") is
      begin
         wait until rising_edge(clk) and req_ready = '1';
         rd_clr    <= '1';
         req_valid <= '1';
         req_we    <= we;
         req_addr  <= addr;
         req_n     <= to_slv(n, 16);
         req_data  <= data;
         wait until rising_edge(clk);
         rd_clr    <= '0';
         req_valid <= '0';
         wait until rising_edge(clk) and done = '1' for C_TIMEOUT;
         assert done = '1'
            report "tb_dbg_host: no end of the request to " & to_hstring(addr)
            severity failure;
      end procedure request;

      procedure wr(addr : std_logic_vector(31 downto 0);
                   data : std_logic_vector(31 downto 0)) is
      begin
         request('1', addr, 1, data);
         assert err = '0'
            report "tb_dbg_host: W " & to_hstring(addr) & " got e" & to_hstring(err_code)
            severity failure;
      end procedure wr;

      procedure rd(addr : std_logic_vector(31 downto 0);
                   n    : natural) is
      begin
         request('0', addr, n);
         wait until rising_edge(clk);
         assert err = '0'
            report "tb_dbg_host: R " & to_hstring(addr) & " got e" & to_hstring(err_code)
            severity failure;
         assert rd_cnt = n
            report "tb_dbg_host: R " & to_hstring(addr) & " got " & to_string(rd_cnt) & " words"
            severity failure;
      end procedure rd;

      procedure check(addr : std_logic_vector(31 downto 0);
                      data : std_logic_vector(31 downto 0)) is
      begin
         rd(addr, 1);
         assert rd_words(0) = data
            report "tb_dbg_host: " & to_hstring(addr) & " reads " & to_hstring(rd_words(0)) &
                   ", not " & to_hstring(data)
            severity failure;
      end procedure check;

      -- Waits for the notice after the count ntc_v, and checks it
      procedure expect_ntc(tag : character;
                           arg : std_logic_vector(7 downto 0)) is
      begin
         if ntc_cnt = ntc_v then
            wait until ntc_cnt /= ntc_v for C_TIMEOUT;
         end if;
         assert ntc_cnt = ntc_v + 1 and ntc_last = to_slv(character'pos(tag), 8) & arg
            report "tb_dbg_host: no notice " & tag & to_hstring(arg)
            severity failure;
         ntc_v := ntc_cnt;
      end procedure expect_ntc;

      -- Waits until the console has n more bytes
      procedure expect_con(n : natural) is
      begin
         cnt_v := con_cnt;
         wait until con_cnt >= cnt_v + n for C_TIMEOUT;
         assert con_cnt >= cnt_v + n
            report "tb_dbg_host: " & to_string(con_cnt - cnt_v) & " console bytes, not " & to_string(n)
            severity failure;
      end procedure expect_con;

      procedure send_byte(b : std_logic_vector(7 downto 0)) is
      begin
         uart_rx <= '0';
         wait for C_BIT_TIME;
         for i in 0 to 7 loop
            uart_rx <= b(i);
            wait for C_BIT_TIME;
         end loop;
         uart_rx <= '1';
         wait for C_BIT_TIME;
      end procedure send_byte;

      procedure send(s : string) is
      begin
         for i in s'range loop
            send_byte(to_slv(character'pos(s(i)), 8));
         end loop;
      end procedure send;

      -- Reads the words of the .bin file
      procedure read_bin(name : string) is
         file     f      : text;
         variable l      : line;
         variable addr_v : std_logic_vector(31 downto 0);
         variable word_v : std_logic_vector(31 downto 0);
      begin
         len_v := 0;
         file_open(f, name, read_mode);
         while not endfile(f) loop
            readline(f, l);
            if l'length > 0 then
               hread(l, addr_v);
               hread(l, word_v);
               assert addr_v = len_v
                  report "tb_dbg_host: " & name & " is not one block from 0"
                  severity failure;
               words_v(len_v) := word_v;
               len_v          := len_v + 1;
            end if;
         end loop;
         file_close(f);
      end procedure read_bin;

   begin
      ntc_v := 0;
      wait for 10 * C_PERIOD;
      wait until rising_edge(clk);
      rst <= '0';

      -- 1. b05, and the version
      expect_ntc('b', X"05");
      check(C_VER, X"00000005");

      -- 2. Load the program, and read it back
      wr(C_CTRL, X"0000000D");
      check(C_CTRL, X"00000009");
      read_bin(G_HOST_FILE);
      for i in 0 to len_v - 1 loop
         wr(to_slv(i, 32), words_v(i));
      end loop;
      rd(X"00000000", len_v);
      for i in 0 to len_v - 1 loop
         assert rd_words(i) = words_v(i)
            report "tb_dbg_host: word " & to_string(i) & " reads " & to_hstring(rd_words(i))
            severity failure;
      end loop;

      -- 3. Run, with the link's own registers in reach and the memory not
      assert con_cnt = 0
         report "tb_dbg_host: console bytes before the start"
         severity failure;
      wr(C_CTRL, X"00000008");
      expect_con(300);
      check(C_CTRL, X"00000008");
      request('0', C_NEXT, 1);
      assert err = '1' and err_code = X"02"
         report "tb_dbg_host: a read of the memory while the core runs"
         severity failure;
      expect_con(10);

      -- 4. Pause, read the registers, and step
      wr(C_CTRL, X"00000018");
      expect_ntc('p', X"00");
      cnt_v := con_cnt;
      check(C_CTRL, X"00000018");
      rd(C_NEXT, 1);
      next_v := rd_words(0);
      rd(C_REGS, 16);
      assert rd_words(1) = next_v or rd_words(1) = ((next_v + 1) and X"000000FF")
         report "tb_dbg_host: R1 is " & to_hstring(rd_words(1)) & " at a pause, the byte at 0x100 " &
                to_hstring(next_v)
         severity failure;
      r15_v := rd_words(15);
      assert r15_v >= 2 and r15_v < len_v
         report "tb_dbg_host: R15 is " & to_hstring(r15_v) & " at a pause"
         severity failure;
      wait for 20 us;
      assert con_cnt = cnt_v
         report "tb_dbg_host: console bytes while paused"
         severity failure;
      wr(C_CTRL, X"00000038");
      expect_ntc('p', X"00");
      if r15_v = 10 then
         check(C_REGS + 15, X"00000002");
      else
         check(C_REGS + 15, r15_v + 2);
      end if;

      -- 5. Go on
      wr(C_CTRL, X"00000008");
      expect_con(300);

      -- 6. The UART's bytes are dropped
      send(character'val(255) & "RFFFFFFF20001#33");
      wait for 20 us;
      check(C_VER, X"00000005");
      assert not uart_sent
         report "tb_dbg_host: the UART sent while the host has the link"
         severity failure;

      -- 7. Hold, and the timeout
      wr(C_CTRL, X"00000009");
      wait until rising_edge(clk);
      dbg_on <= '0';
      request('0', C_VER, 1);
      assert err = '1' and err_code = X"FF"
         report "tb_dbg_host: a dropped request does not time out"
         severity failure;

      report "tb_dbg_host: done";
      stop(0);
   end process p_main;

end architecture simulation;
