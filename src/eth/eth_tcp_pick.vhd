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
-- it has been (fin_sent_i); or the ACK that is owed (ack_req_i); or,
-- last of all, so that a flood of segments that fit no connection does
-- not hold the connection's back, the RST that the connection asks for
-- (rst_req_i), to the host, with the numbers, that it gives (rst_*_i).
-- The choice is dropped (drop_i) if a segment is read or the timer runs
-- out in any of the three cycles, as both change what may be sent. The
-- segment's header fields (seg_*) and where its data is go to
-- eth_tcp_tx.vhd; the receive window, and the fields of a RST, are taken
-- in B_PICK, as the segment is chosen, and adv_wnd_o is the window that
-- the last segment but a RST told, the one it sent.
-- The connection books what the segment carries in the cycle it is chosen,
-- from pick_o and pick_n_o.
--
-- INTERFACE CONTRACTS -- these are requirements on the environment:
-- a) The data from una_ptr_i on stays in the send buffer, and the
--    connection's numbers and the RST's change only in a cycle drop_i is
--    '1', or as pick_o says; more data may come at lim_ptr_i at any time.
-- b) mac_i and ip_i stay stable while busy_o is '1'.
--
-- With G_FORMAL, it states the properties that formal/eth_tcp_pick.sby
-- proves, under contract a): a segment is chosen only in B_PICK, and not
-- while one is sent, and every one but a RST acknowledges; the SYN-ACK,
-- data, the FIN, and the RST are chosen only as the header says, and
-- data never beyond the data there is or the host's window, but for the
-- probe; and the sender gets the connection's fields, its sequence
-- number, and the length chosen, or the RST's fields and numbers, which
-- stay while it is busy.
--
-- RESET
-- Synchronous, to clk_i. Reset drops the choice and the segment being
-- sent.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use work.eth_pkg.all;

entity eth_tcp_pick is
   generic (
      G_PORT      : natural := 4510;
      G_ADDR_BITS : natural := 11;
      G_MSS       : natural := 536;
      -- The properties for formal/eth_tcp_pick.sby
      G_FORMAL    : boolean := false
   );
   port (
      clk_i      : in  std_logic;
      rst_i      : in  std_logic;
      -- This station's addresses
      mac_i      : in  std_logic_vector(47 downto 0);
      ip_i       : in  std_logic_vector(31 downto 0);
      -- The connection: it waits for the ACK of its SYN-ACK, or is open;
      -- it owes the SYN-ACK, or an ACK; this side is closing, and its FIN
      -- has been sent; a byte goes beyond a window of 0; and what may be
      -- sent has changed
      syn_rcvd_i : in  std_logic;
      estab_i    : in  std_logic;
      syn_req_i  : in  std_logic;
      ack_req_i  : in  std_logic;
      closing_i  : in  std_logic;
      fin_sent_i : in  std_logic;
      probe_i    : in  std_logic;
      drop_i     : in  std_logic;
      -- The host, and the connection's numbers: the initial sequence
      -- number, that of the first byte not acknowledged, the next expected
      -- from the host, the host's window, and the receive window
      peer_i     : in  t_host;
      iss_i      : in  std_logic_vector(31 downto 0);
      una_seq_i  : in  std_logic_vector(31 downto 0);
      rcv_nxt_i  : in  std_logic_vector(31 downto 0);
      snd_wnd_i  : in  std_logic_vector(15 downto 0);
      free_i     : in  natural range 0 to 2 ** G_ADDR_BITS;
      -- A RST to send, with ACK or not, and where to: with ACK, its
      -- sequence number is 0 and rst_num_i its acknowledgment number;
      -- without, rst_num_i is its sequence number.
      rst_req_i  : in  std_logic;
      rst_ack_i  : in  std_logic;
      rst_host_i : in  t_host;
      rst_num_i  : in  std_logic_vector(31 downto 0);
      -- The data in the send buffer: the first byte not acknowledged, the
      -- next to send, and the end; and that the output has paused
      una_ptr_i  : in  std_logic_vector(G_ADDR_BITS downto 0);
      nxt_ptr_i  : in  std_logic_vector(G_ADDR_BITS downto 0);
      lim_ptr_i  : in  std_logic_vector(G_ADDR_BITS downto 0);
      paused_i   : in  std_logic;
      -- The segment chosen: its TCP flags, 0 when none, and how much data
      -- it takes; the receive window told in the last one; and that a
      -- segment is being sent
      pick_o     : out std_logic_vector(7 downto 0);
      pick_n_o   : out natural range 0 to G_MSS;
      adv_wnd_o  : out natural range 0 to 2 ** G_ADDR_BITS := 0;
      busy_o     : out std_logic;
      -- The send buffer: the byte at rd_addr_o, a cycle later
      rd_addr_o  : out std_logic_vector(G_ADDR_BITS - 1 downto 0);
      rd_data_i  : in  std_logic_vector(7 downto 0);
      -- The frames to send, to eth_tx_fifo.vhd
      tx_data_o  : out std_logic_vector(7 downto 0);
      tx_last_o  : out std_logic;
      tx_valid_o : out std_logic;
      tx_ready_i : in  std_logic
   );
