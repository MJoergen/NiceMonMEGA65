-- The Ethernet station's side of the port for Ethernet frames of
-- nice_cpu's SYSTEM.md §7 (nice_cpu/hdl/src/eth_regs.vhd, in
-- src/devices.vhd): it reads the received frames of eth_rx_fifo.vhd beside
-- the responders, passes each that the station does not serve to the
-- port's queue, and sends the frames of the port's send buffer through
-- the arbiter (eth_arb.vhd).
--
-- THEORY OF OPERATION
-- A frame is read a byte at a time, idx counting its bytes so far, and
-- packed into the words of buf as the program reads them: big-endian,
-- from byte 2 (pos = idx + 2), word pos / 4, byte pos mod 4 from the top.
-- A word is written when its last byte comes, or the frame's. Its bytes
-- are checked as they pass, as niceemu's station does (nice_cpu's
-- emulator/src/eth.zig, serve):
--   0-5    the destination MAC address, mac_i (uc) or all ones (bc)
--   12-13  the EtherType, kept in etype
--   14-21  for ARP, the hardware type 1, the protocol type 0x0800, the
--          lengths 6 and 4, and the operation 1, a request
--   38-41  for ARP, the target's IP address, which must be ip_i
--   14     for IPv4, the version 4, and the header length, kept in ihl
--   16-17  for IPv4, the total length, kept in total
--   23     for IPv4, the protocol, kept in proto
--   30-33  for IPv4, the destination IP address, which must be ip_i
--   h, h+1 the ICMP type 8, an echo request, and the code 0, where h is
--          14 + 4 * ihl, the end of the IP header
--   h+2, h+3  the TCP destination port, which must be G_PORT
-- After the last byte, two cycles decide. The station serves the frame,
-- while ip_i is not 0, if it is an ARP request for ip_i of at least 42
-- bytes, or an IPv4 packet to ip_i, whose header has at least 20 bytes and
-- fits its total length, which fits the frame, and which is an ICMP echo
-- request of at least 8 bytes, or TCP to G_PORT. The responders and the
-- TCP server (eth_arp.vhd, eth_icmp.vhd, eth_tcp.vhd) check more, such as
-- the checksums, so a frame served may get no answer, but the program
-- sees the frames that niceemu's program does. A frame passes to the port
-- if it is to mac_i or to everyone, the station does not serve it, and it
-- has 14 to 1514 bytes.
-- A frame that passes is then put into the port: q_start_o for a cycle,
-- then its words from buf, one a cycle, a cycle after each is read, and
-- q_done_o with its length. eth_regs.vhd decides whether it takes the
-- frame, and counts it as dropped if it is enabled and full, so the
-- frames that the station serves never count. The stream is held while
-- the frame is decided and put, at most 382 cycles, which the FIFO of
-- received frames absorbs.
-- tx_start_i starts a frame to send: the bytes 2 to tx_len_i + 1 of the
-- send buffer. tx_addr_o reads a word, which is on tx_data_i two cycles
-- later, as eth_regs.vhd registers the address; it is kept in tword, and
-- its bytes go out on tx_data_o, with tx_last_o at the frame's last byte,
-- and tx_done_o for a cycle after that byte is taken. eth_tx_fifo.vhd
-- holds the whole frame, so the gaps between words cost nothing, and
-- rmii_tx.vhd pads it and adds the check sequence.
--
-- INTERFACE CONTRACTS -- these are requirements on the environment:
-- a) mac_i and ip_i stay stable while a frame is read, as for
--    eth_arp.vhd.
-- b) tx_start_i comes only when no frame is sent, and tx_len_i is 14 to
--    1514 and holds until tx_done_o, as eth_regs.vhd does them.
--
-- RESET
-- Synchronous, to clk_i. Reset starts a frame again, and drops a frame
-- that is being put or sent. tx_done_o still ends a frame that was sent,
-- or started in the cycle of reset, so that eth_regs.vhd, whose busy a
-- reset keeps, does not wait for it for good.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use work.eth_pkg.all;

