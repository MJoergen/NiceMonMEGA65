-- The ICMP echo responder: it reads the received frames of eth_rx_fifo.vhd
-- alongside eth_arp.vhd, keeps a copy of each, and answers each ICMP echo
-- request (a ping) to mac_i and ip_i with an echo reply into
-- eth_tx_fifo.vhd. ip_i at 0 turns the answers off.
--
-- THEORY OF OPERATION
-- A frame is read a byte at a time into the memory mem, at idx, its count
-- of bytes so far. Its bytes are checked as they pass, for IPv4 (RFC 791)
-- and ICMP (RFC 792):
--   0-5    the destination MAC address, which must be mac_i; uc says so
--   12-13  the EtherType, 0x0800 for IPv4
--   14     the version 4 and the header length 5, so no options
--   16-17  the total length, kept in ip_len, at least 28
--   20-21  the flags and the fragment offset: no more fragments, and an
--          offset of 0, so a whole packet
--   23     the protocol, 1 for ICMP
--   30-33  the destination IP address, which must be ip_i
--   34-35  the ICMP type 8, an echo request, and the code 0
--   36-37  the ICMP checksum, kept in icmp_ck
-- match stays '1' while each of these is right. The 16-bit words of bytes
-- 14-33, the IP header, are added in sum, in ones' complement, which is
-- 0xFFFF for a header whose checksum is right. If all is right at the
-- frame's last byte, and the frame has the whole packet, 14 + ip_len
-- bytes, the reply goes out: 14 + ip_len bytes, the padding left off,
-- read back from mem as the request was, but for these:
--   0-5    the request's source MAC address, from bytes 6-11
--   6-11   mac_i
--   26-29  the request's destination IP address, ip_i, from bytes 30-33
--   30-33  the request's source IP address, from bytes 26-29
--   34     the ICMP type 0, an echo reply
--   36-37  the ICMP checksum, with the type's change in it
-- The two IP addresses only swap places, so the IP header's checksum stays
-- right. The ICMP checksum is updated as RFC 1624 (equation 3) has it,
-- ~(~icmp_ck + ~0x0800 + 0x0000), for the word of the type and code goes
-- from 0x0800 to 0x0000; that is right for every checksum, 0x0000 too.
-- The memory gives a byte a cycle after its address, which follows tx_idx,
-- the next byte to read; fetch says that the byte read is kept, and it
-- goes out on tx_data_o with tx_valid_o in the cycle after, until
-- tx_ready_i. So a byte takes at least two cycles. No frame is read while
-- the reply is written.
--
-- INTERFACE CONTRACTS -- these are requirements on the environment:
-- a) mac_i and ip_i stay stable while a frame is read and its reply is
--    written, as for eth_arp.vhd.
-- b) A frame has at most 2^G_ADDR_BITS - 1 bytes; a longer one gets no
--    reply. eth_rx_fifo.vhd, of the same size, holds no longer frame.
--
-- RESET
-- Synchronous, to clk_i. Reset starts a frame again, and drops a reply that
-- is being written, as for eth_arp.vhd.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use work.eth_pkg.all;

entity eth_icmp is
   generic (
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
      -- The frames to send, to eth_tx_fifo.vhd
      tx_data_o  : out std_logic_vector(7 downto 0) := (others => '0');
      tx_last_o  : out std_logic                    := '0';
      tx_valid_o : out std_logic;
      tx_ready_i : in  std_logic
   );
end entity eth_icmp;

architecture synthesis of eth_icmp is

   constant C_MAX : natural := 2 ** G_ADDR_BITS - 1;

   type   t_state is (RX_ST, TX_ST);
   signal state : t_state := RX_ST;

   -- The frame being read
   signal idx     : natural range 0 to C_MAX          := 0;
   signal uc      : std_logic                         := '1';
   signal match   : std_logic                         := '1';
   signal hi      : std_logic_vector(7 downto 0)      := (others => '0');
   signal sum     : std_logic_vector(15 downto 0)     := (others => '0');
   signal ip_len  : std_logic_vector(15 downto 0)     := (others => '0');
   signal icmp_ck : std_logic_vector(15 downto 0)     := (others => '0');
   -- Whether the byte on rx_data_i is right, and the destination's
   signal ok    : boolean;
   signal uc_ok : boolean;

   -- The reply being written: its length, the next byte to read, and the
   -- byte read
   signal len       : natural range 0 to 2 ** 16 + 13 := 0;
   signal tx_idx    : natural range 0 to 2 ** 16 + 13 := 0;
   signal fetch     : std_logic                       := '0';
   signal fetch_idx : natural range 0 to 2 ** 16 + 13 := 0;
   signal tx_valid  : std_logic                       := '0';
   signal ck_new    : std_logic_vector(15 downto 0);

   signal mac_b : t_bytes(0 to 5);
   signal ip_b  : t_bytes(0 to 3);

   -- The memory of the frame
   type   t_mem is array (0 to C_MAX) of std_logic_vector(7 downto 0);
   signal mem       : t_mem                        := (others => (others => '0'));
   signal mem_we    : std_logic;
   signal mem_raddr : natural range 0 to C_MAX;
   signal mem_rdata : std_logic_vector(7 downto 0) := (others => '0');

   attribute ram_style : string;
   attribute ram_style of mem : signal is "block";

   -- Where byte i of the reply is in the request
   function source (i : natural) return natural is
   begin
      if i <= 5 then
         return i + 6;
      elsif i >= 26 and i <= 29 then
         return i + 4;
      elsif i >= 30 and i <= 33 then
         return i - 4;
      else
         return i;
      end if;
   end function source;

