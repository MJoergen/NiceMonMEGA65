-- Tests the debugger's adapter to the debug link's side port
-- (src/dbg/dbg_host.vhd), stage 9 of doc/DEBUGGER.md, against the link
-- itself: the whole system, nicemon.vhd, with the adapter on its side
-- port, dbg_*, and a host on the UART beside it.
--
-- PASS AND FAIL
-- Each check is an assert with severity failure, which stops GHDL with a
-- nonzero exit status. The test ends with stop(0).
--
-- THEORY OF OPERATION
-- p_main makes word-level requests of the adapter, as the debugger does,
-- and checks their answers. p_mon collects the words of a read. p_uart_rx
-- decodes the UART output as a host does: the console bytes, which must
-- be 0x00, 0x01, and so on, as G_HOST_FILE writes them, 0xFF among them as
-- the link sends it, ESC ESC, and the packets, counted, the last one kept.
-- p_uart_tx sends a packet on the UART when p_main asks, so that p_main
-- can make requests meanwhile. The steps:
--
-- 1. The link's `b05` after reset goes to the UART, and the version
--    register reads 5 through the adapter.
-- 2. Hold, clear, and hide the ROM, load G_HOST_FILE with writes, which
--    wait for the clear, and read its words back with one read.
-- 3. Start the core. Its console bytes arrive on the UART, in order,
--    while the adapter reads the control register, and a read of the
--    memory is refused: e02.
-- 4. Pause: the UART gets `p`, the stop that the adapter caused, and the
--    console bytes stop. R0-R15 read in one request of 16 words: R1 is the
--    byte at 0x100 or the one after it, and R15 is in the program. A step
--    sends `p` again, and R15 moves to the next instruction, each of
--    which is two words.
-- 5. The host keeps its line: an R packet on the UART for the version
--    register is answered while the adapter reads the control register
--    again and again, and a W packet that lets the core go on lands in a
--    long read of the memory of the adapter's, which ends with e02 after
--    the words it got while the core was paused. The console bytes come
--    again, in order.
-- 6. Hold the core, and a read of no words ends at once.

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
   -- The longest wait of p_main, longer than the clear of the memory
   constant C_TIMEOUT : time := 1 ms;

   constant C_CTRL : std_logic_vector(31 downto 0) := X"FFFFFFF0";
   constant C_VER  : std_logic_vector(31 downto 0) := X"FFFFFFF2";
   constant C_REGS : std_logic_vector(31 downto 0) := X"FFFFFFE0";
   constant C_NEXT : std_logic_vector(31 downto 0) := X"00000100";
   -- The words of the long read of step 5, the whole RAM of the test
   constant C_LONG : natural := 4096;

   constant C_ESC : character := character'val(255);

   type t_words is array (0 to C_LONG - 1) of std_logic_vector(31 downto 0);

   signal clk     : std_logic;
   signal rst     : std_logic := '1';
   signal uart_rx : std_logic := '1';
   signal uart_tx : std_logic;

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

   signal side_valid : std_logic;
   signal side_we    : std_logic;
   signal side_addr  : std_logic_vector(31 downto 0);
   signal side_wdata : std_logic_vector(31 downto 0);
   signal side_done  : std_logic;
   signal side_err   : std_logic;
   signal side_rdata : std_logic_vector(31 downto 0);

   -- What p_mon collected: the words of the last read (rd_clr starts
   -- again)
   signal rd_clr   : std_logic := '0';
   signal rd_words : t_words;
   signal rd_cnt   : natural   := 0;

   -- What p_uart_rx collected: the console bytes, their count and the
   -- last one, and the packets, their count and the last one, from its
   -- tag to its checksum
   signal con_cnt  : natural                      := 0;
   signal con_last : std_logic_vector(7 downto 0) := (others => '0');
   signal pkt_cnt  : natural                      := 0;
   signal pkt_last : string(1 to 32)              := (others => ' ');
   signal pkt_len  : natural                      := 0;

   -- The packet that p_uart_tx sends, from its ESC, when send_req toggles
   signal send_str : string(1 to 32) := (others => ' ');
   signal send_len : natural         := 0;
   signal send_req : std_logic       := '0';
   signal send_ack : std_logic       := '0';

   -- The checksum of DEBUG.md §2, in two hex digits
   function cksum(s : string) return string is
      variable sum_v : natural := 0;
   begin
      for i in s'range loop
         sum_v := (sum_v + character'pos(s(i))) mod 256;
      end loop;
      return to_hstring(to_slv(sum_v, 8));
   end function cksum;

   -- A packet, from its tag to its checksum
   function pkt(tag : character; payload : string) return string is
   begin
      return tag & payload & "#" & cksum(tag & payload);
   end function pkt;

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
         clk_i       => clk,
         rst_i       => rst,
         uart_rxd_i  => uart_rx,
         uart_txd_o  => uart_tx,
         dbg_valid_i => side_valid,
         dbg_we_i    => side_we,
         dbg_addr_i  => side_addr,
         dbg_wdata_i => side_wdata,
         dbg_done_o  => side_done,
         dbg_err_o   => side_err,
         dbg_rdata_o => side_rdata
      ); -- i_nicemon


   i_dbg_host : entity work.dbg_host
      port map (
         clk_i        => clk,
         rst_i        => rst,
         req_valid_i  => req_valid,
         req_ready_o  => req_ready,
         req_we_i     => req_we,
         req_addr_i   => req_addr,
         req_n_i      => req_n,
         req_data_i   => req_data,
         rd_valid_o   => rd_valid,
         rd_data_o    => rd_data,
         done_o       => done,
         err_o        => err,
         err_code_o   => err_code,
         side_valid_o => side_valid,
         side_we_o    => side_we,
         side_addr_o  => side_addr,
         side_data_o  => side_wdata,
         side_done_i  => side_done,
         side_err_i   => side_err,
         side_data_i  => side_rdata
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
      end if;
   end process p_mon;


   -- The UART's bytes, as a host splits them: a console byte, ESC ESC as
   -- the console byte 0xFF, or a packet from ESC and its tag to the two
   -- digits after `#`
   p_uart_rx : process
      variable b_v   : std_logic_vector(7 downto 0);
      variable esc_v : boolean := false;
      variable pkt_v : boolean := false;
      variable str_v : string(1 to 32);
      variable len_v : natural := 0;
      variable end_v : natural := 0;                     -- Digits left after #
   begin
      wait until uart_tx = '0';
      wait for C_BIT_TIME / 2;
      assert uart_tx = '0'
         report "tb_dbg_host: a glitch on the UART"
         severity failure;
      for i in 0 to 7 loop
         wait for C_BIT_TIME;
         b_v(i) := uart_tx;
      end loop;
      wait for C_BIT_TIME;
      assert uart_tx = '1'
         report "tb_dbg_host: a bad stop bit on the UART"
         severity failure;

      if pkt_v then
         len_v        := len_v + 1;
         str_v(len_v) := character'val(to_integer(b_v));
         if end_v /= 0 then
            end_v := end_v - 1;
            if end_v = 0 then
               pkt_v    := false;
               pkt_last <= str_v;
               pkt_len  <= len_v;
               pkt_cnt  <= pkt_cnt + 1;
            end if;
         elsif b_v = X"23" then
            end_v := 2;
         end if;
      elsif esc_v then
         esc_v := false;
         if b_v = X"FF" then
            assert con_cnt = 0 or b_v = con_last + 1
               report "tb_dbg_host: console byte FF after " & to_hstring(con_last)
               severity failure;
            con_last <= b_v;
            con_cnt  <= con_cnt + 1;
         else
            pkt_v    := true;
            len_v    := 1;
            str_v    := (others => ' ');
            str_v(1) := character'val(to_integer(b_v));
         end if;
      elsif b_v = X"FF" then
         esc_v := true;
      else
         assert con_cnt = 0 or b_v = con_last + 1
            report "tb_dbg_host: console byte " & to_hstring(b_v) & " after " & to_hstring(con_last)
            severity failure;
         con_last <= b_v;
         con_cnt  <= con_cnt + 1;
      end if;
   end process p_uart_rx;


   -- A packet to the UART, when p_main asks
   p_uart_tx : process
      variable b_v : std_logic_vector(7 downto 0);
   begin
      wait until send_req /= send_ack;
      for i in 1 to send_len loop
         b_v     := to_slv(character'pos(send_str(i)), 8);
         uart_rx <= '0';
         wait for C_BIT_TIME;
         for j in 0 to 7 loop
            uart_rx <= b_v(j);
            wait for C_BIT_TIME;
         end loop;
         uart_rx <= '1';
         wait for C_BIT_TIME;
      end loop;
      send_ack <= send_req;
   end process p_uart_tx;


   p_main : process
      variable words_v : t_words;
      variable len_v   : natural;
      variable cnt_v   : natural;
      variable pkts_v  : natural;
      variable r15_v   : std_logic_vector(31 downto 0);
      variable next_v  : std_logic_vector(31 downto 0);

      -- Makes a request, and waits for its end. On return, err is that of
      -- the end, and rd_words has the words of a read.
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
         wait until rising_edge(clk);
      end procedure request;

      procedure wr(addr : std_logic_vector(31 downto 0);
                   data : std_logic_vector(31 downto 0)) is
      begin
         request('1', addr, 1, data);
         assert err = '0'
            report "tb_dbg_host: a write of " & to_hstring(addr) & " got e" & to_hstring(err_code)
            severity failure;
      end procedure wr;

      procedure rd(addr : std_logic_vector(31 downto 0);
                   n    : natural) is
      begin
         request('0', addr, n);
         assert err = '0'
            report "tb_dbg_host: a read of " & to_hstring(addr) & " got e" & to_hstring(err_code)
            severity failure;
         assert rd_cnt = n
            report "tb_dbg_host: a read of " & to_hstring(addr) & " got " & to_string(rd_cnt) & " words"
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

      -- Waits for the packet after the count pkts_v on the UART, and
      -- checks it
      procedure expect_pkt(s : string) is
      begin
         if pkt_cnt = pkts_v then
            wait until pkt_cnt /= pkts_v for C_TIMEOUT;
         end if;
         assert pkt_cnt = pkts_v + 1 and pkt_len = s'length and pkt_last(1 to s'length) = s
            report "tb_dbg_host: the UART got '" & pkt_last(1 to pkt_len) & "', not '" & s & "'"
            severity failure;
         pkts_v := pkt_cnt;
      end procedure expect_pkt;

      -- Waits until the console has n more bytes
      procedure expect_con(n : natural) is
      begin
         cnt_v := con_cnt;
         wait until con_cnt >= cnt_v + n for C_TIMEOUT;
         assert con_cnt >= cnt_v + n
            report "tb_dbg_host: " & to_string(con_cnt - cnt_v) & " console bytes, not " & to_string(n)
            severity failure;
      end procedure expect_con;

      -- Starts a packet on the UART, which p_uart_tx sends meanwhile
      procedure send(s : string) is
      begin
         send_str                <= (others => ' ');
         send_str(1 to s'length) <= s;
         send_len                <= s'length;
         send_req                <= not send_req;
         wait until rising_edge(clk);
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
      pkts_v := 0;
      wait for 10 * C_PERIOD;
      wait until rising_edge(clk);
      rst <= '0';

      -- 1. b05 on the UART, and the version
      expect_pkt(pkt('b', "05"));
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
      assert err = '1' and err_code = X"02" and rd_cnt = 0
         report "tb_dbg_host: a read of the memory while the core runs"
         severity failure;
      expect_con(10);

      -- 4. Pause, read the registers, and step
      wr(C_CTRL, X"00000018");
      expect_pkt(pkt('p', ""));
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
      expect_pkt(pkt('p', ""));
      if r15_v = 10 then
         check(C_REGS + 15, X"00000002");
      else
         check(C_REGS + 15, r15_v + 2);
      end if;

      -- 5. The host keeps its line beside the adapter
      send(C_ESC & pkt('R', "FFFFFFF20001"));
      while send_ack /= send_req loop
         check(C_CTRL, X"00000018");
      end loop;
      expect_pkt(pkt('r', "FFFFFFF2000100000005"));
      send(C_ESC & pkt('W', "FFFFFFF0000100000008"));
      request('0', X"00000000", C_LONG);
      assert err = '1' and err_code = X"02" and rd_cnt > 0 and rd_cnt < C_LONG
         report "tb_dbg_host: the long read ended with err " & std_logic'image(err) & " after " &
                to_string(rd_cnt) & " words"
         severity failure;
      for i in 0 to len_v - 1 loop
         assert rd_words(i) = words_v(i)
            report "tb_dbg_host: word " & to_string(i) & " of the long read is " & to_hstring(rd_words(i))
            severity failure;
      end loop;
      expect_pkt(pkt('k', "FFFFFFF00001"));
      expect_con(300);

      -- 6. Hold, and a read of no words
      wr(C_CTRL, X"00000009");
      request('0', C_VER, 0);
      assert err = '0' and rd_cnt = 0
         report "tb_dbg_host: a read of no words got err " & std_logic'image(err) & " and " &
                to_string(rd_cnt) & " words"
         severity failure;
      assert pkt_cnt = pkts_v
         report "tb_dbg_host: " & to_string(pkt_cnt - pkts_v) & " packets more than expected"
         severity failure;

      report "tb_dbg_host: done";
      stop(0);
   end process p_main;

end architecture simulation;