entity eth_frames is
   generic (
      -- The TCP port of the debug link (eth_tcp.vhd)
      G_PORT : natural := 4510
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
      -- The frames for the port's queue (eth_regs.vhd)
      q_start_o  : out std_logic                     := '0';
      q_we_o     : out std_logic                     := '0';
      q_addr_o   : out std_logic_vector(8 downto 0)  := (others => '0');
      q_data_o   : out std_logic_vector(31 downto 0) := (others => '0');
      q_done_o   : out std_logic                     := '0';
      q_len_o    : out std_logic_vector(10 downto 0) := (others => '0');
      -- The frame of the port's send buffer (eth_regs.vhd)
      tx_start_i : in  std_logic;
      tx_len_i   : in  std_logic_vector(10 downto 0);
      tx_addr_o  : out std_logic_vector(8 downto 0)  := (others => '0');
      tx_data_i  : in  std_logic_vector(31 downto 0);
      tx_done_o  : out std_logic                     := '0';
      -- The frames to send, to eth_arb.vhd
      tx_data_o  : out std_logic_vector(7 downto 0);
      tx_last_o  : out std_logic;
      tx_valid_o : out std_logic;
      tx_ready_i : in  std_logic
   );
end entity eth_frames;

architecture synthesis of eth_frames is

   -- The longest frame that passes, and the words of the buffer that the
   -- port has
   constant C_MAX_LEN : natural := 1514;
   constant C_WORDS   : natural := 384;

   -- Bytes 14-21 of an ARP request for IPv4 over Ethernet
   constant C_REQUEST : t_bytes(14 to 21) := (
      X"00", X"01", X"08", X"00", X"06", X"04", X"00", X"01"
   );

   constant C_PORT : std_logic_vector(15 downto 0) := to_stdlogicvector(G_PORT, 16);

   type t_ram is array (0 to 511) of std_logic_vector(31 downto 0);

   signal buf : t_ram := (others => (others => '0'));

   -- Reading a frame, deciding it in two steps, and putting it into the
   -- port
   type   t_rx_state is (READ_ST, CHECK_ST, DECIDE_ST, PUT_ST);
   signal rx_state : t_rx_state := READ_ST;

   -- The bytes of the frame so far, and idx + 2, the byte of the buffer
   signal idx  : std_logic_vector(11 downto 0) := (others => '0');
   signal pos  : std_logic_vector(11 downto 0) := X"002";
   signal word : std_logic_vector(31 downto 0) := (others => '0');
   -- The length of the frame read
   signal len : std_logic_vector(11 downto 0) := (others => '0');

   -- The fields and the matches of the frame so far
   signal uc    : std_logic                     := '1';
   signal bc    : std_logic                     := '1';
   signal etype : std_logic_vector(15 downto 0) := (others => '0');
   signal arp_m : std_logic                     := '1';
   signal ver4  : std_logic                     := '0';
   signal ihl   : std_logic_vector(3 downto 0)  := (others => '0');
   -- Past every byte of a frame that the queue takes, so that hdr_end + 3
   -- does not wrap to the first bytes
   signal hdr_end : std_logic_vector(11 downto 0) := X"FF0";
   signal total   : std_logic_vector(15 downto 0) := (others => '0');
   signal proto   : std_logic_vector(7 downto 0)  := (others => '0');
   signal dst_m   : std_logic                     := '1';
   signal icmp_m  : std_logic                     := '1';
   signal port_m  : std_logic                     := '1';

   -- The checks of CHECK_ST
   signal is_arp  : std_logic := '0';
   signal is_ip   : std_logic := '0';
   signal is_icmp : std_logic := '0';
   signal is_tcp  : std_logic := '0';
   signal size_ok : std_logic := '0';
   signal ip_on   : std_logic := '0';

   -- Putting the frame: the next word to read, the words, and the word read
   signal rd_addr : std_logic_vector(8 downto 0)  := (others => '0');
   signal n_words : std_logic_vector(8 downto 0)  := (others => '0');
   signal rd_data : std_logic_vector(31 downto 0) := (others => '0');

   -- The addresses as bytes, in the order they are sent
   signal mac_b : t_bytes(0 to 5);
   signal ip_b  : t_bytes(0 to 3);

   -- Sending: the address is out, the word is read, its bytes go out
   type   t_tx_state is (IDLE_ST, ADDR_ST, READ_ST, SEND_ST);
   signal tx_state : t_tx_state                    := IDLE_ST;
   signal tpos     : std_logic_vector(10 downto 0) := (others => '0');
   signal tend     : std_logic_vector(10 downto 0) := (others => '0');
   signal tword    : std_logic_vector(31 downto 0) := (others => '0');

