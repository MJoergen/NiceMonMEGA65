-- Tests the Ethernet station (src/eth/eth.vhd) at its pins: the MAC address
-- filter and the ARP responder, through the receiver, the FIFOs, and the
-- transmitter.
--
-- THEORY OF OPERATION
-- The station has the MAC address 02:4E:49:43:45:00 and the IP address
-- 192.168.1.66; its clocks are 100 MHz and 50 MHz, as on the MEGA65.
-- p_phy sends the frames of C_TESTS on RXD and CRS_DV, as the PHY does,
-- each with its own frame check sequence and padded to 60 bytes: ARP
-- requests to everyone and to the station, for its IP address and for
-- another, to another station, to a mix of the station's address and
-- 0xFF, an ARP reply, an IPv4 frame, and one with a wrong check sequence.
-- Each test says whether the station must answer. Before the last, it sets
-- the IP address to 0, which answers nothing, not even a request for 0. p_wire takes
-- TXD while TX_EN is '1', checks the preamble and the frame check
-- sequence, and keeps each frame's bytes. p_check compares the replies with
-- what each answered request must get, byte for byte, with the padding,
-- and checks the counts of frames received, bad, and sent.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use std.env.all;

entity tb_eth is
end entity tb_eth;

architecture simulation of tb_eth is

   type t_bytes is array (natural range <>) of std_logic_vector(7 downto 0);

   constant C_MAC : std_logic_vector(47 downto 0) := X"024E49434500";
   constant C_IP  : std_logic_vector(31 downto 0) := X"C0A80142";
   -- The other station, which asks
   constant C_OTHER : t_bytes(0 to 5)               := (X"A0", X"B1", X"C2", X"D3", X"E4", X"F5");

   type t_test is record
      dst    : t_bytes(0 to 5);
      etype  : t_bytes(0 to 1);
      oper   : std_logic_vector(7 downto 0);
      tpa    : t_bytes(0 to 3);
      fcs_ok : boolean;
      answer : boolean;
   end record t_test;

   type t_tests is array (natural range <>) of t_test;

   constant C_BC   : t_bytes(0 to 5) := (others => X"FF");
   constant C_US   : t_bytes(0 to 5) := (X"02", X"4E", X"49", X"43", X"45", X"00");
   constant C_MIX  : t_bytes(0 to 5) := (X"FF", X"4E", X"49", X"43", X"45", X"00");
   constant C_ARP  : t_bytes(0 to 1) := (X"08", X"06");
   constant C_IPV4 : t_bytes(0 to 1) := (X"08", X"00");
   constant C_TPA  : t_bytes(0 to 3) := (X"C0", X"A8", X"01", X"42");
   constant C_NOT  : t_bytes(0 to 3) := (X"C0", X"A8", X"01", X"43");
   constant C_ZERO : t_bytes(0 to 3) := (others => X"00");

   constant C_TESTS : t_tests := (
      (C_BC,    C_ARP,  X"01", C_TPA, true,  true),  -- a request to everyone
      (C_BC,    C_ARP,  X"01", C_NOT, true,  false), -- for another address
      (C_US,    C_ARP,  X"01", C_TPA, true,  true),  -- a request to the station
      (C_OTHER, C_ARP,  X"01", C_TPA, true,  false), -- to another station
      (C_MIX,   C_ARP,  X"01", C_TPA, true,  false), -- to neither
      (C_BC,    C_ARP,  X"02", C_TPA, true,  false), -- a reply
      (C_BC,    C_IPV4, X"01", C_TPA, true,  false), -- not ARP
      (C_BC,    C_ARP,  X"01", C_TPA, false, false), -- a wrong check sequence
      (C_BC,    C_ARP,  X"01", C_TPA, true,  true),  -- and one more
      (C_BC,    C_ARP,  X"01", C_ZERO, true, false)  -- for 0, with the address 0
   );

   -- The sender's IP address in test k, so that each reply differs
   function spa_of (k : natural) return t_bytes is
   begin
      return (X"C0", X"A8", X"01", to_stdlogicvector(10 + k, 8));
   end function spa_of;

   -- The 60 bytes of the frame of test k, before its check sequence
   function frame_of (k : natural) return t_bytes is
      variable f_v : t_bytes(0 to 59) := (others => X"00");
      constant C_T : t_test           := C_TESTS(k);
   begin
      f_v(0 to 5)   := C_T.dst;
      f_v(6 to 11)  := C_OTHER;
      f_v(12 to 13) := C_T.etype;
      f_v(14 to 21) := (X"00", X"01", X"08", X"00", X"06", X"04", X"00", C_T.oper);
      f_v(22 to 27) := C_OTHER;
      f_v(28 to 31) := spa_of(k);
      f_v(32 to 37) := (others => X"00");
      f_v(38 to 41) := C_T.tpa;
      -- Something in the padding, which the station must not mind
      f_v(59) := X"5A";
      return f_v;
   end function frame_of;

   -- The reply that the request of test k must get, padded
   function reply_of (k : natural) return t_bytes is
      variable f_v : t_bytes(0 to 59) := (others => X"00");
   begin
      f_v(0 to 5)   := C_OTHER;
      f_v(6 to 11)  := C_US;
      f_v(12 to 21) := (X"08", X"06", X"00", X"01", X"08", X"00", X"06", X"04", X"00", X"02");
      f_v(22 to 27) := C_US;
      f_v(28 to 31) := C_TPA;
      f_v(32 to 37) := C_OTHER;
      f_v(38 to 41) := spa_of(k);
      return f_v;
   end function reply_of;

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

   signal clk     : std_logic;
   signal eth_clk : std_logic;
   signal rst     : std_logic                    := '1';
   signal ip      : std_logic_vector(31 downto 0) := C_IP;
   signal rx      : std_logic_vector(31 downto 0);
   signal rx_bad  : std_logic_vector(31 downto 0);
   signal tx      : std_logic_vector(31 downto 0);
   signal rxd     : std_logic_vector(1 downto 0) := "00";
   signal crs_dv  : std_logic                    := '0';
   signal txd     : std_logic_vector(1 downto 0);
   signal tx_en   : std_logic;

   -- The frames sent by the station, kept by p_wire
   type   t_wire is array (0 to 15) of t_bytes(0 to 63);
   signal wire  : t_wire;
   signal wired : natural := 0;
   signal sent  : boolean := false;

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
      port map (
         clk_i     => clk,
         rst_i     => rst,
         mac_i     => C_MAC,
         ip_i      => ip,
         rx_o      => rx,
         rx_bad_o  => rx_bad,
         tx_o      => tx,
         eth_clk_i => eth_clk,
         eth_rst_i => rst,
         rxd_i     => rxd,
         crs_dv_i  => crs_dv,
         txd_o     => txd,
         tx_en_o   => tx_en
      ); -- i_eth


   p_phy : process
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

      procedure send_frame (k : natural) is
         constant C_F   : t_bytes(0 to 59) := frame_of(k);
         variable crc_v : std_logic_vector(31 downto 0);
      begin
         for c in 1 to 31 loop
            send("01", '1');
         end loop;
         send("11", '1');
         crc_v := X"FFFFFFFF";
         for i in C_F'range loop
            send_byte(C_F(i));
            crc_v := crc_byte(crc_v, C_F(i));
         end loop;
         if not C_TESTS(k).fcs_ok then
            crc_v(5) := not crc_v(5);
         end if;
         for i in 0 to 3 loop
            send_byte(not crc_v(8 * i + 7 downto 8 * i));
         end loop;
         -- An idle gap of more than 12 bytes
         for c in 1 to 60 loop
            send("00", '0');
         end loop;
      end procedure send_frame;

   begin
      for c in 1 to 10 loop
         wait until rising_edge(eth_clk);
      end loop;
      rst <= '0';
      for c in 1 to 10 loop
         wait until rising_edge(eth_clk);
      end loop;

      for k in C_TESTS'range loop
         if k = C_TESTS'high then
            for c in 1 to 2000 loop
               wait until rising_edge(eth_clk);
            end loop;
            ip <= X"00000000";
         end if;
         send_frame(k);
      end loop;

      for c in 1 to 2000 loop
         wait until rising_edge(eth_clk);
      end loop;
      sent <= true;
      wait;
   end process p_phy;


   p_wire : process
      variable crc_v  : std_logic_vector(31 downto 0);
      variable byte_v : std_logic_vector(7 downto 0);
      variable n_v    : natural;
   begin
      wait until rising_edge(eth_clk) and tx_en = '1';
      n_v   := 0;
      crc_v := X"FFFFFFFF";
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
            if n_v - 8 < 64 then
               wire(wired)(n_v - 8) <= byte_v;
            end if;
         end if;
         n_v := n_v + 1;
         exit when tx_en = '0';
      end loop;
      assert n_v = 8 + 64
         report "tb_eth: a frame of " & integer'image(n_v - 8) & " bytes was sent"
         severity failure;
      assert crc_v = X"DEBB20E3"
         report "tb_eth: a frame was sent with a wrong check sequence"
         severity failure;
      wired <= wired + 1;
   end process p_wire;


   p_check : process
      variable r_v : natural := 0;
      variable f_v : t_bytes(0 to 59);
      variable n_v : natural := 0;
   begin
      wait until sent;

      for k in C_TESTS'range loop
         if C_TESTS(k).answer then
            assert r_v < wired
               report "tb_eth: the request of test " & integer'image(k) & " got no reply"
               severity failure;
            f_v := reply_of(k);
            for i in f_v'range loop
               assert wire(r_v)(i) = f_v(i)
                  report "tb_eth: byte " & integer'image(i) & " of the reply to test " &
                         integer'image(k) &
                         " is " & to_hstring(wire(r_v)(i)) & ", not " & to_hstring(f_v(i))
                  severity failure;
            end loop;
            r_v := r_v + 1;
         end if;
      end loop;
      assert wired = r_v
         report "tb_eth: " & integer'image(wired) & " frames were sent, not " & integer'image(r_v)
         severity failure;

      -- Every frame but the one with the wrong check sequence came through.
      for k in C_TESTS'range loop
         if C_TESTS(k).fcs_ok then
            n_v := n_v + 1;
         end if;
      end loop;
      assert rx = n_v and rx_bad = 1 and tx = r_v
         report "tb_eth: the counts are " & integer'image(to_integer(rx)) & " received, " &
                integer'image(to_integer(rx_bad)) & " bad, and " &
                integer'image(to_integer(tx)) & " sent"
         severity failure;

      report "tb_eth: PASS, " & integer'image(r_v) & " replies";
      finish;
   end process p_check;

end architecture simulation;
