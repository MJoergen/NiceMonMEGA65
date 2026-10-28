-- Tests the Ethernet station (src/eth/eth.vhd) at its pins: the MAC address
-- filter, the ARP responder, and the ICMP echo responder, through the
-- receiver, the FIFOs, and the transmitter.
--
-- THEORY OF OPERATION
-- The station has the MAC address 02:4E:49:43:45:00 and the IP address
-- 192.168.1.66; its clocks are 100 MHz and 50 MHz, as on the MEGA65.
-- p_phy sends frames on RXD and CRS_DV, as the PHY does, each with its own
-- frame check sequence and padded to 60 bytes, and for each that must be
-- answered, it adds the answer, which this testbench makes itself, to
-- expected. The ARP frames are requests to everyone and to the station,
-- for its IP address and for another, to another station, to a mix of the
-- station's address and 0xFF, an ARP reply, and an IPv4 frame. The pings
-- are echo requests of 0, 56, and 1472 bytes of data, and four whose
-- checksums are 0x0000, 0x07FF, 0xF7FF, and 0xF800, where the change of
-- the type carries or does not. Those that must not be answered go to
-- everyone, to another IP address, or have a wrong header checksum, more
-- fragments, a fragment offset, IP options, another ICMP type, another
-- protocol, or a total length longer than the frame. A request of each
-- kind has a wrong frame check sequence. Last, it sets the IP address to
-- 0, which answers nothing, not even a request for 0. p_wire takes TXD
-- while TX_EN is '1', checks the preamble and the frame check sequence,
-- and keeps each frame. p_check compares the frames sent with expected,
-- byte for byte, with the padding, and checks the counts of frames
-- received, bad, and sent.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use std.env.all;

entity tb_eth is
end entity tb_eth;