begin

   mac_b <= b6(mac_i);
   ip_b  <= b4(ip_i);

   rx_ready_o <= '1' when rx_state = READ_ST else
                 '0';

   q_data_o <= rd_data;

   p_rx : process (clk_i)
      variable word_v : std_logic_vector(31 downto 0);
      variable n_v    : natural range 0 to 4095;
      variable nw_v   : std_logic_vector(11 downto 0);
   begin
      if rising_edge(clk_i) then
         q_start_o <= '0';
         q_we_o    <= '0';
         q_done_o  <= '0';

         case rx_state is

            when READ_ST =>
               if rx_valid_i = '1' then
                  -- The byte goes into its word, which is written when it
                  -- is whole or the frame ends.
                  word_v := word;
                  case pos(1 downto 0) is
                     when "00"   => word_v(31 downto 24) := rx_data_i;
                     when "01"   => word_v(23 downto 16) := rx_data_i;
                     when "10"   => word_v(15 downto 8)  := rx_data_i;
                     when others => word_v(7 downto 0)   := rx_data_i;
                  end case;
                  if pos(1 downto 0) = "11" or rx_last_i = '1' then
                     if pos < C_WORDS * 4 then
                        buf(to_integer(pos(10 downto 2))) <= word_v;
                     end if;
                     word <= (others => '0');
                  else
                     word <= word_v;
                  end if;

                  if idx /= X"FFF" then
                     idx <= idx + 1;
                     pos <= pos + 1;
                  end if;

                  n_v := to_integer(idx);
                  if n_v <= 5 then
                     if rx_data_i /= mac_b(n_v) then
                        uc <= '0';
                     end if;
                     if rx_data_i /= X"FF" then
                        bc <= '0';
                     end if;
                  end if;
                  if n_v = 12 then
                     etype(15 downto 8) <= rx_data_i;
                  end if;
                  if n_v = 13 then
                     etype(7 downto 0) <= rx_data_i;
                  end if;
                  if n_v >= 14 and n_v <= 21 then
                     if rx_data_i /= C_REQUEST(n_v) then
                        arp_m <= '0';
                     end if;
                  end if;
                  if n_v >= 38 and n_v <= 41 then
                     if rx_data_i /= ip_b(n_v - 38) then
                        arp_m <= '0';
                     end if;
                  end if;
                  if n_v = 14 then
                     ver4    <= '1' when rx_data_i(7 downto 4) = X"4" else '0';
                     ihl     <= rx_data_i(3 downto 0);
                     hdr_end <= 14 + ("000000" & rx_data_i(3 downto 0) & "00");
                  end if;
                  if n_v = 16 then
                     total(15 downto 8) <= rx_data_i;
                  end if;
                  if n_v = 17 then
                     total(7 downto 0) <= rx_data_i;
                  end if;
                  if n_v = 23 then
                     proto <= rx_data_i;
                  end if;
                  if n_v >= 30 and n_v <= 33 then
                     if rx_data_i /= ip_b(n_v - 30) then
                        dst_m <= '0';
                     end if;
                  end if;
                  if idx = hdr_end and rx_data_i /= X"08" then
                     icmp_m <= '0';
                  end if;
                  if idx = hdr_end + 1 and rx_data_i /= X"00" then
                     icmp_m <= '0';
                  end if;
                  if idx = hdr_end + 2 and rx_data_i /= C_PORT(15 downto 8) then
                     port_m <= '0';
                  end if;
                  if idx = hdr_end + 3 and rx_data_i /= C_PORT(7 downto 0) then
                     port_m <= '0';
                  end if;

                  if rx_last_i = '1' then
                     len      <= idx + 1;
                     rx_state <= CHECK_ST;
                  end if;
               end if;

            when CHECK_ST =>
               -- The parts of the verdict, from registers only, for the
               -- timing
               is_arp  <= '0';
               is_ip   <= '0';
               is_icmp <= '0';
               is_tcp  <= '0';
               size_ok <= '0';
               ip_on   <= '0';
               if etype = X"0806" and len >= 42 and arp_m = '1' then
                  is_arp <= '1';
               end if;
               if etype = X"0800" and ver4 = '1' and ihl >= 5 and dst_m = '1' and
                  total >= ("00" & ihl & "00") and ("00000" & len) >= ('0' & total) + 14 then
                  is_ip <= '1';
               end if;
               if proto = X"01" and icmp_m = '1' and total >= ("00" & ihl & "00") + 8 then
                  is_icmp <= '1';
               end if;
               if proto = X"06" and G_PORT /= 0 and port_m = '1' and
                  total >= ("00" & ihl & "00") + 4 then
                  is_tcp <= '1';
               end if;
               if (uc = '1' or bc = '1') and len >= 14 and len <= C_MAX_LEN then
                  size_ok <= '1';
               end if;
               if ip_i /= 0 then
                  ip_on <= '1';
               end if;
               rx_state <= DECIDE_ST;

            when DECIDE_ST =>
               rd_addr  <= (others => '0');
               nw_v     := len + 5;
               n_words  <= nw_v(10 downto 2);
               rx_state <= READ_ST;
               if size_ok = '1' and
                  not (ip_on = '1' and (is_arp = '1' or
                                          (is_ip = '1' and (is_icmp = '1' or is_tcp = '1')))) then
                  q_start_o <= '1';
                  rx_state  <= PUT_ST;
               end if;

            when PUT_ST =>
               -- A word is read, and written to the port in the cycle
               -- after; q_done_o follows the last.
               if rd_addr < n_words then
                  rd_data  <= buf(to_integer(rd_addr));
                  q_we_o   <= '1';
                  q_addr_o <= rd_addr;
                  rd_addr  <= rd_addr + 1;
               else
                  q_done_o <= '1';
                  q_len_o  <= len(10 downto 0);
                  rx_state <= READ_ST;
               end if;

         end case;

         if rx_state = DECIDE_ST then
            -- The next frame starts afresh, once CHECK_ST has used the
            -- flags of this one.
            idx     <= (others => '0');
            pos     <= X"002";
            uc      <= '1';
            bc      <= '1';
            arp_m   <= '1';
            dst_m   <= '1';
            icmp_m  <= '1';
            port_m  <= '1';
            hdr_end <= X"FF0";
         end if;

         if rst_i = '1' then
            rx_state <= READ_ST;
            idx      <= (others => '0');
            pos      <= X"002";
            word     <= (others => '0');
            uc       <= '1';
            bc       <= '1';
            arp_m    <= '1';
            dst_m    <= '1';
            icmp_m   <= '1';
            port_m   <= '1';
            hdr_end  <= X"FF0";
            q_start_o <= '0';
            q_we_o    <= '0';
            q_done_o  <= '0';
         end if;
      end if;
   end process p_rx;


   tx_data_o  <= tword(31 downto 24) when tpos(1 downto 0) = "00" else
                 tword(23 downto 16) when tpos(1 downto 0) = "01" else
                 tword(15 downto 8) when tpos(1 downto 0) = "10" else
                 tword(7 downto 0);
   tx_last_o  <= '1' when tpos = tend else
                 '0';
   tx_valid_o <= '1' when tx_state = SEND_ST else
                 '0';

   p_tx : process (clk_i)
   begin
      if rising_edge(clk_i) then
         tx_done_o <= '0';

         case tx_state is

            when IDLE_ST =>
               if tx_start_i = '1' then
                  -- The frame is bytes 2 to tx_len_i + 1 of the buffer.
                  tpos      <= "000" & X"02";
                  tend      <= tx_len_i + 1;
                  tx_addr_o <= (others => '0');
                  tx_state  <= ADDR_ST;
               end if;

            when ADDR_ST =>
               tx_state <= READ_ST;

            when READ_ST =>
               tword    <= tx_data_i;
               tx_state <= SEND_ST;

            when SEND_ST =>
               if tx_ready_i = '1' then
                  tpos <= tpos + 1;
                  if tpos = tend then
                     tx_done_o <= '1';
                     tx_state  <= IDLE_ST;
                  elsif tpos(1 downto 0) = "11" then
                     tx_addr_o <= tx_addr_o + 1;
                     tx_state  <= ADDR_ST;
                  end if;
               end if;

         end case;

         if rst_i = '1' then
            tx_done_o <= '0';
            if tx_state /= IDLE_ST or tx_start_i = '1' then
               tx_done_o <= '1';
            end if;
            tx_state <= IDLE_ST;
         end if;
      end if;
   end process p_tx;

end architecture synthesis;
