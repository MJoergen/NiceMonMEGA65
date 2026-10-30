-- The parser of the TCP server's received frames (eth_tcp.vhd): it reads
-- the frames of eth_rx_fifo.vhd a byte at a time, keeps the fields of
-- those that are TCP segments to port G_PORT of ip_i, checks their
-- checksums, and writes the data of the one that is the next of the
-- connection as it comes.
--
-- THEORY OF OPERATION
-- A frame is read a byte at a time, at idx, its count of bytes so far.
-- Its bytes are checked as they pass, for IPv4 (RFC 791) and TCP (RFC
-- 9293):
--   0-5    the destination MAC address, which must be mac_i
--   12-13  the EtherType, 0x0800 for IPv4
--   14     the version 4 and the header length 5, so no options
--   16-17  the total length, kept in f_len
--   20-21  the flags and the fragment offset: no more fragments, and an
--          offset of 0, so a whole packet
--   23     the protocol, 6 for TCP
--   30-33  the destination IP address, which must be ip_i
--   36-37  the destination port, which must be G_PORT
-- m_ok stays '1' while each of these is right, and the source MAC address
-- (6-11), the source IP address (26-29), and the TCP header's source port
-- (34-35), sequence and acknowledgment numbers (38-45), data offset (46),
-- flags (47), and window (48-49) are kept in f_*. The TCP options, if any,
-- are skipped. The IP header's words are added in ip_sum, and the TCP
-- pseudo header and segment, up to the IP total length, in tcp_sum, both
-- in ones' complement, which are 0xFFFF when the checksums are right. The
-- segment's data runs from the end of its header (p_start) to the IP
-- total length (p_end), plen bytes; a longer frame has padding after it.
-- The data goes to we_o as it comes, a byte a cycle with rx_data_i, if the
-- segment is the next of the connection: it is from exp_ip_i and
-- exp_port_i, its sequence number is exp_seq_i, take_i is '1', and its
-- data is not empty and fits free_i. That is known at byte 47, before the
-- data starts, and wr_ok says so from then on, as does len_o, the length
-- of the data, a register as well. The stream is held (rx_ready_o) for
-- two cycles after the last byte. In the first (last), the verdict goes
-- into registers, for the timing: good_o, whether the frame is a whole
-- segment to this station whose checksums are right, and wr_ok_o,
-- whether its data was written; and the count and the sums start again.
-- In the second (done_o), they, len_o, and the fields stand for the
-- segment. A frame longer than C_MAXF bytes is not good, and no data is
-- written past C_MAXF.
--
-- INTERFACE CONTRACTS -- these are requirements on the environment:
-- a) mac_i and ip_i stay stable while a frame is read, as for
--    eth_arp.vhd.
-- b) take_i, exp_*_i, and free_i stand for the connection as it is when
--    the segment's byte 47 is read; what they are at other times does not
--    matter.
--
-- RESET
-- Synchronous, to clk_i. Reset starts a frame again.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use work.eth_pkg.all;

entity eth_tcp_rx is
   generic (
      G_PORT      : natural := 4510;
      G_ADDR_BITS : natural := 11
   );
   port (
      clk_i      : in  std_logic;
      rst_i      : in  std_logic;
      -- This station's addresses
      mac_i      : in  std_logic_vector(47 downto 0);
      ip_i       : in  std_logic_vector(31 downto 0);
      -- The received frames, from eth_rx_fifo.vhd
      rx_data_i  : in  std_logic_vector(7 downto 0);
      rx_last_i  : in  std_logic;
      rx_valid_i : in  std_logic;
      rx_ready_o : out std_logic;
      -- The connection whose next data is written: that it takes data,
      -- the host's address and port, the sequence number of its next
      -- data, and the room for it
      take_i     : in  std_logic;
      exp_ip_i   : in  std_logic_vector(31 downto 0);
      exp_port_i : in  std_logic_vector(15 downto 0);
      exp_seq_i  : in  std_logic_vector(31 downto 0);
      free_i     : in  natural range 0 to 2 ** G_ADDR_BITS;
      -- The segment's data, a byte at a time on rx_data_i, while it is the
      -- next of the connection
      we_o       : out std_logic;
      -- The segment, in the second cycle after its last byte: whether it
      -- is good, its fields, whether its data was written, and the length
      -- of its data, from byte 48 on, 0 when the header is longer than the
      -- IP total length says, and the segment is not good
      done_o     : out std_logic;
      good_o     : out std_logic                     := '0';
      seg_o      : out t_seg;
      wr_ok_o    : out std_logic                     := '0';
      len_o      : out natural range 0 to 2 ** 16    := 0
   );
