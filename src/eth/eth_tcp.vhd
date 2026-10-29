-- A small TCP server (RFC 9293) for the debug link: one connection at a
-- time, on port G_PORT of ip_i, which carries the link's two byte streams,
-- as the UART does (nicemon.vhd). It reads the received frames of
-- eth_rx_fifo.vhd alongside eth_arp.vhd and eth_icmp.vhd, and writes its
-- segments to eth_tx_fifo.vhd. ip_i at 0 turns it off.
--
-- THEORY OF OPERATION
-- The connection is the line. While there is one (on_o, a cycle behind,
-- from eth_tcp_buf.vhd), the link's input comes from it and its output
-- goes to it. A connection is one from the
-- host's ACK of the SYN-ACK on, so that a SYN alone, as of a port scan,
-- leaves the link on the UART. The host's half-close, its FIN, is a break
-- of the line (lrx_break_o), after the last byte committed (rx_cmt). The
-- link stays with the connection after its end, by an RST or the tries,
-- until it has taken all the input and the break, so that none is lost;
-- the output in that time is dropped. The states are those of a passive
-- open, and of a close:
--   LISTEN_ST      no connection; a SYN to G_PORT opens one
--   SYN_RCVD_ST    the SYN-ACK is sent, and waits for the host's ACK
--   EST_ST         the connection is open
--   CLOSE_WAIT_ST  the host has half-closed; output still goes to it
--   LAST_ACK_ST    this side's FIN is sent, and waits for the host's ACK;
--                  the host's FIN has come (peer_fin), or not, when this
--                  side closed first
-- A new SYN from the host's IP address, from another port, replaces an
-- open connection. It waits in pend_*: the old connection gets the output
-- up to that point (fin_ptr), then its FIN, and when the host has
-- acknowledged that, or reset the old connection, or the tries have run
-- out, the new connection opens, and gets the output after it; an ACK
-- that the old one still owes the host goes first (fin_ack). The link
-- stays with it (keep) while it waits for the host's ACK. That is what the
-- host tools do at the end of a program's input (tools/nicelink.py), after
-- their FIN, and what a tool that starts again after a crash does,
-- without one. The old connection takes data and a FIN until its end, and
-- if its FIN has not come by then, the end is a break. Other SYNs are
-- ignored while a connection is open.
--
-- Receive: eth_tcp_rx.vhd reads a frame a byte at a time, keeps the
-- fields of a TCP segment to this station, and checks its checksums. The
-- segment's data goes into the receive buffer at rx_wr as it comes, if it
-- is the next data of the connection (its sequence number is rcv_nxt) and
-- fits (wr_ok, known before the data starts). In the second cycle after
-- the last byte (eval), with the stream held, the segment is acted on if
-- it is good; its data is committed (rx_cmt) only then, and rcv_nxt moves
-- past it. Its sequence and acknowledgment numbers are compared with the
-- connection's in registers (p_cmp), a cycle behind, for the timing; they
-- stand at eval, for the fields have been there since the frame's byte
-- 49, and the connection's numbers since the last segment acted on.
-- Every segment with data or a FIN gets an ACK (ack_req), also
-- one that is out of order, which is dropped, so the host sends it again;
-- so does one without either whose sequence number is not rcv_nxt, such
-- as a keepalive probe. A segment that overlaps data already taken is
-- dropped whole, and the host sends it again from the sequence number of
-- the ACK.
--
-- Send: the link's output goes into the send buffer at tail_ptr. una_ptr
-- is the first byte not yet acknowledged, whose sequence number is
-- una_seq, nxt_ptr the next to send, and max_ptr the highest sent. The
-- data goes out in segments of at most C_MSS bytes, as much as the host's
-- window takes, when there are C_MSS bytes or the output has paused for
-- C_IDLE cycles, so that one answer of the link goes in few segments. An
-- ACK of the host frees the bytes it covers. If nothing new is
-- acknowledged for C_RTO_MS, nxt_ptr goes back to una_ptr and the data is
-- sent again (go-back-N), up to C_TRIES times, after which the connection
-- is dropped. The SYN-ACK and the FIN are sent again in the same way.
-- While the host's window is 0 and there is data to send, the timer runs
-- as well, and its timeout sends one byte (probe), so that a window update
-- of the host that was lost is not waited for forever; an ACK with a
-- window of 0 starts the tries again, so the connection lasts while the
-- host answers.
-- The segment to send is chosen by eth_tcp_pick.vhd, from the numbers
-- here and what there is to send, and built and sent by eth_tcp_tx.vhd
-- under it; the choice is dropped (drop) if a segment is read or the
-- timer runs out meanwhile, as both change what may be sent. The
-- connection (p_tcp) books what the segment carries in the cycle it is
-- chosen, from its flags (pick): the SYN-ACK or the ACK asked for is
-- sent, the data is out, or the FIN is sent.
--
-- The receive window is the free space of the receive buffer, and when it
-- has grown by C_WND_STEP since the last segment, an ACK tells the host.
-- This side's window is the host's, taken from an ACK of data sent that is
-- not older than the last one it was taken from (snd_wl1 and snd_wl2, RFC
-- 9293 3.10.7.4), without scaling, for the SYN-ACK has no options; for the
-- same reason the host sends segments of at most 536 bytes. No RST is
-- sent; a segment that fits no connection is dropped. A segment belongs to
-- the connection by its IP address and ports, as TCP has it, whatever its
-- source MAC address; the segments of this side go to the MAC address of
-- the host's SYN.
--
-- The server is p_tcp, the connection, which acts on the segments and
-- owns its numbers, with p_cmp, which compares a segment with it, and
-- these entities: eth_tcp_rx.vhd, the parser; eth_tcp_pick.vhd, the
-- choice of the segments to send, with eth_tcp_tx.vhd, their sender;
-- eth_tcp_buf.vhd, the two buffers with their link side; and
-- eth_tcp_timer.vhd, the retransmission timer. What the connection tells
-- one of them that it cannot read is a pulse (brk_set, restart,
-- tries_clr), which lands a cycle later; each says why that is in time.
--
-- INTERFACE CONTRACTS -- these are requirements on the environment:
-- a) mac_i and ip_i stay stable while there is a connection.
-- b) G_CLOCK_HZ is the clock's rate, at least 1000, for the timers.
--
-- RESET
-- Synchronous, to clk_i. Reset drops the connection and empties both
-- buffers.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use work.eth_pkg.all;

