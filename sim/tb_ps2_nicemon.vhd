-- Tests the PS/2 keyboard into the NiceMon system: kbd_ps2.vhd,
-- kbd_ps2_ascii.vhd, and nicemon.vhd, wired as synth/nexys4ddr/top.vhd
-- wires them. tb_ps2 tests the keyboard alone, and tb_nicemon the system
-- with a keyboard input that waits; this one tests the handshake between
-- them, and that a PS/2 keyboard, which cannot wait, loses keys.
--
-- THEORY OF OPERATION
-- send() is the keyboard of tb_ps2. p_main loads programs over the debug
-- link as tb_nicemon does, with fewer helpers, and p_uart_rx splits the
-- UART output into console bytes and packets. The steps:
--
-- 1. The link's `b05` after reset. There is no ROM, and the core is held.
-- 2. Keys typed while the core is held are dropped. Then G_FIFO_FILE runs,
--    and echoes the keys typed, in order, with SHIFT and Enter, until '.'.
-- 3. G_SWITCH_FILE runs, which reads no input until switch 0 is on. The
--    UART fills the core's input FIFO, 16 bytes. A cursor key typed then
--    waits in kbd_ps2_ascii, its three bytes, and the keys typed while
--    they wait are lost. Switch 0 on: the program echoes the 16 bytes and
--    the cursor key, and the keys typed after that.
--
-- The sizes are those of tb_nicemon, without the ROM. A key takes a few
-- milliseconds, so the clock is only 2 MHz, to keep the test short. The
-- receiver's filter and timeout are given in time, through G_CLOCK_HZ, so
-- they keep their real lengths at 2 MHz. The UART runs at a tenth of the
-- clock.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use std.textio.all;
   use std.env.all;

entity tb_ps2_nicemon is
   generic (
      G_FIFO_FILE   : string;
      G_SWITCH_FILE : string
   );
end entity tb_ps2_nicemon;

