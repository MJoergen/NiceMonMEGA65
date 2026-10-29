-- The MAC address filter and the ARP responder: it reads the received
-- frames of eth_rx_fifo.vhd, keeps those to mac_i or to everyone, answers
-- each ARP request for ip_i with an ARP reply into eth_tx_fifo.vhd, and
-- ignores every other frame, which eth_icmp.vhd reads too. ip_i at 0 turns
-- the answers off.
--
-- THEORY OF OPERATION
-- A frame is read a byte at a time, and idx counts its bytes up to
-- C_ARP_LEN, the 14 bytes of the Ethernet header and the 28 of an ARP
-- packet (RFC 826) for IPv4 over Ethernet:
--   0-5    the destination MAC address, which must be mac_i or all ones
--   6-11   the source MAC address
--   12-13  the EtherType, 0x0806 for ARP
--   14-21  the hardware type 1, the protocol type 0x0800, the lengths 6
--          and 4, and the operation, 1 for a request
--   22-27  the sender's MAC address, kept in sha
--   28-31  the sender's IP address, kept in spa
--   32-37  the target's MAC address, ignored in a request
--   38-41  the target's IP address, which must be ip_i
-- dst_uc stays '1' while the destination's bytes so far are mac_i's, dst_bc
-- while they are 0xFF, and match while every other byte so far is as these
-- say; the bytes after C_ARP_LEN, the padding, are not looked at. If match
-- and one of dst_uc and dst_bc are still '1' at the frame's last byte, and
-- the frame has at least C_ARP_LEN bytes, the reply
-- goes out: to sha, from mac_i, with the operation 2, mac_i and ip_i as the
-- sender, and sha and spa as the target. rmii_tx.vhd pads it to the
-- shortest frame. No frame is read while the reply is written.
-- The bytes of mac_i and of ip_i are in the order they are sent: mac_i's
-- bits 47..40 are the first byte, and ip_i = 0xC0A80141 is 192.168.1.65.
--
-- INTERFACE CONTRACTS -- these are requirements on the environment:
-- a) mac_i and ip_i stay stable while a frame is read and its reply is
--    written. They are registers that only a write changes (board_io.vhd).
--
-- RESET
-- Synchronous, to clk_i. Reset starts a frame again, and drops a reply that
-- is being written, which leaves a part of it in eth_tx_fifo.vhd; that FIFO
-- has the same reset.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity eth_arp is
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
      tx_data_o  : out std_logic_vector(7 downto 0);
      tx_last_o  : out std_logic;
      tx_valid_o : out std_logic;
      tx_ready_i : in  std_logic
   );
end entity eth_arp;

architecture synthesis of eth_arp is

   constant C_ARP_LEN : natural := 42;

   type t_bytes is array (natural range <>) of std_logic_vector(7 downto 0);

   -- Bytes 12-21 of an ARP request for IPv4 over Ethernet
   constant C_REQUEST : t_bytes(12 to 21) := (
      X"08", X"06", X"00", X"01", X"08", X"00", X"06", X"04", X"00", X"01"
   );

   type   t_state is (RX_ST, TX_ST);
   signal state  : t_state                       := RX_ST;
   signal idx    : natural range 0 to C_ARP_LEN  := 0;
   signal dst_uc : std_logic                     := '1';
   signal dst_bc : std_logic                     := '1';
   signal match  : std_logic                     := '1';
   signal sha    : std_logic_vector(47 downto 0) := (others => '0');
   signal spa    : std_logic_vector(31 downto 0) := (others => '0');

   -- The addresses as bytes, in the order they are sent, and the reply
   signal mac_b   : t_bytes(0 to 5);
   signal ip_b    : t_bytes(0 to 3);
   signal sha_b   : t_bytes(0 to 5);
   signal spa_b   : t_bytes(0 to 3);
   signal reply_b : t_bytes(0 to C_ARP_LEN - 1);

   -- Whether the byte on rx_data_i is as a request has it: after the
   -- destination (ok), and in the destination, to mac_i (uc) or to all (bc)
   signal ok : boolean;
   signal uc : boolean;
   signal bc : boolean;

begin

   gen_mac : for i in 0 to 5 generate
      mac_b(i) <= mac_i(47 - 8 * i downto 40 - 8 * i);
      sha_b(i) <= sha(47 - 8 * i downto 40 - 8 * i);
   end generate gen_mac;

   gen_ip : for i in 0 to 3 generate
      ip_b(i)  <= ip_i(31 - 8 * i downto 24 - 8 * i);
      spa_b(i) <= spa(31 - 8 * i downto 24 - 8 * i);
   end generate gen_ip;

   reply_b <= sha_b & mac_b & C_REQUEST(12 to 20) & X"02" & mac_b & ip_b & sha_b & spa_b;

   ok <= rx_data_i = C_REQUEST(idx) when idx >= 12 and idx <= 21 else
         rx_data_i = ip_b(idx - 38) when idx >= 38 and idx < C_ARP_LEN else
         true;
   uc <= rx_data_i = mac_b(idx) when idx <= 5 else
         true;
   bc <= rx_data_i = X"FF" when idx <= 5 else
         true;

   rx_ready_o <= '1' when state = RX_ST else
                 '0';

   tx_data_o  <= reply_b(idx) when idx < C_ARP_LEN else
                 X"00";
   tx_last_o  <= '1' when idx = C_ARP_LEN - 1 else
                 '0';
   tx_valid_o <= '1' when state = TX_ST else
                 '0';

   p_arp : process (clk_i)
   begin
      if rising_edge(clk_i) then

         case state is

            when RX_ST =>
               if rx_valid_i = '1' then
                  if idx < C_ARP_LEN then
                     idx <= idx + 1;
                  end if;
                  if not ok then
                     match <= '0';
                  end if;
                  if not uc then
                     dst_uc <= '0';
                  end if;
                  if not bc then
                     dst_bc <= '0';
                  end if;
                  if idx >= 22 and idx <= 27 then
                     sha <= sha(39 downto 0) & rx_data_i;
                  end if;
                  if idx >= 28 and idx <= 31 then
                     spa <= spa(23 downto 0) & rx_data_i;
                  end if;

                  if rx_last_i = '1' then
                     idx    <= 0;
                     dst_uc <= '1';
                     dst_bc <= '1';
                     match  <= '1';
                     -- The destination is done by now, as is the request at
                     -- byte C_ARP_LEN - 1, if this is it.
                     if (dst_uc = '1' or dst_bc = '1') and match = '1' and ok and
                        idx >= C_ARP_LEN - 1 and ip_i /= 0 then
                        state <= TX_ST;
                     end if;
                  end if;
               end if;

            when TX_ST =>
               if tx_ready_i = '1' then
                  idx <= idx + 1;
                  if idx = C_ARP_LEN - 1 then
                     idx   <= 0;
                     state <= RX_ST;
                  end if;
               end if;

         end case;

         if rst_i = '1' then
            state  <= RX_ST;
            idx    <= 0;
            dst_uc <= '1';
            dst_bc <= '1';
            match  <= '1';
         end if;
      end if;
   end process p_arp;

end architecture synthesis;