entity eth_tcp is
   generic (
      G_CLOCK_HZ  : natural;
      G_PORT      : natural := 4510;
      G_ADDR_BITS : natural := 11
   );
   port (
      clk_i       : in  std_logic;
      rst_i       : in  std_logic;
      -- This station's addresses
      mac_i       : in  std_logic_vector(47 downto 0);
      ip_i        : in  std_logic_vector(31 downto 0);
      -- The received frames, from eth_rx_fifo.vhd
      rx_data_i   : in  std_logic_vector(7 downto 0);
      rx_last_i   : in  std_logic;
      rx_valid_i  : in  std_logic;
      rx_ready_o  : out std_logic;
      -- The frames to send, to eth_tx_fifo.vhd
      tx_data_o   : out std_logic_vector(7 downto 0) := (others => '0');
      tx_last_o   : out std_logic                    := '0';
      tx_valid_o  : out std_logic;
      tx_ready_i  : in  std_logic;
      -- The link: '1' while there is a connection, the bytes from the host
      -- and its half-close, and the bytes to the host
      on_o        : out std_logic;
      lrx_data_o  : out std_logic_vector(7 downto 0) := (others => '0');
      lrx_valid_o : out std_logic;
      lrx_ready_i : in  std_logic;
      lrx_break_o : out std_logic                    := '0';
      ltx_data_i  : in  std_logic_vector(7 downto 0);
      ltx_valid_i : in  std_logic;
      ltx_ready_o : out std_logic
   );
end entity eth_tcp;

