-- The choice of the TCP server's segments (eth_tcp.vhd): what to send,
-- and when, from what the connection has to send. The segment is built
-- and sent by eth_tcp_tx.vhd.
--
-- THEORY OF OPERATION
-- What may be sent is worked out in two cycles, for the timing, once the
-- last segment has gone (busy_o): how far the data and the host's window
-- go (B_IDLE: avail, the data from nxt_ptr_i to lim_ptr_i, and room, the
-- host's window snd_wnd_i less what is out past una_ptr_i, below 0 when
-- more is out than the window has), then how much of it a segment takes
-- (B_SIZE: pick_n, at most G_MSS bytes, and pick_big, whether that is a
-- whole segment; one byte beyond a window of 0 when probe_i says so).
-- The segment is chosen in the next (B_PICK), and pick_o is its TCP flags
-- in that cycle, 0 when none: the SYN-ACK (syn_req_i, while the
-- connection waits for its ACK, syn_rcvd_i); once the connection is open
-- (estab_i), data when there is a whole segment of it, or the output has
-- paused (paused_i), or this side is closing (closing_i); then its FIN,
-- once the data before it has been sent (nxt_ptr_i at lim_ptr_i), unless
-- it has been (fin_sent_i); or the ACK that is owed (ack_req_i). The
-- choice is dropped (drop_i) if a segment is read or the timer runs out
-- in any of the three cycles, as both change what may be sent. The
-- segment's header fields (seg_*) and where its data is go to
-- eth_tcp_tx.vhd, and adv_wnd_o is the receive window it told. The
-- connection books what the segment carries in the cycle it is chosen,
-- from pick_o and pick_n_o.
--
-- INTERFACE CONTRACTS -- these are requirements on the environment:
-- a) The data from una_ptr_i on stays in the send buffer, and the
--    connection's numbers change only in a cycle drop_i is '1', or as
--    pick_o says; more data may come at lim_ptr_i at any time.
-- b) mac_i and ip_i stay stable while busy_o is '1'.
--
-- RESET
-- Synchronous, to clk_i. Reset drops the choice and the segment being
-- sent.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity eth_tcp_pick is
   generic (
      G_PORT      : natural := 4510;
      G_ADDR_BITS : natural := 11;
      G_MSS       : natural := 536
   );
   port (
      clk_i       : in  std_logic;
      rst_i       : in  std_logic;
      -- This station's addresses
      mac_i       : in  std_logic_vector(47 downto 0);
      ip_i        : in  std_logic_vector(31 downto 0);
      -- The connection: it waits for the ACK of its SYN-ACK, or is open;
      -- it owes the SYN-ACK, or an ACK; this side is closing, and its FIN
      -- has been sent; a byte goes beyond a window of 0; and what may be
      -- sent has changed
      syn_rcvd_i  : in  std_logic;
      estab_i     : in  std_logic;
      syn_req_i   : in  std_logic;
      ack_req_i   : in  std_logic;
      closing_i   : in  std_logic;
      fin_sent_i  : in  std_logic;
      probe_i     : in  std_logic;
      drop_i      : in  std_logic;
      -- The host, and the connection's numbers: the initial sequence
      -- number, that of the first byte not acknowledged, the next expected
      -- from the host, the host's window, and the receive window
      peer_mac_i  : in  std_logic_vector(47 downto 0);
      peer_ip_i   : in  std_logic_vector(31 downto 0);
      peer_port_i : in  std_logic_vector(15 downto 0);
      iss_i       : in  std_logic_vector(31 downto 0);
      una_seq_i   : in  std_logic_vector(31 downto 0);
      rcv_nxt_i   : in  std_logic_vector(31 downto 0);
      snd_wnd_i   : in  std_logic_vector(15 downto 0);
      free_i      : in  natural range 0 to 2 ** G_ADDR_BITS;
      -- The data in the send buffer: the first byte not acknowledged, the
      -- next to send, and the end; and that the output has paused
      una_ptr_i   : in  std_logic_vector(G_ADDR_BITS downto 0);
      nxt_ptr_i   : in  std_logic_vector(G_ADDR_BITS downto 0);
      lim_ptr_i   : in  std_logic_vector(G_ADDR_BITS downto 0);
      paused_i    : in  std_logic;
      -- The segment chosen: its TCP flags, 0 when none, and how much data
      -- it takes; the receive window told in the last one; and that a
      -- segment is being sent
      pick_o      : out std_logic_vector(7 downto 0);
      pick_n_o    : out natural range 0 to G_MSS;
      adv_wnd_o   : out natural range 0 to 2 ** G_ADDR_BITS := 0;
      busy_o      : out std_logic;
      -- The send buffer: the byte at rd_addr_o, a cycle later
      rd_addr_o   : out std_logic_vector(G_ADDR_BITS - 1 downto 0);
      rd_data_i   : in  std_logic_vector(7 downto 0);
      -- The frames to send, to eth_tx_fifo.vhd
      tx_data_o   : out std_logic_vector(7 downto 0);
      tx_last_o   : out std_logic;
      tx_valid_o  : out std_logic;
      tx_ready_i  : in  std_logic
   );
end entity eth_tcp_pick;