architecture simulation of tb_eth is

   constant C_MAX_LEN : natural := 1514;

   type t_bytes is array (natural range <>) of std_logic_vector(7 downto 0);

   type t_frame is record
      len : natural;
      b   : t_bytes(0 to C_MAX_LEN - 1);
   end record t_frame;

   type t_frames is array (natural range <>) of t_frame;

   constant C_MAC : std_logic_vector(47 downto 0) := X"024E49434500";
   constant C_IP  : std_logic_vector(31 downto 0) := X"C0A80142";
   constant C_US  : t_bytes(0 to 5)               := (X"02", X"4E", X"49", X"43", X"45", X"00");
   -- The other station, which asks
   constant C_OTHER : t_bytes(0 to 5)               := (X"A0", X"B1", X"C2", X"D3", X"E4", X"F5");
   constant C_BC    : t_bytes(0 to 5)               := (others => X"FF");
   constant C_MIX   : t_bytes(0 to 5)               := (X"FF", X"4E", X"49", X"43", X"45", X"00");
   constant C_TPA   : t_bytes(0 to 3)               := (X"C0", X"A8", X"01", X"42");
   constant C_NOT   : t_bytes(0 to 3)               := (X"C0", X"A8", X"01", X"43");
   constant C_ZERO  : t_bytes(0 to 3)               := (others => X"00");

   -- The other station's IP address in test k, so that each reply differs
   function spa_of (k : natural) return t_bytes is
   begin
      return (X"C0", X"A8", X"01", to_stdlogicvector(10 + k, 8));
   end function spa_of;

   -- The ones' complement sum of two words
   function ones_add (
      a : std_logic_vector(15 downto 0);
      b : std_logic_vector(15 downto 0)
   ) return std_logic_vector is
      variable s_v : std_logic_vector(16 downto 0);
   begin
      s_v := ('0' & a) + ('0' & b);
      return s_v(15 downto 0) + s_v(16);
   end function ones_add;

   -- The ones' complement sum of the 16-bit words of bytes first to last
   -- of a frame, a missing low byte at the end as 0
   function ones_sum (f : t_frame; first : natural; last : natural) return std_logic_vector is
      variable s_v : std_logic_vector(15 downto 0) := (others => '0');
      variable i_v : natural;
   begin
      i_v := first;

      while i_v <= last loop
         if i_v + 1 <= last then
            s_v := ones_add(s_v, f.b(i_v) & f.b(i_v + 1));
         else
            s_v := ones_add(s_v, f.b(i_v) & X"00");
         end if;
         i_v := i_v + 2;
      end loop;

      return s_v;
   end function ones_sum;

   -- The IPv4 packet's total length
   function ip_len (f : t_frame) return natural is
   begin
      return to_integer(f.b(16) & f.b(17));
   end function ip_len;

   -- The frame with its IP header's checksum, or its ICMP checksum, right
   function with_ip_ck (f : t_frame) return t_frame is
      variable f_v : t_frame;
      variable c_v : std_logic_vector(15 downto 0);
   begin
      f_v       := f;
      f_v.b(24) := X"00";
      f_v.b(25) := X"00";
      c_v       := not ones_sum(f_v, 14, 33);
      f_v.b(24) := c_v(15 downto 8);
      f_v.b(25) := c_v(7 downto 0);
      return f_v;
   end function with_ip_ck;

   function with_icmp_ck (f : t_frame) return t_frame is
      variable f_v : t_frame;
      variable c_v : std_logic_vector(15 downto 0);
   begin
      f_v       := f;
      f_v.b(36) := X"00";
      f_v.b(37) := X"00";
      c_v       := not ones_sum(f_v, 34, 14 + ip_len(f) - 1);
      f_v.b(36) := c_v(15 downto 8);
      f_v.b(37) := c_v(7 downto 0);
      return f_v;
   end function with_icmp_ck;

   -- An ARP request, or a reply with oper 2, from the other station
   function arp_request (
      dst  : t_bytes(0 to 5);
      oper : std_logic_vector(7 downto 0);
      tpa  : t_bytes(0 to 3);
      k    : natural
   ) return t_frame is
      variable f_v : t_frame;
   begin
      f_v.len         := 60;
      f_v.b           := (others => X"00");
      f_v.b(0 to 5)   := dst;
      f_v.b(6 to 11)  := C_OTHER;
      f_v.b(12 to 21) := (X"08", X"06", X"00", X"01", X"08", X"00", X"06", X"04", X"00", oper);
      f_v.b(22 to 27) := C_OTHER;
      f_v.b(28 to 31) := spa_of(k);
      f_v.b(38 to 41) := tpa;
      -- Something in the padding, which the station must not mind
      f_v.b(59) := X"5A";
      return f_v;
   end function arp_request;

   -- The reply that arp_request(.., X"01", C_TPA, k) must get, padded
   function arp_reply (k : natural) return t_frame is
      variable f_v : t_frame;
   begin
      f_v.len         := 60;
      f_v.b           := (others => X"00");
      f_v.b(0 to 5)   := C_OTHER;
      f_v.b(6 to 11)  := C_US;
      f_v.b(12 to 21) := (X"08", X"06", X"00", X"01", X"08", X"00", X"06", X"04", X"00", X"02");
      f_v.b(22 to 27) := C_US;
      f_v.b(28 to 31) := C_TPA;
      f_v.b(32 to 37) := C_OTHER;
      f_v.b(38 to 41) := spa_of(k);
      return f_v;
   end function arp_reply;

   -- An ICMP echo request from the other station with n bytes of data
   function ping (
      dst : t_bytes(0 to 5);
      dip : t_bytes(0 to 3);
      n   : natural;
      seq : std_logic_vector(15 downto 0);
      k   : natural
   ) return t_frame is
      variable f_v : t_frame;
      variable l_v : std_logic_vector(15 downto 0);
   begin
      l_v     := to_stdlogicvector(28 + n, 16);
      f_v.len := 14 + 28 + n;
      if f_v.len < 60 then
         f_v.len := 60;
      end if;
      f_v.b           := (others => X"00");
      f_v.b(0 to 5)   := dst;
      f_v.b(6 to 11)  := C_OTHER;
      f_v.b(12 to 13) := (X"08", X"00");
      -- The version and header length, the TOS, the total length, the ID,
      -- don't fragment, TTL 64, ICMP, the checksum, and the addresses
      f_v.b(14 to 25) :=
      (
         X"45",
         X"00",
         l_v(15 downto 8),
         l_v(7 downto 0),
         X"00",
         to_stdlogicvector(k,
                             8),
         X"40",
         X"00",
         X"40",
         X"01",
         X"00",
         X"00"
      );
      f_v.b(26 to 29) := spa_of(k);
      f_v.b(30 to 33) := dip;
      -- Echo request, the checksum, the identifier, and the sequence number
      f_v.b(34 to 41) :=
      (
         X"08",
         X"00",
         X"00",
         X"00",
         X"12",
         X"34",
         seq(15 downto 8),
         seq(7 downto 0)
      );

      for i in 0 to n - 1 loop
         f_v.b(42 + i) := to_stdlogicvector((k * 7 + i * 3) mod 256, 8);
      end loop;

      if 42 + n < 60 then
         f_v.b(59) := X"5A";
      end if;
      return with_icmp_ck(with_ip_ck(f_v));
   end function ping;

   -- The echo reply that the request f must get, made from scratch
   function pong (f : t_frame) return t_frame is
      variable f_v : t_frame;
      variable l_v : natural;
   begin
      l_v                 := 14 + ip_len(f);
      f_v.b               := (others => X"00");
      f_v.b(0 to l_v - 1) := f.b(0 to l_v - 1);
      f_v.len             := l_v;
      if f_v.len < 60 then
         f_v.len := 60;
      end if;
      f_v.b(0 to 5)   := f.b(6 to 11);
      f_v.b(6 to 11)  := C_US;
      f_v.b(26 to 29) := f.b(30 to 33);
      f_v.b(30 to 33) := f.b(26 to 29);
      f_v.b(34)       := X"00";
      return with_icmp_ck(with_ip_ck(f_v));
   end function pong;

   -- The CRC-32 of IEEE 802.3, a bit at a time, LSB first
   function crc_byte (
      c : std_logic_vector(31 downto 0);
      d : std_logic_vector(7 downto 0)
   ) return std_logic_vector is
      variable c_v : std_logic_vector(31 downto 0);
   begin
      c_v := c;

      for i in 0 to 7 loop
         if (c_v(0) xor d(i)) = '1' then
            c_v := ('0' & c_v(31 downto 1)) xor X"EDB88320";
         else
            c_v := '0' & c_v(31 downto 1);
         end if;
      end loop;

      return c_v;
   end function crc_byte;

   type t_lens is array (natural range <>) of natural;
   type t_cks is array (natural range <>) of std_logic_vector(15 downto 0);

   constant C_PING_LENS : t_lens := (0, 56, 1472);
   constant C_CKS       : t_cks  := (X"0000", X"07FF", X"F7FF", X"F800");

   signal clk     : std_logic;
   signal eth_clk : std_logic;
   signal rst     : std_logic                     := '1';
   signal ip      : std_logic_vector(31 downto 0) := C_IP;
   signal rx      : std_logic_vector(31 downto 0);
   signal rx_bad  : std_logic_vector(31 downto 0);
   signal tx      : std_logic_vector(31 downto 0);
   signal rxd     : std_logic_vector(1 downto 0)  := "00";
   signal crs_dv  : std_logic                     := '0';
   signal txd     : std_logic_vector(1 downto 0);
   signal tx_en   : std_logic;

   -- The answers p_phy expects, the frames sent by the station, and the
   -- counts of frames p_phy sent, good and bad
   signal expected   : t_frames(0 to 23);
   signal n_expected : natural := 0;
   signal wire       : t_frames(0 to 23);
   signal wired      : natural := 0;
   signal n_good     : natural := 0;
   signal n_bad      : natural := 0;
   signal sent       : boolean := false;