end entity eth_tcp_pick;

architecture synthesis of eth_tcp_pick is

   constant C_SIZE : natural := 2 ** G_ADDR_BITS;

   constant C_FIN : std_logic_vector(7 downto 0) := X"01";
   constant C_SYN : std_logic_vector(7 downto 0) := X"02";
   constant C_RST : std_logic_vector(7 downto 0) := X"04";
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
   signal seg_host  : t_host                        := C_HOST_NONE;
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

   -- The segment chosen in B_PICK: the SYN-ACK, data, the FIN, an ACK, or
   -- a RST
   pick <= X"00" when build /= B_PICK or drop_i = '1' else
           C_SYN or C_ACK when syn_req_i = '1' and syn_rcvd_i = '1' else
           C_ACK or C_PSH when estab_i = '1' and pick_n > 0 and
                               (pick_big or paused_i = '1' or closing_i = '1') else
           C_FIN or C_ACK when estab_i = '1' and closing_i = '1' and nxt_ptr_i = lim_ptr_i and
                               fin_sent_i = '0' else
           C_ACK when estab_i = '1' and ack_req_i = '1' else
           C_RST or C_ACK when rst_req_i = '1' and rst_ack_i = '1' else
           C_RST when rst_req_i = '1' else
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
         seg_host_i  => seg_host,
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
                  seg_host <= peer_i;
                  seg_ack  <= rcv_nxt_i;
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
               -- The RST's host and numbers, and no window
               if pick(2) = '1' then
                  seg_host <= rst_host_i;
                  seg_wnd  <= X"0000";
                  if rst_ack_i = '1' then
                     seg_seq <= X"00000000";
                     seg_ack <= rst_num_i;
                  else
                     seg_seq <= rst_num_i;
                     seg_ack <= X"00000000";
                  end if;
               end if;
               -- Every segment but a RST acknowledges, with the window of
               -- now; a RST tells none.
               if pick /= X"00" then
                  go <= '1';
               end if;
               if pick /= X"00" and pick(2) = '0' then
                  seg_wnd   <= X"0000" + free_i;
                  adv_wnd_o <= free_i;
               end if;

         end case;

         if rst_i = '1' then
            build <= B_IDLE;
            go    <= '0';
         end if;
      end if;
   end process p_pick;


   gen_formal : if G_FORMAL generate
   begin

      -- psl default clock is rising_edge(clk_i);

      -- The choice
      -- psl f_build : assert always build = B_IDLE or build = B_SIZE or build = B_PICK;
      -- psl f_when : assert always pick /= X"00" -> build = B_PICK and drop_i = '0';
      -- psl f_idle : assert always build /= B_IDLE -> busy = '0';
      -- psl f_go : assert always go = '1' -> prev(busy) = '0';
      -- psl f_ack : assert always pick /= X"00" and pick(2) = '0' -> pick(4) = '1';
      -- psl f_rst : assert always pick(2) = '1' ->
      --    rst_req_i = '1' and
      --    ((rst_ack_i = '1' and pick = (C_RST or C_ACK)) or (rst_ack_i = '0' and pick = C_RST));
      -- psl f_syn : assert always pick(1) = '1' ->
      --    syn_req_i = '1' and syn_rcvd_i = '1' and pick = (C_SYN or C_ACK);
      -- psl f_data : assert always pick(3) = '1' ->
      --    estab_i = '1' and pick_n > 0 and pick = (C_ACK or C_PSH);
      -- psl f_fin : assert always pick(0) = '1' ->
      --    estab_i = '1' and closing_i = '1' and nxt_ptr_i = lim_ptr_i and fin_sent_i = '0' and
      --    pick_n = 0 and pick = (C_FIN or C_ACK);

      -- The size: what was worked out still holds when it is chosen from.
      -- psl f_avail : assert always build /= B_IDLE -> avail <= to_integer(lim_ptr_i - nxt_ptr_i);
      -- psl f_room : assert always build /= B_IDLE ->
      --    room = to_integer(snd_wnd_i) - to_integer(nxt_ptr_i - una_ptr_i);
      -- psl f_size : assert always build = B_PICK ->
      --    pick_n <= avail and pick_n <= G_MSS and
      --    (pick_n = 0 or pick_n <= room or (probe_i = '1' and pick_n = 1));
      -- psl f_fits : assert always pick(3) = '1' ->
      --    pick_n <= to_integer(lim_ptr_i - nxt_ptr_i) and
      --    (pick_n + to_integer(nxt_ptr_i - una_ptr_i) <= to_integer(snd_wnd_i) or
      --     (probe_i = '1' and pick_n = 1));

      -- The segment: the connection's fields, and what was chosen
      -- psl f_fields : assert always build /= B_IDLE ->
      --    seg_host = peer_i and seg_ack = rcv_nxt_i and seg_ptr = nxt_ptr_i and
      --    seg_seq = una_seq_i + (nxt_ptr_i - una_ptr_i) + fin_sent_i;
      -- psl f_sent : assert always go = '1' -> seg_flags = prev(pick) and
      --    (seg_flags(1) = '0' or seg_seq = prev(iss_i)) and
      --    (seg_flags(3) = '0' or seg_n = prev(pick_n)) and (seg_flags(3) = '1' or seg_n = 0) and
      --    (seg_flags(2) = '0' or
      --     (seg_host = prev(rst_host_i) and
      --      ((seg_flags(4) = '1' and seg_seq = 0 and seg_ack = prev(rst_num_i)) or
      --       (seg_flags(4) = '0' and seg_seq = prev(rst_num_i) and seg_ack = 0))));
      -- psl f_wnd : assert always {pick /= X"00" and pick(2) = '0'} |=>
      --    {adv_wnd_o = prev(free_i) and to_integer(seg_wnd) = adv_wnd_o};
      -- psl f_wnd_rst : assert always {pick(2) = '1'} |=>
      --    {adv_wnd_o = prev(adv_wnd_o) and seg_wnd = 0};
      -- psl f_stable : assert always busy = '1' and go = '0' ->
      --    seg_host = prev(seg_host) and seg_seq = prev(seg_seq) and seg_ack = prev(seg_ack) and seg_flags = prev(seg_flags) and
      --    seg_wnd = prev(seg_wnd) and seg_ptr = prev(seg_ptr) and seg_n = prev(seg_n);

      -- psl c_syn_sent : cover {pick(1) = '1' and rst_i = '0'};
      -- psl c_data : cover {pick(3) = '1' and pick_n = G_MSS and rst_i = '0'};
      -- psl c_paused : cover {pick(3) = '1' and pick_n < G_MSS and paused_i = '1' and rst_i = '0'};
      -- psl c_probe : cover {pick(3) = '1' and pick_n = 1 and probe_i = '1' and room <= 0 and
      --    rst_i = '0'};
      -- psl c_fin_sent : cover {pick(0) = '1' and rst_i = '0'};
      -- psl c_ack_sent : cover {pick = C_ACK and rst_i = '0'};
      -- psl c_rst_sent : cover {pick = C_RST and rst_i = '0'};
      -- psl c_rst_ack_sent : cover {pick = (C_RST or C_ACK) and rst_i = '0'};
      -- psl c_dropped : cover {build = B_PICK and drop_i = '1' and rst_i = '0'};
   end generate gen_formal;

end architecture synthesis;