architecture synthesis of eth_tcp_pick is

   constant C_SIZE : natural := 2 ** G_ADDR_BITS;

   constant C_FIN : std_logic_vector(7 downto 0) := X"01";
   constant C_SYN : std_logic_vector(7 downto 0) := X"02";
   constant C_PSH : std_logic_vector(7 downto 0) := X"08";
   constant C_ACK : std_logic_vector(7 downto 0) := X"10";

   subtype t_ptr is std_logic_vector(G_ADDR_BITS downto 0);

   function minimum (a : natural; b : natural) return natural is
   begin
      if a < b then
         return a;
      end if;
      return b;
   end function minimum;

   -- The segment being chosen, and the one being sent
   type   t_build is (B_IDLE, B_SIZE, B_PICK);
   signal build     : t_build                       := B_IDLE;
   signal pick      : std_logic_vector(7 downto 0);
   signal go        : std_logic                     := '0';
   signal busy      : std_logic;
   signal seg_mac   : std_logic_vector(47 downto 0) := (others => '0');
   signal seg_ip    : std_logic_vector(31 downto 0) := (others => '0');
   signal seg_port  : std_logic_vector(15 downto 0) := (others => '0');
   signal seg_seq   : std_logic_vector(31 downto 0) := (others => '0');
   signal seg_ack   : std_logic_vector(31 downto 0) := (others => '0');
   signal seg_flags : std_logic_vector(7 downto 0)  := (others => '0');
   signal seg_wnd   : std_logic_vector(15 downto 0) := (others => '0');
   signal seg_ptr   : t_ptr                         := (others => '0');
   -- The data that may be sent: how much there is from nxt_ptr_i on, the
   -- room for it in the host's window, below 0 when more is out than the
   -- window has, its length, and whether it is a whole segment
   signal avail    : natural range 0 to C_SIZE          := 0;
   signal room     : integer range -C_SIZE to 2 ** 16   := 0;
   signal pick_n   : natural range 0 to G_MSS           := 0;
   signal pick_big : boolean                            := false;
   signal seg_n    : natural range 0 to G_MSS           := 0;

begin

   -- The segment chosen in B_PICK: the SYN-ACK, data, the FIN, or an ACK
   pick <= X"00" when build /= B_PICK or drop_i = '1' else
           C_SYN or C_ACK when syn_req_i = '1' and syn_rcvd_i = '1' else
           X"00" when estab_i = '0' else
           C_ACK or C_PSH when pick_n > 0 and (pick_big or paused_i = '1' or closing_i = '1') else
           C_FIN or C_ACK when closing_i = '1' and nxt_ptr_i = lim_ptr_i and fin_sent_i = '0' else
           C_ACK when ack_req_i = '1' else
           X"00";

   pick_o   <= pick;
   pick_n_o <= pick_n;
   busy_o   <= busy;

   i_eth_tcp_tx : entity work.eth_tcp_tx
      generic map (
         G_PORT      => G_PORT,
         G_ADDR_BITS => G_ADDR_BITS,
         G_MSS       => G_MSS
      )
      port map (
         clk_i       => clk_i,
         rst_i       => rst_i,
         mac_i       => mac_i,
         ip_i        => ip_i,
         go_i        => go,
         busy_o      => busy,
         seg_mac_i   => seg_mac,
         seg_ip_i    => seg_ip,
         seg_port_i  => seg_port,
         seg_seq_i   => seg_seq,
         seg_ack_i   => seg_ack,
         seg_flags_i => seg_flags,
         seg_wnd_i   => seg_wnd,
         seg_addr_i  => seg_ptr(G_ADDR_BITS - 1 downto 0),
         seg_n_i     => seg_n,
         rd_addr_o   => rd_addr_o,
         rd_data_i   => rd_data_i,
         tx_data_o   => tx_data_o,
         tx_last_o   => tx_last_o,
         tx_valid_o  => tx_valid_o,
         tx_ready_i  => tx_ready_i
      ); -- i_eth_tcp_tx


   p_pick : process (clk_i)
      variable room_v : natural range 0 to 2 ** 16;
   begin
      if rising_edge(clk_i) then
         go <= '0';

         case build is

            -- What may be sent: worked out here and in B_SIZE, once the
            -- last segment has gone, and chosen from in the cycle after,
            -- unless a segment was read or the timer ran out meanwhile.
            when B_IDLE =>
               if drop_i = '0' and busy = '0' then
                  avail    <= to_integer(lim_ptr_i - nxt_ptr_i);
                  room     <= to_integer(snd_wnd_i) - to_integer(nxt_ptr_i - una_ptr_i);
                  seg_mac  <= peer_mac_i;
                  seg_ip   <= peer_ip_i;
                  seg_port <= peer_port_i;
                  seg_ack  <= rcv_nxt_i;
                  seg_wnd  <= X"0000" + free_i;
                  seg_ptr  <= nxt_ptr_i;
                  seg_n    <= 0;
                  -- After this side's FIN, the next sequence number is past it.
                  seg_seq  <= una_seq_i + (nxt_ptr_i - una_ptr_i) + fin_sent_i;
                  build    <= B_SIZE;
               end if;

            when B_SIZE =>
               build <= B_IDLE;
               if drop_i = '0' then
                  room_v := 0;
                  if room > 0 then
                     room_v := room;
                  end if;
                  pick_n   <= minimum(minimum(avail, room_v), G_MSS);
                  pick_big <= avail >= G_MSS;
                  if probe_i = '1' and room_v = 0 and avail > 0 then
                     pick_n   <= 1;
                     pick_big <= true;
                  end if;
                  build <= B_PICK;
               end if;

            when B_PICK =>
               build     <= B_IDLE;
               seg_flags <= pick;
               -- The SYN-ACK's sequence number, and the data's length
               if pick(1) = '1' then
                  seg_seq <= iss_i;
               end if;
               if pick(3) = '1' then
                  seg_n <= pick_n;
               end if;
               -- Every segment acknowledges, with the window of now.
               if pick /= X"00" then
                  adv_wnd_o <= free_i;
                  go        <= '1';
               end if;

         end case;

         if rst_i = '1' then
            build <= B_IDLE;
            go    <= '0';
         end if;
      end if;
   end process p_pick;

end architecture synthesis;