begin

   p_clk : process
   begin
      clk <= '1', '0' after 5 ns;
      wait for 10 ns;
   end process p_clk;

   p_eth_clk : process
   begin
      eth_clk <= '1', '0' after 10 ns;
      wait for 20 ns;
   end process p_eth_clk;


   i_eth : entity work.eth
      generic map (
         G_CLOCK_HZ => 100_000_000
      )
      port map (
         clk_i       => clk,
         rst_i       => rst,
         mac_i       => C_MAC,
         ip_i        => ip,
         rx_o        => rx,
         rx_bad_o    => rx_bad,
         tx_o        => tx,
         on_o        => open,
         lrx_data_o  => open,
         lrx_valid_o => open,
         lrx_ready_i => '1',
         lrx_break_o => open,
         ltx_data_i  => X"00",
         ltx_valid_i => '0',
         ltx_ready_o => open,
         eth_clk_i   => eth_clk,
         eth_rst_i   => rst,
         rxd_i       => rxd,
         crs_dv_i    => crs_dv,
         txd_o       => txd,
         tx_en_o     => tx_en
      ); -- i_eth


   p_phy : process
      variable f_v   : t_frame;
      variable ck_v  : std_logic_vector(15 downto 0);
      variable seq_v : std_logic_vector(15 downto 0);

      procedure send (d : std_logic_vector(1 downto 0); dv : std_logic) is
      begin
         rxd    <= d;
         crs_dv <= dv;
         wait until rising_edge(eth_clk);
      end procedure send;

      procedure send_byte (b : std_logic_vector(7 downto 0)) is
      begin
         for d in 0 to 3 loop
            send(b(2 * d + 1 downto 2 * d), '1');
         end loop;
      end procedure send_byte;

      -- Sends the frame f, with a wrong check sequence unless fcs_ok
      procedure send_frame (f : t_frame; fcs_ok : boolean := true) is
         variable crc_v : std_logic_vector(31 downto 0);
      begin
         for c in 1 to 31 loop
            send("01", '1');
         end loop;
         send("11", '1');
         crc_v := X"FFFFFFFF";
         for i in 0 to f.len - 1 loop
            send_byte(f.b(i));
            crc_v := crc_byte(crc_v, f.b(i));
         end loop;
         if not fcs_ok then
            crc_v(5) := not crc_v(5);
         end if;
         for i in 0 to 3 loop
            send_byte(not crc_v(8 * i + 7 downto 8 * i));
         end loop;
         -- An idle gap of more than 12 bytes
         for c in 1 to 60 loop
            send("00", '0');
         end loop;
         if fcs_ok then
            n_good <= n_good + 1;
         else
            n_bad <= n_bad + 1;
         end if;
      end procedure send_frame;

      -- Sends the frame f, which must get the answer a
      procedure send_answered (f : t_frame; a : t_frame) is
      begin
         expected(n_expected) <= a;
         n_expected           <= n_expected + 1;
         send_frame(f);
      end procedure send_answered;

   begin
      for c in 1 to 10 loop
         wait until rising_edge(eth_clk);
      end loop;
      rst <= '0';
      for c in 1 to 10 loop
         wait until rising_edge(eth_clk);
      end loop;

      -- ARP
      send_answered(arp_request(C_BC, X"01", C_TPA, 0), arp_reply(0));
      send_frame(arp_request(C_BC, X"01", C_NOT, 1));
      send_answered(arp_request(C_US, X"01", C_TPA, 2), arp_reply(2));
      send_frame(arp_request(C_OTHER, X"01", C_TPA, 3));
      send_frame(arp_request(C_MIX, X"01", C_TPA, 4));
      send_frame(arp_request(C_BC, X"02", C_TPA, 5));
      f_v       := arp_request(C_BC, X"01", C_TPA, 6);
      f_v.b(13) := X"00";
      send_frame(f_v);
      send_frame(arp_request(C_BC, X"01", C_TPA, 7), false);

      -- Pings that are answered
      for n in C_PING_LENS'range loop
         f_v := ping(C_US, C_TPA, C_PING_LENS(n), X"0001", 10 + n);
         send_answered(f_v, pong(f_v));
      end loop;

      -- The checksum is ~S for the ones' complement sum S of the other
      -- words, so with the sequence number 0 it is ck0 = ~S0. With the
      -- sequence number seq, the sum is S0 + seq, which must be ~ck, so
      -- seq = ~ck - S0 = ~ck + ck0.
      for c in C_CKS'range loop
         f_v   := ping(C_US, C_TPA, 16, X"0000", 20 + c);
         ck_v  := f_v.b(36) & f_v.b(37);
         seq_v := ones_add(not C_CKS(c), ck_v);
         f_v   := ping(C_US, C_TPA, 16, seq_v, 20 + c);
         assert (f_v.b(36) & f_v.b(37)) = C_CKS(c)
            report "tb_eth: the testbench made a checksum of " & to_hstring(f_v.b(36) & f_v.b(37)) &
                   ", not " & to_hstring(C_CKS(c))
            severity failure;
         send_answered(f_v, pong(f_v));
      end loop;

      -- Pings that are not answered: to everyone, to another address, and
      -- with a wrong header checksum
      send_frame(ping(C_BC, C_TPA, 56, X"0002", 30));
      send_frame(ping(C_US, C_NOT, 56, X"0003", 31));
      f_v       := ping(C_US, C_TPA, 56, X"0004", 32);
      f_v.b(25) := not f_v.b(25);
      send_frame(f_v);
      -- More fragments, and a fragment offset
      f_v       := ping(C_US, C_TPA, 56, X"0005", 33);
      f_v.b(20) := X"20";
      send_frame(with_ip_ck(f_v));
      f_v       := ping(C_US, C_TPA, 56, X"0006", 34);
      f_v.b(21) := X"01";
      send_frame(with_ip_ck(f_v));
      -- IP options, a timestamp request, and TCP
      f_v       := ping(C_US, C_TPA, 56, X"0007", 35);
      f_v.b(14) := X"46";
      send_frame(with_ip_ck(f_v));
      f_v       := ping(C_US, C_TPA, 56, X"0008", 36);
      f_v.b(34) := X"0D";
      send_frame(with_icmp_ck(f_v));
      f_v       := ping(C_US, C_TPA, 56, X"0009", 37);
      f_v.b(23) := X"06";
      send_frame(with_ip_ck(f_v));
      -- A total length longer than the frame, and a wrong check sequence
      f_v       := ping(C_US, C_TPA, 56, X"000A", 38);
      f_v.b(17) := f_v.b(17) + 1;
      send_frame(with_ip_ck(f_v));
      send_frame(ping(C_US, C_TPA, 56, X"000B", 39), false);

      -- With the IP address 0, nothing is answered.
      for c in 1 to 4000 loop
         wait until rising_edge(eth_clk);
      end loop;
      ip <= X"00000000";
      send_frame(arp_request(C_BC, X"01", C_ZERO, 40));
      send_frame(ping(C_US, C_ZERO, 56, X"000C", 41));

      for c in 1 to 4000 loop
         wait until rising_edge(eth_clk);
      end loop;
      sent <= true;
      wait;
   end process p_phy;


   p_wire : process
      variable crc_v  : std_logic_vector(31 downto 0);
      variable byte_v : std_logic_vector(7 downto 0);
      variable n_v    : natural;
      variable f_v    : t_frame;
   begin
      wait until rising_edge(eth_clk) and tx_en = '1';
      n_v   := 0;
      crc_v := X"FFFFFFFF";
      f_v.b := (others => X"00");

      loop
         for d in 0 to 3 loop
            byte_v(2 * d + 1 downto 2 * d) := txd;
            wait until rising_edge(eth_clk);
         end loop;
         if n_v < 7 then
            assert byte_v = X"55"
               report "tb_eth: wrong preamble"
               severity failure;
         elsif n_v = 7 then
            assert byte_v = X"D5"
               report "tb_eth: wrong start frame delimiter"
               severity failure;
         else
            crc_v := crc_byte(crc_v, byte_v);
            if n_v - 8 < C_MAX_LEN then
               f_v.b(n_v - 8) := byte_v;
            end if;
         end if;
         n_v := n_v + 1;
         exit when tx_en = '0';
      end loop;

      assert crc_v = X"DEBB20E3"
         report "tb_eth: a frame was sent with a wrong check sequence"
         severity failure;
      -- Without its check sequence
      f_v.len     := n_v - 8 - 4;
      wire(wired) <= f_v;
      wired       <= wired + 1;
   end process p_wire;


   p_check : process
   begin
      wait until sent;

      assert wired = n_expected
         report "tb_eth: " & integer'image(wired) & " frames were sent, not " &
                integer'image(n_expected)
         severity failure;

      for k in 0 to n_expected - 1 loop
         assert wire(k).len = expected(k).len
            report "tb_eth: frame " & integer'image(k) & " has " & integer'image(wire(k).len) &
                   " bytes, not " & integer'image(expected(k).len)
            severity failure;

         for i in 0 to expected(k).len - 1 loop
            assert wire(k).b(i) = expected(k).b(i)
               report "tb_eth: byte " & integer'image(i) & " of frame " & integer'image(k) &
                      " is " & to_hstring(wire(k).b(i)) & ", not " &
                      to_hstring(expected(k).b(i))
               severity failure;
         end loop;

      end loop;

      assert rx = n_good and rx_bad = n_bad and tx = n_expected
         report "tb_eth: the counts are " & integer'image(to_integer(rx)) & " received, " &
                integer'image(to_integer(rx_bad)) & " bad, and " &
                integer'image(to_integer(tx)) & " sent"
         severity failure;

      report "tb_eth: PASS, " & integer'image(n_expected) & " replies";
      finish;
   end process p_check;

end architecture simulation;