architecture synthesis of eth_tcp is

   constant C_SIZE     : natural := 2 ** G_ADDR_BITS;
   constant C_MSS      : natural := 536;
   constant C_IDLE     : natural := 64;
   constant C_RTO_MS   : natural := 300;
   constant C_TRIES    : natural := 17;
   constant C_TICK     : natural := G_CLOCK_HZ / 1000;
   constant C_WND_STEP : natural := C_SIZE / 2;

   subtype t_ptr is std_logic_vector(G_ADDR_BITS downto 0);

   type   t_state is (LISTEN_ST, SYN_RCVD_ST, EST_ST, CLOSE_WAIT_ST, LAST_ACK_ST);
   signal state : t_state := LISTEN_ST;

   -- The connection
   signal peer_mac  : std_logic_vector(47 downto 0) := (others => '0');
   signal peer_ip   : std_logic_vector(31 downto 0) := (others => '0');
   signal peer_port : std_logic_vector(15 downto 0) := (others => '0');
   signal irs       : std_logic_vector(31 downto 0) := (others => '0');
   signal rcv_nxt   : std_logic_vector(31 downto 0) := (others => '0');
   signal iss       : std_logic_vector(31 downto 0) := (others => '0');
   signal una_seq   : std_logic_vector(31 downto 0) := (others => '0');
   signal snd_wnd   : std_logic_vector(15 downto 0) := (others => '0');
   signal snd_wl1   : std_logic_vector(31 downto 0) := (others => '0');
   signal snd_wl2   : std_logic_vector(31 downto 0) := (others => '0');
   signal una_ptr   : t_ptr                         := (others => '0');
   signal nxt_ptr   : t_ptr                         := (others => '0');
   signal max_ptr   : t_ptr                         := (others => '0');
   signal fin_ptr   : t_ptr                         := (others => '0');
   -- The end of the data to send to this connection
   signal lim_ptr : t_ptr;
   -- The close of this side: started, the FIN sent since the last
   -- retransmission, and the FIN sent at all
   signal closing  : std_logic                     := '0';
   signal fin_sent : std_logic                     := '0';
   signal fin_max  : std_logic                     := '0';
   -- The host has acknowledged this side's FIN.
   signal fin_ack : std_logic                     := '0';
   signal syn_req : std_logic                     := '0';
   signal ack_req : std_logic                     := '0';
   -- One byte goes beyond the host's window of 0.
   signal probe : std_logic                     := '0';
   -- The SYN of the next connection
   signal pend : std_logic                     := '0';
   -- The connection that waits for the ACK of its SYN-ACK came from pend,
   -- and has the link
   signal keep      : std_logic                     := '0';
   signal pend_mac  : std_logic_vector(47 downto 0) := (others => '0');
   signal pend_ip   : std_logic_vector(31 downto 0) := (others => '0');
   signal pend_port : std_logic_vector(15 downto 0) := (others => '0');
   signal pend_seq  : std_logic_vector(31 downto 0) := (others => '0');
   signal pend_win  : std_logic_vector(15 downto 0) := (others => '0');
   -- The retransmission timer (eth_tcp_timer.vhd) runs, runs out, and is
   -- on its last try
   signal armed    : std_logic;
   signal timeout  : std_logic;
   signal last_try : std_logic;
   -- The connection ends, once the ACK that the host is owed is sent.
   signal ending : std_logic;
   -- What the connection tells the timer, a cycle after: it starts again,
   -- or the tries alone do
   signal restart   : std_logic := '0';
   signal tries_clr : std_logic := '0';
   -- The initial sequence number, a cycle counter
   signal isn : std_logic_vector(31 downto 0) := (others => '0');

   -- The segment read (eth_tcp_rx.vhd), in the second cycle after its
   -- last byte
   signal eval    : std_logic;
   signal good    : std_logic;
   signal f_smac  : std_logic_vector(47 downto 0);
   signal f_sip   : std_logic_vector(31 downto 0);
   signal f_sport : std_logic_vector(15 downto 0);
   signal f_seq   : std_logic_vector(31 downto 0);
   signal f_ack   : std_logic_vector(31 downto 0);
   signal f_flags : std_logic_vector(7 downto 0);
   signal f_win   : std_logic_vector(15 downto 0);
   signal plen    : natural range 0 to 2 ** 16;
   signal wr_ok   : std_logic;
   -- The connection takes data.
   signal take : std_logic;
   -- The segment against the connection, a cycle behind: it is from the
   -- host; how far its acknowledgment number is past una_seq, its
   -- sequence number past snd_wl1 and rcv_nxt, and its acknowledgment
   -- number past snd_wl2; the end of its data; whether it acknowledges
   -- the SYN-ACK, and the FIN; and rcv_nxt past its data, with the FIN
   -- and without, and past a FIN alone
   signal from_peer : boolean                       := false;
   signal k         : std_logic_vector(31 downto 0) := (others => '0');
   signal d1        : std_logic_vector(31 downto 0) := (others => '0');
   signal seq_off   : std_logic_vector(31 downto 0) := (others => '0');
   signal d2        : std_logic_vector(31 downto 0) := (others => '0');
   signal f_end     : std_logic_vector(31 downto 0) := (others => '0');
   signal syn_acked : boolean                       := false;
   signal fin_acked : boolean                       := false;
   signal rcv_end   : std_logic_vector(31 downto 0) := (others => '0');
   signal rcv_end1  : std_logic_vector(31 downto 0) := (others => '0');
   signal rcv_nxt1  : std_logic_vector(31 downto 0) := (others => '0');

   -- The receive buffer (eth_tcp_buf.vhd): where a segment's data goes,
   -- the end of the data committed, and the room after it
   signal rx_wr   : t_ptr                     := (others => '0');
   signal rx_cmt  : t_ptr                     := (others => '0');
   signal rx_free : natural range 0 to C_SIZE;
   signal rx_we   : std_logic;
   -- The host's FIN has come.
   signal peer_fin : std_logic := '0';
   -- The connection's half-close for the link, a cycle after
   signal brk_set : std_logic := '0';

   -- The send buffer (eth_tcp_buf.vhd): where the link's next byte goes,
   -- that its output has paused, and the sender's reads
   signal tail_ptr : t_ptr;
   signal paused   : std_logic;
   signal tx_raddr : std_logic_vector(G_ADDR_BITS - 1 downto 0);
   signal tx_rdata : std_logic_vector(7 downto 0);

   -- The segment chosen (eth_tcp_pick.vhd): its TCP flags, 0 when none,
   -- how much data it takes, the receive window told in the last one, and
   -- that one is being sent
   signal pick    : std_logic_vector(7 downto 0);
   signal pick_n  : natural range 0 to C_MSS;
   signal adv_wnd : natural range 0 to C_SIZE;
   signal busy    : std_logic;
   -- A segment is acted on, the connection ends, or the timer runs out:
   -- the segment being chosen is dropped.
   signal drop : std_logic;

   -- The connection waits for the ACK of its SYN-ACK, is open, and is the
   -- line
   signal syn_rcvd : std_logic;
   signal estab    : std_logic;
   signal conn     : std_logic;