end entity eth_tcp_rx;

architecture synthesis of eth_tcp_rx is

   -- The longest frame that is read
   constant C_MAXF : natural := 2047;

   constant C_PORT : std_logic_vector(15 downto 0) := to_stdlogicvector(G_PORT, 16);

   -- The frame being read
   signal idx     : natural range 0 to C_MAXF     := 0;
   signal m_ok    : std_logic                     := '1';
   signal f_smac  : std_logic_vector(47 downto 0) := (others => '0');
   signal f_sip   : std_logic_vector(31 downto 0) := (others => '0');
   signal f_sport : std_logic_vector(15 downto 0) := (others => '0');
   signal f_seq   : std_logic_vector(31 downto 0) := (others => '0');
   signal f_ack   : std_logic_vector(31 downto 0) := (others => '0');
   signal f_doff  : std_logic_vector(3 downto 0)  := (others => '0');
   signal f_flags : std_logic_vector(7 downto 0)  := (others => '0');
   signal f_win   : std_logic_vector(15 downto 0) := (others => '0');
   signal f_len   : std_logic_vector(15 downto 0) := (others => '0');
   signal ip_sum  : std_logic_vector(15 downto 0) := (others => '0');
   signal tcp_sum : std_logic_vector(15 downto 0) := (others => '0');
   signal hi      : std_logic_vector(7 downto 0)  := (others => '0');
   signal wr_ok   : std_logic                     := '0';
   -- The two cycles after the last byte
   signal last : std_logic := '0';
   signal done : std_logic := '0';
   -- Whether the byte on rx_data_i is right, and whether the frame is good
   signal ok   : boolean;
   signal good : std_logic;
   -- Where the segment's data starts and ends in the frame, and its length
   signal p_start : natural range 0 to 94;
   signal p_end   : natural range 0 to 2 ** 16 + 13;
   signal plen    : integer range -80 to 2 ** 16;

   signal mac_b : t_bytes(0 to 5);
   signal ip_b  : t_bytes(0 to 3);