begin

   mac_b <= b6(mac_i);
   ip_b  <= b4(ip_i);

   ok    <= rx_data_i = X"08" when idx = 12 else
         rx_data_i = X"00" when idx = 13 else
         rx_data_i = X"45" when idx = 14 else
         (rx_data_i and X"BF") = X"00" when idx = 20 else
         rx_data_i = X"00" when idx = 21 else
         rx_data_i = X"01" when idx = 23 else
         rx_data_i = ip_b(idx - 30) when idx >= 30 and idx <= 33 else
         rx_data_i = X"08" when idx = 34 else
         rx_data_i = X"00" when idx = 35 else
         true;
   uc_ok <= rx_data_i = mac_b(idx) when idx <= 5 else
            true;

   ck_new <= not ones_add(not icmp_ck, X"F7FF");

   rx_ready_o <= '1' when state = RX_ST else
                 '0';
   tx_valid_o <= tx_valid;

   mem_we    <= rx_valid_i when state = RX_ST else
                '0';
   mem_raddr <= source(tx_idx) when tx_idx <= C_MAX else
                0;

   p_mem : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if mem_we = '1' then
            mem(idx) <= rx_data_i;
         end if;
         mem_rdata <= mem(mem_raddr);
      end if;
   end process p_mem;

   p_icmp : process (clk_i)
   begin
      if rising_edge(clk_i) then

         case state is

            when RX_ST =>
               if rx_valid_i = '1' then
                  if idx < C_MAX then
                     idx <= idx + 1;
                  else
                     match <= '0';
                  end if;
                  if not ok then
                     match <= '0';
                  end if;
                  if not uc_ok then
                     uc <= '0';
                  end if;

                  if idx >= 14 and idx <= 33 then
                     if idx mod 2 = 0 then
                        hi <= rx_data_i;
                     else
                        sum <= ones_add(sum, hi & rx_data_i);
                     end if;
                  end if;
                  if idx = 16 then
                     ip_len(15 downto 8) <= rx_data_i;
                  end if;
                  if idx = 17 then
                     ip_len(7 downto 0) <= rx_data_i;
                  end if;
                  if idx = 36 then
                     icmp_ck(15 downto 8) <= rx_data_i;
                  end if;
                  if idx = 37 then
                     icmp_ck(7 downto 0) <= rx_data_i;
                  end if;

                  if rx_last_i = '1' then
                     idx   <= 0;
                     uc    <= '1';
                     match <= '1';
                     sum   <= (others => '0');
                     -- The frame has idx + 1 bytes.
                     if uc = '1' and match = '1' and sum = X"FFFF" and ip_len >= 28 and
                        14 + to_integer(ip_len) <= idx + 1 and ip_i /= 0 then
                        len    <= 14 + to_integer(ip_len);
                        tx_idx <= 0;
                        state  <= TX_ST;
                     end if;
                  end if;
               end if;

            when TX_ST =>
               if tx_ready_i = '1' and tx_valid = '1' then
                  tx_valid <= '0';
                  if tx_last_o = '1' then
                     state <= RX_ST;
                  end if;
               end if;

               -- The byte read in the cycle before
               if fetch = '1' then
                  if fetch_idx >= 6 and fetch_idx <= 11 then
                     tx_data_o <= mac_b(fetch_idx - 6);
                  elsif fetch_idx = 34 then
                     tx_data_o <= X"00";
                  elsif fetch_idx = 36 then
                     tx_data_o <= ck_new(15 downto 8);
                  elsif fetch_idx = 37 then
                     tx_data_o <= ck_new(7 downto 0);
                  else
                     tx_data_o <= mem_rdata;
                  end if;
                  tx_last_o <= '1' when fetch_idx = len - 1 else '0';
                  tx_valid  <= '1';
               end if;

               -- The memory reads at the source of tx_idx in every cycle;
               -- this read is kept.
               fetch <= '0';
               if fetch = '0' and tx_idx < len and (tx_valid = '0' or tx_ready_i = '1') then
                  fetch     <= '1';
                  fetch_idx <= tx_idx;
                  tx_idx    <= tx_idx + 1;
               end if;

         end case;

         if rst_i = '1' then
            state    <= RX_ST;
            idx      <= 0;
            uc       <= '1';
            match    <= '1';
            sum      <= (others => '0');
            fetch    <= '0';
            tx_valid <= '0';
         end if;
      end if;
   end process p_icmp;

end architecture synthesis;