begin

   syn_rcvd <= '1' when state = SYN_RCVD_ST else
               '0';
   estab    <= '1' when state = EST_ST or state = CLOSE_WAIT_ST or state = LAST_ACK_ST else
               '0';
   conn     <= estab or (syn_rcvd and keep);

   ---------------------------------------------------------------------------
   -- Receive
   ---------------------------------------------------------------------------

   take <= '1' when state /= LISTEN_ST and peer_fin = '0' else
           '0';

   i_eth_tcp_rx : entity work.eth_tcp_rx
      generic map (
         G_PORT      => G_PORT,
         G_ADDR_BITS => G_ADDR_BITS
      )
      port map (
         clk_i      => clk_i,
         rst_i      => rst_i,
         mac_i      => mac_i,
         ip_i       => ip_i,
         rx_data_i  => rx_data_i,
         rx_last_i  => rx_last_i,
         rx_valid_i => rx_valid_i,
         rx_ready_o => rx_ready_o,
         take_i     => take,
         exp_ip_i   => peer_ip,
         exp_port_i => peer_port,
         exp_seq_i  => rcv_nxt,
         free_i     => rx_free,
         we_o       => rx_we,
         done_o     => eval,
         good_o     => good,
         smac_o     => f_smac,
         sip_o      => f_sip,
         sport_o    => f_sport,
         seq_o      => f_seq,
         ack_o      => f_ack,
         flags_o    => f_flags,
         win_o      => f_win,
         wr_ok_o    => wr_ok,
         len_o      => plen
      ); -- i_eth_tcp_rx


   ---------------------------------------------------------------------------
   -- The buffers
   ---------------------------------------------------------------------------

   i_eth_tcp_buf : entity work.eth_tcp_buf
      generic map (
         G_ADDR_BITS => G_ADDR_BITS,
         G_IDLE      => C_IDLE
      )
      port map (
         clk_i       => clk_i,
         rst_i       => rst_i,
         conn_i      => conn,
         una_ptr_i   => una_ptr,
         ltx_data_i  => ltx_data_i,
         ltx_valid_i => ltx_valid_i,
         ltx_ready_o => ltx_ready_o,
         tail_ptr_o  => tail_ptr,
         paused_o    => paused,
         rd_addr_i   => tx_raddr,
         rd_data_o   => tx_rdata,
         wr_we_i     => rx_we,
         wr_addr_i   => rx_wr,
         wr_data_i   => rx_data_i,
         cmt_i       => rx_cmt,
         free_o      => rx_free,
         brk_set_i   => brk_set,
         lrx_data_o  => lrx_data_o,
         lrx_valid_o => lrx_valid_o,
         lrx_ready_i => lrx_ready_i,
         lrx_break_o => lrx_break_o,
         on_o        => on_o
      ); -- i_eth_tcp_buf

   ---------------------------------------------------------------------------
   -- Send
   ---------------------------------------------------------------------------

   lim_ptr <= fin_ptr when closing = '1' else
              tail_ptr;

   ending <= '1' when fin_ack = '1' and ack_req = '0' and busy = '0' else
             '0';

   -- The timer runs while the SYN-ACK, data, or the FIN is out, or a
   -- window of 0 holds data back; it stands still while a segment is
   -- acted on or the connection ends, which come first.
   armed <= '1' when state = SYN_RCVD_ST or max_ptr /= una_ptr or
                     (state = LAST_ACK_ST and fin_max = '1') or
                     (conn = '1' and snd_wnd = 0 and lim_ptr /= una_ptr) else
            '0';

   i_eth_tcp_timer : entity work.eth_tcp_timer
      generic map (
         G_TICK   => C_TICK,
         G_RTO_MS => C_RTO_MS,
         G_TRIES  => C_TRIES
      )
      port map (
         clk_i       => clk_i,
         rst_i       => rst_i,
         armed_i     => armed,
         hold_i      => eval or ending,
         restart_i   => restart,
         tries_clr_i => tries_clr,
         timeout_o   => timeout,
         last_try_o  => last_try
      ); -- i_eth_tcp_timer


   drop <= eval or ending or timeout;

   i_eth_tcp_pick : entity work.eth_tcp_pick
      generic map (
         G_PORT      => G_PORT,
         G_ADDR_BITS => G_ADDR_BITS,
         G_MSS       => C_MSS
      )
      port map (
         clk_i       => clk_i,
         rst_i       => rst_i,
         mac_i       => mac_i,
         ip_i        => ip_i,
         syn_rcvd_i  => syn_rcvd,
         estab_i     => estab,
         syn_req_i   => syn_req,
         ack_req_i   => ack_req,
         closing_i   => closing,
         fin_sent_i  => fin_sent,
         probe_i     => probe,
         drop_i      => drop,
         peer_mac_i  => peer_mac,
         peer_ip_i   => peer_ip,
         peer_port_i => peer_port,
         iss_i       => iss,
         una_seq_i   => una_seq,
         rcv_nxt_i   => rcv_nxt,
         snd_wnd_i   => snd_wnd,
         free_i      => rx_free,
         una_ptr_i   => una_ptr,
         nxt_ptr_i   => nxt_ptr,
         lim_ptr_i   => lim_ptr,
         paused_i    => paused,
         pick_o      => pick,
         pick_n_o    => pick_n,
         adv_wnd_o   => adv_wnd,
         busy_o      => busy,
         rd_addr_o   => tx_raddr,
         rd_data_i   => tx_rdata,
         tx_data_o   => tx_data_o,
         tx_last_o   => tx_last_o,
         tx_valid_o  => tx_valid_o,
         tx_ready_i  => tx_ready_i
      ); -- i_eth_tcp_pick


   p_cmp : process (clk_i)
   begin
      if rising_edge(clk_i) then
         from_peer <= f_sip = peer_ip and f_sport = peer_port;
         k         <= f_ack - una_seq;
         d1        <= f_seq - snd_wl1;
         seq_off   <= f_seq - rcv_nxt;
         d2        <= f_ack - snd_wl2;
         f_end     <= f_seq + plen;
         syn_acked <= f_ack = iss + 1;
         fin_acked <= f_ack = una_seq + (fin_ptr - una_ptr) + 1;
         rcv_end   <= rcv_nxt + plen;
         rcv_end1  <= rcv_nxt + plen + 1;
         rcv_nxt1  <= rcv_nxt + 1;
      end if;
   end process p_cmp;


   p_tcp : process (clk_i)
      variable syn_v : boolean;
      variable fin_v : boolean;

      -- Opens a connection for a SYN; the output after base goes to it.
      procedure accept (
         mac  : std_logic_vector(47 downto 0);
         ip   : std_logic_vector(31 downto 0);
         sport : std_logic_vector(15 downto 0);
         seq  : std_logic_vector(31 downto 0);
         win  : std_logic_vector(15 downto 0);
         base : t_ptr
      ) is
      begin
         state     <= SYN_RCVD_ST;
         peer_mac  <= mac;
         peer_ip   <= ip;
         peer_port <= sport;
         irs       <= seq;
         rcv_nxt   <= seq + 1;
         iss       <= isn;
         una_seq   <= isn + 1;
         snd_wnd   <= win;
         snd_wl1   <= seq;
         snd_wl2   <= isn;
         una_ptr   <= base;
         nxt_ptr   <= base;
         max_ptr   <= base;
         closing   <= '0';
         fin_sent  <= '0';
         fin_max   <= '0';
         fin_ack   <= '0';
         syn_req   <= '1';
         ack_req   <= '0';
         probe     <= '0';
         pend      <= '0';
         peer_fin  <= '0';
         restart   <= '1';
      end procedure accept;

      -- Ends the connection, and opens the one that waits, if any.
      procedure finish is
      begin
         if pend = '1' then
            accept(pend_mac, pend_ip, pend_port, pend_seq, pend_win, fin_ptr);
            keep <= '1';
            -- The old connection's input has ended.
            if peer_fin = '0' then
               brk_set <= '1';
            end if;
         else
            state   <= LISTEN_ST;
            keep    <= '0';
            fin_ack <= '0';
         end if;
      end procedure finish;

   begin
      if rising_edge(clk_i) then
         isn       <= isn + 1;
         brk_set   <= '0';
         restart   <= '0';
         tries_clr <= '0';

         -- A window that has grown is told.
         if state = EST_ST and rx_free >= adv_wnd + C_WND_STEP then
            ack_req <= '1';
         end if;

         -- A segment's data, as it comes
         if rx_we = '1' then
            rx_wr <= rx_wr + 1;
         end if;

         ------------------------------------------------------------------
         -- The segment, in the second cycle after its last byte
         ------------------------------------------------------------------
         if eval = '1' then
            rx_wr <= rx_cmt;

            if good = '1' and ip_i /= 0 then
               syn_v := f_flags(1) = '1' and f_flags(4) = '0' and f_flags(2) = '0';

               if syn_v then

                  case state is

                     when LISTEN_ST =>
                        accept(f_smac, f_sip, f_sport, f_seq, f_win, tail_ptr);

                     when SYN_RCVD_ST =>
                        -- Another SYN replaces it; the output after its base,
                        -- if the link is kept, goes to the new one.
                        if from_peer and f_seq = irs then
                           syn_req <= '1';
                        else
                           accept(f_smac, f_sip, f_sport, f_seq, f_win, una_ptr);
                        end if;

                     when EST_ST | CLOSE_WAIT_ST | LAST_ACK_ST =>
                        if from_peer and f_seq = irs then
                           ack_req <= '1';
                        elsif f_sip = peer_ip then
                           pend      <= '1';
                           pend_mac  <= f_smac;
                           pend_ip   <= f_sip;
                           pend_port <= f_sport;
                           pend_seq  <= f_seq;
                           pend_win  <= f_win;
                           if closing = '0' then
                              closing <= '1';
                              fin_ptr <= tail_ptr;
                           end if;
                        end if;

                  end case;

               elsif from_peer and state /= LISTEN_ST then
                  if f_flags(2) = '1' then
                     -- A reset, with a sequence number in the window
                     if seq_off < C_SIZE then
                        finish;
                     end if;
                  elsif state = SYN_RCVD_ST and not (f_flags(4) = '1' and syn_acked) then
                     -- Nothing but the ACK of the SYN-ACK opens the connection.
                     null;
                  else
                     -- The ACK of the SYN-ACK, which may carry data and a FIN
                     if state = SYN_RCVD_ST then
                        state   <= EST_ST;
                        keep    <= '0';
                        restart <= '1';
                     end if;

                     -- The ACK: the bytes it covers are free.
                     if f_flags(4) = '1' then
                        if k <= max_ptr - una_ptr and
                           ((d1 /= 0 and d1(31) = '0') or (d1 = 0 and d2(31) = '0')) then
                           snd_wnd <= f_win;
                           snd_wl1 <= f_seq;
                           snd_wl2 <= f_ack;
                           if f_win = 0 then
                              tries_clr <= '1';
                           end if;
                        end if;
                        if k /= 0 and k <= max_ptr - una_ptr then
                           una_ptr <= una_ptr + k(G_ADDR_BITS downto 0);
                           una_seq <= f_ack;
                           if k > nxt_ptr - una_ptr then
                              nxt_ptr <= una_ptr + k(G_ADDR_BITS downto 0);
                           end if;
                           restart <= '1';
                        end if;
                     end if;

                     -- The host's FIN, if all before it has come: after the
                     -- data written, whose sequence number is rcv_nxt, or
                     -- at rcv_nxt otherwise
                     fin_v := f_flags(0) = '1' and peer_fin = '0' and
                              (wr_ok = '1' or f_end = rcv_nxt);
                     -- The data, which was written if it is the next
                     if wr_ok = '1' then
                        rx_cmt  <= rx_wr;
                        rx_wr   <= rx_wr;
                        rcv_nxt <= rcv_end;
                        if fin_v then
                           rcv_nxt <= rcv_end1;
                        end if;
                     elsif fin_v then
                        rcv_nxt <= rcv_nxt1;
                     end if;
                     -- Data, a FIN, or a segment that is not the next, as a
                     -- keepalive probe at rcv_nxt - 1 is, gets an ACK.
                     if plen > 0 or f_flags(0) = '1' or seq_off /= 0 then
                        ack_req <= '1';
                     end if;
                     if fin_v then
                        if state = EST_ST or state = SYN_RCVD_ST then
                           state <= CLOSE_WAIT_ST;
                        end if;
                        peer_fin <= '1';
                        brk_set  <= '1';
                     end if;

                     -- The ACK of this side's FIN ends the connection.
                     if state = LAST_ACK_ST and fin_max = '1' and f_flags(4) = '1' and
                        fin_acked then
                        fin_ack <= '1';
                     end if;
                  end if;
               end if;
            end if;

         -- The end, once the ACK that the host is owed is sent
         elsif ending = '1' then
            finish;

         ------------------------------------------------------------------
         -- The retransmission timer runs out (eth_tcp_timer.vhd): what is out goes
         -- again, or a byte beyond a window of 0, until the tries are up
         ------------------------------------------------------------------
         elsif timeout = '1' then
            if last_try = '1' then
               finish;
            else
               nxt_ptr  <= una_ptr;
               fin_sent <= '0';
               if snd_wnd = 0 then
                  probe <= '1';
               end if;
               if state = SYN_RCVD_ST then
                  syn_req <= '1';
               end if;
            end if;
         end if;

         ------------------------------------------------------------------
         -- The segment chosen (eth_tcp_pick.vhd), by its flags: what it
         -- carries is out
         ------------------------------------------------------------------
         if pick /= X"00" then
            ack_req <= '0';
         end if;
         -- The SYN-ACK
         if pick(1) = '1' then
            syn_req <= '0';
         end if;
         -- The data
         if pick(3) = '1' then
            probe   <= '0';
            nxt_ptr <= nxt_ptr + pick_n;
            if nxt_ptr + pick_n - una_ptr > max_ptr - una_ptr then
               max_ptr <= nxt_ptr + pick_n;
            end if;
         end if;
         -- The FIN
         if pick(0) = '1' then
            fin_sent <= '1';
            fin_max  <= '1';
            state    <= LAST_ACK_ST;
         end if;

         if rst_i = '1' then
            state     <= LISTEN_ST;
            una_ptr   <= (others => '0');
            nxt_ptr   <= (others => '0');
            max_ptr   <= (others => '0');
            closing   <= '0';
            fin_sent  <= '0';
            fin_max   <= '0';
            fin_ack   <= '0';
            syn_req   <= '0';
            ack_req   <= '0';
            probe     <= '0';
            pend      <= '0';
            keep      <= '0';
            rx_wr     <= (others => '0');
            rx_cmt    <= (others => '0');
            peer_fin  <= '0';
            brk_set   <= '0';
            restart   <= '0';
            tries_clr <= '0';
         end if;
      end if;
   end process p_tcp;

end architecture synthesis;