begin

   mac_b <= b6(mac_i);
   ip_b  <= b4(ip_i);

   ok <= rx_data_i = mac_b(idx) when idx <= 5 else
         rx_data_i = X"08" when idx = 12 else
         rx_data_i = X"00" when idx = 13 else
         rx_data_i = X"45" when idx = 14 else
         (rx_data_i and X"BF") = X"00" when idx = 20 else
         rx_data_i = X"00" when idx = 21 else
         rx_data_i = X"06" when idx = 23 else
         rx_data_i = ip_b(idx - 30) when idx >= 30 and idx <= 33 else
         rx_data_i = C_PORT(15 downto 8) when idx = 36 else
         rx_data_i = C_PORT(7 downto 0) when idx = 37 else
         true;

   p_start <= 34 + 4 * to_integer(f_doff);
   p_end   <= 14 + to_integer(f_len);
   plen    <= to_integer(f_len) - 20 - 4 * to_integer(f_doff);

   rx_ready_o <= not (last or done);
   -- Below C_MAXF, so that a longer frame writes no more than plen bytes
   we_o <= '1' when rx_valid_i = '1' and last = '0' and done = '0' and wr_ok = '1' and
                    idx >= p_start and idx < p_end and idx < C_MAXF else
           '0';

   good   <= '1' when m_ok = '1' and ip_sum = X"FFFF" and tcp_sum = X"FFFF" and
                      f_doff >= 5 and plen >= 0 and p_end <= idx else
             '0';
   done_o <= done;
   seg_o  <=
   (
      host  => (mac => f_smac, ip => f_sip, tcp_port => f_sport),
      seq   => f_seq,
      ack   => f_ack,
      flags => f_flags,
      win   => f_win
   );


   p_rx : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if rx_valid_i = '1' and last = '0' and done = '0' then
            if idx < C_MAXF then
               idx <= idx + 1;
            else
               m_ok <= '0';
            end if;
            if not ok then
               m_ok <= '0';
            end if;

            if idx >= 6 and idx <= 11 then
               f_smac <= f_smac(39 downto 0) & rx_data_i;
            end if;
            if idx = 16 or idx = 17 then
               f_len <= f_len(7 downto 0) & rx_data_i;
            end if;
            if idx >= 26 and idx <= 29 then
               f_sip <= f_sip(23 downto 0) & rx_data_i;
            end if;
            if idx = 34 or idx = 35 then
               f_sport <= f_sport(7 downto 0) & rx_data_i;
            end if;
            if idx >= 38 and idx <= 41 then
               f_seq <= f_seq(23 downto 0) & rx_data_i;
            end if;
            if idx >= 42 and idx <= 45 then
               f_ack <= f_ack(23 downto 0) & rx_data_i;
            end if;
            if idx = 46 then
               f_doff <= rx_data_i(7 downto 4);
            end if;
            if idx = 47 then
               f_flags <= rx_data_i;
            end if;
            if idx = 48 or idx = 49 then
               f_win <= f_win(7 downto 0) & rx_data_i;
            end if;

            -- The checksums. The pseudo header's protocol and TCP length
            -- are 6 + (f_len - 20), added once f_len is known.
            if idx mod 2 = 0 then
               hi <= rx_data_i;
            end if;
            if idx >= 14 and idx <= 33 and idx mod 2 = 1 then
               ip_sum <= ones_add(ip_sum, hi & rx_data_i);
            end if;
            if idx = 18 then
               tcp_sum <= ones_add(tcp_sum, f_len - 14);
            end if;
            if idx >= 26 and idx < p_end then
               if idx mod 2 = 1 then
                  tcp_sum <= ones_add(tcp_sum, hi & rx_data_i);
               elsif idx = p_end - 1 then
                  tcp_sum <= ones_add(tcp_sum, rx_data_i & X"00");
               end if;
            end if;

            -- Whether the data is the next of the connection, and fits;
            -- the header has passed far enough to know.
            if idx = 47 then
               len_o <= plen when plen > 0 else 0;
               if m_ok = '1' and take_i = '1' and f_sip = exp_ip_i and f_sport = exp_port_i and
                  f_seq = exp_seq_i and f_doff >= 5 and plen > 0 and plen <= free_i then
                  wr_ok <= '1';
               end if;
            end if;

            if rx_last_i = '1' then
               last <= '1';
            end if;
         end if;

         -- The cycle after the last byte: the verdict, and the next frame
         done <= last;
         if last = '1' then
            last    <= '0';
            good_o  <= good;
            wr_ok_o <= wr_ok;
            idx     <= 0;
            m_ok    <= '1';
            ip_sum  <= (others => '0');
            tcp_sum <= (others => '0');
            wr_ok   <= '0';
         end if;

         if rst_i = '1' then
            idx     <= 0;
            m_ok    <= '1';
            ip_sum  <= (others => '0');
            tcp_sum <= (others => '0');
            wr_ok   <= '0';
            last    <= '0';
            done    <= '0';
         end if;
      end if;
   end process p_rx;

end architecture synthesis;