architecture simulation of tb_ps2_nicemon is

   constant C_CLOCK_HZ : natural := 2_000_000;
   constant C_PERIOD   : time    := 1 sec / C_CLOCK_HZ;
   constant C_BAUDRATE : natural := 200_000;
   constant C_BIT_TIME : time    := (C_CLOCK_HZ / C_BAUDRATE) * C_PERIOD;
   -- Half a period of the keyboard's clock
   constant C_HALF : time := 40 us;
   -- Longer than the slowest answer
   constant C_TIMEOUT : time := 10 ms;

   -- C_KEY_ESC is the ESC of the cursor keys, and C_ESC the link's
   constant C_LF      : character := character'val(10);
   constant C_CR      : character := character'val(13);
   constant C_KEY_ESC : character := character'val(27);
   constant C_ESC     : character := character'val(255);

   signal clk     : std_logic;
   signal rst     : std_logic;
   signal uart_rx : std_logic := '1';
   signal uart_tx : std_logic;

   signal ps2_clk  : std_logic := '1';
   signal ps2_data : std_logic := '1';

   signal ps2_valid : std_logic;
   signal ps2_code  : std_logic_vector(7 downto 0);
   signal kbd_valid : std_logic;
   signal kbd_ready : std_logic;
   signal kbd_data  : std_logic_vector(7 downto 0);

   signal brd_sw : std_logic_vector(15 downto 0) := X"0000";

   -- The console bytes, and the packets, each from its tag to its checksum
   -- and an LF
   signal con_str : string(1 to 256);
   signal con_len : natural := 0;
   signal pkt_str : string(1 to 4096);
   signal pkt_len : natural := 0;

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


   i_kbd_ps2 : entity work.kbd_ps2
      generic map (
         G_CLOCK_HZ => C_CLOCK_HZ
      )
      port map (
         clk_i        => clk,
         rst_i        => rst,
         ps2_clk_i    => ps2_clk,
         ps2_data_i   => ps2_data,
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


   i_nicemon : entity work.nicemon
      generic map (
         G_CLOCK_HZ      => C_CLOCK_HZ,
         G_UART_BAUDRATE => C_BAUDRATE,
         G_RAM_ADDR_BITS => 12,
         G_SCR_ADDR_BITS => 11,
         G_RX_FIFO_BITS  => 4,
         G_ROM_ADDR_BITS => 11,
         G_BOARD_IO      => true
      )
      port map (
         clk_i          => clk,
         rst_i          => rst,
         uart_rxd_i     => uart_rx,
         uart_txd_o     => uart_tx,
         kbd_valid_i    => kbd_valid,
         kbd_ready_o    => kbd_ready,
         kbd_data_i     => kbd_data,
         running_o      => open,
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
         brd_btn_i      => "00000",
         brd_sw_i       => brd_sw
      ); -- i_nicemon


   -- Decodes the UART output, 8-N-1, sampling in the middle of each bit,
   -- and splits it into console bytes and packets, as tb_nicemon does.
   p_uart_rx : process
      variable byte_v : std_logic_vector(7 downto 0);
      variable c_v    : character;
      -- 0: console bytes, 1: after ESC, 2: in a packet, 3 and 4: the
      -- checksum's digits
      variable st_v  : natural range 0 to 4 := 0;
      variable buf_v : string(1 to 256);
      variable n_v   : natural              := 0;
   begin
      wait until uart_tx = '0';
      wait for C_BIT_TIME / 2;
      for i in 0 to 7 loop
         wait for C_BIT_TIME;
         byte_v(i) := uart_tx;
      end loop;
      wait for C_BIT_TIME;
      assert uart_tx = '1'
         report "tb_ps2_nicemon: bad stop bit"
         severity failure;
      c_v := character'val(to_integer(byte_v));

      case st_v is
         when 0 =>
            if c_v = C_ESC then
               st_v := 1;
            else
               con_str(con_len + 1) <= c_v;
               con_len              <= con_len + 1;
            end if;
         when 1 =>
            if c_v = C_ESC then
               con_str(con_len + 1) <= C_ESC;
               con_len              <= con_len + 1;
               st_v                 := 0;
            else
               buf_v(1) := c_v;
               n_v      := 1;
               st_v     := 2;
            end if;
         when others =>
            n_v        := n_v + 1;
            buf_v(n_v) := c_v;
            if st_v = 2 and c_v = '#' then
               st_v := 3;
            elsif st_v = 3 then
               st_v := 4;
            elsif st_v = 4 then
               pkt_str(pkt_len + 1 to pkt_len + n_v + 1) <= buf_v(1 to n_v) & C_LF;
               pkt_len                                   <= pkt_len + n_v + 1;
               st_v                                      := 0;
            end if;
      end case;
   end process p_uart_rx;


   p_main : process
      variable con_pos_v : natural := 0;
      variable pkt_pos_v : natural := 0;

      -- Sends one byte on the UART.
      procedure send_byte(c : character) is
         variable byte_v : std_logic_vector(7 downto 0);
      begin
         byte_v  := to_slv(character'pos(c), 8);
         uart_rx <= '0';
         wait for C_BIT_TIME;
         for b in 0 to 7 loop
            uart_rx <= byte_v(b);
            wait for C_BIT_TIME;
         end loop;
         uart_rx <= '1';
         wait for C_BIT_TIME;
      end procedure send_byte;

      procedure send(s : string) is
      begin
         for i in s'range loop
            send_byte(s(i));
         end loop;
      end procedure send;

      -- The next console bytes must be s.
      procedure expect_con(s : string) is
      begin
         if con_len < con_pos_v + s'length then
            wait until con_len >= con_pos_v + s'length for C_TIMEOUT;
         end if;
         assert con_len >= con_pos_v + s'length
            report "tb_ps2_nicemon: timeout, waiting for """ & s & """, got """ &
                   con_str(con_pos_v + 1 to con_len) & """"
            severity failure;
         assert con_str(con_pos_v + 1 to con_pos_v + s'length) = s
            report "tb_ps2_nicemon: expected """ & s & """, got """ &
                   con_str(con_pos_v + 1 to con_pos_v + s'length) & """"
            severity failure;
         con_pos_v := con_pos_v + s'length;
      end procedure expect_con;

      -- The next packet must be s.
      procedure expect_pkt(s : string) is
         variable end_v : natural;
      begin
         if pkt_len = pkt_pos_v then
            wait until pkt_len > pkt_pos_v for C_TIMEOUT;
         end if;
         assert pkt_len > pkt_pos_v
            report "tb_ps2_nicemon: timeout, waiting for " & s
            severity failure;
         end_v := pkt_pos_v + 1;
         while pkt_str(end_v) /= C_LF loop
            end_v := end_v + 1;
         end loop;
         assert pkt_str(pkt_pos_v + 1 to end_v - 1) = s
            report "tb_ps2_nicemon: expected the packet " & s & ", got " &
                   pkt_str(pkt_pos_v + 1 to end_v - 1)
            severity failure;
         pkt_pos_v := end_v;
      end procedure expect_pkt;

      -- Writes one word, and checks the answer.
      procedure wr(addr : string; data : string) is
      begin
         send(C_ESC & pkt('W', addr & "0001" & data));
         expect_pkt(pkt('k', addr & "0001"));
      end procedure wr;

      -- Reads one word, which must be data.
      procedure check(addr : string; data : string) is
      begin
         send(C_ESC & pkt('R', addr & "0001"));
         expect_pkt(pkt('r', addr & "0001" & data));
      end procedure check;

      function upper(s : string) return string is
         variable res_v : string(1 to s'length) := s;
      begin
         for i in res_v'range loop
            if res_v(i) >= 'a' and res_v(i) <= 'f' then
               res_v(i) := character'val(character'pos(res_v(i)) - 32);
            end if;
         end loop;
         return res_v;
      end function upper;

      -- Writes each word of the .bin file with a W packet.
      procedure load(name : string) is
         file     f : text;
         variable l : line;
      begin
         file_open(f, name, read_mode);
         while not endfile(f) loop
            readline(f, l);
            if l'length > 0 then
               assert l'length = 17
                  report "tb_ps2_nicemon: " & name & " has a line that is not 'address word': '" & l.all & "'"
                  severity failure;
               wr(upper(l.all(1 to 8)), upper(l.all(10 to 17)));
            end if;
         end loop;
         file_close(f);
      end procedure load;

      -- Send a frame of byte b on the keyboard's lines, then a pause, as
      -- tb_ps2 does.
      procedure ps2_send(b : std_logic_vector(7 downto 0)) is
         variable frame_v : std_logic_vector(10 downto 0);
      begin
         frame_v := '1' & not (xor b) & b & '0';
         for i in 0 to 10 loop
            ps2_data <= frame_v(i);
            wait for C_HALF / 2;
            ps2_clk  <= '0';
            wait for C_HALF;
            ps2_clk  <= '1';
            wait for C_HALF / 2;
         end loop;
         ps2_data <= '1';
         wait for 4 * C_HALF;
      end procedure ps2_send;

      -- A key pressed and released, with E0 before its code if ext
      procedure tap(c : std_logic_vector(7 downto 0); ext : boolean := false) is
      begin
         if ext then
            ps2_send(X"E0");
         end if;
         ps2_send(c);
         if ext then
            ps2_send(X"E0");
         end if;
         ps2_send(X"F0");
         ps2_send(c);
      end procedure tap;

      procedure press(c : std_logic_vector(7 downto 0)) is
      begin
         ps2_send(c);
      end procedure press;

      procedure lift(c : std_logic_vector(7 downto 0)) is
      begin
         ps2_send(X"F0");
         ps2_send(c);
      end procedure lift;

   begin
      rst <= '1';
      wait for 1 us;
      wait until rising_edge(clk);
      rst <= '0';

      report "tb_ps2_nicemon: b05";
      expect_pkt("b05#C7");
      check("FFFFFFF0", "00000009");         -- held, and no ROM

      report "tb_ps2_nicemon: keys typed while the core is held are dropped";
      tap(X"22");                            -- X
      tap(X"35");                            -- Y
      load(G_FIFO_FILE);
      wr("FFFFFFF0", "00000008");
      press(X"12");                          -- SHIFT
      tap(X"33");                            -- H
      lift(X"12");
      tap(X"43");                            -- i
      press(X"59");
      tap(X"16");                            -- !
      lift(X"59");
      tap(X"5A");                            -- Enter
      tap(X"49");                            -- .
      expect_con("Hi!" & C_CR & ".");
      expect_pkt(pkt('h', "01"));

      report "tb_ps2_nicemon: keys typed while the FIFO is full are lost";
      wr("FFFFFFF0", "00000009");
      load(G_SWITCH_FILE);
      wr("FFFFFFF0", "00000008");
      send("0123456789abcdef");
      check("FFFFFFF3", "00000000");         -- the FIFO is full
      tap(X"75", true);                      -- up, which waits
      tap(X"1D");                            -- W, lost
      tap(X"24");                            -- E, lost
      brd_sw <= X"0001";
      expect_con("0123456789abcdef" & C_KEY_ESC & "[A");
      tap(X"1A");                            -- Z, as there is room again
      tap(X"49");                            -- .
      expect_con("z.");
      expect_pkt(pkt('h', "01"));

      wait for 100 us;
      assert pkt_len = pkt_pos_v and con_len = con_pos_v
         report "tb_ps2_nicemon: more output than expected: """ & con_str(con_pos_v + 1 to con_len) &
                """ and the packets """ & pkt_str(pkt_pos_v + 1 to pkt_len) & """"
         severity failure;

      report "tb_ps2_nicemon: PASS";
      stop(0);
   end process p_main;

end architecture simulation;
